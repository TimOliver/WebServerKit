// The SSE channel state machine, and the /events endpoint that vends it.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import "TestsSupport.h"

// The uploader declares its NSFilePresenter conformance in a class extension inside its own .m, so
// the selector is invisible here. Re-declaring the conformance — and nothing else — is enough to
// override the callback and message super; it adds no implementation and changes no behaviour.
@interface WSKWebUploader (TestVisibleFilePresenter) <NSFilePresenter>
@end

// Counts -presentedSubitemDidChangeAtURL: without changing what it does. A plain subclass rather
// than a swizzle: this stays confined to the uploaders these tests construct instead of altering
// the class for the whole test process.
@interface PresenterCountingUploader : WSKWebUploader
@property (nonatomic) NSUInteger presenterEventCount;
@end

@implementation PresenterCountingUploader

- (void)presentedSubitemDidChangeAtURL:(NSURL*)url {
    self.presenterEventCount += 1;
    [super presentedSubitemDidChangeAtURL:url];
}

@end

@interface WSKServerSentEventsTests : XCTestCase
@end

@implementation WSKServerSentEventsTests

// Reaches -_relativePathForAbsolutePath: by selector: it is private to the uploader, and the SSE
// path derivation is exactly what this suite exists to pin. Lived on the old monolithic Tests
// class; it belongs with its only caller.
- (NSString*)relativePathFrom:(WSKWebUploader*)server forAbsolute:(NSString*)absolutePath {
    SEL selector = NSSelectorFromString(@"_relativePathForAbsolutePath:");
    XCTAssertTrue([server respondsToSelector:selector]);
    NSMethodSignature* signature = [server methodSignatureForSelector:selector];
    NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = server;
    invocation.selector = selector;
    [invocation setArgument:&absolutePath atIndex:2];
    [invocation invoke];
    __unsafe_unretained NSString* result = nil;
    [invocation getReturnValue:&result];
    return result;
}

// Messages produced while no reader is parked must be buffered and later
// delivered in FIFO order — not dropped.
- (void)testSSEChannelBuffersMessagesUntilReaderParks {
    WSKWebUploaderSSEChannel* channel = [[WSKWebUploaderSSEChannel alloc] initWithCapacity:100];

    [channel enqueueData:SSEData(@"a")];
    [channel enqueueData:SSEData(@"b")];
    XCTAssertEqual(channel.bufferedCount, (NSUInteger)2);
    XCTAssertFalse(channel.hasParkedReader);

    NSMutableArray<NSData*>* received = [NSMutableArray array];
    void (^reader)(NSData*) = ^(NSData* data) { [received addObject:data]; };

    [channel parkReader:reader];
    XCTAssertEqualObjects(received, (@[ SSEData(@"a") ]));
    XCTAssertEqual(channel.bufferedCount, (NSUInteger)1);

    [channel parkReader:reader];
    XCTAssertEqualObjects(received, (@[ SSEData(@"a"), SSEData(@"b") ]));
    XCTAssertEqual(channel.bufferedCount, (NSUInteger)0);
}

// A message enqueued while a reader is parked is delivered to it immediately.
- (void)testSSEChannelDeliversToParkedReaderOnEnqueue {
    WSKWebUploaderSSEChannel* channel = [[WSKWebUploaderSSEChannel alloc] initWithCapacity:100];

    __block NSData* received = nil;
    [channel parkReader:^(NSData* data) { received = data; }];
    XCTAssertTrue(channel.hasParkedReader);
    XCTAssertNil(received);

    [channel enqueueData:SSEData(@"a")];
    XCTAssertEqualObjects(received, SSEData(@"a"));
    XCTAssertFalse(channel.hasParkedReader);
}

