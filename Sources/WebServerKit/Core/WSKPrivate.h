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

#import <os/object.h>
#import <sys/socket.h>

/**
 *  All WSKWebServer headers.
 */

#if __has_include(<WebServerKit/WSKWebServer.h>)
#import <WebServerKit/WSKWebServer.h>
#import <WebServerKit/WSKConnection.h>
#import <WebServerKit/WSKDataRequest.h>
#import <WebServerKit/WSKDataResponse.h>
#import <WebServerKit/WSKErrorResponse.h>
#import <WebServerKit/WSKFileRequest.h>
#import <WebServerKit/WSKFileResponse.h>
#import <WebServerKit/WSKFunctions.h>
#import <WebServerKit/WSKHTTPStatusCodes.h>
#import <WebServerKit/WSKMultiPartFormRequest.h>
#import <WebServerKit/WSKStreamedResponse.h>
#import <WebServerKit/WSKURLEncodedFormRequest.h>
#else
#import "WSKWebServer.h"
#import "WSKConnection.h"
#import "WSKDataRequest.h"
#import "WSKDataResponse.h"
#import "WSKErrorResponse.h"
#import "WSKFileRequest.h"
#import "WSKFileResponse.h"
#import "WSKFunctions.h"
#import "WSKHTTPStatusCodes.h"
#import "WSKMultiPartFormRequest.h"
#import "WSKStreamedResponse.h"
#import "WSKURLEncodedFormRequest.h"
#endif

/**
 *  Upper bounds on how much request data may be held in memory at once, to keep
 *  a malicious or broken client from exhausting memory on a constrained device.
 *  These cap in-memory buffering only; bodies streamed to disk (uploaded files,
 *  WebDAV PUT) are not limited by these. Like kHeadersMaxLength and
 *  kWSKMaxConnections, they are fixed safety limits, not options.
 *
 *  kWSKMaxInMemoryBodyLength bounds any single in-memory body buffer
 *  (a data request body, a multipart argument part or the parser's working
 *  buffer, a single chunked-transfer chunk). kWSKMaxDecompressedBodyLength
 *  bounds the total output a gzip-encoded request body may inflate to.
 */
#define kWSKMaxInMemoryBodyLength (16 * 1024 * 1024)
#define kWSKMaxDecompressedBodyLength (64 * 1024 * 1024)

/**
 *  Ceiling on request data held in memory across *all* live connections at once.
 *
 *  The two limits above are per-request, and they do not compose: with
 *  kWSKMaxConnections concurrent requests the real ceiling was their product —
 *  around 2 GB of chunked framing buffers, or 8 GB of inflated gzip output — many times
 *  what any phone survives. Each per-request limit still applies; this bounds the sum.
 *
 *  Sized so that legitimate traffic never approaches it: real uploads stream to disk and
 *  hold only a read-sized buffer in memory, so only a client deliberately parking large
 *  in-memory bodies gets close.
 */
#define kWSKMaxTotalInMemoryLength (64 * 1024 * 1024)

/**
 *  Check if a custom logging facility should be used instead.
 */

#if defined(__WEBSERVERKIT_LOGGING_HEADER__)

#define __WEBSERVERKIT_LOGGING_FACILITY_CUSTOM__

#import __WEBSERVERKIT_LOGGING_HEADER__

/**
 *  Automatically detect if XLFacility is available and if so use it as a
 *  logging facility.
 */

#elif defined(__has_include) && __has_include("XLFacilityMacros.h")

#define __WEBSERVERKIT_LOGGING_FACILITY_XLFACILITY__

#undef XLOG_TAG
#define XLOG_TAG @"gcdwebserver.internal"

#import "XLFacilityMacros.h"

#define WSK_LOG_DEBUG(...) XLOG_DEBUG(__VA_ARGS__)
#define WSK_LOG_VERBOSE(...) XLOG_VERBOSE(__VA_ARGS__)
#define WSK_LOG_INFO(...) XLOG_INFO(__VA_ARGS__)
#define WSK_LOG_WARNING(...) XLOG_WARNING(__VA_ARGS__)
#define WSK_LOG_ERROR(...) XLOG_ERROR(__VA_ARGS__)

