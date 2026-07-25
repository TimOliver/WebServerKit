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
 *  All GCDWebServer headers.
 */

#if __has_include(<GCDWebServers/GCDWebServer.h>)
#import <GCDWebServers/GCDWebServer.h>
#import <GCDWebServers/GCDWebServerConnection.h>
#import <GCDWebServers/GCDWebServerDataRequest.h>
#import <GCDWebServers/GCDWebServerDataResponse.h>
#import <GCDWebServers/GCDWebServerErrorResponse.h>
#import <GCDWebServers/GCDWebServerFileRequest.h>
#import <GCDWebServers/GCDWebServerFileResponse.h>
#import <GCDWebServers/GCDWebServerFunctions.h>
#import <GCDWebServers/GCDWebServerHTTPStatusCodes.h>
#import <GCDWebServers/GCDWebServerMultiPartFormRequest.h>
#import <GCDWebServers/GCDWebServerStreamedResponse.h>
#import <GCDWebServers/GCDWebServerURLEncodedFormRequest.h>
#else
#import "GCDWebServer.h"
#import "GCDWebServerConnection.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerErrorResponse.h"
#import "GCDWebServerFileRequest.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerFunctions.h"
#import "GCDWebServerHTTPStatusCodes.h"
#import "GCDWebServerMultiPartFormRequest.h"
#import "GCDWebServerStreamedResponse.h"
#import "GCDWebServerURLEncodedFormRequest.h"
#endif

/**
 *  Upper bounds on how much request data may be held in memory at once, to keep
 *  a malicious or broken client from exhausting memory on a constrained device.
 *  These cap in-memory buffering only; bodies streamed to disk (uploaded files,
 *  WebDAV PUT) are not limited by these. Like kHeadersMaxLength and
 *  kGCDWebServerMaxConnections, they are fixed safety limits, not options.
 *
 *  kGCDWebServerMaxInMemoryBodyLength bounds any single in-memory body buffer
 *  (a data request body, a multipart argument part or the parser's working
 *  buffer, a single chunked-transfer chunk). kGCDWebServerMaxDecompressedBodyLength
 *  bounds the total output a gzip-encoded request body may inflate to.
 */
#define kGCDWebServerMaxInMemoryBodyLength (16 * 1024 * 1024)
#define kGCDWebServerMaxDecompressedBodyLength (64 * 1024 * 1024)

/**
 *  Ceiling on request data held in memory across *all* live connections at once.
 *
 *  The two limits above are per-request, and they do not compose: with
 *  kGCDWebServerMaxConnections concurrent requests the real ceiling was their product —
 *  around 2 GB of chunked framing buffers, or 8 GB of inflated gzip output — many times
 *  what any phone survives. Each per-request limit still applies; this bounds the sum.
 *
 *  Sized so that legitimate traffic never approaches it: real uploads stream to disk and
 *  hold only a read-sized buffer in memory, so only a client deliberately parking large
 *  in-memory bodies gets close.
 */
#define kGCDWebServerMaxTotalInMemoryLength (64 * 1024 * 1024)

/**
 *  Check if a custom logging facility should be used instead.
 */

#if defined(__GCDWEBSERVER_LOGGING_HEADER__)

#define __GCDWEBSERVER_LOGGING_FACILITY_CUSTOM__

#import __GCDWEBSERVER_LOGGING_HEADER__

/**
 *  Automatically detect if XLFacility is available and if so use it as a
 *  logging facility.
 */

#elif defined(__has_include) && __has_include("XLFacilityMacros.h")

#define __GCDWEBSERVER_LOGGING_FACILITY_XLFACILITY__

#undef XLOG_TAG
#define XLOG_TAG @"gcdwebserver.internal"

#import "XLFacilityMacros.h"

#define GWS_LOG_DEBUG(...) XLOG_DEBUG(__VA_ARGS__)
#define GWS_LOG_VERBOSE(...) XLOG_VERBOSE(__VA_ARGS__)
#define GWS_LOG_INFO(...) XLOG_INFO(__VA_ARGS__)
#define GWS_LOG_WARNING(...) XLOG_WARNING(__VA_ARGS__)
#define GWS_LOG_ERROR(...) XLOG_ERROR(__VA_ARGS__)

#define GWS_DCHECK(__CONDITION__) XLOG_DEBUG_CHECK(__CONDITION__)
#define GWS_DNOT_REACHED() XLOG_DEBUG_UNREACHABLE()

