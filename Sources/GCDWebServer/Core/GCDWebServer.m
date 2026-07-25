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

#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#ifdef __GCDWEBSERVER_ENABLE_TESTING__
#import <AppKit/AppKit.h>
#endif
#endif
#import <dns_sd.h>
#import <netinet/in.h>
#import <objc/runtime.h>
#import <signal.h>
#import <unistd.h>

#import "GCDWebServerPrivate.h"

#if TARGET_OS_IPHONE && !TARGET_IPHONE_SIMULATOR
#define kDefaultPort 80
#else
#define kDefaultPort 8080
#endif

#define kBonjourResolutionTimeout 5.0
#define kGCDWebServerMaxConnections 128  // Upper bound on simultaneous connections, to cap file-descriptor use.

NSString *const GCDWebServerOption_Port = @"Port";
NSString *const GCDWebServerOption_BonjourName = @"BonjourName";
NSString *const GCDWebServerOption_BonjourType = @"BonjourType";
NSString *const GCDWebServerOption_BonjourTXTData = @"BonjourTXTData";
NSString *const GCDWebServerOption_RequestNATPortMapping = @"RequestNATPortMapping";
NSString *const GCDWebServerOption_BindToLocalhost = @"BindToLocalhost";
NSString *const GCDWebServerOption_MaxPendingConnections = @"MaxPendingConnections";
NSString *const GCDWebServerOption_ServerName = @"ServerName";
NSString *const GCDWebServerOption_AuthenticationMethod = @"AuthenticationMethod";
NSString *const GCDWebServerOption_AuthenticationRealm = @"AuthenticationRealm";
NSString *const GCDWebServerOption_AuthenticationAccounts = @"AuthenticationAccounts";
NSString *const GCDWebServerOption_ConnectionClass = @"ConnectionClass";
NSString *const GCDWebServerOption_AutomaticallyMapHEADToGET = @"AutomaticallyMapHEADToGET";
NSString *const GCDWebServerOption_ConnectedStateCoalescingInterval = @"ConnectedStateCoalescingInterval";
NSString *const GCDWebServerOption_DispatchQueuePriority = @"DispatchQueuePriority";
NSString *const GCDWebServerOption_ConnectionIdleTimeout = @"ConnectionIdleTimeout";
#if TARGET_OS_IPHONE
NSString *const GCDWebServerOption_AutomaticallySuspendInBackground = @"AutomaticallySuspendInBackground";
#endif

NSString *const GCDWebServerAuthenticationMethod_Basic = @"Basic";
NSString *const GCDWebServerAuthenticationMethod_DigestAccess = @"DigestAccess";

#if defined(__GCDWEBSERVER_LOGGING_FACILITY_BUILTIN__)
#if DEBUG
GCDWebServerLoggingLevel GCDWebServerLogLevel = kGCDWebServerLoggingLevel_Debug;
#else
GCDWebServerLoggingLevel GCDWebServerLogLevel = kGCDWebServerLoggingLevel_Info;
#endif
#endif

#if !TARGET_OS_IPHONE
// Written from a signal handler and polled from the run loop below, so it has to be
// the one type the C standard lets cross that boundary; a plain BOOL read is UB.
static volatile sig_atomic_t _run;
#endif

#ifdef __GCDWEBSERVER_LOGGING_FACILITY_BUILTIN__

static GCDWebServerBuiltInLoggerBlock _builtInLoggerBlock;

void GCDWebServerLogMessage(GCDWebServerLoggingLevel level, NSString *format, ...) {
    static const char *levelNames[] = {
        "DEBUG", "VERBOSE", "INFO", "WARNING", "ERROR"};
    static int enableLogging = -1;

    if (enableLogging < 0) {
        enableLogging = (isatty(STDERR_FILENO) ? 1 : 0);
    }

    if (_builtInLoggerBlock || enableLogging) {
        va_list arguments;
        va_start(arguments, format);
        NSString *const message = [[NSString alloc] initWithFormat:format arguments:arguments];
        va_end(arguments);

        if (_builtInLoggerBlock) {
            _builtInLoggerBlock(level, message);
        } else {
            fprintf(stderr, "[%s] %s\n", levelNames[level], [message UTF8String]);
        }
    }
}

#endif /* ifdef __GCDWEBSERVER_LOGGING_FACILITY_BUILTIN__ */

#if !TARGET_OS_IPHONE

static void _SignalHandler(int signal) {
    _run = 0;
    // Only async-signal-safe calls belong here: printf() takes the stdio lock, so a
    // signal delivered while another thread holds it would deadlock the process
    // instead of shutting it down.
    ssize_t result = write(STDOUT_FILENO, "\n", 1);
    (void)result;
}

#endif

#if !TARGET_OS_IPHONE || defined(__GCDWEBSERVER_ENABLE_TESTING__)

// This utility function is used to ensure scheduled callbacks on the main thread are called when running the server synchronously
// https://developer.apple.com/library/mac/documentation/General/Conceptual/ConcurrencyProgrammingGuide/OperationQueues/OperationQueues.html
// The main queue works with the application’s run loop to interleave the execution of queued tasks with the execution of other event sources attached to the run loop
// TODO: Ensure all scheduled blocks on the main queue are also executed
static void _ExecuteMainThreadRunLoopSources(void) {
    SInt32 result;

    do {
        result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
    } while (result == kCFRunLoopRunHandledSource);
}

#endif

@implementation GCDWebServerHandler

- (instancetype)initWithMatchBlock:(GCDWebServerMatchBlock _Nonnull)matchBlock asyncProcessBlock:(GCDWebServerAsyncProcessBlock _Nonnull)processBlock {
    if ((self = [super init])) {
        _matchBlock = [matchBlock copy];
        _asyncProcessBlock = [processBlock copy];
    }

    return self;
}

@end

// Private helpers that assume they are already running on _stateQueue. They exist so the
// public accessors can funnel through that queue without any of them re-entering it.
@interface GCDWebServer ()
- (BOOL)_startWithOptions:(NSDictionary<NSString *, id> *)options inBackground:(BOOL)inBackground error:(NSError **)error;
- (void)_stopWithOptions;
@end

// Same contract, for the helpers implemented alongside their public counterparts in the
// Extensions category.
@interface GCDWebServer (ExtensionsPrivate)
- (NSURL *)_serverURL;
- (NSURL *)_bonjourServerURL;
- (NSURL *)_publicServerURL;
@end

@implementation GCDWebServer {
    dispatch_queue_t _syncQueue;
    // Serializes the whole start/stop lifecycle. -_start / -_stop mutate the dispatch
    // sources, the options and the CF Bonjour/DNS refs, and the header advertises use
    // from any thread while iOS drives the same paths from its background/foreground
    // notifications on the main thread. Unsynchronized, two concurrent -_stop calls
    // release the same source twice and two concurrent -_start calls over-resume a
    // source or orphan one whose cancel handler never leaves _sourceGroup (making every
    // later -_stop hang forever). Nothing executed on this queue ever blocks on
    // _syncQueue or on the main queue, so its dispatch_group_wait cannot deadlock.
    dispatch_queue_t _stateQueue;
    dispatch_group_t _sourceGroup;
    NSMutableArray<GCDWebServerHandler *> *_handlers;
    NSInteger _activeConnections;        // Accessed through _syncQueue only
    NSInteger _reservedConnections;      // Accepted sockets not yet counted in _activeConnections; through _syncQueue only
    BOOL _connected;                     // Accessed on main thread only
    CFRunLoopTimerRef _disconnectTimer;  // Accessed on main thread only

    NSDictionary<NSString *, id> *_options;
    NSMutableDictionary<NSString *, NSString *> *_authenticationBasicAccounts;
    NSMutableDictionary<NSString *, NSString *> *_authenticationDigestAccounts;
    Class _connectionClass;
    CFTimeInterval _disconnectDelay;
    dispatch_source_t _source4;
    dispatch_source_t _source6;
    CFNetServiceRef _registrationService;
    CFNetServiceRef _resolutionService;
    DNSServiceRef _dnsService;
    CFSocketRef _dnsSocket;
    CFRunLoopSourceRef _dnsSource;
    NSString *_dnsAddress;
    NSUInteger _dnsPort;
    BOOL _bindToLocalhost;
    NSUInteger _lastBoundPort;  // OS-assigned port to reuse across background/resume when Port option is 0

#if TARGET_OS_IPHONE
    BOOL _suspendInBackground;
    UIBackgroundTaskIdentifier _backgroundTask;
#endif
#ifdef __GCDWEBSERVER_ENABLE_TESTING__
    BOOL _recording;
#endif
}

+ (void)initialize {
    GCDWebServerInitializeFunctions();
}

- (instancetype)init {
    if ((self = [super init])) {
        _syncQueue = dispatch_queue_create([NSStringFromClass([self class]) UTF8String], DISPATCH_QUEUE_SERIAL);
        _stateQueue = dispatch_queue_create("gcdwebserver.state", DISPATCH_QUEUE_SERIAL);
        _sourceGroup = dispatch_group_create();
        _handlers = [[NSMutableArray alloc] init];
#if TARGET_OS_IPHONE
        _backgroundTask = UIBackgroundTaskInvalid;
#endif
    }

    return self;
}

