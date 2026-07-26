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
 *  All SRVServer headers.
 */

#if __has_include(<Serve/SRVServer.h>)
#import <Serve/SRVServer.h>
#import <Serve/SRVConnection.h>
#import <Serve/SRVDataRequest.h>
#import <Serve/SRVDataResponse.h>
#import <Serve/SRVErrorResponse.h>
#import <Serve/SRVFileRequest.h>
#import <Serve/SRVFileResponse.h>
#import <Serve/SRVFunctions.h>
#import <Serve/SRVHTTPStatusCodes.h>
#import <Serve/SRVMultiPartFormRequest.h>
#import <Serve/SRVStreamedResponse.h>
#import <Serve/SRVURLEncodedFormRequest.h>
#else
#import "SRVServer.h"
#import "SRVConnection.h"
#import "SRVDataRequest.h"
#import "SRVDataResponse.h"
#import "SRVErrorResponse.h"
#import "SRVFileRequest.h"
#import "SRVFileResponse.h"
#import "SRVFunctions.h"
#import "SRVHTTPStatusCodes.h"
#import "SRVMultiPartFormRequest.h"
#import "SRVStreamedResponse.h"
#import "SRVURLEncodedFormRequest.h"
#endif

/**
 *  Upper bounds on how much request data may be held in memory at once, to keep
 *  a malicious or broken client from exhausting memory on a constrained device.
 *  These cap in-memory buffering only; bodies streamed to disk (uploaded files,
 *  WebDAV PUT) are not limited by these. Like kHeadersMaxLength and
 *  kSRVMaxConnections, they are fixed safety limits, not options.
 *
 *  kSRVMaxInMemoryBodyLength bounds any single in-memory body buffer
 *  (a data request body, a multipart argument part or the parser's working
 *  buffer, a single chunked-transfer chunk). kSRVMaxDecompressedBodyLength
 *  bounds the total output a gzip-encoded request body may inflate to.
 */
#define kSRVMaxInMemoryBodyLength (16 * 1024 * 1024)
#define kSRVMaxDecompressedBodyLength (64 * 1024 * 1024)

/**
 *  Ceiling on request data held in memory across *all* live connections at once.
 *
 *  The two limits above are per-request, and they do not compose: with
 *  kSRVMaxConnections concurrent requests the real ceiling was their product —
 *  around 2 GB of chunked framing buffers, or 8 GB of inflated gzip output — many times
 *  what any phone survives. Each per-request limit still applies; this bounds the sum.
 *
 *  Sized so that legitimate traffic never approaches it: real uploads stream to disk and
 *  hold only a read-sized buffer in memory, so only a client deliberately parking large
 *  in-memory bodies gets close.
 */
#define kSRVMaxTotalInMemoryLength (64 * 1024 * 1024)

/**
 *  Check if a custom logging facility should be used instead.
 */

#if defined(__SERVE_LOGGING_HEADER__)

#define __SERVE_LOGGING_FACILITY_CUSTOM__

#import __SERVE_LOGGING_HEADER__

/**
 *  Automatically detect if XLFacility is available and if so use it as a
 *  logging facility.
 */

#elif defined(__has_include) && __has_include("XLFacilityMacros.h")

#define __SERVE_LOGGING_FACILITY_XLFACILITY__

#undef XLOG_TAG
#define XLOG_TAG @"gcdwebserver.internal"

#import "XLFacilityMacros.h"

#define SRV_LOG_DEBUG(...) XLOG_DEBUG(__VA_ARGS__)
#define SRV_LOG_VERBOSE(...) XLOG_VERBOSE(__VA_ARGS__)
#define SRV_LOG_INFO(...) XLOG_INFO(__VA_ARGS__)
#define SRV_LOG_WARNING(...) XLOG_WARNING(__VA_ARGS__)
#define SRV_LOG_ERROR(...) XLOG_ERROR(__VA_ARGS__)

#define SRV_DCHECK(__CONDITION__) XLOG_DEBUG_CHECK(__CONDITION__)
#define SRV_DNOT_REACHED() XLOG_DEBUG_UNREACHABLE()

