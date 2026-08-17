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
#import "WSKPrivate.h"
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
- (nullable WSKResponse *)previewFile:(WSKRequest *)request;
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
    // The share as realpath(3) sees it. Immutable after -initWithUploadDirectory:. See
    // -_relativePathForAbsolutePath: for why the standardized spelling alone is not enough.
    NSString *_resolvedUploadDirectory;
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

        // Resolved once, here, because every path handed to -_relativePathForAbsolutePath: has
        // been through realpath(3) while this one has only been standardized, and the two
        // disagree far more often than "an unusual symlink" suggests — see that method.
        char resolvedBuffer[PATH_MAX];

        // -fileSystemRepresentation RAISES for an empty or NUL-bearing receiver, and this line was
        // added without that guard — re-opening, three files from the comment explaining it, the
        // exact class the WSKFileResponse fix had just closed. Fifth recurrence of this codebase's
        // most repeated defect. Leaving _resolvedUploadDirectory nil is already handled: the reader
        // falls back to _uploadDirectory.
        if ((_uploadDirectory.length > 0) && !WSKPathContainsNULByte(_uploadDirectory) &&
            (realpath([_uploadDirectory fileSystemRepresentation], resolvedBuffer) != NULL)) {
            _resolvedUploadDirectory = [[[NSFileManager defaultManager] stringWithFileSystemRepresentation:resolvedBuffer length:strlen(resolvedBuffer)] copy];
        }
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
        // statement about the *method* and wrong here ("/favicon.ico", which browsers request
        // unprompted, must not answer "Not Implemented"). Matches GET only, so no other
        // method's status changes.
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
        // Convenience only — "/index.html" is the obvious thing to type. It is *not* what keeps
        // the raw template unreachable: that is the scoped asset handlers above, because an
        // exact path like this one is not a containment boundary ("/./index.html" does not
        // match it).
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

        // Inline media, for an interface that shows pictures rather than listing them. Separate
        // from /download rather than a flag on it: "always an attachment" and "always inert and
        // inline" are each defensible in one sentence, where one endpoint with a switch has a
        // wrong setting to reach.
        [self addHandlerForMethod:@"GET"
                             path:@"/preview"
                     requestClass:[WSKRequest class]
                     processBlock:^WSKResponse *(WSKRequest *request) {
                         return [server previewFile:request];
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
    // The RESOLVED path, not the standardized one. NSFileCoordinator matches a presenter against
    // the canonical path of the item that changed, so registering under a spelling that reaches
    // the share through a symlink registers for a path no change is ever reported against: a
    // symlinked share received NOT FEWER events but ZERO, against 8 on an identical real-path
    // control in the same process. That is the uploader's entire external-change feature silently
    // absent for a deployment whose share is a link — which is an ordinary way to publish one.
    //
    // This is the SAME rule as -_relativePathForAbsolutePath: and -presentedSubitemDidChangeAtURL:
    // (compare resolved against resolved), at the third site that did not have it. Note the
    // asymmetry that hid it: those two are handed a realpath'd argument and had to resolve their
    // OWN root to match it, whereas this method is the one that hands a root OUT, so nothing
    // downstream could compensate.
    //
    // Stability matters here in a way it does not there: NSFilePresenter requires this URL not to
    // change while registered, so it deliberately reads the ONCE-captured _resolvedUploadDirectory
    // and must not re-resolve per call.
    return [NSURL fileURLWithPath:(_resolvedUploadDirectory ? _resolvedUploadDirectory : _uploadDirectory)];
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
    return WSKNamePassesExtensionAllowList(fileName, _allowedFileExtensions);
}

// Both names an entry presents must satisfy the allow-list; see WSKEntryPassesExtensionAllowList.
// `resolvedName` is nil for anything that is not a link, which reduces to the single-name rule.
- (BOOL)_checkFileExtensionForName:(NSString *)namedName resolvedName:(nullable NSString *)resolvedName {
    return WSKEntryPassesExtensionAllowList(namedName, resolvedName, _allowedFileExtensions);
}

// -allowHiddenItems was only ever enforced on the leaf component, so a hidden
// *directory* was refused while nothing stopped a request from reaching inside one
// ("/.git/config" listed, downloaded, deleted and overwritten happily). Test every
// component instead. The path is normalized first so that a benign "." or ".."
// component is resolved away rather than mistaken for a hidden name.
// Resolve the client's path ONCE, so containment and hiddenness are judged on the same
// observation of the filesystem — and so the caller can act on what was actually vetted.
//
// Checking containment with one realpath(3) and hiddenness with another meant two observations
// that need not agree, and then operating on a *third* path: the one the client sent, symlinks
// intact. A symlink retargeted between those steps served content from outside the share, and
// landed a WebDAV PUT outside it. Callers must use the returned path for the filesystem
// operation that follows: a resolved path contains no symlinks, so retargeting one cannot
// redirect it. Paths that do not exist yet resolve through their parent, so this works for
// upload and rename destinations too.
//
// Returns nil when the path does not resolve inside the share. Sets *outHidden when the
// resolved location — or the path the client typed — lies inside a hidden item.
// The same resolution, but yielding the entry the client NAMED rather than what it points at —
// see WSKResolveNamedEntryWithinDirectory(). Used by the verbs that REMOVE or RELOCATE an entry
// (DELETE, and MOVE/COPY on both their source and their destination), because `rm latest` removes
// the alias and `mv a latest` replaces it; only reads follow a link. The NUL guard, the
// containment check, the hidden-item rule and the refusal to act on the root all still apply, and
// all still come from a single resolution.
- (nullable NSString *)_namedEntryPathForRelativePath:(NSString *)relativePath hidden:(BOOL *)outHidden {
    return WSKNamedEntryPathForRelativePath(relativePath, _uploadDirectory, _allowHiddenItems, outHidden);
}

- (nullable NSString *)_resolvedPathForRelativePath:(NSString *)relativePath hidden:(BOOL *)outHidden {
    return WSKResolvedPathForRelativePath(relativePath, _uploadDirectory, _allowHiddenItems, outHidden);
}

// Map an absolute path inside the share back to the client-facing relative path used in
// SSE events. Chopping _uploadDirectory.length off the front assumes the root carries no
// trailing separator — -initWithUploadDirectory: standardizes it so that holds — but stay
// defensive: a mismatch would otherwise yield a path the browser cannot match against the
// folder it is viewing, or run off the end of the string.
- (NSString *)_relativePathForAbsolutePath:(NSString *)absolutePath {
    // Every caller hands over a path that has been through realpath(3), while _uploadDirectory
    // has only been -stringByStandardizingPath'd — and those disagree for any share reached
    // through a symlinked ancestor. That is NOT an exotic case: it is every share under
    // NSTemporaryDirectory(), where "/var" is a symlink to "/private/var" that neither
    // -stringByStandardizingPath nor -stringByResolvingSymlinksInPath expands. The prefix test
    // then failed and the fallback fired, so a change event named "/" — or "//" for a create,
    // which appends its own separator — and the browser, which only reloads when the changed
    // directory matches the folder it is viewing, silently stopped updating for every subfolder.
    //
    // -presentedSubitemDidChangeAtURL: already resolved both sides before comparing. This is the
    // same rule at the site that did not have it, which is this codebase's signature defect.
    NSString *const resolvedRoot = _resolvedUploadDirectory ? _resolvedUploadDirectory : _uploadDirectory;

    // _resolvedUploadDirectory is captured ONCE, at init. If the share's realpath changes under
    // a live server — a symlinked share repointed at a new directory, which is exactly how an
    // atomic publish swaps one — both roots above are stale and every event collapses to "/"
    // again, silently reverting the fix this method exists for. Re-resolving here, LAST and
    // only on a miss, costs one realpath(3) on a path that would otherwise be answered wrongly,
    // and nothing on the common path.
    //
    // Deliberately NOT written back to _resolvedUploadDirectory: these callers run on concurrent
    // connection queues, and -presentedItemURL requires that value to stay put for as long as the
    // presenter is registered.
    NSString *freshRoot = nil;
    char resolvedBuffer[PATH_MAX];

    if ((_uploadDirectory.length > 0) && !WSKPathContainsNULByte(_uploadDirectory) &&
        (realpath([_uploadDirectory fileSystemRepresentation], resolvedBuffer) != NULL)) {
        freshRoot = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:resolvedBuffer length:strlen(resolvedBuffer)];
    }

    for (NSString *const root in @[ _uploadDirectory, resolvedRoot, freshRoot ? freshRoot : @"" ]) {
        if (root.length == 0) {
            continue;
        }

        // The prefix test needs a SEPARATOR BOUNDARY, or a sibling directory whose name merely
        // begins with the share's is mapped INTO the share: with a share at ".../Share", the path
        // ".../Share2/x.txt" answered "/2/x.txt" — a client-facing path naming a file that is not
        // in the share at all, assembled by slicing a name in half. -presentedSubitemDidChangeAtURL:
        // has always compared against root + "/" for this reason; this is the same rule at the
        // sibling site that did not have it.
        //
        // Honest limit: every current caller hands over a path already resolved INSIDE the share,
        // so this was not reachable from the network — it is the function being wrong, not the
        // server. It is fixed because the next caller is the one that would not know.
        if ([absolutePath isEqualToString:root]) {
            return @"/";
        }

        if (![absolutePath hasPrefix:[root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"]]) {
            continue;
        }

        NSString *const relativePath = [absolutePath substringFromIndex:root.length];
        return [relativePath hasPrefix:@"/"] ? relativePath : [@"/" stringByAppendingString:relativePath];
    }

    return @"/";
}

// Do two paths name the same file on disk? Compares file resource identifiers (inode +
// volume), so it also catches the case-variant pair "File.txt"/"file.txt" that resolves
// to one file on a case-insensitive volume. Same approach as WSKWebDAVServer's MOVE/COPY.
- (BOOL)_fileAtPath:(NSString *)path1 isSameAsPath:(NSString *)path2 {
    return WSKPathsNameTheSameFile(path1, path2);
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
    BOOL isDirectory = NO;

    // Containment is confirmed BEFORE the item is stat'ed. Answering 404-vs-403 from a path
    // that has not been vetted yet makes the status an existence oracle for the whole
    // filesystem: a symlink pointing out of the share answers 403 when its target exists and
    // 404 when it does not, so a client can probe for files it can never read. Same ordering
    // as DAV and as -deleteItem: in this same file.
    BOOL isHidden = NO;
    NSString *const resolvedPath = [self _resolvedPathForRelativePath:relativePath hidden:&isHidden];

    if (resolvedPath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Listing \"%@\" is not allowed", relativePath];
    }

    if (isHidden) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Listing hidden path \"%@\" is not allowed", relativePath];
    }

    NSString *absolutePath = resolvedPath;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    if (!isDirectory) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"\"%@\" is not a directory", relativePath];
    }

    // Everything below enumerates the location that was just vetted, not the one the client
    // sent: a resolved path holds no symlinks, so retargeting one cannot redirect it.
    absolutePath = resolvedPath;

    NSError *error = nil;
    NSArray *const contents = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:absolutePath error:&error] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    if (contents == nil) {
        return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed listing directory \"%@\"", relativePath];
    }

    NSMutableArray *const array = [NSMutableArray array];

    for (NSString *item in [contents sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if (_allowHiddenItems || ![item hasPrefix:@"."]) {
            NSString *const itemPath = [absolutePath stringByAppendingPathComponent:item];
            NSDictionary *const attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:itemPath error:NULL];
            // Classified by what a symlink points at, so the listing describes what is served.
            NSString *resolvedName = nil;
            NSString *const type = WSKServableFileTypeAtPath(itemPath, _uploadDirectory, _allowHiddenItems, &resolvedName);
            // A symlink's own attributes report the length of its target PATH, not the file, so
            // ask again through the link for anything classified as a regular file.
            NSString *const rawType = attributes[NSFileType];
            NSDictionary *const effective = [rawType isEqualToString:NSFileTypeSymbolicLink]
                                                ? [[NSFileManager defaultManager] attributesOfItemAtPath:[itemPath stringByResolvingSymlinksInPath] error:NULL]
                                                : attributes;
            NSNumber *const size = effective[NSFileSize];  // Nil if the item vanished between the listing and this stat; must not reach the literal below.

            if ([type isEqualToString:NSFileTypeRegular] && size && [self _checkFileExtensionForName:item resolvedName:resolvedName]) {
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

// Types a browser renders but cannot execute. Serving a shared file INLINE puts it in this
// server's own origin, and this interface's one-click buttons delete and move files — so an
// uploaded ".html" served inline is stored XSS against the share. /download forces "attachment"
// for exactly that reason, which is also why it cannot simply be relaxed: <img src="/download?…">
// gets a save dialog instead of a picture.
//
// The list is an allow-list of whole types rather than a deny-list of dangerous ones, because a
// deny-list is wrong the moment a new type is registered. "image/svg+xml" is excluded DELIBERATELY
// and is the reason this is not simply "anything beginning image/": SVG carries script and runs it,
// so an "images are inert" rule admits the one image that is not. PDF is excluded for the same
// reason — it has its own scripting model.
static BOOL _MimeTypeIsInertMedia(NSString *mimeType) {
    NSString *const type = [[mimeType componentsSeparatedByString:@";"].firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;

    if ([type isEqualToString:@"image/svg+xml"]) {
        return NO;
    }

    return [type hasPrefix:@"image/"] || [type hasPrefix:@"audio/"] || [type hasPrefix:@"video/"];
}

- (WSKResponse *)previewFile:(WSKRequest *)request {
    return [self _fileResponseForRequest:request inline:YES];
}

- (WSKResponse *)downloadFile:(WSKRequest *)request {
    return [self _fileResponseForRequest:request inline:NO];
}

// One body for both surfaces. /preview is a second door to the same files, so every refusal
// /download makes it has to make too — sharing the walk is what stops the two drifting, which is
// this codebase's most reliable defect shape.
- (WSKResponse *)_fileResponseForRequest:(WSKRequest *)request inline:(BOOL)serveInline {
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
    BOOL isDirectory = NO;

    // Containment is confirmed BEFORE the item is stat'ed — same ordering, and same existence-
    // oracle reason, as /list above.
    BOOL isHidden = NO;
    NSString *const resolvedPath = [self _resolvedPathForRelativePath:relativePath hidden:&isHidden];

    if (resolvedPath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Downloading \"%@\" is not allowed", relativePath];
    }

    if (isHidden) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Downloading hidden path \"%@\" is not allowed", relativePath];
    }

    NSString *const absolutePath = resolvedPath;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    if (isDirectory) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"\"%@\" is a directory", relativePath];
    }

    // As in DAV's GET: absolutePath is resolved by here, so judge the client's name too.
    NSString *const fileName = [relativePath lastPathComponent];
    NSString *const resolvedName = [absolutePath lastPathComponent];

    if (![self _checkFileExtensionForName:fileName resolvedName:resolvedName]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Downloading file name \"%@\" is not allowed", fileName];
    }

    // Decided from the same extension mapping the response itself will use, so the type this
    // refuses on and the type it then declares cannot disagree.
    NSString *const mimeType = WSKGetMimeTypeForExtension([absolutePath pathExtension], nil);

    if (serveInline && !_MimeTypeIsInertMedia(mimeType)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"\"%@\" cannot be shown inline; use /download instead", [relativePath lastPathComponent]];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didDownloadFileAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Re-read and re-check inside the block. The property is weak AND mutable, so the
            // object checked above need not be the one messaged here — a host app that swaps
            // its delegate for another LIVE object implementing a different subset of these
            // optional methods raises unrecognized-selector, and nothing in Sources/ catches an
            // NSException. (Setting it to nil, or letting it deallocate, was always safe: the
            // weak read yields nil and the message is a no-op.) The strong local also removes a
            // second weak load between this check and the send. Deliberately NOT a strong
            // capture at check time: that would keep a delegate the host app has released alive
            // and deliver into an object mid-teardown.
            id<WSKWebUploaderDelegate> const delegate = self.delegate;

            if ([delegate respondsToSelector:@selector(webUploader:didDownloadFileAtPath:)]) {
                [delegate webUploader:self didDownloadFileAtPath:absolutePath];
            }
        });
    }

    // Range and If-Range are passed through now. This endpoint built its response with
    // +responseWithFile:isAttachment:, which passes NSMakeRange(NSUIntegerMax, 0) — no range —
    // so a "Range" header was ignored and the whole file came back 200: an interrupted download
    // of a large build could not resume, and a <video> could not seek. The base-path handler and
    // DAV's GET have both passed these for several passes; this was the one file-vending surface
    // that did not. Going through the ifRange: variant is also what brings the If-Range protection
    // with it, so a resume against a REPLACED file is refused rather than spliced.
    WSKFileResponse *const response = [WSKFileResponse responseWithFile:absolutePath byteRange:request.byteRange isAttachment:!serveInline ifRange:request.ifRange];

    if (response == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    if (serveInline) {
        // "attachment" is what +responseWithFile: sets when asked for one; the inline case sets
        // none at all, which leaves the browser to guess from the type. Say it explicitly, and
        // carry the two headers that make guessing harmless: nosniff so a .png full of markup
        // cannot be sniffed into active content, and a policy that denies every subresource and
        // script even if a type ever slips past the allow-list above.
        [response setValue:@"inline" forAdditionalHeader:@"Content-Disposition"];
        [response setValue:@"nosniff" forAdditionalHeader:@"X-Content-Type-Options"];
        [response setValue:@"default-src 'none'; sandbox; frame-ancestors 'none'" forAdditionalHeader:@"Content-Security-Policy"];
    }

    response.cacheControlMaxAge = _fileCacheControlMaxAge;
    return response;
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
    //
    // "/" is the one input for which -lastPathComponent does not return a leaf: it returns "/"
    // unchanged (as does "//" and any run of slashes). That name passed every guard below, and
    // -stringByAppendingPathComponent: then collapsed it straight back to the upload directory,
    // so -_uniquePathForPath: found that directory already existing and renamed *its own leaf*
    // in the PARENT — landing the body beside the share as "Share (1)", answered 200. So the
    // separator is rejected outright afterwards: the requirement is that the name be a single
    // path component, and testing for that directly is what makes it true, rather than trusting
    // the reduction to have produced one.
    NSString *const fileName = [file.fileName lastPathComponent];

    // The NUL test belongs with the others: this value reaches -stringByAppendingPathComponent:,
    // which returns nil for a NUL-bearing receiver, and nil then reaches a place that cannot take
    // one. The same shape that made "/list?path=%00" terminate the process — the query and form
    // fields were guarded then, this one was missed because it arrives through the multipart
    // parser rather than the request arguments.
    if ((fileName.length == 0) || [fileName containsString:@"/"] || WSKPathContainsNULByte(fileName) || [fileName isEqualToString:@"."] || [fileName isEqualToString:@".."] ||
        (!_allowHiddenItems && [fileName hasPrefix:@"."]) || ![self _checkFileExtension:fileName]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Uploaded file name \"%@\" is not allowed", file.fileName];
    }

    NSString *const relativePath = [[request firstArgumentForControlName:@"path"] string];

    if (WSKPathContainsNULByte(relativePath)) {
        // Same reason as the file name above, and the same reason as every other client path in
        // this file: truncating at the NUL would place the upload in a directory the client did
        // not name.
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Path contains a NUL byte"];
    }
    // Vet the destination DIRECTORY once — the leaf is already reduced to a single validated
    // component above — and compose onto the resolved directory. The client-supplied "path" may
    // traverse a symlink out of the share, and a non-hidden file name is not enough on its own:
    // an upload could otherwise drop files into ".git" and friends.
    BOOL isHidden = NO;
    NSString *const resolvedDirectory = [self _resolvedPathForRelativePath:relativePath hidden:&isHidden];

    if (isHidden) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Uploading to hidden path \"%@\" is not allowed", relativePath];
    }

    if (resolvedDirectory == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Uploading to \"%@\" is not allowed", relativePath];
    }

    NSString *const desiredPath = [resolvedDirectory stringByAppendingPathComponent:fileName];

    // /upload was the only one of the uploader's three write endpoints with no containment check
    // on the *composed* path — /move, /delete and /create all have one — and that is what let a
    // leaf of "/" collapse the composition back onto the directory itself. The leaf guard above
    // closes that spelling; this judges the result, so a future way for the leaf to collapse is
    // caught without anyone having to think of it first.
    //
    // Compared against resolvedDirectory, NOT _uploadDirectory: the latter is stored
    // -stringByStandardizingPath'd (so a share under NSTemporaryDirectory() stays "/var/..."),
    // while desiredPath is composed onto a realpath(3) result ("/private/var/..."). Comparing
    // the two would refuse every legitimate upload for any share under /var or /tmp.
    if (!WSKPathIsInsideDirectory(desiredPath, resolvedDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Uploaded file name \"%@\" is not allowed", file.fileName];
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
        // A full volume or exhausted quota is 507, not 500 — the same mapping WebDAV's PUT and
        // COPY/MOVE already run through, and the same rule the record states for every write-to-disk
        // verb. This endpoint hardcoded 500, so an upload onto a nearly-full device (temp on
        // internal storage, share smaller or near-full) reported a server fault for what is really
        // "no room" — and a 5xx invites the client to retry a request that can never succeed.
        // WSKServerErrorStatusCodeForError reads NSFileWriteOutOfSpaceError AND the POSIX errno
        // under NSUnderlyingError, so it catches both spellings; everything else it still maps to 500.
        return [WSKErrorResponse responseWithServerError:WSKServerErrorStatusCodeForError(error) underlyingError:error message:@"Failed moving uploaded file to \"%@\"", relativePath];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didUploadFileAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Re-read and re-check inside the block. The property is weak AND mutable, so the
            // object checked above need not be the one messaged here — a host app that swaps
            // its delegate for another LIVE object implementing a different subset of these
            // optional methods raises unrecognized-selector, and nothing in Sources/ catches an
            // NSException. (Setting it to nil, or letting it deallocate, was always safe: the
            // weak read yields nil and the message is a no-op.) The strong local also removes a
            // second weak load between this check and the send. Deliberately NOT a strong
            // capture at check time: that would keep a delegate the host app has released alive
            // and deliver into an object mid-teardown.
            id<WSKWebUploaderDelegate> const delegate = self.delegate;

            if ([delegate respondsToSelector:@selector(webUploader:didUploadFileAtPath:)]) {
                [delegate webUploader:self didUploadFileAtPath:absolutePath];
            }
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

    NSString *oldAbsolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(oldRelativePath)];
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

    NSString *desiredNewPath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(newRelativePath)];
    if (!WSKPathIsInsideDirectory(oldAbsolutePath, _uploadDirectory) || !WSKPathIsInsideDirectory(desiredNewPath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Operating on the root directory is not allowed"];
    }

    // Both endpoints resolved ONCE each, so neither can reach out of the share through a symlink
    // (which the textual check above cannot detect) and neither can be redirected between the
    // check and the rename by a link retargeted underneath us. Hidden components are refused at
    // any depth, not just the leaf: a move out of a dot-directory would exfiltrate its contents
    // into plain view, and a move into one would smuggle files past the same guard.
    BOOL oldIsHidden = NO;
    BOOL newIsHidden = NO;
    NSString *const resolvedOldPath = [self _namedEntryPathForRelativePath:oldRelativePath hidden:&oldIsHidden];
    NSString *const resolvedNewPath = [self _namedEntryPathForRelativePath:newRelativePath hidden:&newIsHidden];

    if ((resolvedOldPath == nil) || (resolvedNewPath == nil)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Moving \"%@\" to \"%@\" is not allowed", oldRelativePath, newRelativePath];
    }

    oldAbsolutePath = resolvedOldPath;
    desiredNewPath = resolvedNewPath;

    if (![[NSFileManager defaultManager] fileExistsAtPath:oldAbsolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", oldRelativePath];
    }

    if (oldIsHidden || newIsHidden) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Moving \"%@\" to \"%@\" is not allowed: a hidden path is involved", oldRelativePath, newRelativePath];
    }

    NSString *const oldItemName = [oldAbsolutePath lastPathComponent];

    if (!isDirectory && ![self _checkFileExtension:oldItemName]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Moving from item name \"%@\" is not allowed", oldItemName];
    }

    // A DIRECTORY source skips the check above entirely, so moving a folder was a spelling that
    // relocated everything inside it whatever the allow-list said — including files this endpoint
    // refuses to move when they are named directly. Same walk, same shared home, as the DELETE
    // above and as WebDAV's MOVE/COPY: a recursive operation must not do what a direct request
    // refuses, which is the class this project has now re-found at five separate verbs.
    //
    // Nothing is destroyed here (/move has no overwrite path — it routes through
    // -_uniquePathForPath:), but relocating a file the client may not touch is still acting on it.
    if (isDirectory) {
        NSString *const unvettable = WSKFirstUnvettableItemAtPath(oldAbsolutePath, YES, _allowedFileExtensions);

        if (unvettable) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Moving \"%@\" is not allowed: it contains \"%@\"", oldRelativePath, unvettable];
        }
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
        // Same rule as /upload above: a full volume or quota is 507, via the shared mapping.
        return [WSKErrorResponse responseWithServerError:WSKServerErrorStatusCodeForError(error) underlyingError:error message:@"Failed moving \"%@\" to \"%@\"", oldRelativePath, newRelativePath];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didMoveItemFromPath:toPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Re-read and re-check inside the block. The property is weak AND mutable, so the
            // object checked above need not be the one messaged here — a host app that swaps
            // its delegate for another LIVE object implementing a different subset of these
            // optional methods raises unrecognized-selector, and nothing in Sources/ catches an
            // NSException. (Setting it to nil, or letting it deallocate, was always safe: the
            // weak read yields nil and the message is a no-op.) The strong local also removes a
            // second weak load between this check and the send. Deliberately NOT a strong
            // capture at check time: that would keep a delegate the host app has released alive
            // and deliver into an object mid-teardown.
            id<WSKWebUploaderDelegate> const delegate = self.delegate;

            if ([delegate respondsToSelector:@selector(webUploader:didMoveItemFromPath:toPath:)]) {
                [delegate webUploader:self didMoveItemFromPath:oldAbsolutePath toPath:newAbsolutePath];
            }
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

    NSString *absolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];
    BOOL isDirectory = NO;

    // A missing/empty path collapses to the upload directory itself; refuse to
    // operate on the root (deleting it would wipe the entire share).
    if (!WSKPathIsInsideDirectory(absolutePath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Operating on the root directory is not allowed"];
    }

    // Deleting is destructive, so resolve once and destroy exactly what was vetted: a symlink
    // retargeted between the check and the unlink would otherwise decide what gets removed.
    BOOL isHidden = NO;
    NSString *const resolvedPath = [self _namedEntryPathForRelativePath:relativePath hidden:&isHidden];

    if (resolvedPath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not allowed", relativePath];
    }

    absolutePath = resolvedPath;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    if (isHidden) {
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
        // Deleting a directory removes its whole subtree, which must not become a way to destroy
        // files that a direct delete would refuse. The extension check above only applies to the
        // item itself, so vet the contents first.
        //
        // Shared with WebDAV rather than spelled again here: this walk was a second implementation
        // of the same rule, comments and all, and "a rule closed in one server and not the other"
        // is the class that has recurred FOUR times in this project — including through this exact
        // walk, where the -skipDescendants handling was wrong in both copies simultaneously.
        NSString *const unvettable = WSKFirstUnvettableItemAtPath(absolutePath, isDirectory, _allowedFileExtensions);

        if (unvettable) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not allowed: it contains \"%@\"", relativePath, unvettable];
        }

        // -removeItemAtPath: deletes as it walks and stops at the first member it cannot unlink,
        // keeping everything it already destroyed and reporting only a failure. Ask before
        // touching anything. Deliberately NOT folded into the allow-list walk above, which is
        // skipped entirely when no allow-list is configured — the default, and where this is
        // reachable.
        NSString *const unremovable = WSKFirstUnremovableItemAtPath(absolutePath);

        if (unremovable) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not allowed: \"%@\" cannot be removed", relativePath, unremovable];
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
            // Re-read and re-check inside the block. The property is weak AND mutable, so the
            // object checked above need not be the one messaged here — a host app that swaps
            // its delegate for another LIVE object implementing a different subset of these
            // optional methods raises unrecognized-selector, and nothing in Sources/ catches an
            // NSException. (Setting it to nil, or letting it deallocate, was always safe: the
            // weak read yields nil and the message is a no-op.) The strong local also removes a
            // second weak load between this check and the send. Deliberately NOT a strong
            // capture at check time: that would keep a delegate the host app has released alive
            // and deliver into an object mid-teardown.
            id<WSKWebUploaderDelegate> const delegate = self.delegate;

            if ([delegate respondsToSelector:@selector(webUploader:didDeleteItemAtPath:)]) {
                [delegate webUploader:self didDeleteItemAtPath:absolutePath];
            }
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

    NSString *const requestedPath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];

    // An empty path collapses to the upload directory itself; refuse it (uniquing
    // the root would otherwise create a sibling directory outside the share).
    if (!WSKPathIsInsideDirectory(requestedPath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Operating on the root directory is not allowed"];
    }

    // Resolved once — the parent must resolve inside the share, so a symlinked intermediate
    // component cannot place the new directory outside it — and a hidden component is refused
    // anywhere in the chain, not just in the new directory's own name, or /create becomes a way
    // to populate a dot-directory. The mkdir below then targets the resolved location.
    BOOL isHidden = NO;
    NSString *const desiredPath = [self _resolvedPathForRelativePath:relativePath hidden:&isHidden];

    if (desiredPath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Creating \"%@\" is not allowed", relativePath];
    }

    if (isHidden) {
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
        // Same rule as /upload and /move: a full volume or quota is 507, via the shared mapping.
        // Matches WebDAV's MKCOL, which already routes createDirectory failures through it.
        return [WSKErrorResponse responseWithServerError:WSKServerErrorStatusCodeForError(error) underlyingError:error message:@"Failed creating directory \"%@\"", relativePath];
    }

    if ([self.delegate respondsToSelector:@selector(webUploader:didCreateDirectoryAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Re-read and re-check inside the block. The property is weak AND mutable, so the
            // object checked above need not be the one messaged here — a host app that swaps
            // its delegate for another LIVE object implementing a different subset of these
            // optional methods raises unrecognized-selector, and nothing in Sources/ catches an
            // NSException. (Setting it to nil, or letting it deallocate, was always safe: the
            // weak read yields nil and the message is a no-op.) The strong local also removes a
            // second weak load between this check and the send. Deliberately NOT a strong
            // capture at check time: that would keep a delegate the host app has released alive
            // and deliver into an object mid-teardown.
            id<WSKWebUploaderDelegate> const delegate = self.delegate;

            if ([delegate respondsToSelector:@selector(webUploader:didCreateDirectoryAtPath:)]) {
                [delegate webUploader:self didCreateDirectoryAtPath:absolutePath];
            }
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
