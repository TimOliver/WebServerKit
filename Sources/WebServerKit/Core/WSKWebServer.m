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

#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#ifdef __WEBSERVERKIT_ENABLE_TESTING__
#import <AppKit/AppKit.h>
#endif
#endif
#import <dns_sd.h>
#import <netinet/in.h>
#import <objc/runtime.h>
#import <signal.h>
#import <unistd.h>

#import "WSKPrivate.h"

#if TARGET_OS_IPHONE && !TARGET_IPHONE_SIMULATOR
#define kDefaultPort 80
#else
#define kDefaultPort 8080
#endif

#define kBonjourResolutionTimeout 5.0
#define kWSKMaxConnections 128  // Upper bound on simultaneous connections, to cap file-descriptor use.

NSString *const WSKOption_Port = @"Port";
NSString *const WSKOption_BonjourName = @"BonjourName";
NSString *const WSKOption_BonjourType = @"BonjourType";
NSString *const WSKOption_BonjourTXTData = @"BonjourTXTData";
NSString *const WSKOption_RequestNATPortMapping = @"RequestNATPortMapping";
NSString *const WSKOption_BindToLocalhost = @"BindToLocalhost";
NSString *const WSKOption_AllowedHostNames = @"AllowedHostNames";
NSString *const WSKOption_MaxPendingConnections = @"MaxPendingConnections";
NSString *const WSKOption_ServerName = @"ServerName";
NSString *const WSKOption_AuthenticationMethod = @"AuthenticationMethod";
NSString *const WSKOption_AuthenticationRealm = @"AuthenticationRealm";
NSString *const WSKOption_AuthenticationAccounts = @"AuthenticationAccounts";
NSString *const WSKOption_ConnectionClass = @"ConnectionClass";
NSString *const WSKOption_AutomaticallyMapHEADToGET = @"AutomaticallyMapHEADToGET";
NSString *const WSKOption_ConnectedStateCoalescingInterval = @"ConnectedStateCoalescingInterval";
NSString *const WSKOption_DispatchQueuePriority = @"DispatchQueuePriority";
NSString *const WSKOption_ConnectionIdleTimeout = @"ConnectionIdleTimeout";
NSString *const WSKOption_ConnectionKeepAliveTimeout = @"ConnectionKeepAliveTimeout";
#if TARGET_OS_IPHONE
NSString *const WSKOption_AutomaticallySuspendInBackground = @"AutomaticallySuspendInBackground";
#endif

NSString *const WSKAuthenticationMethod_Basic = @"Basic";
NSString *const WSKAuthenticationMethod_DigestAccess = @"DigestAccess";

#if defined(__WEBSERVERKIT_LOGGING_FACILITY_BUILTIN__)
#if DEBUG
WSKLoggingLevel WSKLogLevel = kWSKLoggingLevel_Debug;
#else
WSKLoggingLevel WSKLogLevel = kWSKLoggingLevel_Info;
#endif
#endif

#if !TARGET_OS_IPHONE
// Written from a signal handler and polled from the run loop below, so it has to be
// the one type the C standard lets cross that boundary; a plain BOOL read is UB.
static volatile sig_atomic_t _run;
#endif

#ifdef __WEBSERVERKIT_LOGGING_FACILITY_BUILTIN__

static WSKBuiltInLoggerBlock _builtInLoggerBlock;

void WSKLogMessage(WSKLoggingLevel level, NSString *format, ...) {
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

#endif /* ifdef __WEBSERVERKIT_LOGGING_FACILITY_BUILTIN__ */

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

#if !TARGET_OS_IPHONE || defined(__WEBSERVERKIT_ENABLE_TESTING__)

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

@implementation WSKHandler

- (instancetype)initWithMatchBlock:(WSKMatchBlock _Nonnull)matchBlock asyncProcessBlock:(WSKAsyncProcessBlock _Nonnull)processBlock {
    if ((self = [super init])) {
        _matchBlock = [matchBlock copy];
        _asyncProcessBlock = [processBlock copy];
    }

    return self;
}

@end

// Private helpers that assume they are already running on _stateQueue. They exist so the
// public accessors can funnel through that queue without any of them re-entering it.
@interface WSKWebServer ()
- (BOOL)_startWithOptions:(NSDictionary<NSString *, id> *)options inBackground:(BOOL)inBackground error:(NSError **)error;
- (void)_stopWithOptions;
@end

// Same contract, for the helpers implemented alongside their public counterparts in the
// Extensions category.
@interface WSKWebServer (ExtensionsPrivate)
- (NSURL *)_serverURL;
- (NSURL *)_bonjourServerURL;
- (NSURL *)_publicServerURL;
@end

@implementation WSKWebServer {
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
    NSMutableArray<WSKHandler *> *_handlers;
    NSInteger _activeConnections;        // Accessed through _syncQueue only
    NSInteger _reservedConnections;      // Accepted sockets not yet counted in _activeConnections; through _syncQueue only
    BOOL _connected;                     // Accessed on main thread only
    CFRunLoopTimerRef _disconnectTimer;  // Accessed on main thread only

    NSDictionary<NSString *, id> *_options;
    NSSet<NSString *> *_allowedHostNames;
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
#ifdef __WEBSERVERKIT_ENABLE_TESTING__
    BOOL _recording;
#endif
}

+ (void)initialize {
    WSKInitializeFunctions();
}

- (instancetype)init {
    if ((self = [super init])) {
        _syncQueue = dispatch_queue_create([NSStringFromClass([self class]) UTF8String], DISPATCH_QUEUE_SERIAL);
        // The Thread Performance Checker reports a priority inversion on every -stop called
        // from the main thread. It is NOT this queue's QoS — raising it to user-initiated or
        // even user-interactive changes nothing, which was measured. The wait is inside
        // -_stop itself: dispatch_group_wait blocks on the listening sources' cancel
        // handlers, which run on dispatch_get_global_queue(_dispatchQueuePriority, 0), and
        // that priority is a documented public option (WSKOption_DispatchQueuePriority)
        // governing connection handling too. Left alone deliberately: the warning is
        // diagnostic, the wait is bounded and correct, and silencing it would mean changing
        // the priority of every accepted connection.
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
    WSK_DCHECK(_connected == NO);
    WSK_DCHECK(_activeConnections == 0);
    WSK_DCHECK(_options == nil);           // The server can never be dealloc'ed while running because of the retain-cycle with the dispatch source
    WSK_DCHECK(_disconnectTimer == NULL);  // The server can never be dealloc'ed while the disconnect timer is pending because of the retain-cycle

#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
    dispatch_release(_sourceGroup);
    dispatch_release(_stateQueue);
    dispatch_release(_syncQueue);
#endif
}

#if TARGET_OS_IPHONE

// Always called on main thread
- (void)_startBackgroundTask {
    WSK_DCHECK([NSThread isMainThread]);

    if (_backgroundTask == UIBackgroundTaskInvalid) {
        WSK_LOG_DEBUG(@"Did start background task");
        _backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            WSK_LOG_WARNING(@"Application is being suspended while %@ is still connected", [self class]);
            [self _endBackgroundTask];
        }];
    } else {
        WSK_DNOT_REACHED();
    }
}

