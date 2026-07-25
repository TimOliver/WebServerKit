#import <GCDWebServers/GCDWebServers.h>
#import <XCTest/XCTest.h>

#import <netinet/in.h>
#import <sys/socket.h>
#import <zlib.h>

#import "GCDWebServerPrivate.h"
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

// Inverse of GZipCompress: inflate a gzip stream produced by the server's response
// encoder, so tests can assert on what a client would actually receive.
static NSData* GZipDecompress(NSData* input) {
    z_stream stream;
    bzero(&stream, sizeof(stream));

    if (inflateInit2(&stream, 15 + 16) != Z_OK) {
        return nil;
    }

    stream.next_in = (Bytef*)input.bytes;
    stream.avail_in = (uInt)input.length;
    NSMutableData* output = [NSMutableData dataWithLength:(64 * 1024)];
    NSUInteger total = 0;
    int result;

    do {
        if (total == output.length) {
            output.length = 2 * output.length;
        }

        stream.next_out = (Bytef*)output.mutableBytes + total;
        stream.avail_out = (uInt)(output.length - total);
        result = inflate(&stream, Z_NO_FLUSH);
        total = output.length - stream.avail_out;
    } while (result == Z_OK);

    inflateEnd(&stream);

    if (result != Z_STREAM_END) {
        return nil;
    }

    output.length = total;
    return output;
}

// Drives a response through the same reader contract the connection uses, returning the
// whole body. Handles both synchronous readers and async ones that park the completion.
static NSData* DrainResponseBody(GCDWebServerResponse* response) {
    [response prepareForReading];
    NSError* error = nil;

    if (![response performOpen:&error]) {
        return nil;
    }

    NSMutableData* body = [NSMutableData data];

    while (1) {
        __block NSData* chunk = nil;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [response performReadDataWithCompletion:^(NSData* data, NSError* readError) {
            chunk = data;
            dispatch_semaphore_signal(semaphore);
        }];

        if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC))) != 0) {
            return nil;  // Reader never completed
        }

        if (chunk.length == 0) {
            break;
        }

        [body appendData:chunk];
    }

    [response performClose];
    return body;
}

