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
#error WSKWebUploader requires ARC
#endif

#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#ifdef SWIFT_PACKAGE
// SwiftPM emits this accessor for any target that declares resources, naming it after the
// SwiftPM *target* — WebServerKitUploader — which is deliberately not the class prefix, so it
// does not follow a rename of the classes. Declared here rather than importing its generated header, which SwiftPM puts in
// DerivedSources without placing that directory on this target's own include path.
FOUNDATION_EXPORT NSBundle *WebServerKitUploader_SWIFTPM_MODULE_BUNDLE(void);
#endif

#import "WSKDataRequest.h"
#import "WSKDataResponse.h"
#import "WSKErrorResponse.h"
#import "WSKFileResponse.h"
#import "WSKFunctions.h"
#import "WSKMultiPartFormRequest.h"
#import "WSKStreamedResponse.h"
#import "WSKURLEncodedFormRequest.h"
#import "WSKWebUploader.h"
#import "WSKWebUploaderSSEChannel.h"

@implementation WSKWebUploaderSSEChannel {
    NSUInteger _capacity;
    NSMutableArray<NSData*>* _buffer;
    void (^_parkedReader)(NSData* data);
}

- (instancetype)init {
    return [self initWithCapacity:100];
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    if ((self = [super init])) {
        _capacity = capacity > 0 ? capacity : 1;
        _buffer = [[NSMutableArray alloc] init];
    }
    return self;
}

- (NSUInteger)capacity {
    return _capacity;
}

- (BOOL)hasParkedReader {
    return _parkedReader != nil;
}

- (NSUInteger)bufferedCount {
    return _buffer.count;
}

- (void)enqueueData:(NSData*)data {
    if (_closed) {
        return;
    }
    if (_parkedReader) {
        void (^reader)(NSData*) = _parkedReader;
        _parkedReader = nil;
        reader(data);
        return;
    }
    [_buffer addObject:data];
    if (_buffer.count > _capacity) {
        [_buffer removeObjectAtIndex:0];  // Drop oldest to stay bounded.
    }
}

- (void)parkReader:(void (^)(NSData* data))reader {
    if (_closed) {
        reader([NSData data]);  // End-of-stream: complete immediately, never park.
        return;
    }
    _idleHeartbeats = 0;  // The client came back to read: it is alive.
    if (_buffer.count > 0) {
        NSData* data = _buffer.firstObject;
        [_buffer removeObjectAtIndex:0];
        reader(data);
        return;
    }
    _parkedReader = [reader copy];
}

- (void)close {
    if (_closed) {
        return;
    }
    _closed = YES;
    [_buffer removeAllObjects];
    if (_parkedReader) {
        void (^reader)(NSData*) = _parkedReader;
        _parkedReader = nil;
        reader([NSData data]);  // End-of-stream sentinel: lets the connection finish cleanly.
    }
}

@end

NS_ASSUME_NONNULL_BEGIN

@interface WSKWebUploader (Methods)
- (nullable WSKResponse *)listDirectory:(WSKRequest *)request;
- (nullable WSKResponse *)downloadFile:(WSKRequest *)request;
- (nullable WSKResponse *)uploadFile:(WSKMultiPartFormRequest *)request;
- (nullable WSKResponse *)moveItem:(WSKURLEncodedFormRequest *)request;
- (nullable WSKResponse *)deleteItem:(WSKURLEncodedFormRequest *)request;
- (nullable WSKResponse *)createDirectory:(WSKURLEncodedFormRequest *)request;
// Declared here, with the rest of this category's methods, because the handler blocks in
// -initWithUploadDirectory: call it before its definition appears further down the file.
- (nullable WSKResponse *)_rejectIfCrossOrigin:(WSKRequest *)request;
@end

NS_ASSUME_NONNULL_END

// WSKConnection calls -performClose on the response the moment its body write chain ends,
// including the write that fails because the client has gone. Nothing listened for that, so a
// channel outlived its own connection by a full 30 seconds: the server only learned of the
// departure when a heartbeat write failed (15-30s), and only then did the reaper begin counting
// its two idle ticks. Sixteen abandoned streams therefore denied live updates to a real client
// for roughly 45-60s — a browser tab navigating away is enough, no hostility required.
@interface WSKWebUploaderSSEResponse : WSKStreamedResponse
@property (nonatomic, copy, nullable) dispatch_block_t onClose;
@end

@implementation WSKWebUploaderSSEResponse

- (void)close {
    // Taken once: -close is reachable more than once, and the block drops the channel.
    dispatch_block_t const block = _onClose;

    _onClose = nil;
    [super close];

    if (block) {
        block();
    }
}

@end

@interface WSKWebUploader () <NSFilePresenter>
@end

// Render `string` as a complete JavaScript string literal, quotes included.
//
// -initWithHTMLTemplate:variables: substitutes raw text, and index.html places the
// device name inside a quoted JS string ("var _device = %device%;"). HTML escaping is
// the wrong context there: a name containing a quote would break the literal, and one
// containing "</script>" would end the whole block. JSON string syntax is a subset of
// JavaScript's, so let NSJSONSerialization do the escaping, then neutralise "<" as well
// since JSON leaves it alone and it is what makes "</script>" dangerous.
static NSString *_JavaScriptStringLiteral(NSString *string) {
    NSData *const data = [NSJSONSerialization dataWithJSONObject:@[string ? string : @""] options:0 error:NULL];
    NSString *const array = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;

    if (array.length < 2) {
        return @"\"\"";
    }

    NSString *const literal = [array substringWithRange:NSMakeRange(1, array.length - 2)];  // Strip the enclosing "[" and "]".
    return [literal stringByReplacingOccurrencesOfString:@"<" withString:@"\\u003c"];
}

// An SSE stream never ends by itself: it pins one of WSKWebServer's 128 connection
// slots for as long as the browser keeps it open, and the 15s heartbeat keeps the
// connection idle timeout from ever reaping it. Unbounded, a handful of "GET /events"
// requests therefore denies service to the whole server, so cap concurrent streams
// well below the connection limit. A page only ever opens one.
static const NSUInteger kMaxSSEChannels = 16;

// Body returned to a client that arrives when every SSE slot is taken. It is a complete —
// if eventless — event stream: the "retry" field moves EventSource off its ~3 second
// default so a refused client backs off instead of hammering the endpoint (and the log)
// until a slot frees up.
static NSString *const kSSERefusedStreamBody = @"retry: 30000\n\n";

// First chunk of an accepted stream, restoring the prompt reconnect delay for a client
// that was refused earlier: EventSource remembers the last "retry" value it was given.
static NSString *const kSSEAcceptedStreamPreamble = @"retry: 3000\n\n";

// A refused EventSource retries forever, so warn about refusals at most this often
// rather than once per attempt per client.
static const NSTimeInterval kSSERefusalLogInterval = 60.0;

// Delivery of coalesced file-system changes is debounced by this much, but never
// postponed by more than the maximum below: without a ceiling, sustained file activity
// keeps pushing the deadline out and clients see no "external" event at all.
static const NSTimeInterval kChangeCoalescingInterval = 0.1;
static const NSTimeInterval kChangeCoalescingMaxDelay = 1.0;

@implementation WSKWebUploader {
    NSMutableArray<WSKWebUploaderSSEChannel *> *_sseChannels;  // One per connected /events client. Accessed only on _sseQueue.
    dispatch_queue_t _sseQueue;
    BOOL _sseAcceptingChannels;  // Owned by _sseQueue. YES only between -start and -stop, while SSE is enabled.
    NSDate *_lastSSERefusalLogDate;  // Owned by _sseQueue. Rate-limits the "at capacity" warning.
    dispatch_source_t _heartbeatTimer;
    BOOL _heartbeatSuspended;  // Owned by _sseQueue (except in -dealloc). Keeps suspend/resume balanced.
    NSOperationQueue *_filePresenterQueue;
    NSMutableSet<NSString *> *_pendingChangedPaths;
    NSTimer *_changeCoalescingTimer;
    NSDate *_firstPendingChangeDate;  // Main thread only, alongside _changeCoalescingTimer.
    BOOL _filePresenterRegistered;
    NSObject *_fileOperationLock;  // Serializes "pick a unique path, then create it" against concurrent requests.
}