/**
 *  If all of the above fail, then use SRVServer built-in
 *  logging facility.
 */

#else /* if defined(__SERVE_LOGGING_HEADER__) */

#define __SERVE_LOGGING_FACILITY_BUILTIN__

typedef NS_ENUM(int, SRVLoggingLevel) {
    kSRVLoggingLevel_Debug = 0,
    kSRVLoggingLevel_Verbose,
    kSRVLoggingLevel_Info,
    kSRVLoggingLevel_Warning,
    kSRVLoggingLevel_Error
};

extern SRVLoggingLevel SRVLogLevel;
extern void SRVLogMessage(SRVLoggingLevel level, NSString *_Nonnull format, ...) NS_FORMAT_FUNCTION(2, 3);

#if DEBUG
#define SRV_LOG_DEBUG(...)                                                                                                                 \
    do {                                                                                                                                   \
        if (SRVLogLevel <= kSRVLoggingLevel_Debug) SRVLogMessage(kSRVLoggingLevel_Debug, __VA_ARGS__); \
    } while (0)
#else
#define SRV_LOG_DEBUG(...)
#endif
#define SRV_LOG_VERBOSE(...)                                                                                                                   \
    do {                                                                                                                                       \
        if (SRVLogLevel <= kSRVLoggingLevel_Verbose) SRVLogMessage(kSRVLoggingLevel_Verbose, __VA_ARGS__); \
    } while (0)
#define SRV_LOG_INFO(...)                                                                                                                \
    do {                                                                                                                                 \
        if (SRVLogLevel <= kSRVLoggingLevel_Info) SRVLogMessage(kSRVLoggingLevel_Info, __VA_ARGS__); \
    } while (0)
#define SRV_LOG_WARNING(...)                                                                                                                   \
    do {                                                                                                                                       \
        if (SRVLogLevel <= kSRVLoggingLevel_Warning) SRVLogMessage(kSRVLoggingLevel_Warning, __VA_ARGS__); \
    } while (0)
#define SRV_LOG_ERROR(...)                                                                                                                 \
    do {                                                                                                                                   \
        if (SRVLogLevel <= kSRVLoggingLevel_Error) SRVLogMessage(kSRVLoggingLevel_Error, __VA_ARGS__); \
    } while (0)

#endif /* if defined(__SERVE_LOGGING_HEADER__) */

/**
 *  Consistency check macros used when building Debug only.
 */

#if !defined(SRV_DCHECK) || !defined(SRV_DNOT_REACHED)

#if DEBUG

#define SRV_DCHECK(__CONDITION__) \
    do {                          \
        if (!(__CONDITION__)) {   \
            abort();              \
        }                         \
    } while (0)
#define SRV_DNOT_REACHED() abort()

#else

#define SRV_DCHECK(__CONDITION__)
#define SRV_DNOT_REACHED()

#endif

#endif

NS_ASSUME_NONNULL_BEGIN

/**
 *  SRVServer internal constants and APIs.
 */

#define kSRVDefaultMimeType @"application/octet-stream"

// The value of the "Server" response header. Deliberately a constant rather than the class
// name: it is observable output, so tying it to an identifier means a refactor changes the
// wire format and breaks every recorded trace that asserts it.
#define kSRVServerName @"Serve"
#define kSRVErrorDomain @"SRVErrorDomain"

static inline BOOL SRVIsValidByteRange(NSRange range) {
    return ((range.location != NSUIntegerMax) || (range.length > 0));
}

static inline NSError *SRVMakePosixError(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: (NSString *)[NSString stringWithUTF8String:strerror(code)]}];
}

/**
 *  A share of the process-wide in-memory ceiling, held by whatever is doing the buffering.
 *
 *  Deliberately an object: the bytes are returned in -dealloc, so a connection that dies
 *  mid-body — dropped, reset, timed out — cannot leak budget and permanently shrink what
 *  the server can serve afterwards. A holder resizes its reservation as its buffer grows.
 */
@interface SRVMemoryReservation : NSObject