/**
 *  If all of the above fail, then use GCDWebServer built-in
 *  logging facility.
 */

#else /* if defined(__GCDWEBSERVER_LOGGING_HEADER__) */

#define __GCDWEBSERVER_LOGGING_FACILITY_BUILTIN__

typedef NS_ENUM(int, GCDWebServerLoggingLevel) {
    kGCDWebServerLoggingLevel_Debug = 0,
    kGCDWebServerLoggingLevel_Verbose,
    kGCDWebServerLoggingLevel_Info,
    kGCDWebServerLoggingLevel_Warning,
    kGCDWebServerLoggingLevel_Error
};

extern GCDWebServerLoggingLevel GCDWebServerLogLevel;
extern void GCDWebServerLogMessage(GCDWebServerLoggingLevel level, NSString *_Nonnull format, ...) NS_FORMAT_FUNCTION(2, 3);

#if DEBUG
#define GWS_LOG_DEBUG(...)                                                                                                                 \
    do {                                                                                                                                   \
        if (GCDWebServerLogLevel <= kGCDWebServerLoggingLevel_Debug) GCDWebServerLogMessage(kGCDWebServerLoggingLevel_Debug, __VA_ARGS__); \
    } while (0)
#else
#define GWS_LOG_DEBUG(...)
#endif
#define GWS_LOG_VERBOSE(...)                                                                                                                   \
    do {                                                                                                                                       \
        if (GCDWebServerLogLevel <= kGCDWebServerLoggingLevel_Verbose) GCDWebServerLogMessage(kGCDWebServerLoggingLevel_Verbose, __VA_ARGS__); \
    } while (0)
#define GWS_LOG_INFO(...)                                                                                                                \
    do {                                                                                                                                 \
        if (GCDWebServerLogLevel <= kGCDWebServerLoggingLevel_Info) GCDWebServerLogMessage(kGCDWebServerLoggingLevel_Info, __VA_ARGS__); \
    } while (0)
#define GWS_LOG_WARNING(...)                                                                                                                   \
    do {                                                                                                                                       \
        if (GCDWebServerLogLevel <= kGCDWebServerLoggingLevel_Warning) GCDWebServerLogMessage(kGCDWebServerLoggingLevel_Warning, __VA_ARGS__); \
    } while (0)
#define GWS_LOG_ERROR(...)                                                                                                                 \
    do {                                                                                                                                   \
        if (GCDWebServerLogLevel <= kGCDWebServerLoggingLevel_Error) GCDWebServerLogMessage(kGCDWebServerLoggingLevel_Error, __VA_ARGS__); \
    } while (0)

#endif /* if defined(__GCDWEBSERVER_LOGGING_HEADER__) */

/**
 *  Consistency check macros used when building Debug only.
 */

#if !defined(GWS_DCHECK) || !defined(GWS_DNOT_REACHED)

#if DEBUG

#define GWS_DCHECK(__CONDITION__) \
    do {                          \
        if (!(__CONDITION__)) {   \
            abort();              \
        }                         \
    } while (0)
#define GWS_DNOT_REACHED() abort()

#else

#define GWS_DCHECK(__CONDITION__)
#define GWS_DNOT_REACHED()

#endif

#endif

NS_ASSUME_NONNULL_BEGIN

/**
 *  GCDWebServer internal constants and APIs.
 */

#define kGCDWebServerDefaultMimeType @"application/octet-stream"
#define kGCDWebServerErrorDomain @"GCDWebServerErrorDomain"

static inline BOOL GCDWebServerIsValidByteRange(NSRange range) {
    return ((range.location != NSUIntegerMax) || (range.length > 0));
}

static inline NSError *GCDWebServerMakePosixError(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: (NSString *)[NSString stringWithUTF8String:strerror(code)]}];
}

/**
 *  A share of the process-wide in-memory ceiling, held by whatever is doing the buffering.
 *
 *  Deliberately an object: the bytes are returned in -dealloc, so a connection that dies
 *  mid-body — dropped, reset, timed out — cannot leak budget and permanently shrink what
 *  the server can serve afterwards. A holder resizes its reservation as its buffer grows.
 */
@interface GCDWebServerMemoryReservation : NSObject