@dynamic delegate;

@synthesize serverSentEventsEnabled = _serverSentEventsEnabled;

- (instancetype)initWithUploadDirectory:(NSString *)path {
    if ((self = [super init])) {
        // SwiftPM copies the web assets into the package's own resource bundle rather than
        // into the consumer's main bundle, and for a statically linked target
        // +bundleForClass: returns the main bundle — so the generated accessor is the only
        // thing that finds them there. Every other distribution (the framework, CocoaPods)
        // keeps the bundle alongside the class.
#ifdef SWIFT_PACKAGE
        NSBundle *const ownerBundle = WebServerKitUploader_SWIFTPM_MODULE_BUNDLE();
#else
        NSBundle *const ownerBundle = [NSBundle bundleForClass:[WSKWebUploader class]];
#endif
        NSString *const bundlePath = [ownerBundle pathForResource:@"WSKWebUploader" ofType:@"bundle"];

        if (bundlePath == nil) {
            return nil;
        }

        NSBundle *const siteBundle = [NSBundle bundleWithPath:bundlePath];

        if (siteBundle == nil) {
            return nil;
        }

        // Standardize once, so the root has no trailing separator and no "." components:
        // client-facing relative paths are derived by chopping _uploadDirectory.length off
        // an absolute path, which silently produces the wrong answer for "/Docs/" and can
        // raise NSRangeException for a pathological run of separators.
        _uploadDirectory = [[path stringByStandardizingPath] copy];
        _serverSentEventsEnabled = YES;
        _sseChannels = [NSMutableArray array];
        _sseQueue = dispatch_queue_create("com.gcdwebuploader.sse", DISPATCH_QUEUE_SERIAL);
        _pendingChangedPaths = [NSMutableSet set];
        _fileOperationLock = [[NSObject alloc] init];
        _filePresenterQueue = [[NSOperationQueue alloc] init];
        _filePresenterQueue.maxConcurrentOperationCount = 1;
        [self _createHeartbeatTimer];
        // The NSFilePresenter is registered on -start and removed on -stop (see
        // -_updateFilePresenterRegistration) so we only participate in system file
        // coordination while actually serving, not for the object's whole lifetime.
        WSKWebUploader *const __unsafe_unretained server = self;

        // Resource files. cacheAge:0 sends "Cache-Control: no-cache" so browsers
        // revalidate (via ETag/Last-Modified) on every load instead of caching for
        // an hour. Unchanged files still return a cheap 304, but after an app
        // update the rebuilt bundle changes each file's ETag, so the new assets
        // (e.g. index.js) are picked up immediately rather than served stale.
        // Registered FIRST so that it is matched LAST — handlers are inserted at index 0, so
        // registration order is reverse match order. A GET that nothing else claims answers 404
        // rather than the 501 the server returns when no handler matches at all, which is a
        // statement about the *method* and wrong here. Serving the bundle root used to supply
        // this incidentally: every unmatched GET fell through to a missing-file 404. Scoping the
        // asset handlers below took that away, so "/favicon.ico" — which browsers request
        // unprompted — began answering "Not Implemented". Matches GET only, which is exactly
        // what the base path handler did, so no other method's status changes.
        [self addHandlerWithMatchBlock:^WSKRequest *(NSString *requestMethod, NSURL *requestURL, NSDictionary<NSString *, NSString *> *requestHeaders, NSString *urlPath, NSDictionary<NSString *, NSString *> *urlQuery) {
            if (![requestMethod isEqualToString:@"GET"]) {
                return nil;
            }

            return [[WSKRequest alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
        }
            processBlock:^WSKResponse *(WSKRequest *request) {
                return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", request.path];
            }];

        //
        // Only the three asset directories the page actually loads are served. Serving the
        // bundle's *root* also exposed index.html — which is the template, and which the base
        // path handler returns raw: placeholders unsubstituted and, the point, without the
        // framing headers the page handler below sets. Framing "/index.html" instead of "/"
        // therefore defeated the clickjacking defence completely.
        //
        // Excluding it by path does not hold: the base path handler normalizes, so with an
        // exact-path alias in front of it "/./index.html" and "/x/../index.html" still reach
        // the raw file (both verified). Serving only what the page asks for takes the template
        // — and en.lproj/Localizable.strings, which no browser ever needs — out of the URL
        // space altogether, so there is no spelling left to find.
        for (NSString *const assetDirectory in @[ @"css", @"js", @"fonts" ]) {
            [self addGETHandlerForBasePath:[NSString stringWithFormat:@"/%@/", assetDirectory]
                             directoryPath:[(NSString *)[siteBundle resourcePath] stringByAppendingPathComponent:assetDirectory]
                             indexFilename:nil
                                  cacheAge:0
                        allowRangeRequests:NO];
        }

        // Web page
        WSKProcessBlock const servePage = ^WSKResponse *(WSKRequest *request) {
#if TARGET_OS_IPHONE
                         NSString *device = [[UIDevice currentDevice] name];
#else
                NSString *device = [[NSHost currentHost] localizedName];
#endif
                         NSString *title = server.title;

                         if (title == nil) {
                             title = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];

                             if (title == nil) {
                                 title = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
                             }

#if !TARGET_OS_IPHONE

                             if (title == nil) {
                                 title = [[NSProcessInfo processInfo] processName];
                             }

#endif
                         }

                         NSString *header = server.header;

                         if (header == nil) {
                             header = title;
                         }

                         NSString *prologue = server.prologue;

                         if (prologue == nil) {
                             prologue = [siteBundle localizedStringForKey:@"PROLOGUE" value:@"" table:nil];
                         }

                         NSString *epilogue = server.epilogue;

                         if (epilogue == nil) {
                             epilogue = [siteBundle localizedStringForKey:@"EPILOGUE" value:@"" table:nil];
                         }

                         NSString *footer = server.footer;

                         if (footer == nil) {
                             NSString *name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];

                             if (name == nil) {
                                 name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
                             }

                             NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
#if !TARGET_OS_IPHONE

                             if (!name && !version) {
                                 name = @"OS X";
                                 version = [[NSProcessInfo processInfo] operatingSystemVersionString];
                             }

#endif
                             footer = [NSString stringWithFormat:[siteBundle localizedStringForKey:@"FOOTER_FORMAT" value:@"" table:nil], name, version];
                         }

                         // Every value must be non-nil: a nil in a dictionary literal raises
                         // NSInvalidArgumentException, which would abort the app on "GET /".
                         // Both sources can legitimately be nil — -[NSHost localizedName] for a
                         // host with no resolvable name, and the bundle keys for a bundle that
                         // declares neither a display name nor a name.
                         WSKDataResponse *const response =
                             [WSKDataResponse responseWithHTMLTemplate:(NSString *)[siteBundle pathForResource:@"index" ofType:@"html"]
                                                                      variables:@{
                                                                          @"device": _JavaScriptStringLiteral(device),  // Substituted into a JS string literal, which supplies its own quotes.
                                                                          @"title": title ? title : @"",
                                                                          @"header": header ? header : @"",
                                                                          @"prologue": prologue ? prologue : @"",
                                                                          @"epilogue": epilogue ? epilogue : @"",
                                                                          @"footer": footer ? footer : @""
                                                                      }];

                         // The UI's one-click delete and move buttons are worth clickjacking —
                         // and the "#/path" fragment even lets an attacker aim the framed page
                         // at a chosen folder — so refuse to be framed at all. Only
                         // "frame-ancestors" is set: a full CSP would have to allow
                         // "unsafe-eval", because the bundled tmpl.min.js compiles its
                         // templates with "new Function".
                         [response setValue:@"DENY" forAdditionalHeader:@"X-Frame-Options"];
                         [response setValue:@"frame-ancestors 'none'" forAdditionalHeader:@"Content-Security-Policy"];
                         [response setValue:@"nosniff" forAdditionalHeader:@"X-Content-Type-Options"];
                         return response;
        };

        [self addHandlerForMethod:@"GET" path:@"/" requestClass:[WSKRequest class] processBlock:servePage];
        // Convenience only — "/index.html" is the obvious thing to type, and it used to work
        // when the bundle root was served. It is *not* what keeps the raw template unreachable:
        // that is the scoped asset handlers above, because an exact path like this one is not a
        // containment boundary ("/./index.html" does not match it).
        [self addHandlerForMethod:@"GET" path:@"/index.html" requestClass:[WSKRequest class] processBlock:servePage];

        // File listing
        [self addHandlerForMethod:@"GET"
                             path:@"/list"
                     requestClass:[WSKRequest class]
                     processBlock:^WSKResponse *(WSKRequest *request) {
                         return [server listDirectory:request];
                     }];

        // File download
        [self addHandlerForMethod:@"GET"
                             path:@"/download"
                     requestClass:[WSKRequest class]
                     processBlock:^WSKResponse *(WSKRequest *request) {
                         return [server downloadFile:request];
                     }];

        // File upload
        [self addHandlerForMethod:@"POST"
                             path:@"/upload"
                     requestClass:[WSKMultiPartFormRequest class]
                     processBlock:^WSKResponse *(WSKRequest *request) {
                         return [server uploadFile:(WSKMultiPartFormRequest *)request];
                     }];

        // File and folder moving
        [self addHandlerForMethod:@"POST"
                             path:@"/move"
                     requestClass:[WSKURLEncodedFormRequest class]
                     processBlock:^WSKResponse *(WSKRequest *request) {
                         return [server moveItem:(WSKURLEncodedFormRequest *)request];
                     }];

        // File and folder deletion
        [self addHandlerForMethod:@"POST"
                             path:@"/delete"
                     requestClass:[WSKURLEncodedFormRequest class]
                     processBlock:^WSKResponse *(WSKRequest *request) {
                         return [server deleteItem:(WSKURLEncodedFormRequest *)request];
                     }];

        // Directory creation
        [self addHandlerForMethod:@"POST"
                             path:@"/create"
                     requestClass:[WSKURLEncodedFormRequest class]
                     processBlock:^WSKResponse *(WSKRequest *request) {
                         return [server createDirectory:(WSKURLEncodedFormRequest *)request];
                     }];

        // Server-Sent Events endpoint
        [self addHandlerForMethod:@"GET"
                             path:@"/events"
                     requestClass:[WSKRequest class]
             asyncProcessBlock:^(WSKRequest *request, WSKCompletionBlock completionBlock) {
                         if (!server.serverSentEventsEnabled) {
                             completionBlock([WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"SSE not enabled"]);
                             return;
                         }

                         // A mapped HEAD never reads the body, so registering a channel for one
                         // hands out a slot that no client will ever hold or release: it is only
                         // recovered by the heartbeat reaper, two ticks later. Sixteen HEADs — which
                         // cost the sender nothing, since each request *completes* and frees its
                         // connection slot immediately — therefore deny live updates to every real
                         // client for ~30s, and repeating them sustains that indefinitely. The
                         // Sec-Fetch-* checks below do not help: they are about which origin is
                         // asking, and this costs nothing to ask from anywhere on the network.
                         // A bodiless reply is the right answer to HEAD regardless.
                         if (request.isVirtualHEAD) {
                             completionBlock([WSKDataResponse responseWithData:[NSData data] contentType:@"text/event-stream"]);
                             return;
                         }

                         // The same rule the mutating endpoints use. Without it this endpoint is
                         // the one place a cross-origin page can still reach: the Sec-Fetch-*
                         // checks below fail *open* when the headers are absent, and they are
                         // absent on every browser predating them (Safari < 16.4, Firefox < 90).
                         // Such a browser can hold every channel from any origin.
                         WSKResponse *const crossOrigin = [server _rejectIfCrossOrigin:request];

                         if (crossOrigin) {
                             completionBlock(crossOrigin);
                             return;
                         }

                         // An SSE stream never ends by itself and there are only
                         // kMaxSSEChannels slots, so any page that can merely *open* this URL
                         // as a subresource — "new Image().src = 'http://host:port/events'",
                         // twenty times over, from any origin — pins every slot and silently
                         // kills live updates for the real user. EventSource always sends
                         // "Accept: text/event-stream", and browsers that send Sec-Fetch-Dest
                         // label it "empty"; both are forbidden header names, so page script
                         // cannot forge them onto an <img>/<script>/<link> load. Non-browser
                         // clients send no Sec-Fetch-* at all and are unaffected.
                         //
                         // "Accept" alone is not sufficient: fetch(url, {mode: 'no-cors'})
                         // may set it, so a page can request this URL cross-origin without a
                         // preflight and without ever reading the reply — which is all that
                         // is needed to hold the slot. Sec-Fetch-Mode and Sec-Fetch-Site
                         // close that: EventSource is always a cors-mode fetch, and the
                         // page's own EventSource is same-origin, whereas a no-cors fetch is
                         // labelled "no-cors" and cross-site by the browser itself.
                         NSString *const accept = request.headers[@"Accept"];
                         NSString *const fetchDest = request.headers[@"Sec-Fetch-Dest"];
                         NSString *const fetchMode = request.headers[@"Sec-Fetch-Mode"];
                         NSString *const fetchSite = request.headers[@"Sec-Fetch-Site"];

                         if (([accept rangeOfString:@"text/event-stream" options:NSCaseInsensitiveSearch].location == NSNotFound) ||
                             (fetchDest.length && ([fetchDest caseInsensitiveCompare:@"empty"] != NSOrderedSame)) ||
                             (fetchMode.length && ([fetchMode caseInsensitiveCompare:@"cors"] != NSOrderedSame)) ||
                             (fetchSite.length && ([fetchSite caseInsensitiveCompare:@"same-origin"] != NSOrderedSame))) {
                             completionBlock([WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotAcceptable message:@"This endpoint only serves \"text/event-stream\" requests"]);
                             return;
                         }

                         // Each connection gets its own channel, which buffers events so that
                         // nothing is dropped in the window between WSKWebServer consuming one
                         // reader and asking for the next (its streaming API is a ping-pong).
                         WSKWebUploaderSSEChannel *channel = [[WSKWebUploaderSSEChannel alloc] init];
                         dispatch_async(server->_sseQueue, ^{
                             // Decide on the SSE queue, which owns _sseAcceptingChannels and
                             // _sseChannels: the server may have been stopped (or SSE disabled)
                             // between the check above and now, and a channel added after that
                             // cleanup would never be serviced or reaped again — the heartbeat
                             // that would reap it is gone too — stranding the connection on a
                             // parked reader forever. Answering here instead ends it cleanly.
                             if (!server->_sseAcceptingChannels) {
                                 [channel close];
                                 completionBlock([WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"SSE not enabled"]);
                                 return;
                             }

                             if (server->_sseChannels.count >= kMaxSSEChannels) {
                                 // At the cap: refuse rather than pin another connection slot. The
                                 // browser's EventSource reconnects on its own, so a client that
                                 // loses the race recovers once a slot frees up — but tell it to
                                 // wait, and do not log once per attempt while it waits.
                                 NSDate *const now = [NSDate date];

                                 if ((server->_lastSSERefusalLogDate == nil) || ([now timeIntervalSinceDate:server->_lastSSERefusalLogDate] >= kSSERefusalLogInterval)) {
                                     server->_lastSSERefusalLogDate = now;
                                     [server logWarning:@"Refused a Server-Sent Events connection: already streaming to the maximum of %lu clients", (unsigned long)kMaxSSEChannels];
                                 }

                                 [channel close];
                                 completionBlock([WSKDataResponse responseWithData:(NSData *)[kSSERefusedStreamBody dataUsingEncoding:NSUTF8StringEncoding] contentType:@"text/event-stream"]);
                                 return;
                             }

                             [server->_sseChannels addObject:channel];
                             // Buffered now, delivered as the stream's first chunk: undoes the
                             // back-off above for a client that was refused on an earlier attempt.
                             [channel enqueueData:(NSData *)[kSSEAcceptedStreamPreamble dataUsingEncoding:NSUTF8StringEncoding]];

                             WSKWebUploaderSSEResponse *response =
                                 [WSKWebUploaderSSEResponse responseWithContentType:@"text/event-stream"
                                                                      asyncStreamBlock:^(WSKBodyReaderCompletionBlock dataBlock) {
                                     dispatch_async(server->_sseQueue, ^{
                                         [channel parkReader:^(NSData *data) {
                                             dataBlock(data, nil);
                                         }];
                                     });
                                 }];
                             // Let the channel die with the connection rather than waiting for
                             // the reaper to notice. The reaper stays as the backstop for a
                             // client that is merely silent — this only fires when the body
                             // write chain has actually ended. Weak, because the response
                             // outlives nothing but must not keep the uploader alive; the
                             // handler's own capture is __unsafe_unretained.
                             __weak WSKWebUploader *const weakServer = server;
                             response.onClose = ^{
                                 WSKWebUploader *const strongServer = weakServer;

                                 if (strongServer == nil) {
                                     return;
                                 }

                                 dispatch_async(strongServer->_sseQueue, ^{
                                     [strongServer->_sseChannels removeObject:channel];
                                     [channel close];  // Completes any parked reader; harmless if already closed.
                                 });
                             };
                             response.cacheControlMaxAge = 0;
                             [response setValue:@"no-cache" forAdditionalHeader:@"Cache-Control"];
                             // No "Connection: keep-alive" here: it would overwrite the connection
                             // layer's "Connection: Close", and WSKWebServer never reads a second
                             // request off a connection, so advertising keep-alive is a lie.
                             completionBlock(response);
                         });
                     }];
    }

    return self;
}

