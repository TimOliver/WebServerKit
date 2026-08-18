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

#import <TargetConditionals.h>

#if __has_include(<WebServerKit/WSKRequest.h>)
#import <WebServerKit/WSKRequest.h>
#import <WebServerKit/WSKResponse.h>
#else
#import "WSKRequest.h"
#import "WSKResponse.h"
#endif

NS_ASSUME_NONNULL_BEGIN

/**
 *  The WSKMatchBlock is called for every handler added to the
 *  WSKWebServer whenever a new HTTP request has started (i.e. HTTP headers have
 *  been received). The block is passed the basic info for the request (HTTP method,
 *  URL, headers...) and must decide if it wants to handle it or not.
 *
 *  If the handler can handle the request, the block must return a new
 *  WSKRequest instance created with the same basic info.
 *  Otherwise, it simply returns nil.
 */
typedef WSKRequest *_Nullable (^WSKMatchBlock)(NSString *requestMethod, NSURL *requestURL, NSDictionary<NSString *, NSString *> *requestHeaders, NSString *urlPath, NSDictionary<NSString *, NSString *> *urlQuery);

/**
 *  The WSKProcessBlock is called after the HTTP request has been fully
 *  received (i.e. the entire HTTP body has been read). The block is passed the
 *  WSKRequest created at the previous step by the WSKMatchBlock.
 *
 *  The block must return a WSKResponse or nil on error, which will
 *  result in a 500 HTTP status code returned to the client. It's however
 *  recommended to return a WSKErrorResponse on error so more useful
 *  information can be returned to the client.
 */
typedef WSKResponse *_Nullable (^WSKProcessBlock)(__kindof WSKRequest *request);

/**
 *  The WSKAsynchronousProcessBlock works like the WSKProcessBlock
 *  except the WSKResponse can be returned to the server at a later time
 *  allowing for asynchronous generation of the response.
 *
 *  The block must eventually call "completionBlock" passing a WSKResponse
 *  or nil on error, which will result in a 500 HTTP status code returned to the client.
 *  It's however recommended to return a WSKErrorResponse on error so more
 *  useful information can be returned to the client.
 */
typedef void (^WSKCompletionBlock)(WSKResponse *_Nullable response);
typedef void (^WSKAsyncProcessBlock)(__kindof WSKRequest *request, WSKCompletionBlock completionBlock);

/**
 *  The WSKBuiltInLoggerBlock is used to override the built-in logger at runtime.
 *  The block will be passed the log level and the log message, see setLogLevel for
 *  documentation of the log levels for the built-in logger.
 */
typedef void (^WSKBuiltInLoggerBlock)(int level, NSString *_Nonnull message);

/**
 *  The port used by the WSKWebServer (NSNumber / NSUInteger).
 *
 *  The default value is 0 i.e. let the OS pick a random port.
 */
extern NSString *const WSKOption_Port;

/**
 *  The Bonjour name used by the WSKWebServer (NSString). If set to an empty string,
 *  the name will automatically take the value of the WSKOption_ServerName
 *  option. If this option is set to nil, Bonjour will be disabled.
 *
 *  The default value is nil.
 */
extern NSString *const WSKOption_BonjourName;

/**
 *  The Bonjour TXT Data used by the WSKWebServer (NSDictionary<NSString, NSString>).
 *
 *  The default value is nil.
 */
extern NSString *const WSKOption_BonjourTXTData;

/**
 *  The Bonjour service type used by the WSKWebServer (NSString).
 *
 *  The default value is "_http._tcp", the service type for HTTP web servers.
 */
extern NSString *const WSKOption_BonjourType;

/**
 *  Request a port mapping in the NAT gateway (NSNumber / BOOL).
 *
 *  This uses the DNSService API under the hood which supports IPv4 mappings only.
 *
 *  The default value is NO.
 *
 *  @warning The external port set up by the NAT gateway may be different than
 *  the one used by the WSKWebServer.
 */
extern NSString *const WSKOption_RequestNATPortMapping;