// Produce a gzip stream (RFC 1952) from the given data, matching the format the
// server's GCDWebServerGZipDecoder expects (inflateInit2 window bits 15 + 16).
static NSData* GZipCompress(NSData* input) {
    z_stream stream;
    bzero(&stream, sizeof(stream));

    if (deflateInit2(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return nil;
    }

    stream.next_in = (Bytef*)input.bytes;
    stream.avail_in = (uInt)input.length;
    NSMutableData* output = [NSMutableData dataWithLength:(64 * 1024)];
    NSUInteger total = 0;
    int result;

    do {
        if (total == output.length) {
            output.length = 2 * output.length;
        }

        stream.next_out = (Bytef*)output.mutableBytes + total;
        stream.avail_out = (uInt)(output.length - total);
        result = deflate(&stream, Z_FINISH);
        total = output.length - stream.avail_out;
    } while (result == Z_OK);

    deflateEnd(&stream);

    if (result != Z_STREAM_END) {
        return nil;
    }

    output.length = total;
    return output;
}

// Build a request of the given class with a body, ready to receive performWriteData:.
static __kindof GCDWebServerRequest* OpenBodyRequest(Class requestClass, NSDictionary* extraHeaders) {
    NSURL* url = [NSURL URLWithString:@"http://localhost/"];
    // A Content-Length is required for the request to keep its Content-Type (and
    // thus hasBody); its value is only a capacity hint here — writing past it via
    // performWriteData: directly is fine (only the connection enforces the length).
    NSMutableDictionary* headers = [NSMutableDictionary dictionaryWithDictionary:@{@"Content-Type": @"application/octet-stream", @"Content-Length": @"1024"}];
    [headers addEntriesFromDictionary:extraHeaders];
    GCDWebServerRequest* request = [[requestClass alloc] initWithMethod:@"POST" url:url headers:headers path:@"/" query:@{}];
    [request prepareForWriting];
    NSError* error = nil;
    [request performOpen:&error];
    return request;
}

// Sends a raw request over a fresh connection and returns the full reply, read to
// EOF (every response sets Connection: Close). Nil on connect/send failure.
static NSString* SendRawRequest(NSUInteger port, NSString* request) {
    int fd = ConnectToLocalhostPort(port);
    if (fd < 0) {
        return nil;
    }
    const char* bytes = [request UTF8String];
    if (send(fd, bytes, strlen(bytes), 0) != (ssize_t)strlen(bytes)) {
        close(fd);
        return nil;
    }
    BOOL sawEOF = NO;
    NSData* data = ReadToEOF(fd, &sawEOF);
    close(fd);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString* MakeTempDirectory(void) {
    NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
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

#pragma mark - Authentication

// Basic auth must be enforced over a real connection: a request without
// credentials gets 401 (and no body leaks), and correct credentials get through.
// This exercises the per-connection path that reads the server's auth
// configuration, guarding it against regressions.
- (void)testBasicAuthEnforcedOverConnection {
    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[GCDWebServerRequest class]
                          processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                              return [GCDWebServerDataResponse responseWithText:@"secret-body"];
                          }];
    NSDictionary* options = @{
        GCDWebServerOption_Port : @0,
        GCDWebServerOption_BindToLocalhost : @YES,
        GCDWebServerOption_AuthenticationMethod : GCDWebServerAuthenticationMethod_Basic,
        GCDWebServerOption_AuthenticationAccounts : @{@"user" : @"pass"}
    };
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // No credentials: expect 401 with a challenge, and the body must not leak.
    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(fd, 0);
    const char* anonRequest = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    XCTAssertEqual(send(fd, anonRequest, strlen(anonRequest), 0), (ssize_t)strlen(anonRequest));
    BOOL sawEOF = NO;
    NSString* anonReply = [[NSString alloc] initWithData:ReadToEOF(fd, &sawEOF) encoding:NSUTF8StringEncoding];
    XCTAssertTrue([anonReply containsString:@"401"], @"expected 401 without credentials, got: %@", anonReply);
    XCTAssertNotEqual([anonReply rangeOfString:@"WWW-Authenticate" options:NSCaseInsensitiveSearch].location, (NSUInteger)NSNotFound, @"expected a challenge, got: %@", anonReply);  // CFNetwork normalizes the header case
    XCTAssertFalse([anonReply containsString:@"secret-body"], @"body leaked without authentication");
    close(fd);

    // Correct credentials: expect 200 with the body.
    int authFd = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(authFd, 0);
    NSString* credentials = [[@"user:pass" dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    NSString* authRequest = [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Basic %@\r\n\r\n", credentials];
    const char* authRequestBytes = [authRequest UTF8String];
    XCTAssertEqual(send(authFd, authRequestBytes, strlen(authRequestBytes), 0), (ssize_t)strlen(authRequestBytes));
    BOOL authSawEOF = NO;
    NSString* authReply = [[NSString alloc] initWithData:ReadToEOF(authFd, &authSawEOF) encoding:NSUTF8StringEncoding];
    XCTAssertTrue([authReply containsString:@"200"], @"expected 200 with valid credentials, got: %@", authReply);
    XCTAssertTrue([authReply containsString:@"secret-body"], @"expected the body with valid credentials, got: %@", authReply);
    close(authFd);

    [server stop];
}

#pragma mark - Error response escaping

// Request-controlled text (paths, filenames, header values) is reflected into the
// HTML error body served as text/html, so it must be fully HTML-escaped. Escaping
// only quotes leaves '<'/'>'/'&' through, allowing reflected XSS in the server's
// origin (which can list/move/delete files).
- (void)testErrorResponseEscapesReflectedMarkup {
    NSString* const payload = @"<script>alert(1)</script> a&b \"q\" 'z'";
    GCDWebServerErrorResponse* response = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"\"%@\" does not exist", payload];
    XCTAssertNotNil(response);

    [response prepareForReading];
    NSError* error = nil;
    XCTAssertTrue([response performOpen:&error]);
    __block NSData* body = nil;
    [response performReadDataWithCompletion:^(NSData* data, NSError* readError) {
        body = data;
    }];
    [response performClose];

    NSString* const html = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    XCTAssertNotNil(html);
    // The payload's angle brackets must be escaped: no raw <script> tag (the template's
    // own tags are fine; <script> only comes from the reflected message).
    XCTAssertFalse([html containsString:@"<script>"], @"reflected markup was not escaped: %@", html);
    XCTAssertFalse([html containsString:@"</script>"], @"reflected markup was not escaped: %@", html);
    XCTAssertTrue([html containsString:@"&lt;script&gt;"], @"expected escaped payload in body: %@", html);
    XCTAssertTrue([html containsString:@"a&amp;b"], @"'&' must be escaped: %@", html);
}

#pragma mark - WebDAV MOVE/COPY

// A MOVE whose destination resolves to the source file must never destroy it. The
// old code removed the destination then moved the (now-deleted) source, losing the
// only copy of the file.
- (void)testDAVMoveOntoItselfPreservesFile {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* path = [dir stringByAppendingPathComponent:@"a.txt"];
    XCTAssertTrue([@"important" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    GCDWebDAVServer* server = [[GCDWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* reply = SendRawRequest(server.port, @"MOVE /a.txt HTTP/1.1\r\nHost: localhost\r\nDestination: http://localhost/a.txt\r\nOverwrite: T\r\n\r\n");
    XCTAssertNotNil(reply);
    XCTAssertTrue([fm fileExistsAtPath:path], @"a self-MOVE must not destroy the only copy; reply: %@", reply);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// COPY onto an existing destination (with overwrite permitted) must replace it, not
// fail. The old code never removed the existing destination, so copyItem always failed.
- (void)testDAVCopyOverExistingReplacesContent {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* srcPath = [dir stringByAppendingPathComponent:@"a.txt"];
    NSString* dstPath = [dir stringByAppendingPathComponent:@"b.txt"];
    XCTAssertTrue([@"source" writeToFile:srcPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"destination" writeToFile:dstPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    GCDWebDAVServer* server = [[GCDWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* reply = SendRawRequest(server.port, @"COPY /a.txt HTTP/1.1\r\nHost: localhost\r\nDestination: http://localhost/b.txt\r\nOverwrite: T\r\n\r\n");
    XCTAssertNotNil(reply);
    XCTAssertTrue([fm fileExistsAtPath:srcPath], @"source should remain after a copy; reply: %@", reply);
    NSString* dstContent = [NSString stringWithContentsOfFile:dstPath encoding:NSUTF8StringEncoding error:NULL];
    XCTAssertEqualObjects(dstContent, @"source", @"copy-over-existing should replace the destination; reply: %@", reply);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// Regression guard: a MOVE onto a *different* existing destination (Overwrite: T)
// must still replace it and remove the source.
- (void)testDAVMoveOverExistingReplacesContent {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* srcPath = [dir stringByAppendingPathComponent:@"a.txt"];
    NSString* dstPath = [dir stringByAppendingPathComponent:@"b.txt"];
    XCTAssertTrue([@"source" writeToFile:srcPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"destination" writeToFile:dstPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    GCDWebDAVServer* server = [[GCDWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* reply = SendRawRequest(server.port, @"MOVE /a.txt HTTP/1.1\r\nHost: localhost\r\nDestination: http://localhost/b.txt\r\nOverwrite: T\r\n\r\n");
    XCTAssertNotNil(reply);
    XCTAssertFalse([fm fileExistsAtPath:srcPath], @"source should be gone after a move; reply: %@", reply);
    NSString* dstContent = [NSString stringWithContentsOfFile:dstPath encoding:NSUTF8StringEncoding error:NULL];
    XCTAssertEqualObjects(dstContent, @"source", @"move-over-existing should replace the destination; reply: %@", reply);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

#pragma mark - Request body-size caps

// A body buffered entirely in memory (e.g. a DAV PROPFIND/LOCK body or a data
// request) must be rejected once it exceeds the in-memory cap, rather than
// growing unbounded and exhausting memory on the device.
- (void)testDataRequestRejectsBodyExceedingInMemoryCap {
    GCDWebServerDataRequest* request = OpenBodyRequest([GCDWebServerDataRequest class], @{});
    XCTAssertTrue([request hasBody]);

    NSData* chunk = [NSMutableData dataWithLength:(1024 * 1024)];  // 1 MB
    NSError* error = nil;
    BOOL rejected = NO;

    for (int i = 0; i < 256; i++) {  // up to 256 MB if never rejected
        if (![request performWriteData:chunk error:&error]) {
            rejected = YES;
            break;
        }
    }

    XCTAssertTrue(rejected, @"Data request should reject a body exceeding the in-memory cap");
}

// The multipart parser can be wedged by a part whose content contains the
// boundary token not followed by CRLF: it can never advance, so the buffer
// would grow without bound. It must reject once the buffer exceeds the cap.
- (void)testMultiPartParserRejectsUnboundedBufferingFromFakeBoundary {
    GCDWebServerMultiPartFormRequest* request = OpenBodyRequest([GCDWebServerMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    XCTAssertTrue([request hasBody]);

    // A file part header, then content that begins with the boundary token "--X"
    // followed by 'y' (not CRLF) — the parser stalls on this forever.
    NSMutableData* head = [NSMutableData data];
    [head appendData:SSEData(@"--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n\r\n")];
    [head appendData:SSEData(@"--Xy")];
    NSError* error = nil;
    XCTAssertTrue([request performWriteData:head error:&error]);

    NSData* filler = [NSMutableData dataWithLength:(1024 * 1024)];  // zeros: no boundary token
    BOOL rejected = NO;

    for (int i = 0; i < 256; i++) {
        if (![request performWriteData:filler error:&error]) {
            rejected = YES;
            break;
        }
    }

    XCTAssertTrue(rejected, @"Multipart parser should reject unbounded buffering from a fake boundary");
}

// A gzip-encoded body must not be allowed to inflate without bound: a small
// highly-compressible payload that decompresses past the cap must be rejected.
- (void)testGZipDecoderRejectsDecompressionBomb {
    NSData* bomb = GZipCompress([NSMutableData dataWithLength:(80 * 1024 * 1024)]);  // inflates to 80 MB
    XCTAssertNotNil(bomb);
    XCTAssertLessThan(bomb.length, (NSUInteger)(1024 * 1024));  // sanity: compressed form is tiny

    GCDWebServerDataRequest* request = OpenBodyRequest([GCDWebServerDataRequest class], @{@"Content-Encoding": @"gzip"});
    NSError* error = nil;

    XCTAssertFalse([request performWriteData:bomb error:&error], @"gzip decoder should reject a decompression bomb");
}

#pragma mark - Crash / DoS hardening

// A COPY/MOVE carrying a Destination header but NO Host header must be rejected with
// 400, not crash the process. The destination parsing did [dst rangeOfString:Host]
// with a nil Host, which throws NSInvalidArgumentException; uncaught, that terminates
// the whole server. The server must survive and keep serving afterwards.
- (void)testDAVMoveWithoutHostHeaderDoesNotCrash {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* path = [dir stringByAppendingPathComponent:@"a.txt"];
    XCTAssertTrue([@"data" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    GCDWebDAVServer* server = [[GCDWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Destination present, Host absent (HTTP/1.0 so CFHTTPMessage accepts no Host).
    NSString* reply = SendRawRequest(server.port, @"MOVE /a.txt HTTP/1.0\r\nDestination: http://localhost/b.txt\r\nOverwrite: T\r\n\r\n");
    XCTAssertNotNil(reply);
    XCTAssertTrue([reply containsString:@"400"], @"missing Host must yield 400, got: %@", reply);
    XCTAssertTrue([fm fileExistsAtPath:path], @"file must be untouched; reply: %@", reply);

    // The process must still be alive: a fresh, well-formed request must get a reply.
    NSString* reply2 = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(reply2, @"server appears to have crashed after the malformed request");
    XCTAssertTrue([reply2 containsString:@"200"], @"server did not respond normally after the malformed request: %@", reply2);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// A chunked request whose chunk-size line never contains a CRLF must be rejected once
// the framing buffer exceeds its bound, rather than accumulating without limit (OOM).
// The per-chunk cap only applies after a size line is parsed; the framing scan itself
// was previously unbounded.
- (void)testChunkedTransferRejectsUnterminatedSizeLine {
    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"POST"
                          requestClass:[GCDWebServerDataRequest class]
                          processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                              return [GCDWebServerDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES, GCDWebServerOption_ConnectionIdleTimeout : @5.0};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(fd, 0);
    const char* head = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n";
    XCTAssertEqual(send(fd, head, strlen(head), 0), (ssize_t)strlen(head));

    // Stream ~20 MB of 'a' (all valid hex, no CRLF) so the chunk-size line can never
    // complete, exceeding the 16 MB + framing-slack bound. Send on a background queue
    // so the main thread can read the server's rejection response promptly (a blocking
    // send of the whole blob would otherwise deadlock against the server that has
    // stopped reading). A rejecting server produces an HTTP error response; a server
    // that buffered without bound would send nothing and the read would just time out.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Stream from a small reusable buffer rather than allocating the whole 20 MB. The
        // bytes on the wire are identical, but the test process no longer holds 20 MB
        // alongside the ~16 MB the server is buffering — under AddressSanitizer that peak
        // was enough to disturb neighbouring timing-sensitive tests in the same run.
        char chunk[64 * 1024];
        memset(chunk, 'a', sizeof(chunk));

        for (int i = 0; i < (20 * 1024 * 1024) / (int)sizeof(chunk); i++) {
            if (send(fd, chunk, sizeof(chunk), 0) < 0) {
                break;  // The server rejected and closed; the point is already proven
            }
        }
    });

    BOOL sawEOF = NO;
    NSString* reply = [[NSString alloc] initWithData:ReadToEOF(fd, &sawEOF) encoding:NSUTF8StringEncoding];
    XCTAssertTrue(([reply containsString:@"500"] || [reply containsString:@"400"]), @"server did not reject unbounded chunk framing (reply: %@)", reply);
    close(fd);
    [server stop];
}

// A slowloris that dribbles one byte per tick keeps "bytes moving", so the
// zero-progress idle check never fires — but the request headers never complete.
// The header-phase deadline must still close such a connection so it cannot hold a
// slot forever. Dribbling faster than one tick guarantees the zero-progress check is
// not what closes it, so a close proves the header deadline works.
- (void)testConnectionClosesSlowlorisHeaderDribble {
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

    // What is being asserted is that the connection gets closed, not that it happens within
    // any particular wall-clock time. The deadline is three 0.5 s timer ticks, but GCD timer
    // delivery slips under load, and running the whole suite (the chunked-framing test just
    // before this one pushes ~16 MB through a server under AddressSanitizer) pushed it past
    // the shared 5 s receive timeout often enough to make the suite unreliable. Give this
    // one a wider read window; it still returns the moment the server closes.
    struct timeval readTimeout = {30, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, sizeof(readTimeout));

    const char* partial = "GET / HTTP/1.1\r\nHost: localhost\r\n";  // deliberately never completes the header block
    XCTAssertEqual(send(fd, partial, strlen(partial), 0), (ssize_t)strlen(partial));

    // Dribble one header byte every 0.25 s (< the 0.5 s tick) on a background queue so
    // socket I/O keeps "progressing" and only the header-phase deadline can close us.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (int i = 0; i < 40; i++) {  // up to ~10 s of dribbling; stops early on EPIPE
            usleep(250 * 1000);
            const char space = ' ';
            if (send(fd, &space, 1, 0) < 0) {
                break;
            }
        }
    });

    BOOL sawEOF = NO;
    ReadToEOF(fd, &sawEOF);  // returns when the server closes the connection (or the 5 s recv timeout)
    XCTAssertTrue(sawEOF, @"header-phase deadline did not close a slowloris dribbling under one tick");
    close(fd);
    [server stop];
}

// Builds `levels` nested "multipart/mixed" wrappers around a single text leaf part.
// Boundaries: `top` for the outermost part, then mix1..mix{levels} for the nested
// parts; the leaf lives inside boundary mix{levels}.
static NSData* NestedMultipartMixedBody(NSString* top, NSUInteger levels) {
    NSString* leafBoundary = [NSString stringWithFormat:@"mix%lu", (unsigned long)levels];
    NSString* body = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"leaf\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--%@--\r\n", leafBoundary, leafBoundary];

    for (NSInteger i = (NSInteger)levels; i >= 1; i--) {
        NSString* boundary = (i == 1) ? top : [NSString stringWithFormat:@"mix%ld", (long)(i - 1)];
        NSString* childBoundary = [NSString stringWithFormat:@"mix%ld", (long)i];
        NSString* header = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"n%ld\"\r\nContent-Type: multipart/mixed; boundary=%@\r\n\r\n", boundary, (long)i, childBoundary];
        body = [NSString stringWithFormat:@"%@%@\r\n--%@--\r\n", header, body, boundary];
    }

    return [body dataUsingEncoding:NSUTF8StringEncoding];
}

// Nested multipart/mixed parts are fed to a synchronously-recursing sub-parser, so
// unbounded nesting overflows the worker-thread stack. Nesting within the depth cap is
// accepted; nesting beyond it is rejected (before it can recurse deeply and crash).
- (void)testMultiPartRejectsDeeplyNestedMixed {
    // Within the cap: parses successfully.
    GCDWebServerMultiPartFormRequest* shallow = OpenBodyRequest([GCDWebServerMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=top"});
    NSError* error = nil;
    XCTAssertTrue([shallow performWriteData:NestedMultipartMixedBody(@"top", 2) error:&error], @"shallow nesting should parse: %@", error);
    XCTAssertTrue([shallow performClose:&error], @"shallow nesting should finish cleanly: %@", error);

    // Beyond the cap: rejected rather than recursing to the crash depth.
    GCDWebServerMultiPartFormRequest* deep = OpenBodyRequest([GCDWebServerMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=top"});
    XCTAssertFalse([deep performWriteData:NestedMultipartMixedBody(@"top", 20) error:&error], @"deeply nested multipart/mixed must be rejected");
}

#pragma mark - Digest authentication

// Extracts a quoted directive value (e.g. nonce="…") from a header line.
static NSString* QuotedParam(NSString* header, NSString* name) {
    NSString* needle = [NSString stringWithFormat:@"%@=\"", name];
    NSRange start = [header rangeOfString:needle];
    if (start.location == NSNotFound) {
        return nil;
    }
    NSUInteger valueStart = start.location + start.length;
    NSRange end = [header rangeOfString:@"\"" options:0 range:NSMakeRange(valueStart, header.length - valueStart)];
    if (end.location == NSNotFound) {
        return nil;
    }
    return [header substringWithRange:NSMakeRange(valueStart, end.location - valueStart)];
}

// Digest auth must (a) work end-to-end and (b) bind the credential to the actual
// request target: a response computed for one URI must not authenticate a request for
// a different URI (the "uri" directive was previously never checked against the
// request line, so a captured header authenticated any same-method resource).
- (void)testDigestAuthRoundTripAndURIBinding {
    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[GCDWebServerRequest class]
                          processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                              return [GCDWebServerDataResponse responseWithText:@"secret-body"];
                          }];
    NSDictionary* options = @{
        GCDWebServerOption_Port : @0,
        GCDWebServerOption_BindToLocalhost : @YES,
        GCDWebServerOption_AuthenticationMethod : GCDWebServerAuthenticationMethod_DigestAccess,
        GCDWebServerOption_AuthenticationRealm : @"test",
        GCDWebServerOption_AuthenticationAccounts : @{@"user" : @"pass"}
    };
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Anonymous request -> 401 with a Digest challenge; capture the server-issued nonce.
    NSString* challenge = SendRawRequest(server.port, @"GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([challenge containsString:@"401"], @"expected 401 challenge, got: %@", challenge);
    NSString* nonce = QuotedParam(challenge, @"nonce");
    XCTAssertNotNil(nonce, @"no nonce in challenge: %@", challenge);

    // Compute a valid Digest response for GET /secret and authenticate.
    NSString* ha1 = GCDWebServerComputeMD5Digest(@"%@:%@:%@", @"user", @"test", @"pass");
    NSString* ha2Secret = GCDWebServerComputeMD5Digest(@"%@:%@", @"GET", @"/secret");
    NSString* response = GCDWebServerComputeMD5Digest(@"%@:%@:%@", ha1, nonce, ha2Secret);
    NSString* authForSecret = [NSString stringWithFormat:@"Authorization: Digest username=\"user\", realm=\"test\", nonce=\"%@\", uri=\"/secret\", response=\"%@\"", nonce, response];

    NSString* ok = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /secret HTTP/1.1\r\nHost: localhost\r\n%@\r\n\r\n", authForSecret]);
    XCTAssertTrue([ok containsString:@"200"], @"valid digest credentials should authenticate, got: %@", ok);
    XCTAssertTrue([ok containsString:@"secret-body"], @"expected body with valid credentials, got: %@", ok);

    // Replay the exact same Authorization header (computed for /secret) against a
    // different resource: must be rejected because the uri no longer matches.
    NSString* replay = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /other HTTP/1.1\r\nHost: localhost\r\n%@\r\n\r\n", authForSecret]);
    XCTAssertTrue([replay containsString:@"401"], @"a header computed for /secret must not authenticate /other, got: %@", replay);
    XCTAssertFalse([replay containsString:@"secret-body"], @"cross-resource replay leaked the body: %@", replay);

    [server stop];
}

#pragma mark - Uploader CSRF

// The uploader's state-changing endpoints must reject a cross-origin browser request
// (a CSRF attempt): a request whose Origin authority differs from the Host is refused,
// while a request with no Origin at all (a non-browser client) is allowed through.
// Deleting a directory removes its whole subtree, so it must not become a way to destroy
// files a direct DELETE would refuse — otherwise the same allow-list means two different
// things depending on how the request is phrased. Dot-files are the one exception: the
// client cannot see or address them, and every macOS folder carries a ".DS_Store".
- (void)testUploaderRecursiveDeleteRespectsExtensionAllowList {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    GCDWebUploader* server = [[GCDWebUploader alloc] initWithUploadDirectory:dir];
    server.allowedFileExtensions = @[ @"txt" ];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    NSString* host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port];

    NSString* (^deleteFolder)(NSString*) = ^(NSString* name) {
        NSString* body = [NSString stringWithFormat:@"path=/%@", name];
        return SendRawRequest(server.port, [NSString stringWithFormat:@"POST /delete HTTP/1.1\r\nHost: %@\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n\r\n%@", host, (unsigned long)body.length, body]);
    };

    // A folder holding a file the client may not address must not be destroyed wholesale.
    NSString* guarded = [dir stringByAppendingPathComponent:@"Guarded"];
    XCTAssertTrue([fm createDirectoryAtPath:guarded withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"ok" writeToFile:[guarded stringByAppendingPathComponent:@"note.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"secret" writeToFile:[guarded stringByAppendingPathComponent:@"id_rsa"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSString* refused = deleteFolder(@"Guarded");
    XCTAssertTrue([refused containsString:@"403"], @"expected 403 for a folder containing a disallowed file, got: %@", refused);
    XCTAssertTrue([fm fileExistsAtPath:[guarded stringByAppendingPathComponent:@"id_rsa"]], @"recursive delete destroyed a file a direct delete would refuse");

    // A folder whose only extra entry is filesystem noise must still be deletable.
    NSString* ordinary = [dir stringByAppendingPathComponent:@"Ordinary"];
    XCTAssertTrue([fm createDirectoryAtPath:ordinary withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"ok" writeToFile:[ordinary stringByAppendingPathComponent:@"note.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"junk" writeToFile:[ordinary stringByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSString* allowed = deleteFolder(@"Ordinary");
    XCTAssertFalse([allowed containsString:@"403"], @"a .DS_Store must not make an ordinary folder undeletable, got: %@", allowed);
    XCTAssertFalse([fm fileExistsAtPath:ordinary], @"the deletable folder was not removed: %@", allowed);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

- (void)testUploaderRejectsCrossOriginMutation {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    GCDWebUploader* server = [[GCDWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port];

    // Cross-origin Origin -> rejected with 403; the directory must not be created.
    NSString* body = @"path=/EvilFolder";
    NSString* crossOrigin = SendRawRequest(server.port, [NSString stringWithFormat:@"POST /create HTTP/1.1\r\nHost: %@\r\nOrigin: http://evil.example\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n\r\n%@", host, (unsigned long)body.length, body]);
    XCTAssertTrue([crossOrigin containsString:@"403"], @"cross-origin mutation must be rejected, got: %@", crossOrigin);
    XCTAssertFalse([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"EvilFolder"]], @"cross-origin request created the folder");

    // No Origin header (non-browser client) -> allowed.
    NSString* body2 = @"path=/GoodFolder";
    NSString* noOrigin = SendRawRequest(server.port, [NSString stringWithFormat:@"POST /create HTTP/1.1\r\nHost: %@\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n\r\n%@", host, (unsigned long)body2.length, body2]);
    XCTAssertFalse([noOrigin containsString:@"403"], @"a request with no Origin should be allowed, got: %@", noOrigin);
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"GoodFolder"]], @"the legitimate request did not create the folder: %@", noOrigin);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// "GET /list" with no "path" query parameter must be answered, not crash the process.
// A nil path survived every guard (GCDWebServerNormalizePath(nil) is @"", so the
// absolute path collapsed to the upload directory, which exists and is a directory) and
// then reached the per-entry dictionary literal, where -stringByAppendingPathComponent:
// on nil yields nil — inserting nil raises NSInvalidArgumentException, which nothing
// catches, so a single unauthenticated GET terminated the whole app. The listing must be
// non-empty for the loop to be entered at all, so seed both a file and a subdirectory.
- (void)testUploaderListWithoutPathParameterDoesNotCrash {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"data" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"Sub"] withIntermediateDirectories:NO attributes:nil error:NULL]);

    GCDWebUploader* server = [[GCDWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* reply = SendRawRequest(server.port, @"GET /list HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(reply, @"server appears to have crashed handling /list with no path parameter");
    XCTAssertTrue([reply containsString:@"200"], @"a missing path should list the root, got: %@", reply);
    // The entries must be rooted at "/", i.e. the default was applied rather than a nil
    // path silently producing bare names. NSJSONSerialization escapes "/" as "\/".
    XCTAssertTrue([reply containsString:@"\"\\/a.txt\""], @"file entry not rooted at the default path: %@", reply);
    XCTAssertTrue([reply containsString:@"\"\\/Sub\\/\""], @"directory entry not rooted at the default path: %@", reply);

    // The process must still be alive and serving.
    NSString* reply2 = SendRawRequest(server.port, @"GET /list?path=/ HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(reply2, @"server appears to have crashed after the parameterless request");
    XCTAssertTrue([reply2 containsString:@"200"], @"server did not respond normally afterwards: %@", reply2);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// A WebDAV LOCK with no Host header must be rejected, not crash the process. The
// <D:lockroot> href was built by chaining -stringByAppendingString: through the Host
// header, which raises NSInvalidArgumentException on a nil argument. This is the sibling
// of the COPY/MOVE Host crash (see -testDAVMoveWithoutHostHeaderDoesNotCrash), which the
// LOCK path missed. Every other precondition here is attacker-supplied: the Mac Finder
// User-Agent, Depth: 0, and an exclusive/write lockinfo body.
- (void)testDAVLockWithoutHostHeaderDoesNotCrash {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    GCDWebDAVServer* server = [[GCDWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* body = @"<?xml version=\"1.0\" encoding=\"utf-8\"?><D:lockinfo xmlns:D=\"DAV:\"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>";
    // HTTP/1.0 so CFHTTPMessage accepts the absent Host. Target "/" (the upload
    // directory itself), which always exists and skips the extension check.
    NSString* request = [NSString stringWithFormat:@"LOCK / HTTP/1.0\r\nUser-Agent: WebDAVFS/3.0.0\r\nDepth: 0\r\nContent-Type: text/xml\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)body.length, body];
    NSString* reply = SendRawRequest(server.port, request);
    XCTAssertNotNil(reply, @"server appears to have crashed handling LOCK with no Host header");
    XCTAssertTrue([reply containsString:@"400"], @"missing Host must yield 400, got: %@", reply);

    // The process must still be alive: a fresh, well-formed request must get a reply.
    NSString* reply2 = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(reply2, @"server appears to have crashed after the malformed request");
    XCTAssertTrue([reply2 containsString:@"200"], @"server did not respond normally after the malformed request: %@", reply2);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// A LOCK that does carry a Host must still succeed, and must report a lockroot built
// from it — guarding the rewritten interpolation against a behavior change.
- (void)testDAVLockWithHostHeaderReportsLockRoot {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"data" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    GCDWebDAVServer* server = [[GCDWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* body = @"<?xml version=\"1.0\" encoding=\"utf-8\"?><D:lockinfo xmlns:D=\"DAV:\"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>";
    NSString* request = [NSString stringWithFormat:@"LOCK /a.txt HTTP/1.1\r\nHost: localhost\r\nUser-Agent: WebDAVFS/3.0.0\r\nDepth: 0\r\nContent-Type: text/xml\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)body.length, body];
    NSString* reply = SendRawRequest(server.port, request);
    XCTAssertNotNil(reply);
    XCTAssertTrue([reply containsString:@"200"], @"a well-formed LOCK should succeed, got: %@", reply);
    XCTAssertTrue([reply containsString:@"<D:lockroot><D:href>http://localhost//a.txt</D:href></D:lockroot>"], @"lockroot not built from the Host header: %@", reply);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// GCDWebServerFileResponse must serve only regular files. S_IFREG is a value inside the
// S_IFMT field rather than a flag, so the old "st_mode & S_IFREG" test also accepted
// symlinks and sockets; only O_NOFOLLOW in -open: stopped a symlink being read through.
// Constructing the response must now fail outright for a symlink, whether it points
// outside the served directory or at a perfectly ordinary file inside it.
- (void)testFileResponseRejectsSymlink {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* realPath = [dir stringByAppendingPathComponent:@"real.txt"];
    XCTAssertTrue([@"payload" writeToFile:realPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    // A regular file is still served, with the body length taken from the file itself.
    GCDWebServerFileResponse* ok = [GCDWebServerFileResponse responseWithFile:realPath];
    XCTAssertNotNil(ok, @"a regular file must still be servable");
    XCTAssertEqual(ok.contentLength, (NSUInteger)7);

    // A symlink to a file inside the directory must be refused.
    NSString* insideLink = [dir stringByAppendingPathComponent:@"inside.txt"];
    XCTAssertTrue([fm createSymbolicLinkAtPath:insideLink withDestinationPath:realPath error:NULL]);
    XCTAssertNil([GCDWebServerFileResponse responseWithFile:insideLink], @"a symlink must not be accepted as a regular file");

    // A symlink escaping the directory must be refused too. Previously this built a
    // response whose Content-Length came from the link rather than its target, and was
    // only stopped later by O_NOFOLLOW failing with ELOOP.
    NSString* outsidePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    XCTAssertTrue([@"secret" writeToFile:outsidePath atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSString* escapingLink = [dir stringByAppendingPathComponent:@"escape.txt"];
    XCTAssertTrue([fm createSymbolicLinkAtPath:escapingLink withDestinationPath:outsidePath error:NULL]);
    XCTAssertNil([GCDWebServerFileResponse responseWithFile:escapingLink], @"a symlink out of the served directory must not be accepted");

    // A directory is still refused, as before.
    XCTAssertNil([GCDWebServerFileResponse responseWithFile:dir]);

    [fm removeItemAtPath:outsidePath error:NULL];
    [fm removeItemAtPath:dir error:NULL];
}

#pragma mark - Symlink-resolved path containment

// The textual containment checks cannot see symlinks: GCDWebServerNormalizePath strips
// ".." before any file is touched, and GCDWebServerPathIsInsideDirectory compares path
// text, but the filesystem follows symlinks in intermediate components. The resolved
// check must accept a path inside the directory (whether or not it exists yet) and
// reject one that leaves it through a link.
- (void)testResolvedPathContainment {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* outside = MakeTempDirectory();
    XCTAssertTrue([@"secret" writeToFile:[outside stringByAppendingPathComponent:@"secret.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"data" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"Sub"] withIntermediateDirectories:NO attributes:nil error:NULL]);

    // The directory itself and real items inside it are within.
    XCTAssertTrue(GCDWebServerResolvedPathIsWithinDirectory(dir, dir));
    XCTAssertTrue(GCDWebServerResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"a.txt"], dir));
    XCTAssertTrue(GCDWebServerResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Sub"], dir));

    // A destination that does not exist yet resolves through its parent, so uploads and
    // MKCOL keep working.
    XCTAssertTrue(GCDWebServerResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"new.txt"], dir));
    XCTAssertTrue(GCDWebServerResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Sub/new.txt"], dir));

    // A symlink that stays inside the directory is still usable.
    XCTAssertTrue([fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"Inside"] withDestinationPath:[dir stringByAppendingPathComponent:@"Sub"] error:NULL]);
    XCTAssertTrue(GCDWebServerResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Inside/new.txt"], dir));

    // A symlink pointing out of the directory is rejected, both as the leaf and as an
    // intermediate component (the case that string comparison misses entirely).
    XCTAssertTrue([fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"Escape"] withDestinationPath:outside error:NULL]);
    NSString* throughLink = [dir stringByAppendingPathComponent:@"Escape/secret.txt"];
    XCTAssertTrue(GCDWebServerPathIsInsideDirectory(throughLink, dir), @"precondition: the textual check does not catch this");
    XCTAssertFalse(GCDWebServerResolvedPathIsWithinDirectory(throughLink, dir), @"a path traversing a symlink out of the directory must be rejected");
    XCTAssertFalse(GCDWebServerResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Escape"], dir));
    XCTAssertFalse(GCDWebServerResolvedPathIsWithinDirectory([outside stringByAppendingPathComponent:@"secret.txt"], dir));

    // Unresolvable input fails closed.
    XCTAssertFalse(GCDWebServerResolvedPathIsWithinDirectory(@"", dir));
    XCTAssertFalse(GCDWebServerResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Nope/deeper/x.txt"], dir));

    [fm removeItemAtPath:outside error:NULL];
    [fm removeItemAtPath:dir error:NULL];
}

// End to end: a WebDAV GET that reaches a file outside the share through a symlink
// planted inside it must be refused rather than serving the file's contents.
- (void)testDAVGetThroughEscapingSymlinkIsRefused {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* outside = MakeTempDirectory();
    XCTAssertTrue([@"TOP-SECRET-PAYLOAD" writeToFile:[outside stringByAppendingPathComponent:@"secret.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"Escape"] withDestinationPath:outside error:NULL]);

    GCDWebDAVServer* server = [[GCDWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* reply = SendRawRequest(server.port, @"GET /Escape/secret.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(reply);
    XCTAssertFalse([reply containsString:@"TOP-SECRET-PAYLOAD"], @"a file outside the share was served through a symlink: %@", reply);
    XCTAssertTrue([reply containsString:@"403"], @"expected the traversal to be refused, got: %@", reply);

    [server stop];
    [fm removeItemAtPath:outside error:NULL];
    [fm removeItemAtPath:dir error:NULL];
}

#pragma mark - Preflight exemption

// The CORS-preflight exemption from authentication must require BOTH "Origin" and
// "Access-Control-Request-Method", as a real browser preflight always sends both.
// Otherwise setting a single header reaches the application's OPTIONS handler with no
// credentials at all.
- (void)testPreflightAuthExemptionRequiresOrigin {
    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"OPTIONS"
                          requestClass:[GCDWebServerRequest class]
                          processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                              return [GCDWebServerDataResponse responseWithText:@"handler-reached"];
                          }];
    NSDictionary* options = @{
        GCDWebServerOption_Port : @0,
        GCDWebServerOption_BindToLocalhost : @YES,
        GCDWebServerOption_AuthenticationMethod : GCDWebServerAuthenticationMethod_Basic,
        GCDWebServerOption_AuthenticationAccounts : @{@"user" : @"pass"}
    };
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // A genuine preflight (both headers) is exempt and reaches the handler.
    NSString* preflight = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\nOrigin: http://example.test\r\nAccess-Control-Request-Method: POST\r\n\r\n");
    XCTAssertTrue([preflight containsString:@"handler-reached"], @"a real CORS preflight must stay exempt from auth, got: %@", preflight);

    // Access-Control-Request-Method alone is not a preflight and must still need auth.
    NSString* forged = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\nAccess-Control-Request-Method: POST\r\n\r\n");
    XCTAssertTrue([forged containsString:@"401"], @"expected 401 without Origin, got: %@", forged);
    XCTAssertFalse([forged containsString:@"handler-reached"], @"the OPTIONS handler ran unauthenticated: %@", forged);

    // A plain OPTIONS request is unaffected and still requires auth.
    NSString* plain = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([plain containsString:@"401"], @"expected 401 for a plain OPTIONS, got: %@", plain);

    [server stop];
}

#pragma mark - Template escaping

// The device name is substituted into a JavaScript string literal in index.html, so it
// must be escaped for that context. A name containing a quote would otherwise break the
// literal and a name containing "</script>" would end the script block outright.
- (void)testUploaderIndexEscapesDeviceNameForJavaScript {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    GCDWebUploader* server = [[GCDWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* page = SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(page);
    XCTAssertTrue([page containsString:@"200"], @"index page did not load: %@", page);
    // Whatever this host is called, the assignment must be a syntactically closed literal
    // and must not have left a raw "%device%" placeholder behind.
    XCTAssertTrue([page containsString:@"var _device = \""], @"device name is not emitted as a quoted literal");
    XCTAssertFalse([page containsString:@"%device%"], @"the device placeholder was not substituted");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

#pragma mark - Request buffering and framing limits

// Every non-file part of a multipart body is retained in memory for the life of the
// request, so the parser's working-buffer cap does not bound them: a body made of many
// individually-legal argument parts grew without limit (200 MB of parts took the process
// to 626 MB) until the device killed the app.
- (void)testMultiPartRejectsUnboundedArgumentAccumulation {
    GCDWebServerMultiPartFormRequest* request = OpenBodyRequest([GCDWebServerMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    XCTAssertTrue([request hasBody]);

    NSMutableData* filler = [NSMutableData dataWithLength:(512 * 1024)];
    memset(filler.mutableBytes, 'A', filler.length);

    NSError* error = nil;
    BOOL rejected = NO;

    // 64 x 512 KB is 32 MB of argument data, twice the in-memory cap.
    for (int i = 0; i < 64; i++) {
        NSMutableData* part = [NSMutableData data];
        [part appendData:SSEData([NSString stringWithFormat:@"--X\r\nContent-Disposition: form-data; name=\"f%i\"\r\n\r\n", i])];
        [part appendData:filler];
        [part appendData:SSEData(@"\r\n")];

        if (![request performWriteData:part error:&error]) {
            rejected = YES;
            break;
        }
    }

    XCTAssertTrue(rejected, @"Multipart parser should reject argument parts accumulating past the in-memory cap");
}

// The budget above charges part *content*, but the control name, file name and content type
// parsed out of a part's headers are retained per part too. A body of parts each carrying a
// multi-megabyte name=".…" therefore grew memory without limit while the budget read zero.
- (void)testMultiPartRejectsOversizedPartHeaders {
    GCDWebServerMultiPartFormRequest* request = OpenBodyRequest([GCDWebServerMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});

    NSMutableString* hugeName = [NSMutableString string];
    while (hugeName.length < (64 * 1024)) {
        [hugeName appendString:@"AAAAAAAAAAAAAAAA"];
    }

    NSMutableData* part = [NSMutableData data];
    [part appendData:SSEData([NSString stringWithFormat:@"--X\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n\r\n", hugeName])];

    NSError* error = nil;
    XCTAssertFalse([request performWriteData:part error:&error], @"a part whose header block exceeds the cap should be rejected");
}

// A part whose Content-Disposition carries no "name" is malformed client input, not an
// unreachable state: it must fail the parse rather than abort the process.
- (void)testMultiPartRejectsPartWithoutControlNameWithoutAborting {
    GCDWebServerMultiPartFormRequest* request = OpenBodyRequest([GCDWebServerMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    NSMutableData* body = [NSMutableData data];
    [body appendData:SSEData(@"--X\r\nContent-Disposition: form-data; filename=\"a.txt\"\r\n\r\npayload\r\n--X--\r\n")];

    NSError* error = nil;
    XCTAssertFalse([request performWriteData:body error:&error], @"a part with no control name should be rejected");
}

// A request target whose percent-escapes are invalid or not valid UTF-8 cannot be
// decoded. That is the client's error: it must be answered 400 and must never abort.
- (void)testMalformedPercentEncodedPathIsRejectedNotFatal {
    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[GCDWebServerRequest class]
                          processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                              return [GCDWebServerDataResponse responseWithText:@"hello"];
                          }];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* reply = SendRawRequest(server.port, @"GET /%FF HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(reply);
    XCTAssertTrue([reply containsString:@"400"], @"expected 400 for an undecodable request target, got: %@", reply);

    // The server must still be serving afterwards.
    NSString* second = SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([second containsString:@"200"], @"server stopped serving after a malformed target: %@", second);
    [server stop];
}

// A Content-Length together with a chunked Transfer-Encoding is a framing conflict the
// client controls: reject it with 400 rather than asserting.
- (void)testConflictingFramingHeadersAreRejectedNotFatal {
    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"POST"
                          requestClass:[GCDWebServerDataRequest class]
                          processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                              return [GCDWebServerDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* reply = SendRawRequest(server.port, @"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n");
    XCTAssertNotNil(reply);
    XCTAssertTrue([reply containsString:@"400"], @"expected 400 for conflicting framing headers, got: %@", reply);
    [server stop];
}

// A Content-Length must be exactly a run of digits. -integerValue used to accept "5abc"
// as 5 and silently clamp an over-large value to NSIntegerMax.
- (void)testContentLengthIsParsedStrictly {
    NSURL* url = [NSURL URLWithString:@"http://localhost/"];
    NSDictionary* (^headers)(NSString*) = ^(NSString* length) {
        return @{@"Content-Type" : @"text/plain", @"Content-Length" : length};
    };

    XCTAssertNil([[GCDWebServerRequest alloc] initWithMethod:@"POST" url:url headers:headers(@"5abc") path:@"/" query:@{}]);
    XCTAssertNil([[GCDWebServerRequest alloc] initWithMethod:@"POST" url:url headers:headers(@"-1") path:@"/" query:@{}]);
    XCTAssertNil([[GCDWebServerRequest alloc] initWithMethod:@"POST" url:url headers:headers(@"") path:@"/" query:@{}]);
    XCTAssertNil([[GCDWebServerRequest alloc] initWithMethod:@"POST" url:url headers:headers(@"99999999999999999999999") path:@"/" query:@{}]);

    GCDWebServerRequest* valid = [[GCDWebServerRequest alloc] initWithMethod:@"POST" url:url headers:headers(@"5") path:@"/" query:@{}];
    XCTAssertNotNil(valid);
    XCTAssertEqual(valid.contentLength, (NSUInteger)5);
}

// A header parameter name must match at a token boundary. A plain substring search finds
// "name=" inside "filename=" and "nonce=" inside "cnonce=", so a client could pick which
// value the server read just by reordering the parameters — which broke Digest auth for
// any RFC 2617 client sending cnonce before nonce.
- (void)testHeaderValueParameterMatchesOnlyAtTokenBoundary {
    XCTAssertEqualObjects(GCDWebServerExtractHeaderValueParameter(@"form-data; filename=\"EVIL.txt\"; name=\"upload\"", @"name"), @"upload");
    XCTAssertEqualObjects(GCDWebServerExtractHeaderValueParameter(@"Digest realm=\"r\", cnonce=\"CLIENT\", nonce=\"REAL\"", @"nonce"), @"REAL");
    XCTAssertEqualObjects(GCDWebServerExtractHeaderValueParameter(@"Digest realm=\"r\", nonce=\"N\", myuri=\"/shadow\", uri=\"/real\"", @"uri"), @"/real");
    XCTAssertNil(GCDWebServerExtractHeaderValueParameter(@"form-data; filename=\"only.txt\"", @"name"));

    // Ordinary cases must be unaffected.
    XCTAssertEqualObjects(GCDWebServerExtractHeaderValueParameter(@"form-data; name=\"upload\"; filename=\"a.txt\"", @"name"), @"upload");
    XCTAssertEqualObjects(GCDWebServerExtractHeaderValueParameter(@"form-data; name=\"upload\"; filename=\"a.txt\"", @"filename"), @"a.txt");
    XCTAssertEqualObjects(GCDWebServerExtractHeaderValueParameter(@"multipart/form-data; boundary=ABC", @"boundary"), @"ABC");
    XCTAssertEqualObjects(GCDWebServerExtractHeaderValueParameter(@"text/plain; charset=utf-8", @"charset"), @"utf-8");
    XCTAssertEqualObjects(GCDWebServerExtractHeaderValueParameter(@"form-data; name=upload; filename=a.txt", @"name"), @"upload");

    // RFC 2046 allows "," in a boundary, so an unquoted value must NOT terminate there —
    // truncating "ab,cd" to "ab" makes every upload from such a client fail to parse.
    XCTAssertEqualObjects(GCDWebServerExtractHeaderValueParameter(@"multipart/form-data; boundary=ab,cd", @"boundary"), @"ab,cd");
    XCTAssertEqualObjects(GCDWebServerExtractHeaderValueParameter(@"multipart/form-data; boundary=ab,cd; charset=utf-8", @"boundary"), @"ab,cd");
}

// The idle timeout's zero-progress rule is defeated by a client that dribbles one byte
// per tick: it always looks like it is "making progress" while pinning a connection slot
// for as long as it likes. While a request body is still arriving the server must demand
// real throughput, not merely non-zero throughput.
- (void)testConnectionIdleTimeoutClosesDribblingBodyClient {
    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"POST"
                          requestClass:[GCDWebServerDataRequest class]
                          processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                              return [GCDWebServerDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES, GCDWebServerOption_ConnectionIdleTimeout : @0.5};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(fd, 0);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));  // Report a closed peer as an error, not a signal

    const char* request = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 1000000\r\n\r\n";
    XCTAssertEqual(send(fd, request, strlen(request), 0), (ssize_t)strlen(request));

    // One byte every 0.2s: faster than the 0.5s tick, so every tick observes progress.
    BOOL disconnected = NO;

    for (int i = 0; i < 50; i++) {
        usleep(200 * 1000);

        if (send(fd, "A", 1, 0) != 1) {
            disconnected = YES;
            break;
        }
    }

    close(fd);
    [server stop];
    XCTAssertTrue(disconnected, @"server did not disconnect a client dribbling its request body");
}

// -addGETHandlerForBasePath: was the one file-serving path with no containment check: it
// only stripped ".." textually, and lstat/O_NOFOLLOW refuse a symlink solely as the *final*
// component. Any symlinked directory under the served root therefore served whatever it
// pointed at.
- (void)testBasePathHandlerRefusesSymlinkEscape {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* outside = MakeTempDirectory();
    XCTAssertTrue([@"PUBLIC" writeToFile:[root stringByAppendingPathComponent:@"app.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"TOP-SECRET" writeToFile:[outside stringByAppendingPathComponent:@"secret.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"linkdir"] withDestinationPath:outside error:NULL]);

    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* escape = SendRawRequest(server.port, @"GET /linkdir/secret.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertFalse([escape containsString:@"TOP-SECRET"], @"served a file through a symlink out of the base directory");

    // Ordinary assets must still be served — this handler serves the uploader's own web UI.
    NSString* normal = SendRawRequest(server.port, @"GET /app.js HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([normal containsString:@"PUBLIC"], @"containment check broke normal asset serving: %@", normal);

    [server stop];
    [fm removeItemAtPath:root error:NULL];
    [fm removeItemAtPath:outside error:NULL];
}

// Transfer-Encoding was matched by exact string equality against "chunked", so every other
// legal spelling was silently read as "this message has no body": the server answered 200,
// discarded the body unread, and WebDAV PUT (which unlinks the destination first) destroyed
// the target file. Anything that cannot be framed or decoded must be refused instead.
- (void)testTransferEncodingIsParsedNotStringCompared {
    NSURL* url = [NSURL URLWithString:@"http://localhost/"];
    GCDWebServerRequest* (^make)(NSString*) = ^(NSString* transferEncoding) {
        return [[GCDWebServerRequest alloc] initWithMethod:@"PUT"
                                                      url:url
                                                  headers:@{@"Content-Type" : @"text/plain", @"Transfer-Encoding" : transferEncoding}
                                                     path:@"/"
                                                    query:@{}];
    };

    // Chunked, in every spelling that means chunked.
    XCTAssertTrue(make(@"chunked").usesChunkedTransferEncoding);
    XCTAssertTrue(make(@"CHUNKED").usesChunkedTransferEncoding);
    XCTAssertTrue(make(@" chunked ").usesChunkedTransferEncoding);
    XCTAssertTrue(make(@"chunked;a=b").usesChunkedTransferEncoding, @"transfer-parameters play no part in framing");

    // Codings we cannot honour must be refused, never treated as an empty body.
    XCTAssertNil(make(@"gzip, chunked"), @"a content coding we cannot decode must be refused");
    XCTAssertNil(make(@"bogus"));
    XCTAssertNil(make(@"chunked, gzip"), @"chunked must be the final coding");
    XCTAssertNil(make(@""));

    // "identity" means no chunked framing; length framing still applies.
    GCDWebServerRequest* identity = make(@"identity");
    XCTAssertNotNil(identity);
    XCTAssertFalse(identity.usesChunkedTransferEncoding);
}

// Range halves get the same strict parsing Content-Length received: -integerValue read
// "0x10" as 0 and " 5"/"+5"/"5abc" as 5.
- (void)testByteRangeIsParsedStrictly {
    NSURL* url = [NSURL URLWithString:@"http://localhost/"];
    NSRange (^rangeFor)(NSString*) = ^(NSString* value) {
        return [[[GCDWebServerRequest alloc] initWithMethod:@"GET" url:url headers:@{@"Range" : value} path:@"/" query:@{}] byteRange];
    };

    NSRange valid = rangeFor(@"bytes=500-999");
    XCTAssertEqual(valid.location, (NSUInteger)500);
    XCTAssertEqual(valid.length, (NSUInteger)500);

    NSRange openEnded = rangeFor(@"bytes=9500-");
    XCTAssertEqual(openEnded.location, (NSUInteger)9500);
    XCTAssertEqual(openEnded.length, NSUIntegerMax);

    NSRange suffix = rangeFor(@"bytes=-500");
    XCTAssertEqual(suffix.location, NSUIntegerMax);
    XCTAssertEqual(suffix.length, (NSUInteger)500);

    // Malformed values must be ignored (the sentinel), not silently coerced to a number.
    for (NSString* bad in @[ @"bytes=0x10-20", @"bytes=+5-20", @"bytes=5abc-20", @"bytes= 5-20", @"bytes=abc-def" ]) {
        NSRange r = rangeFor(bad);
        XCTAssertFalse(GCDWebServerIsValidByteRange(r), @"expected \"%@\" to be rejected, got {%lu,%lu}", bad, (unsigned long)r.location, (unsigned long)r.length);
    }
}

// The MD5 helper hashed via -UTF8String + strlen, so an embedded NUL (which survives from
// the wire into request.headers) ended the hashed input early — for a Digest nonce that
// meant the per-process secret never reached the digest and its tag became forgeable.
- (void)testMD5DigestHashesPastEmbeddedNUL {
    unichar nul = 0;
    NSString* withNUL = [NSString stringWithFormat:@"abc%@def", [NSString stringWithCharacters:&nul length:1]];
    XCTAssertNotEqualObjects(GCDWebServerComputeMD5Digest(@"%@", withNUL), GCDWebServerComputeMD5Digest(@"%@", @"abc"),
                             @"input must not be truncated at the first NUL");
}

#pragma mark - Host validation (DNS rebinding)

// A page on evil.example that repoints its DNS at this server is, to the browser, genuinely
// same-origin: CORS, Origin comparison and CSRF tokens are all satisfied. The one thing that
// still differs is the name the browser puts in Host, which is why this check exists and why
// nothing else substitutes for it.
- (void)testHostValidationRefusesRebindingButAllowsRealNames {
    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[GCDWebServerRequest class]
                          processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                              return [GCDWebServerDataResponse responseWithText:@"served"];
                          }];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* (^get)(NSString*) = ^(NSString* host) {
        return SendRawRequest(server.port, [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: %@\r\n\r\n", host]);
    };

    // Names and literals this server genuinely answers to.
    for (NSString* host in @[ @"localhost", @"LOCALHOST", @"127.0.0.1", @"192.168.1.42", @"[::1]" ]) {
        XCTAssertTrue([get(host) containsString:@"served"], @"legitimate host \"%@\" was refused", host);
    }
    XCTAssertTrue([get([NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port]) containsString:@"served"], @"matching port was refused");

    // The rebinding case, and near-misses around it.
    for (NSString* host in @[ @"evil.example", @"localhost.evil.com", @"attacker.localhost.evil.com" ]) {
        XCTAssertTrue([get(host) containsString:@"421"], @"host \"%@\" should have been refused", host);
    }
    XCTAssertTrue([get([NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port + 1]) containsString:@"421"], @"a mismatched port should be refused");

    // No Host at all is allowed: HTTP/1.0 and native clients omit it, and rebinding needs a
    // browser, which never does.
    XCTAssertTrue([SendRawRequest(server.port, @"GET / HTTP/1.0\r\n\r\n") containsString:@"served"], @"a request with no Host should be allowed");

    [server stop];
}

// The check lives in the connection layer precisely so WebDAV inherits it — WebDAV has no
// origin check of its own, so an uploader-only fix would leave the more capable API exposed.
- (void)testHostValidationCoversWebDAV {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"secret" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    GCDWebDAVServer* server = [[GCDWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{GCDWebServerOption_Port : @0, GCDWebServerOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* rebound = SendRawRequest(server.port, @"GET /a.txt HTTP/1.1\r\nHost: evil.example\r\n\r\n");
    XCTAssertTrue([rebound containsString:@"421"], @"WebDAV did not inherit host validation: %@", rebound);
    XCTAssertFalse([rebound containsString:@"secret"], @"WebDAV served file contents to a rebound host");

    NSString* legitimate = SendRawRequest(server.port, @"GET /a.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([legitimate containsString:@"secret"], @"host validation broke a legitimate WebDAV read: %@", legitimate);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The escape hatch for anyone reached under another name — a reverse proxy, a custom DNS
// entry. Entries may pin their own port.
- (void)testHostValidationHonoursConfiguredNames {
    GCDWebServer* server = [[GCDWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[GCDWebServerRequest class]
                          processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                              return [GCDWebServerDataResponse responseWithText:@"served"];
                          }];
    NSDictionary* options = @{
        GCDWebServerOption_Port : @0,
        GCDWebServerOption_BindToLocalhost : @YES,
        GCDWebServerOption_AllowedHostNames : @[ @"files.example", @"pinned.example:8080" ]
    };
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* (^get)(NSString*) = ^(NSString* host) {
        return SendRawRequest(server.port, [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: %@\r\n\r\n", host]);
    };

    XCTAssertTrue([get(@"files.example") containsString:@"served"]);
    XCTAssertTrue([get(@"FILES.EXAMPLE") containsString:@"served"], @"configured names should match case-insensitively");
    XCTAssertTrue([get(@"pinned.example:8080") containsString:@"served"], @"an entry may pin its own port");
    XCTAssertTrue([get(@"other.example") containsString:@"421"], @"an unconfigured name should still be refused");
    XCTAssertTrue([get(@"localhost") containsString:@"served"], @"the defaults should survive adding names");

    [server stop];
}

#pragma mark - gzip response encoding

// A gzip-encoded response body must decompress back to exactly what the handler produced.
- (void)testGZipEncodedDataResponseRoundTrips {
    NSString* text = @"the quick brown fox jumps over the lazy dog";
    GCDWebServerDataResponse* response = [GCDWebServerDataResponse responseWithText:text];
    response.gzipContentEncodingEnabled = YES;

    NSData* encoded = DrainResponseBody(response);
    XCTAssertNotNil(encoded);
    NSData* decoded = GZipDecompress(encoded);
    XCTAssertNotNil(decoded, @"response body was not a valid gzip stream");
    XCTAssertEqualObjects([[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding], text);
}

// The encoder pulled its source through the synchronous -readData: only, so a response
// that implements just the async reader — every GCDWebServerStreamedResponse — silently
// encoded an empty body and never ran its stream block at all.
- (void)testGZipEncodedStreamedResponseRoundTrips {
    NSArray<NSString*>* chunks = @[ @"first-", @"second-", @"third" ];
    __block NSUInteger index = 0;
    GCDWebServerStreamedResponse* response =
        [GCDWebServerStreamedResponse responseWithContentType:@"text/plain"
                                             asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock completionBlock) {
                                                 NSData* data = (index < chunks.count) ? SSEData(chunks[index]) : [NSData data];
                                                 index += 1;
                                                 completionBlock(data, nil);
                                             }];
    response.gzipContentEncodingEnabled = YES;

    NSData* encoded = DrainResponseBody(response);
    XCTAssertNotNil(encoded, @"streamed gzip response never completed");
    NSData* decoded = GZipDecompress(encoded);
    XCTAssertNotNil(decoded, @"response body was not a valid gzip stream");
    XCTAssertEqualObjects([[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding], [chunks componentsJoinedByString:@""]);
}

// The same streamed response without gzip must be unaffected.
- (void)testStreamedResponseWithoutGZipRoundTrips {
    __block NSUInteger index = 0;
    GCDWebServerStreamedResponse* response =
        [GCDWebServerStreamedResponse responseWithContentType:@"text/plain"
                                             asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock completionBlock) {
                                                 NSData* data = (index < 3) ? SSEData(@"chunk") : [NSData data];
                                                 index += 1;
                                                 completionBlock(data, nil);
                                             }];

    NSData* body = DrainResponseBody(response);
    XCTAssertEqualObjects([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding], @"chunkchunkchunk");
}

@end