- (void)_createHeartbeatTimer {
    _heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _sseQueue);
    dispatch_source_set_timer(_heartbeatTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                              15 * NSEC_PER_SEC,
                              1 * NSEC_PER_SEC);
    __weak WSKWebUploader *weakSelf = self;
    dispatch_source_set_event_handler(_heartbeatTimer, ^{
        [weakSelf _sendHeartbeat];
    });
    // Deliberately left suspended (the state a new dispatch source starts in). The
    // heartbeat only has work to do between -start and -stop; resuming it here would wake
    // the process every 15 seconds for the whole lifetime of an uploader that is merely
    // alive. -_updateHeartbeatTimerState arms and disarms it.
    _heartbeatSuspended = YES;
}

// dispatch_suspend/dispatch_resume are counted and must balance, so the flag that tracks
// them is owned by _sseQueue — the timer's own queue — and only ever changed there.
- (void)_updateHeartbeatTimerState {
    BOOL const suspend = !(self.isRunning && _serverSentEventsEnabled);
    dispatch_async(_sseQueue, ^{
        if (self->_heartbeatSuspended == suspend) {
            return;
        }

        self->_heartbeatSuspended = suspend;

        if (suspend) {
            dispatch_suspend(self->_heartbeatTimer);
        } else {
            dispatch_resume(self->_heartbeatTimer);
        }
    });
}

