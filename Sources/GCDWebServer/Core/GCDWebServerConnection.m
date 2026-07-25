/*
   Copyright (c) 2012-2019, Pierre-Olivier Latour
   All rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
   or promote products derived from this software without specific
   prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
   ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
   WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
   DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
   DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
   (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
   LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
   ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#if !__has_feature(objc_arc)
#error GCDWebServer requires ARC
#endif

#import <netdb.h>
#import <sys/socket.h>
#import <TargetConditionals.h>
#ifdef __GCDWEBSERVER_ENABLE_TESTING__
#import <stdatomic.h>
#endif

#import "GCDWebServerPrivate.h"

#define kHeadersReadCapacity (1 * 1024)
#define kBodyReadCapacity (256 * 1024)
#define kHeadersMaxLength (64 * 1024)  // Upper bound on total request header bytes, to cap memory for a client that never sends the terminating blank line.
#define kMaxHeaderPhaseTicks 2  // Idle-timer ticks a connection may spend receiving its request line + headers before being closed (defeats a slowloris dribbling bytes just under the zero-progress check).
#define kMinReceiveBytesPerSecond 32  // Throughput a connection must sustain while its request body is still arriving; see -_checkIdleTimeout.

typedef void (^ReadDataCompletionBlock)(BOOL success);
typedef void (^ReadHeadersCompletionBlock)(NSData *extraData);
typedef void (^ReadBodyCompletionBlock)(BOOL success);

typedef void (^WriteDataCompletionBlock)(BOOL success);
typedef void (^WriteHeadersCompletionBlock)(BOOL success);
typedef void (^WriteBodyCompletionBlock)(BOOL success);

static NSData *_CRLFData = nil;
static NSData *_CRLFCRLFData = nil;
static NSData *_continueData = nil;
static NSData *_lastChunkData = nil;
static NSString *_digestAuthenticationSecret = nil;  // Per-process key for minting/validating Digest nonces
#ifdef __GCDWEBSERVER_ENABLE_TESTING__
static _Atomic(int32_t) _connectionCounter = 0;
#endif

NS_ASSUME_NONNULL_BEGIN

@interface GCDWebServerConnection (Read)
- (void)readData:(NSMutableData *)data withLength:(NSUInteger)length completionBlock:(ReadDataCompletionBlock)block;
- (void)readHeaders:(NSMutableData *)headersData withCompletionBlock:(ReadHeadersCompletionBlock)block;
- (void)readBodyWithRemainingLength:(NSUInteger)length completionBlock:(ReadBodyCompletionBlock)block;
- (void)readNextBodyChunk:(NSMutableData *)chunkData completionBlock:(ReadBodyCompletionBlock)block;
@end

@interface GCDWebServerConnection (Write)
- (void)writeData:(NSData *)data withCompletionBlock:(WriteDataCompletionBlock)block;
- (void)writeHeadersWithCompletionBlock:(WriteHeadersCompletionBlock)block;
- (void)writeBodyWithCompletionBlock:(WriteBodyCompletionBlock)block;
@end

NS_ASSUME_NONNULL_END

@implementation GCDWebServerConnection {
    CFSocketNativeHandle _socket;
    dispatch_queue_t _connectionQueue;
    BOOL _virtualHEAD;

    // Server configuration captured once at accept time. The server re-creates these
    // ivars (e.g. when it rebuilds its listening sockets on a background/foreground
    // cycle) while this connection may still be live on its own queue; reading the
    // server's mutable ivars directly would be a data race (and could momentarily
    // observe nil auth, bypassing authentication). Each connection instead reads its
    // own stable snapshot for its whole life.
    NSString *_serverName;
    NSString *_authenticationRealm;
    NSDictionary<NSString *, NSString *> *_authenticationBasicAccounts;
    NSDictionary<NSString *, NSString *> *_authenticationDigestAccounts;
    BOOL _shouldAutomaticallyMapHEADToGET;

    CFHTTPMessageRef _requestMessage;
    GCDWebServerRequest *_request;
    GCDWebServerHandler *_handler;
    CFHTTPMessageRef _responseMessage;
    GCDWebServerResponse *_response;
    NSInteger _statusCode;

    BOOL _opened;

    dispatch_source_t _idleTimer;  // Nil when idle timeouts are disabled
    NSUInteger _pendingIOCount;    // Accessed on _connectionQueue only
    NSUInteger _idleCheckedBytes;  // Accessed on _connectionQueue only
    BOOL _idleCheckWasBusy;        // Accessed on _connectionQueue only
    NSUInteger _headerPhaseTicks;  // Idle ticks elapsed before a request was matched; on _connectionQueue only
    BOOL _requestReceived;         // Set once the body is fully read and the handler runs; on _connectionQueue only
    NSTimeInterval _idleTimeout;   // Seconds between idle-timer ticks; 0 when idle timeouts are disabled

#ifdef __GCDWEBSERVER_ENABLE_TESTING__
    NSUInteger _connectionIndex;
    NSString *_requestPath;
    int _requestFD;
    NSString *_responsePath;
    int _responseFD;
#endif
}

+ (void)initialize {
    if (_CRLFData == nil) {
        _CRLFData = [[NSData alloc] initWithBytes:"\r\n" length:2];
        GWS_DCHECK(_CRLFData);
    }

    if (_CRLFCRLFData == nil) {
        _CRLFCRLFData = [[NSData alloc] initWithBytes:"\r\n\r\n" length:4];
        GWS_DCHECK(_CRLFCRLFData);
    }

    if (_continueData == nil) {
        CFHTTPMessageRef message = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 100, NULL, kCFHTTPVersion1_1);
        _continueData = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(message));
        CFRelease(message);
        GWS_DCHECK(_continueData);
    }

    if (_lastChunkData == nil) {
        _lastChunkData = [[NSData alloc] initWithBytes:"0\r\n\r\n" length:5];
    }

    if (_digestAuthenticationSecret == nil) {
        CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
        _digestAuthenticationSecret = GCDWebServerComputeMD5Digest(@"%@", CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuid)));
        CFRelease(uuid);
    }
}

- (BOOL)isUsingIPv6 {
    const struct sockaddr *localSockAddr = _localAddressData.bytes;

    return (localSockAddr->sa_family == AF_INET6);
}

- (void)_initializeResponseHeadersWithStatusCode:(NSInteger)statusCode {
    _statusCode = statusCode;
    _responseMessage = CFHTTPMessageCreateResponse(kCFAllocatorDefault, statusCode, NULL, kCFHTTPVersion1_1);
    CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Connection"), CFSTR("Close"));
    CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Server"), (__bridge CFStringRef)_serverName);
    CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Date"), (__bridge CFStringRef)GCDWebServerFormatRFC822([NSDate date]));
}

- (void)_startProcessingRequest {
    GWS_DCHECK(_responseMessage == NULL);
    _requestReceived = YES;  // Nothing further is read from the socket for this request

    GCDWebServerResponse *preflightResponse = [self preflightRequest:_request];

    if (preflightResponse) {
        [self _finishProcessingRequest:preflightResponse];
    } else {
        // Guard against an async handler that invokes its completion block more than
        // once: a second call would overwrite _responseMessage (leaking the first
        // CFHTTPMessageRef) and race a second write chain on the same socket.
        __block BOOL processed = NO;
        [self processRequest:_request
                  completion:^(GCDWebServerResponse *processResponse) {
                      if (processed) {
                          GWS_LOG_ERROR(@"Ignoring extra completion block invocation for request on socket %i", self->_socket);
                          return;
                      }
                      processed = YES;
                      [self _finishProcessingRequest:processResponse];
                  }];
    }
}

// http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html
- (void)_finishProcessingRequest:(GCDWebServerResponse *)response {
    GWS_DCHECK(_responseMessage == NULL);
    BOOL hasBody = NO;

    if (response) {
        response = [self overrideResponse:response forRequest:_request];
    }

    if (response) {
        if ([response hasBody]) {
            [response prepareForReading];
            hasBody = !_virtualHEAD;
        }

        NSError *error = nil;

        if (hasBody && ![response performOpen:&error]) {
            GWS_LOG_ERROR(@"Failed opening response body for socket %i: %@", _socket, error);
        } else {
            _response = response;
        }
    }

    if (_response) {
        [self _initializeResponseHeadersWithStatusCode:_response.statusCode];

        if (_response.lastModifiedDate) {
            CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Last-Modified"), (__bridge CFStringRef)GCDWebServerFormatRFC822((NSDate *)_response.lastModifiedDate));
        }

        if (_response.eTag) {
            CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("ETag"), (__bridge CFStringRef)_response.eTag);
        }

        if ((_response.statusCode >= 200) && (_response.statusCode < 300)) {
            if (_response.cacheControlMaxAge > 0) {
                CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Cache-Control"), (__bridge CFStringRef)[NSString stringWithFormat:@"max-age=%i, public", (int)_response.cacheControlMaxAge]);
            } else {
                CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Cache-Control"), CFSTR("no-cache"));
            }
        }

        if (_response.contentType != nil) {
            CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Content-Type"), (__bridge CFStringRef)GCDWebServerNormalizeHeaderValue(_response.contentType));
        }

        if (_response.contentLength != NSUIntegerMax) {
            CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Content-Length"), (__bridge CFStringRef)[NSString stringWithFormat:@"%lu", (unsigned long)_response.contentLength]);
        }

        if (_response.usesChunkedTransferEncoding) {
            CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Transfer-Encoding"), CFSTR("chunked"));
        }

        [_response.additionalHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            CFHTTPMessageSetHeaderFieldValue(self->_responseMessage, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
        }];
        [self writeHeadersWithCompletionBlock:^(BOOL success) {
            if (success) {
                if (hasBody) {
                    [self writeBodyWithCompletionBlock:^(BOOL successInner) {
                        [self->_response performClose];  // TODO: There's nothing we can do on failure as headers have already been sent
                    }];
                }
            } else if (hasBody) {
                [self->_response performClose];
            }
        }];
    } else {
        [self abortRequest:_request withStatusCode:kGCDWebServerHTTPStatusCode_InternalServerError];
    }
}

- (void)_readBodyWithLength:(NSUInteger)length initialData:(NSData *)initialData {
    NSError *error = nil;

    if (![_request performOpen:&error]) {
        GWS_LOG_ERROR(@"Failed opening request body for socket %i: %@", _socket, error);
        [self abortRequest:_request withStatusCode:kGCDWebServerHTTPStatusCode_InternalServerError];
        return;
    }

    if (initialData.length) {
        if (![_request performWriteData:initialData error:&error]) {
            GWS_LOG_ERROR(@"Failed writing request body on socket %i: %@", _socket, error);

            if (![_request performClose:&error]) {
                GWS_LOG_ERROR(@"Failed closing request body for socket %i: %@", _socket, error);
            }

            [self abortRequest:_request withStatusCode:kGCDWebServerHTTPStatusCode_InternalServerError];
            return;
        }

        length -= initialData.length;
    }

    if (length) {
        [self readBodyWithRemainingLength:length
                          completionBlock:^(BOOL success) {
                              NSError *localError = nil;

                              if (!success) {
                                  // The body read failed: the client disconnected mid-body, the
                                  // chunk framing was malformed, or a size cap rejected it. Don't
                                  // hand the handler a partial body as if it were complete.
                                  [self->_request performClose:NULL];
                                  [self abortRequest:self->_request withStatusCode:kGCDWebServerHTTPStatusCode_InternalServerError];
                                  return;
                              }

                              if ([self->_request performClose:&localError]) {
                                  [self _startProcessingRequest];
                              } else {
                                  GWS_LOG_ERROR(@"Failed closing request body for socket %i: %@", self->_socket, localError);
                                  [self abortRequest:self->_request withStatusCode:kGCDWebServerHTTPStatusCode_InternalServerError];
                              }
                          }];
    } else {
        if ([_request performClose:&error]) {
            [self _startProcessingRequest];
        } else {
            GWS_LOG_ERROR(@"Failed closing request body for socket %i: %@", _socket, error);
            [self abortRequest:_request withStatusCode:kGCDWebServerHTTPStatusCode_InternalServerError];
        }
    }
}

- (void)_readChunkedBodyWithInitialData:(NSData *)initialData {
    NSError *error = nil;

    if (![_request performOpen:&error]) {
        GWS_LOG_ERROR(@"Failed opening request body for socket %i: %@", _socket, error);
        [self abortRequest:_request withStatusCode:kGCDWebServerHTTPStatusCode_InternalServerError];
        return;
    }

    NSMutableData *const chunkData = [[NSMutableData alloc] initWithData:initialData];
    [self readNextBodyChunk:chunkData
            completionBlock:^(BOOL success) {
                NSError *localError = nil;

                if (!success) {
                    // The body read failed: the client disconnected mid-body, the chunk
                    // framing was malformed, or a size cap rejected it. Don't hand the
                    // handler a partial body as if it were complete.
                    [self->_request performClose:NULL];
                    [self abortRequest:self->_request withStatusCode:kGCDWebServerHTTPStatusCode_InternalServerError];
                    return;
                }

                if ([self->_request performClose:&localError]) {
                    [self _startProcessingRequest];
                } else {
                    GWS_LOG_ERROR(@"Failed closing request body for socket %i: %@", self->_socket, localError);
                    [self abortRequest:self->_request withStatusCode:kGCDWebServerHTTPStatusCode_InternalServerError];
                }
            }];
}

// Runs on _connectionQueue. A connection is considered hung when a socket read or write
// has been pending across two consecutive timer ticks without enough bytes moving in
// either direction; requiring two ticks avoids killing an I/O operation that merely
// started just before a tick. Time spent waiting on a request handler to produce a
// response (no pending socket I/O) never counts, so slow handlers are unaffected. How
// much counts as "enough" depends on the phase — see the two guards below.
- (void)_checkIdleTimeout {
    NSUInteger transferredBytes = _totalBytesRead + _totalBytesWritten;
    BOOL waitingOnSocket = (_pendingIOCount > 0);

    // Absolute deadline for the request-line + headers phase (before any handler is
    // matched, i.e. while _request is still nil — assigned on this same queue). Headers
    // are small and bounded, so no legitimate client needs more than this; a deadline
    // rather than a rate is what defeats a slowloris trickling them out forever.
    if (_request == nil) {
        _headerPhaseTicks += 1;

        if (_headerPhaseTicks > kMaxHeaderPhaseTicks) {
            GWS_LOG_WARNING(@"Closing connection on socket %i: request headers not fully received within the header-phase deadline", _socket);
            dispatch_source_cancel(_idleTimer);
            shutdown(_socket, SHUT_RDWR);
            return;
        }
    }

    // While the request body is still arriving, require real progress rather than merely
    // *some* progress. The zero-progress rule below is defeated by a client dribbling a
    // single byte per tick — it costs the attacker nothing and pins a connection slot
    // indefinitely, and kGCDWebServerMaxConnections of them deny service to the whole
    // server. The floor is a *rate* scaled by the tick length, not a fixed count: a fixed
    // count means the effective throughput demand rises as the configured timeout shrinks,
    // which would disconnect a slow-but-genuine uploader on a short timeout. The response
    // phase deliberately keeps the laxer rule so a slow but live reader (an SSE stream
    // between heartbeats) is never cut off, and time spent inside a request handler still
    // never counts because no socket I/O is pending.
    NSUInteger minimumProgress = 1;

    if (_request && !_requestReceived) {
        minimumProgress = (NSUInteger)(kMinReceiveBytesPerSecond * _idleTimeout);
        minimumProgress = MAX(minimumProgress, (NSUInteger)1);
    }

    BOOL starved = ((transferredBytes - _idleCheckedBytes) < minimumProgress);

    if (waitingOnSocket && _idleCheckWasBusy && starved) {
        GWS_LOG_WARNING(@"Closing connection on socket %i: too few bytes transferred while waiting on socket I/O across the idle timeout", _socket);
        dispatch_source_cancel(_idleTimer);
        // Shut down (rather than close) so the pending read completes with EOF or
        // the pending write errors, and the connection tears down through its
        // normal paths; the descriptor itself is still closed in -dealloc.
        shutdown(_socket, SHUT_RDWR);
        return;
    }

    _idleCheckWasBusy = waitingOnSocket;
    _idleCheckedBytes = transferredBytes;
}

- (void)_readRequestHeaders {
    _requestMessage = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true);
    NSMutableData *const headersData = [[NSMutableData alloc] initWithCapacity:kHeadersReadCapacity];
    [self readHeaders:headersData
        withCompletionBlock:^(NSData *extraData) {
            if (extraData) {
                NSString *requestMethod = CFBridgingRelease(CFHTTPMessageCopyRequestMethod(self->_requestMessage));  // Method verbs are case-sensitive and uppercase

                if (self->_shouldAutomaticallyMapHEADToGET && [requestMethod isEqualToString:@"HEAD"]) {
                    requestMethod = @"GET";
                    self->_virtualHEAD = YES;
                }

                NSDictionary *const requestHeaders = CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(self->_requestMessage));  // Header names are case-insensitive but CFHTTPMessageCopyAllHeaderFields() will standardize the common ones
                NSURL *requestURL = CFBridgingRelease(CFHTTPMessageCopyRequestURL(self->_requestMessage));

                if (requestURL) {
                    requestURL = [self rewriteRequestURL:requestURL withMethod:requestMethod headers:requestHeaders];
                    GWS_DCHECK(requestURL);
                }

                NSString *urlPath = requestURL ? CFBridgingRelease(CFURLCopyPath((CFURLRef)requestURL)) : nil;  // Don't use -[NSURL path] which strips the ending slash

                if (urlPath == nil) {
                    urlPath = @"/";  // CFURLCopyPath() returns NULL for a relative URL with path "//" contrary to -[NSURL path] which returns "/"
                }

                NSString *const requestPath = urlPath ? GCDWebServerUnescapeURLString(urlPath) : nil;
                NSString *const queryString = requestURL ? CFBridgingRelease(CFURLCopyQueryString((CFURLRef)requestURL, NULL)) : nil;  // Don't use -[NSURL query] to make sure query is not unescaped;
                NSDictionary *const requestQuery = queryString ? GCDWebServerParseURLEncodedForm(queryString) : @{};

                if (requestMethod && requestURL && requestHeaders && requestPath && requestQuery) {
                    for (self->_handler in self->_server.handlers) {
                        self->_request = self->_handler.matchBlock(requestMethod, requestURL, requestHeaders, requestPath, requestQuery);

                        if (self->_request) {
                            break;
                        }
                    }

                    if (self->_request) {
                        self->_request.localAddressData = self.localAddressData;
                        self->_request.remoteAddressData = self.remoteAddressData;

                        if ([self->_request hasBody]) {
                            [self->_request prepareForWriting];

                            if (self->_request.usesChunkedTransferEncoding || (extraData.length <= self->_request.contentLength)) {
                                NSString *const expectHeader = requestHeaders[@"Expect"];

                                if (expectHeader) {
                                    if ([expectHeader caseInsensitiveCompare:@"100-continue"] == NSOrderedSame) {  // TODO: Actually validate request before continuing
                                        [self writeData:_continueData
                                            withCompletionBlock:^(BOOL success) {
                                                if (success) {
                                                    if (self->_request.usesChunkedTransferEncoding) {
                                                        [self _readChunkedBodyWithInitialData:extraData];
                                                    } else {
                                                        [self _readBodyWithLength:self->_request.contentLength initialData:extraData];
                                                    }
                                                } else {
                                                    // Without this the request is left neither answered nor
                                                    // aborted, and the connection just unwinds silently.
                                                    [self abortRequest:self->_request withStatusCode:kGCDWebServerHTTPStatusCode_InternalServerError];
                                                }
                                            }];
                                    } else {
                                        GWS_LOG_ERROR(@"Unsupported 'Expect' / 'Content-Length' header combination on socket %i", self->_socket);
                                        [self abortRequest:self->_request withStatusCode:kGCDWebServerHTTPStatusCode_ExpectationFailed];
                                    }
                                } else {
                                    if (self->_request.usesChunkedTransferEncoding) {
                                        [self _readChunkedBodyWithInitialData:extraData];
                                    } else {
                                        [self _readBodyWithLength:self->_request.contentLength initialData:extraData];
                                    }
                                }
                            } else {
                                GWS_LOG_ERROR(@"Unexpected 'Content-Length' header value on socket %i", self->_socket);
                                [self abortRequest:self->_request withStatusCode:kGCDWebServerHTTPStatusCode_BadRequest];
                            }
                        } else {
                            [self _startProcessingRequest];
                        }
                    } else {
                        self->_request = [[GCDWebServerRequest alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:requestPath query:requestQuery];

                        if (self->_request) {
                            [self abortRequest:self->_request withStatusCode:kGCDWebServerHTTPStatusCode_NotImplemented];
                        } else {
                            // The base request rejected these headers too — a framing conflict
                            // such as "Content-Length" together with a chunked "Transfer-Encoding"
                            // — so no handler could have matched. That is a malformed request
                            // rather than an unimplemented one, and must not assert.
                            GWS_LOG_ERROR(@"Rejecting malformed request headers on socket %i", self->_socket);
                            [self abortRequest:nil withStatusCode:kGCDWebServerHTTPStatusCode_BadRequest];
                        }
                    }
                } else {
                    // Reachable on ordinary malformed input, not an unreachable state: a
                    // request-target whose percent-escapes are invalid or not valid UTF-8
                    // (e.g. "GET /%FF") makes GCDWebServerUnescapeURLString return nil. That
                    // is the client's error, so answer 400 rather than 500 — and never abort.
                    GWS_LOG_ERROR(@"Failed decoding request target on socket %i", self->_socket);
                    [self abortRequest:nil withStatusCode:kGCDWebServerHTTPStatusCode_BadRequest];
                }
            } else {
                [self abortRequest:nil withStatusCode:kGCDWebServerHTTPStatusCode_InternalServerError];
            }
        }];
}

- (instancetype)initWithServer:(GCDWebServer *)server localAddress:(NSData *)localAddress remoteAddress:(NSData *)remoteAddress socket:(CFSocketNativeHandle)socket {
    if ((self = [super init])) {
        _server = server;
        // Snapshot the server's config now (see the ivar declarations): the accept
        // handler runs only while the listening socket is live, i.e. after -_start has
        // populated this config and before -_stop tears it down, so this read is safe.
        _serverName = server.serverName;
        _authenticationRealm = server.authenticationRealm;
        _authenticationBasicAccounts = server.authenticationBasicAccounts;
        _authenticationDigestAccounts = server.authenticationDigestAccounts;
        _shouldAutomaticallyMapHEADToGET = server.shouldAutomaticallyMapHEADToGET;
        _localAddressData = localAddress;
        _remoteAddressData = remoteAddress;
        _socket = socket;
        _connectionQueue = dispatch_queue_create("gcdwebserver.connection", DISPATCH_QUEUE_SERIAL);
        GWS_LOG_DEBUG(@"Did open connection on socket %i", _socket);

        NSTimeInterval idleTimeout = server.connectionIdleTimeout;
        _idleTimeout = idleTimeout;

        if (idleTimeout > 0.0) {
            _idleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _connectionQueue);
            uint64_t interval = (uint64_t)(idleTimeout * (NSTimeInterval)NSEC_PER_SEC);
            dispatch_source_set_timer(_idleTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, interval / 10);
            __weak GCDWebServerConnection *weakSelf = self;  // A strong capture would cycle through the source's handler and keep the connection alive forever
            dispatch_source_set_event_handler(_idleTimer, ^{
                [weakSelf _checkIdleTimeout];
            });
            dispatch_resume(_idleTimer);
        }

        [_server willStartConnection:self];

        if (![self open]) {
            // Don't close here: returning nil deallocates self immediately and -dealloc is
            // the sole owner of the descriptor. Closing twice would, once the number has
            // been recycled by a concurrent accept on the other address family, tear down
            // an unrelated live connection.
            return nil;
        }

        _opened = YES;

        [self _readRequestHeaders];
    }

    return self;
}

- (NSString *)localAddressString {
    return GCDWebServerStringFromSockAddr(_localAddressData.bytes, YES);
}

- (NSString *)remoteAddressString {
    return GCDWebServerStringFromSockAddr(_remoteAddressData.bytes, YES);
}

- (void)dealloc {
    if (_idleTimer) {
        dispatch_source_cancel(_idleTimer);
    }

    int result = close(_socket);

    if (result != 0) {
        GWS_LOG_ERROR(@"Failed closing socket %i for connection: %s (%i)", _socket, strerror(errno), errno);
    } else {
        GWS_LOG_DEBUG(@"Did close connection on socket %i", _socket);
    }

    if (_opened) {
        [self close];
    }

    [_server didEndConnection:self];

    if (_requestMessage) {
        CFRelease(_requestMessage);
    }

    if (_responseMessage) {
        CFRelease(_responseMessage);
    }
}

@end

@implementation GCDWebServerConnection (Read)

- (void)readData:(NSMutableData *)data withLength:(NSUInteger)length completionBlock:(ReadDataCompletionBlock)block {
    if (_idleTimer) {
        dispatch_async(_connectionQueue, ^{  // Enqueued ahead of dispatch_read's handler on the same serial queue, so the increment always runs first
            self->_pendingIOCount += 1;
        });
    }

    dispatch_read(_socket, length, _connectionQueue, ^(dispatch_data_t buffer, int error) {
        @autoreleasepool {
            if (self->_idleTimer) {
                self->_pendingIOCount -= 1;
            }

            if (error == 0) {
                size_t size = dispatch_data_get_size(buffer);

                if (size > 0) {
                    NSUInteger originalLength = data.length;
                    dispatch_data_apply(buffer, ^bool(dispatch_data_t region, size_t chunkOffset, const void *chunkBytes, size_t chunkSize) {
                        [data appendBytes:chunkBytes length:chunkSize];
                        return true;
                    });
                    [self didReadBytes:((char *)data.bytes + originalLength) length:(data.length - originalLength)];
                    block(YES);
                } else {
                    if (self->_totalBytesRead > 0) {
                        GWS_LOG_ERROR(@"No more data available on socket %i", self->_socket);
                    } else {
                        GWS_LOG_WARNING(@"No data received from socket %i", self->_socket);
                    }

                    block(NO);
                }
            } else {
                GWS_LOG_ERROR(@"Error while reading from socket %i: %s (%i)", self->_socket, strerror(error), error);
                block(NO);
            }
        }
    });
}

- (void)readHeaders:(NSMutableData *)headersData withCompletionBlock:(ReadHeadersCompletionBlock)block {
    GWS_DCHECK(_requestMessage);
    [self readData:headersData
             withLength:NSUIntegerMax
        completionBlock:^(BOOL success) {
            if (success) {
                NSRange range = [headersData rangeOfData:_CRLFCRLFData options:0 range:NSMakeRange(0, headersData.length)];

                if (range.location == NSNotFound) {
                    if (headersData.length > kHeadersMaxLength) {
                        GWS_LOG_ERROR(@"Request headers exceeded %i bytes on socket %i", (int)kHeadersMaxLength, self->_socket);
                        block(nil);
                    } else {
                        [self readHeaders:headersData withCompletionBlock:block];
                    }
                } else {
                    NSUInteger length = range.location + range.length;

                    if (CFHTTPMessageAppendBytes(self->_requestMessage, headersData.bytes, length)) {
                        if (CFHTTPMessageIsHeaderComplete(self->_requestMessage)) {
                            block([headersData subdataWithRange:NSMakeRange(length, headersData.length - length)]);
                        } else {
                            GWS_LOG_ERROR(@"Failed parsing request headers from socket %i", self->_socket);
                            block(nil);
                        }
                    } else {
                        GWS_LOG_ERROR(@"Failed appending request headers data from socket %i", self->_socket);
                        block(nil);
                    }
                }
            } else {
                block(nil);
            }
        }];
}

- (void)readBodyWithRemainingLength:(NSUInteger)length completionBlock:(ReadBodyCompletionBlock)block {
    GWS_DCHECK([_request hasBody] && ![_request usesChunkedTransferEncoding]);
    NSMutableData *const bodyData = [[NSMutableData alloc] initWithCapacity:kBodyReadCapacity];
    [self readData:bodyData
             withLength:length
        completionBlock:^(BOOL success) {
            if (success) {
                if (bodyData.length <= length) {
                    NSError *error = nil;

                    if ([self->_request performWriteData:bodyData error:&error]) {
                        NSUInteger remainingLength = length - bodyData.length;

                        if (remainingLength) {
                            [self readBodyWithRemainingLength:remainingLength completionBlock:block];
                        } else {
                            block(YES);
                        }
                    } else {
                        GWS_LOG_ERROR(@"Failed writing request body on socket %i: %@", self->_socket, error);
                        block(NO);
                    }
                } else {
                    GWS_LOG_ERROR(@"Unexpected extra content reading request body on socket %i", self->_socket);
                    block(NO);
                    GWS_DNOT_REACHED();
                }
            } else {
                block(NO);
            }
        }];
}

// Parse a chunk-size line: one or more hex digits and nothing else. strtol() also accepted
// leading whitespace, a sign and a "0x" prefix — so " 5", "+5" and "0x5" all read as 5, and
// "-0" was taken as the last-chunk marker — while the old fixed 32-byte line cap rejected a
// legal size padded with leading zeros. Bound the number of *significant* digits instead,
// which both keeps the value well inside NSUInteger and needs no stack buffer at all.
static inline NSUInteger _ScanHexNumber(const void *bytes, NSUInteger size) {
    const unsigned char *const characters = (const unsigned char *)bytes;
    NSUInteger index = 0;

    if (size == 0) {
        return NSNotFound;
    }

    while ((index < size) && (characters[index] == '0')) {  // Leading zeros are legal and carry no value
        index += 1;
    }

    if (index == size) {
        return 0;  // All zeros: the last-chunk marker
    }

    NSUInteger value = 0;
    NSUInteger digits = 0;

    for (; index < size; index++) {
        unsigned char character = characters[index];
        NSUInteger digit;

        if ((character >= '0') && (character <= '9')) {
            digit = (NSUInteger)(character - '0');
        } else if ((character >= 'a') && (character <= 'f')) {
            digit = (NSUInteger)(character - 'a' + 10);
        } else if ((character >= 'A') && (character <= 'F')) {
            digit = (NSUInteger)(character - 'A' + 10);
        } else {
            return NSNotFound;
        }

        digits += 1;

        if (digits > 15) {  // 60 bits: far beyond any legal chunk, and cannot overflow
            return NSNotFound;
        }

        value = (value << 4) | digit;
    }

    return value;
}

- (void)readNextBodyChunk:(NSMutableData *)chunkData completionBlock:(ReadBodyCompletionBlock)block {
    GWS_DCHECK([_request hasBody] && [_request usesChunkedTransferEncoding]);

    while (1) {
        NSRange range = [chunkData rangeOfData:_CRLFData options:0 range:NSMakeRange(0, chunkData.length)];

        if (range.location == NSNotFound) {
            break;
        }

        NSRange extensionRange = [chunkData rangeOfData:[NSData dataWithBytes:";" length:1] options:0 range:NSMakeRange(0, range.location)];  // Ignore chunk extensions
        NSUInteger length = _ScanHexNumber((char *)chunkData.bytes, extensionRange.location != NSNotFound ? extensionRange.location : range.location);

        if (length != NSNotFound) {
            if (length) {
                if (length > kGCDWebServerMaxInMemoryBodyLength) {
                    // A single chunk is buffered whole in memory before being written, so
                    // cap its declared size. Legitimate chunked uploads use many smaller
                    // chunks; this only rejects a pathologically large single chunk.
                    GWS_LOG_ERROR(@"Chunk size %lu exceeds the %i byte limit reading request body on socket %i", (unsigned long)length, (int)kGCDWebServerMaxInMemoryBodyLength, _socket);
                    block(NO);
                    return;
                }

                if (chunkData.length < range.location + range.length + length + 2) {
                    break;
                }

                const char *ptr = (char *)chunkData.bytes + range.location + range.length + length;

                if ((*ptr == '\r') && (*(ptr + 1) == '\n')) {
                    NSError *error = nil;

                    if ([_request performWriteData:[chunkData subdataWithRange:NSMakeRange(range.location + range.length, length)] error:&error]) {
                        [chunkData replaceBytesInRange:NSMakeRange(0, range.location + range.length + length + 2) withBytes:NULL length:0];
                    } else {
                        GWS_LOG_ERROR(@"Failed writing request body on socket %i: %@", _socket, error);
                        block(NO);
                        return;
                    }
                } else {
                    GWS_LOG_ERROR(@"Missing terminating CRLF sequence for chunk reading request body on socket %i", _socket);
                    block(NO);
                    return;
                }
            } else {
                NSRange trailerRange = [chunkData rangeOfData:_CRLFCRLFData options:0 range:NSMakeRange(range.location, chunkData.length - range.location)];  // Ignore trailers

                if (trailerRange.location != NSNotFound) {
                    block(YES);
                    return;
                }
                break;  // Last-chunk marker seen but the terminating CRLFCRLF has not arrived
                        // yet: break to read more data. Without this, the loop re-runs with
                        // identical state forever (100% CPU), never fetching the missing bytes.
            }
        } else {
            GWS_LOG_ERROR(@"Invalid chunk length reading request body on socket %i", _socket);
            block(NO);
            return;
        }
    }

    // Every loop break above falls through to here to read more bytes into the same
    // `chunkData`. The per-chunk cap (line above) only fires once a chunk-size line's
    // CRLF has been parsed; before that — a client that streams bytes never forming a
    // chunk-size-line CRLF, or that never terminates the last chunk's trailer — nothing
    // bounds the buffer, so it would grow until the app is jetsam/OOM-killed (the idle
    // timeout never fires while bytes keep arriving). Bound it at one max-size chunk
    // plus framing slack: a legitimate in-flight chunk needs at most that much buffered.
    if (chunkData.length > (NSUInteger)kGCDWebServerMaxInMemoryBodyLength + kHeadersMaxLength) {
        GWS_LOG_ERROR(@"Chunked transfer framing exceeds the buffer limit reading request body on socket %i", _socket);
        block(NO);
        return;
    }

    [self readData:chunkData
             withLength:NSUIntegerMax
        completionBlock:^(BOOL success) {
            if (success) {
                [self readNextBodyChunk:chunkData completionBlock:block];
            } else {
                block(NO);
            }
        }];
}

@end

@implementation GCDWebServerConnection (Write)

- (void)writeData:(NSData *)data withCompletionBlock:(WriteDataCompletionBlock)block {
    dispatch_data_t buffer = dispatch_data_create(data.bytes, data.length, _connectionQueue, ^{
        [data self];  // Keeps ARC from releasing data too early
    });

    if (_idleTimer) {
        dispatch_async(_connectionQueue, ^{  // Enqueued ahead of dispatch_write's handler on the same serial queue, so the increment always runs first
            self->_pendingIOCount += 1;
        });
    }

    dispatch_write(_socket, buffer, _connectionQueue, ^(dispatch_data_t remainingData, int error) {
        @autoreleasepool {
            if (self->_idleTimer) {
                self->_pendingIOCount -= 1;
            }

            if (error == 0) {
                GWS_DCHECK(remainingData == NULL);
                [self didWriteBytes:data.bytes length:data.length];
                block(YES);
            } else {
                GWS_LOG_ERROR(@"Error while writing to socket %i: %s (%i)", self->_socket, strerror(error), error);
                block(NO);
            }
        }
    });
#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
    dispatch_release(buffer);
#endif
}

- (void)writeHeadersWithCompletionBlock:(WriteHeadersCompletionBlock)block {
    GWS_DCHECK(_responseMessage);
    CFDataRef data = CFHTTPMessageCopySerializedMessage(_responseMessage);
    [self writeData:(__bridge NSData *)data withCompletionBlock:block];
    CFRelease(data);
}

- (void)writeBodyWithCompletionBlock:(WriteBodyCompletionBlock)block {
    GWS_DCHECK([_response hasBody]);
    [_response performReadDataWithCompletion:^(NSData *data, NSError *error) {
        if (data) {
            if (data.length) {
                if (self->_response.usesChunkedTransferEncoding) {
                    const char *hexString = [[NSString stringWithFormat:@"%lx", (unsigned long)data.length] UTF8String];
                    size_t hexLength = strlen(hexString);
                    NSData *chunk = [NSMutableData dataWithLength:(hexLength + 2 + data.length + 2)];

                    if (chunk == nil) {
                        GWS_LOG_ERROR(@"Failed allocating memory for response body chunk for socket %i: %@", self->_socket, error);
                        block(NO);
                        return;
                    }

                    char *ptr = (char *)[(NSMutableData *)chunk mutableBytes];
                    bcopy(hexString, ptr, hexLength);
                    ptr += hexLength;
                    *ptr++ = '\r';
                    *ptr++ = '\n';
                    bcopy(data.bytes, ptr, data.length);
                    ptr += data.length;
                    *ptr++ = '\r';
                    *ptr = '\n';
                    data = chunk;
                }

                [self writeData:data
                    withCompletionBlock:^(BOOL success) {
                        if (success) {
                            [self writeBodyWithCompletionBlock:block];
                        } else {
                            block(NO);
                        }
                    }];
            } else {
                if (self->_response.usesChunkedTransferEncoding) {
                    [self writeData:_lastChunkData
                        withCompletionBlock:^(BOOL success) {
                            block(success);
                        }];
                } else {
                    block(YES);
                }
            }
        } else {
            GWS_LOG_ERROR(@"Failed reading response body for socket %i: %@", self->_socket, error);
            block(NO);
        }
    }];
}

@end

@implementation GCDWebServerConnection (Subclassing)

- (BOOL)open {
#ifdef __GCDWEBSERVER_ENABLE_TESTING__

    if (_server.recordingEnabled) {
        _connectionIndex = atomic_fetch_add(&_connectionCounter, 1) + 1;

        _requestPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
        _requestFD = open([_requestPath fileSystemRepresentation], O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
        GWS_DCHECK(_requestFD > 0);

        _responsePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
        _responseFD = open([_responsePath fileSystemRepresentation], O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
        GWS_DCHECK(_responseFD > 0);
    }

#endif

    return YES;
}

- (void)didReadBytes:(const void *)bytes length:(NSUInteger)length {
    GWS_LOG_DEBUG(@"Connection received %lu bytes on socket %i", (unsigned long)length, _socket);
    _totalBytesRead += length;

#ifdef __GCDWEBSERVER_ENABLE_TESTING__

    if ((_requestFD > 0) && (write(_requestFD, bytes, length) != (ssize_t)length)) {
        GWS_LOG_ERROR(@"Failed recording request data: %s (%i)", strerror(errno), errno);
        close(_requestFD);
        _requestFD = 0;
    }

#endif
}

- (void)didWriteBytes:(const void *)bytes length:(NSUInteger)length {
    GWS_LOG_DEBUG(@"Connection sent %lu bytes on socket %i", (unsigned long)length, _socket);
    _totalBytesWritten += length;

#ifdef __GCDWEBSERVER_ENABLE_TESTING__

    if ((_responseFD > 0) && (write(_responseFD, bytes, length) != (ssize_t)length)) {
        GWS_LOG_ERROR(@"Failed recording response data: %s (%i)", strerror(errno), errno);
        close(_responseFD);
        _responseFD = 0;
    }

#endif
}

- (NSURL *)rewriteRequestURL:(NSURL *)url withMethod:(NSString *)method headers:(NSDictionary<NSString *, NSString *> *)headers {
    return url;
}

// Compare two credential strings without an early-out on the first differing
// byte, to avoid leaking how much of a credential/digest was correct via response
// timing. Length differences still leak length, which is not sensitive here.
static BOOL _ConstantTimeEqualStrings(NSString *a, NSString *b) {
    if ((a == nil) || (b == nil)) {
        return NO;
    }
    // Compare the full byte strings: -UTF8String with strlen stops at an embedded NUL, which
    // a client can put in a header, so "X" and "X\0Y" compared equal.
    NSData *const da = [a dataUsingEncoding:NSUTF8StringEncoding];
    NSData *const db = [b dataUsingEncoding:NSUTF8StringEncoding];

    if ((da == nil) || (db == nil)) {
        return NO;
    }
    const char *ca = da.bytes;
    const char *cb = db.bytes;
    size_t la = da.length;
    size_t lb = db.length;
    size_t n = (la > lb) ? la : lb;
    unsigned char diff = (unsigned char)(la ^ lb);
    for (size_t i = 0; i < n; i++) {
        unsigned char x = (i < la) ? (unsigned char)ca[i] : 0;
        unsigned char y = (i < lb) ? (unsigned char)cb[i] : 0;
        diff |= (unsigned char)(x ^ y);
    }
    return (diff == 0);
}

// Digest nonces are issued time-stamped and integrity-protected with a per-process
// secret, so the server can validate and expire them statelessly. A static,
// never-expiring nonce (the previous behaviour) lets an on-network eavesdropper replay
// a captured Authorization header for the entire process lifetime; expiry bounds that
// to a short window. Format: "<hexSeconds>.<MD5(hexSeconds ":" secret)>". The alphabet
// (hex + ".") is safe inside the quoted nonce of WWW-Authenticate / Authorization.
#define kDigestNonceLifetime 300.0  // seconds a nonce stays valid after issue

static NSString *_GenerateDigestNonce(NSString *secret) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    unsigned long long seconds = (unsigned long long)now;
    NSString *const stamp = [NSString stringWithFormat:@"%llX", seconds];
    return [NSString stringWithFormat:@"%@.%@", stamp, GCDWebServerComputeMD5Digest(@"%@:%@", stamp, secret)];
}

// Returns YES if `nonce` is one this process issued (its MAC verifies). On success,
// *expired reports whether it has aged past its lifetime — a genuine but stale nonce,
// answered with stale=TRUE so a compliant client retries transparently.
static BOOL _ValidateDigestNonce(NSString *nonce, NSString *secret, BOOL *expired) {
    *expired = NO;
    if (nonce.length == 0) {
        return NO;
    }

    NSRange dot = [nonce rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location == NSNotFound) {
        return NO;
    }

    NSString *const stamp = [nonce substringToIndex:dot.location];
    NSString *const mac = [nonce substringFromIndex:(dot.location + 1)];

    if (!_ConstantTimeEqualStrings(mac, GCDWebServerComputeMD5Digest(@"%@:%@", stamp, secret))) {
        return NO;  // Not minted by us (forged, or from a previous process run).
    }

    unsigned long long seconds = 0;
    if (![[NSScanner scannerWithString:stamp] scanHexLongLong:&seconds]) {
        return NO;
    }

    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - (CFAbsoluteTime)seconds;
    if ((elapsed < 0.0) || (elapsed > kDigestNonceLifetime)) {
        *expired = YES;
    }

    return YES;
}

// Reduce a Digest "uri" parameter to its decoded path so it can be compared to the
// request's actual path. Handles origin-form ("/a?b") and absolute-form
// ("http://h/a?b") request-targets, and strips any query/fragment.
static NSString *_DigestURIPath(NSString *uri) {
    if (uri == nil) {
        return nil;
    }

    NSRange cut = [uri rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
    NSString *target = (cut.location != NSNotFound) ? [uri substringToIndex:cut.location] : uri;

    NSRange scheme = [target rangeOfString:@"://"];
    if (scheme.location != NSNotFound) {
        NSString *const rest = [target substringFromIndex:(scheme.location + 3)];
        NSRange slash = [rest rangeOfString:@"/"];
        target = (slash.location != NSNotFound) ? [rest substringFromIndex:slash.location] : @"/";
    }

    return GCDWebServerUnescapeURLString(target);
}

// https://tools.ietf.org/html/rfc2617
- (GCDWebServerResponse *)preflightRequest:(GCDWebServerRequest *)request {
    GWS_LOG_DEBUG(@"Connection on socket %i preflighting request \"%@ %@\" with %lu bytes body", _socket, _virtualHEAD ? @"HEAD" : _request.method, _request.path, (unsigned long)_totalBytesRead);
    GCDWebServerResponse *response = nil;

    // A CORS preflight (an OPTIONS request carrying "Access-Control-Request-Method")
    // must not require credentials: browsers never send "Authorization" on preflight
    // per the CORS spec, so enforcing auth here rejects it with 401 and breaks every
    // subsequent cross-origin request. Let it through to the handler so the app can
    // answer the preflight. See swisspol/GCDWebServer#479.
    //
    // "Origin" is required as well as "Access-Control-Request-Method": a real preflight
    // always carries both, so demanding both keeps the exemption to the case it exists
    // for. Without it, any client could reach an OPTIONS handler unauthenticated just by
    // setting one header. Note the request is still dispatched to the application's
    // OPTIONS handler with no credentials, so such a handler must only describe
    // capabilities — never read, write, or enumerate anything.
    if ([request.method isEqualToString:@"OPTIONS"] && request.headers[@"Origin"] && request.headers[@"Access-Control-Request-Method"]) {
        return nil;
    }

    if (_authenticationBasicAccounts) {
        __block BOOL authenticated = NO;
        NSString *const authorizationHeader = request.headers[@"Authorization"];

        if ([authorizationHeader hasPrefix:@"Basic "]) {
            NSString *const basicAccount = [authorizationHeader substringFromIndex:6];
            [_authenticationBasicAccounts enumerateKeysAndObjectsUsingBlock:^(NSString *username, NSString *digest, BOOL *stop) {
                if (_ConstantTimeEqualStrings(basicAccount, digest)) {  // Do not *stop early: keep the match position from leaking via timing.
                    authenticated = YES;
                }
            }];
        }

        if (!authenticated) {
            response = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_Unauthorized];
            [response setValue:[NSString stringWithFormat:@"Basic realm=\"%@\"", _authenticationRealm] forAdditionalHeader:@"WWW-Authenticate"];
        }
    } else if (_authenticationDigestAccounts) {
        BOOL authenticated = NO;
        BOOL isStaled = NO;
        NSString *const authorizationHeader = request.headers[@"Authorization"];

        if ([authorizationHeader hasPrefix:@"Digest "]) {
            NSString *const realm = GCDWebServerExtractHeaderValueParameter(authorizationHeader, @"realm");

            if (realm && [_authenticationRealm isEqualToString:realm]) {
                NSString *const nonce = GCDWebServerExtractHeaderValueParameter(authorizationHeader, @"nonce");
                BOOL nonceExpired = NO;

                if (_ValidateDigestNonce(nonce, _digestAuthenticationSecret, &nonceExpired)) {
                    if (nonceExpired) {
                        isStaled = YES;  // Genuine nonce, just aged out: stale=TRUE lets the client retry silently.
                    } else {
                        NSString *const username = GCDWebServerExtractHeaderValueParameter(authorizationHeader, @"username");
                        NSString *const uri = GCDWebServerExtractHeaderValueParameter(authorizationHeader, @"uri");
                        NSString *const actualResponse = GCDWebServerExtractHeaderValueParameter(authorizationHeader, @"response");
                        NSString *const ha1 = _authenticationDigestAccounts[username];
                        // Bind the credential to the resource actually requested: HA2 is
                        // computed over the client-supplied "uri", so without requiring it to
                        // match the real request path a captured Authorization header would
                        // authenticate any other same-method resource. An unknown username MUST
                        // also be rejected here — otherwise ha1 is nil and formats into the
                        // digest as the literal "(null)", whose every input is attacker-known
                        // (nonce and realm are disclosed in the 401; method and uri are
                        // attacker-chosen), forging a valid response with no password at all.
                        if ((ha1 != nil) && [_DigestURIPath(uri) isEqualToString:request.path]) {
                            NSString *const ha2 = GCDWebServerComputeMD5Digest(@"%@:%@", request.method, uri);  // Use "uri" not "request.path": the query string is part of the client's digest
                            NSString *const expectedResponse = GCDWebServerComputeMD5Digest(@"%@:%@:%@", ha1, nonce, ha2);

                            if (_ConstantTimeEqualStrings(actualResponse, expectedResponse)) {
                                authenticated = YES;
                            }
                        }
                    }
                } else if (nonce.length) {
                    isStaled = YES;  // A nonce we never issued (forged, or from a prior process run): re-challenge as stale so a well-behaved client retries with the fresh one rather than re-prompting.
                }
            }
        }

        if (!authenticated) {
            response = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_Unauthorized];
            [response setValue:[NSString stringWithFormat:@"Digest realm=\"%@\", nonce=\"%@\"%@", _authenticationRealm, _GenerateDigestNonce(_digestAuthenticationSecret), isStaled ? @", stale=TRUE" : @""] forAdditionalHeader:@"WWW-Authenticate"];  // TODO: Support Quality of Protection ("qop")
        }
    }

    return response;
}

- (void)processRequest:(GCDWebServerRequest *)request completion:(GCDWebServerCompletionBlock)completion {
    GWS_LOG_DEBUG(@"Connection on socket %i processing request \"%@ %@\" with %lu bytes body", _socket, _virtualHEAD ? @"HEAD" : _request.method, _request.path, (unsigned long)_totalBytesRead);

    if (_handler.asyncProcessBlock) {
        _handler.asyncProcessBlock(request, [completion copy]);
    } else {
        completion(nil);
    }
}

// http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.25
// http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.26
static inline BOOL _CompareResources(NSString *responseETag, NSString *requestETag, NSDate *responseLastModified, NSDate *requestLastModified) {
    if (requestLastModified && responseLastModified) {
        if ([responseLastModified compare:requestLastModified] != NSOrderedDescending) {
            return YES;
        }
    }

    if (requestETag && responseETag) {  // Per the specs "If-None-Match" must be checked after "If-Modified-Since"
        if ([requestETag isEqualToString:@"*"]) {
            return YES;
        }

        if ([responseETag isEqualToString:requestETag]) {
            return YES;
        }
    }

    return NO;
}

- (GCDWebServerResponse *)overrideResponse:(GCDWebServerResponse *)response forRequest:(GCDWebServerRequest *)request {
    if ((response.statusCode >= 200) && (response.statusCode < 300) &&
        _CompareResources(response.eTag, request.ifNoneMatch, response.lastModifiedDate, request.ifModifiedSince)) {
        NSInteger code = kGCDWebServerHTTPStatusCode_PreconditionFailed;
        if ([request.method isEqualToString:@"HEAD"] || [request.method isEqualToString:@"GET"]) {
          code = kGCDWebServerHTTPStatusCode_NotModified;
        }
        GCDWebServerResponse *newResponse = [GCDWebServerResponse responseWithStatusCode:code];
        newResponse.cacheControlMaxAge = response.cacheControlMaxAge;
        newResponse.lastModifiedDate = response.lastModifiedDate;
        newResponse.eTag = response.eTag;
        GWS_DCHECK(newResponse);
        return newResponse;
    }

    return response;
}

- (void)abortRequest:(GCDWebServerRequest *)request withStatusCode:(NSInteger)statusCode {
    GWS_DCHECK(_responseMessage == NULL);
    GWS_DCHECK((statusCode >= 400) && (statusCode < 600));
    _requestReceived = YES;  // Reading is over either way; only the error response remains
    [self _initializeResponseHeadersWithStatusCode:statusCode];
    [self writeHeadersWithCompletionBlock:^(BOOL success){
        // Nothing more to do
    }];
    GWS_LOG_DEBUG(@"Connection aborted with status code %i on socket %i", (int)statusCode, _socket);
}

- (void)close {
#ifdef __GCDWEBSERVER_ENABLE_TESTING__

    if (_requestPath) {
        BOOL success = NO;
        NSError *error = nil;

        if (_requestFD > 0) {
            close(_requestFD);
            NSString *const name = [NSString stringWithFormat:@"%03lu-%@.request", (unsigned long)_connectionIndex, _virtualHEAD ? @"HEAD" : _request.method];
            success = [[NSFileManager defaultManager] moveItemAtPath:_requestPath toPath:[[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:name] error:&error];
        }

        if (!success) {
            GWS_LOG_ERROR(@"Failed saving recorded request: %@", error);
            GWS_DNOT_REACHED();
        }

        unlink([_requestPath fileSystemRepresentation]);
    }

    if (_responsePath) {
        BOOL success = NO;
        NSError *error = nil;

        if (_responseFD > 0) {
            close(_responseFD);
            NSString *const name = [NSString stringWithFormat:@"%03lu-%i.response", (unsigned long)_connectionIndex, (int)_statusCode];
            success = [[NSFileManager defaultManager] moveItemAtPath:_responsePath toPath:[[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:name] error:&error];
        }

        if (!success) {
            GWS_LOG_ERROR(@"Failed saving recorded response: %@", error);
            GWS_DNOT_REACHED();
        }

        unlink([_responsePath fileSystemRepresentation]);
    }

#endif /* ifdef __GCDWEBSERVER_ENABLE_TESTING__ */

    if (_request) {
        GWS_LOG_VERBOSE(@"[%@] %@ %i \"%@ %@\" (%lu | %lu)", self.localAddressString, self.remoteAddressString, (int)_statusCode, _virtualHEAD ? @"HEAD" : _request.method, _request.path, (unsigned long)_totalBytesRead, (unsigned long)_totalBytesWritten);
    } else {
        GWS_LOG_VERBOSE(@"[%@] %@ %i \"(invalid request)\" (%lu | %lu)", self.localAddressString, self.remoteAddressString, (int)_statusCode, (unsigned long)_totalBytesRead, (unsigned long)_totalBytesWritten);
    }
}

@end