- (void)dealloc {
    GWS_DCHECK(_connected == NO);
    GWS_DCHECK(_activeConnections == 0);
    GWS_DCHECK(_options == nil);           // The server can never be dealloc'ed while running because of the retain-cycle with the dispatch source
    GWS_DCHECK(_disconnectTimer == NULL);  // The server can never be dealloc'ed while the disconnect timer is pending because of the retain-cycle

#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
    dispatch_release(_sourceGroup);
    dispatch_release(_stateQueue);
    dispatch_release(_syncQueue);
#endif
}

#if TARGET_OS_IPHONE

// Always called on main thread
- (void)_startBackgroundTask {
    GWS_DCHECK([NSThread isMainThread]);

    if (_backgroundTask == UIBackgroundTaskInvalid) {
        GWS_LOG_DEBUG(@"Did start background task");
        _backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            GWS_LOG_WARNING(@"Application is being suspended while %@ is still connected", [self class]);
            [self _endBackgroundTask];
        }];
    } else {
        GWS_DNOT_REACHED();
    }
}

#endif

// Always called on main thread
- (void)_didConnect {
    GWS_DCHECK([NSThread isMainThread]);
    GWS_DCHECK(_connected == NO);
    _connected = YES;
    GWS_LOG_DEBUG(@"Did connect");

#if TARGET_OS_IPHONE

    if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground) {
        [self _startBackgroundTask];
    }

#endif

    if ([_delegate respondsToSelector:@selector(webServerDidConnect:)]) {
        [_delegate webServerDidConnect:self];
    }
}

- (void)willStartConnection:(GCDWebServerConnection *)connection {
    dispatch_sync(_syncQueue, ^{
        GWS_DCHECK(self->_activeConnections >= 0);

        if (self->_activeConnections == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_disconnectTimer) {
                    CFRunLoopTimerInvalidate(self->_disconnectTimer);
                    CFRelease(self->_disconnectTimer);
                    self->_disconnectTimer = NULL;
                }

                if (self->_connected == NO) {
                    [self _didConnect];
                }
            });
        }

        self->_activeConnections += 1;
    });
}

#if TARGET_OS_IPHONE

// Always called on main thread
- (void)_endBackgroundTask {
    GWS_DCHECK([NSThread isMainThread]);

    if (_backgroundTask != UIBackgroundTaskInvalid) {
        if (_suspendInBackground && ([[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground)) {
            // Test-and-stop has to happen inside _stateQueue: another thread's -stop (or
            // the foreground reconnect) may be halfway through tearing the sources down.
            dispatch_sync(_stateQueue, ^{
                if (self->_source4) {
                    [self _stop];
                }
            });
        }

        [[UIApplication sharedApplication] endBackgroundTask:_backgroundTask];
        _backgroundTask = UIBackgroundTaskInvalid;
        GWS_LOG_DEBUG(@"Did end background task");
    }
}

#endif

// Always called on main thread
- (void)_didDisconnect {
    GWS_DCHECK([NSThread isMainThread]);
    GWS_DCHECK(_connected == YES);
    _connected = NO;
    GWS_LOG_DEBUG(@"Did disconnect");

#if TARGET_OS_IPHONE
    [self _endBackgroundTask];
#endif

    if ([_delegate respondsToSelector:@selector(webServerDidDisconnect:)]) {
        [_delegate webServerDidDisconnect:self];
    }
}

- (void)didEndConnection:(GCDWebServerConnection *)connection {
    dispatch_sync(_syncQueue, ^{
        GWS_DCHECK(self->_activeConnections > 0);
        self->_activeConnections -= 1;

        if (self->_activeConnections == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // _disconnectDelay and _source4 belong to the lifecycle state, which -_start
                // and -_stop mutate from _stateQueue; read a consistent snapshot rather than
                // racing them. Blocking here is safe: nothing on _stateQueue waits on the
                // main queue.
                __block CFTimeInterval disconnectDelay = 0.0;
                __block BOOL listening = NO;
                dispatch_sync(self->_stateQueue, ^{
                    disconnectDelay = self->_disconnectDelay;
                    listening = (self->_source4 != NULL);
                });

                if ((disconnectDelay > 0.0) && listening) {
                    if (self->_disconnectTimer) {
                        CFRunLoopTimerInvalidate(self->_disconnectTimer);
                        CFRelease(self->_disconnectTimer);
                    }

                    self->_disconnectTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + disconnectDelay, 0.0, 0, 0, ^(CFRunLoopTimerRef timer) {
                        GWS_DCHECK([NSThread isMainThread]);
                        [self _didDisconnect];
                        CFRelease(self->_disconnectTimer);
                        self->_disconnectTimer = NULL;
                    });
                    CFRunLoopAddTimer(CFRunLoopGetMain(), self->_disconnectTimer, kCFRunLoopCommonModes);
                } else {
                    [self _didDisconnect];
                }
            });
        }
    });
}

// _resolutionService is created by -_start and released by -_stop, so it has to be read
// on _stateQueue or a caller on another thread can copy from a freed CFNetService.
- (NSString *)bonjourName {
    __block NSString *result = nil;

    dispatch_sync(_stateQueue, ^{
        CFStringRef name = self->_resolutionService ? CFNetServiceGetName(self->_resolutionService) : NULL;
        result = name && CFStringGetLength(name) ? CFBridgingRelease(CFStringCreateCopy(kCFAllocatorDefault, name)) : nil;
    });
    return result;
}

- (NSString *)bonjourType {
    __block NSString *result = nil;

    dispatch_sync(_stateQueue, ^{
        CFStringRef type = self->_resolutionService ? CFNetServiceGetType(self->_resolutionService) : NULL;
        result = type && CFStringGetLength(type) ? CFBridgingRelease(CFStringCreateCopy(kCFAllocatorDefault, type)) : nil;
    });
    return result;
}

- (void)addHandlerWithMatchBlock:(GCDWebServerMatchBlock)matchBlock processBlock:(GCDWebServerProcessBlock)processBlock {
    [self addHandlerWithMatchBlock:matchBlock
                 asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
                     completionBlock(processBlock(request));
                 }];
}

- (void)addHandlerWithMatchBlock:(GCDWebServerMatchBlock)matchBlock asyncProcessBlock:(GCDWebServerAsyncProcessBlock)processBlock {
    GWS_DCHECK(_options == nil);
    GCDWebServerHandler *const handler = [[GCDWebServerHandler alloc] initWithMatchBlock:matchBlock asyncProcessBlock:processBlock];
    [_handlers insertObject:handler atIndex:0];
}

- (void)removeAllHandlers {
    GWS_DCHECK(_options == nil);
    [_handlers removeAllObjects];
}

static void _NetServiceRegisterCallBack(CFNetServiceRef service, CFStreamError *error, void *info) {
    GWS_DCHECK([NSThread isMainThread]);
    @autoreleasepool {
        if (error->error) {
            GWS_LOG_ERROR(@"Bonjour registration error %i (domain %i)", (int)error->error, (int)error->domain);
        } else {
            GCDWebServer *server = (__bridge GCDWebServer *)info;
            GWS_LOG_VERBOSE(@"Bonjour registration complete for %@", [server class]);

            // Resolution can fail to start for environmental reasons (mDNSResponder
            // unavailable, service already cancelled), so log it instead of aborting.
            if (!CFNetServiceResolveWithTimeout(server->_resolutionService, kBonjourResolutionTimeout, NULL)) {
                GWS_LOG_ERROR(@"Failed starting Bonjour resolution");
            }
        }
    }
}

static void _NetServiceResolveCallBack(CFNetServiceRef service, CFStreamError *error, void *info) {
    GWS_DCHECK([NSThread isMainThread]);
    @autoreleasepool {
        if (error->error) {
            if ((error->domain != kCFStreamErrorDomainNetServices) && (error->error != kCFNetServicesErrorTimeout)) {
                GWS_LOG_ERROR(@"Bonjour resolution error %i (domain %i)", (int)error->error, (int)error->domain);
            }
        } else {
            GCDWebServer *server = (__bridge GCDWebServer *)info;
            GWS_LOG_INFO(@"%@ now locally reachable at %@", [server class], server.bonjourServerURL);

            if ([server.delegate respondsToSelector:@selector(webServerDidCompleteBonjourRegistration:)]) {
                [server.delegate webServerDidCompleteBonjourRegistration:server];
            }
        }
    }
}