// The NSFilePresenter registration participates in system-wide file coordination,
// so it is only installed while SSE is enabled. Guarded so add/remove stay balanced.
- (void)_registerFilePresenter {
    @synchronized(self) {
        if (!_filePresenterRegistered) {
            [NSFileCoordinator addFilePresenter:self];
            _filePresenterRegistered = YES;
        }
    }
}

- (void)_unregisterFilePresenter {
    @synchronized(self) {
        if (_filePresenterRegistered) {
            [NSFileCoordinator removeFilePresenter:self];
            _filePresenterRegistered = NO;
        }
    }
}

// The file presenter should be registered only while the server is actually
// running AND SSE is enabled. Centralised here and driven from -start/-stop and
// the SSE toggle. Idempotent (the register/unregister helpers are guarded).
- (void)_updateFilePresenterRegistration {
    if (self.isRunning && _serverSentEventsEnabled) {
        [self _registerFilePresenter];
    } else {
        [self _unregisterFilePresenter];
    }
}

- (void)setServerSentEventsEnabled:(BOOL)enabled {
    if (_serverSentEventsEnabled == enabled) {
        return;
    }
    _serverSentEventsEnabled = enabled;
    [self _updateFilePresenterRegistration];
    [self _updateHeartbeatTimerState];
    if (enabled) {
        BOOL const running = self.isRunning;
        dispatch_async(_sseQueue, ^{
            self->_sseAcceptingChannels = running;
        });
        return;
    }
    dispatch_async(_sseQueue, ^{
        // Stop accepting first: a registration landing after the drain below would add a
        // channel nothing services or reaps any more, stranding its connection.
        self->_sseAcceptingChannels = NO;
        // Close before dropping: an unclosed channel with a parked reader
        // strands its connection forever (and leaks it via a retain cycle).
        for (WSKWebUploaderSSEChannel* channel in self->_sseChannels) {
            [channel close];
        }
        [self->_sseChannels removeAllObjects];
    });
}

- (BOOL)startWithOptions:(NSDictionary<NSString *, id> *)options error:(NSError **)error {
    // Arm SSE registration before the listening socket goes live, so a "/events" request
    // accepted immediately after start is not refused by the disarmed state -stop left behind.
    BOOL const enabled = _serverSentEventsEnabled;
    dispatch_async(_sseQueue, ^{
        self->_sseAcceptingChannels = enabled;
    });
    BOOL const started = [super startWithOptions:options error:error];
    if (!started) {
        // -stop is not called after a failed start, so disarm what was armed above:
        // otherwise the registry keeps accepting channels that nothing ever services or
        // reaps (there is no heartbeat and no listening socket), stranding any connection
        // a later start hands it.
        dispatch_async(_sseQueue, ^{
            self->_sseAcceptingChannels = NO;
        });
        return NO;
    }
    [self _updateFilePresenterRegistration];
    [self _updateHeartbeatTimerState];
    return YES;
}

- (void)stop {
    [super stop];
    // No longer serving: stop observing the file system and actively end any
    // lingering SSE connections. Each channel must be closed (not just dropped):
    // closing completes the parked reader with end-of-stream so the connection
    // finishes its response and releases its socket, whereas merely emptying the
    // array would strand the connection parked forever, leaking the socket, the
    // connection, and the server through a retain cycle.
    [self _updateFilePresenterRegistration];
    dispatch_async(_sseQueue, ^{
        // Disarm before draining. A "/events" registration already in flight would
        // otherwise land in the emptied registry, where nothing ever closes or reaps it
        // (the heartbeat is stopped too) — the connection stays parked forever, and
        // _activeConnections never returns to zero.
        self->_sseAcceptingChannels = NO;
        for (WSKWebUploaderSSEChannel* channel in self->_sseChannels) {
            [channel close];
        }
        [self->_sseChannels removeAllObjects];
    });
    // Queued after the drain, so the last tick cannot race it: with no channels left the
    // heartbeat has nothing to keep alive, and an armed timer would go on waking the
    // process every 15 seconds for as long as the stopped uploader is retained.
    [self _updateHeartbeatTimerState];
}

#pragma mark - NSFilePresenter

- (NSURL *)presentedItemURL {
    return [NSURL fileURLWithPath:_uploadDirectory];
}

- (NSOperationQueue *)presentedItemOperationQueue {
    return _filePresenterQueue;
}

