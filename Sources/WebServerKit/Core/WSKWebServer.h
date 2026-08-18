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
#import <WebServerKit/WSKDelegate.h>
#import <WebServerKit/WSKRequest.h>
#import <WebServerKit/WSKResponse.h>
#import <WebServerKit/WSKWebServerOptions.h>
#else
#import "WSKDelegate.h"
#import "WSKRequest.h"
#import "WSKResponse.h"
#import "WSKWebServerOptions.h"
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
- (instancetype)init NS_DESIGNATED_INITIALIZER;

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
 *
 *  The one exception is a connection already draining before close (see the
 *  class documentation above): it stops draining and closes, so its client may
 *  lose that last response. Stopping never waits on a connection either way.
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