static void _DNSServiceCallBack(DNSServiceRef sdRef, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, uint32_t externalAddress, DNSServiceProtocol protocol, uint16_t internalPort, uint16_t externalPort, uint32_t ttl, void *context) {
    GWS_DCHECK([NSThread isMainThread]);
    @autoreleasepool {
        GCDWebServer *server = (__bridge GCDWebServer *)context;

        if ((errorCode == kDNSServiceErr_NoError) || (errorCode == kDNSServiceErr_DoubleNAT)) {
            struct sockaddr_in addr4;
            bzero(&addr4, sizeof(addr4));
            addr4.sin_len = sizeof(addr4);
            addr4.sin_family = AF_INET;
            addr4.sin_addr.s_addr = externalAddress;  // Already in network byte order
            server->_dnsAddress = GCDWebServerStringFromSockAddr((const struct sockaddr *)&addr4, NO);
            server->_dnsPort = ntohs(externalPort);
            GWS_LOG_INFO(@"%@ now publicly reachable at %@", [server class], server.publicServerURL);
        } else {
            GWS_LOG_ERROR(@"DNS service error %i", errorCode);
            server->_dnsAddress = nil;
            server->_dnsPort = 0;
        }

        if ([server.delegate respondsToSelector:@selector(webServerDidUpdateNATPortMapping:)]) {
            [server.delegate webServerDidUpdateNATPortMapping:server];
        }
    }
}

static void _SocketCallBack(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    GWS_DCHECK([NSThread isMainThread]);
    @autoreleasepool {
        GCDWebServer *server = (__bridge GCDWebServer *)info;
        DNSServiceErrorType status = DNSServiceProcessResult(server->_dnsService);

        if (status != kDNSServiceErr_NoError) {
            GWS_LOG_ERROR(@"DNS service error %i", status);
        }
    }
}

static inline id _GetOption(NSDictionary<NSString *, id> *options, NSString *key, id defaultValue) {
    id value = options[key];

    return value ? value : defaultValue;
}

// The options dictionary is untyped, and every value below is consumed without a check:
// a wrong class reaches an unrecognized selector (crash), and an out-of-range port is
// silently truncated by htons() so the server binds something other than what was asked
// for. Validate up front and fail closed, the same way an unknown authentication method
// does. Returns a description of the first problem found, or nil when the options are usable.
static NSString *_ValidateOptions(NSDictionary<NSString *, id> *options) {
    NSDictionary<NSString *, Class> *const expectedClasses = @{
        GCDWebServerOption_Port: [NSNumber class],
        GCDWebServerOption_BonjourName: [NSString class],
        GCDWebServerOption_BonjourType: [NSString class],
        GCDWebServerOption_BonjourTXTData: [NSDictionary class],
        GCDWebServerOption_RequestNATPortMapping: [NSNumber class],
        GCDWebServerOption_BindToLocalhost: [NSNumber class],
        GCDWebServerOption_MaxPendingConnections: [NSNumber class],
        GCDWebServerOption_ServerName: [NSString class],
        GCDWebServerOption_AuthenticationMethod: [NSString class],
        GCDWebServerOption_AuthenticationRealm: [NSString class],
        GCDWebServerOption_AuthenticationAccounts: [NSDictionary class],
        GCDWebServerOption_AutomaticallyMapHEADToGET: [NSNumber class],
        GCDWebServerOption_ConnectedStateCoalescingInterval: [NSNumber class],
        GCDWebServerOption_DispatchQueuePriority: [NSNumber class],
        GCDWebServerOption_ConnectionIdleTimeout: [NSNumber class],
#if TARGET_OS_IPHONE
        GCDWebServerOption_AutomaticallySuspendInBackground: [NSNumber class],
#endif
    };

    for (NSString *key in expectedClasses) {
        NSObject *const value = options[key];
        Class const expectedClass = expectedClasses[key];

        if (value && ![value isKindOfClass:expectedClass]) {
            return [NSString stringWithFormat:@"Option \"%@\" must be of class %@", key, NSStringFromClass(expectedClass)];
        }
    }

    NSNumber *const port = options[GCDWebServerOption_Port];

    if (port && (port.unsignedIntegerValue > 65535)) {  // Also catches negatives, which wrap to a huge value.
        return [NSString stringWithFormat:@"Option \"%@\" must be in the range 0...65535", GCDWebServerOption_Port];
    }

    id const connectionClass = options[GCDWebServerOption_ConnectionClass];

    if (connectionClass && (!class_isMetaClass(object_getClass(connectionClass)) || ![(Class)connectionClass isSubclassOfClass:[GCDWebServerConnection class]])) {
        return [NSString stringWithFormat:@"Option \"%@\" must be a subclass of GCDWebServerConnection", GCDWebServerOption_ConnectionClass];
    }

    return nil;
}

static inline NSString *_EncodeBase64(NSString *string) {
    NSData *const data = [string dataUsingEncoding:NSUTF8StringEncoding];

#if TARGET_OS_IPHONE || (__MAC_OS_X_VERSION_MIN_REQUIRED >= __MAC_10_9)
    return [[NSString alloc] initWithData:[data base64EncodedDataWithOptions:0] encoding:NSASCIIStringEncoding];

#else

    if (@available(macOS 10.9, *)) {
        return [[NSString alloc] initWithData:[data base64EncodedDataWithOptions:0] encoding:NSASCIIStringEncoding];
    }

    return [data base64Encoding];

#endif
}