- (void)presentedSubitemDidChangeAtURL:(NSURL *)url {
    if (!_serverSentEventsEnabled) {
        return;
    }

    // Convert to a relative path. Resolve symlinks on both sides first: the URL
    // handed to us can be rooted at /private/var while _uploadDirectory is /var
    // (or vice-versa), and a raw hasPrefix: would then miss and report every
    // change as the root directory.
    NSString *base = [[[NSURL fileURLWithPath:_uploadDirectory] URLByResolvingSymlinksInPath] path];
    NSString *absolutePath = [[url URLByResolvingSymlinksInPath] path];
    NSString *relativePath = @"/";
    if ([absolutePath isEqualToString:base]) {
        relativePath = @"/";
    } else if ([absolutePath hasPrefix:[base stringByAppendingString:@"/"]]) {
        relativePath = [absolutePath substringFromIndex:base.length];
    }

    // Get the directory containing the changed item
    NSString *changedDirectory = [relativePath stringByDeletingLastPathComponent];
    if (changedDirectory.length == 0 || ![changedDirectory hasPrefix:@"/"]) {
        changedDirectory = @"/";
    }
    if (![changedDirectory hasSuffix:@"/"]) {
        changedDirectory = [changedDirectory stringByAppendingString:@"/"];
    }

    @synchronized(_pendingChangedPaths) {
        [_pendingChangedPaths addObject:changedDirectory];
    }

    // Coalesce rapid changes with a short timer. Use the block-based API capturing
    // a weak reference so the scheduled timer never retains self — a target:self
    // timer would keep self alive (and, under continuous file activity, perpetually
    // renew that retain), preventing deterministic teardown.
    __weak WSKWebUploader *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        WSKWebUploader *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        // Debouncing alone has no ceiling: sustained activity (a large copy, an app
        // rewriting files in a loop) pushes the deadline out on every callback, so
        // clients would never be told anything changed. Once the oldest pending change
        // has waited long enough, stop rescheduling and let the armed timer fire.
        NSDate *const now = [NSDate date];
        if (strongSelf->_firstPendingChangeDate == nil) {
            strongSelf->_firstPendingChangeDate = now;
        } else if ([now timeIntervalSinceDate:strongSelf->_firstPendingChangeDate] >= kChangeCoalescingMaxDelay) {
            return;
        }
        [strongSelf->_changeCoalescingTimer invalidate];
        strongSelf->_changeCoalescingTimer = [NSTimer scheduledTimerWithTimeInterval:kChangeCoalescingInterval
                                                                              repeats:NO
                                                                                block:^(NSTimer *timer) {
            [weakSelf _flushPendingChanges];
        }];
    });
}

// Called from the coalescing timer, i.e. on the main run loop.
- (void)_flushPendingChanges {
    _changeCoalescingTimer = nil;
    _firstPendingChangeDate = nil;  // The next change opens a fresh coalescing window.

    NSSet *paths;
    @synchronized(_pendingChangedPaths) {
        paths = [_pendingChangedPaths copy];
        [_pendingChangedPaths removeAllObjects];
    }

    for (NSString *path in paths) {
        [self _broadcastSSEEvent:@"change" data:@{@"type": @"external", @"path": path}];
    }
}

// Runs on _sseQueue (the heartbeat timer targets it). Reaps dead connections and
// pushes a keep-alive comment to the survivors. A live client always re-parks a
// reader shortly after each delivery, so a channel that has no parked reader AND
// still holds buffered data we handed it earlier is treated as gone.
- (void)_sendHeartbeat {
    if (!_serverSentEventsEnabled) {
        return;
    }
    NSMutableArray<WSKWebUploaderSSEChannel *> *live = [NSMutableArray arrayWithCapacity:_sseChannels.count];
    for (WSKWebUploaderSSEChannel *channel in _sseChannels) {
        if (channel.hasParkedReader) {
            channel.idleHeartbeats = 0;  // A reader is waiting: alive.
        } else {
            // No reader waiting since we last serviced it. A live client re-parks
            // within milliseconds of each delivery, so tolerate a single transient
            // miss (e.g. a socket write completing across a heartbeat boundary) and
            // only reap after two consecutive idle heartbeats.
            channel.idleHeartbeats += 1;
            if (channel.idleHeartbeats >= 2) {
                // Stopped reading: reap. Close so that a connection that is
                // merely slow (not dead) gets end-of-stream when it re-parks,
                // instead of parking forever on a channel we no longer service.
                [channel close];
                continue;
            }
        }
        [live addObject:channel];
    }
    _sseChannels = live;

    NSData *heartbeat = [@":heartbeat\n\n" dataUsingEncoding:NSUTF8StringEncoding];
    for (WSKWebUploaderSSEChannel *channel in _sseChannels) {
        [channel enqueueData:heartbeat];
    }
}

- (void)_broadcastSSEEvent:(NSString *)eventType data:(NSDictionary *)data {
    if (!_serverSentEventsEnabled) {
        return;
    }
    NSError *error = nil;
    NSData *const jsonData = [NSJSONSerialization dataWithJSONObject:data options:0 error:&error];
    NSString *const json = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : nil;

    if (json == nil) {
        // Formatting a nil payload yields the literal "data: (null)", on which the
        // browser's JSON.parse throws — killing the listener rather than losing one event.
        [self logError:@"Failed serializing Server-Sent Event \"%@\": %@", eventType, error];
        return;
    }

    NSString *sseMessage = [NSString stringWithFormat:@"event: %@\ndata: %@\n\n", eventType, json];
    NSData *messageData = [sseMessage dataUsingEncoding:NSUTF8StringEncoding];

    dispatch_async(_sseQueue, ^{
        for (WSKWebUploaderSSEChannel *channel in self->_sseChannels) {
            [channel enqueueData:messageData];
        }
    });
}

- (void)dealloc {
    if (_heartbeatTimer) {
        // libdispatch traps on the release of a suspended object, and the timer spends
        // most of its life suspended, so resume it before letting go. Reading the flag
        // directly is safe here: every block that writes it retains self, so none can
        // still be in flight once -dealloc runs.
        if (_heartbeatSuspended) {
            _heartbeatSuspended = NO;
            dispatch_resume(_heartbeatTimer);
        }

        dispatch_source_cancel(_heartbeatTimer);
    }
    [self _unregisterFilePresenter];
    // -invalidate must be sent from the thread that scheduled the timer (here, the main
    // run loop) but -dealloc runs wherever the last release happened. The timer holds no
    // strong reference back to us — it captures self weakly — so handing it to the main
    // queue keeps it alive just long enough to be invalidated there.
    NSTimer *const timer = _changeCoalescingTimer;
    _changeCoalescingTimer = nil;
    if (timer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [timer invalidate];
        });
    }
}

@end

@implementation WSKWebUploader (Methods)

- (BOOL)_checkFileExtension:(NSString *)fileName {
    if (_allowedFileExtensions && ![_allowedFileExtensions containsObject:[[fileName pathExtension] lowercaseString]]) {
        return NO;
    }

    return YES;
}

// -allowHiddenItems was only ever enforced on the leaf component, so a hidden
// *directory* was refused while nothing stopped a request from reaching inside one
// ("/.git/config" listed, downloaded, deleted and overwritten happily). Test every
// component instead. The path is normalized first so that a benign "." or ".."
// component is resolved away rather than mistaken for a hidden name.
- (BOOL)_isHiddenPath:(NSString *)relativePath {
    if (_allowHiddenItems) {
        return NO;
    }

    NSString *const normalizedPath = WSKNormalizePath(relativePath);

    for (NSString *component in [normalizedPath pathComponents]) {
        if ([component hasPrefix:@"."]) {  // The leading "/" component never matches.
            return YES;
        }
    }

    // The walk above sees only what the client typed, and that is not where the bytes live: a
    // symlink named "pub" pointing at ".git" makes "/pub/config" carry no dot at all, while
    // containment passes because the target is inside the share. Both rules were satisfied by a
    // path inside a dot-directory — readable here, enumerable through /list, and writable
    // through DAV PUT, which refuses the same write spelled "/.git/hooks/x". Resolving is the
    // only way to see it. The cheap textual walk stays in front so the realpath is only paid
    // when it can change the answer.
    return WSKResolvedPathHasHiddenComponent([_uploadDirectory stringByAppendingPathComponent:normalizedPath], _uploadDirectory);
}

// Map an absolute path inside the share back to the client-facing relative path used in
// SSE events. Chopping _uploadDirectory.length off the front assumes the root carries no
// trailing separator — -initWithUploadDirectory: standardizes it so that holds — but stay
// defensive: a mismatch would otherwise yield a path the browser cannot match against the
// folder it is viewing, or run off the end of the string.
- (NSString *)_relativePathForAbsolutePath:(NSString *)absolutePath {
    if ((_uploadDirectory.length == 0) || ![absolutePath hasPrefix:_uploadDirectory]) {
        return @"/";
    }

    NSString *const relativePath = [absolutePath substringFromIndex:_uploadDirectory.length];
    return [relativePath hasPrefix:@"/"] ? relativePath : [@"/" stringByAppendingString:relativePath];
}