// The bug this class fixes: a burst of events arriving between ping-pong reads
// must all survive and be delivered in order once the reader re-parks.
- (void)testSSEChannelDoesNotDropBurstBetweenReads {
    WSKWebUploaderSSEChannel* channel = [[WSKWebUploaderSSEChannel alloc] initWithCapacity:100];

    NSMutableArray<NSString*>* received = [NSMutableArray array];
    void (^reader)(NSData*) = ^(NSData* data) {
        [received addObject:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    };

    [channel parkReader:reader];           // parked on empty buffer
    [channel enqueueData:SSEData(@"1")];   // delivered immediately, reader consumed
    // Three more events arrive before the reader re-parks.
    [channel enqueueData:SSEData(@"2")];
    [channel enqueueData:SSEData(@"3")];
    [channel enqueueData:SSEData(@"4")];

    [channel parkReader:reader];
    [channel parkReader:reader];
    [channel parkReader:reader];

    XCTAssertEqualObjects(received, (@[ @"1", @"2", @"3", @"4" ]));
}

// Parking a reader signals the client is alive, so it resets the idle-heartbeat
// counter the owner uses to reap connections that have stopped reading.
- (void)testSSEChannelParkingResetsIdleHeartbeats {
    WSKWebUploaderSSEChannel* channel = [[WSKWebUploaderSSEChannel alloc] initWithCapacity:100];
    channel.idleHeartbeats = 5;
    [channel parkReader:^(NSData* data) {}];
    XCTAssertEqual(channel.idleHeartbeats, (NSUInteger)0);
}

// When the buffer overflows (e.g. a dead connection), the oldest messages are
// dropped so memory stays bounded.
- (void)testSSEChannelDropsOldestBeyondCapacity {
    WSKWebUploaderSSEChannel* channel = [[WSKWebUploaderSSEChannel alloc] initWithCapacity:2];

    [channel enqueueData:SSEData(@"1")];
    [channel enqueueData:SSEData(@"2")];
    [channel enqueueData:SSEData(@"3")];  // drops "1"
    XCTAssertEqual(channel.bufferedCount, (NSUInteger)2);

    NSMutableArray<NSString*>* received = [NSMutableArray array];
    void (^reader)(NSData*) = ^(NSData* data) {
        [received addObject:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    };
    [channel parkReader:reader];
    [channel parkReader:reader];
    XCTAssertEqualObjects(received, (@[ @"2", @"3" ]));
}

// Closing a channel must complete a parked reader with the empty-data sentinel
// (WSKWebServer's end-of-stream marker) so the connection winds down cleanly
// instead of waiting forever on a channel nothing will ever write to again.
- (void)testSSEChannelCloseDeliversEndOfStreamToParkedReader {
    WSKWebUploaderSSEChannel* channel = [[WSKWebUploaderSSEChannel alloc] initWithCapacity:100];

    __block NSData* received = nil;
    [channel parkReader:^(NSData* data) { received = data; }];
    XCTAssertFalse(channel.isClosed);

    [channel close];
    XCTAssertTrue(channel.isClosed);
    XCTAssertEqualObjects(received, [NSData data]);
    XCTAssertFalse(channel.hasParkedReader);
}

// A reader parked after close (e.g. a connection whose channel was reaped or
// orphaned by -stop) must complete immediately with end-of-stream, never park.
- (void)testSSEChannelParkAfterCloseCompletesImmediately {
    WSKWebUploaderSSEChannel* channel = [[WSKWebUploaderSSEChannel alloc] initWithCapacity:100];
    [channel close];

    __block NSData* received = nil;
    [channel parkReader:^(NSData* data) { received = data; }];
    XCTAssertEqualObjects(received, [NSData data]);
    XCTAssertFalse(channel.hasParkedReader);
}

// After close, the buffer is dropped and further messages are discarded: the
// next reader must see end-of-stream, not stale events.
- (void)testSSEChannelDropsMessagesAfterClose {
    WSKWebUploaderSSEChannel* channel = [[WSKWebUploaderSSEChannel alloc] initWithCapacity:100];

    [channel enqueueData:SSEData(@"before")];
    [channel close];
    [channel enqueueData:SSEData(@"after")];
    XCTAssertEqual(channel.bufferedCount, (NSUInteger)0);

    __block NSData* received = nil;
    [channel parkReader:^(NSData* data) { received = data; }];
    XCTAssertEqualObjects(received, [NSData data]);
}

// Double-close must not fire the end-of-stream sentinel twice.
- (void)testSSEChannelCloseIsIdempotent {
    WSKWebUploaderSSEChannel* channel = [[WSKWebUploaderSSEChannel alloc] initWithCapacity:100];

    __block NSUInteger callCount = 0;
    [channel parkReader:^(NSData* data) { callCount += 1; }];
    [channel close];
    [channel close];
    XCTAssertEqual(callCount, (NSUInteger)1);
}

// Stopping the uploader while an SSE client is connected must actively end that
// connection (via the channel close sentinel). Previously the channels were just
// dropped from the registry, leaving the connection parked forever — leaking the
// socket, the connection, and (through a retain cycle) the server itself.
- (void)testStopClosesActiveSSEConnections {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
    WSKWebUploader* uploader = [[WSKWebUploader alloc] initWithUploadDirectory:directory];
    XCTAssertNotNil(uploader);
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([uploader startWithOptions:options error:NULL]);

    int fd = ConnectToLocalhostPort(uploader.port);
    XCTAssertGreaterThan(fd, 0);
    // The Accept header is required: /events refuses requests without it so that a
    // cross-origin <img>/<script> cannot pin SSE channels. Without it this test would get a
    // 406 and still pass — seeing headers then EOF — while exercising no SSE path at all.
    const char* request = "GET /events HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\n\r\n";
    XCTAssertEqual(send(fd, request, strlen(request), 0), (ssize_t)strlen(request));

    // Wait for the response headers so the stream is established before stopping.
    char buffer[4096];
    ssize_t received = recv(fd, buffer, sizeof(buffer) - 1, 0);
    XCTAssertGreaterThan(received, (ssize_t)0);
    buffer[received] = 0;
    XCTAssertTrue(strnstr(buffer, "text/event-stream", (size_t)received) != NULL, @"expected an SSE stream, got: %s", buffer);

    [uploader stop];

    BOOL sawEOF = NO;
    ReadToEOF(fd, &sawEOF);
    XCTAssertTrue(sawEOF, @"server did not close the SSE connection after -stop");
    close(fd);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

// A channel used to outlive its own connection by a full 30s: the server learned of the client's
// departure only when a write failed, and only *then* did the reaper start counting its two idle
// ticks. So 16 abandoned streams — browser tabs navigating away, no hostility required — denied
// live updates to a real client long after the server knew every one of them was gone. The
// channel now dies with the connection, and the reaper remains the backstop for a client that is
// merely silent.
//
// The clients here reset rather than closing gracefully, and a broadcast is issued to force the
// write that discovers them. Both are for speed: they collapse the discovery delay that this fix
// does NOT address, isolating the 30s reaper tail that it does. A graceful close is slower on
// both sides of the fix (measured: 62s before, 32s after).
- (void)testSSEChannelIsReleasedWhenItsConnectionEnds {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    NSString* host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port];
    NSString* sseRequest = [NSString stringWithFormat:@"GET /events HTTP/1.1\r\nHost: %@\r\nAccept: text/event-stream\r\nSec-Fetch-Dest: empty\r\nSec-Fetch-Mode: cors\r\nSec-Fetch-Site: same-origin\r\n\r\n", host];

    // Fill every one of the kMaxSSEChannels slots, then abandon them.
    for (NSUInteger i = 0; i < 16; i++) {
        int fd = ConnectToLocalhostPort(server.port);
        XCTAssertTrue(fd >= 0, @"could not open stream %lu", (unsigned long)i);
        const char* bytes = [sseRequest UTF8String];
        send(fd, bytes, strlen(bytes), 0);
        char buffer[2048];
        recv(fd, buffer, sizeof(buffer), 0);  // Let the stream actually start.
        struct linger abortive = {1, 0};      // RST, so the server's next write fails at once.
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &abortive, sizeof(abortive));
        close(fd);
    }

    // Provoke a write to every channel, which is what discovers the dead ones.
    NSString* createBody = @"path=/probe-folder";
    SendRawRequest(server.port, [NSString stringWithFormat:@"POST /create HTTP/1.1\r\nHost: %@\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n\r\n%@", host, (unsigned long)createBody.length, createBody]);

    // Recovery is ~2s with the fix and ~31s without it, so this bound separates them widely
    // while staying well inside a suite that otherwise runs in about eight seconds.
    BOOL granted = NO;
    for (NSUInteger attempt = 0; (attempt < 12) && !granted; attempt++) {
        [NSThread sleepForTimeInterval:1.0];
        NSString* reply = SendRawRequestUntilMarker(server.port, sseRequest, @"retry: 3000\n\n", 2.0);
        // "retry: 30000" (refused) contains "retry: 3000" (accepted), so test the longer first.
        granted = ![reply containsString:@"retry: 30000"] && [reply containsString:@"retry: 3000\n\n"];
    }
    XCTAssertTrue(granted, @"channels were still held long after the server knew every client had gone");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// An SSE stream is only ever released when the client that is reading it goes away. A HEAD
// mapped to GET has no reader at all — the connection layer discards the body unsent — so the
// channel the handler registered was held by nobody and freed only by the heartbeat reaper,
// two ticks (~30s) later. That made sixteen HEADs a complete denial of live updates for every
// real client, and unusually cheap to sustain: each request *completes*, so the sender holds
// no connection slot and can repeat the burst every 30s from anywhere on the network.
// Measured before the fix: 16 HEADs, then a genuine EventSource is refused for 30s.
- (void)testHEADOnEventsDoesNotConsumeSSEChannels {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    NSString* host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port];
    NSString* sseHeaders = @"Accept: text/event-stream\r\nSec-Fetch-Dest: empty\r\nSec-Fetch-Mode: cors\r\nSec-Fetch-Site: same-origin\r\n";

    // "retry: 30000" (refused, backing the client off) has "retry: 3000" (accepted) as a
    // prefix, so the accepted marker is matched including its terminator.
    NSString* const acceptedMarker = @"retry: 3000\n\n";
    NSString* const refusedMarker = @"retry: 30000";

    // kMaxSSEChannels is 16: enough HEADs to have exhausted every slot.
    for (NSUInteger i = 0; i < 16; i++) {
        SendRawRequest(server.port, [NSString stringWithFormat:@"HEAD /events HTTP/1.1\r\nHost: %@\r\n%@\r\n", host, sseHeaders]);
    }

    NSString* granted = SendRawRequestUntilMarker(server.port, [NSString stringWithFormat:@"GET /events HTTP/1.1\r\nHost: %@\r\n%@\r\n", host, sseHeaders], acceptedMarker, 5.0);
    XCTAssertFalse([granted containsString:refusedMarker], @"16 HEADs exhausted the SSE channels, denying a real client: %@", granted);
    XCTAssertTrue([granted containsString:acceptedMarker], @"a genuine EventSource must still be given a stream: %@", granted);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The Sec-Fetch-* checks that keep a cross-origin page from pinning every SSE channel fail
// *open* when those headers are absent — and they are absent on every browser predating them
// (Safari < 16.4, Firefox < 90), which is exactly the browser an attacker would choose. The
// Origin check the mutating endpoints already use closes that, without affecting non-browser
// clients, which send no Origin at all.
- (void)testEventsRefusesCrossOriginRequestWithoutSecFetchHeaders {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    NSString* host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port];

    NSString* hostile = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /events HTTP/1.1\r\nHost: %@\r\nOrigin: http://evil.example\r\nAccept: text/event-stream\r\n\r\n", host]);
    XCTAssertTrue([hostile hasPrefix:@"HTTP/1.1 403"], @"a cross-origin page holding a channel: %@", [hostile substringToIndex:MIN((NSUInteger)40, hostile.length)]);

    // The page's own EventSource must be unaffected: it sends a matching Origin.
    NSString* sameOrigin = SendRawRequestUntilMarker(server.port, [NSString stringWithFormat:@"GET /events HTTP/1.1\r\nHost: %@\r\nOrigin: http://%@\r\nAccept: text/event-stream\r\nSec-Fetch-Dest: empty\r\nSec-Fetch-Mode: cors\r\nSec-Fetch-Site: same-origin\r\n\r\n", host, host], @"retry: 3000\n\n", 5.0);
    XCTAssertTrue([sameOrigin containsString:@"retry: 3000\n\n"], @"the served page's own EventSource was refused: %@", sameOrigin);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The Accept gate alone does not stop a cross-origin fetch(mode:'no-cors'), which may set
// Accept and needs no preflight — enough to pin every SSE slot without reading a byte. The
// Sec-Fetch-* labels are set by the browser and cannot be forged by page script.
- (void)testSSEEndpointRefusesCrossOriginNoCorsFetch {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* noCors = SendRawRequest(server.port, @"GET /events HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\nSec-Fetch-Mode: no-cors\r\nSec-Fetch-Site: cross-site\r\nSec-Fetch-Dest: empty\r\n\r\n");
    XCTAssertTrue([noCors containsString:@"406"], @"a no-cors cross-site fetch must be refused: %@", [noCors substringToIndex:MIN((NSUInteger)40, noCors.length)]);

    NSString* crossSite = SendRawRequest(server.port, @"GET /events HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\nSec-Fetch-Mode: cors\r\nSec-Fetch-Site: cross-site\r\nSec-Fetch-Dest: empty\r\n\r\n");
    XCTAssertTrue([crossSite containsString:@"406"], @"a cross-site EventSource must be refused: %@", [crossSite substringToIndex:MIN((NSUInteger)40, crossSite.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// SSE change events name the directory that changed, and the browser only reloads when that
// matches the folder it is viewing. The path was derived by chopping the share off the front of
// a realpath(3) result while the share itself had only been -stringByStandardizingPath'd — which
// disagree for any share under NSTemporaryDirectory(), since "/var" is a symlink to
// "/private/var" that neither standardizing nor -stringByResolvingSymlinksInPath expands. Every
// event then collapsed to "/" (or "//" for a create), so live updates silently stopped for every
// subfolder. MakeTempDirectory() returns exactly such a path, so this reproduces by default.
- (void)testSSEEventsNameTheSubfolderThatChanged {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* sub = [dir stringByAppendingPathComponent:@"Sub"];
    [fm createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:NULL];

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];

    // The share must actually be one whose realpath differs, or this proves nothing.
    NSString* resolved = [dir stringByResolvingSymlinksInPath];
    char buffer[PATH_MAX];
    if (realpath([dir fileSystemRepresentation], buffer) != NULL) {
        resolved = [fm stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
    }
    XCTAssertNotEqualObjects(resolved, dir, @"this test needs a share whose realpath differs; got %@", dir);

    // Drive the private derivation directly: the event payload is built from it, and going
    // through the network would make this a test of the SSE plumbing instead.
    NSString* relative = [server valueForKey:@"uploadDirectory"] ? [self relativePathFrom:server forAbsolute:[resolved stringByAppendingPathComponent:@"Sub"]] : nil;
    XCTAssertEqualObjects(relative, @"/Sub", @"an event for a subfolder must name it, not collapse to \"/\"");

    [fm removeItemAtPath:dir error:NULL];
}

// The prefix test that derives a client-facing path needs a separator boundary. Without one, a
// SIBLING directory whose name merely begins with the share's is mapped INTO the share: a share at
// ".../Share" answered "/2/x.txt" for ".../Share2/x.txt", slicing a directory name in half to
// manufacture a path naming a file the share does not contain.
//
// Reachability, stated rather than implied: every current caller hands over a path already resolved
// INSIDE the share, so this was not reachable from the network. It is the function being wrong, and
// the sibling method -presentedSubitemDidChangeAtURL: has always had the boundary — the same rule
// spelled two ways in two places, which is this codebase's signature defect shape.
- (void)testRelativePathDerivationRequiresASeparatorBoundary {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* parent = MakeTempDirectory();
    NSString* share = [parent stringByAppendingPathComponent:@"Share"];
    NSString* sibling = [parent stringByAppendingPathComponent:@"Share2"];
    [fm createDirectoryAtPath:share withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm createDirectoryAtPath:sibling withIntermediateDirectories:YES attributes:nil error:NULL];

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:share];

    char buffer[PATH_MAX];
    XCTAssertTrue(realpath([sibling fileSystemRepresentation], buffer) != NULL);
    NSString* resolvedSibling = [fm stringWithFileSystemRepresentation:buffer length:strlen(buffer)];

    NSString* outside = [self relativePathFrom:server forAbsolute:[resolvedSibling stringByAppendingPathComponent:@"x.txt"]];
    XCTAssertEqualObjects(outside, @"/", @"a path outside the share must not be mapped into it (got %@)", outside);

    // The permitted half, so no later fix can degrade this into "answer / for everything".
    XCTAssertTrue(realpath([share fileSystemRepresentation], buffer) != NULL);
    NSString* resolvedShare = [fm stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
    XCTAssertEqualObjects([self relativePathFrom:server forAbsolute:[resolvedShare stringByAppendingPathComponent:@"Sub/x.txt"]], @"/Sub/x.txt");
    XCTAssertEqualObjects([self relativePathFrom:server forAbsolute:resolvedShare], @"/");

    [fm removeItemAtPath:parent error:NULL];
}

// _resolvedUploadDirectory is captured once at init, so a share whose realpath changes under a live
// server left every SSE event naming the share root — silently reverting the very fix the method
// above exists for. A symlinked share repointed at a new directory is exactly how an atomic publish
// swaps one, so this is not a contrived trigger.
- (void)testSSEEventPathsSurviveTheShareBeingRepointed {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* parent = MakeTempDirectory();
    NSString* targetA = [parent stringByAppendingPathComponent:@"A"];
    NSString* targetB = [parent stringByAppendingPathComponent:@"B"];
    NSString* link = [parent stringByAppendingPathComponent:@"share"];
    [fm createDirectoryAtPath:[targetA stringByAppendingPathComponent:@"Sub"] withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm createDirectoryAtPath:[targetB stringByAppendingPathComponent:@"Sub"] withIntermediateDirectories:YES attributes:nil error:NULL];
    XCTAssertTrue([fm createSymbolicLinkAtPath:link withDestinationPath:targetA error:NULL]);

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:link];

    char buffer[PATH_MAX];
    XCTAssertTrue(realpath([targetA fileSystemRepresentation], buffer) != NULL);
    NSString* resolvedA = [fm stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
    // Control: the pre-repoint answer must be right, or the assertion below proves nothing.
    XCTAssertEqualObjects([self relativePathFrom:server forAbsolute:[resolvedA stringByAppendingPathComponent:@"Sub"]], @"/Sub");

    [fm removeItemAtPath:link error:NULL];
    XCTAssertTrue([fm createSymbolicLinkAtPath:link withDestinationPath:targetB error:NULL]);

    XCTAssertTrue(realpath([targetB fileSystemRepresentation], buffer) != NULL);
    NSString* resolvedB = [fm stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
    NSString* after = [self relativePathFrom:server forAbsolute:[resolvedB stringByAppendingPathComponent:@"Sub"]];
    XCTAssertEqualObjects(after, @"/Sub", @"an event under the repointed share must still name its subfolder (got %@)", after);

    [fm removeItemAtPath:parent error:NULL];
}

// -presentedItemURL handed NSFileCoordinator the standardized path, so a share reached through a
// symlink registered for a path no change is ever reported against and the uploader's whole
// external-change feature was absent — not degraded, absent.
//
// The real-path control is load-bearing twice over: it proves the probe can see anything at all
// (the first version of this test read _pendingChangedPaths and scored zero on the control too,
// because the 100 ms coalescing timer drains that set and the writes were uncoordinated), and it
// gives the symlinked case a number to match rather than a bar to clear.
- (NSUInteger)countPresenterEventsForShare:(NSString*)share {
    PresenterCountingUploader* server = [[PresenterCountingUploader alloc] initWithUploadDirectory:share];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Let the presenter registration settle before touching anything.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

    // Coordinated writes, because that is what NSFilePresenter subitem notifications are built
    // around and what a real external client (Finder) performs. A nil presenter means these are
    // somebody else's writes, so the uploader is entitled to hear about them.
    NSFileCoordinator* coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    for (int i = 0; i < 4; i++) {
        NSString* file = [share stringByAppendingPathComponent:[NSString stringWithFormat:@"external-%d.txt", i]];
        NSURL* url = [NSURL fileURLWithPath:file];
        [coordinator coordinateWritingItemAtURL:url options:0 error:NULL byAccessor:^(NSURL* writeURL) {
            [[NSString stringWithFormat:@"content %d", i] writeToURL:writeURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
    }

    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (([deadline timeIntervalSinceNow] > 0) && (server.presenterEventCount == 0)) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    NSUInteger count = server.presenterEventCount;
    [server stop];
    return count;
}

- (void)testSymlinkedShareStillReceivesFilePresenterEvents {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* parent = MakeTempDirectory();
    NSString* real = [parent stringByAppendingPathComponent:@"Real"];
    NSString* target = [parent stringByAppendingPathComponent:@"Target"];
    NSString* link = [parent stringByAppendingPathComponent:@"Link"];
    [fm createDirectoryAtPath:real withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:NULL];
    XCTAssertTrue([fm createSymbolicLinkAtPath:link withDestinationPath:target error:NULL]);

    NSUInteger control = [self countPresenterEventsForShare:real];
    NSUInteger linked = [self countPresenterEventsForShare:link];

    XCTAssertGreaterThan(control, (NSUInteger)0, @"the real-path control saw no events — this test is measuring nothing");
    XCTAssertGreaterThan(linked, (NSUInteger)0, @"a symlinked share received no file-presenter events at all (control saw %lu)", (unsigned long)control);

    [fm removeItemAtPath:parent error:NULL];
}

@end