- (int)_createListeningSocket:(BOOL)useIPv6
                 localAddress:(const void *)address
                       length:(socklen_t)length
        maxPendingConnections:(NSUInteger)maxPendingConnections
                        error:(NSError **)error {
    int listeningSocket = socket(useIPv6 ? PF_INET6 : PF_INET, SOCK_STREAM, IPPROTO_TCP);

    // socket() only fails with -1; fd 0 is a perfectly good descriptor and is handed
    // out whenever stdin has been closed, so it must not be read as an error.
    if (listeningSocket >= 0) {
        int yes = 1;
        setsockopt(listeningSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        if (bind(listeningSocket, address, length) == 0) {
            if (listen(listeningSocket, (int)maxPendingConnections) == 0) {
                GWS_LOG_DEBUG(@"Did open %s listening socket %i", useIPv6 ? "IPv6" : "IPv4", listeningSocket);
                return listeningSocket;
            } else {
                if (error) {
                    *error = GCDWebServerMakePosixError(errno);
                }

                GWS_LOG_ERROR(@"Failed starting %s listening socket: %s (%i)", useIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
                close(listeningSocket);
            }
        } else {
            if (error) {
                *error = GCDWebServerMakePosixError(errno);
            }

            GWS_LOG_ERROR(@"Failed binding %s listening socket: %s (%i)", useIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
            close(listeningSocket);
        }
    } else {
        if (error) {
            *error = GCDWebServerMakePosixError(errno);
        }

        GWS_LOG_ERROR(@"Failed creating %s listening socket: %s (%i)", useIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
    }

    return -1;
}

- (dispatch_source_t)_createDispatchSourceWithListeningSocket:(int)listeningSocket isIPv6:(BOOL)isIPv6 {
    dispatch_group_enter(_sourceGroup);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, listeningSocket, 0, dispatch_get_global_queue(_dispatchQueuePriority, 0));
    dispatch_source_set_cancel_handler(source, ^{
        @autoreleasepool {
            int result = close(listeningSocket);

            if (result != 0) {
                GWS_LOG_ERROR(@"Failed closing %s listening socket: %s (%i)", isIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
            } else {
                GWS_LOG_DEBUG(@"Did close %s listening socket %i", isIPv6 ? "IPv6" : "IPv4", listeningSocket);
            }
        }
        dispatch_group_leave(self->_sourceGroup);
    });
    dispatch_source_set_event_handler(source, ^{
        @autoreleasepool {
            struct sockaddr_storage remoteSockAddr;
            socklen_t remoteAddrLen = sizeof(remoteSockAddr);
            int socket = accept(listeningSocket, (struct sockaddr *)&remoteSockAddr, &remoteAddrLen);

            // accept() only fails with -1; fd 0 is a perfectly good descriptor and is
            // handed out whenever stdin has been closed, so it must not be read as an error.
            if (socket >= 0) {
                NSData *remoteAddress = [NSData dataWithBytes:&remoteSockAddr length:remoteAddrLen];

                struct sockaddr_storage localSockAddr;
                socklen_t localAddrLen = sizeof(localSockAddr);

                // A peer that resets the connection between accept() and here can make
                // getsockname() fail. Without a local address the connection would later
                // dereference a NULL sockaddr (-isUsingIPv6, -localAddressString), so drop
                // this socket rather than serve it.
                if (getsockname(socket, (struct sockaddr *)&localSockAddr, &localAddrLen) != 0) {
                    GWS_LOG_ERROR(@"Failed retrieving local address of accepted %s socket: %s (%i)", isIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
                    close(socket);
                    return;
                }

                NSData *localAddress = [NSData dataWithBytes:&localSockAddr length:localAddrLen];
                GWS_DCHECK((!isIPv6 && localSockAddr.ss_family == AF_INET) || (isIPv6 && localSockAddr.ss_family == AF_INET6));

                int noSigPipe = 1;
                setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));  // Make sure this socket cannot generate SIG_PIPE

                // Cap the number of simultaneous connections so a flood of (e.g. idle)
                // connections cannot exhaust file descriptors — especially important on
                // iOS where the per-process fd limit is small. The slot is reserved and
                // released around the connection's creation because the connection itself
                // only bumps _activeConnections part-way through -initWithServer:; testing
                // the count and letting the connection increment it later would let the two
                // accept sources (IPv4 and IPv6) both pass the check and exceed the cap.
                __block BOOL reserved = NO;
                dispatch_sync(self->_syncQueue, ^{
                    if (self->_activeConnections + self->_reservedConnections < kGCDWebServerMaxConnections) {
                        self->_reservedConnections += 1;
                        reserved = YES;
                    }
                });
                if (!reserved) {
                    GWS_LOG_ERROR(@"Refusing %s connection: already at the %i connection limit", isIPv6 ? "IPv6" : "IPv4", (int)kGCDWebServerMaxConnections);
                    close(socket);
                    return;
                }

                GCDWebServerConnection *connection = [(GCDWebServerConnection *)[self->_connectionClass alloc] initWithServer:self localAddress:localAddress remoteAddress:remoteAddress socket:socket];  // Connection will automatically retain itself while opened
                [connection self];                                                                                                                                                                        // Prevent compiler from complaining about unused variable / useless statement
                dispatch_sync(self->_syncQueue, ^{
                    self->_reservedConnections -= 1;
                });
            } else {
                GWS_LOG_ERROR(@"Failed accepting %s socket: %s (%i)", isIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
            }
        }
    });
    return source;
}

// Must run on _stateQueue (see the ivar comment). Never call a public accessor from here:
// those funnel through the same serial queue and would deadlock.
- (BOOL)_start:(NSError **)error {
    GWS_DCHECK(_source4 == NULL);

    NSUInteger const configuredPort = [(NSNumber *)_GetOption(_options, GCDWebServerOption_Port, @0) unsignedIntegerValue];
    NSUInteger port = configuredPort;
    // When the caller asked for an OS-assigned port (0), reuse the port we were
    // given last time so client URLs stay valid across a background/resume cycle
    // (which tears the sockets down and starts them again). See swisspol/GCDWebServer#563.
    if (configuredPort == 0 && _lastBoundPort != 0) {
        port = _lastBoundPort;
    }
    BOOL bindToLocalhost = [(NSNumber *)_GetOption(_options, GCDWebServerOption_BindToLocalhost, @NO) boolValue];
    // listen(2) takes an int backlog, so an out-of-range option would be truncated into
    // something nonsensical (possibly negative). Clamp instead of casting blindly.
    NSUInteger const requestedPendingConnections = [(NSNumber *)_GetOption(_options, GCDWebServerOption_MaxPendingConnections, @16) unsignedIntegerValue];
    NSUInteger const maxPendingConnections = MIN(MAX(requestedPendingConnections, (NSUInteger)1), (NSUInteger)SOMAXCONN);

    struct sockaddr_in addr4;
    bzero(&addr4, sizeof(addr4));
    addr4.sin_len = sizeof(addr4);
    addr4.sin_family = AF_INET;
    addr4.sin_port = htons(port);
    addr4.sin_addr.s_addr = bindToLocalhost ? htonl(INADDR_LOOPBACK) : htonl(INADDR_ANY);
    // Only surface the error on the attempt we won't retry from.
    int listeningSocket4 = [self _createListeningSocket:NO localAddress:&addr4 length:sizeof(addr4) maxPendingConnections:maxPendingConnections error:(port == configuredPort ? error : NULL)];

    // If reusing the remembered port failed (e.g. another process took it while we
    // were suspended), fall back to letting the OS assign a fresh one.
    if ((listeningSocket4 < 0) && (port != 0) && (configuredPort == 0)) {
        port = 0;
        addr4.sin_port = htons(port);
        listeningSocket4 = [self _createListeningSocket:NO localAddress:&addr4 length:sizeof(addr4) maxPendingConnections:maxPendingConnections error:error];
    }

    if (listeningSocket4 < 0) {
        return NO;
    }

    if (port == 0) {
        struct sockaddr_in addr;
        socklen_t addrlen = sizeof(addr);

        if (getsockname(listeningSocket4, (struct sockaddr *)&addr, &addrlen) == 0) {
            port = ntohs(addr.sin_port);
        } else {
            GWS_LOG_ERROR(@"Failed retrieving socket address: %s (%i)", strerror(errno), errno);
        }
    }

    struct sockaddr_in6 addr6;
    bzero(&addr6, sizeof(addr6));
    addr6.sin6_len = sizeof(addr6);
    addr6.sin6_family = AF_INET6;
    addr6.sin6_port = htons(port);
    addr6.sin6_addr = bindToLocalhost ? in6addr_loopback : in6addr_any;
    int listeningSocket6 = [self _createListeningSocket:YES localAddress:&addr6 length:sizeof(addr6) maxPendingConnections:maxPendingConnections error:error];

    if (listeningSocket6 < 0) {
        close(listeningSocket4);
        return NO;
    }

    _serverName = [(NSString *)_GetOption(_options, GCDWebServerOption_ServerName, NSStringFromClass([self class])) copy];
    NSString *const authenticationMethod = _GetOption(_options, GCDWebServerOption_AuthenticationMethod, nil);

    if ([authenticationMethod isEqualToString:GCDWebServerAuthenticationMethod_Basic]) {
        _authenticationRealm = [(NSString *)_GetOption(_options, GCDWebServerOption_AuthenticationRealm, _serverName) copy];
        _authenticationBasicAccounts = [[NSMutableDictionary alloc] init];
        NSDictionary *accounts = _GetOption(_options, GCDWebServerOption_AuthenticationAccounts, @{});
        [accounts enumerateKeysAndObjectsUsingBlock:^(NSString *username, NSString *password, BOOL *stop) {
            [self->_authenticationBasicAccounts setObject:_EncodeBase64([NSString stringWithFormat:@"%@:%@", username, password]) forKey:username];
        }];
    } else if ([authenticationMethod isEqualToString:GCDWebServerAuthenticationMethod_DigestAccess]) {
        _authenticationRealm = [(NSString *)_GetOption(_options, GCDWebServerOption_AuthenticationRealm, _serverName) copy];
        _authenticationDigestAccounts = [[NSMutableDictionary alloc] init];
        NSDictionary *accounts = _GetOption(_options, GCDWebServerOption_AuthenticationAccounts, @{});
        [accounts enumerateKeysAndObjectsUsingBlock:^(NSString *username, NSString *password, BOOL *stop) {
            [self->_authenticationDigestAccounts setObject:GCDWebServerComputeMD5Digest(@"%@:%@:%@", username, self->_authenticationRealm, password) forKey:username];
        }];
    } else if (authenticationMethod != nil) {
        // An AuthenticationMethod was requested but doesn't match a method we implement
        // (a typo such as @"Digest" instead of @"DigestAccess" is easy to make). Neither
        // account dictionary would be populated, and enforcement gates purely on those
        // being non-nil, so we would silently run with NO authentication. Fail closed:
        // refuse to start rather than serve unauthenticated when the caller asked for auth.
        GWS_LOG_ERROR(@"Refusing to start: unknown authentication method \"%@\"", authenticationMethod);
        if (error) {
            *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown authentication method \"%@\"", authenticationMethod]}];
        }
        close(listeningSocket4);
        close(listeningSocket6);
        return NO;
    }

    _connectionClass = _GetOption(_options, GCDWebServerOption_ConnectionClass, [GCDWebServerConnection class]);
    _shouldAutomaticallyMapHEADToGET = [(NSNumber *)_GetOption(_options, GCDWebServerOption_AutomaticallyMapHEADToGET, @YES) boolValue];
    _disconnectDelay = [(NSNumber *)_GetOption(_options, GCDWebServerOption_ConnectedStateCoalescingInterval, @1.0) doubleValue];
    _dispatchQueuePriority = [(NSNumber *)_GetOption(_options, GCDWebServerOption_DispatchQueuePriority, @(DISPATCH_QUEUE_PRIORITY_DEFAULT)) longValue];
    _connectionIdleTimeout = [(NSNumber *)_GetOption(_options, GCDWebServerOption_ConnectionIdleTimeout, @30.0) doubleValue];

    _source4 = [self _createDispatchSourceWithListeningSocket:listeningSocket4 isIPv6:NO];
    _source6 = [self _createDispatchSourceWithListeningSocket:listeningSocket6 isIPv6:YES];
    _port = port;
    _lastBoundPort = port;  // Remember it so a background/resume cycle keeps the same port.
    _bindToLocalhost = bindToLocalhost;

    NSString *const bonjourName = _GetOption(_options, GCDWebServerOption_BonjourName, nil);
    NSString *const bonjourType = _GetOption(_options, GCDWebServerOption_BonjourType, @"_http._tcp");

    if (bonjourName) {
        _registrationService = CFNetServiceCreate(kCFAllocatorDefault, CFSTR("local."), (__bridge CFStringRef)bonjourType, (__bridge CFStringRef)(bonjourName.length ? bonjourName : _serverName), (SInt32)_port);

        if (_registrationService) {
            CFNetServiceClientContext context = {
                0, (__bridge void *)self, NULL, NULL, NULL};

            CFNetServiceSetClient(_registrationService, _NetServiceRegisterCallBack, &context);
            CFNetServiceScheduleWithRunLoop(_registrationService, CFRunLoopGetMain(), kCFRunLoopCommonModes);
            CFStreamError streamError = {
                0};

            NSDictionary *txtDataDictionary = _GetOption(_options, GCDWebServerOption_BonjourTXTData, nil);

            // Built up in a heap dictionary rather than stack arrays sized from the
            // caller's count: a large dictionary would overflow the stack (the arrays were
            // VLAs) and an empty one is a zero-length VLA. Entries are also type-checked
            // here — CFNetServiceCreateTXTDataWithDictionary requires CFString keys with
            // CFString or CFData values, and the old code bridged whatever it was given.
            if (txtDataDictionary.count > 0) {
                CFMutableDictionaryRef txtDictionary = CFDictionaryCreateMutable(kCFAllocatorDefault, (CFIndex)txtDataDictionary.count, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

                if (txtDictionary != NULL) {
                    for (NSObject *key in txtDataDictionary) {
                        NSObject *const value = [(NSDictionary *)txtDataDictionary objectForKey:key];

                        if ([key isKindOfClass:[NSString class]] && ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSData class]])) {
                            CFDictionarySetValue(txtDictionary, (__bridge const void *)key, (__bridge const void *)value);
                        } else {
                            GWS_LOG_ERROR(@"Ignoring Bonjour TXT data entry with unsupported key or value type");
                        }
                    }

                    CFDataRef txtData = CFNetServiceCreateTXTDataWithDictionary(kCFAllocatorDefault, txtDictionary);

                    if (txtData != NULL) {  // Guard: CFRelease(NULL) is a hard crash, and the dictionary may be un-encodable.
                        if (!CFNetServiceSetTXTData(_registrationService, txtData)) {
                            GWS_LOG_ERROR(@"Failed setting TXTData");
                        }
                        CFRelease(txtData);
                    }

                    CFRelease(txtDictionary);  // Was leaked on every start when BonjourTXTData was set.
                }
            }

            CFNetServiceRegisterWithOptions(_registrationService, 0, &streamError);

            _resolutionService = CFNetServiceCreateCopy(kCFAllocatorDefault, _registrationService);

            if (_resolutionService) {
                CFNetServiceSetClient(_resolutionService, _NetServiceResolveCallBack, &context);
                CFNetServiceScheduleWithRunLoop(_resolutionService, CFRunLoopGetMain(), kCFRunLoopCommonModes);
            } else {
                GWS_LOG_ERROR(@"Failed creating CFNetService for resolution");
            }
        } else {
            GWS_LOG_ERROR(@"Failed creating CFNetService for registration");
        }
    }

    if ([(NSNumber *)_GetOption(_options, GCDWebServerOption_RequestNATPortMapping, @NO) boolValue]) {
        DNSServiceErrorType status = DNSServiceNATPortMappingCreate(&_dnsService, 0, 0, kDNSServiceProtocol_TCP, htons(port), htons(port), 0, _DNSServiceCallBack, (__bridge void *)self);

        if (status == kDNSServiceErr_NoError) {
            CFSocketContext context = {
                0, (__bridge void *)self, NULL, NULL, NULL};
            _dnsSocket = CFSocketCreateWithNative(kCFAllocatorDefault, DNSServiceRefSockFD(_dnsService), kCFSocketReadCallBack, _SocketCallBack, &context);

            if (_dnsSocket) {
                CFSocketSetSocketFlags(_dnsSocket, CFSocketGetSocketFlags(_dnsSocket) & ~kCFSocketCloseOnInvalidate);
                _dnsSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _dnsSocket, 0);

                if (_dnsSource) {
                    CFRunLoopAddSource(CFRunLoopGetMain(), _dnsSource, kCFRunLoopCommonModes);
                } else {
                    // Allocation failure, not a logic error: NAT-PMP is optional, so log and
                    // keep serving rather than abort() the host app in a Debug build.
                    GWS_LOG_ERROR(@"Failed creating CFRunLoopSource");
                }
            } else {
                GWS_LOG_ERROR(@"Failed creating CFSocket");
            }
        } else {
            GWS_LOG_ERROR(@"Failed creating NAT port mapping (%i)", status);
        }
    }

    dispatch_resume(_source4);
    dispatch_resume(_source6);
    GWS_LOG_INFO(@"%@ started on port %i and reachable at %@", [self class], (int)_port, [self _serverURL]);  // Not self.serverURL: that re-enters _stateQueue and would deadlock.

    if ([_delegate respondsToSelector:@selector(webServerDidStart:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate webServerDidStart:self];
        });
    }

    return YES;
}