// Do two paths name the same file on disk? Compares file resource identifiers (inode +
// volume), so it also catches the case-variant pair "File.txt"/"file.txt" that resolves
// to one file on a case-insensitive volume. Same approach as WSKWebDAVServer's MOVE/COPY.
- (BOOL)_fileAtPath:(NSString *)path1 isSameAsPath:(NSString *)path2 {
    if ([path1 isEqualToString:path2]) {
        return YES;
    }

    id identifier1 = nil;
    id identifier2 = nil;
    return [[NSURL fileURLWithPath:path1] getResourceValue:&identifier1 forKey:NSURLFileResourceIdentifierKey error:NULL] &&
           [[NSURL fileURLWithPath:path2] getResourceValue:&identifier2 forKey:NSURLFileResourceIdentifierKey error:NULL] &&
           identifier1 && [(NSObject *)identifier1 isEqual:identifier2];
}

- (NSString *)_uniquePathForPath:(NSString *)path {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSString *const directory = [path stringByDeletingLastPathComponent];
        NSString *const file = [path lastPathComponent];
        NSString *const base = [file stringByDeletingPathExtension];
        NSString *const extension = [file pathExtension];
        int retries = 0;
        do {
            if (extension.length) {
                path = [directory stringByAppendingPathComponent:(NSString *)[[base stringByAppendingFormat:@" (%i)", ++retries] stringByAppendingPathExtension:extension]];
            } else {
                path = [directory stringByAppendingPathComponent:[base stringByAppendingFormat:@" (%i)", ++retries]];
            }
        } while ([[NSFileManager defaultManager] fileExistsAtPath:path]);
    }

    return path;
}

- (WSKResponse *)listDirectory:(WSKRequest *)request {
    // Default a missing "path" query parameter to the root. Left nil it survives every
    // check below — WSKNormalizePath(nil) is @"", so the absolute path
    // collapses to the upload directory, which exists and is a directory — and then
    // reaches the per-entry dictionary literals, where
    // -stringByAppendingPathComponent: on a nil receiver yields nil. Inserting nil
    // into a dictionary literal raises NSInvalidArgumentException, and nothing here
    // catches it, so a bare "GET /list" terminated the whole app.
    NSString *const requestedPath = [request query][@"path"];

    if (WSKPathContainsNULByte(requestedPath)) {
        // Refuse rather than let WSKNormalizePath truncate and act on the prefix: the request
        // would then be honoured as something the client did not ask for. "/Keep\0/nonexistent"
        // named nothing and deleted "/Keep"; "/list?path=\0" reached a per-entry dictionary
        // literal with a nil value and terminated the process.
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Path contains a NUL byte"];
    }

    NSString *const relativePath = requestedPath ? requestedPath : @"/";
    NSString *const normalizedPath = WSKNormalizePath(relativePath);
    NSString *const absolutePath = [_uploadDirectory stringByAppendingPathComponent:normalizedPath];
    BOOL isDirectory = NO;

    if (!absolutePath || ![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    if (!isDirectory) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"\"%@\" is not a directory", relativePath];
    }

    // Verify the resolved location, not just the path text: a symlink somewhere inside
    // the share can point out of it, and normalize/prefix checks cannot see that.
    if (!WSKResolvedPathIsWithinDirectory(absolutePath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Listing \"%@\" is not allowed", relativePath];
    }

    if ([self _isHiddenPath:relativePath]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Listing hidden path \"%@\" is not allowed", relativePath];
    }

    NSError *error = nil;
    NSArray *const contents = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:absolutePath error:&error] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    if (contents == nil) {
        return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed listing directory \"%@\"", relativePath];
    }

    NSMutableArray *const array = [NSMutableArray array];

    for (NSString *item in [contents sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if (_allowHiddenItems || ![item hasPrefix:@"."]) {
            NSDictionary *const attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[absolutePath stringByAppendingPathComponent:item] error:NULL];
            NSString *const type = attributes[NSFileType];
            NSNumber *const size = attributes[NSFileSize];  // Nil if the item vanished between the listing and this stat; must not reach the literal below.

            if ([type isEqualToString:NSFileTypeRegular] && size && [self _checkFileExtension:item]) {
                [array addObject:@{
                    @"path": [normalizedPath stringByAppendingPathComponent:item],
                    @"name": item,
                    @"size": size
                }];
            } else if ([type isEqualToString:NSFileTypeDirectory]) {
                [array addObject:@{
                    @"path": [[normalizedPath stringByAppendingPathComponent:item] stringByAppendingString:@"/"],
                    @"name": item
                }];
            }
        }
    }

    return [WSKDataResponse responseWithJSONObject:array];
}

- (WSKResponse *)downloadFile:(WSKRequest *)request {
    // Never nil, so error bodies name a path instead of "(null)" — and match -listDirectory:.
    NSString *const requestedPath = [request query][@"path"];

    if (WSKPathContainsNULByte(requestedPath)) {
        // Refuse rather than let WSKNormalizePath truncate and act on the prefix: the request
        // would then be honoured as something the client did not ask for. "/Keep\0/nonexistent"
        // named nothing and deleted "/Keep"; "/list?path=\0" reached a per-entry dictionary
        // literal with a nil value and terminated the process.
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Path contains a NUL byte"];
    }

    NSString *const relativePath = requestedPath ? requestedPath : @"/";
    NSString *const absolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];
    BOOL isDirectory = NO;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    if (isDirectory) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"\"%@\" is a directory", relativePath];
    }

    // As in -listDirectory:, confirm the resolved location is still inside the share.
    if (!WSKResolvedPathIsWithinDirectory(absolutePath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Downloading \"%@\" is not allowed", relativePath];
    }

    if ([self _isHiddenPath:relativePath]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Downloading hidden path \"%@\" is not allowed", relativePath];
    }

    NSString *const fileName = [absolutePath lastPathComponent];

    if (![self _checkFileExtension:fileName]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Downlading file name \"%@\" is not allowed", fileName];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didDownloadFileAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate webUploader:self didDownloadFileAtPath:absolutePath];
        });
    }

    return [WSKFileResponse responseWithFile:absolutePath isAttachment:YES];
}

// Extract the host[:port] authority from an Origin ("scheme://host:port") or a
// Referer ("scheme://host:port/path…") header value; nil for an opaque/"null" origin.
static NSString *_OriginAuthority(NSString *value) {
    if (value.length == 0) {
        return nil;
    }

    NSRange scheme = [value rangeOfString:@"://"];
    if (scheme.location == NSNotFound) {
        return nil;
    }

    NSString *authority = [value substringFromIndex:(scheme.location + 3)];
    NSRange slash = [authority rangeOfString:@"/"];
    if (slash.location != NSNotFound) {
        authority = [authority substringToIndex:slash.location];
    }

    return authority;
}

// Defends the state-changing endpoints (/upload, /move, /delete, /create) against
// browser-driven CSRF: a malicious LAN web page can auto-POST a "simple" form to them
// and the browser attaches any credentials cached for this origin. A cross-origin
// browser request always carries an Origin whose authority differs from ours (POST
// always sends Origin), so reject those. Requests with no Origin/Referer at all — a
// non-browser client such as curl or a native app — are allowed: they cannot be a
// confused deputy. Returns a 403 response to reject, or nil to allow.
//
// Comparing against the client-supplied Host is only meaningful because the connection
// layer has already validated it against an allow-list (see -_rejectIfHostNotAllowed). On
// its own this check compares two attacker-controlled values and a DNS-rebound page passes
// it trivially, so the two belong together.
- (WSKResponse *)_rejectIfCrossOrigin:(WSKRequest *)request {
    NSString *const originHeader = request.headers[@"Origin"];
    NSString *const host = request.headers[@"Host"];
    NSString *authority = _OriginAuthority(originHeader);

    if (authority == nil) {
        if (originHeader.length) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Cross-origin request rejected"];  // Explicit but opaque Origin ("null")
        }

        authority = _OriginAuthority(request.headers[@"Referer"]);  // Fall back to Referer when Origin is absent
    }

    // Compare case-insensitively: host names are, so a mixed-case Bonjour name
    // ("http://MyMac.local:8080" against a "mymac.local:8080" Host) is the same origin
    // and must not be refused.
    if (authority && ((host.length == 0) || ([authority caseInsensitiveCompare:host] != NSOrderedSame))) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Cross-origin request rejected"];
    }

    return nil;
}

