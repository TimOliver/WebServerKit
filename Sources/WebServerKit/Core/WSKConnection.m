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
#import <zlib.h>  // Z_DATA_ERROR / Z_NEED_DICT, to tell the client's bad stream from our allocation failure
#ifdef __WEBSERVERKIT_ENABLE_TESTING__
#import <stdatomic.h>
#endif

#import "WSKPrivate.h"

#define kHeadersReadCapacity (1 * 1024)
#define kBodyReadCapacity (256 * 1024)
#define kHeadersMaxLength (64 * 1024)  // Upper bound on total request header bytes, to cap memory for a client that never sends the terminating blank line.
#define kMaxHeaderPhaseTicks 2  // Idle-timer ticks a connection may spend receiving its request line + headers before being closed (defeats a slowloris dribbling bytes just under the zero-progress check).
#define kMinReceiveBytesPerSecond 32  // Throughput a connection must sustain while its request body is still arriving; see -_checkIdleTimeout.
#define kMaxRequestsPerConnection 100  // Requests one reused connection may carry before it must be re-established; bounds how long a single client can hold one of the kWSKMaxConnections slots.

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

@interface WSKConnection (Logging)
- (void)_flushRequestRecordAndLog;
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
    NSSet<NSString *> *_registeredMethods;  // Methods SOME handler claims; decides 404 vs 501 for an unmatched request

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
    NSInteger _bodyFailureStatus;    // Why the body was rejected; same idiom, because the body readers report only a BOOL
    NSTimeInterval _idleTimeout;   // Seconds between idle-timer ticks; 0 when idle timeouts are disabled

    // Connection reuse. Deliberately restricted to requests carrying NO body, which is what keeps
    // request smuggling structurally impossible rather than a matter of parsing carefully: a
    // desync is a disagreement about where a body ends, and no body is ever read on a reused
    // connection. Everything else — a body, a refusal, HTTP/1.0, an indeterminate response length
    // — answers and closes exactly as it always has.
    NSTimeInterval _keepAliveTimeout;   // 0 disables reuse entirely, which is the default
    BOOL _requestIsBodyless;            // No Content-Length and no Transfer-Encoding, from the raw header names
    BOOL _requestTargetIsAbsoluteForm;  // The request-target carried its own authority (RFC 9112 §3.2.2), read off the raw request line
    BOOL _willKeepAlive;                // Decided before the headers go out, honoured after the body does
    BOOL _awaitingNextRequest;          // Between requests: the idle rules differ from the header phase
    NSUInteger _requestsServed;         // Bounds how long one client can hold a connection slot
    NSUInteger _readBytesWhenIdleBegan;  // Read count when the last response finished; the next request can only arrive as reads
    NSMutableData *_carryOverData;      // Bytes of the NEXT request that arrived in this request's last read
    BOOL _requestLogged;                // This request's access line and recording are already flushed
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
// so every status registered since gets its class default instead of its name — three are
// emitted in ordinary operation here: 421 (the DNS-rebinding refusal), 424 (PROPPATCH
// atomicity) and 431 (the header cap).
//
// ONLY the fourteen CF gets wrong are supplied. Everything CF already gets right is left to
// CF, so every status the recorded-trace corpus contains still serializes byte for byte —
// the corpus fails on any difference, and rewriting phrases it records would turn a fix into
// a corpus change.
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

// What to tell a client whose request body we would not accept. 500 is a claim that the
// SERVER broke: it invites a retry of something that can never succeed (malformed chunk
// framing, a corrupt gzip stream) and makes a client give up on something that could (a
// momentarily exhausted budget). The typed codes exist so this can tell the truth.
//
// Only the zlib results that mean "the bytes you sent are not a valid stream" are the
// client's. Z_DATA_ERROR and Z_NEED_DICT are; Z_MEM_ERROR is an allocation failure of OURS,
// and inflateInit2 reports through the same domain — so blanket-mapping this domain to 400
// would tell a client its request was malformed because the server ran out of memory.
//
// Anything unrecognised falls through to WSKServerErrorStatusCodeForError, which already maps
// a full volume to 507 and everything else to 500, so the ENOSPC rule has ONE home.
static NSInteger _StatusForBodyError(NSError *error) {
    if (error == nil) {
        return kWSKHTTPStatusCode_InternalServerError;
    }

    if ([error.domain isEqualToString:kZlibErrorDomain]) {
        if ((error.code == Z_DATA_ERROR) || (error.code == Z_NEED_DICT)) {
            return kWSKHTTPStatusCode_BadRequest;
        }

        return kWSKHTTPStatusCode_InternalServerError;
    }

    if ([error.domain isEqualToString:kWSKErrorDomain]) {
        WSKRequestBodyErrorCode const code = (WSKRequestBodyErrorCode)error.code;

        if (code == kWSKRequestBodyError_Malformed) {
            return kWSKHTTPStatusCode_BadRequest;
        }

        if (code == kWSKRequestBodyError_TooLarge) {
            return kWSKHTTPStatusCode_RequestEntityTooLarge;
        }

        if (code == kWSKRequestBodyError_ServerAtCapacity) {
            return kWSKHTTPStatusCode_ServiceUnavailable;
        }
    }

    return WSKServerErrorStatusCodeForError(error);
}