/**
 *  Resizes this reservation. Returns NO when the process-wide ceiling would be exceeded,
 *  leaving the existing reservation untouched so the caller can fail the request cleanly.
 *  Shrinking always succeeds.
 */
- (BOOL)reserveBytes:(NSUInteger)bytes;

@end

/**
 *  Current limits. These read the testing overrides below, so consult them rather than the
 *  kSRV... constants directly.
 */
extern NSUInteger SRVMaxInMemoryBodyLength(void);
extern NSUInteger SRVMaxDecompressedBodyLength(void);

/**
 *  Shrinks the limits so a test can prove a bound is enforced without moving tens of
 *  megabytes through the server — which is slow, and under AddressSanitizer is itself
 *  enough to lose the test runner. Pass 0 for either to restore its default.
 */
extern void SRVSetMemoryLimitsForTesting(NSUInteger perRequest, NSUInteger decompressed, NSUInteger total);

/**
 *  Bytes currently reserved across all live reservations. For tests and diagnostics.
 */
extern NSUInteger SRVReservedMemoryLength(void);

extern void SRVInitializeFunctions(void);
extern NSString *_Nullable SRVNormalizeHeaderValue(NSString *_Nullable value);
extern NSString *_Nullable SRVTruncateHeaderValue(NSString *_Nullable value);
extern NSString *_Nullable SRVExtractHeaderValueParameter(NSString *_Nullable value, NSString *attribute);
extern NSStringEncoding SRVStringEncodingFromCharset(NSString *charset);
extern BOOL SRVIsTextContentType(NSString *type);
extern NSString *SRVDescribeData(NSData *data, NSString *contentType);
extern NSString *SRVComputeMD5Digest(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
extern NSString *SRVStringFromSockAddr(const struct sockaddr *addr, BOOL includeService);

@interface SRVConnection ()
- (instancetype)initWithServer:(SRVServer *)server localAddress:(NSData *)localAddress remoteAddress:(NSData *)remoteAddress socket:(CFSocketNativeHandle)socket;
@end

@interface SRVServer ()
@property (nonatomic, readonly) NSMutableArray<SRVHandler *> *handlers;
@property (nonatomic, readonly, nullable) NSString *serverName;
@property (nonatomic, readonly, nullable) NSSet<NSString *> *allowedHostNames;
@property (nonatomic, readonly, nullable) NSString *authenticationRealm;
@property (nonatomic, readonly, nullable) NSMutableDictionary<NSString *, NSString *> *authenticationBasicAccounts;
@property (nonatomic, readonly, nullable) NSMutableDictionary<NSString *, NSString *> *authenticationDigestAccounts;
@property (nonatomic, readonly) BOOL shouldAutomaticallyMapHEADToGET;
@property (nonatomic, readonly) dispatch_queue_priority_t dispatchQueuePriority;
@property (nonatomic, readonly) NSTimeInterval connectionIdleTimeout;
- (void)willStartConnection:(SRVConnection *)connection;
- (void)didEndConnection:(SRVConnection *)connection;
@end

@interface SRVHandler : NSObject
@property (nonatomic, readonly) SRVMatchBlock matchBlock;
@property (nonatomic, readonly) SRVAsyncProcessBlock asyncProcessBlock;
@end

@interface SRVRequest ()
@property (nonatomic, readonly) BOOL usesChunkedTransferEncoding;
@property (nonatomic) NSData *localAddressData;
@property (nonatomic) NSData *remoteAddressData;
- (void)prepareForWriting;
- (BOOL)performOpen:(NSError **)error;
- (BOOL)performWriteData:(NSData *)data error:(NSError **)error;
- (BOOL)performClose:(NSError **)error;
- (void)setAttribute:(nullable id)attribute forKey:(NSString *)key;
@end

@interface SRVResponse ()
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *additionalHeaders;
@property (nonatomic, readonly) BOOL usesChunkedTransferEncoding;
- (void)prepareForReading;
- (BOOL)performOpen:(NSError **)error;
- (void)performReadDataWithCompletion:(SRVBodyReaderCompletionBlock)block;
- (void)performClose;
@end

NS_ASSUME_NONNULL_END