// Must run on _stateQueue (see the ivar comment). The dispatch_group_wait below is only
// safe because the cancel handlers run on a global queue and touch neither this queue nor
// the main queue.
- (void)_stop {
    GWS_DCHECK(_source4 != NULL);

    if (_dnsService) {
        _dnsAddress = nil;
        _dnsPort = 0;

        if (_dnsSource) {
            CFRunLoopSourceInvalidate(_dnsSource);
            CFRelease(_dnsSource);
            _dnsSource = NULL;
        }

        if (_dnsSocket) {
            CFRelease(_dnsSocket);
            _dnsSocket = NULL;
        }

        DNSServiceRefDeallocate(_dnsService);
        _dnsService = NULL;
    }

    if (_registrationService) {
        if (_resolutionService) {
            CFNetServiceUnscheduleFromRunLoop(_resolutionService, CFRunLoopGetMain(), kCFRunLoopCommonModes);
            CFNetServiceSetClient(_resolutionService, NULL, NULL);
            CFNetServiceCancel(_resolutionService);
            CFRelease(_resolutionService);
            _resolutionService = NULL;
        }

        CFNetServiceUnscheduleFromRunLoop(_registrationService, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFNetServiceSetClient(_registrationService, NULL, NULL);
        CFNetServiceCancel(_registrationService);
        CFRelease(_registrationService);
        _registrationService = NULL;
    }

    dispatch_source_cancel(_source6);
    dispatch_source_cancel(_source4);
    dispatch_group_wait(_sourceGroup, DISPATCH_TIME_FOREVER);  // Wait until the cancellation handlers have been called which guarantees the listening sockets are closed
#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
    dispatch_release(_source6);
#endif
    _source6 = NULL;
#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
    dispatch_release(_source4);
#endif
    _source4 = NULL;
    _port = 0;
    _bindToLocalhost = NO;

    _serverName = nil;
    _authenticationRealm = nil;
    _authenticationBasicAccounts = nil;
    _authenticationDigestAccounts = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_disconnectTimer) {
            CFRunLoopTimerInvalidate(self->_disconnectTimer);
            CFRelease(self->_disconnectTimer);
            self->_disconnectTimer = NULL;
            [self _didDisconnect];
        }
    });

    GWS_LOG_INFO(@"%@ stopped", [self class]);

    if ([_delegate respondsToSelector:@selector(webServerDidStop:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate webServerDidStop:self];
        });
    }
}

#if TARGET_OS_IPHONE

// These fire on the main thread but race the host app's own -start/-stop calls, which may
// come from any thread, so the test-and-act has to happen on _stateQueue like every other
// lifecycle transition. Blocking the main thread here also preserves the property the
// original main-thread-confined code relied on: the main run loop cannot dispatch a
// CFNetService/DNSService callback while the Bonjour refs are being rebuilt.
- (void)_didEnterBackground:(NSNotification *)notification {
    GWS_DCHECK([NSThread isMainThread]);
    GWS_LOG_DEBUG(@"Did enter background");

    dispatch_sync(_stateQueue, ^{
        if ((self->_backgroundTask == UIBackgroundTaskInvalid) && self->_source4) {
            [self _stop];
        }
    });
}

- (void)_willEnterForeground:(NSNotification *)notification {
    GWS_DCHECK([NSThread isMainThread]);
    GWS_LOG_DEBUG(@"Will enter foreground");

    dispatch_sync(_stateQueue, ^{
        if (!self->_source4) {
            [self _start:NULL];  // TODO: There's probably nothing we can do on failure
        }
    });
}

- (void)_reconnectInForeground:(NSNotification *)notification {
    GWS_DCHECK([NSThread isMainThread]);
    GWS_LOG_DEBUG(@"Will enter foreground (not suspending in background)");

    // When not suspending in the background we keep serving, but iOS may still
    // tear down our listening sockets once the process is actually suspended.
    // If we were running, rebuild them from scratch when returning to the
    // foreground so the server keeps accepting connections. -_start: reuses the
    // previously assigned port, so client URLs stay valid. See
    // swisspol/GCDWebServer#292. Existing (already-accepted) connections are
    // unaffected — only the listening sockets are rebuilt.
    dispatch_sync(_stateQueue, ^{
        if (self->_source4) {
            [self _stop];
            [self _start:NULL];  // TODO: There's probably nothing we can do on failure
        }
    });
}

