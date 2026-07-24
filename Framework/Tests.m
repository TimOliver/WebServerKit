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

@end