/**
 *  Only accept HTTP requests coming from localhost i.e. not from the outside
 *  network (NSNumber / BOOL).
 *
 *  The default value is NO.
 *
 *  @warning Bonjour and NAT port mapping should be disabled if using this option
 *  since the server will not be reachable from the outside network anyway.
 */
extern NSString *const WSKOption_BindToLocalhost;

/**
 *  Additional host names this server will answer to, beyond the ones it accepts
 *  automatically (NSArray of NSString).
 *
 *  Every request's "Host" header is checked against an allow-list, and anything
 *  else is refused with 421. This is what stops DNS rebinding: a browser sends the
 *  *name* the page was loaded from, so a page on evil.example that has repointed
 *  its DNS at this server still sends "Host: evil.example" — and an attacker
 *  cannot make a browser send a raw IP address in Host while scripting from a
 *  domain. Without this check, every same-origin protection (CORS, Origin
 *  comparison, CSRF tokens) is bypassed, because after rebinding the attacker
 *  genuinely *is* same-origin.
 *
 *  Accepted without configuration: any IP address literal, "localhost", this
 *  machine's own host name, and the Bonjour name being advertised. Supply this
 *  option only if the server is reached under some other name — behind a reverse
 *  proxy, or via a custom DNS entry. Entries are compared case-insensitively and
 *  may include a port ("files.example:8080"); without one, any port matches.
 *
 *  A request carrying no "Host" header at all is allowed: HTTP/1.0 and many
 *  non-browser clients omit it, and rebinding requires a browser, which never does.
 *
 *  Rejections are logged with the offending name and the full accepted set, so an
 *  unanticipated deployment reports itself rather than failing mysteriously.
 */
extern NSString *const WSKOption_AllowedHostNames;

/**
 *  The maximum number of incoming HTTP requests that can be queued waiting to
 *  be handled before new ones are dropped (NSNumber / NSUInteger).
 *
 *  The default value is 16.
 */
extern NSString *const WSKOption_MaxPendingConnections;

/**
 *  The value for "Server" HTTP header used by the WSKWebServer (NSString).
 *
 *  The default value is "WebServerKit".
 */
extern NSString *const WSKOption_ServerName;

/**
 *  The authentication method used by the WSKWebServer
 *  (one of "WSKAuthenticationMethod_...").
 *
 *  The default value is nil i.e. authentication is disabled.
 */
extern NSString *const WSKOption_AuthenticationMethod;

/**
 *  The authentication realm used by the WSKWebServer (NSString).
 *
 *  The default value is the same as the WSKOption_ServerName option.
 */
extern NSString *const WSKOption_AuthenticationRealm;

/**
 *  The authentication accounts used by the WSKWebServer
 *  (NSDictionary of username / password pairs).
 *
 *  The default value is nil i.e. no accounts.
 */
extern NSString *const WSKOption_AuthenticationAccounts;

/**
 *  The class used by the WSKWebServer when instantiating WSKConnection
 *  (subclass of WSKConnection).
 *
 *  The default value is the WSKConnection class.
 */
extern NSString *const WSKOption_ConnectionClass;

/**
 *  Allow the WSKWebServer to pretend "HEAD" requests are actually "GET" ones
 *  and automatically discard the HTTP body of the response (NSNumber / BOOL).
 *
 *  The default value is YES.
 */
extern NSString *const WSKOption_AutomaticallyMapHEADToGET;

/**
 *  The interval expressed in seconds used by the WSKWebServer to decide how to
 *  coalesce calls to -webServerDidConnect: and -webServerDidDisconnect:
 *  (NSNumber / double). Coalescing will be disabled if the interval is <= 0.0.
 *
 *  The default value is 1.0 second.
 */
extern NSString *const WSKOption_ConnectedStateCoalescingInterval;

/**
 *  Set the dispatch queue priority on which server connection will be
 *  run (NSNumber / long).
 *
 *
 *  The default value is DISPATCH_QUEUE_PRIORITY_DEFAULT.
 */
extern NSString *const WSKOption_DispatchQueuePriority;