#endif

// Runs on _stateQueue; -startWithOptions:error: is the public funnel.
- (BOOL)_startWithOptions:(NSDictionary<NSString *, id> *)options inBackground:(BOOL)inBackground error:(NSError **)error {
    if (_options == nil) {
        NSDictionary<NSString *, id> *const newOptions = options ? [options copy] : @{};
        NSString *const invalidOption = _ValidateOptions(newOptions);

        if (invalidOption) {
            GWS_LOG_ERROR(@"Refusing to start: %@", invalidOption);

            if (error) {
                *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: invalidOption}];
            }

            return NO;
        }

        _options = newOptions;
        _lastBoundPort = 0;  // Fresh session: don't inherit a port remembered from a previous run.
#if TARGET_OS_IPHONE
        _suspendInBackground = [(NSNumber *)_GetOption(_options, GCDWebServerOption_AutomaticallySuspendInBackground, @YES) boolValue];

        if (((_suspendInBackground == NO) || (inBackground == NO)) && ![self _start:error])
#else

        if (![self _start:error])
#endif
        {
            _options = nil;
            return NO;
        }

#if TARGET_OS_IPHONE

        if (_suspendInBackground) {
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_didEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_willEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        } else {
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_reconnectInForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        }

#endif
        return YES;
    } else {
        GWS_DNOT_REACHED();  // Starting an already-started server is an API misuse by the host app
    }

    return NO;
}

- (BOOL)startWithOptions:(NSDictionary<NSString *, id> *)options error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *startError = nil;

    // Sample the application state on the caller's thread, not inside the _stateQueue block
    // below: UIApplication is main-thread-only and _stateQueue always runs on a worker
    // thread. Callers are expected to start the server from the main thread, which is where
    // this was read before the lifecycle funnel existed.
#if TARGET_OS_IPHONE
    BOOL inBackground = ([[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground);
#else
    BOOL inBackground = NO;
#endif

    dispatch_sync(_stateQueue, ^{
        success = [self _startWithOptions:options inBackground:inBackground error:&startError];
    });

    if (!success && error) {
        *error = startError;
    }

    return success;
}

- (BOOL)isRunning {
    // Reflect whether the server is actually listening, not merely configured.
    // This is NO while the server is suspended in the background (its listening
    // sockets are torn down until the app returns to the foreground), which is
    // the behavior the header documents for
    // GCDWebServerOption_AutomaticallySuspendInBackground. Previously this
    // returned YES whenever the server had been started, so it stayed YES while
    // suspended and lied about the server's state. See swisspol/GCDWebServer#437.
    __block BOOL running = NO;

    dispatch_sync(_stateQueue, ^{
        running = (self->_source4 != NULL);
    });
    return running;
}

// Runs on _stateQueue; -stop is the public funnel.
- (void)_stopWithOptions {
    if (_options) {
#if TARGET_OS_IPHONE

        if (_suspendInBackground) {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
            [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
        } else {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
        }

#endif

        if (_source4) {
            [self _stop];
        }

        _options = nil;
    } else {
        GWS_DNOT_REACHED();  // Stopping a server that was never started is an API misuse by the host app
    }
}

- (void)stop {
    dispatch_sync(_stateQueue, ^{
        [self _stopWithOptions];
    });
}

@end

@implementation GCDWebServer (Extensions)

// The _xxx variants assume they are already on _stateQueue; the public properties funnel
// through it so a caller on another thread can't read a half-torn-down configuration (and
// -_start can log its URL without re-entering the queue).
- (NSURL *)serverURL {
    __block NSURL *url = nil;

    dispatch_sync(_stateQueue, ^{
        url = [self _serverURL];
    });
    return url;
}

- (NSURL *)_serverURL {
    if (_source4) {
        NSString *ipAddress = _bindToLocalhost ? @"localhost" : GCDWebServerGetPrimaryIPAddress(NO);  // We can't really use IPv6 anyway as it doesn't work great with HTTP URLs in practice

        if (ipAddress) {
            if (_port != 80) {
                return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%i/", ipAddress, (int)_port]];
            } else {
                return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/", ipAddress]];
            }
        }
    }

    return nil;
}

- (NSURL *)bonjourServerURL {
    __block NSURL *url = nil;

    dispatch_sync(_stateQueue, ^{
        url = [self _bonjourServerURL];
    });
    return url;
}

- (NSURL *)_bonjourServerURL {
    if (_source4 && _resolutionService) {
        NSString *name = (__bridge NSString *)CFNetServiceGetTargetHost(_resolutionService);

        if (name.length) {
            name = [name substringToIndex:(name.length - 1)];  // Strip trailing period at end of domain

            if (_port != 80) {
                return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%i/", name, (int)_port]];
            } else {
                return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/", name]];
            }
        }
    }

    return nil;
}

- (NSURL *)publicServerURL {
    __block NSURL *url = nil;

    dispatch_sync(_stateQueue, ^{
        url = [self _publicServerURL];
    });
    return url;
}

- (NSURL *)_publicServerURL {
    if (_source4 && _dnsService && _dnsAddress && _dnsPort) {
        if (_dnsPort != 80) {
            return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%i/", _dnsAddress, (int)_dnsPort]];
        } else {
            return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/", _dnsAddress]];
        }
    }

    return nil;
}

- (BOOL)start {
    return [self startWithPort:kDefaultPort bonjourName:@""];
}

- (BOOL)startWithPort:(NSUInteger)port bonjourName:(NSString *)name {
    NSMutableDictionary *options = [NSMutableDictionary dictionary];

    [options setObject:@(port) forKey:GCDWebServerOption_Port];
    [options setValue:name forKey:GCDWebServerOption_BonjourName];
    return [self startWithOptions:options error:NULL];
}

#if !TARGET_OS_IPHONE

- (BOOL)runWithPort:(NSUInteger)port bonjourName:(NSString *)name {
    NSMutableDictionary *options = [NSMutableDictionary dictionary];

    [options setObject:@(port) forKey:GCDWebServerOption_Port];
    [options setValue:name forKey:GCDWebServerOption_BonjourName];
    return [self runWithOptions:options error:NULL];
}

- (BOOL)runWithOptions:(NSDictionary<NSString *, id> *)options error:(NSError **)error {
    GWS_DCHECK([NSThread isMainThread]);
    BOOL success = NO;
    _run = 1;
    void (*termHandler)(int) = signal(SIGTERM, _SignalHandler);
    void (*intHandler)(int) = signal(SIGINT, _SignalHandler);

    if ((termHandler != SIG_ERR) && (intHandler != SIG_ERR)) {
        if ([self startWithOptions:options error:error]) {
            while (_run)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, true);
            [self stop];
            success = YES;
        }

        _ExecuteMainThreadRunLoopSources();
        signal(SIGINT, intHandler);
        signal(SIGTERM, termHandler);
    }

    return success;
}

#endif /* if !TARGET_OS_IPHONE */

@end

@implementation GCDWebServer (Handlers)

- (void)addDefaultHandlerForMethod:(NSString *)method requestClass:(Class)aClass processBlock:(GCDWebServerProcessBlock)block {
    [self addDefaultHandlerForMethod:method
                        requestClass:aClass
                   asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
                       completionBlock(block(request));
                   }];
}