- (WSKResponse *)uploadFile:(WSKMultiPartFormRequest *)request {
    WSKResponse *const crossOrigin = [self _rejectIfCrossOrigin:request];
    if (crossOrigin) {
        return crossOrigin;
    }

    NSRange range = [request.headers[@"Accept"] rangeOfString:@"application/json" options:NSCaseInsensitiveSearch];
    NSString *const contentType = (range.location != NSNotFound ? @"application/json" : @"text/plain; charset=utf-8");  // Required when using iFrame transport (see https://github.com/blueimp/jQuery-File-Upload/wiki/Setup)

    WSKMultiPartFile *const file = [request firstFileForControlName:@"files[]"];

    // The multipart "filename" is fully attacker-controlled and may contain path
    // separators or "..", which -stringByAppendingPathComponent: does NOT resolve,
    // so an unsanitized name lets a move escape the upload directory. Reduce it to
    // a single leaf component and reject the traversal specials.
    NSString *const fileName = [file.fileName lastPathComponent];

    if ((fileName.length == 0) || [fileName isEqualToString:@"."] || [fileName isEqualToString:@".."] ||
        (!_allowHiddenItems && [fileName hasPrefix:@"."]) || ![self _checkFileExtension:fileName]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Uploaded file name \"%@\" is not allowed", file.fileName];
    }

    NSString *const relativePath = [[request firstArgumentForControlName:@"path"] string];
    NSString *const desiredPath = [[_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)] stringByAppendingPathComponent:fileName];

    // A non-hidden file name is not enough: the destination directory must not be hidden
    // either, at any depth, or an upload could drop files into ".git" and friends.
    if ([self _isHiddenPath:relativePath]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Uploading to hidden path \"%@\" is not allowed", relativePath];
    }

    // The leaf is already reduced to a single component above, but the client-supplied
    // "path" it is appended to may traverse a symlink out of the share.
    if (!WSKResolvedPathIsWithinDirectory(desiredPath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Uploading to \"%@\" is not allowed", relativePath];
    }

    // Resolving a unique name and moving the uploaded file into place must be
    // atomic against concurrent requests, otherwise two uploads of the same
    // filename can resolve the same "unique" path and one clobbers or fails.
    NSString *absolutePath;
    NSError *error = nil;
    BOOL moved;
    @synchronized(_fileOperationLock) {
        absolutePath = [self _uniquePathForPath:desiredPath];

        if (![self shouldUploadFileAtPath:absolutePath withTemporaryFile:file.temporaryPath]) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Uploading file \"%@\" to \"%@\" is not permitted", file.fileName, relativePath];
        }

        moved = [[NSFileManager defaultManager] moveItemAtPath:file.temporaryPath toPath:absolutePath error:&error];
    }

    if (!moved) {
        return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed moving uploaded file to \"%@\"", relativePath];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didUploadFileAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate webUploader:self didUploadFileAtPath:absolutePath];
        });
    }

    NSString *const uploadedRelativePath = [self _relativePathForAbsolutePath:absolutePath];
    [self _broadcastSSEEvent:@"change" data:@{@"type": @"upload", @"path": uploadedRelativePath}];

    return [WSKDataResponse responseWithJSONObject:@{} contentType:contentType];
}

- (WSKResponse *)moveItem:(WSKURLEncodedFormRequest *)request {
    WSKResponse *const crossOrigin = [self _rejectIfCrossOrigin:request];
    if (crossOrigin) {
        return crossOrigin;
    }

    NSString *const oldRelativePath = request.arguments[@"oldPath"];

    if (WSKPathContainsNULByte(oldRelativePath)) {
        // Refuse rather than let WSKNormalizePath truncate and act on the prefix: the request
        // would then be honoured as something the client did not ask for. "/Keep\0/nonexistent"
        // named nothing and deleted "/Keep"; "/list?path=\0" reached a per-entry dictionary
        // literal with a nil value and terminated the process.
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Path contains a NUL byte"];
    }

    NSString *const oldAbsolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(oldRelativePath)];
    BOOL isDirectory = NO;

    // Neither endpoint may be the upload directory itself (a missing/empty path
    // collapses to it), which would let a move destroy or displace the root.
    NSString *const newRelativePath = request.arguments[@"newPath"];

    if (WSKPathContainsNULByte(newRelativePath)) {
        // Refuse rather than let WSKNormalizePath truncate and act on the prefix: the request
        // would then be honoured as something the client did not ask for. "/Keep\0/nonexistent"
        // named nothing and deleted "/Keep"; "/list?path=\0" reached a per-entry dictionary
        // literal with a nil value and terminated the process.
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Path contains a NUL byte"];
    }

    NSString *const desiredNewPath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(newRelativePath)];
    if (!WSKPathIsInsideDirectory(oldAbsolutePath, _uploadDirectory) || !WSKPathIsInsideDirectory(desiredNewPath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Operating on the root directory is not allowed"];
    }

    // Both endpoints must also resolve inside the share, so neither can reach out of it
    // through a symlink (which the textual check above cannot detect).
    if (!WSKResolvedPathIsWithinDirectory(oldAbsolutePath, _uploadDirectory) || !WSKResolvedPathIsWithinDirectory(desiredNewPath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Moving \"%@\" to \"%@\" is not allowed", oldRelativePath, newRelativePath];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:oldAbsolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", oldRelativePath];
    }

    // Check both endpoints for a hidden component at any depth, not just the leaf: a move
    // out of a dot-directory would otherwise exfiltrate its contents into plain view, and
    // a move into one would smuggle files past the same guard.
    if ([self _isHiddenPath:oldRelativePath] || [self _isHiddenPath:newRelativePath]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Moving \"%@\" to \"%@\" is not allowed: a hidden path is involved", oldRelativePath, newRelativePath];
    }

    NSString *const oldItemName = [oldAbsolutePath lastPathComponent];

    if (!isDirectory && ![self _checkFileExtension:oldItemName]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Moving from item name \"%@\" is not allowed", oldItemName];
    }

    // Resolving a unique destination name and performing the move must be atomic
    // against concurrent requests, otherwise two moves targeting the same name
    // can resolve the same "unique" path and the second move fails.
    NSString *newAbsolutePath;
    NSError *error = nil;
    BOOL moved;
    @synchronized(_fileOperationLock) {
        // A destination that IS the source is not an obstacle to route around: without
        // this, an exact no-op move — or a case-only rename such as "File.txt" to
        // "file.txt" on a case-insensitive volume — makes -_uniquePathForPath: see the
        // source itself as a name collision and silently produce "file (1).txt".
        // NSFileManager refuses a move onto an existing destination anyway, so say so
        // plainly, matching WSKWebDAVServer's MOVE-onto-itself rejection.
        if ([self _fileAtPath:oldAbsolutePath isSameAsPath:desiredNewPath]) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Moving \"%@\" onto itself is not allowed", oldRelativePath];
        }

        newAbsolutePath = [self _uniquePathForPath:desiredNewPath];

        // The hidden check ran on newRelativePath above; -_uniquePathForPath: only ever
        // appends " (n)" to the leaf, so it cannot turn a visible name into a hidden one.
        NSString *const newItemName = [newAbsolutePath lastPathComponent];

        if (!isDirectory && ![self _checkFileExtension:newItemName]) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Moving to item name \"%@\" is not allowed", newItemName];
        }

        if (![self shouldMoveItemFromPath:oldAbsolutePath toPath:newAbsolutePath]) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Moving \"%@\" to \"%@\" is not permitted", oldRelativePath, newRelativePath];
        }

        moved = [[NSFileManager defaultManager] moveItemAtPath:oldAbsolutePath toPath:newAbsolutePath error:&error];
    }

    if (!moved) {
        return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed moving \"%@\" to \"%@\"", oldRelativePath, newRelativePath];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didMoveItemFromPath:toPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate webUploader:self didMoveItemFromPath:oldAbsolutePath toPath:newAbsolutePath];
        });
    }

    NSString *const movedOldRelativePath = [self _relativePathForAbsolutePath:oldAbsolutePath];
    NSString *const movedNewRelativePath = [self _relativePathForAbsolutePath:newAbsolutePath];
    [self _broadcastSSEEvent:@"change" data:@{@"type": @"move", @"oldPath": movedOldRelativePath, @"newPath": movedNewRelativePath}];

    return [WSKDataResponse responseWithJSONObject:@{}];
}