/**
 *  The timeout expressed in seconds after which a connection that is waiting on
 *  socket I/O without any bytes moving in either direction is forcibly closed
 *  (NSNumber / double). This protects against clients that connect and then go
 *  silent (or stop reading a response), which would otherwise hold their
 *  connection — and a file descriptor — forever. The timeout only applies while
 *  a socket read or write is actually pending: time spent waiting for a handler
 *  to produce a response does not count, and a connection is closed no sooner
 *  than one timeout interval and no later than two after going idle.
 *
 *  Set to 0.0 to disable idle timeouts entirely.
 *
 *  The default value is 30.0 seconds.
 */
extern NSString *const WSKOption_ConnectionIdleTimeout;

/**
 *  Allows a connection to carry more than one request, so a client does not pay
 *  a TCP handshake per request (NSNumber / double, in seconds). The value is how
 *  long an otherwise idle connection is held open waiting for the next request.
 *
 *  Reuse is deliberately restricted to requests that carry NO BODY — no
 *  "Content-Length" and no "Transfer-Encoding" header at all. Request smuggling
 *  is a disagreement about where one request's body ends and the next begins, so
 *  a connection on which no body is ever read cannot be desynchronized: the
 *  property is structural rather than a matter of parsing carefully. Anything
 *  with a body is answered and the connection is closed, exactly as before, as is
 *  any request that was refused, any HTTP/1.0 client, and any response whose
 *  length the server cannot state up front.
 *
 *  This matters most for an interface that fetches many small resources — icons,
 *  thumbnails, stylesheets — where the handshake dominates the transfer.
 *
 *  Set to 0.0 to serve exactly one request per connection.
 *
 *  The default value is 0.0.
 */
extern NSString *const WSKOption_ConnectionKeepAliveTimeout;

#if TARGET_OS_IPHONE

/**
 *  Enables the WSKWebServer to automatically suspend itself (as if -stop was
 *  called) when the iOS app goes into the background and the last
 *  WSKConnection is closed, then resume itself (as if -start was called)
 *  when the iOS app comes back to the foreground (NSNumber / BOOL).
 *
 *  See the README.md file for more information about this option.
 *
 *  The default value is YES.
 *
 *  @warning The running property will be NO while the WSKWebServer is suspended.
 */
extern NSString *const WSKOption_AutomaticallySuspendInBackground;

#endif

/**
 *  HTTP Basic Authentication scheme (see https://tools.ietf.org/html/rfc2617).
 *
 *  @warning Use of this authentication scheme is not recommended as the
 *  passwords are sent in clear.
 */
extern NSString *const WSKAuthenticationMethod_Basic;

/**
 *  HTTP Digest Access Authentication scheme (see https://tools.ietf.org/html/rfc2617).
 */
extern NSString *const WSKAuthenticationMethod_DigestAccess;

@class WSKWebServer;

/**
 *  Delegate methods for WSKWebServer.
 *
 *  @warning These methods are always called on the main thread in a serialized way.
 */
@protocol WSKDelegate <NSObject>
@optional

/**
 *  This method is called after the server has successfully started.
 */
- (void)webServerDidStart:(WSKWebServer *)server;

/**
 *  This method is called after the Bonjour registration for the server has
 *  successfully completed.
 *
 *  Use the "bonjourServerURL" property to retrieve the Bonjour address of the
 *  server.
 */
- (void)webServerDidCompleteBonjourRegistration:(WSKWebServer *)server;

/**
 *  This method is called after the NAT port mapping for the server has been
 *  updated.
 *
 *  Use the "publicServerURL" property to retrieve the public address of the
 *  server.
 */
- (void)webServerDidUpdateNATPortMapping:(WSKWebServer *)server;

/**
 *  This method is called when the first WSKConnection is opened by the
 *  server to serve a series of HTTP requests.
 *
 *  A series of HTTP requests is considered ongoing as long as new HTTP requests
 *  keep coming (and new WSKConnection instances keep being opened),
 *  until before the last HTTP request has been responded to (and the
 *  corresponding last WSKConnection closed).
 */