/**
 *  Resizes this reservation. Returns NO when the process-wide ceiling would be exceeded,
 *  leaving the existing reservation untouched so the caller can fail the request cleanly.
 *  Shrinking always succeeds.
 */
- (BOOL)reserveBytes:(NSUInteger)bytes;

@end

/**
 *  Current limits. These read the testing overrides below, so consult them rather than the
 *  kGCDWebServer... constants directly.
 */
extern NSUInteger GCDWebServerMaxInMemoryBodyLength(void);
extern NSUInteger GCDWebServerMaxDecompressedBodyLength(void);

/**
 *  Shrinks the limits so a test can prove a bound is enforced without moving tens of
 *  megabytes through the server — which is slow, and under AddressSanitizer is itself
 *  enough to lose the test runner. Pass 0 for either to restore its default.
 */
extern void GCDWebServerSetMemoryLimitsForTesting(NSUInteger perRequest, NSUInteger decompressed, NSUInteger total);

/**
 *  Bytes currently reserved across all live reservations. For tests and diagnostics.
 */
extern NSUInteger GCDWebServerReservedMemoryLength(void);

extern void GCDWebServerInitializeFunctions(void);
extern NSString *_Nullable GCDWebServerNormalizeHeaderValue(NSString *_Nullable value);
extern NSString *_Nullable GCDWebServerTruncateHeaderValue(NSString *_Nullable value);
extern NSString *_Nullable GCDWebServerExtractHeaderValueParameter(NSString *_Nullable value, NSString *attribute);
extern NSStringEncoding GCDWebServerStringEncodingFromCharset(NSString *charset);
extern BOOL GCDWebServerIsTextContentType(NSString *type);
extern NSString *GCDWebServerDescribeData(NSData *data, NSString *contentType);
extern NSString *GCDWebServerComputeMD5Digest(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
extern NSString *GCDWebServerStringFromSockAddr(const struct sockaddr *addr, BOOL includeService);

@interface GCDWebServerConnection ()
- (instancetype)initWithServer:(GCDWebServer *)server localAddress:(NSData *)localAddress remoteAddress:(NSData *)remoteAddress socket:(CFSocketNativeHandle)socket;
@end

@interface GCDWebServer ()
@property (nonatomic, readonly) NSMutableArray<GCDWebServerHandler *> *handlers;
@property (nonatomic, readonly, nullable) NSString *serverName;
@property (nonatomic, readonly, nullable) NSSet<NSString *> *allowedHostNames;
@property (nonatomic, readonly, nullable) NSString *authenticationRealm;
@property (nonatomic, readonly, nullable) NSMutableDictionary<NSString *, NSString *> *authenticationBasicAccounts;
@property (nonatomic, readonly, nullable) NSMutableDictionary<NSString *, NSString *> *authenticationDigestAccounts;
@property (nonatomic, readonly) BOOL shouldAutomaticallyMapHEADToGET;
@property (nonatomic, readonly) dispatch_queue_priority_t dispatchQueuePriority;
@property (nonatomic, readonly) NSTimeInterval connectionIdleTimeout;
- (void)willStartConnection:(GCDWebServerConnection *)connection;
- (void)didEndConnection:(GCDWebServerConnection *)connection;
@end

@interface GCDWebServerHandler : NSObject
@property (nonatomic, readonly) GCDWebServerMatchBlock matchBlock;
@property (nonatomic, readonly) GCDWebServerAsyncProcessBlock asyncProcessBlock;
@end

@interface GCDWebServerRequest ()
@property (nonatomic, readonly) BOOL usesChunkedTransferEncoding;
@property (nonatomic) NSData *localAddressData;
@property (nonatomic) NSData *remoteAddressData;
- (void)prepareForWriting;
- (BOOL)performOpen:(NSError **)error;
- (BOOL)performWriteData:(NSData *)data error:(NSError **)error;
- (BOOL)performClose:(NSError **)error;
- (void)setAttribute:(nullable id)attribute forKey:(NSString *)key;
@end

@interface GCDWebServerResponse ()
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *additionalHeaders;
@property (nonatomic, readonly) BOOL usesChunkedTransferEncoding;
- (void)prepareForReading;
- (BOOL)performOpen:(NSError **)error;
- (void)performReadDataWithCompletion:(GCDWebServerBodyReaderCompletionBlock)block;
- (void)performClose;
@end

NS_ASSUME_NONNULL_END