#endif

// Always called on main thread
- (void)_didConnect {
    WSK_DCHECK([NSThread isMainThread]);
    WSK_DCHECK(_connected == NO);
    _connected = YES;
    WSK_LOG_DEBUG(@"Did connect");

#if TARGET_OS_IPHONE

    if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground) {
        [self _startBackgroundTask];
    }

#endif

    if ([_delegate respondsToSelector:@selector(webServerDidConnect:)]) {
        [_delegate webServerDidConnect:self];
    }
}

- (void)willStartConnection:(WSKConnection *)connection {
    dispatch_sync(_syncQueue, ^{
        WSK_DCHECK(self->_activeConnections >= 0);

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
    WSK_DCHECK([NSThread isMainThread]);

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
        WSK_LOG_DEBUG(@"Did end background task");
    }
}

#endif

// Always called on main thread
- (void)_didDisconnect {
    WSK_DCHECK([NSThread isMainThread]);
    WSK_DCHECK(_connected == YES);
    _connected = NO;
    WSK_LOG_DEBUG(@"Did disconnect");

#if TARGET_OS_IPHONE
    [self _endBackgroundTask];
#endif

    if ([_delegate respondsToSelector:@selector(webServerDidDisconnect:)]) {
        [_delegate webServerDidDisconnect:self];
    }
}

- (void)didEndConnection:(WSKConnection *)connection {
    dispatch_sync(_syncQueue, ^{
        WSK_DCHECK(self->_activeConnections > 0);
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
                        WSK_DCHECK([NSThread isMainThread]);
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
        // _registrationService first, because it is the one that was actually registered and so
        // the only one that carries an auto-renamed name. _resolutionService is a COPY taken
        // immediately after CFNetServiceRegisterWithOptions is *initiated* — registration is
        // asynchronous, so that copy froze the name as configured. Registering with flags 0
        // means auto-rename is enabled, so a second instance on the network becomes
        // "<name> (2)" and this property reported the original name for the rest of the run.
        CFStringRef name = self->_registrationService ? CFNetServiceGetName(self->_registrationService) : NULL;

        if ((name == NULL) || (CFStringGetLength(name) == 0)) {
            name = self->_resolutionService ? CFNetServiceGetName(self->_resolutionService) : NULL;
        }

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

- (void)addHandlerWithMatchBlock:(WSKMatchBlock)matchBlock processBlock:(WSKProcessBlock)processBlock {
    [self addHandlerWithMatchBlock:matchBlock
                 asyncProcessBlock:^(WSKRequest *request, WSKCompletionBlock completionBlock) {
                     completionBlock(processBlock(request));
                 }];
}

- (void)addHandlerWithMatchBlock:(WSKMatchBlock)matchBlock asyncProcessBlock:(WSKAsyncProcessBlock)processBlock {
    WSK_DCHECK(_options == nil);
    WSKHandler *const handler = [[WSKHandler alloc] initWithMatchBlock:matchBlock asyncProcessBlock:processBlock];
    [_handlers insertObject:handler atIndex:0];
}

- (void)removeAllHandlers {
    WSK_DCHECK(_options == nil);
    [_handlers removeAllObjects];
}

static void _NetServiceRegisterCallBack(CFNetServiceRef service, CFStreamError *error, void *info) {
    WSK_DCHECK([NSThread isMainThread]);
    @autoreleasepool {
        if (error->error) {
            WSK_LOG_ERROR(@"Bonjour registration error %i (domain %i)", (int)error->error, (int)error->domain);
        } else {
            WSKWebServer *server = (__bridge WSKWebServer *)info;
            WSK_LOG_VERBOSE(@"Bonjour registration complete for %@", [server class]);

            // Resolution can fail to start for environmental reasons (mDNSResponder
            // unavailable, service already cancelled), so log it instead of aborting.
            if (!CFNetServiceResolveWithTimeout(server->_resolutionService, kBonjourResolutionTimeout, NULL)) {
                WSK_LOG_ERROR(@"Failed starting Bonjour resolution");
            }
        }
    }
}

static void _NetServiceResolveCallBack(CFNetServiceRef service, CFStreamError *error, void *info) {
    WSK_DCHECK([NSThread isMainThread]);
    @autoreleasepool {
        if (error->error) {
            if ((error->domain != kCFStreamErrorDomainNetServices) && (error->error != kCFNetServicesErrorTimeout)) {
                WSK_LOG_ERROR(@"Bonjour resolution error %i (domain %i)", (int)error->error, (int)error->domain);
            }
        } else {
            WSKWebServer *server = (__bridge WSKWebServer *)info;
            WSK_LOG_INFO(@"%@ now locally reachable at %@", [server class], server.bonjourServerURL);

            if ([server.delegate respondsToSelector:@selector(webServerDidCompleteBonjourRegistration:)]) {
                [server.delegate webServerDidCompleteBonjourRegistration:server];
            }
        }
    }
}

// Reached only from _SocketCallBack's DNSServiceProcessResult, which already holds
// _stateQueue — so this must NOT dispatch onto it again: a nested dispatch_sync on a serial
// queue deadlocks. It still runs on the main thread, because dispatch_sync executes the
// block on the calling thread.
static void _DNSServiceCallBack(DNSServiceRef sdRef, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, uint32_t externalAddress, DNSServiceProtocol protocol, uint16_t internalPort, uint16_t externalPort, uint32_t ttl, void *context) {
    WSK_DCHECK([NSThread isMainThread]);
    @autoreleasepool {
        WSKWebServer *server = (__bridge WSKWebServer *)context;

        if ((errorCode == kDNSServiceErr_NoError) || (errorCode == kDNSServiceErr_DoubleNAT)) {
            struct sockaddr_in addr4;
            bzero(&addr4, sizeof(addr4));
            addr4.sin_len = sizeof(addr4);
            addr4.sin_family = AF_INET;
            addr4.sin_addr.s_addr = externalAddress;  // Already in network byte order
            server->_dnsAddress = WSKStringFromSockAddr((const struct sockaddr *)&addr4, NO);
            server->_dnsPort = ntohs(externalPort);
            WSK_LOG_INFO(@"%@ now publicly reachable at %@", [server class], [server _publicServerURL]);  // Not .publicServerURL: that takes _stateQueue, which we hold
        } else {
            WSK_LOG_ERROR(@"DNS service error %i", errorCode);
            server->_dnsAddress = nil;
            server->_dnsPort = 0;
        }

        // Notified asynchronously, and therefore outside _stateQueue: a delegate is free to
        // call straight back into the server — -publicServerURL and -serverURL both take
        // that queue — and doing so from inside it would deadlock.
        if ([server.delegate respondsToSelector:@selector(webServerDidUpdateNATPortMapping:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [server.delegate webServerDidUpdateNATPortMapping:server];
            });
        }
    }
}

static void _SocketCallBack(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    WSK_DCHECK([NSThread isMainThread]);
    @autoreleasepool {
        WSKWebServer *server = (__bridge WSKWebServer *)info;

        // _dnsService, _dnsAddress and _dnsPort are owned by _stateQueue, but this callback
        // arrives on the main run loop: without confining it, the main thread could load the
        // service ref here and then call into it after -_stop had already run
        // DNSServiceRefDeallocate, and _DNSServiceCallBack's ARC store to _dnsAddress could
        // race a read from -_publicServerURL. Safe to block: nothing running on _stateQueue
        // waits on the main queue.
        dispatch_sync(server->_stateQueue, ^{
            if (server->_dnsService == NULL) {
                return;  // Torn down between the run loop signalling us and getting here
            }

            DNSServiceErrorType status = DNSServiceProcessResult(server->_dnsService);

            if (status != kDNSServiceErr_NoError) {
                WSK_LOG_ERROR(@"DNS service error %i", status);
            }
        });
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
        WSKOption_Port: [NSNumber class],
        WSKOption_BonjourName: [NSString class],
        WSKOption_BonjourType: [NSString class],
        WSKOption_BonjourTXTData: [NSDictionary class],
        WSKOption_RequestNATPortMapping: [NSNumber class],
        WSKOption_BindToLocalhost: [NSNumber class],
        WSKOption_AllowedHostNames: [NSArray class],
        WSKOption_MaxPendingConnections: [NSNumber class],
        WSKOption_ServerName: [NSString class],
        WSKOption_AuthenticationMethod: [NSString class],
        WSKOption_AuthenticationRealm: [NSString class],
        WSKOption_AuthenticationAccounts: [NSDictionary class],
        WSKOption_AutomaticallyMapHEADToGET: [NSNumber class],
        WSKOption_ConnectedStateCoalescingInterval: [NSNumber class],
        WSKOption_DispatchQueuePriority: [NSNumber class],
        WSKOption_ConnectionIdleTimeout: [NSNumber class],
        WSKOption_ConnectionKeepAliveTimeout: [NSNumber class],
#if TARGET_OS_IPHONE
        WSKOption_AutomaticallySuspendInBackground: [NSNumber class],
#endif
    };

    for (NSString *key in expectedClasses) {
        NSObject *const value = options[key];
        Class const expectedClass = expectedClasses[key];

        if (value && ![value isKindOfClass:expectedClass]) {
            return [NSString stringWithFormat:@"Option \"%@\" must be of class %@", key, NSStringFromClass(expectedClass)];
        }
    }

    NSNumber *const port = options[WSKOption_Port];

    if (port && (port.unsignedIntegerValue > 65535)) {  // Also catches negatives, which wrap to a huge value.
        return [NSString stringWithFormat:@"Option \"%@\" must be in the range 0...65535", WSKOption_Port];
    }

    id const connectionClass = options[WSKOption_ConnectionClass];

    if (connectionClass && (!class_isMetaClass(object_getClass(connectionClass)) || ![(Class)connectionClass isSubclassOfClass:[WSKConnection class]])) {
        return [NSString stringWithFormat:@"Option \"%@\" must be a subclass of WSKConnection", WSKOption_ConnectionClass];
    }

    return nil;
}

static inline NSString *_EncodeBase64(NSString *string) {
    NSData *const data = [string dataUsingEncoding:NSUTF8StringEncoding];
    return [[NSString alloc] initWithData:[data base64EncodedDataWithOptions:0] encoding:NSASCIIStringEncoding];
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
                WSK_LOG_DEBUG(@"Did open %s listening socket %i", useIPv6 ? "IPv6" : "IPv4", listeningSocket);
                return listeningSocket;
            } else {
                if (error) {
                    *error = WSKMakePosixError(errno);
                }

                WSK_LOG_ERROR(@"Failed starting %s listening socket: %s (%i)", useIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
                close(listeningSocket);
            }
        } else {
            if (error) {
                *error = WSKMakePosixError(errno);
            }

            WSK_LOG_ERROR(@"Failed binding %s listening socket: %s (%i)", useIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
            close(listeningSocket);
        }
    } else {
        if (error) {
            *error = WSKMakePosixError(errno);
        }

        WSK_LOG_ERROR(@"Failed creating %s listening socket: %s (%i)", useIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
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
                WSK_LOG_ERROR(@"Failed closing %s listening socket: %s (%i)", isIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
            } else {
                WSK_LOG_DEBUG(@"Did close %s listening socket %i", isIPv6 ? "IPv6" : "IPv4", listeningSocket);
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
                    WSK_LOG_ERROR(@"Failed retrieving local address of accepted %s socket: %s (%i)", isIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
                    close(socket);
                    return;
                }

                NSData *localAddress = [NSData dataWithBytes:&localSockAddr length:localAddrLen];
                WSK_DCHECK((!isIPv6 && localSockAddr.ss_family == AF_INET) || (isIPv6 && localSockAddr.ss_family == AF_INET6));

                // This must be checked rather than assumed. If the peer's RST has already
                // reached the kernel by the time this runs, Darwin fails the option with
                // EINVAL and leaves SO_NOSIGPIPE *off* — and the first write to that
                // descriptor then raises SIGPIPE, whose default disposition terminates the
                // whole host application. Neither this library nor Foundation changes that
                // disposition, so an unauthenticated peer that connects and resets in a loop
                // kills the process within seconds. A peer that has already reset has nothing
                // to be served, so drop it here, before a connection slot is reserved.
                //
                // Deliberately not solved with signal(SIGPIPE, SIG_IGN): that mutates
                // process-wide state belonging to the host app, and would still leave this
                // descriptor without the option actually set.
                int noSigPipe = 1;

                if (setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe)) != 0) {
                    WSK_LOG_ERROR(@"Dropping accepted %s socket: SO_NOSIGPIPE could not be set (%s (%i)); the peer is already gone", isIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
                    close(socket);
                    return;
                }

                // Cap the number of simultaneous connections so a flood of (e.g. idle)
                // connections cannot exhaust file descriptors — especially important on
                // iOS where the per-process fd limit is small. The slot is reserved and
                // released around the connection's creation because the connection itself
                // only bumps _activeConnections part-way through -initWithServer:; testing
                // the count and letting the connection increment it later would let the two
                // accept sources (IPv4 and IPv6) both pass the check and exceed the cap.
                __block BOOL reserved = NO;
                dispatch_sync(self->_syncQueue, ^{
                    if (self->_activeConnections + self->_reservedConnections < kWSKMaxConnections) {
                        self->_reservedConnections += 1;
                        reserved = YES;
                    }
                });
                if (!reserved) {
                    WSK_LOG_ERROR(@"Refusing %s connection: already at the %i connection limit", isIPv6 ? "IPv6" : "IPv4", (int)kWSKMaxConnections);
                    close(socket);
                    return;
                }

                WSKConnection *connection = [(WSKConnection *)[self->_connectionClass alloc] initWithServer:self localAddress:localAddress remoteAddress:remoteAddress socket:socket];  // Connection will automatically retain itself while opened
                [connection self];                                                                                                                                                                        // Prevent compiler from complaining about unused variable / useless statement
                dispatch_sync(self->_syncQueue, ^{
                    self->_reservedConnections -= 1;
                });
            } else {
                WSK_LOG_ERROR(@"Failed accepting %s socket: %s (%i)", isIPv6 ? "IPv6" : "IPv4", strerror(errno), errno);
            }
        }
    });
    return source;
}

// Must run on _stateQueue (see the ivar comment). Never call a public accessor from here:
// those funnel through the same serial queue and would deadlock.
- (BOOL)_start:(NSError **)error {
    WSK_DCHECK(_source4 == NULL);

    NSUInteger const configuredPort = [(NSNumber *)_GetOption(_options, WSKOption_Port, @0) unsignedIntegerValue];
    NSUInteger port = configuredPort;
    // When the caller asked for an OS-assigned port (0), reuse the port we were
    // given last time so client URLs stay valid across a background/resume cycle
    // (which tears the sockets down and starts them again). See swisspol/WSKWebServer#563.
    if (configuredPort == 0 && _lastBoundPort != 0) {
        port = _lastBoundPort;
    }
    BOOL bindToLocalhost = [(NSNumber *)_GetOption(_options, WSKOption_BindToLocalhost, @NO) boolValue];
    // listen(2) takes an int backlog, so an out-of-range option would be truncated into
    // something nonsensical (possibly negative). Clamp instead of casting blindly.
    NSUInteger const requestedPendingConnections = [(NSNumber *)_GetOption(_options, WSKOption_MaxPendingConnections, @16) unsignedIntegerValue];
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
            WSK_LOG_ERROR(@"Failed retrieving socket address: %s (%i)", strerror(errno), errno);
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

    // A fixed product name rather than NSStringFromClass([self class]). This value is the
    // "Server" response header — public, observable output — and deriving it from a class
    // name meant any internal rename leaked onto the wire and invalidated every recorded
    // trace that asserts it. Subclasses used to change it silently too, which is not
    // something a subclass should decide. Use WSKOption_ServerName to override.
    _serverName = [(NSString *)_GetOption(_options, WSKOption_ServerName, kWSKServerName) copy];
    NSString *const authenticationMethod = _GetOption(_options, WSKOption_AuthenticationMethod, nil);

    if ([authenticationMethod isEqualToString:WSKAuthenticationMethod_Basic]) {
        _authenticationRealm = [(NSString *)_GetOption(_options, WSKOption_AuthenticationRealm, _serverName) copy];
        _authenticationBasicAccounts = [[NSMutableDictionary alloc] init];
        NSDictionary *accounts = _GetOption(_options, WSKOption_AuthenticationAccounts, @{});
        [accounts enumerateKeysAndObjectsUsingBlock:^(NSString *username, NSString *password, BOOL *stop) {
            [self->_authenticationBasicAccounts setObject:_EncodeBase64([NSString stringWithFormat:@"%@:%@", username, password]) forKey:username];
        }];
    } else if ([authenticationMethod isEqualToString:WSKAuthenticationMethod_DigestAccess]) {
        _authenticationRealm = [(NSString *)_GetOption(_options, WSKOption_AuthenticationRealm, _serverName) copy];
        _authenticationDigestAccounts = [[NSMutableDictionary alloc] init];
        NSDictionary *accounts = _GetOption(_options, WSKOption_AuthenticationAccounts, @{});
        [accounts enumerateKeysAndObjectsUsingBlock:^(NSString *username, NSString *password, BOOL *stop) {
            [self->_authenticationDigestAccounts setObject:WSKComputeMD5Digest(@"%@:%@:%@", username, self->_authenticationRealm, password) forKey:username];
        }];
    } else if (authenticationMethod != nil) {
        // An AuthenticationMethod was requested but doesn't match a method we implement
        // (a typo such as @"Digest" instead of @"DigestAccess" is easy to make). Neither
        // account dictionary would be populated, and enforcement gates purely on those
        // being non-nil, so we would silently run with NO authentication. Fail closed:
        // refuse to start rather than serve unauthenticated when the caller asked for auth.
        WSK_LOG_ERROR(@"Refusing to start: unknown authentication method \"%@\"", authenticationMethod);
        if (error) {
            *error = [NSError errorWithDomain:kWSKErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown authentication method \"%@\"", authenticationMethod]}];
        }
        close(listeningSocket4);
        close(listeningSocket6);
        return NO;
    }

    _connectionClass = _GetOption(_options, WSKOption_ConnectionClass, [WSKConnection class]);
    _shouldAutomaticallyMapHEADToGET = [(NSNumber *)_GetOption(_options, WSKOption_AutomaticallyMapHEADToGET, @YES) boolValue];
    _disconnectDelay = [(NSNumber *)_GetOption(_options, WSKOption_ConnectedStateCoalescingInterval, @1.0) doubleValue];
    _dispatchQueuePriority = [(NSNumber *)_GetOption(_options, WSKOption_DispatchQueuePriority, @(DISPATCH_QUEUE_PRIORITY_DEFAULT)) longValue];
    _connectionIdleTimeout = [(NSNumber *)_GetOption(_options, WSKOption_ConnectionIdleTimeout, @30.0) doubleValue];
    _connectionKeepAliveTimeout = [(NSNumber *)_GetOption(_options, WSKOption_ConnectionKeepAliveTimeout, @0.0) doubleValue];

    _source4 = [self _createDispatchSourceWithListeningSocket:listeningSocket4 isIPv6:NO];
    _source6 = [self _createDispatchSourceWithListeningSocket:listeningSocket6 isIPv6:YES];
    _port = port;
    _lastBoundPort = port;  // Remember it so a background/resume cycle keeps the same port.
    _bindToLocalhost = bindToLocalhost;

    NSString *const bonjourName = _GetOption(_options, WSKOption_BonjourName, nil);
    NSString *const bonjourType = _GetOption(_options, WSKOption_BonjourType, @"_http._tcp");

    // Names this server answers to. Anything else in a request's "Host" is refused: see
    // WSKOption_AllowedHostNames for why that is the only defence against DNS
    // rebinding. IP literals are not listed because they are recognised by shape rather
    // than by value — the interface set can change under us, and a browser cannot be made
    // to put a literal in Host while scripting from a domain, so any literal is safe.
    NSMutableSet<NSString *> *const allowedHostNames = [[NSMutableSet alloc] init];
    [allowedHostNames addObject:@"localhost"];
    NSString *const advertisedName = (bonjourName.length ? bonjourName : _serverName);

    if (advertisedName.length) {
        [allowedHostNames addObject:[WSKHostNameWithoutRootLabel([advertisedName stringByAppendingString:@".local"]) lowercaseString]];
    }

    NSString *const machineName = [[NSProcessInfo processInfo] hostName];  // Typically "<device>.local"

    if (machineName.length) {
        // A trailing dot makes an mDNS name fully qualified; browsers send it without.
        [allowedHostNames addObject:[WSKHostNameWithoutRootLabel(machineName) lowercaseString]];
    }

    // Normalized through the SAME helper the check side uses. Previously these entries were only
    // lowercased, while the incoming Host had its root label stripped — so an entry written as a
    // fully-qualified name ("puck.tailnet.ts.net.") could never match anything, and the server
    // answered 421 to every request. That is the one option a Tailscale deployment is REQUIRED to
    // set, so the failure presents as "the server just doesn't work".
    for (NSString *name in (NSArray *)_GetOption(_options, WSKOption_AllowedHostNames, @[])) {
        if ([name isKindOfClass:[NSString class]] && name.length) {
            [allowedHostNames addObject:[WSKHostNameWithoutRootLabel(name) lowercaseString]];
        }
    }

    _allowedHostNames = allowedHostNames;
    WSK_LOG_INFO(@"%@ will answer to host names %@ (and any IP address literal) on port %i", [self class], [[allowedHostNames allObjects] componentsJoinedByString:@", "], (int)_port);

    if (bonjourName) {
        _registrationService = CFNetServiceCreate(kCFAllocatorDefault, CFSTR("local."), (__bridge CFStringRef)bonjourType, (__bridge CFStringRef)(bonjourName.length ? bonjourName : _serverName), (SInt32)_port);

        if (_registrationService) {
            CFNetServiceClientContext context = {
                0, (__bridge void *)self, NULL, NULL, NULL};

            CFNetServiceSetClient(_registrationService, _NetServiceRegisterCallBack, &context);
            CFNetServiceScheduleWithRunLoop(_registrationService, CFRunLoopGetMain(), kCFRunLoopCommonModes);
            CFStreamError streamError = {
                0};

            NSDictionary *txtDataDictionary = _GetOption(_options, WSKOption_BonjourTXTData, nil);

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
                            WSK_LOG_ERROR(@"Ignoring Bonjour TXT data entry with unsupported key or value type");
                        }
                    }

                    CFDataRef txtData = CFNetServiceCreateTXTDataWithDictionary(kCFAllocatorDefault, txtDictionary);

                    if (txtData != NULL) {  // Guard: CFRelease(NULL) is a hard crash, and the dictionary may be un-encodable.
                        if (!CFNetServiceSetTXTData(_registrationService, txtData)) {
                            WSK_LOG_ERROR(@"Failed setting TXTData");
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
                WSK_LOG_ERROR(@"Failed creating CFNetService for resolution");
            }
        } else {
            WSK_LOG_ERROR(@"Failed creating CFNetService for registration");
        }
    }

    if ([(NSNumber *)_GetOption(_options, WSKOption_RequestNATPortMapping, @NO) boolValue]) {
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
                    WSK_LOG_ERROR(@"Failed creating CFRunLoopSource");
                }
            } else {
                WSK_LOG_ERROR(@"Failed creating CFSocket");
            }
        } else {
            WSK_LOG_ERROR(@"Failed creating NAT port mapping (%i)", status);
        }
    }

    dispatch_resume(_source4);
    dispatch_resume(_source6);
    WSK_LOG_INFO(@"%@ started on port %i and reachable at %@", [self class], (int)_port, [self _serverURL]);  // Not self.serverURL: that re-enters _stateQueue and would deadlock.

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
    WSK_DCHECK(_source4 != NULL);

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
    _allowedHostNames = nil;
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

    WSK_LOG_INFO(@"%@ stopped", [self class]);

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
    WSK_DCHECK([NSThread isMainThread]);
    WSK_LOG_DEBUG(@"Did enter background");

    dispatch_sync(_stateQueue, ^{
        if ((self->_backgroundTask == UIBackgroundTaskInvalid) && self->_source4) {
            [self _stop];
        }
    });
}