- (void)webServerDidConnect:(WSKWebServer *)server;

/**
 *  This method is called when the last WSKConnection is closed after
 *  the server has served a series of HTTP requests.
 *
 *  The WSKOption_ConnectedStateCoalescingInterval option can be used
 *  to have the server wait some extra delay before considering that the series
 *  of HTTP requests has ended (in case there some latency between consecutive
 *  requests). This effectively coalesces the calls to -webServerDidConnect:
 *  and -webServerDidDisconnect:.
 */
- (void)webServerDidDisconnect:(WSKWebServer *)server;

/**
 *  This method is called after the server has stopped.
 */
- (void)webServerDidStop:(WSKWebServer *)server;

@end

/**
 *  The WSKWebServer class listens for incoming HTTP requests on a given port,
 *  then passes each one to a "handler" capable of generating an HTTP response
 *  for it, which is then sent back to the client.
 *
 *  WSKWebServer instances can be created and used from any thread but it's
 *  recommended to have the main thread's runloop be running so internal callbacks
 *  can be handled e.g. for Bonjour registration.
 *
 *  Responses are delivered best-effort, not guaranteed whole. When a client is still sending as its
 *  request is answered, the server half-closes and briefly drains the socket before closing, because
 *  close(2) with unread inbound data makes the kernel send RST, and an RST destroys bytes the client
 *  has not read yet. The drain is bounded, so a client that keeps sending past the deadline or the
 *  discard cap can still lose the response — the same as a connection still draining when the server
 *  stops.
 *
 *  See the README.md file for more information about the architecture of WSKWebServer.
 */
@interface WSKWebServer : NSObject

/**
 *  Sets the delegate for the server.
 */
@property (nonatomic, weak, nullable) id<WSKDelegate> delegate;

/**
 *  Returns YES if the server is currently running, i.e. actively listening for
 *  connections. This is NO while the server is suspended in the background (see
 *  WSKOption_AutomaticallySuspendInBackground), even though it will
 *  resume automatically when the app returns to the foreground.
 */
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/**
 *  Returns the port used by the server.
 *
 *  @warning This property is only valid if the server is running.
 */
@property (nonatomic, readonly) NSUInteger port;

/**
 *  Returns the Bonjour name used by the server.
 *
 *  @warning This property is only valid if the server is running and Bonjour
 *  registration has successfully completed, which can take up to a few seconds.
 */
@property (nonatomic, readonly, nullable) NSString *bonjourName;

/**
 *  Returns the Bonjour service type used by the server.
 *
 *  @warning This property is only valid if the server is running and Bonjour
 *  registration has successfully completed, which can take up to a few seconds.
 */
@property (nonatomic, readonly, nullable) NSString *bonjourType;

/**
 *  This method is the designated initializer for the class.
 */
- (instancetype)init;

/**
 *  Adds to the server a handler that generates responses synchronously when handling incoming HTTP requests.
 *
 *  Handlers are called in a LIFO queue, so if multiple handlers can potentially
 *  respond to a given request, the latest added one wins.
 *
 *  @warning Addling handlers while the server is running is not allowed.
 */
- (void)addHandlerWithMatchBlock:(WSKMatchBlock)matchBlock processBlock:(WSKProcessBlock)processBlock;

/**
 *  Adds to the server a handler that generates responses asynchronously when handling incoming HTTP requests.
 *
 *  Handlers are called in a LIFO queue, so if multiple handlers can potentially
 *  respond to a given request, the latest added one wins.
 *
 *  @warning Addling handlers while the server is running is not allowed.
 */
- (void)addHandlerWithMatchBlock:(WSKMatchBlock)matchBlock asyncProcessBlock:(WSKAsyncProcessBlock)processBlock;

/**
 *  Removes all handlers previously added to the server.
 *
 *  @warning Removing handlers while the server is running is not allowed.
 */
- (void)removeAllHandlers;

/**
 *  Starts the server with explicit options. This method is the designated way
 *  to start the server.
 *
 *  Returns NO if the server failed to start and sets "error" argument if not NULL.
 */