// Records why the body was refused, for the abort that follows. Mirrors _headerFailureStatus:
// the readers hand back a BOOL, so the reason has to be left where the abort can find it.
- (void)_noteBodyFailure:(NSError *)error {
    _bodyFailureStatus = _StatusForBodyError(error);
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

// Is this a syntactically plausible reg-name (RFC 3986 §3.2.2: unreserved / pct-encoded /
// sub-delims)? Decides 400-versus-421 on the Host refusal path — RFC 9112 §3.2 requires 400 for
// an INVALID field value, and a 421 there instead invites the client to retry the same malformed
// bytes at another origin. Deliberately not consulted on the admission path, so an allow-list
// entry an operator spelled unusually keeps working.
static BOOL _IsSyntacticallyValidRegName(NSString *name) {
    if (name.length == 0) {
        return NO;
    }

    for (NSUInteger i = 0; i < name.length; i++) {
        unichar const character = [name characterAtIndex:i];
        BOOL const unreserved = ((character >= 'a') && (character <= 'z')) || ((character >= 'A') && (character <= 'Z')) ||
                                ((character >= '0') && (character <= '9')) ||
                                (character == '-') || (character == '.') || (character == '_') || (character == '~');
        BOOL const subDelimOrEscape = (character == '!') || (character == '$') || (character == '&') || (character == '\'') ||
                                      (character == '(') || (character == ')') || (character == '*') || (character == '+') ||
                                      (character == ',') || (character == ';') || (character == '=') || (character == '%');

        if (!unreserved && !subDelimOrEscape) {
            return NO;
        }
    }

    return YES;
}


// Refuse a request whose "Host" names something this server does not answer to. This is the
// only defence against DNS rebinding: once a page on evil.example repoints its DNS here, the
// browser treats it as same-origin, so CORS, Origin comparison and CSRF tokens are all
// satisfied — but the browser still sends the name the page was loaded from. See

- (WSKResponse *)_rejectIfHostNotAllowed {
    NSString *authority = _request.headers[@"Host"];

    // RFC 9112 §3.2.2: with an absolute-form request-target the origin server MUST ignore the
    // Host header and validate the TARGET's authority — of the two, Host is the one this check
    // used, i.e. the more attacker-shaped input won. CFHTTPMessageCopyRequestURL preserves the
    // target as sent, so the URL carries a host exactly when the request line was absolute-form.
    // This does not move the rebinding defence (a rebound browser sends origin-form), it makes
    // the absolute-form spelling answer the same way its origin-form spelling always has.
    NSURL *const requestURL = _request.URL;
    NSString *const targetHost = _requestTargetIsAbsoluteForm ? requestURL.host : nil;

    if (targetHost.length) {
        NSNumber *const targetPort = requestURL.port;
        // NSURL hands an IPv6 literal back without its brackets; restore the header spelling so
        // one parse below serves both sources.
        NSString *const bracketedHost = [targetHost containsString:@":"] ? [NSString stringWithFormat:@"[%@]", targetHost] : targetHost;
        authority = targetPort ? [NSString stringWithFormat:@"%@:%@", bracketedHost, targetPort] : bracketedHost;
    }

    // No "Host" at all: HTTP/1.0 and plenty of native clients omit it, and rebinding needs
    // a browser, which never does. There is nothing here that could have been rebound.
    if (authority.length == 0) {
        return nil;
    }

    // Split by the shared authority parser (see WSKSplitAuthority): WebDAV's Destination check
    // asks the same question of the same grammar, and one home is what stops the two drifting.
    // It strips the DNS root label from the *name*, not from the end of the whole value, so
    // "name.local.:8080" normalizes as well as "name.local.".
    NSString *name = nil;
    NSString *portText = nil;
    BOOL isBracketed = NO;

    if (!WSKSplitAuthority(authority, &name, &portText, &isBracketed)) {
        return [self _invalidHostResponseForAuthority:authority];
    }

    // An allow-list entry may pin a port ("files.example:8080"), and such an entry is
    // deliberately honoured verbatim — including its port — so rebuild the canonical
    // authority and try that before validating the port against this connection.
    NSString *const canonical = portText.length
                                    ? [NSString stringWithFormat:(isBracketed ? @"[%@]:%@" : @"%@:%@"), name, portText]
                                    : (isBracketed ? [NSString stringWithFormat:@"[%@]", name] : name);

    if ([_allowedHostNames containsObject:canonical]) {
        return nil;
    }

    // A stated port must be syntactically a port, but it is deliberately NOT required to equal
    // the one this connection arrived on — requiring that refuses every deployment behind a
    // port-translating hop (the client states the port it dialled, the hop forwards to a
    // different one), which is precisely the priority deployment: Tailscale Serve terminating
    // TLS on 443 and forwarding to an ephemeral local port.
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
            return [self _invalidHostResponseForAuthority:authority];
        }
    }

    if (_IsIPAddressLiteral(name) || [_allowedHostNames containsObject:name]) {
        return nil;
    }

    // RFC 9112 §3.2 splits the refusals: a value that is not even a syntactically valid
    // authority answers 400, while a well-formed name this server does not serve answers 421.
    // The syntax question is asked only on the refusal path, deliberately: an exact allow-list
    // match was admitted above, so an operator who explicitly listed an odd spelling keeps it.
    // A bracketed form reaching this point is always invalid — every valid IPv6 literal was
    // admitted by _IsIPAddressLiteral.
    if (isBracketed || !_IsSyntacticallyValidRegName(name)) {
        return [self _invalidHostResponseForAuthority:authority];
    }

    return [self _misdirectedResponseForHost:authority];
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

// RFC 9112 §3.2: a Host whose field value is not a syntactically valid authority answers 400 —
// the message itself is broken, which is a different statement from 421's "well-formed, but not
// a name this server answers to". Logged just as loudly: a deployment tripping this is almost
// certainly a client or proxy bug worth seeing.
- (WSKResponse *)_invalidHostResponseForAuthority:(NSString *)authority {
    WSK_LOG_ERROR(@"Refusing \"%@ %@\" from %@: \"%@\" is not a syntactically valid authority (RFC 9112 §3.2)",
                  _request.method, _request.path, self.remoteAddressString, authority);
    return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Invalid \"Host\" header \"%@\"", authority];
}

// RFC 9110 §9.3.4: an origin server MUST answer 400 to a PUT carrying "Content-Range", "since the
// target resource may be truncated by the partial content and the client may not be aware of that".
// It was honoured as an ordinary whole-body write instead: a 3-byte body under
// "Content-Range: bytes 0-2/10" was stored as the complete representation under a 201, and the
// range's OFFSET was ignored too ("bytes 5-7/10" also wrote at offset 0) — the complete,
// well-formed, WRONG response this codebase keeps finding. curl -C - puts the header on the wire
// for upload resume, so an everyday client reaches it.
//
// Lives here, in the connection's header-time refusal path, rather than in WebDAV's performPUT:
// for two reasons: the rule is RFC 9110's and applies to any PUT handler a host app registers, not
// only to the one PUT in this tree; and refusing on headers means a large partial body is never
// spooled to disk first.
//
// Scoped to PUT because that is where the RFC scopes it. Content-Range on a method for which it
// has no defined meaning is ignored, not fatal.
- (WSKResponse *)_rejectIfPUTCarriesContentRange {
    if (![_request.method isEqualToString:@"PUT"]) {
        return nil;
    }

    NSString *const contentRange = _HeaderValueForName(_request.headers, @"Content-Range");

    if (contentRange == nil) {
        return nil;
    }

    WSK_LOG_WARNING(@"Refusing PUT on \"%@\" carrying 'Content-Range: %@': a partial PUT would be stored as the whole entity", _request.path, contentRange);
    return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest
                                                      message:@"A 'Content-Range' header is not allowed on a PUT (RFC 9110 §9.3.4)"];
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

    WSKResponse *const contentRangeResponse = [self _rejectIfPUTCarriesContentRange];

    if (contentRangeResponse) {
        return contentRangeResponse;
    }

    return [self preflightRequest:_request];
}

