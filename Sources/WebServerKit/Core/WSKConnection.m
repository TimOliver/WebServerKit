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
#error WSKWebServer requires ARC
#endif

#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <TargetConditionals.h>
#ifdef __WEBSERVERKIT_ENABLE_TESTING__
#import <stdatomic.h>
#endif

#import "WSKPrivate.h"

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
#ifdef __WEBSERVERKIT_ENABLE_TESTING__
static _Atomic(int32_t) _connectionCounter = 0;
#endif

NS_ASSUME_NONNULL_BEGIN

@interface WSKConnection (Read)
- (void)readData:(NSMutableData *)data withLength:(NSUInteger)length completionBlock:(ReadDataCompletionBlock)block;
- (void)readHeaders:(NSMutableData *)headersData withCompletionBlock:(ReadHeadersCompletionBlock)block;
- (void)readBodyWithRemainingLength:(NSUInteger)length completionBlock:(ReadBodyCompletionBlock)block;
- (void)readNextBodyChunk:(NSMutableData *)chunkData completionBlock:(ReadBodyCompletionBlock)block;
@end

@interface WSKConnection (Write)
- (void)writeData:(NSData *)data withCompletionBlock:(WriteDataCompletionBlock)block;
- (void)writeHeadersWithCompletionBlock:(WriteHeadersCompletionBlock)block;
- (void)writeBodyWithCompletionBlock:(WriteBodyCompletionBlock)block;
@end

NS_ASSUME_NONNULL_END

@implementation WSKConnection {
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
    NSSet<NSString *> *_allowedHostNames;
    BOOL _shouldAutomaticallyMapHEADToGET;

    CFHTTPMessageRef _requestMessage;
    WSKRequest *_request;
    WSKHandler *_handler;
    CFHTTPMessageRef _responseMessage;
    WSKResponse *_response;
    NSInteger _statusCode;

    BOOL _opened;

    dispatch_source_t _idleTimer;  // Nil when idle timeouts are disabled
    NSUInteger _pendingIOCount;    // Accessed on _connectionQueue only
    NSUInteger _idleCheckedBytes;  // Accessed on _connectionQueue only
    BOOL _idleCheckWasBusy;        // Accessed on _connectionQueue only
    NSUInteger _headerPhaseTicks;  // Idle ticks elapsed before a request was matched; on _connectionQueue only
    BOOL _requestReceived;         // Set once the body is fully read and the handler runs; on _connectionQueue only
    BOOL _clientIsHTTP10;          // The client spoke HTTP/1.0 (or older): no chunked framing, no interim 1xx
    BOOL _earlyChecksRun;          // Host allow-list and preflight are decided once, as early as the headers allow
    NSInteger _headerFailureStatus;  // Why the header block was rejected; 500 only if nothing more specific applies
    NSTimeInterval _idleTimeout;   // Seconds between idle-timer ticks; 0 when idle timeouts are disabled
    WSKMemoryReservation *_chunkReservation;  // This connection's chunked framing buffer

#ifdef __WEBSERVERKIT_ENABLE_TESTING__
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
        WSK_DCHECK(_CRLFData);
    }

    if (_CRLFCRLFData == nil) {
        _CRLFCRLFData = [[NSData alloc] initWithBytes:"\r\n\r\n" length:4];
        WSK_DCHECK(_CRLFCRLFData);
    }

    if (_continueData == nil) {
        CFHTTPMessageRef message = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 100, NULL, kCFHTTPVersion1_1);
        _continueData = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(message));
        CFRelease(message);
        WSK_DCHECK(_continueData);
    }

    if (_lastChunkData == nil) {
        _lastChunkData = [[NSData alloc] initWithBytes:"0\r\n\r\n" length:5];
    }

    if (_digestAuthenticationSecret == nil) {
        CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
        _digestAuthenticationSecret = WSKComputeMD5Digest(@"%@", CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuid)));
        CFRelease(uuid);
    }
}

- (BOOL)isUsingIPv6 {
    const struct sockaddr *localSockAddr = _localAddressData.bytes;

    return (localSockAddr->sa_family == AF_INET6);
}

// CFHTTPMessageCreateResponse's own reason-phrase table stops at HTTP/1.1 as it stood in 1999,
// so every status registered since gets its class default instead of its name. Three of them
// this library emits in ordinary operation: 421 Misdirected Request — the Host allow-list
// refusal, i.e. the DNS-rebinding defence — went out as "421 Bad Request", as did 424 Failed
// Dependency (PROPPATCH's atomicity refusal) and 431 Request Header Fields Too Large (the
// header cap). Measured across all 56 codes in WSKHTTPStatusCodes.h: fourteen were wrong.
//
// ONLY those fourteen are supplied. Everything CF already gets right is left to CF, so every
// status the recorded-trace corpus contains (200, 201, 207, 404) still serializes byte for
// byte — the corpus fails on any difference, and rewriting phrases it records would have made
// this a corpus change rather than a fix.
static CFStringRef _ReasonPhraseForStatusCode(NSInteger statusCode) {
    switch (statusCode) {
        case 102:
            return CFSTR("Processing");
        case 208:
            return CFSTR("Already Reported");
        case 421:
            return CFSTR("Misdirected Request");
        case 422:
            return CFSTR("Unprocessable Content");
        case 423:
            return CFSTR("Locked");
        case 424:
            return CFSTR("Failed Dependency");
        case 426:
            return CFSTR("Upgrade Required");
        case 428:
            return CFSTR("Precondition Required");
        case 429:
            return CFSTR("Too Many Requests");
        case 431:
            return CFSTR("Request Header Fields Too Large");
        case 507:
            return CFSTR("Insufficient Storage");
        case 508:
            return CFSTR("Loop Detected");
        case 510:
            return CFSTR("Not Extended");
        case 511:
            return CFSTR("Network Authentication Required");
        default:
            return NULL;  // CF's phrase is correct for this one.
    }
}

- (void)_initializeResponseHeadersWithStatusCode:(NSInteger)statusCode {
    _statusCode = statusCode;
    _responseMessage = CFHTTPMessageCreateResponse(kCFAllocatorDefault, statusCode, _ReasonPhraseForStatusCode(statusCode), kCFHTTPVersion1_1);
    CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Connection"), CFSTR("Close"));
    CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Server"), (__bridge CFStringRef)_serverName);
    CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Date"), (__bridge CFStringRef)WSKFormatRFC822([NSDate date]));
}

// A textual IP address needs no allow-list entry. The interface set can change under us, so
// enumerating our own addresses would be both racy and incomplete — and the whole check
// rests on the fact that a browser cannot be made to put a literal in "Host" while
// scripting from a domain, so a literal can never be a rebound name.
static BOOL _IsIPAddressLiteral(NSString *host) {
    if (host.length == 0) {
        return NO;
    }

    const char *const value = host.UTF8String;
    struct in_addr address4;
    struct in6_addr address6;
    return (inet_pton(AF_INET, value, &address4) == 1) || (inet_pton(AF_INET6, value, &address6) == 1);
}