- (BOOL)startWithOptions:(nullable NSDictionary<NSString *, id> *)options error:(NSError **_Nullable)error;

/**
 *  Stops the server and prevents it to accepts new HTTP requests.
 *
 *  @warning Stopping the server does not abort WSKConnection instances
 *  currently handling already received HTTP requests. These connections will
 *  continue to execute normally until completion.
 */
- (void)stop;

@end

@interface WSKWebServer (Extensions)

/**
 *  Returns the server's URL.
 *
 *  @warning This property is only valid if the server is running.
 */
@property (nonatomic, readonly, nullable) NSURL *serverURL;

/**
 *  Returns the server's Bonjour URL.
 *
 *  @warning This property is only valid if the server is running and Bonjour
 *  registration has successfully completed, which can take up to a few seconds.
 *  Also be aware this property will not automatically update if the Bonjour hostname
 *  has been dynamically changed after the server started running (this should be rare).
 */
@property (nonatomic, readonly, nullable) NSURL *bonjourServerURL;

/**
 *  Returns the server's public URL.
 *
 *  @warning This property is only valid if the server is running and NAT port
 *  mapping is active.
 */
@property (nonatomic, readonly, nullable) NSURL *publicServerURL;

/**
 *  Starts the server on port 8080 (OS X & iOS Simulator) or port 80 (iOS)
 *  using the default Bonjour name.
 *
 *  Returns NO if the server failed to start.
 */
- (BOOL)start;

/**
 *  Starts the server on a given port and with a specific Bonjour name.
 *  Pass a nil Bonjour name to disable Bonjour entirely or an empty string to
 *  use the default name.
 *
 *  Returns NO if the server failed to start.
 */
- (BOOL)startWithPort:(NSUInteger)port bonjourName:(nullable NSString *)name;

#if !TARGET_OS_IPHONE

/**
 *  Runs the server synchronously using -startWithPort:bonjourName: until a
 *  SIGINT signal is received i.e. Ctrl-C. This method is intended to be used
 *  by command line tools.
 *
 *  Returns NO if the server failed to start.
 *
 *  @warning This method must be used from the main thread only.
 */
- (BOOL)runWithPort:(NSUInteger)port bonjourName:(nullable NSString *)name;

/**
 *  Runs the server synchronously using -startWithOptions: until a SIGTERM or
 *  SIGINT signal is received i.e. Ctrl-C in Terminal. This method is intended to
 *  be used by command line tools.
 *
 *  Returns NO if the server failed to start and sets "error" argument if not NULL.
 *
 *  @warning This method must be used from the main thread only.
 */
- (BOOL)runWithOptions:(nullable NSDictionary<NSString *, id> *)options error:(NSError **_Nullable)error;

#endif

@end

@interface WSKWebServer (Handlers)

/**
 *  Adds a default handler to the server to handle all incoming HTTP requests
 *  with a given HTTP method and generate responses synchronously.
 */
- (void)addDefaultHandlerForMethod:(NSString *)method requestClass:(Class)aClass processBlock:(WSKProcessBlock)block;

/**
 *  Adds a default handler to the server to handle all incoming HTTP requests
 *  with a given HTTP method and generate responses asynchronously.
 */
- (void)addDefaultHandlerForMethod:(NSString *)method requestClass:(Class)aClass asyncProcessBlock:(WSKAsyncProcessBlock)block;

/**
 *  Adds a handler to the server to handle incoming HTTP requests with a given
 *  HTTP method and a specific case-insensitive path  and generate responses
 *  synchronously.
 */
- (void)addHandlerForMethod:(NSString *)method path:(NSString *)path requestClass:(Class)aClass processBlock:(WSKProcessBlock)block;

/**
 *  Adds a handler to the server to handle incoming HTTP requests with a given
 *  HTTP method and a specific case-insensitive path and generate responses
 *  asynchronously.
 */
- (void)addHandlerForMethod:(NSString *)method path:(NSString *)path requestClass:(Class)aClass asyncProcessBlock:(WSKAsyncProcessBlock)block;