- (void)addDefaultHandlerForMethod:(NSString *)method requestClass:(Class)aClass asyncProcessBlock:(GCDWebServerAsyncProcessBlock)block {
    [self
        addHandlerWithMatchBlock:^GCDWebServerRequest *(NSString *requestMethod, NSURL *requestURL, NSDictionary<NSString *, NSString *> *requestHeaders, NSString *urlPath, NSDictionary<NSString *, NSString *> *urlQuery) {
            if (![requestMethod isEqualToString:method]) {
                return nil;
            }

            return [(GCDWebServerRequest *)[aClass alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
        }
               asyncProcessBlock:block];
}

- (void)addHandlerForMethod:(NSString *)method path:(NSString *)path requestClass:(Class)aClass processBlock:(GCDWebServerProcessBlock)block {
    [self addHandlerForMethod:method
                         path:path
                 requestClass:aClass
            asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
                completionBlock(block(request));
            }];
}

- (void)addHandlerForMethod:(NSString *)method path:(NSString *)path requestClass:(Class)aClass asyncProcessBlock:(GCDWebServerAsyncProcessBlock)block {
    if ([path hasPrefix:@"/"] && [aClass isSubclassOfClass:[GCDWebServerRequest class]]) {
        [self
            addHandlerWithMatchBlock:^GCDWebServerRequest *(NSString *requestMethod, NSURL *requestURL, NSDictionary<NSString *, NSString *> *requestHeaders, NSString *urlPath, NSDictionary<NSString *, NSString *> *urlQuery) {
                if (![requestMethod isEqualToString:method]) {
                    return nil;
                }

                if ([urlPath caseInsensitiveCompare:path] != NSOrderedSame) {
                    return nil;
                }

                return [(GCDWebServerRequest *)[aClass alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
            }
                   asyncProcessBlock:block];
    } else {
        GWS_DNOT_REACHED();
    }
}

- (void)addHandlerForMethod:(NSString *)method pathRegex:(NSString *)regex requestClass:(Class)aClass processBlock:(GCDWebServerProcessBlock)block {
    [self addHandlerForMethod:method
                    pathRegex:regex
                 requestClass:aClass
            asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
                completionBlock(block(request));
            }];
}

- (void)addHandlerForMethod:(NSString *)method pathRegex:(NSString *)regex requestClass:(Class)aClass asyncProcessBlock:(GCDWebServerAsyncProcessBlock)block {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:regex options:NSRegularExpressionCaseInsensitive error:NULL];

    if (expression && [aClass isSubclassOfClass:[GCDWebServerRequest class]]) {
        [self
            addHandlerWithMatchBlock:^GCDWebServerRequest *(NSString *requestMethod, NSURL *requestURL, NSDictionary<NSString *, NSString *> *requestHeaders, NSString *urlPath, NSDictionary<NSString *, NSString *> *urlQuery) {
                if (![requestMethod isEqualToString:method]) {
                    return nil;
                }

                NSArray *matches = [expression matchesInString:urlPath options:0 range:NSMakeRange(0, urlPath.length)];

                if (matches.count == 0) {
                    return nil;
                }

                NSMutableArray *captures = [NSMutableArray array];

                for (NSTextCheckingResult *result in matches) {
                    // Start at 1; index 0 is the whole string
                    for (NSUInteger i = 1; i < result.numberOfRanges; i++) {
                        NSRange range = [result rangeAtIndex:i];

                        // range is {NSNotFound, 0} "if one of the capture groups did not participate in this particular match"
                        // see discussion in -[NSRegularExpression firstMatchInString:options:range:]
                        if (range.location != NSNotFound) {
                            [captures addObject:[urlPath substringWithRange:range]];
                        }
                    }
                }

                GCDWebServerRequest *request = [(GCDWebServerRequest *)[aClass alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
                [request setAttribute:captures forKey:GCDWebServerRequestAttribute_RegexCaptures];
                return request;
            }
                   asyncProcessBlock:block];
    } else {
        GWS_DNOT_REACHED();
    }
}

@end

@implementation GCDWebServer (GETHandlers)

- (void)addGETHandlerForPath:(NSString *)path staticData:(NSData *)staticData contentType:(NSString *)contentType cacheAge:(NSUInteger)cacheAge {
    [self addHandlerForMethod:@"GET"
                         path:path
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                     GCDWebServerResponse *response = [GCDWebServerDataResponse responseWithData:staticData contentType:contentType];
                     response.cacheControlMaxAge = cacheAge;
                     return response;
                 }];
}

- (void)addGETHandlerForPath:(NSString *)path filePath:(NSString *)filePath isAttachment:(BOOL)isAttachment cacheAge:(NSUInteger)cacheAge allowRangeRequests:(BOOL)allowRangeRequests {
    [self addHandlerForMethod:@"GET"
                         path:path
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                     GCDWebServerResponse *response = nil;

                     if (allowRangeRequests) {
                         response = [GCDWebServerFileResponse responseWithFile:filePath byteRange:request.byteRange isAttachment:isAttachment];
                         [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
                     } else {
                         response = [GCDWebServerFileResponse responseWithFile:filePath isAttachment:isAttachment];
                     }

                     response.cacheControlMaxAge = cacheAge;
                     return response;
                 }];
}

static NSString *_EscapeHTMLString(NSString *string) {
    NSMutableString *const escaped = [string mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];  // Must run first.
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"'" withString:@"&#39;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

- (GCDWebServerResponse *)_responseWithContentsOfDirectory:(NSString *)path {
    NSArray *const contents = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    if (contents == nil) {
        return nil;
    }

    NSMutableString *const html = [NSMutableString string];
    [html appendString:@"<!DOCTYPE html>\n"];
    [html appendString:@"<html><head><meta charset=\"utf-8\"></head><body>\n"];
    [html appendString:@"<ul>\n"];

    for (NSString *entry in contents) {
        if (![entry hasPrefix:@"."]) {
            NSString *const type = [[NSFileManager defaultManager] attributesOfItemAtPath:[path stringByAppendingPathComponent:entry] error:NULL][NSFileType];

            // Any process can delete the entry between the directory read above and this
            // stat, so a missing type is an ordinary race, not a logic error to assert on.
            if (type == nil) {
                continue;
            }

            NSString *const escapedFile = [entry stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
            GWS_DCHECK(escapedFile);

            NSString *const escapedEntry = _EscapeHTMLString(entry);  // The filename is reflected into HTML text; escape it to prevent stored XSS via crafted names.

            if ([type isEqualToString:NSFileTypeRegular]) {
                [html appendFormat:@"<li><a href=\"%@\">%@</a></li>\n", escapedFile, escapedEntry];
            } else if ([type isEqualToString:NSFileTypeDirectory]) {
                [html appendFormat:@"<li><a href=\"%@/\">%@/</a></li>\n", escapedFile, escapedEntry];
            }
        }
    }

    [html appendString:@"</ul>\n"];
    [html appendString:@"</body></html>\n"];
    return [GCDWebServerDataResponse responseWithHTML:html];
}

- (void)addGETHandlerForBasePath:(NSString *)basePath directoryPath:(NSString *)directoryPath indexFilename:(NSString *)indexFilename cacheAge:(NSUInteger)cacheAge allowRangeRequests:(BOOL)allowRangeRequests {
    if ([basePath hasPrefix:@"/"] && [basePath hasSuffix:@"/"]) {
        GCDWebServer *__unsafe_unretained server = self;
        [self
            addHandlerWithMatchBlock:^GCDWebServerRequest *(NSString *requestMethod, NSURL *requestURL, NSDictionary<NSString *, NSString *> *requestHeaders, NSString *urlPath, NSDictionary<NSString *, NSString *> *urlQuery) {
                if (![requestMethod isEqualToString:@"GET"]) {
                    return nil;
                }

                if (![urlPath hasPrefix:basePath]) {
                    return nil;
                }

                return [[GCDWebServerRequest alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
            }
            processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                GCDWebServerResponse *response = nil;
                NSString *filePath = [directoryPath stringByAppendingPathComponent:GCDWebServerNormalizePath([request.path substringFromIndex:basePath.length])];
                // Stripping ".." textually is not containment: -attributesOfItemAtPath: uses
                // lstat, which only refuses a symlink as the *final* component, and O_NOFOLLOW
                // in the file response does the same — so any symlinked directory anywhere
                // under directoryPath (a git checkout, an unpacked archive) would serve files
                // from wherever it points. Resolve the whole path and require it to stay
                // inside, the way every other file-serving handler in this library does.
                if (!GCDWebServerResolvedPathIsWithinDirectory(filePath, directoryPath)) {
                    GWS_LOG_WARNING(@"Refusing to serve \"%@\": it resolves outside \"%@\"", filePath, directoryPath);
                    return [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_NotFound];
                }

                NSString *fileType = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL] fileType];

                if (fileType) {
                    if ([fileType isEqualToString:NSFileTypeDirectory]) {
                        if (indexFilename) {
                            NSString *indexPath = [filePath stringByAppendingPathComponent:indexFilename];
                            NSString *indexType = [[[NSFileManager defaultManager] attributesOfItemAtPath:indexPath error:NULL] fileType];

                            if ([indexType isEqualToString:NSFileTypeRegular]) {
                                return [GCDWebServerFileResponse responseWithFile:indexPath];
                            }
                        }

                        response = [server _responseWithContentsOfDirectory:filePath];
                    } else if ([fileType isEqualToString:NSFileTypeRegular]) {
                        if (allowRangeRequests) {
                            response = [GCDWebServerFileResponse responseWithFile:filePath byteRange:request.byteRange];
                            [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
                        } else {
                            response = [GCDWebServerFileResponse responseWithFile:filePath];
                        }
                    }
                }

                if (response) {
                    response.cacheControlMaxAge = cacheAge;
                } else {
                    response = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_NotFound];
                }

                return response;
            }];
    } else {
        GWS_DNOT_REACHED();
    }
}

@end

@implementation GCDWebServer (Logging)

+ (void)setLogLevel:(int)level {
#if defined(__GCDWEBSERVER_LOGGING_FACILITY_XLFACILITY__)
    [XLSharedFacility setMinLogLevel:level];
#elif defined(__GCDWEBSERVER_LOGGING_FACILITY_BUILTIN__)
    GCDWebServerLogLevel = level;
#endif
}

+ (void)setBuiltInLogger:(GCDWebServerBuiltInLoggerBlock)block {
#if defined(__GCDWEBSERVER_LOGGING_FACILITY_BUILTIN__)
    _builtInLoggerBlock = block;
#else
    GWS_DNOT_REACHED();  // Built-in logger must be enabled in order to override
#endif
}

- (void)logVerbose:(NSString *)format, ... {
    va_list arguments;

    va_start(arguments, format);
    GWS_LOG_VERBOSE(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
    va_end(arguments);
}

- (void)logInfo:(NSString *)format, ... {
    va_list arguments;

    va_start(arguments, format);
    GWS_LOG_INFO(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
    va_end(arguments);
}

- (void)logWarning:(NSString *)format, ... {
    va_list arguments;

    va_start(arguments, format);
    GWS_LOG_WARNING(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
    va_end(arguments);
}

- (void)logError:(NSString *)format, ... {
    va_list arguments;

    va_start(arguments, format);
    GWS_LOG_ERROR(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
    va_end(arguments);
}

@end

#ifdef __GCDWEBSERVER_ENABLE_TESTING__

@implementation GCDWebServer (Testing)

- (void)setRecordingEnabled:(BOOL)flag {
    _recording = flag;
}

- (BOOL)isRecordingEnabled {
    return _recording;
}

static CFHTTPMessageRef _CreateHTTPMessageFromData(NSData *data, BOOL isRequest) {
    CFHTTPMessageRef message = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, isRequest);

    if (CFHTTPMessageAppendBytes(message, data.bytes, data.length)) {
        return message;
    }

    CFRelease(message);
    return NULL;
}

static CFHTTPMessageRef _CreateHTTPMessageFromPerformingRequest(NSData *inData, NSUInteger port) {
    CFHTTPMessageRef response = NULL;
    int httpSocket = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);

    if (httpSocket > 0) {
        struct sockaddr_in addr4;
        bzero(&addr4, sizeof(addr4));
        addr4.sin_len = sizeof(addr4);
        addr4.sin_family = AF_INET;
        addr4.sin_port = htons(port);
        addr4.sin_addr.s_addr = htonl(INADDR_ANY);

        if (connect(httpSocket, (void *)&addr4, sizeof(addr4)) == 0) {
            if (write(httpSocket, inData.bytes, inData.length) == (ssize_t)inData.length) {
                NSMutableData *outData = [[NSMutableData alloc] initWithLength:(256 * 1024)];
                NSUInteger length = 0;

                while (1) {
                    ssize_t result = read(httpSocket, (char *)outData.mutableBytes + length, outData.length - length);

                    if (result < 0) {
                        length = NSUIntegerMax;
                        break;
                    } else if (result == 0) {
                        break;
                    }

                    length += result;

                    if (length >= outData.length) {
                        outData.length = 2 * outData.length;
                    }
                }

                if (length != NSUIntegerMax) {
                    outData.length = length;
                    response = _CreateHTTPMessageFromData(outData, NO);
                } else {
                    GWS_DNOT_REACHED();
                }
            }
        }

        close(httpSocket);
    }

    return response;
}

static void _LogResult(NSString *format, ...) {
    va_list arguments;

    va_start(arguments, format);
    NSString *const message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    fprintf(stdout, "%s\n", [message UTF8String]);
}

- (NSInteger)runTestsWithOptions:(NSDictionary<NSString *, id> *)options inDirectory:(NSString *)path {
    GWS_DCHECK([NSThread isMainThread]);
    NSArray *const ignoredHeaders = @[@"Date", @"Etag"];  // Dates are always different by definition and ETags depend on file system node IDs
    NSInteger result = -1;

    if ([self startWithOptions:options error:NULL]) {
        _ExecuteMainThreadRunLoopSources();

        result = 0;
        NSArray *const files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

        for (NSString *requestFile in files) {
            if (![requestFile hasSuffix:@".request"]) {
                continue;
            }

            @autoreleasepool {
                NSString *const index = [[requestFile componentsSeparatedByString:@"-"] firstObject];
                BOOL success = NO;
                NSData *const requestData = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:requestFile]];

                if (requestData) {
                    CFHTTPMessageRef request = _CreateHTTPMessageFromData(requestData, YES);

                    if (request) {
                        NSString *const requestMethod = CFBridgingRelease(CFHTTPMessageCopyRequestMethod(request));
                        NSURL *const requestURL = CFBridgingRelease(CFHTTPMessageCopyRequestURL(request));
                        _LogResult(@"[%i] %@ %@", (int)[index integerValue], requestMethod, requestURL.path);
                        NSString *const prefix = [index stringByAppendingString:@"-"];

                        for (NSString *responseFile in files) {
                            if ([responseFile hasPrefix:prefix] && [responseFile hasSuffix:@".response"]) {
                                NSData *const responseData = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:responseFile]];

                                if (responseData) {
                                    CFHTTPMessageRef expectedResponse = _CreateHTTPMessageFromData(responseData, NO);

                                    if (expectedResponse) {
                                        CFHTTPMessageRef actualResponse = _CreateHTTPMessageFromPerformingRequest(requestData, self.port);

                                        if (actualResponse) {
                                            success = YES;

                                            CFIndex expectedStatusCode = CFHTTPMessageGetResponseStatusCode(expectedResponse);
                                            CFIndex actualStatusCode = CFHTTPMessageGetResponseStatusCode(actualResponse);

                                            if (actualStatusCode != expectedStatusCode) {
                                                _LogResult(@"  Status code not matching:\n    Expected: %i\n      Actual: %i", (int)expectedStatusCode, (int)actualStatusCode);
                                                success = NO;
                                            }

                                            NSDictionary *const expectedHeaders = CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(expectedResponse));
                                            NSDictionary *const actualHeaders = CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(actualResponse));

                                            for (NSString *expectedHeader in expectedHeaders) {
                                                if ([ignoredHeaders containsObject:expectedHeader]) {
                                                    continue;
                                                }

                                                NSString *const expectedValue = expectedHeaders[expectedHeader];
                                                NSString *const actualValue = actualHeaders[expectedHeader];

                                                if (![actualValue isEqualToString:expectedValue]) {
                                                    _LogResult(@"  Header '%@' not matching:\n    Expected: \"%@\"\n      Actual: \"%@\"", expectedHeader, expectedValue, actualValue);
                                                    success = NO;
                                                }
                                            }

                                            for (NSString *actualHeader in actualHeaders) {
                                                if (!expectedHeaders[actualHeader]) {
                                                    _LogResult(@"  Header '%@' not matching:\n    Expected: \"%@\"\n      Actual: \"%@\"", actualHeader, nil, actualHeaders[actualHeader]);
                                                    success = NO;
                                                }
                                            }

                                            NSString *const expectedContentLength = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(expectedResponse, CFSTR("Content-Length")));
                                            NSData *const expectedBody = CFBridgingRelease(CFHTTPMessageCopyBody(expectedResponse));
                                            NSString *const actualContentLength = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(actualResponse, CFSTR("Content-Length")));
                                            NSData *actualBody = CFBridgingRelease(CFHTTPMessageCopyBody(actualResponse));

                                            if ([actualContentLength isEqualToString:expectedContentLength] && (actualBody.length > expectedBody.length)) {  // Handle web browser closing connection before retrieving entire body (e.g. when playing a video file)
                                                actualBody = [actualBody subdataWithRange:NSMakeRange(0, expectedBody.length)];
                                            }

                                            if ((actualBody && expectedBody && ![actualBody isEqualToData:expectedBody]) || (actualBody && !expectedBody) || (!actualBody && expectedBody)) {
                                                _LogResult(@"  Bodies not matching:\n    Expected: %lu bytes\n      Actual: %lu bytes", (unsigned long)expectedBody.length, (unsigned long)actualBody.length);
                                                success = NO;
#if !TARGET_OS_IPHONE
#if DEBUG

                                                if (GCDWebServerIsTextContentType((NSString *)expectedHeaders[@"Content-Type"])) {
                                                    NSString *const expectedPath = [NSTemporaryDirectory() stringByAppendingPathComponent:(NSString *)[[[NSProcessInfo processInfo] globallyUniqueString] stringByAppendingPathExtension:@"txt"]];
                                                    NSString *const actualPath = [NSTemporaryDirectory() stringByAppendingPathComponent:(NSString *)[[[NSProcessInfo processInfo] globallyUniqueString] stringByAppendingPathExtension:@"txt"]];

                                                    if ([expectedBody writeToFile:expectedPath atomically:YES] && [actualBody writeToFile:actualPath atomically:YES]) {
                                                        NSTask *const task = [[NSTask alloc] init];
                                                        [task setLaunchPath:@"/usr/bin/opendiff"];
                                                        [task setArguments:@[expectedPath, actualPath]];
                                                        [task launch];
                                                    }
                                                }

#endif
#endif
                                            }

                                            CFRelease(actualResponse);
                                        }

                                        CFRelease(expectedResponse);
                                    }
                                } else {
                                    GWS_DNOT_REACHED();
                                }

                                break;
                            }
                        }

                        CFRelease(request);
                    }
                } else {
                    GWS_DNOT_REACHED();
                }

                _LogResult(@"");

                if (!success) {
                    ++result;
                }
            }
            _ExecuteMainThreadRunLoopSources();
        }

        [self stop];

        _ExecuteMainThreadRunLoopSources();
    }

    return result;
}

@end

#endif /* ifdef __GCDWEBSERVER_ENABLE_TESTING__ */
