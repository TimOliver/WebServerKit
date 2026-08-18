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

// Quoted deliberately in both build flavors: these are project headers, never installed into
// the framework, so the <WebServerKit/…> spelling can't reach them.
#import "WSKHandler.h"
#import "WSKMemoryReservation.h"
#import "WSKPathResolution.h"
#import "WSKValidators.h"

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

// Was #defined identically in WSKRequest.m and WSKResponse.m; the connection now needs it too, to
// tell a zlib failure (the client's data) from one of ours.
#define kZlibErrorDomain @"ZlibErrorDomain"

/**
 *  Why a request body could not be accepted.
 *
 *  Every error in this domain used to be `code:-1`, distinguished only by its localized
 *  description — so the connection layer had nothing to key on and answered 500 for all of them.
 *  A client told 500 has been told the SERVER broke, which invites a retry of something that can
 *  never succeed (malformed framing), or gives up on something that could (a full disk, a
 *  momentarily exhausted budget). These codes exist so the status can tell the truth; the
 *  description stays for the log.
 */
typedef NS_ENUM(NSInteger, WSKRequestBodyErrorCode) {
    kWSKRequestBodyError_Unspecified = -1,     // What every one of these errors used to be
    kWSKRequestBodyError_Malformed = 1,        // The client's framing or encoding is wrong -> 400
    kWSKRequestBodyError_TooLarge,             // A per-request size cap was exceeded -> 413
    kWSKRequestBodyError_ServerAtCapacity,     // The process-wide in-memory ceiling is full -> 503
    kWSKRequestBodyError_Internal,             // Ours, not the client's -> 500
};

static inline BOOL WSKIsValidByteRange(NSRange range) {
    return ((range.location != NSUIntegerMax) || (range.length > 0));
}

static inline NSError *WSKMakePosixError(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: (NSString *)[NSString stringWithUTF8String:strerror(code)]}];
}

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
@property (nonatomic, readonly) NSTimeInterval connectionKeepAliveTimeout;
@property (nonatomic, readonly) NSSet<NSString *> *registeredMethods;
/**
 *  YES once -stop has begun. Safe to read from any thread and deliberately NOT serialized on the
 *  server's state queue, because connections read it from their own queues while -stop runs.
 */
@property (nonatomic, readonly, getter=isStopping) BOOL stopping;
- (void)willStartConnection:(WSKConnection *)connection;
- (void)didEndConnection:(WSKConnection *)connection;
@end

@interface WSKRequest ()
@property (nonatomic, readonly) BOOL usesChunkedTransferEncoding;
@property (nonatomic, getter=isVirtualHEAD) BOOL virtualHEAD;
@property (nonatomic) NSData *localAddressData;
@property (nonatomic) NSData *remoteAddressData;
- (BOOL)prepareForWriting;
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

/**
 *  Does this socket have inbound data that has been received but not yet read?
 *
 *  close(2) on a socket in that state makes the kernel send RST rather than FIN, and an RST
 *  discards bytes already handed to TCP — including a response already sitting in the client's
 *  receive buffer, unread. This is the guard that decides whether a connection must linger before
 *  closing; when it answers NO the close is exactly the one this server has always performed.
 *
 *  Answers NO when it cannot tell (a closed descriptor, or one FIONREAD refuses, like /dev/null),
 *  because the caller uses it to decide whether to do EXTRA work, and "unknown" must not mean "do
 *  the new thing".
 */
BOOL WSKSocketHasUnreadInboundData(int socket);

NS_ASSUME_NONNULL_END