// Refuse a request whose "Host" names something this server does not answer to. This is the
// only defence against DNS rebinding: once a page on evil.example repoints its DNS here, the
// browser treats it as same-origin, so CORS, Origin comparison and CSRF tokens are all
// satisfied — but the browser still sends the name the page was loaded from. See
// WSKOption_AllowedHostNames.
// "name.local." and "name.local" are the same host: the trailing dot is the DNS root label,
// which a user typing a fully-qualified name, a canonicalizing client library, or curl will
// all send. Refusing it answered 421 for the server's own mDNS name and read as "the server
// just doesn't work". Only one dot is stripped; "name.local.." remains malformed.
static NSString *_WithoutRootLabel(NSString *host) {
    return [host hasSuffix:@"."] ? [host substringToIndex:(host.length - 1)] : host;
}

- (WSKResponse *)_rejectIfHostNotAllowed {
    NSString *const hostHeader = _request.headers[@"Host"];

    // No "Host" at all: HTTP/1.0 and plenty of native clients omit it, and rebinding needs
    // a browser, which never does. There is nothing here that could have been rebound.
    if (hostHeader.length == 0) {
        return nil;
    }

    NSString *const normalized = [hostHeader lowercaseString];
    NSString *name = normalized;
    NSString *portText = nil;

    if ([name hasPrefix:@"["]) {  // Bracketed IPv6 literal, optionally followed by a port
        NSRange closing = [name rangeOfString:@"]"];

        if (closing.location == NSNotFound) {
            return [self _misdirectedResponseForHost:hostHeader];
        }

        NSString *const remainder = [name substringFromIndex:(closing.location + 1)];

        if (remainder.length && ![remainder hasPrefix:@":"]) {
            return [self _misdirectedResponseForHost:hostHeader];
        }

        portText = remainder.length ? [remainder substringFromIndex:1] : nil;
        name = [name substringWithRange:NSMakeRange(1, closing.location - 1)];
    } else {
        NSRange colon = [name rangeOfString:@":" options:NSBackwardsSearch];

        if (colon.location != NSNotFound) {
            portText = [name substringFromIndex:(colon.location + 1)];
            name = [name substringToIndex:colon.location];
        }
    }

    // Strip the DNS root label from the *name*, not from the end of the whole value, so
    // "name.local.:8080" normalizes as well as "name.local.".
    BOOL const isBracketed = [normalized hasPrefix:@"["];
    name = _WithoutRootLabel(name);

    // An allow-list entry may pin a port ("files.example:8080"), and such an entry is
    // deliberately honoured verbatim — including its port — so rebuild the canonical
    // authority and try that before validating the port against this connection.
    NSString *const canonical = portText.length
                                    ? [NSString stringWithFormat:(isBracketed ? @"[%@]:%@" : @"%@:%@"), name, portText]
                                    : (isBracketed ? [NSString stringWithFormat:@"[%@]", name] : name);

    if ([_allowedHostNames containsObject:canonical]) {
        return nil;
    }

    // A stated port must be syntactically a port, but it is deliberately NOT required to equal the
    // one this connection arrived on. It used to be, which contradicted this option's own
    // documentation ("may include a port ...; without one, any port matches") and refused every
    // deployment behind a port-translating hop: the client states the port it dialled, the hop
    // forwards to a different one, and the server saw a mismatch. That is precisely the priority
    // deployment — Tailscale Serve terminating TLS on 443 and forwarding to an ephemeral local
    // port — where it presented as a total outage, 421 for every request.
    //
    // Dropping it costs no security, which is the whole reason it can go. The DNS-rebinding
    // defence turns entirely on the NAME: an attacker who repoints DNS still cannot make a browser
    // put a raw IP literal or a name we accept into Host, and he controls the port he targets
    // either way, so matching it proves nothing about who is asking. An entry that DOES pin a port
    // is still honoured verbatim, by the canonical comparison above, so a deployment that wants the
    // stricter behaviour can still ask for it explicitly.
    if (portText.length) {
        BOOL digitsOnly = (portText.length <= 5);

        for (NSUInteger i = 0; digitsOnly && (i < portText.length); i++) {
            unichar character = [portText characterAtIndex:i];
            digitsOnly = ((character >= '0') && (character <= '9'));
        }

        if (!digitsOnly) {
            return [self _misdirectedResponseForHost:hostHeader];
        }
    }

    if (_IsIPAddressLiteral(name) || [_allowedHostNames containsObject:name]) {
        return nil;
    }

    return [self _misdirectedResponseForHost:hostHeader];
}

