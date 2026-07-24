#import <GCDWebServers/GCDWebServers.h>
#import <XCTest/XCTest.h>

#import <netinet/in.h>
#import <sys/socket.h>

#import "GCDWebUploaderSSEChannel.h"

#pragma clang diagnostic ignored "-Weverything"  // Prevent "messaging to unqualified id" warnings

static NSData* SSEData(NSString* string) {
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

// Opens a raw TCP connection to localhost:port with a 5 second receive timeout,
// so tests can exercise server behavior below the HTTP-client abstraction.
static int ConnectToLocalhostPort(NSUInteger port) {
    int fd = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_in addr;
    bzero(&addr, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    return fd;
}

// Reads until the peer closes the connection (EOF) or the receive timeout fires.
// Returns the accumulated bytes; *sawEOF reports whether EOF was actually seen.
static NSData* ReadToEOF(int fd, BOOL* sawEOF) {
    NSMutableData* data = [NSMutableData data];
    char buffer[4096];
    *sawEOF = NO;
    while (1) {
        ssize_t result = recv(fd, buffer, sizeof(buffer), 0);
        if (result > 0) {
            [data appendBytes:buffer length:(NSUInteger)result];
        } else {
            *sawEOF = (result == 0);
            return data;
        }
    }
}

@interface Tests : XCTestCase
@end

@implementation Tests

- (void)testWebServer {
    GCDWebServer *server = [[GCDWebServer alloc] init];

    XCTAssertNotNil(server);
}

- (void)testDAVServer {
    GCDWebDAVServer *server = [[GCDWebDAVServer alloc] init];

    XCTAssertNotNil(server);
}

- (void)testWebUploader {
    GCDWebUploader *server = [[GCDWebUploader alloc] init];

    XCTAssertNotNil(server);
}

- (void)testPaths {
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@""), @"");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"/foo/"), @"/foo");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/bar"), @"foo/bar");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo//bar"), @"foo/bar");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/bar//"), @"foo/bar");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/./bar"), @"foo/bar");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/bar/."), @"foo/bar");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"foo/../bar"), @"bar");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"/foo/../bar"), @"/bar");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"/foo/.."), @"/");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"/.."), @"/");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"."), @"");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@".."), @"");
    XCTAssertEqualObjects(GCDWebServerNormalizePath(@"../.."), @"");

    // An embedded NUL is treated as a terminator, so the extension check and the actual
    // file access can no longer disagree (which would bypass an extension allow-list).
    unichar nul = 0;
    NSString *const nulStr = [NSString stringWithCharacters:&nul length:1];
    XCTAssertEqualObjects(GCDWebServerNormalizePath([[@"secret.dat" stringByAppendingString:nulStr] stringByAppendingString:@".png"]), @"secret.dat");
}

// A misspelled AuthenticationMethod must fail closed (refuse to start) rather than
// silently run the server with no authentication at all.
- (void)testUnknownAuthenticationMethodFailsClosed {
    GCDWebServer *server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [GCDWebServerDataResponse responseWithText:@"ok"];
    }];

    NSError *error = nil;
    BOOL started = [server startWithOptions:@{
        GCDWebServerOption_Port : @(0),
        GCDWebServerOption_BindToLocalhost : @(YES),
        GCDWebServerOption_AuthenticationMethod : @"Digest",  // typo for "DigestAccess"
        GCDWebServerOption_AuthenticationAccounts : @{@"user" : @"password"}
    } error:&error];
    XCTAssertFalse(started);
    XCTAssertNotNil(error);
    if (started) {
        [server stop];
    }

    // The correctly-spelled method still starts.
    NSError *validError = nil;
    BOOL validStarted = [server startWithOptions:@{
        GCDWebServerOption_Port : @(0),
        GCDWebServerOption_BindToLocalhost : @(YES),
        GCDWebServerOption_AuthenticationMethod : GCDWebServerAuthenticationMethod_DigestAccess,
        GCDWebServerOption_AuthenticationAccounts : @{@"user" : @"password"}
    } error:&validError];
    XCTAssertTrue(validStarted);
    if (validStarted) {
        [server stop];
    }
}