- (void)_willEnterForeground:(NSNotification *)notification {
    WSK_DCHECK([NSThread isMainThread]);
    WSK_LOG_DEBUG(@"Will enter foreground");

    dispatch_sync(_stateQueue, ^{
        if (!self->_source4) {
            [self _start:NULL];  // TODO: There's probably nothing we can do on failure
        }
    });
}

- (void)_reconnectInForeground:(NSNotification *)notification {
    WSK_DCHECK([NSThread isMainThread]);
    WSK_LOG_DEBUG(@"Will enter foreground (not suspending in background)");

    // When not suspending in the background we keep serving, but iOS may still
    // tear down our listening sockets once the process is actually suspended.
    // If we were running, rebuild them from scratch when returning to the
    // foreground so the server keeps accepting connections. -_start: reuses the
    // previously assigned port, so client URLs stay valid. See
    // swisspol/WSKWebServer#292. Existing (already-accepted) connections are
    // unaffected — only the listening sockets are rebuilt.
    dispatch_sync(_stateQueue, ^{
        if (self->_source4) {
            [self _stop];
            NSError *error = nil;
            BOOL const restarted = [self _start:&error];

            if (!restarted) {
                // Previously "[self _start:NULL]" with a TODO saying nothing could be done on
                // failure. Something can: log it. The listening sockets are gone and the server is
                // dead for the rest of the foreground session, so an operator staring at an
                // unreachable device otherwise has nothing at all to go on.
                //
                // Deliberately NOT a -webServerDidStop: call. -_stop above already posts one, so
                // adding a second delivered TWO callbacks for one stop — and the added one fired
                // synchronously, so it arrived FIRST and inverted the ordering against
                // -webServerDidDisconnect:. The delegate could already tell this case apart
                // without it: a failed restart delivers a stop with no matching start.
                //
                // The claim that justified that call — that -isRunning and -serverURL "still
                // answer as though it were serving" — was measured FALSE on both trees, 7/7:
                // both report stopped. Recorded here because this file has now overstated the
                // code five times, and this is the correction.
                WSK_LOG_ERROR(@"Failed restarting %@ on returning to the foreground: %@", [self class], error);
            }
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
            WSK_LOG_ERROR(@"Refusing to start: %@", invalidOption);

            if (error) {
                *error = [NSError errorWithDomain:kWSKErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: invalidOption}];
            }

            return NO;
        }

        _options = newOptions;
        _lastBoundPort = 0;  // Fresh session: don't inherit a port remembered from a previous run.
#if TARGET_OS_IPHONE
        _suspendInBackground = [(NSNumber *)_GetOption(_options, WSKOption_AutomaticallySuspendInBackground, @YES) boolValue];

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
    }

    // Deliberately NOT WSK_DNOT_REACHED(). This returns NO, so the documented way for a host
    // app to find out is *error — which was never set, leaving a caller that did exactly what
    // the header says with nothing to report and, in Debug, an abort instead of a return.
    WSK_LOG_ERROR(@"Refusing to start: the server is already running");

    if (error) {
        *error = [NSError errorWithDomain:kWSKErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"The server is already running"}];
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
    // WSKOption_AutomaticallySuspendInBackground. Previously this
    // returned YES whenever the server had been started, so it stayed YES while
    // suspended and lied about the server's state. See swisspol/WSKWebServer#437.
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
    }

    // Deliberately NOT WSK_DNOT_REACHED(). -stop on a server that never started is what an
    // error path naturally does — most obviously right after -startWithOptions:error:
    // returned NO, which leaves _options nil — and aborting a Debug build for it punished
    // exactly the careful host app. Idempotent tidy-up is the useful contract here.
}