- (WSKResponse *)deleteItem:(WSKURLEncodedFormRequest *)request {
    WSKResponse *const crossOrigin = [self _rejectIfCrossOrigin:request];
    if (crossOrigin) {
        return crossOrigin;
    }

    NSString *const relativePath = request.arguments[@"path"];

    if (WSKPathContainsNULByte(relativePath)) {
        // Refuse rather than let WSKNormalizePath truncate and act on the prefix: the request
        // would then be honoured as something the client did not ask for. "/Keep\0/nonexistent"
        // named nothing and deleted "/Keep"; "/list?path=\0" reached a per-entry dictionary
        // literal with a nil value and terminated the process.
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Path contains a NUL byte"];
    }

    NSString *const absolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];
    BOOL isDirectory = NO;

    // A missing/empty path collapses to the upload directory itself; refuse to
    // operate on the root (deleting it would wipe the entire share).
    if (!WSKPathIsInsideDirectory(absolutePath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Operating on the root directory is not allowed"];
    }

    // Deleting is destructive, so also confirm the resolved target is inside the share
    // rather than something a symlink points to outside it.
    if (!WSKResolvedPathIsWithinDirectory(absolutePath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not allowed", relativePath];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    if ([self _isHiddenPath:relativePath]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting hidden path \"%@\" is not allowed", relativePath];
    }

    NSString *const itemName = [absolutePath lastPathComponent];

    if (!isDirectory && ![self _checkFileExtension:itemName]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting item name \"%@\" is not allowed", itemName];
    }

    // Vetting the subtree and removing it must be atomic against the other file
    // operations: a concurrent /move can relocate a whole *directory* into this tree —
    // and directories skip the extension check — so a tree that vetted clean can hold
    // disallowed files by the time it is destroyed. Take the same lock they do.
    NSError *error = nil;
    BOOL removed;

    @synchronized(_fileOperationLock) {
        // Deleting a directory removes its whole subtree, which must not become a way to
        // destroy files that a direct delete would refuse. The extension check above only
        // applies to files, so vet the contents before removing a directory.
        if (isDirectory && _allowedFileExtensions) {
            NSDirectoryEnumerator<NSString *> *const enumerator = [[NSFileManager defaultManager] enumeratorAtPath:absolutePath];

            for (NSString *subpath in enumerator) {
                // Skip dot-names — and everything under them — whatever -allowHiddenItems
                // says. They are incidental metadata rather than content the allow-list is
                // meant to protect (a ".DS_Store" sits in every macOS folder, and its empty
                // pathExtension is in no allow-list), so vetting them would make ordinary
                // directories permanently undeletable. Note this cannot use -_isHiddenPath:,
                // which reports NO for everything once hidden items are allowed.
                if ([[subpath lastPathComponent] hasPrefix:@"."]) {
                    [enumerator skipDescendants];
                    continue;
                }

                NSString *const subpathType = [enumerator fileAttributes][NSFileType];

                // An extensionless file ("README", "LICENSE") is vetted like any other: a
                // direct DELETE of it is already refused, so letting a recursive delete
                // destroy it would make the same request mean two different things. Refusing
                // the folder is the honest answer — the client is told exactly which entry
                // blocked it and can remove that first.
                if ([subpathType isEqualToString:NSFileTypeRegular] && ![self _checkFileExtension:subpath]) {
                    return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not allowed: it contains \"%@\"", relativePath, subpath];
                }
            }
        }

        if (![self shouldDeleteItemAtPath:absolutePath]) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not permitted", relativePath];
        }

        removed = [[NSFileManager defaultManager] removeItemAtPath:absolutePath error:&error];
    }

    if (!removed) {
        return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed deleting \"%@\"", relativePath];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didDeleteItemAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate webUploader:self didDeleteItemAtPath:absolutePath];
        });
    }

    // Derive the broadcast path from the resolved location, as upload/move/create do:
    // echoing the raw client string back would make other browsers compute a directory
    // that never matches the one they are viewing, so they would not refresh.
    NSString *const deletedRelativePath = [self _relativePathForAbsolutePath:absolutePath];
    [self _broadcastSSEEvent:@"change" data:@{@"type": @"delete", @"path": deletedRelativePath}];

    return [WSKDataResponse responseWithJSONObject:@{}];
}

- (WSKResponse *)createDirectory:(WSKURLEncodedFormRequest *)request {
    WSKResponse *const crossOrigin = [self _rejectIfCrossOrigin:request];
    if (crossOrigin) {
        return crossOrigin;
    }

    NSString *const relativePath = request.arguments[@"path"];

    if (WSKPathContainsNULByte(relativePath)) {
        // Refuse rather than let WSKNormalizePath truncate and act on the prefix: the request
        // would then be honoured as something the client did not ask for. "/Keep\0/nonexistent"
        // named nothing and deleted "/Keep"; "/list?path=\0" reached a per-entry dictionary
        // literal with a nil value and terminated the process.
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Path contains a NUL byte"];
    }

    NSString *const desiredPath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];

    // An empty path collapses to the upload directory itself; refuse it (uniquing
    // the root would otherwise create a sibling directory outside the share).
    if (!WSKPathIsInsideDirectory(desiredPath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Operating on the root directory is not allowed"];
    }

    // The parent of the new directory must resolve inside the share, so a symlinked
    // intermediate component cannot place it outside.
    if (!WSKResolvedPathIsWithinDirectory(desiredPath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Creating \"%@\" is not allowed", relativePath];
    }

    // Refuse a hidden component anywhere, not just in the new directory's own name: the
    // parent chain must be visible too, or /create becomes a way to populate a dot-directory.
    if ([self _isHiddenPath:relativePath]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Creating hidden path \"%@\" is not allowed", relativePath];
    }

    // Resolving a unique name and creating the directory must be atomic: request
    // handlers run concurrently, so without this two requests for the same name
    // would both resolve the same "unique" path and the second mkdir would fail.
    NSString *absolutePath;
    NSError *error = nil;
    BOOL created;
    @synchronized(_fileOperationLock) {
        absolutePath = [self _uniquePathForPath:desiredPath];

        if (![self shouldCreateDirectoryAtPath:absolutePath]) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Creating directory \"%@\" is not permitted", relativePath];
        }

        created = [[NSFileManager defaultManager] createDirectoryAtPath:absolutePath withIntermediateDirectories:NO attributes:nil error:&error];
    }

    if (!created) {
        return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed creating directory \"%@\"", relativePath];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didCreateDirectoryAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate webUploader:self didCreateDirectoryAtPath:absolutePath];
        });
    }

    NSString *const createdRelativePath = [[self _relativePathForAbsolutePath:absolutePath] stringByAppendingString:@"/"];
    [self _broadcastSSEEvent:@"change" data:@{@"type": @"create", @"path": createdRelativePath}];

    return [WSKDataResponse responseWithJSONObject:@{}];
}

@end

@implementation WSKWebUploader (Subclassing)

- (BOOL)shouldUploadFileAtPath:(NSString *)path withTemporaryFile:(NSString *)tempPath {
    return YES;
}

- (BOOL)shouldMoveItemFromPath:(NSString *)fromPath toPath:(NSString *)toPath {
    return YES;
}

- (BOOL)shouldDeleteItemAtPath:(NSString *)path {
    return YES;
}

- (BOOL)shouldCreateDirectoryAtPath:(NSString *)path {
    return YES;
}

@end