// A filename containing a bare CR/LF must not reach the Content-Disposition value (a raw
// control char makes CFNetwork drop the whole header, serving the file inline), and
// downloads must carry X-Content-Type-Options: nosniff.
- (void)testAttachmentFilenameStripsControlCharactersAndSetsNosniff {
    unichar cr = 0x0D;
    NSString *const crString = [NSString stringWithCharacters:&cr length:1];
    NSString *const fileName = [[@"evil" stringByAppendingString:crString] stringByAppendingString:@".html"];
    NSString *const path = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    NSError *writeError = nil;
    BOOL wrote = [@"<script>alert(1)</script>" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    XCTAssertTrue(wrote, @"could not create test file: %@", writeError);

    GCDWebServerFileResponse *const response = [GCDWebServerFileResponse responseWithFile:path isAttachment:YES];
    XCTAssertNotNil(response);
    NSString *const disposition = [response valueForAdditionalHeader:@"Content-Disposition"];
    XCTAssertNotNil(disposition);
    XCTAssertEqual([disposition rangeOfString:crString].location, (NSUInteger)NSNotFound);  // no raw CR
    XCTAssertFalse([disposition containsString:@"\n"]);  // no raw LF
    XCTAssertTrue([disposition hasPrefix:@"attachment;"]);
    XCTAssertEqualObjects([response valueForAdditionalHeader:@"X-Content-Type-Options"], @"nosniff");

    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

#pragma mark - GCDWebUploaderSSEChannel

// Messages produced while no reader is parked must be buffered and later
// delivered in FIFO order — not dropped.
- (void)testSSEChannelBuffersMessagesUntilReaderParks {
    GCDWebUploaderSSEChannel* channel = [[GCDWebUploaderSSEChannel alloc] initWithCapacity:100];

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
    GCDWebUploaderSSEChannel* channel = [[GCDWebUploaderSSEChannel alloc] initWithCapacity:100];

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
    GCDWebUploaderSSEChannel* channel = [[GCDWebUploaderSSEChannel alloc] initWithCapacity:100];

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
    GCDWebUploaderSSEChannel* channel = [[GCDWebUploaderSSEChannel alloc] initWithCapacity:100];
    channel.idleHeartbeats = 5;
    [channel parkReader:^(NSData* data) {}];
    XCTAssertEqual(channel.idleHeartbeats, (NSUInteger)0);
}

// When the buffer overflows (e.g. a dead connection), the oldest messages are
// dropped so memory stays bounded.
- (void)testSSEChannelDropsOldestBeyondCapacity {
    GCDWebUploaderSSEChannel* channel = [[GCDWebUploaderSSEChannel alloc] initWithCapacity:2];

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
// (GCDWebServer's end-of-stream marker) so the connection winds down cleanly
// instead of waiting forever on a channel nothing will ever write to again.
- (void)testSSEChannelCloseDeliversEndOfStreamToParkedReader {
    GCDWebUploaderSSEChannel* channel = [[GCDWebUploaderSSEChannel alloc] initWithCapacity:100];

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
    GCDWebUploaderSSEChannel* channel = [[GCDWebUploaderSSEChannel alloc] initWithCapacity:100];
    [channel close];

    __block NSData* received = nil;
    [channel parkReader:^(NSData* data) { received = data; }];
    XCTAssertEqualObjects(received, [NSData data]);
    XCTAssertFalse(channel.hasParkedReader);
}

// After close, the buffer is dropped and further messages are discarded: the
// next reader must see end-of-stream, not stale events.
- (void)testSSEChannelDropsMessagesAfterClose {
    GCDWebUploaderSSEChannel* channel = [[GCDWebUploaderSSEChannel alloc] initWithCapacity:100];

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
    GCDWebUploaderSSEChannel* channel = [[GCDWebUploaderSSEChannel alloc] initWithCapacity:100];

    __block NSUInteger callCount = 0;
    [channel parkReader:^(NSData* data) { callCount += 1; }];
    [channel close];
    [channel close];
    XCTAssertEqual(callCount, (NSUInteger)1);
}

#pragma mark - SSE connection teardown

// Stopping the uploader while an SSE client is connected must actively end that
// connection (via the channel close sentinel). Previously the channels were just
// dropped from the registry, leaving the connection parked forever — leaking the
// socket, the connection, and (through a retain cycle) the server itself.
- (void)testStopClosesActiveSSEConnections {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
    GCDWebUploader* uploader = [[GCDWebUploader alloc] initWithUploadDirectory:directory];
    XCTAssertNotNil(uploader);
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([uploader startWithOptions:options error:NULL]);

    int fd = ConnectToLocalhostPort(uploader.port);
    XCTAssertGreaterThan(fd, 0);
    const char* request = "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n";
    XCTAssertEqual(send(fd, request, strlen(request), 0), (ssize_t)strlen(request));

    // Wait for the response headers so the stream is established before stopping.
    char buffer[4096];
    XCTAssertGreaterThan(recv(fd, buffer, sizeof(buffer), 0), (ssize_t)0);

    [uploader stop];

    BOOL sawEOF = NO;
    ReadToEOF(fd, &sawEOF);
    XCTAssertTrue(sawEOF, @"server did not close the SSE connection after -stop");
    close(fd);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

#pragma mark - Connection idle timeout

// A client that connects and then goes silent while the server is waiting on
// socket I/O must be disconnected once the idle timeout elapses, instead of
// holding a connection slot (and file descriptor) forever.
- (void)testConnectionIdleTimeoutClosesSilentConnection {
    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[GCDWebServerRequest class]
                          processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                              return [GCDWebServerDataResponse responseWithText:@"hello"];
                          }];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES, GCDWebServerOption_ConnectionIdleTimeout : @0.5};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(fd, 0);

    // Send nothing: the server is parked in a header read that will never complete.
    BOOL sawEOF = NO;
    ReadToEOF(fd, &sawEOF);
    XCTAssertTrue(sawEOF, @"server did not disconnect a silent client");
    close(fd);
    [server stop];
}

// The timeout must only fire while the connection is actually waiting on socket
// I/O. A handler that takes longer than the timeout to produce a response (no
// pending reads or writes during that window) must not have its connection cut.
- (void)testConnectionIdleTimeoutSparesSlowHandler {
    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[GCDWebServerRequest class]
                     asyncProcessBlock:^(GCDWebServerRequest* request, GCDWebServerCompletionBlock completionBlock) {
                         dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * (double)NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                             completionBlock([GCDWebServerDataResponse responseWithText:@"slow-response-body"]);
                         });
                     }];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES, GCDWebServerOption_ConnectionIdleTimeout : @0.5};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(fd, 0);
    const char* request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    XCTAssertEqual(send(fd, request, strlen(request), 0), (ssize_t)strlen(request));

    BOOL sawEOF = NO;
    NSData* data = ReadToEOF(fd, &sawEOF);
    NSString* reply = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    XCTAssertTrue([reply containsString:@"200"], @"expected a 200 response, got: %@", reply);
    XCTAssertTrue([reply containsString:@"slow-response-body"], @"slow handler's response was cut off: %@", reply);
    close(fd);
    [server stop];
}

@end