- (void)stop {
    dispatch_sync(_stateQueue, ^{
        [self _stopWithOptions];
    });
}

@end

@implementation WSKWebServer (Extensions)

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
        NSString *ipAddress = _bindToLocalhost ? @"localhost" : WSKGetPrimaryIPAddress(NO);  // We can't really use IPv6 anyway as it doesn't work great with HTTP URLs in practice

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

    [options setObject:@(port) forKey:WSKOption_Port];
    [options setValue:name forKey:WSKOption_BonjourName];
    return [self startWithOptions:options error:NULL];
}

#if !TARGET_OS_IPHONE

- (BOOL)runWithPort:(NSUInteger)port bonjourName:(NSString *)name {
    NSMutableDictionary *options = [NSMutableDictionary dictionary];

    [options setObject:@(port) forKey:WSKOption_Port];
    [options setValue:name forKey:WSKOption_BonjourName];
    return [self runWithOptions:options error:NULL];
}

- (BOOL)runWithOptions:(NSDictionary<NSString *, id> *)options error:(NSError **)error {
    WSK_DCHECK([NSThread isMainThread]);
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

@implementation WSKWebServer (Handlers)

- (void)addDefaultHandlerForMethod:(NSString *)method requestClass:(Class)aClass processBlock:(WSKProcessBlock)block {
    [self addDefaultHandlerForMethod:method
                        requestClass:aClass
                   asyncProcessBlock:^(WSKRequest *request, WSKCompletionBlock completionBlock) {
                       completionBlock(block(request));
                   }];
}

- (void)addDefaultHandlerForMethod:(NSString *)method requestClass:(Class)aClass asyncProcessBlock:(WSKAsyncProcessBlock)block {
    [self
        addHandlerWithMatchBlock:^WSKRequest *(NSString *requestMethod, NSURL *requestURL, NSDictionary<NSString *, NSString *> *requestHeaders, NSString *urlPath, NSDictionary<NSString *, NSString *> *urlQuery) {
            if (![requestMethod isEqualToString:method]) {
                return nil;
            }

            return [(WSKRequest *)[aClass alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
        }
               asyncProcessBlock:block];
}

- (void)addHandlerForMethod:(NSString *)method path:(NSString *)path requestClass:(Class)aClass processBlock:(WSKProcessBlock)block {
    [self addHandlerForMethod:method
                         path:path
                 requestClass:aClass
            asyncProcessBlock:^(WSKRequest *request, WSKCompletionBlock completionBlock) {
                completionBlock(block(request));
            }];
}

- (void)addHandlerForMethod:(NSString *)method path:(NSString *)path requestClass:(Class)aClass asyncProcessBlock:(WSKAsyncProcessBlock)block {
    if ([path hasPrefix:@"/"] && [aClass isSubclassOfClass:[WSKRequest class]]) {
        [self
            addHandlerWithMatchBlock:^WSKRequest *(NSString *requestMethod, NSURL *requestURL, NSDictionary<NSString *, NSString *> *requestHeaders, NSString *urlPath, NSDictionary<NSString *, NSString *> *urlQuery) {
                if (![requestMethod isEqualToString:method]) {
                    return nil;
                }

                if ([urlPath caseInsensitiveCompare:path] != NSOrderedSame) {
                    return nil;
                }

                return [(WSKRequest *)[aClass alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
            }
                   asyncProcessBlock:block];
    } else {
        WSK_DNOT_REACHED();
    }
}

- (void)addHandlerForMethod:(NSString *)method pathRegex:(NSString *)regex requestClass:(Class)aClass processBlock:(WSKProcessBlock)block {
    [self addHandlerForMethod:method
                    pathRegex:regex
                 requestClass:aClass
            asyncProcessBlock:^(WSKRequest *request, WSKCompletionBlock completionBlock) {
                completionBlock(block(request));
            }];
}

- (void)addHandlerForMethod:(NSString *)method pathRegex:(NSString *)regex requestClass:(Class)aClass asyncProcessBlock:(WSKAsyncProcessBlock)block {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:regex options:NSRegularExpressionCaseInsensitive error:NULL];

    if (expression && [aClass isSubclassOfClass:[WSKRequest class]]) {
        [self
            addHandlerWithMatchBlock:^WSKRequest *(NSString *requestMethod, NSURL *requestURL, NSDictionary<NSString *, NSString *> *requestHeaders, NSString *urlPath, NSDictionary<NSString *, NSString *> *urlQuery) {
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

                WSKRequest *request = [(WSKRequest *)[aClass alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
                [request setAttribute:captures forKey:WSKRequestAttribute_RegexCaptures];
                return request;
            }
                   asyncProcessBlock:block];
    } else {
        WSK_DNOT_REACHED();
    }
}

@end

@implementation WSKWebServer (GETHandlers)

- (void)addGETHandlerForPath:(NSString *)path staticData:(NSData *)staticData contentType:(NSString *)contentType cacheAge:(NSUInteger)cacheAge {
    [self addHandlerForMethod:@"GET"
                         path:path
                 requestClass:[WSKRequest class]
                 processBlock:^WSKResponse *(WSKRequest *request) {
                     WSKResponse *response = [WSKDataResponse responseWithData:staticData contentType:contentType];
                     response.cacheControlMaxAge = cacheAge;
                     return response;
                 }];
}

- (void)addGETHandlerForPath:(NSString *)path filePath:(NSString *)filePath isAttachment:(BOOL)isAttachment cacheAge:(NSUInteger)cacheAge allowRangeRequests:(BOOL)allowRangeRequests {
    [self addHandlerForMethod:@"GET"
                         path:path
                 requestClass:[WSKRequest class]
                 processBlock:^WSKResponse *(WSKRequest *request) {
                     WSKResponse *response = nil;

                     if (allowRangeRequests) {
                         response = [WSKFileResponse responseWithFile:filePath byteRange:request.byteRange isAttachment:isAttachment ifRange:request.ifRange];
                         [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
                     } else {
                         response = [WSKFileResponse responseWithFile:filePath isAttachment:isAttachment];
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

- (WSKResponse *)_responseWithContentsOfDirectory:(NSString *)path includingHiddenItems:(BOOL)includeHiddenItems {
    NSArray *const contents = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    if (contents == nil) {
        return nil;
    }

    NSMutableString *const html = [NSMutableString string];
    [html appendString:@"<!DOCTYPE html>\n"];
    [html appendString:@"<html><head><meta charset=\"utf-8\"></head><body>\n"];
    [html appendString:@"<ul>\n"];

    for (NSString *entry in contents) {
        // The index must agree with what the handler will actually serve. With
        // allowHiddenItems:YES it served a dot-file happily while omitting it here, so the
        // browsable listing described a *smaller* tree than the one being vended — the same
        // disagreement, in the opposite direction, that the sixth pass fixed by refusing to
        // serve what this listing hid.
        if (includeHiddenItems || ![entry hasPrefix:@"."]) {
            // Classified by what a symlink points at, so the index describes what is actually
            // served — the same "the listing must agree with the handler" rule the sixth and
            // eighth passes each fixed in the other direction. A link out of the served root, or
            // a dangling one, classifies as nothing and stays unlisted, because that is what the
            // handler would refuse.
            NSString *const type = WSKServableFileTypeAtPath([path stringByAppendingPathComponent:entry], path, includeHiddenItems, NULL);

            // Any process can delete the entry between the directory read above and this
            // stat, so a missing type is an ordinary race, not a logic error to assert on.
            if (type == nil) {
                continue;
            }

            // Percent-encoding alone is not enough for an attribute value. URLPathAllowedCharacterSet
            // leaves "&" and ";" intact, and an HTML parser decodes named character references
            // inside attributes — so a file named "javascript&colon;alert(1)" was emitted
            // verbatim and the browser read the href as "javascript:alert(1)". The link *text*
            // has been HTML-escaped since the fourth pass; the attribute never was, and the two
            // halves disagreed about whether filenames are hostile. Percent-encoding has already
            // removed <, >, " and ', so this only turns "&" into "&amp;" — which is exactly what
            // defeats the entity.
            NSString *const escapedFile = _EscapeHTMLString([entry stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]]);
            WSK_DCHECK(escapedFile);

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
    return [WSKDataResponse responseWithHTML:html];
}

- (void)addGETHandlerForBasePath:(NSString *)basePath directoryPath:(NSString *)directoryPath indexFilename:(NSString *)indexFilename cacheAge:(NSUInteger)cacheAge allowRangeRequests:(BOOL)allowRangeRequests {
    [self addGETHandlerForBasePath:basePath directoryPath:directoryPath indexFilename:indexFilename cacheAge:cacheAge allowRangeRequests:allowRangeRequests allowHiddenItems:NO];
}

- (void)addGETHandlerForBasePath:(NSString *)basePath directoryPath:(NSString *)directoryPath indexFilename:(NSString *)indexFilename cacheAge:(NSUInteger)cacheAge allowRangeRequests:(BOOL)allowRangeRequests allowHiddenItems:(BOOL)allowHiddenItems {
    // The leading and trailing slashes used to be an undocumented precondition enforced by
    // WSK_DNOT_REACHED(): abort with no diagnostic in Debug, and in Release register
    // NOTHING and return, so every request 404'd with the host app given no clue why.
    // Neither spelling is ambiguous, so both are simply normalized. Only a genuinely
    // unusable base path is refused now, and loudly.
    if (basePath.length == 0) {
        WSK_LOG_ERROR(@"Refusing to add a base-path handler: the base path is empty");
        return;
    }

    if (![basePath hasPrefix:@"/"]) {
        basePath = [@"/" stringByAppendingString:basePath];
    }

    if (![basePath hasSuffix:@"/"]) {
        basePath = [basePath stringByAppendingString:@"/"];
    }

    {
        WSKWebServer *__unsafe_unretained server = self;
        [self
            addHandlerWithMatchBlock:^WSKRequest *(NSString *requestMethod, NSURL *requestURL, NSDictionary<NSString *, NSString *> *requestHeaders, NSString *urlPath, NSDictionary<NSString *, NSString *> *urlQuery) {
                if (![requestMethod isEqualToString:@"GET"]) {
                    return nil;
                }

                if (![urlPath hasPrefix:basePath]) {
                    return nil;
                }

                return [[WSKRequest alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
            }
            processBlock:^WSKResponse *(WSKRequest *request) {
                WSKResponse *response = nil;
                NSString *const requestedRelativePath = [request.path substringFromIndex:basePath.length];

                // Truncating at a NUL and then serving the prefix means answering a request the
                // client did not make: "/build.ipa\0.txt" served build.ipa, which is the very
                // extension confusion the truncation exists to prevent. Read-only here, so
                // nothing is destroyed — but the uploader and WebDAV both refuse this shape, and
                // one server quietly disagreeing is how this class has survived four sweeps.
                if (WSKPathContainsNULByte(requestedRelativePath)) {
                    WSK_LOG_WARNING(@"Refusing to serve a path containing a NUL byte");
                    return [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_BadRequest];
                }

                NSString *const relativePath = WSKNormalizePath(requestedRelativePath);

                // The directory listing below deliberately omits every dot-entry, so without
                // this the browsable index actively advertises a *smaller* tree than the one
                // being served: ".git/config", ".env" and friends stayed directly fetchable
                // and an operator checking in a browser would never see them. Both subclasses
                // that vend files already refuse hidden items; this was the one file-serving
                // path in the library with no such concept. Every component is tested, not
                // just the leaf, because the interesting secrets live *inside* a dot-directory.
                if (!allowHiddenItems) {
                    for (NSString *component in [relativePath componentsSeparatedByString:@"/"]) {
                        if ([component hasPrefix:@"."]) {
                            WSK_LOG_WARNING(@"Refusing to serve \"%@\": \"%@\" is a hidden item", relativePath, component);
                            return [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_NotFound];
                        }
                    }
                }

                NSString *filePath = [directoryPath stringByAppendingPathComponent:relativePath];
                // Stripping ".." textually is not containment: -attributesOfItemAtPath: uses
                // lstat, which only refuses a symlink as the *final* component, and O_NOFOLLOW
                // in the file response does the same — so any symlinked directory anywhere
                // under directoryPath (a git checkout, an unpacked archive) would serve files
                // from wherever it points. Resolve the whole path and require it to stay
                // inside, the way every other file-serving handler in this library does.
                // Resolved ONCE, and everything below acts on the result. Checking containment
                // with one realpath and hiddenness with another meant two observations of a
                // filesystem that need not agree, and then serving a *third* path — the one the
                // client typed, symlinks and all. A symlink retargeted between those steps served
                // content from outside the served root in 24% of requests, with no concurrency on
                // the client side at all. Serving the resolved path instead means a retargeted
                // link cannot redirect the open: a resolved path contains no symlinks.
                NSString *resolvedRelativePath = nil;
                NSString *const resolvedPath = WSKResolveWithinDirectory(filePath, directoryPath, &resolvedRelativePath);

                if (resolvedPath == nil) {
                    WSK_LOG_WARNING(@"Refusing to serve \"%@\": it resolves outside \"%@\"", filePath, directoryPath);
                    return [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_NotFound];
                }

                // Hiddenness is judged on that same observation. The textual walk above sees only
                // the path the client typed, and a symlink named "pub" pointing at ".git" carries
                // no dot in "/pub/config" while resolving inside the root — so both rules passed
                // and the file was served. Tested after containment so an escape is still reported
                // as an escape rather than mislabelled a hidden item.
                if (!allowHiddenItems) {
                    for (NSString *component in [resolvedRelativePath pathComponents]) {
                        if ([component hasPrefix:@"."]) {
                            WSK_LOG_WARNING(@"Refusing to serve \"%@\": it resolves inside a hidden item", relativePath);
                            return [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_NotFound];
                        }
                    }
                }

                filePath = resolvedPath;

                NSString *fileType = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL] fileType];

                if (fileType) {
                    if ([fileType isEqualToString:NSFileTypeDirectory]) {
                        if (indexFilename) {
                            NSString *indexPath = [filePath stringByAppendingPathComponent:indexFilename];
                            NSString *indexType = [[[NSFileManager defaultManager] attributesOfItemAtPath:indexPath error:NULL] fileType];

                            if ([indexType isEqualToString:NSFileTypeRegular]) {
                                return [WSKFileResponse responseWithFile:indexPath];
                            }
                        }

                        response = [server _responseWithContentsOfDirectory:filePath includingHiddenItems:allowHiddenItems];
                    } else if ([fileType isEqualToString:NSFileTypeRegular]) {
                        if (allowRangeRequests) {
                            response = [WSKFileResponse responseWithFile:filePath byteRange:request.byteRange isAttachment:NO ifRange:request.ifRange];
                            [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
                        } else {
                            response = [WSKFileResponse responseWithFile:filePath];
                        }
                    }
                }

                if (response) {
                    response.cacheControlMaxAge = cacheAge;
                } else {
                    response = [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_NotFound];
                }

                return response;
            }];
    }
}

@end

@implementation WSKWebServer (Logging)

+ (NSUInteger)reservedInMemoryByteCount {
    return WSKReservedMemoryLength();
}

+ (void)setLogLevel:(int)level {
#if defined(__WEBSERVERKIT_LOGGING_FACILITY_XLFACILITY__)
    [XLSharedFacility setMinLogLevel:level];
#elif defined(__WEBSERVERKIT_LOGGING_FACILITY_BUILTIN__)
    WSKLogLevel = level;
#endif
}

+ (void)setBuiltInLogger:(WSKBuiltInLoggerBlock)block {
#if defined(__WEBSERVERKIT_LOGGING_FACILITY_BUILTIN__)
    _builtInLoggerBlock = block;
#else
    WSK_DNOT_REACHED();  // Built-in logger must be enabled in order to override
#endif
}

- (void)logVerbose:(NSString *)format, ... {
    va_list arguments;

    va_start(arguments, format);
    WSK_LOG_VERBOSE(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
    va_end(arguments);
}

- (void)logInfo:(NSString *)format, ... {
    va_list arguments;

    va_start(arguments, format);
    WSK_LOG_INFO(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
    va_end(arguments);
}

- (void)logWarning:(NSString *)format, ... {
    va_list arguments;

    va_start(arguments, format);
    WSK_LOG_WARNING(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
    va_end(arguments);
}

- (void)logError:(NSString *)format, ... {
    va_list arguments;

    va_start(arguments, format);
    WSK_LOG_ERROR(@"%@", [[NSString alloc] initWithFormat:format arguments:arguments]);
    va_end(arguments);
}

@end

#ifdef __WEBSERVERKIT_ENABLE_TESTING__

@implementation WSKWebServer (Testing)

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
                    WSK_DNOT_REACHED();
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
    WSK_DCHECK([NSThread isMainThread]);
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

                                                if (WSKIsTextContentType((NSString *)expectedHeaders[@"Content-Type"])) {
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
                                    WSK_DNOT_REACHED();
                                }

                                break;
                            }
                        }

                        CFRelease(request);
                    }
                } else {
                    WSK_DNOT_REACHED();
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

#endif /* ifdef __WEBSERVERKIT_ENABLE_TESTING__ */