/**
 *  Adds a handler to the server to handle incoming HTTP requests with a given
 *  HTTP method and a path matching a case-insensitive regular expression and
 *  generate responses synchronously.
 */
- (void)addHandlerForMethod:(NSString *)method pathRegex:(NSString *)regex requestClass:(Class)aClass processBlock:(WSKProcessBlock)block;

/**
 *  Adds a handler to the server to handle incoming HTTP requests with a given
 *  HTTP method and a path matching a case-insensitive regular expression and
 *  generate responses asynchronously.
 */
- (void)addHandlerForMethod:(NSString *)method pathRegex:(NSString *)regex requestClass:(Class)aClass asyncProcessBlock:(WSKAsyncProcessBlock)block;

@end

@interface WSKWebServer (GETHandlers)

/**
 *  Adds a handler to the server to respond to incoming "GET" HTTP requests
 *  with a specific case-insensitive path with in-memory data.
 */
- (void)addGETHandlerForPath:(NSString *)path staticData:(NSData *)staticData contentType:(nullable NSString *)contentType cacheAge:(NSUInteger)cacheAge;

/**
 *  Adds a handler to the server to respond to incoming "GET" HTTP requests
 *  with a specific case-insensitive path with a file.
 */
- (void)addGETHandlerForPath:(NSString *)path filePath:(NSString *)filePath isAttachment:(BOOL)isAttachment cacheAge:(NSUInteger)cacheAge allowRangeRequests:(BOOL)allowRangeRequests;

/**
 *  Adds a handler to the server to respond to incoming "GET" HTTP requests
 *  with a case-insensitive path inside a base path with the corresponding file
 *  inside a local directory. If no local file matches the request path, a 404
 *  HTTP status code is returned to the client.
 *
 *  The "indexFilename" argument allows to specify an "index" file name to use
 *  when the request path corresponds to a directory.
 *
 *  "basePath" is normalized: a missing leading or trailing "/" is added, so "files",
 *  "/files" and "/files/" all register the same handler. An empty base path registers
 *  nothing and logs an error.
 */
- (void)addGETHandlerForBasePath:(NSString *)basePath directoryPath:(NSString *)directoryPath indexFilename:(nullable NSString *)indexFilename cacheAge:(NSUInteger)cacheAge allowRangeRequests:(BOOL)allowRangeRequests;

/**
 *  As above, but able to serve hidden items.
 *
 *  Hidden items are refused by default, and "hidden" means where the bytes actually live, not
 *  what the client typed: a symlink whose own name carries no dot but which resolves inside a
 *  dot-directory is refused too. That is what makes this opt-out necessary — a deliberate
 *  convenience link such as "latest" pointing at ".builds/2026-07-25" is otherwise
 *  unreachable, with no way to permit it.
 *
 *  Passing YES serves dot-files and dot-directories like any other content. Containment is
 *  unaffected either way: a path resolving outside `directoryPath` is always refused.
 */
- (void)addGETHandlerForBasePath:(NSString *)basePath directoryPath:(NSString *)directoryPath indexFilename:(nullable NSString *)indexFilename cacheAge:(NSUInteger)cacheAge allowRangeRequests:(BOOL)allowRangeRequests allowHiddenItems:(BOOL)allowHiddenItems;

@end