- (WSKResponse *)_misdirectedResponseForHost:(NSString *)hostHeader {
    NSString *const accepted = [[[_allowedHostNames allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "];
    // Deliberately loud. This is the check most likely to surprise a deployment nobody
    // anticipated, and a quiet refusal would present as "the server just doesn't work".
    WSK_LOG_ERROR(@"Refusing \"%@ %@\" from %@: host \"%@\" is not one this server answers to (accepted: %@, plus any IP address literal). Set WSKOption_AllowedHostNames if this name is legitimate.",
                  _request.method, _request.path, self.remoteAddressString, hostHeader, accepted);
    return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_MisdirectedRequest
                                                      message:@"Host \"%@\" is not served here. Accepted: %@, or any IP address. Set WSKOption_AllowedHostNames to add one.", hostHeader, accepted];
}

// The Host allow-list and authentication both decide on headers alone, so they can be
// settled before a body is read — and they must be, or a client we are going to refuse
// still gets to make the server spool an unbounded body into NSTemporaryDirectory()
// first. Runs at most once per request: the body path consults it before reading, and
// -_startProcessingRequest consults it for the body-less path. A rejection never reaches
// -_startProcessingRequest, so returning nil for an already-run check is unambiguous.
- (WSKResponse *)_responseForRejectedRequest {
    if (_earlyChecksRun) {
        return nil;
    }

    _earlyChecksRun = YES;

    // Ahead of -preflightRequest: deliberately. That method is a documented subclassing
    // point, and a subclass that does not call super must not be able to switch this off.
    WSKResponse *const misdirectedResponse = [self _rejectIfHostNotAllowed];

    if (misdirectedResponse) {
        return misdirectedResponse;
    }

    return [self preflightRequest:_request];
}

- (void)_startProcessingRequest {
    WSK_DCHECK(_responseMessage == NULL);
    _requestReceived = YES;  // Nothing further is read from the socket for this request

    WSKResponse *const rejectionResponse = [self _responseForRejectedRequest];

    if (rejectionResponse) {
        [self _finishProcessingRequest:rejectionResponse];
    } else {
        // Guard against an async handler that invokes its completion block more than
        // once: a second call would overwrite _responseMessage (leaking the first
        // CFHTTPMessageRef) and race a second write chain on the same socket.
        __block BOOL processed = NO;
        [self processRequest:_request
                  completion:^(WSKResponse *processResponse) {
                      if (processed) {
                          WSK_LOG_ERROR(@"Ignoring extra completion block invocation for request on socket %i", self->_socket);
                          return;
                      }
                      processed = YES;
                      [self _finishProcessingRequest:processResponse];
                  }];
    }
}

// Chunked transfer coding was introduced in HTTP/1.1. Sending it to a 1.0 client makes it
// read the chunk-size lines as part of the entity body — a silently corrupted download
// rather than an error. Falling back to identity framing is safe here precisely because
// every response already carries "Connection: Close" and the connection serves one request:
// end-of-body by connection close is well defined, which is exactly how HTTP/1.0 did it.
- (void)_readRequestBodyWithInitialData:(NSData *)initialData {
    if (_request.usesChunkedTransferEncoding) {
        [self _readChunkedBodyWithInitialData:initialData];
    } else {
        [self _readBodyWithLength:_request.contentLength initialData:initialData];
    }
}

- (BOOL)_shouldChunkResponse {
    return _response.usesChunkedTransferEncoding && !_clientIsHTTP10;
}

// http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html
- (void)_finishProcessingRequest:(WSKResponse *)response {
    WSK_DCHECK(_responseMessage == NULL);
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
            WSK_LOG_ERROR(@"Failed opening response body for socket %i: %@", _socket, error);
        } else {
            _response = response;
        }
    }

    if (_response) {
        [self _initializeResponseHeadersWithStatusCode:_response.statusCode];

        if (_response.lastModifiedDate) {
            CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Last-Modified"), (__bridge CFStringRef)WSKFormatRFC822((NSDate *)_response.lastModifiedDate));
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
            CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Content-Type"), (__bridge CFStringRef)WSKNormalizeHeaderValue(_response.contentType));
        }

        if (_response.contentLength != NSUIntegerMax) {
            CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Content-Length"), (__bridge CFStringRef)[NSString stringWithFormat:@"%lu", (unsigned long)_response.contentLength]);
        }

        if ([self _shouldChunkResponse]) {
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
        [self abortRequest:_request withStatusCode:kWSKHTTPStatusCode_InternalServerError];
    }
}

- (void)_readBodyWithLength:(NSUInteger)length initialData:(NSData *)initialData {
    NSError *error = nil;

    if (![_request performOpen:&error]) {
        WSK_LOG_ERROR(@"Failed opening request body for socket %i: %@", _socket, error);
        [self abortRequest:_request withStatusCode:kWSKHTTPStatusCode_InternalServerError];
        return;
    }

    if (initialData.length) {
        if (![_request performWriteData:initialData error:&error]) {
            WSK_LOG_ERROR(@"Failed writing request body on socket %i: %@", _socket, error);

            if (![_request performClose:&error]) {
                WSK_LOG_ERROR(@"Failed closing request body for socket %i: %@", _socket, error);
            }

            [self abortRequest:_request withStatusCode:kWSKHTTPStatusCode_InternalServerError];
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
                                  [self abortRequest:self->_request withStatusCode:kWSKHTTPStatusCode_InternalServerError];
                                  return;
                              }

                              if ([self->_request performClose:&localError]) {
                                  [self _startProcessingRequest];
                              } else {
                                  WSK_LOG_ERROR(@"Failed closing request body for socket %i: %@", self->_socket, localError);
                                  [self abortRequest:self->_request withStatusCode:kWSKHTTPStatusCode_InternalServerError];
                              }
                          }];
    } else {
        if ([_request performClose:&error]) {
            [self _startProcessingRequest];
        } else {
            WSK_LOG_ERROR(@"Failed closing request body for socket %i: %@", _socket, error);
            [self abortRequest:_request withStatusCode:kWSKHTTPStatusCode_InternalServerError];
        }
    }
}