// A request is eligible for connection reuse only if it carries NO body framing at all. Read from
// the RAW header names rather than from -[WSKRequest hasBody], which keys on _contentType and is
// only equivalent to "has a body" because -initWithMethod: maintains that correspondence thirty
// lines away. Basing a framing decision on a second spelling of the rule is how this codebase's
// defects usually start — and the difference is not theoretical: "Transfer-Encoding: identity" sets
// no content type, so -hasBody answers NO for a request that DOES carry transfer-coding framing,
// which is exactly the shape a TE.CL desync is built from.
//
// Matched case-insensitively over every key, rather than by subscripting the two standard
// spellings, because CFHTTPMessageCopyAllHeaderFields only standardizes the names it
// recognises — a lookup that matters is done over the keys, never one spelling.
static NSString *_HeaderValueForName(NSDictionary *headers, NSString *name) {
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) {
            return headers[key];
        }
    }

    return nil;
}

static BOOL _HeadersCarryNoBodyFraming(NSDictionary *headers) {
    for (NSString *name in headers) {
        if (([name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) ||
            ([name caseInsensitiveCompare:@"Transfer-Encoding"] == NSOrderedSame)) {
            return NO;
        }
    }

    return YES;
}

// Every condition that must hold for this connection to carry another request. Evaluated once, with
// the response in hand, immediately before the header block that announces the decision goes out.
- (BOOL)_shouldKeepConnectionAlive {
    if (_keepAliveTimeout <= 0.0) {
        return NO;  // Disabled, which is the default: one request per connection, as before.
    }

    // No body was read, so no body bytes can be left unconsumed and there is nothing for this
    // server and an intermediary to disagree about. This is the whole basis of the guarantee.
    if (!_requestIsBodyless) {
        return NO;
    }

    // HTTP/1.0 has no persistent connections by default, and this server does not implement the
    // "Connection: keep-alive" extension it would need. It is also the client for which the
    // response may be framed by connection close.
    if (_clientIsHTTP10) {
        return NO;
    }

    // Note the nil guard: messaging nil returns a ZEROED struct, so a missing Connection header
    // gives {0, 0} and `location != NSNotFound` is true — which made this refuse every request that
    // did not send the header, i.e. all of them. It failed safe, so nothing was unsafe; the feature
    // was simply never on.
    NSString *const connectionHeader = _HeaderValueForName(_request.headers, @"Connection");

    if (connectionHeader && ([connectionHeader rangeOfString:@"close" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        return NO;  // The client asked us not to.
    }

    // The response must state its own length, or the client cannot tell where it ends without
    // waiting for the close that reuse is avoiding. A chunked response frames itself; anything
    // else needs Content-Length.
    if (![self _shouldChunkResponse] && (_response.contentLength == NSUIntegerMax)) {
        return NO;
    }

    // A bound on how long one client can hold a slot. With kWSKMaxConnections at 128 and a browser
    // opening six per origin, unbounded reuse would let a handful of tabs occupy the server
    // indefinitely — the cap that binds in practice is the connection pool, not this.
    if (_requestsServed >= kMaxRequestsPerConnection) {
        return NO;
    }

    return YES;
}

// Everything the next request must not inherit. Kept adjacent to the ivar block it mirrors,
// because a field added there and forgotten here is a cross-request state leak — a defect class
// this connection could not previously have, since it never served a second request.
- (void)_resetForNextRequest {
    if (_requestMessage) {
        CFRelease(_requestMessage);
        _requestMessage = NULL;
    }

    if (_responseMessage) {
        CFRelease(_responseMessage);
        _responseMessage = NULL;
    }

    _request = nil;
    _response = nil;
    _handler = nil;
    _statusCode = 0;
    _virtualHEAD = NO;
    _requestReceived = NO;
    _earlyChecksRun = NO;
    _requestIsBodyless = NO;
    _willKeepAlive = NO;
    _clientIsHTTP10 = NO;
    _headerFailureStatus = kWSKHTTPStatusCode_InternalServerError;
    _bodyFailureStatus = kWSKHTTPStatusCode_InternalServerError;
    _chunkReservation = nil;  // Named in the reuse ivar block, so it is cleared here like the rest
    _headerPhaseTicks = 0;  // Or the second request inherits the first's deadline and is killed early.
    // _requestLogged is deliberately NOT cleared here, and this note exists so the omission reads
    // as a decision rather than the leak this method exists to prevent. It is cleared where the
    // next request's header block actually ARRIVES: this reset runs whether or not another request
    // ever comes, so clearing it here would leave the connection believing it still owed a log line
    // for the request it just finished, and -close would write a second, emptied-out one.

#ifdef __WEBSERVERKIT_ENABLE_TESTING__
    _requestPath = nil;
    _responsePath = nil;
    _requestFD = 0;
    _responseFD = 0;
#endif
}

// The end of a response. Either the connection carries another request or it is simply released,
// which is what closes it — the same unwind as before this existed.
- (void)_finishConnectionOrReadNextRequest {
    if (!_willKeepAlive) {
        return;
    }

    // Flush this request's log line and any recording while its state is still live. NOT -close:
    // that is the connection-level subclassing hook, documented as the partner of -open ("called
    // when the connection is opened", and able to REJECT it by returning NO), so it is meaningful
    // only once per connection. Calling it per request gave a host app pairing the two — allocate
    // in one, release in the other — one open and N closes.
    [self _flushRequestRecordAndLog];
    _requestsServed += 1;
    [self _resetForNextRequest];
    // Snapshot the READ count, not read+written. The response that just went out moved bytes, so
    // comparing the combined total would make the very first idle tick conclude the next request
    // had started arriving — dropping straight back into the header-phase deadline and closing the
    // connection after two ticks regardless of the configured keep-alive.
    _readBytesWhenIdleBegan = _totalBytesRead;
    _awaitingNextRequest = YES;
    [self _readRequestHeaders];
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

        // Decided here rather than in -_initializeResponseHeadersWithStatusCode:, which sets
        // "Close" unconditionally. That default is what makes every abort, every refusal and every
        // path that does not reach this point close the connection by construction rather than by
        // remembering to.
        _willKeepAlive = [self _shouldKeepConnectionAlive];

        if (_willKeepAlive) {
            CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Connection"), CFSTR("keep-alive"));
            CFHTTPMessageSetHeaderFieldValue(_responseMessage, CFSTR("Keep-Alive"), (__bridge CFStringRef)[NSString stringWithFormat:@"timeout=%i, max=%i", (int)_keepAliveTimeout, (int)(kMaxRequestsPerConnection - _requestsServed)]);
        }

        [self writeHeadersWithCompletionBlock:^(BOOL success) {
            if (success) {
                if (hasBody) {
                    [self writeBodyWithCompletionBlock:^(BOOL successInner) {
                        [self->_response performClose];  // TODO: There's nothing we can do on failure as headers have already been sent

                        // Only a body that went out whole leaves the stream at a known
                        // position; after a partial write the client cannot tell where the
                        // next response begins, so the connection has to end.
                        if (successInner) {
                            [self _finishConnectionOrReadNextRequest];
                        }
                    }];
                } else {
                    [self _finishConnectionOrReadNextRequest];
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
        // The error was populated and thrown away. It carries real information: a multipart body
        // with no usable boundary is malformed (400), and an open(2) that fails ENOSPC is a full
        // volume (507) — the same errno the very next call would have mapped correctly.
        [self _noteBodyFailure:error];
        [self abortRequest:_request withStatusCode:_bodyFailureStatus];
        return;
    }

    if (initialData.length) {
        if (![_request performWriteData:initialData error:&error]) {
            WSK_LOG_ERROR(@"Failed writing request body on socket %i: %@", _socket, error);
            [self _noteBodyFailure:error];
            NSError *closeError = nil;

            if (![_request performClose:&closeError]) {
                // Deliberately does not overwrite the reason: the write failure is why the
                // request is being refused, and closing a body that already failed to write is
                // expected to fail too. Reusing one `error` variable here meant the close's
                // error replaced the write's before anything could read it.
                WSK_LOG_ERROR(@"Failed closing request body for socket %i: %@", _socket, closeError);
            }

            [self abortRequest:_request withStatusCode:_bodyFailureStatus];
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
                                  [self abortRequest:self->_request withStatusCode:self->_bodyFailureStatus];
                                  return;
                              }

                              if ([self->_request performClose:&localError]) {
                                  [self _startProcessingRequest];
                              } else {
                                  WSK_LOG_ERROR(@"Failed closing request body for socket %i: %@", self->_socket, localError);
                                  [self _noteBodyFailure:localError];
                                  [self abortRequest:self->_request withStatusCode:self->_bodyFailureStatus];
                              }
                          }];
    } else {
        if ([_request performClose:&error]) {
            [self _startProcessingRequest];
        } else {
            WSK_LOG_ERROR(@"Failed closing request body for socket %i: %@", _socket, error);
            [self _noteBodyFailure:error];
            [self abortRequest:_request withStatusCode:_bodyFailureStatus];
        }
    }
}

- (void)_readChunkedBodyWithInitialData:(NSData *)initialData {
    NSError *error = nil;

    if (![_request performOpen:&error]) {
        WSK_LOG_ERROR(@"Failed opening request body for socket %i: %@", _socket, error);
        [self _noteBodyFailure:error];
        [self abortRequest:_request withStatusCode:_bodyFailureStatus];
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
                    [self abortRequest:self->_request withStatusCode:self->_bodyFailureStatus];
                    return;
                }

                if ([self->_request performClose:&localError]) {
                    [self _startProcessingRequest];
                } else {
                    WSK_LOG_ERROR(@"Failed closing request body for socket %i: %@", self->_socket, localError);
                    [self _noteBodyFailure:localError];
                    [self abortRequest:self->_request withStatusCode:self->_bodyFailureStatus];
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

    // A reused connection with no request in flight is idle BY DESIGN — that is what it is for —
    // so the slowloris deadline below must not apply to it. It gets its own, longer allowance
    // instead: the configured keep-alive timeout, after which the slot is reclaimed. The moment
    // the first byte of the next request lands this reverts to the ordinary header-phase rules,
    // so a client cannot buy slowloris immunity by keeping a connection alive first.
    if (_awaitingNextRequest) {
        if (_totalBytesRead > _readBytesWhenIdleBegan) {
            // The next request has started arriving. Hand the ordinary header-phase deadline a
            // FRESH budget: _headerPhaseTicks counts idle waiting above and header dribbling
            // below, so carrying it across would charge this request for time the connection was
            // legitimately idle and cut short a slow but genuine one.
            _awaitingNextRequest = NO;
            _headerPhaseTicks = 0;
        } else {
            _headerPhaseTicks += 1;

            if ((_idleTimeout > 0.0) && ((NSTimeInterval)_headerPhaseTicks * _idleTimeout > _keepAliveTimeout)) {
                WSK_LOG_DEBUG(@"Closing idle keep-alive connection on socket %i", _socket);
                dispatch_source_cancel(_idleTimer);
                shutdown(_socket, SHUT_RDWR);
                return;
            }

            _idleCheckWasBusy = waitingOnSocket;
            _idleCheckedBytes = transferredBytes;
            return;
        }
    }

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

    // On a reused connection the next request's first bytes usually arrived in the previous
    // request's final read. They are the ONLY thing carried across, and they can only ever be a
    // request line: reuse requires that the previous request had no body, so there are no
    // unconsumed body bytes that could be mistaken for one.
    if (_carryOverData.length > 0) {
        [headersData appendData:_carryOverData];
        _carryOverData = nil;
        // The next request is already in hand, so this connection is NOT idle and the keep-alive
        // reaper below must not judge it. Nothing else can clear the flag on this path: the idle
        // check clears it by noticing _totalBytesRead RISE, and a request served entirely from
        // carried-over bytes issues no read at all, because those bytes were counted against the
        // request before it. Left set, the reaper ran against a response that was still streaming
        // and cut the body off mid-transfer — under a Content-Length it then never reached.
        _awaitingNextRequest = NO;
        _headerPhaseTicks = 0;  // A fresh header-phase budget, exactly as the idle check hands out
    }
    [self readHeaders:headersData
        withCompletionBlock:^(NSData *extraData) {
            if (extraData) {
                // A header block arrived, so there is a new request to account for. Cleared HERE
                // rather than in -_resetForNextRequest because the reset runs whether or not
                // another request ever comes: a persistent connection whose client simply goes
                // away must leave the last real request marked as flushed, or -close logs a second
                // line for a request it has already reset away.
                self->_requestLogged = NO;
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
                self->_requestIsBodyless = _HeadersCarryNoBodyFraming(requestHeaders);
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
                            // byte of it is accepted — an unknown coding left in place stores
                            // the still-encoded octets as the entity under a success status.
                            // Same rule, and same reason, as an unsupported Transfer-Encoding.
                            if (![self->_request prepareForWriting]) {
                                self->_requestReceived = YES;  // Nothing further is read from this socket
                                [self _finishProcessingRequest:[WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_UnsupportedMediaType message:@"Unsupported 'Content-Encoding' header: %@", requestHeaders[@"Content-Encoding"]]];
                                return;
                            }

                            // Everything past the header block, trimmed to the body this request
                            // declared. More than that is not an error: a client may write its
                            // body and whatever follows it in one segment, and TCP is free to
                            // deliver the two in a single read regardless. Refusing it with 400
                            // made the verdict depend on how the client happened to split its
                            // writes — the split-dependence class this project has an oracle for
                            // — and it refused ordinary pipelining outright.
                            //
                            // The remainder is DROPPED, never interpreted. A request carrying body
                            // framing is not eligible for reuse, so this connection closes after
                            // it; that is what keeps "nothing can be framed by a length the next
                            // request disagrees about" structurally true rather than parsed-for.
                            NSData *bodyData = extraData;

                            if (!self->_request.usesChunkedTransferEncoding && (extraData.length > self->_request.contentLength)) {
                                bodyData = [extraData subdataWithRange:NSMakeRange(0, self->_request.contentLength)];
                            }

                            NSString *const expectHeader = requestHeaders[@"Expect"];

                            if (expectHeader && !self->_clientIsHTTP10) {
                                if ([expectHeader caseInsensitiveCompare:@"100-continue"] == NSOrderedSame) {  // TODO: Actually validate request before continuing
                                    [self writeData:_continueData
                                        withCompletionBlock:^(BOOL success) {
                                            if (success) {
                                                [self _readRequestBodyWithInitialData:bodyData];
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
                                [self _readRequestBodyWithInitialData:bodyData];
                            }
                        } else {
                            // No body to read, so anything past the header block belongs to the
                            // NEXT request. Held only when this connection may actually carry one;
                            // otherwise it is dropped exactly as it always was, which is what made
                            // "leftover bytes are never read" true.
                            if ((self->_keepAliveTimeout > 0.0) && self->_requestIsBodyless && (extraData.length > 0)) {
                                self->_carryOverData = [extraData mutableCopy];
                            }

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
                            // 501 says "this server does not implement that method". It was the
                            // answer for an unknown TARGET too, so a browser asking for
                            // /favicon.ico was told the server does not implement GET — and 501 is
                            // heuristically cacheable, so an intermediary may remember it for a
                            // path that later gains a handler. If some handler claims the method,
                            // the method is implemented and what is missing is the target: 404.
                            //
                            // 405 with Allow, which is what a KNOWN target with the wrong method
                            // owes, is deliberately not attempted: a handler is an opaque match
                            // block, so the server cannot ask which methods a path accepts without
                            // changing the registration model. Guessing it would be worse.
                            NSInteger unmatchedStatus = kWSKHTTPStatusCode_NotImplemented;

                            if ([self->_registeredMethods containsObject:requestMethod]) {
                                unmatchedStatus = kWSKHTTPStatusCode_NotFound;
                            }

                            [self abortRequest:self->_request withStatusCode:unmatchedStatus];
                        } else {
                            // The base request rejected these headers too — a framing conflict
                            // such as "Content-Length" together with a chunked "Transfer-Encoding"
                            // — so no handler could have matched, and must not assert. One shape
                            // in this branch owes a different status: a Transfer-Encoding naming
                            // a coding this server does not implement is a WELL-FORMED request
                            // the server cannot decode, and RFC 9112 §6.1 assigns that 501 —
                            // answering 400 told the client its message was broken when it was
                            // not. A malformed application of a coding the server DOES implement
                            // ("chunked, chunked", Content-Length alongside chunked) stays 400.
                            NSString *const transferEncodingHeader = _HeaderValueForName(requestHeaders, @"Transfer-Encoding");
                            NSInteger status = kWSKHTTPStatusCode_BadRequest;

                            if ((transferEncodingHeader != nil) && WSKTransferEncodingIsUnsupported(transferEncodingHeader)) {
                                status = kWSKHTTPStatusCode_NotImplemented;
                            }

                            WSK_LOG_ERROR(@"Rejecting malformed request headers on socket %i", self->_socket);
                            [self abortRequest:nil withStatusCode:status];
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
            } else if (self->_awaitingNextRequest && (self->_totalBytesRead == self->_readBytesWhenIdleBegan)) {
                // A persistent connection whose client went away without beginning another
                // request. That is how one is SUPPOSED to end — there is no request to refuse,
                // and nobody left to read an answer — so it unwinds silently, with no ERROR
                // line and no fabricated 500 into a socket that is already gone.
                WSK_LOG_DEBUG(@"Client closed idle keep-alive connection on socket %i", self->_socket);
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
        _registeredMethods = server.registeredMethods;
        _localAddressData = localAddress;
        _remoteAddressData = remoteAddress;
        _socket = socket;
        _connectionQueue = dispatch_queue_create("gcdwebserver.connection", DISPATCH_QUEUE_SERIAL);
        _headerFailureStatus = kWSKHTTPStatusCode_InternalServerError;
        _bodyFailureStatus = kWSKHTTPStatusCode_InternalServerError;
        WSK_LOG_DEBUG(@"Did open connection on socket %i", _socket);

        _keepAliveTimeout = server.connectionKeepAliveTimeout;
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
                    if (self->_awaitingNextRequest) {
                        // The designed end of a persistent connection, not a failure: the client
                        // finished with it and closed. Logging that at ERROR made every correct
                        // keep-alive client look like a fault.
                        WSK_LOG_DEBUG(@"Client closed idle keep-alive connection on socket %i", self->_socket);
                    } else if (self->_totalBytesRead > 0) {
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

// method SP request-target SP HTTP-version, with no room for interpretation. Without
// this a request line is split on the first two spaces and whatever remains becomes part
// of the path: "GET /a HTTP/1.1 junk" was dispatched with a path of "/a HTTP/1.1".
//
// Returns 0 for a valid line, otherwise the status to refuse with: 400 for a grammar
// violation, and 505 for a well-formed HTTP-version whose MAJOR this server does not
// implement (RFC 9112 §2.3 — refusing those with 400 claimed the message was malformed
// when it was not). A higher MINOR within HTTP/1 is not refused at all: RFC 9110 §2.5
// says to process it as the highest minor version this server is conformant to, so the
// version byte is rewritten to '1' in place — the line is exactly what CFHTTPMessage
// parses next, so patching it here IS the "process as 1.1" the RFC asks for, and
// _clientIsHTTP10 then correctly reads such a client as 1.1-capable.
static NSInteger _ValidateRequestLine(unsigned char *line, NSUInteger length, BOOL *outAbsoluteFormTarget) {
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
            return kWSKHTTPStatusCode_BadRequest;  // A CTL or stray whitespace inside the method, target or version
        }
    }

    if ((spaceCount != 2) || (firstSpace == 0) || (lastSpace <= firstSpace + 1)) {
        return kWSKHTTPStatusCode_BadRequest;  // Wrong shape, empty method, or empty request-target
    }

    // Report the request-target's form off the RAW line: anything that is not origin-form
    // ("/...") or asterisk-form ("*") carries its own authority (RFC 9112 §3.2). This cannot be
    // derived from the parsed URL downstream, because CFHTTPMessageCopyRequestURL synthesizes an
    // absolute URL FROM the Host header for origin-form requests — by then "the target carried
    // an authority" and "the Host header carried one" are indistinguishable, and CF has already
    // sanitized the value the syntax rules need to judge raw.
    *outAbsoluteFormTarget = (line[firstSpace + 1] != '/') &&
                             !((lastSpace - firstSpace == 2) && (line[firstSpace + 1] == '*'));

    for (NSUInteger i = 0; i < firstSpace; i++) {
        if (!WSKIsHeaderTokenCharacter(line[i])) {
            return kWSKHTTPStatusCode_BadRequest;
        }
    }

    // A '#' in the request-target is not a fragment to be discarded, it is a malformed target:
    // RFC 9110 §7.1 says the fragment is not part of the request target at all. CFURLCopyPath()
    // honours it as a delimiter and hands back only the prefix, and every verb then executes
    // against that prefix — `PUT /ci/MyApp#42.ipa` writes to `/ci/MyApp`, `DELETE /D1/#nope`
    // destroys `/D1`. Truncating does not make the request mean what the client wrote.
    //
    // Checked on the raw wire bytes, ahead of any CF parsing, so a -rewriteRequestURL: subclass
    // cannot route around it. "%23" still addresses a '#'-bearing filename correctly and must
    // keep working — that is the case a naive fix breaks.
    for (NSUInteger i = firstSpace + 1; i < lastSpace; i++) {
        if (line[i] == '#') {
            return kWSKHTTPStatusCode_BadRequest;
        }
    }

    NSUInteger const versionLength = length - lastSpace - 1;
    unsigned char *const version = line + lastSpace + 1;

    // The grammar is exactly HTTP-name "/" DIGIT "." DIGIT (RFC 9112 §2.3); anything else —
    // "http/1.1", "HTTP/1.x", a ten-byte "HTTP/12.1" — is malformed, not merely unsupported.
    if ((versionLength != 8) || (memcmp(version, "HTTP/", 5) != 0) ||
        (version[5] < '0') || (version[5] > '9') || (version[6] != '.') ||
        (version[7] < '0') || (version[7] > '9')) {
        return kWSKHTTPStatusCode_BadRequest;
    }

    if (version[5] != '1') {
        return kWSKHTTPStatusCode_HTTPVersionNotSupported;  // HTTP/2.0, HTTP/0.9, ...
    }

    if (version[7] > '1') {
        version[7] = '1';  // HTTP/1.2 through 1.9: process as HTTP/1.1 (RFC 9110 §2.5)
    }

    return 0;
}

// The header block is FRAMED here by scanning for CRLFCRLF but PARSED by CFHTTPMessage, which ends
// a message at a bare LF-LF. Where the two disagreed, every header in between was silently
// discarded and the request still succeeded — the server acting on a different message than the
// client sent. Rather than reconcile two scanners, require unambiguous framing: every CR paired
// with an LF, no obs-fold. The rest is field syntax CFHTTPMessage accepts far too leniently
// ("Content-Length : 5" and a folded "Content-Length:\r\n 5" both yielded a length), and those
// fields decide how many bytes reach the disk.
//
// Returns 0 for a valid block, else the refusal status (400, or 505 from the request-line check).
// *outRequestLineOffset skips the empty lines RFC 9112 §2.2 ignores ahead of the request line. The
// buffer is mutable because the request-line check rewrites a higher HTTP/1.x minor to 1.1 in place.
static NSInteger _ValidateRequestHeaderBlock(void *rawBytes, NSUInteger length, NSUInteger *outRequestLineOffset, BOOL *outAbsoluteFormTarget) {
    unsigned char *const bytes = (unsigned char *)rawBytes;
    *outRequestLineOffset = 0;
    *outAbsoluteFormTarget = NO;

    for (NSUInteger i = 0; i < length; i++) {
        if (bytes[i] == '\r') {
            if ((i + 1 >= length) || (bytes[i + 1] != '\n')) {
                return kWSKHTTPStatusCode_BadRequest;
            }
        } else if (bytes[i] == '\n') {
            if ((i == 0) || (bytes[i - 1] != '\r')) {
                return kWSKHTTPStatusCode_BadRequest;
            }
        } else if (((bytes[i] < 0x20) && (bytes[i] != '\t')) || (bytes[i] == 0x7F)) {
            // RFC 9110 §5.5: CR, LF or NUL in a field value must be rejected or replaced with
            // SP, and every other C0 control (plus DEL) is illegal field content outright.
            // Bare CR and LF are handled by the pairing checks above; this closes the rest —
            // the NUL was measured sailing through into request.headers, the exact byte whose
            // consumers each needed individual hardening. HTAB is legal in a value, and
            // obs-text (0x80-0xFF) is untouched: this refuses controls, it is not an ASCII
            // allow-list.
            return kWSKHTTPStatusCode_BadRequest;
        }
    }

    BOOL expectingRequestLine = YES;
    NSUInteger hostLineCount = 0;
    NSUInteger lineStart = 0;

    for (NSUInteger i = 0; i + 1 < length; i++) {
        if ((bytes[i] != '\r') || (bytes[i + 1] != '\n')) {
            continue;
        }

        unsigned char *const line = bytes + lineStart;
        NSUInteger const lineLength = i - lineStart;

        if (lineLength == 0) {
            if (expectingRequestLine) {
                // RFC 9112 §2.2: ignore empty lines received ahead of the request-line.
                *outRequestLineOffset = i + 2;
                lineStart = i + 2;
                i += 1;
                continue;
            }

            break;  // The empty line terminates the block
        }

        if (expectingRequestLine) {
            NSInteger const requestLineStatus = _ValidateRequestLine(line, lineLength, outAbsoluteFormTarget);

            if (requestLineStatus != 0) {
                return requestLineStatus;
            }

            expectingRequestLine = NO;
        } else {
            if ((line[0] == ' ') || (line[0] == '\t')) {
                return kWSKHTTPStatusCode_BadRequest;  // obs-fold continuation line
            }

            NSUInteger colon = NSNotFound;

            for (NSUInteger j = 0; j < lineLength; j++) {
                if (line[j] == ':') {
                    colon = j;
                    break;
                }
            }

            if ((colon == NSNotFound) || (colon == 0)) {
                return kWSKHTTPStatusCode_BadRequest;  // No field name, or no colon at all
            }

            for (NSUInteger j = 0; j < colon; j++) {
                if (!WSKIsHeaderTokenCharacter(line[j])) {
                    return kWSKHTTPStatusCode_BadRequest;  // Includes whitespace before the colon
                }
            }

            // RFC 9112 §3.2: more than one Host header line MUST answer 400. Counted here on
            // the raw lines because CFHTTPMessage merges duplicates into one comma-joined
            // value, after which "two Host lines" and "one strange Host" are indistinguishable
            // — and a comma is legal inside a reg-name, so the merged spelling cannot simply
            // be refused downstream by syntax.
            if ((colon == 4) &&
                ((line[0] == 'H') || (line[0] == 'h')) && ((line[1] == 'O') || (line[1] == 'o')) &&
                ((line[2] == 'S') || (line[2] == 's')) && ((line[3] == 'T') || (line[3] == 't'))) {
                hostLineCount += 1;

                if (hostLineCount > 1) {
                    return kWSKHTTPStatusCode_BadRequest;
                }
            }
        }

        lineStart = i + 2;
        i += 1;  // Skip the LF we just consumed
    }

    return expectingRequestLine ? kWSKHTTPStatusCode_BadRequest : 0;
}

typedef NS_ENUM(NSInteger, WSKHeaderBlockState) {
    kWSKHeaderBlockIncomplete = 0,  // More bytes needed
    kWSKHeaderBlockComplete,        // Parsed; anything past the terminator is returned as extra data
    kWSKHeaderBlockFailed,          // Malformed or oversized; _headerFailureStatus says which
};

// Which refusal does an over-cap header block owe? 431 covers an oversized BLOCK, but when no line
// terminator has arrived anywhere inside the block budget, what overflowed is the request LINE —
// a request-target longer than the server will parse, which RFC 9110 §15.5.15 assigns 414. (A
// target that fits the block but exceeds PATH_MAX parses fine and 404s later from the resolvers.)
static NSInteger _StatusForOversizedHeaderBlock(NSData *headersData) {
    NSUInteger const scanLength = MIN(headersData.length, (NSUInteger)kHeadersMaxLength);
    NSRange const lineEnd = [headersData rangeOfData:_CRLFData options:(NSDataSearchOptions)0 range:NSMakeRange(0, scanLength)];
    return (lineEnd.location == NSNotFound) ? kWSKHTTPStatusCode_RequestURITooLong
                                            : kWSKHTTPStatusCode_RequestHeaderFieldsTooLarge;
}

// Decides on what is ALREADY buffered without calling the completion block — the caller owns that,
// so it fires exactly once on every path. (Folding the two together made the block's invocation
// correlate with a return value the analyzer cannot relate; it reported both "never called" and
// "called twice" in the same function.)
//
// Separate from -readHeaders: because a reused connection starts with the next request's bytes
// already in the buffer, left by the previous read. Going straight to dispatch_read then waits for
// bytes the client has no reason to send — it has a complete request outstanding and is waiting on
// us — which hangs until the idle timeout.
- (WSKHeaderBlockState)_settleHeadersFromBuffer:(NSMutableData *)headersData extraData:(NSData *_Nullable *_Nonnull)outExtraData {
    NSRange range = [headersData rangeOfData:_CRLFCRLFData options:0 range:NSMakeRange(0, headersData.length)];

    if (range.location == NSNotFound) {
        if (headersData.length > kHeadersMaxLength) {
            WSK_LOG_ERROR(@"Request headers exceeded %i bytes on socket %i", (int)kHeadersMaxLength, _socket);
            _headerFailureStatus = _StatusForOversizedHeaderBlock(headersData);
            return kWSKHeaderBlockFailed;
        }

        return kWSKHeaderBlockIncomplete;
    }

    NSUInteger const length = range.location + range.length;

    // The cap applies to the BLOCK, not the buffer: enforced only while waiting for the
    // terminator (the branch above), an oversized block sent in one burst is found, parsed and
    // served. The buffer legitimately runs past the cap once body bytes arrive in the same read.
    if (length > kHeadersMaxLength) {
        WSK_LOG_ERROR(@"Request headers exceeded %i bytes on socket %i", (int)kHeadersMaxLength, _socket);
        _headerFailureStatus = _StatusForOversizedHeaderBlock(headersData);
        return kWSKHeaderBlockFailed;
    }

    NSUInteger requestLineOffset = 0;
    BOOL absoluteFormTarget = NO;
    NSInteger const invalidStatus = _ValidateRequestHeaderBlock(headersData.mutableBytes, length, &requestLineOffset, &absoluteFormTarget);

    if (invalidStatus != 0) {
        WSK_LOG_ERROR(@"Rejecting malformed request line or header syntax on socket %i", _socket);
        _headerFailureStatus = invalidStatus;
        return kWSKHeaderBlockFailed;
    }

    _requestTargetIsAbsoluteForm = absoluteFormTarget;

    // Append from the request line onward: CFHTTPMessage is not owed the leading empty lines
    // the validator just skipped, and the extra-data split below still uses the ORIGINAL
    // buffer offsets, so nothing downstream shifts.
    if (!CFHTTPMessageAppendBytes(_requestMessage, (const UInt8 *)headersData.bytes + requestLineOffset, length - requestLineOffset)) {
        WSK_LOG_ERROR(@"Failed appending request headers data from socket %i", _socket);
        _headerFailureStatus = kWSKHTTPStatusCode_BadRequest;
        return kWSKHeaderBlockFailed;
    }

    if (!CFHTTPMessageIsHeaderComplete(_requestMessage)) {
        WSK_LOG_ERROR(@"Failed parsing request headers from socket %i", _socket);
        _headerFailureStatus = kWSKHTTPStatusCode_BadRequest;
        return kWSKHeaderBlockFailed;
    }

    *outExtraData = [headersData subdataWithRange:NSMakeRange(length, headersData.length - length)];
    return kWSKHeaderBlockComplete;
}

- (void)readHeaders:(NSMutableData *)headersData withCompletionBlock:(ReadHeadersCompletionBlock)block {
    WSK_DCHECK(_requestMessage);
    NSData *bufferedExtraData = nil;
    WSKHeaderBlockState const buffered = [self _settleHeadersFromBuffer:headersData extraData:&bufferedExtraData];

    if (buffered == kWSKHeaderBlockComplete) {
        block(bufferedExtraData);
        return;
    }

    if (buffered == kWSKHeaderBlockFailed) {
        block(nil);
        return;
    }

    [self readData:headersData
             withLength:NSUIntegerMax
        completionBlock:^(BOOL success) {
            if (!success) {
                block(nil);
                return;
            }

            NSData *extraData = nil;
            WSKHeaderBlockState const state = [self _settleHeadersFromBuffer:headersData extraData:&extraData];

            if (state == kWSKHeaderBlockComplete) {
                block(extraData);
            } else if (state == kWSKHeaderBlockFailed) {
                block(nil);
            } else {
                [self readHeaders:headersData withCompletionBlock:block];
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
                        [self _noteBodyFailure:error];
                        block(NO);
                    }
                } else {
                    WSK_LOG_ERROR(@"Unexpected extra content reading request body on socket %i", self->_socket);
                    self->_bodyFailureStatus = kWSKHTTPStatusCode_BadRequest;
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
                    _bodyFailureStatus = kWSKHTTPStatusCode_RequestEntityTooLarge;
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
                        [self _noteBodyFailure:error];
                        block(NO);
                        return;
                    }
                } else {
                    WSK_LOG_ERROR(@"Missing terminating CRLF sequence for chunk reading request body on socket %i", _socket);
                    _bodyFailureStatus = kWSKHTTPStatusCode_BadRequest;
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
            _bodyFailureStatus = kWSKHTTPStatusCode_BadRequest;
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
        _bodyFailureStatus = kWSKHTTPStatusCode_RequestEntityTooLarge;
        block(NO);
        return;
    }

    // That cap is per-connection, and per-connection caps do not compose: with the
    // connection limit it allowed gigabytes in aggregate. Charge this buffer against the
    // process-wide ceiling too, and give bytes back as the parser drains them.
    if (![_chunkReservation reserveBytes:chunkData.length]) {
        WSK_LOG_ERROR(@"Refusing chunked body on socket %i: the server is already holding its %lu byte in-memory limit across all connections", _socket, (unsigned long)kWSKMaxTotalInMemoryLength);
        _bodyFailureStatus = kWSKHTTPStatusCode_ServiceUnavailable;
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
// present. Evaluating the date first lets a revalidation carrying a *stale* ETag still get
// a 304 whenever the replacement's mtime is not strictly newer — and per RFC 9111 §4.3.4
// the client updates its stored headers from that 304, so it holds the old body under the
// new ETag and every later revalidation matches too: the stale copy is pinned indefinitely,
// which is precisely what the ETag exists to prevent.
static inline BOOL _CompareResources(NSString *responseETag, NSString *requestETag, NSDate *responseLastModified, NSDate *requestLastModified) {
    if (requestETag) {
        if (!responseETag) {
            return NO;
        }

        return [requestETag isEqualToString:@"*"] || _ETagMatchesIfNoneMatch(responseETag, requestETag);
    }

    // EXACT equality, not "not newer". Answering 304 for an equal-or-OLDER mtime pins a date-only
    // client on stale bytes permanently: restore a previous build (rsync -a, cp -p, touch -t) and
    // the client is told 304, keeps its body, and per RFC 9111 §4.3.4 adopts the CURRENT validators
    // from that 304 — so its next revalidation matches on the ETag too and nothing dislodges it. It
    // also answered 304 for a future If-Modified-Since, i.e. a resource the client cannot hold.
    //
    // Safe to tighten only because _NSDateFromTimeSpec truncates Last-Modified to whole seconds and
    // WSKParseRFC822 parses at the same precision, so a client echoing back what it was given still
    // compares equal. Matches nginx's default ("if_modified_since exact").
    if (requestLastModified && responseLastModified) {
        return [responseLastModified compare:requestLastModified] == NSOrderedSame;
    }

    return NO;
}

- (WSKResponse *)overrideResponse:(WSKResponse *)response forRequest:(WSKRequest *)request {
    // RFC 9110 §13.2.1: If-Match and If-Unmodified-Since apply to EVERY method, and a false
    // condition owes 412 — on a GET as much as on a PUT. The write verbs evaluate them in
    // WSKWebDAVServer BEFORE acting, and their success responses carry no entity tag, which is
    // why this site is gated to the read methods: re-judging a 204 whose precondition already
    // held would turn every conditional write into a 412. Only a 2xx is judged (§13.2.1 says to
    // ignore preconditions when the unconditional response would be an error anyway), and the
    // order is §13.2.2: If-Match, then If-Unmodified-Since in its absence, both ahead of the
    // If-None-Match / If-Modified-Since pair below. The failure this closes was safe-direction —
    // the current representation was served to a client asking for exactly-that-representation —
    // but "the server ignored my precondition" is still the wrong answer to give.
    if ((response.statusCode >= 200) && (response.statusCode < 300) &&
        ([request.method isEqualToString:@"GET"] || [request.method isEqualToString:@"HEAD"])) {
        NSString *const ifMatch = request.headers[@"If-Match"];
        NSString *const ifUnmodifiedSince = request.headers[@"If-Unmodified-Since"];

        if (ifMatch != nil) {
            // A 2xx read IS a current representation, so "*" holds here by construction.
            if (!WSKEntityTagMatchesList(YES, response.eTag, ifMatch, YES)) {
                return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_PreconditionFailed message:@"\"If-Match\" precondition failed for \"%@\"", request.path];
            }
        } else if (ifUnmodifiedSince != nil) {
            NSDate *const limit = WSKParseRFC822(ifUnmodifiedSince);
            NSDate *const lastModified = response.lastModifiedDate;

            // An unparseable date is ignored (RFC 9110 §13.1.4), and so is a response without a
            // modification date — which includes one the timestamp seal is deliberately
            // withholding: inside the bucket a date cannot distinguish two representations, so
            // it cannot be allowed to refuse one either.
            if ((limit != nil) && (lastModified != nil) &&
                (floor(lastModified.timeIntervalSince1970) > floor(limit.timeIntervalSince1970))) {
                return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_PreconditionFailed message:@"\"If-Unmodified-Since\" precondition failed for \"%@\"", request.path];
            }
        }
    }

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

// One request's worth of bookkeeping: move its recording into place and write its access-log line.
// Split out of -close, which is a once-per-CONNECTION hook, because a reused connection owes one of
// these per REQUEST — and the last request on such a connection reaches only -close.
- (void)_flushRequestRecordAndLog {
    _requestLogged = YES;  // Cleared when the next request's header block arrives, so -close cannot double-log
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

- (void)close {
    // The connection is ending. Only the request still un-flushed is owed anything here: on a
    // reused connection every earlier one was flushed as its response completed, and flushing again
    // would log a second, emptied-out line for a request that has already been reset away.
    if (!_requestLogged) {
        [self _flushRequestRecordAndLog];
    }
}

@end