/**
 *  WSKWebServer provides its own built-in logging facility which is used by
 *  default. It simply sends log messages to stderr assuming it is connected
 *  to a terminal type device.
 *
 *  WSKWebServer is also compatible with a limited set of third-party logging
 *  facilities. If one of them is available at compile time, WSKWebServer will
 *  automatically use it in place of the built-in one.
 *
 *  Currently supported third-party logging facilities are:
 *  - XLFacility (by the same author as WSKWebServer): https://github.com/swisspol/XLFacility
 *
 *  For the built-in logging facility, the default logging level is INFO
 *  (or DEBUG if the preprocessor constant "DEBUG" evaluates to non-zero at
 *  compile time).
 *
 *  It's possible to have WSKWebServer use a custom logging facility by defining
 *  the "__WEBSERVERKIT_LOGGING_HEADER__" preprocessor constant in Xcode build
 *  settings to the name of a custom header file (escaped like \"MyLogging.h\").
 *  This header file must define the following set of macros:
 *
 *    WSK_LOG_DEBUG(...)
 *    WSK_LOG_VERBOSE(...)
 *    WSK_LOG_INFO(...)
 *    WSK_LOG_WARNING(...)
 *    WSK_LOG_ERROR(...)
 *
 *  IMPORTANT: These macros must behave like NSLog(). Furthermore the WSK_LOG_DEBUG()
 *  macro should not do anything unless the preprocessor constant "DEBUG" evaluates
 *  to non-zero.
 *
 *  The logging methods below send log messages to the same logging facility
 *  used by WSKWebServer. They can be used for consistency wherever you interact
 *  with WSKWebServer in your code (e.g. in the implementation of handlers).
 */
@interface WSKWebServer (Logging)

/**
 *  Sets the log level of the logging facility below which log messages are discarded.
 *
 *  @warning The interpretation of the "level" argument depends on the logging
 *  facility used at compile time.
 *
 *  If using the built-in logging facility, the log levels are as follow:
 *  DEBUG = 0
 *  VERBOSE = 1
 *  INFO = 2
 *  WARNING = 3
 *  ERROR = 4
 */
+ (void)setLogLevel:(int)level;

/**
 *  Set a logger to be used instead of the built-in logger which logs to stderr.
 *
 *  IMPORTANT: In order for this override to work, you should not be specifying
 *  a custom logger at compile time with "__WEBSERVERKIT_LOGGING_HEADER__".
 */
+ (void)setBuiltInLogger:(WSKBuiltInLoggerBlock)block;

/**
 *  Returns the number of bytes currently reserved against the in-memory budget that every
 *  server in this process shares. Request bodies held in memory — form posts, multipart
 *  uploads, WebDAV property and lock bodies, chunked framing buffers and inflated gzip
 *  output — are charged here and released when the request that owns them is deallocated.
 *
 *  This exists to be watched by long-running hosts. When no request is in flight the value
 *  should be zero; a reading that stays high while the server is idle means a reservation
 *  has outlived its request, and since the budget is a hard ceiling, every in-memory
 *  endpoint will fail once enough of them accumulate.
 *
 *  @warning There is deliberately no way to reset this. Reservations are released by their
 *  owners during deallocation, so zeroing the counter would make those later releases
 *  underflow it — turning a bounded leak into an unbounded one. Recovering from a leak
 *  means restarting the process, which is why it is worth monitoring rather than repairing.
 */
@property (class, nonatomic, readonly) NSUInteger reservedInMemoryByteCount;

/**
 *  Logs a message to the logging facility at the VERBOSE level.
 */
- (void)logVerbose:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/**
 *  Logs a message to the logging facility at the INFO level.
 */
- (void)logInfo:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/**
 *  Logs a message to the logging facility at the WARNING level.
 */
- (void)logWarning:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/**
 *  Logs a message to the logging facility at the ERROR level.
 */
- (void)logError:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

@end

#ifdef __WEBSERVERKIT_ENABLE_TESTING__

@interface WSKWebServer (Testing)

/**
 *  Activates recording of HTTP requests and responses which create files in the
 *  current directory containing the raw data for all requests and responses.
 *
 *  @warning The current directory must not contain any prior recording files.
 */
@property (nonatomic, getter=isRecordingEnabled) BOOL recordingEnabled;

/**
 *  Runs tests by playing back pre-recorded HTTP requests in the given directory
 *  and comparing the generated responses with the pre-recorded ones.
 *
 *  Returns the number of failed tests or -1 if server failed to start.
 */
- (NSInteger)runTestsWithOptions:(nullable NSDictionary<NSString *, id> *)options inDirectory:(NSString *)path;

@end

#endif

NS_ASSUME_NONNULL_END