- (void)_readChunkedBodyWithInitialData:(NSData *)initialData {
    NSError *error = nil;

    if (![_request performOpen:&error]) {
        WSK_LOG_ERROR(@"Failed opening request body for socket %i: %@", _socket, error);
        [self abortRequest:_request withStatusCode:kWSKHTTPStatusCode_InternalServerError];
        return;
    }

    _chunkReservation = [[WSKMemoryReservation alloc] init];
    NSMutableData *const chunkData = [[NSMutableData alloc] initWithData:initialData];
    [self readNextBodyChunk:chunkData
            completionBlock:^(BOOL success) {
                NSError *localError = nil;

                if (!success) {
                    // The body read failed: the client disconnected mid-body, the chunk
                    // framing was malformed, or a size cap rejected it. Don't hand the
                    // handler a partial body as if it were complete.
                    [self->_request performClose:NULL];
                    [self abortRequest:self->_request withStatusCode:kWSKHTTPStatusCode_InternalServerError];
                    return;
                }

                if ([self->_request performClose:&localError]) {
                    [self _startProcessingRequest];
                } else {
                    WSK_LOG_ERROR(@"Failed closing request body for socket %i: %@", self->_socket, localError);
                    [self abortRequest:self->_request withStatusCode:kWSKHTTPStatusCode_InternalServerError];
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
            WSK_LOG_WARNING(@"Closing connection on socket %i: request headers not fully received within the header-phase deadline", _socket);
            dispatch_source_cancel(_idleTimer);
            shutdown(_socket, SHUT_RDWR);
            return;
        }
    }

    // While the request body is still arriving, require real progress rather than merely
    // *some* progress. The zero-progress rule below is defeated by a client dribbling a
    // single byte per tick — it costs the attacker nothing and pins a connection slot
    // indefinitely, and kWSKMaxConnections of them deny service to the whole
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
        WSK_LOG_WARNING(@"Closing connection on socket %i: too few bytes transferred while waiting on socket I/O across the idle timeout", _socket);
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
                // An HTTP/1.0 client cannot parse a chunked body or an interim 1xx response,
                // so remember which dialect it speaks before framing anything back at it.
                NSString *const requestVersion = CFBridgingRelease(CFHTTPMessageCopyVersion(self->_requestMessage));
                self->_clientIsHTTP10 = requestVersion && ![requestVersion isEqualToString:(__bridge NSString *)kCFHTTPVersion1_1];

                NSString *requestMethod = CFBridgingRelease(CFHTTPMessageCopyRequestMethod(self->_requestMessage));  // Method verbs are case-sensitive and uppercase

                if (self->_shouldAutomaticallyMapHEADToGET && [requestMethod isEqualToString:@"HEAD"]) {
                    requestMethod = @"GET";
                    self->_virtualHEAD = YES;
                }

                NSDictionary *const requestHeaders = CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(self->_requestMessage));  // Header names are case-insensitive but CFHTTPMessageCopyAllHeaderFields() will standardize the common ones
                NSURL *requestURL = CFBridgingRelease(CFHTTPMessageCopyRequestURL(self->_requestMessage));

                if (requestURL) {
                    requestURL = [self rewriteRequestURL:requestURL withMethod:requestMethod headers:requestHeaders];
                    WSK_DCHECK(requestURL);
                }

                NSString *urlPath = requestURL ? CFBridgingRelease(CFURLCopyPath((CFURLRef)requestURL)) : nil;  // Don't use -[NSURL path] which strips the ending slash

                if (urlPath == nil) {
                    urlPath = @"/";  // CFURLCopyPath() returns NULL for a relative URL with path "//" contrary to -[NSURL path] which returns "/"
                }

                NSString *const requestPath = urlPath ? WSKUnescapeURLString(urlPath) : nil;
                NSString *const queryString = requestURL ? CFBridgingRelease(CFURLCopyQueryString((CFURLRef)requestURL, NULL)) : nil;  // Don't use -[NSURL query] to make sure query is not unescaped;
                NSDictionary *const requestQuery = queryString ? WSKParseURLEncodedForm(queryString) : @{};

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
                        // The method was rewritten to GET above so a GET handler would match,
                        // which leaves the handler unable to see that nothing will ever read
                        // the body it is about to produce. Tell it.
                        self->_request.virtualHEAD = self->_virtualHEAD;

                        if ([self->_request hasBody]) {
                            // Decide the header-only refusals before a single body byte is
                            // accepted. Previously a request with no credentials, a
                            // disallowed Host, or no same-origin standing still streamed its
                            // whole body to the device's temp directory and was only then
                            // answered 401/421/403 — 288 MB written before the 401 in
                            // testing. Expect: 100-continue made it worse still, explicitly
                            // inviting a body from a client we were about to refuse.
                            WSKResponse *const rejectionResponse = [self _responseForRejectedRequest];

                            if (rejectionResponse) {
                                self->_requestReceived = YES;  // Nothing further is read from this socket
                                [self _finishProcessingRequest:rejectionResponse];
                                return;
                            }

                            // A content coding we cannot undo has to be refused here, before a
                            // byte of it is accepted. Preparing the writer is what decides that:
                            // an unknown coding used to leave the raw sink in place, so the
                            // still-encoded octets were stored as the entity and answered with a
                            // success status. Same rule, and same reason, as an unsupported
                            // Transfer-Encoding.
                            if (![self->_request prepareForWriting]) {
                                self->_requestReceived = YES;  // Nothing further is read from this socket
                                [self _finishProcessingRequest:[WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_UnsupportedMediaType message:@"Unsupported 'Content-Encoding' header: %@", requestHeaders[@"Content-Encoding"]]];
                                return;
                            }

                            if (self->_request.usesChunkedTransferEncoding || (extraData.length <= self->_request.contentLength)) {
                                NSString *const expectHeader = requestHeaders[@"Expect"];

                                if (expectHeader && !self->_clientIsHTTP10) {
                                    if ([expectHeader caseInsensitiveCompare:@"100-continue"] == NSOrderedSame) {  // TODO: Actually validate request before continuing
                                        [self writeData:_continueData
                                            withCompletionBlock:^(BOOL success) {
                                                if (success) {
                                                    [self _readRequestBodyWithInitialData:extraData];
                                                } else {
                                                    // Without this the request is left neither answered nor
                                                    // aborted, and the connection just unwinds silently.
                                                    [self abortRequest:self->_request withStatusCode:kWSKHTTPStatusCode_InternalServerError];
                                                }
                                            }];
                                    } else {
                                        WSK_LOG_ERROR(@"Unsupported 'Expect' / 'Content-Length' header combination on socket %i", self->_socket);
                                        [self abortRequest:self->_request withStatusCode:kWSKHTTPStatusCode_ExpectationFailed];
                                    }
                                } else {
                                    // An HTTP/1.0 client has no concept of an interim response: it would
                                    // read "100 Continue" as the final one and then mis-parse the real
                                    // response as the body. It is not waiting for one either, so ignore
                                    // any Expect it sent and just read the body.
                                    [self _readRequestBodyWithInitialData:extraData];
                                }
                            } else {
                                WSK_LOG_ERROR(@"Unexpected 'Content-Length' header value on socket %i", self->_socket);
                                [self abortRequest:self->_request withStatusCode:kWSKHTTPStatusCode_BadRequest];
                            }
                        } else {
                            [self _startProcessingRequest];
                        }
                    } else {
                        self->_request = [[WSKRequest alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:requestPath query:requestQuery];

                        if (self->_request) {
                            // The matched path populates these three; this branch populated
                            // none of them, and the request still reaches
                            // -abortRequest:withStatusCode:, which is a subclassing point a
                            // host app reaches through WSKOption_ConnectionClass. Reading
                            // -remoteAddressString on it dereferenced a NULL sockaddr and took
                            // the process down — WSKStringFromSockAddr evaluates addr->sa_len
                            // before calling getnameinfo, so there is nothing to fail closed on
                            // — from a single unauthenticated request to any path no handler
                            // claims. virtualHEAD belongs here for the related reason: the
                            // method was rewritten to GET before matching, so without it a
                            // subclass cannot tell a mapped HEAD from a real GET on this path.
                            self->_request.localAddressData = self.localAddressData;
                            self->_request.remoteAddressData = self.remoteAddressData;
                            self->_request.virtualHEAD = self->_virtualHEAD;
                            [self abortRequest:self->_request withStatusCode:kWSKHTTPStatusCode_NotImplemented];
                        } else {
                            // The base request rejected these headers too — a framing conflict
                            // such as "Content-Length" together with a chunked "Transfer-Encoding"
                            // — so no handler could have matched. That is a malformed request
                            // rather than an unimplemented one, and must not assert.
                            WSK_LOG_ERROR(@"Rejecting malformed request headers on socket %i", self->_socket);
                            [self abortRequest:nil withStatusCode:kWSKHTTPStatusCode_BadRequest];
                        }
                    }
                } else {
                    // Reachable on ordinary malformed input, not an unreachable state: a
                    // request-target whose percent-escapes are invalid or not valid UTF-8
                    // (e.g. "GET /%FF") makes WSKUnescapeURLString return nil. That
                    // is the client's error, so answer 400 rather than 500 — and never abort.
                    WSK_LOG_ERROR(@"Failed decoding request target on socket %i", self->_socket);
                    [self abortRequest:nil withStatusCode:kWSKHTTPStatusCode_BadRequest];
                }
            } else {
                // A header block we could not read is the client's problem far more often
                // than ours — it is malformed, or it is larger than kHeadersMaxLength.
                // Answering 500 told the client the server had failed and invited a retry
                // of something that can never succeed.
                [self abortRequest:nil withStatusCode:self->_headerFailureStatus];
            }
        }];
}