#define WSK_DCHECK(__CONDITION__) XLOG_DEBUG_CHECK(__CONDITION__)
#define WSK_DNOT_REACHED() XLOG_DEBUG_UNREACHABLE()

/**
 *  If all of the above fail, then use WSKWebServer built-in
 *  logging facility.
 */

#else /* if defined(__WEBSERVERKIT_LOGGING_HEADER__) */

#define __WEBSERVERKIT_LOGGING_FACILITY_BUILTIN__

typedef NS_ENUM(int, WSKLoggingLevel) {
    kWSKLoggingLevel_Debug = 0,
    kWSKLoggingLevel_Verbose,
    kWSKLoggingLevel_Info,
    kWSKLoggingLevel_Warning,
    kWSKLoggingLevel_Error
};

extern WSKLoggingLevel WSKLogLevel;
extern void WSKLogMessage(WSKLoggingLevel level, NSString *_Nonnull format, ...) NS_FORMAT_FUNCTION(2, 3);

#if DEBUG
#define WSK_LOG_DEBUG(...)                                                                                                                 \
    do {                                                                                                                                   \
        if (WSKLogLevel <= kWSKLoggingLevel_Debug) WSKLogMessage(kWSKLoggingLevel_Debug, __VA_ARGS__); \
    } while (0)
#else
#define WSK_LOG_DEBUG(...)
#endif
#define WSK_LOG_VERBOSE(...)                                                                                                                   \
    do {                                                                                                                                       \
        if (WSKLogLevel <= kWSKLoggingLevel_Verbose) WSKLogMessage(kWSKLoggingLevel_Verbose, __VA_ARGS__); \
    } while (0)
#define WSK_LOG_INFO(...)                                                                                                                \
    do {                                                                                                                                 \
        if (WSKLogLevel <= kWSKLoggingLevel_Info) WSKLogMessage(kWSKLoggingLevel_Info, __VA_ARGS__); \
    } while (0)
#define WSK_LOG_WARNING(...)                                                                                                                   \
    do {                                                                                                                                       \
        if (WSKLogLevel <= kWSKLoggingLevel_Warning) WSKLogMessage(kWSKLoggingLevel_Warning, __VA_ARGS__); \
    } while (0)
#define WSK_LOG_ERROR(...)                                                                                                                 \
    do {                                                                                                                                   \
        if (WSKLogLevel <= kWSKLoggingLevel_Error) WSKLogMessage(kWSKLoggingLevel_Error, __VA_ARGS__); \
    } while (0)

#endif /* if defined(__WEBSERVERKIT_LOGGING_HEADER__) */

/**
 *  Consistency check macros used when building Debug only.
 */

#if !defined(WSK_DCHECK) || !defined(WSK_DNOT_REACHED)

#if DEBUG

#define WSK_DCHECK(__CONDITION__) \
    do {                          \
        if (!(__CONDITION__)) {   \
            abort();              \
        }                         \
    } while (0)
#define WSK_DNOT_REACHED() abort()

#else

#define WSK_DCHECK(__CONDITION__)
#define WSK_DNOT_REACHED()

#endif

#endif

NS_ASSUME_NONNULL_BEGIN

/**
 *  WSKWebServer internal constants and APIs.
 */

#define kWSKDefaultMimeType @"application/octet-stream"

// The value of the "Server" response header. Deliberately a constant rather than the class
// name: it is observable output, so tying it to an identifier means a refactor changes the
// wire format and breaks every recorded trace that asserts it.
#define kWSKServerName @"WebServerKit"
#define kWSKErrorDomain @"WSKErrorDomain"

static inline BOOL WSKIsValidByteRange(NSRange range) {
    return ((range.location != NSUIntegerMax) || (range.length > 0));
}

static inline NSError *WSKMakePosixError(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: (NSString *)[NSString stringWithUTF8String:strerror(code)]}];
}

/**
 *  A share of the process-wide in-memory ceiling, held by whatever is doing the buffering.
 *
 *  Deliberately an object: the bytes are returned in -dealloc, so a connection that dies
 *  mid-body — dropped, reset, timed out — cannot leak budget and permanently shrink what
 *  the server can serve afterwards. A holder resizes its reservation as its buffer grows.
 */
@interface WSKMemoryReservation : NSObject

/**
 *  Resizes this reservation. Returns NO when the process-wide ceiling would be exceeded,
 *  leaving the existing reservation untouched so the caller can fail the request cleanly.
 *  Shrinking always succeeds.
 */
- (BOOL)reserveBytes:(NSUInteger)bytes;

@end

/**
 *  Current limits. These read the testing overrides below, so consult them rather than the
 *  kWSK... constants directly.
 */
extern NSUInteger WSKMaxInMemoryBodyLength(void);
extern NSUInteger WSKMaxDecompressedBodyLength(void);

/**
 *  Shrinks the limits so a test can prove a bound is enforced without moving tens of
 *  megabytes through the server — which is slow, and under AddressSanitizer is itself
 *  enough to lose the test runner. Pass 0 for either to restore its default.
 */
extern void WSKSetMemoryLimitsForTesting(NSUInteger perRequest, NSUInteger decompressed, NSUInteger total);

/**
 *  Bytes currently reserved across all live reservations. For tests and diagnostics.
 */
extern NSUInteger WSKReservedMemoryLength(void);

extern void WSKInitializeFunctions(void);
extern NSString *_Nullable WSKNormalizeHeaderValue(NSString *_Nullable value);
extern NSString *_Nullable WSKTruncateHeaderValue(NSString *_Nullable value);
extern NSString *_Nullable WSKExtractHeaderValueParameter(NSString *_Nullable value, NSString *attribute);
extern NSStringEncoding WSKStringEncodingFromCharset(NSString *charset);
extern BOOL WSKIsTextContentType(NSString *type);
extern NSString *WSKDescribeData(NSData *data, NSString *contentType);
extern NSString *WSKComputeMD5Digest(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
extern NSString *WSKStringFromSockAddr(const struct sockaddr *addr, BOOL includeService);

@interface WSKConnection ()
- (instancetype)initWithServer:(WSKWebServer *)server localAddress:(NSData *)localAddress remoteAddress:(NSData *)remoteAddress socket:(CFSocketNativeHandle)socket;
@end

@interface WSKWebServer ()
@property (nonatomic, readonly) NSMutableArray<WSKHandler *> *handlers;
@property (nonatomic, readonly, nullable) NSString *serverName;
@property (nonatomic, readonly, nullable) NSSet<NSString *> *allowedHostNames;
@property (nonatomic, readonly, nullable) NSString *authenticationRealm;
@property (nonatomic, readonly, nullable) NSMutableDictionary<NSString *, NSString *> *authenticationBasicAccounts;
@property (nonatomic, readonly, nullable) NSMutableDictionary<NSString *, NSString *> *authenticationDigestAccounts;
@property (nonatomic, readonly) BOOL shouldAutomaticallyMapHEADToGET;
@property (nonatomic, readonly) dispatch_queue_priority_t dispatchQueuePriority;
@property (nonatomic, readonly) NSTimeInterval connectionIdleTimeout;
- (void)willStartConnection:(WSKConnection *)connection;
- (void)didEndConnection:(WSKConnection *)connection;
@end

@interface WSKHandler : NSObject
@property (nonatomic, readonly) WSKMatchBlock matchBlock;
@property (nonatomic, readonly) WSKAsyncProcessBlock asyncProcessBlock;
@end

@interface WSKRequest ()
@property (nonatomic, readonly) BOOL usesChunkedTransferEncoding;
@property (nonatomic, getter=isVirtualHEAD) BOOL virtualHEAD;
@property (nonatomic) NSData *localAddressData;
@property (nonatomic) NSData *remoteAddressData;
- (void)prepareForWriting;
- (BOOL)performOpen:(NSError **)error;
- (BOOL)performWriteData:(NSData *)data error:(NSError **)error;
- (BOOL)performClose:(NSError **)error;
- (void)setAttribute:(nullable id)attribute forKey:(NSString *)key;
@end

@interface WSKResponse ()
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *additionalHeaders;
@property (nonatomic, readonly) BOOL usesChunkedTransferEncoding;
- (void)prepareForReading;
- (BOOL)performOpen:(NSError **)error;
- (void)performReadDataWithCompletion:(WSKBodyReaderCompletionBlock)block;
- (void)performClose;
@end

NS_ASSUME_NONNULL_END