- (instancetype)initWithServer:(WSKWebServer *)server localAddress:(NSData *)localAddress remoteAddress:(NSData *)remoteAddress socket:(CFSocketNativeHandle)socket {
    if ((self = [super init])) {
        _server = server;
        // Snapshot the server's config now (see the ivar declarations): the accept
        // handler runs only while the listening socket is live, i.e. after -_start has
        // populated this config and before -_stop tears it down, so this read is safe.
        _serverName = server.serverName;
        _authenticationRealm = server.authenticationRealm;
        _authenticationBasicAccounts = server.authenticationBasicAccounts;
        _authenticationDigestAccounts = server.authenticationDigestAccounts;
        _allowedHostNames = server.allowedHostNames;
        _shouldAutomaticallyMapHEADToGET = server.shouldAutomaticallyMapHEADToGET;
        _localAddressData = localAddress;
        _remoteAddressData = remoteAddress;
        _socket = socket;
        _connectionQueue = dispatch_queue_create("gcdwebserver.connection", DISPATCH_QUEUE_SERIAL);
        _headerFailureStatus = kWSKHTTPStatusCode_InternalServerError;
        WSK_LOG_DEBUG(@"Did open connection on socket %i", _socket);

        NSTimeInterval idleTimeout = server.connectionIdleTimeout;
        _idleTimeout = idleTimeout;

        if (idleTimeout > 0.0) {
            _idleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _connectionQueue);
            uint64_t interval = (uint64_t)(idleTimeout * (NSTimeInterval)NSEC_PER_SEC);
            dispatch_source_set_timer(_idleTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, interval / 10);
            __weak WSKConnection *weakSelf = self;  // A strong capture would cycle through the source's handler and keep the connection alive forever
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
    return WSKStringFromSockAddr(_localAddressData.bytes, YES);
}

- (NSString *)remoteAddressString {
    return WSKStringFromSockAddr(_remoteAddressData.bytes, YES);
}

- (void)dealloc {
    if (_idleTimer) {
        dispatch_source_cancel(_idleTimer);
    }

    int result = close(_socket);

    if (result != 0) {
        WSK_LOG_ERROR(@"Failed closing socket %i for connection: %s (%i)", _socket, strerror(errno), errno);
    } else {
        WSK_LOG_DEBUG(@"Did close connection on socket %i", _socket);
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

@implementation WSKConnection (Read)

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
                        WSK_LOG_ERROR(@"No more data available on socket %i", self->_socket);
                    } else {
                        WSK_LOG_WARNING(@"No data received from socket %i", self->_socket);
                    }

                    block(NO);
                }
            } else {
                WSK_LOG_ERROR(@"Error while reading from socket %i: %s (%i)", self->_socket, strerror(error), error);
                block(NO);
            }
        }
    });
}

// RFC 9112 §5.1: tchar, the only characters legal in a field name or a method.
static BOOL _IsHeaderTokenCharacter(unsigned char character) {
    if (((character >= 'a') && (character <= 'z')) || ((character >= 'A') && (character <= 'Z')) || ((character >= '0') && (character <= '9'))) {
        return YES;
    }

    switch (character) {
        case '!':
        case '#':
        case '$':
        case '%':
        case '&':
        case '\'':
        case '*':
        case '+':
        case '-':
        case '.':
        case '^':
        case '_':
        case '`':
        case '|':
        case '~':
            return YES;

        default:
            return NO;
    }
}

// method SP request-target SP HTTP-version, with no room for interpretation. Without
// this a request line is split on the first two spaces and whatever remains becomes part
// of the path: "GET /a HTTP/1.1 junk" was dispatched with a path of "/a HTTP/1.1".
static BOOL _ValidateRequestLine(const unsigned char *line, NSUInteger length) {
    NSUInteger firstSpace = NSNotFound;
    NSUInteger lastSpace = NSNotFound;
    NSUInteger spaceCount = 0;

    for (NSUInteger i = 0; i < length; i++) {
        unsigned char const character = line[i];

        if (character == ' ') {
            spaceCount += 1;

            if (firstSpace == NSNotFound) {
                firstSpace = i;
            }

            lastSpace = i;
        } else if ((character < 0x21) || (character == 0x7F)) {
            return NO;  // A CTL or stray whitespace inside the method, target or version
        }
    }

    if ((spaceCount != 2) || (firstSpace == 0) || (lastSpace <= firstSpace + 1)) {
        return NO;  // Wrong shape, empty method, or empty request-target
    }

    for (NSUInteger i = 0; i < firstSpace; i++) {
        if (!_IsHeaderTokenCharacter(line[i])) {
            return NO;
        }
    }

    // A '#' in the request-target is not a fragment to be discarded, it is a malformed target: RFC
    // 9110 §7.1 says the fragment is not part of the request target at all. CFURLCopyPath() honours
    // it as a delimiter and hands back only the prefix, and every verb was then executed against
    // that prefix — so `PUT /ci/MyApp#42.ipa` wrote to `/ci/MyApp`, three builds published that way
    // collapsed into one file under 201/204/204, and `DELETE /D1/#nope` answered 204 having
    // destroyed `/D1`. Same shape as the NUL truncation the eighth pass refused rather than
    // honoured, at a delimiter that fix never covered, and refused here for the same reason:
    // truncating does not make the request mean what the client wrote.
    //
    // Checked on the raw wire bytes, ahead of any CF parsing, so a -rewriteRequestURL: subclass
    // cannot route around it. "%23" still addresses a '#'-bearing filename correctly and must keep
    // working — that is the case a naive fix breaks.
    for (NSUInteger i = firstSpace + 1; i < lastSpace; i++) {
        if (line[i] == '#') {
            return NO;
        }
    }

    NSUInteger const versionLength = length - lastSpace - 1;
    const unsigned char *const version = line + lastSpace + 1;

    if ((versionLength != 8) || (memcmp(version, "HTTP/1.", 7) != 0)) {
        return NO;
    }

    return (version[7] == '0') || (version[7] == '1');
}

// The header block is framed here by scanning for CRLFCRLF, but it is *parsed* by
// CFHTTPMessage, which ends the message at a bare LF-LF. When the two disagree every
// header in between was silently discarded and the request still succeeded — the server
// acted on a different message than the client sent, which is the worst outcome for a
// server that would rather refuse than half-succeed. Instead of reconciling the two
// scanners, require the framing to be unambiguous: every CR paired with an LF, and no
// obs-fold. The remaining checks are ordinary field syntax that CFHTTPMessage accepts far
// too leniently — "Content-Length : 5" and a folded "Content-Length:\r\n 5" both yielded
// a content length, and those fields decide how many bytes reach the disk.
static BOOL _ValidateRequestHeaderBlock(const void *rawBytes, NSUInteger length) {
    const unsigned char *const bytes = (const unsigned char *)rawBytes;

    for (NSUInteger i = 0; i < length; i++) {
        if (bytes[i] == '\r') {
            if ((i + 1 >= length) || (bytes[i + 1] != '\n')) {
                return NO;
            }
        } else if (bytes[i] == '\n') {
            if ((i == 0) || (bytes[i - 1] != '\r')) {
                return NO;
            }
        }
    }

    BOOL expectingRequestLine = YES;
    NSUInteger lineStart = 0;

    for (NSUInteger i = 0; i + 1 < length; i++) {
        if ((bytes[i] != '\r') || (bytes[i + 1] != '\n')) {
            continue;
        }

        const unsigned char *const line = bytes + lineStart;
        NSUInteger const lineLength = i - lineStart;

        if (lineLength == 0) {
            break;  // The empty line terminates the block
        }

        if (expectingRequestLine) {
            if (!_ValidateRequestLine(line, lineLength)) {
                return NO;
            }

            expectingRequestLine = NO;
        } else {
            if ((line[0] == ' ') || (line[0] == '\t')) {
                return NO;  // obs-fold continuation line
            }

            NSUInteger colon = NSNotFound;

            for (NSUInteger j = 0; j < lineLength; j++) {
                if (line[j] == ':') {
                    colon = j;
                    break;
                }
            }

            if ((colon == NSNotFound) || (colon == 0)) {
                return NO;  // No field name, or no colon at all
            }

            for (NSUInteger j = 0; j < colon; j++) {
                if (!_IsHeaderTokenCharacter(line[j])) {
                    return NO;  // Includes whitespace before the colon
                }
            }
        }

        lineStart = i + 2;
        i += 1;  // Skip the LF we just consumed
    }

    return !expectingRequestLine;
}

- (void)readHeaders:(NSMutableData *)headersData withCompletionBlock:(ReadHeadersCompletionBlock)block {
    WSK_DCHECK(_requestMessage);
    [self readData:headersData
             withLength:NSUIntegerMax
        completionBlock:^(BOOL success) {
            if (success) {
                NSRange range = [headersData rangeOfData:_CRLFCRLFData options:0 range:NSMakeRange(0, headersData.length)];

                if (range.location == NSNotFound) {
                    if (headersData.length > kHeadersMaxLength) {
                        WSK_LOG_ERROR(@"Request headers exceeded %i bytes on socket %i", (int)kHeadersMaxLength, self->_socket);
                        self->_headerFailureStatus = kWSKHTTPStatusCode_RequestHeaderFieldsTooLarge;
                        block(nil);
                    } else {
                        [self readHeaders:headersData withCompletionBlock:block];
                    }
                } else {
                    NSUInteger length = range.location + range.length;

                    // kHeadersMaxLength was only ever enforced on the branch above, i.e.
                    // while still waiting for the terminator. A client that sent an
                    // oversized header block in one burst had it found, parsed and served
                    // — the cap was skipped entirely. Bound the block itself, not the
                    // buffer, which legitimately runs past it once body bytes arrive in the
                    // same read.
                    if (length > kHeadersMaxLength) {
                        WSK_LOG_ERROR(@"Request headers exceeded %i bytes on socket %i", (int)kHeadersMaxLength, self->_socket);
                        self->_headerFailureStatus = kWSKHTTPStatusCode_RequestHeaderFieldsTooLarge;
                        block(nil);
                    } else if (!_ValidateRequestHeaderBlock(headersData.bytes, length)) {
                        WSK_LOG_ERROR(@"Rejecting malformed request line or header syntax on socket %i", self->_socket);
                        self->_headerFailureStatus = kWSKHTTPStatusCode_BadRequest;
                        block(nil);
                    } else if (CFHTTPMessageAppendBytes(self->_requestMessage, headersData.bytes, length)) {
                        if (CFHTTPMessageIsHeaderComplete(self->_requestMessage)) {
                            block([headersData subdataWithRange:NSMakeRange(length, headersData.length - length)]);
                        } else {
                            WSK_LOG_ERROR(@"Failed parsing request headers from socket %i", self->_socket);
                            self->_headerFailureStatus = kWSKHTTPStatusCode_BadRequest;
                            block(nil);
                        }
                    } else {
                        WSK_LOG_ERROR(@"Failed appending request headers data from socket %i", self->_socket);
                        self->_headerFailureStatus = kWSKHTTPStatusCode_BadRequest;
                        block(nil);
                    }
                }
            } else {
                block(nil);
            }
        }];
}

- (void)readBodyWithRemainingLength:(NSUInteger)length completionBlock:(ReadBodyCompletionBlock)block {
    WSK_DCHECK([_request hasBody] && ![_request usesChunkedTransferEncoding]);
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
                        WSK_LOG_ERROR(@"Failed writing request body on socket %i: %@", self->_socket, error);
                        block(NO);
                    }
                } else {
                    WSK_LOG_ERROR(@"Unexpected extra content reading request body on socket %i", self->_socket);
                    block(NO);
                    WSK_DNOT_REACHED();
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
    WSK_DCHECK([_request hasBody] && [_request usesChunkedTransferEncoding]);

    while (1) {
        NSRange range = [chunkData rangeOfData:_CRLFData options:0 range:NSMakeRange(0, chunkData.length)];

        if (range.location == NSNotFound) {
            break;
        }

        NSRange extensionRange = [chunkData rangeOfData:[NSData dataWithBytes:";" length:1] options:0 range:NSMakeRange(0, range.location)];  // Ignore chunk extensions
        NSUInteger length = _ScanHexNumber((char *)chunkData.bytes, extensionRange.location != NSNotFound ? extensionRange.location : range.location);

        if (length != NSNotFound) {
            if (length) {
                if (length > WSKMaxInMemoryBodyLength()) {
                    // A single chunk is buffered whole in memory before being written, so
                    // cap its declared size. Legitimate chunked uploads use many smaller
                    // chunks; this only rejects a pathologically large single chunk.
                    WSK_LOG_ERROR(@"Chunk size %lu exceeds the %lu byte limit reading request body on socket %i", (unsigned long)length, (unsigned long)WSKMaxInMemoryBodyLength(), _socket);
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
                        WSK_LOG_ERROR(@"Failed writing request body on socket %i: %@", _socket, error);
                        block(NO);
                        return;
                    }
                } else {
                    WSK_LOG_ERROR(@"Missing terminating CRLF sequence for chunk reading request body on socket %i", _socket);
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
            WSK_LOG_ERROR(@"Invalid chunk length reading request body on socket %i", _socket);
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
    if (chunkData.length > WSKMaxInMemoryBodyLength() + kHeadersMaxLength) {
        WSK_LOG_ERROR(@"Chunked transfer framing exceeds the buffer limit reading request body on socket %i", _socket);
        block(NO);
        return;
    }

    // That cap is per-connection, and per-connection caps do not compose: with the
    // connection limit it allowed gigabytes in aggregate. Charge this buffer against the
    // process-wide ceiling too, and give bytes back as the parser drains them.
    if (![_chunkReservation reserveBytes:chunkData.length]) {
        WSK_LOG_ERROR(@"Refusing chunked body on socket %i: the server is already holding its %lu byte in-memory limit across all connections", _socket, (unsigned long)kWSKMaxTotalInMemoryLength);
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

@implementation WSKConnection (Write)

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
                WSK_DCHECK(remainingData == NULL);
                [self didWriteBytes:data.bytes length:data.length];
                block(YES);
            } else {
                WSK_LOG_ERROR(@"Error while writing to socket %i: %s (%i)", self->_socket, strerror(error), error);
                block(NO);
            }
        }
    });
#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
    dispatch_release(buffer);
#endif
}

- (void)writeHeadersWithCompletionBlock:(WriteHeadersCompletionBlock)block {
    WSK_DCHECK(_responseMessage);
    CFDataRef data = CFHTTPMessageCopySerializedMessage(_responseMessage);
    [self writeData:(__bridge NSData *)data withCompletionBlock:block];
    CFRelease(data);
}

- (void)writeBodyWithCompletionBlock:(WriteBodyCompletionBlock)block {
    WSK_DCHECK([_response hasBody]);
    [_response performReadDataWithCompletion:^(NSData *data, NSError *error) {
        if (data) {
            if (data.length) {
                if ([self _shouldChunkResponse]) {
                    const char *hexString = [[NSString stringWithFormat:@"%lx", (unsigned long)data.length] UTF8String];
                    size_t hexLength = strlen(hexString);
                    NSData *chunk = [NSMutableData dataWithLength:(hexLength + 2 + data.length + 2)];

                    if (chunk == nil) {
                        WSK_LOG_ERROR(@"Failed allocating memory for response body chunk for socket %i: %@", self->_socket, error);
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
                if ([self _shouldChunkResponse]) {
                    [self writeData:_lastChunkData
                        withCompletionBlock:^(BOOL success) {
                            block(success);
                        }];
                } else {
                    block(YES);
                }
            }
        } else {
            WSK_LOG_ERROR(@"Failed reading response body for socket %i: %@", self->_socket, error);
            block(NO);
        }
    }];
}

@end

@implementation WSKConnection (Subclassing)

- (BOOL)open {
#ifdef __WEBSERVERKIT_ENABLE_TESTING__

    if (_server.recordingEnabled) {
        _connectionIndex = atomic_fetch_add(&_connectionCounter, 1) + 1;

        _requestPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
        _requestFD = open([_requestPath fileSystemRepresentation], O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
        WSK_DCHECK(_requestFD > 0);

        _responsePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
        _responseFD = open([_responsePath fileSystemRepresentation], O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
        WSK_DCHECK(_responseFD > 0);
    }

#endif

    return YES;
}

- (void)didReadBytes:(const void *)bytes length:(NSUInteger)length {
    WSK_LOG_DEBUG(@"Connection received %lu bytes on socket %i", (unsigned long)length, _socket);
    _totalBytesRead += length;

#ifdef __WEBSERVERKIT_ENABLE_TESTING__

    if ((_requestFD > 0) && (write(_requestFD, bytes, length) != (ssize_t)length)) {
        WSK_LOG_ERROR(@"Failed recording request data: %s (%i)", strerror(errno), errno);
        close(_requestFD);
        _requestFD = 0;
    }

#endif
}

- (void)didWriteBytes:(const void *)bytes length:(NSUInteger)length {
    WSK_LOG_DEBUG(@"Connection sent %lu bytes on socket %i", (unsigned long)length, _socket);
    _totalBytesWritten += length;

#ifdef __WEBSERVERKIT_ENABLE_TESTING__

    if ((_responseFD > 0) && (write(_responseFD, bytes, length) != (ssize_t)length)) {
        WSK_LOG_ERROR(@"Failed recording response data: %s (%i)", strerror(errno), errno);
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
    return [NSString stringWithFormat:@"%@.%@", stamp, WSKComputeMD5Digest(@"%@:%@", stamp, secret)];
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

    if (!_ConstantTimeEqualStrings(mac, WSKComputeMD5Digest(@"%@:%@", stamp, secret))) {
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

    return WSKUnescapeURLString(target);
}

// https://tools.ietf.org/html/rfc2617
- (WSKResponse *)preflightRequest:(WSKRequest *)request {
    WSK_LOG_DEBUG(@"Connection on socket %i preflighting request \"%@ %@\" with %lu bytes body", _socket, _virtualHEAD ? @"HEAD" : _request.method, _request.path, (unsigned long)_totalBytesRead);
    WSKResponse *response = nil;

    // A CORS preflight (an OPTIONS request carrying "Access-Control-Request-Method")
    // must not require credentials: browsers never send "Authorization" on preflight
    // per the CORS spec, so enforcing auth here rejects it with 401 and breaks every
    // subsequent cross-origin request. Let it through to the handler so the app can
    // answer the preflight. See swisspol/WSKWebServer#479.
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
            response = [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_Unauthorized];
            [response setValue:[NSString stringWithFormat:@"Basic realm=\"%@\"", _authenticationRealm] forAdditionalHeader:@"WWW-Authenticate"];
        }
    } else if (_authenticationDigestAccounts) {
        BOOL authenticated = NO;
        BOOL isStaled = NO;
        NSString *const authorizationHeader = request.headers[@"Authorization"];

        if ([authorizationHeader hasPrefix:@"Digest "]) {
            NSString *const realm = WSKExtractHeaderValueParameter(authorizationHeader, @"realm");

            if (realm && [_authenticationRealm isEqualToString:realm]) {
                NSString *const nonce = WSKExtractHeaderValueParameter(authorizationHeader, @"nonce");
                BOOL nonceExpired = NO;

                if (_ValidateDigestNonce(nonce, _digestAuthenticationSecret, &nonceExpired)) {
                    if (nonceExpired) {
                        isStaled = YES;  // Genuine nonce, just aged out: stale=TRUE lets the client retry silently.
                    } else {
                        NSString *const username = WSKExtractHeaderValueParameter(authorizationHeader, @"username");
                        NSString *const uri = WSKExtractHeaderValueParameter(authorizationHeader, @"uri");
                        NSString *const actualResponse = WSKExtractHeaderValueParameter(authorizationHeader, @"response");
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
                            NSString *const ha2 = WSKComputeMD5Digest(@"%@:%@", request.method, uri);  // Use "uri" not "request.path": the query string is part of the client's digest
                            NSString *const expectedResponse = WSKComputeMD5Digest(@"%@:%@:%@", ha1, nonce, ha2);

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
            response = [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_Unauthorized];
            [response setValue:[NSString stringWithFormat:@"Digest realm=\"%@\", nonce=\"%@\"%@", _authenticationRealm, _GenerateDigestNonce(_digestAuthenticationSecret), isStaled ? @", stale=TRUE" : @""] forAdditionalHeader:@"WWW-Authenticate"];  // TODO: Support Quality of Protection ("qop")
        }
    }

    return response;
}

- (void)processRequest:(WSKRequest *)request completion:(WSKCompletionBlock)completion {
    WSK_LOG_DEBUG(@"Connection on socket %i processing request \"%@ %@\" with %lu bytes body", _socket, _virtualHEAD ? @"HEAD" : _request.method, _request.path, (unsigned long)_totalBytesRead);

    if (_handler.asyncProcessBlock) {
        _handler.asyncProcessBlock(request, [completion copy]);
    } else {
        completion(nil);
    }
}

// http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.25
// http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.26
// If-None-Match is a list, and it is compared weakly: a "W/" prefix is stripped from both
// sides before comparing (RFC 9110 §8.8.3.2). Matching one verbatim value meant a client
// sending either form revalidated as a miss and re-downloaded the whole body. Candidates
// must still look like entity-tags, so a stray fragment cannot produce a false match — a
// wrong "no" here costs a download, a wrong "yes" serves stale content.
static BOOL _ETagMatchesIfNoneMatch(NSString *responseETag, NSString *ifNoneMatch) {
    NSString *responseValue = [responseETag hasPrefix:@"W/"] ? [responseETag substringFromIndex:2] : responseETag;

    for (NSString *candidate in [ifNoneMatch componentsSeparatedByString:@","]) {
        NSString *trimmed = [candidate stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if ([trimmed hasPrefix:@"W/"]) {
            trimmed = [trimmed substringFromIndex:2];
        }

        if ((trimmed.length >= 2) && [trimmed hasPrefix:@"\""] && [trimmed hasSuffix:@"\""] && [trimmed isEqualToString:responseValue]) {
            return YES;
        }
    }

    return NO;
}

// RFC 9110 §13.1.3: a recipient MUST ignore If-Modified-Since when If-None-Match is
// present. Evaluating the date first, and independently, meant a revalidation carrying a
// *stale* ETag still got a 304 whenever the replacement's mtime was not strictly newer —
// routine when a file is replaced within the same second, or restored with an older mtime.
// Per RFC 9111 §4.3.4 the client then updates its stored headers from that 304, so it
// holds the old body under the new ETag and every later revalidation matches too: the
// stale copy is pinned indefinitely, which is precisely what the ETag exists to prevent.
// The comment this replaces had the precedence backwards.
static inline BOOL _CompareResources(NSString *responseETag, NSString *requestETag, NSDate *responseLastModified, NSDate *requestLastModified) {
    if (requestETag) {
        if (!responseETag) {
            return NO;
        }

        return [requestETag isEqualToString:@"*"] || _ETagMatchesIfNoneMatch(responseETag, requestETag);
    }

    // Exact equality, not "not newer". The old comparison answered 304 whenever the file's
    // mtime was equal *or older*, which pins a date-only client on stale bytes permanently:
    // restore a previous build (or rsync -a / cp -p / touch -t from an older source) and the
    // client revalidating with the newer representation's Last-Modified is told 304, keeps the
    // body it has, and — per RFC 9111 §4.3.4 — adopts the *current* ETag and Last-Modified from
    // that 304. Its next revalidation therefore matches on the ETag too, so no request will
    // ever dislodge it. It also answered 304 for an If-Modified-Since in the future, i.e. for a
    // resource the client demonstrably does not hold.
    //
    // Safe to tighten here specifically because _NSDateFromTimeSpec truncates the response's
    // Last-Modified to whole seconds (see the comment on it), and WSKParseRFC822 parses at the
    // same precision, so a client echoing back the value it was given still compares equal and
    // ordinary unchanged-file revalidation keeps working. This is also nginx's default
    // ("if_modified_since exact"), so it is not an unusual reading.
    if (requestLastModified && responseLastModified) {
        return [responseLastModified compare:requestLastModified] == NSOrderedSame;
    }

    return NO;
}

- (WSKResponse *)overrideResponse:(WSKResponse *)response forRequest:(WSKRequest *)request {
    if ((response.statusCode >= 200) && (response.statusCode < 300) &&
        _CompareResources(response.eTag, request.ifNoneMatch, response.lastModifiedDate, request.ifModifiedSince)) {
        NSInteger code = kWSKHTTPStatusCode_PreconditionFailed;
        if ([request.method isEqualToString:@"HEAD"] || [request.method isEqualToString:@"GET"]) {
          code = kWSKHTTPStatusCode_NotModified;
        }
        WSKResponse *newResponse = [WSKResponse responseWithStatusCode:code];
        newResponse.cacheControlMaxAge = response.cacheControlMaxAge;
        newResponse.lastModifiedDate = response.lastModifiedDate;
        newResponse.eTag = response.eTag;
        WSK_DCHECK(newResponse);
        return newResponse;
    }

    return response;
}

- (void)abortRequest:(WSKRequest *)request withStatusCode:(NSInteger)statusCode {
    WSK_DCHECK(_responseMessage == NULL);
    WSK_DCHECK((statusCode >= 400) && (statusCode < 600));
    _requestReceived = YES;  // Reading is over either way; only the error response remains
    [self _initializeResponseHeadersWithStatusCode:statusCode];
    [self writeHeadersWithCompletionBlock:^(BOOL success){
        // Nothing more to do
    }];
    WSK_LOG_DEBUG(@"Connection aborted with status code %i on socket %i", (int)statusCode, _socket);
}

- (void)close {
#ifdef __WEBSERVERKIT_ENABLE_TESTING__

    if (_requestPath) {
        BOOL success = NO;
        NSError *error = nil;

        if (_requestFD > 0) {
            close(_requestFD);
            NSString *const name = [NSString stringWithFormat:@"%03lu-%@.request", (unsigned long)_connectionIndex, _virtualHEAD ? @"HEAD" : _request.method];
            success = [[NSFileManager defaultManager] moveItemAtPath:_requestPath toPath:[[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:name] error:&error];
        }

        if (!success) {
            WSK_LOG_ERROR(@"Failed saving recorded request: %@", error);
            WSK_DNOT_REACHED();
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
            WSK_LOG_ERROR(@"Failed saving recorded response: %@", error);
            WSK_DNOT_REACHED();
        }

        unlink([_responsePath fileSystemRepresentation]);
    }

#endif /* ifdef __WEBSERVERKIT_ENABLE_TESTING__ */

    if (_request) {
        WSK_LOG_VERBOSE(@"[%@] %@ %i \"%@ %@\" (%lu | %lu)", self.localAddressString, self.remoteAddressString, (int)_statusCode, _virtualHEAD ? @"HEAD" : _request.method, _request.path, (unsigned long)_totalBytesRead, (unsigned long)_totalBytesWritten);
    } else {
        WSK_LOG_VERBOSE(@"[%@] %@ %i \"(invalid request)\" (%lu | %lu)", self.localAddressString, self.remoteAddressString, (int)_statusCode, (unsigned long)_totalBytesRead, (unsigned long)_totalBytesWritten);
    }
}

@end
