#import <WebServerKit/WebServerKit.h>
#import <XCTest/XCTest.h>

#import <netinet/in.h>
#import <sys/socket.h>
#import <zlib.h>

#import "WSKPrivate.h"
#import "WSKWebUploaderSSEChannel.h"

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
    // A server that refuses a request part way through reading it closes the socket while
    // we may still be sending, and the rest of that send would otherwise raise SIGPIPE and
    // kill the test process rather than returning an error.
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
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
static NSData* DrainResponseBody(WSKResponse* response) {
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
// server's WSKGZipDecoder expects (inflateInit2 window bits 15 + 16).
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
static __kindof WSKRequest* OpenBodyRequest(Class requestClass, NSDictionary* extraHeaders) {
    NSURL* url = [NSURL URLWithString:@"http://localhost/"];
    // A Content-Length is required for the request to keep its Content-Type (and
    // thus hasBody); its value is only a capacity hint here — writing past it via
    // performWriteData: directly is fine (only the connection enforces the length).
    NSMutableDictionary* headers = [NSMutableDictionary dictionaryWithDictionary:@{@"Content-Type": @"application/octet-stream", @"Content-Length": @"1024"}];
    [headers addEntriesFromDictionary:extraHeaders];
    WSKRequest* request = [[requestClass alloc] initWithMethod:@"POST" url:url headers:headers path:@"/" query:@{}];
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
    // A short send is not a failure: the server may legitimately have refused the request
    // and closed the socket before we finished writing it. What matters is the reply.
    send(fd, bytes, strlen(bytes), 0);
    BOOL sawEOF = NO;
    NSData* data = ReadToEOF(fd, &sawEOF);
    close(fd);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// As SendRawRequest, but for a request whose body is not valid UTF-8 (e.g. gzip).
static NSString* SendRawDataRequest(NSUInteger port, NSData* request) {
    int fd = ConnectToLocalhostPort(port);
    if (fd < 0) {
        return nil;
    }
    send(fd, request.bytes, request.length, 0);
    BOOL sawEOF = NO;
    NSData* data = ReadToEOF(fd, &sawEOF);
    close(fd);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// As SendRawRequest, but for an endpoint whose response is not meant to end: an accepted SSE
// stream is held open deliberately, so reading to EOF costs the socket's whole timeout on
// every *successful* assertion. Returns as soon as `marker` arrives (the fast path), when the
// server closes, or at the deadline — so only a genuine failure waits.
static NSString* SendRawRequestUntilMarker(NSUInteger port, NSString* request, NSString* marker, NSTimeInterval seconds) {
    int fd = ConnectToLocalhostPort(port);
    if (fd < 0) {
        return nil;
    }
    const char* bytes = [request UTF8String];
    send(fd, bytes, strlen(bytes), 0);

    struct timeval tv = {0, 200000};  // Poll; the deadline below is what actually bounds this.
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    NSMutableData* data = [NSMutableData data];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    char buffer[4096];

    while ([deadline timeIntervalSinceNow] > 0) {
        ssize_t result = recv(fd, buffer, sizeof(buffer), 0);
        if (result > 0) {
            [data appendBytes:buffer length:(NSUInteger)result];
            NSString* soFar = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if ((marker == nil) || [soFar containsString:marker]) {
                break;
            }
        } else if (result == 0) {
            break;  // Server closed: what we have is the whole reply.
        } else if ((errno != EAGAIN) && (errno != EWOULDBLOCK)) {
            break;
        }
    }
    close(fd);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// Descriptors currently open by this process. Used to prove that sustained serving does not
// leak them: on a server that lives for weeks, a descriptor leaked once per request is the
// difference between working and hitting the process limit.
static NSUInteger OpenFileDescriptorCount(void) {
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/dev/fd" error:NULL].count;
}

static NSString* MakeTempDirectory(void) {
    NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

// A request matching no handler still reaches -abortRequest:withStatusCode:, which
// WSKOption_ConnectionClass makes a host-app subclassing point. That branch populated none of
// the request's address data, so reading -remoteAddressString there dereferenced a NULL
// sockaddr — WSKStringFromSockAddr evaluates addr->sa_len before getnameinfo, so there is
// nothing to fail closed on. NOTE: against the unfixed source this does not fail, it SEGVs and
// takes the whole test process with it, which xctest reports as "0 failures". Read the executed
// count.
static NSString* gAbortRequestPeer = nil;
static BOOL gAbortRequestSawVirtualHEAD = NO;

@interface AbortProbeConnection : WSKConnection
@end

@implementation AbortProbeConnection

- (void)abortRequest:(WSKRequest*)request withStatusCode:(NSInteger)statusCode {
    gAbortRequestPeer = request.remoteAddressString;
    gAbortRequestSawVirtualHEAD = request.isVirtualHEAD;
    [super abortRequest:request withStatusCode:statusCode];
}

@end

@interface Tests : XCTestCase
@end

@implementation Tests

- (void)testWebServer {
    WSKWebServer *server = [[WSKWebServer alloc] init];

    XCTAssertNotNil(server);
}

- (void)testDAVServer {
    WSKWebDAVServer *server = [[WSKWebDAVServer alloc] init];

    XCTAssertNotNil(server);
}

- (void)testWebUploader {
    WSKWebUploader *server = [[WSKWebUploader alloc] init];

    XCTAssertNotNil(server);
}

- (void)testPaths {
    XCTAssertEqualObjects(WSKNormalizePath(@""), @"");
    XCTAssertEqualObjects(WSKNormalizePath(@"/foo/"), @"/foo");
    XCTAssertEqualObjects(WSKNormalizePath(@"foo/bar"), @"foo/bar");
    XCTAssertEqualObjects(WSKNormalizePath(@"foo//bar"), @"foo/bar");
    XCTAssertEqualObjects(WSKNormalizePath(@"foo/bar//"), @"foo/bar");
    XCTAssertEqualObjects(WSKNormalizePath(@"foo/./bar"), @"foo/bar");
    XCTAssertEqualObjects(WSKNormalizePath(@"foo/bar/."), @"foo/bar");
    XCTAssertEqualObjects(WSKNormalizePath(@"foo/../bar"), @"bar");
    XCTAssertEqualObjects(WSKNormalizePath(@"/foo/../bar"), @"/bar");
    XCTAssertEqualObjects(WSKNormalizePath(@"/foo/.."), @"/");
    XCTAssertEqualObjects(WSKNormalizePath(@"/.."), @"/");
    XCTAssertEqualObjects(WSKNormalizePath(@"."), @"");
    XCTAssertEqualObjects(WSKNormalizePath(@".."), @"");
    XCTAssertEqualObjects(WSKNormalizePath(@"../.."), @"");

    // An embedded NUL is treated as a terminator, so the extension check and the actual
    // file access can no longer disagree (which would bypass an extension allow-list).
    unichar nul = 0;
    NSString *const nulStr = [NSString stringWithCharacters:&nul length:1];
    XCTAssertEqualObjects(WSKNormalizePath([[@"secret.dat" stringByAppendingString:nulStr] stringByAppendingString:@".png"]), @"secret.dat");
}

// A misspelled AuthenticationMethod must fail closed (refuse to start) rather than
// silently run the server with no authentication at all.
- (void)testUnknownAuthenticationMethodFailsClosed {
    WSKWebServer *server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET" requestClass:[WSKRequest class] processBlock:^WSKResponse *(WSKRequest *request) {
        return [WSKDataResponse responseWithText:@"ok"];
    }];

    NSError *error = nil;
    BOOL started = [server startWithOptions:@{
        WSKOption_Port : @(0),
        WSKOption_BindToLocalhost : @(YES),
        WSKOption_AuthenticationMethod : @"Digest",  // typo for "DigestAccess"
        WSKOption_AuthenticationAccounts : @{@"user" : @"password"}
    } error:&error];
    XCTAssertFalse(started);
    XCTAssertNotNil(error);
    if (started) {
        [server stop];
    }

    // The correctly-spelled method still starts.
    NSError *validError = nil;
    BOOL validStarted = [server startWithOptions:@{
        WSKOption_Port : @(0),
        WSKOption_BindToLocalhost : @(YES),
        WSKOption_AuthenticationMethod : WSKAuthenticationMethod_DigestAccess,
        WSKOption_AuthenticationAccounts : @{@"user" : @"password"}
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

    WSKFileResponse *const response = [WSKFileResponse responseWithFile:path isAttachment:YES];
    XCTAssertNotNil(response);
    NSString *const disposition = [response valueForAdditionalHeader:@"Content-Disposition"];
    XCTAssertNotNil(disposition);
    XCTAssertEqual([disposition rangeOfString:crString].location, (NSUInteger)NSNotFound);  // no raw CR
    XCTAssertFalse([disposition containsString:@"\n"]);  // no raw LF
    XCTAssertTrue([disposition hasPrefix:@"attachment;"]);
    XCTAssertEqualObjects([response valueForAdditionalHeader:@"X-Content-Type-Options"], @"nosniff");

    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

#pragma mark - WSKWebUploaderSSEChannel

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

#pragma mark - SSE connection teardown

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

#pragma mark - Connection idle timeout

// A client that connects and then goes silent while the server is waiting on
// socket I/O must be disconnected once the idle timeout elapses, instead of
// holding a connection slot (and file descriptor) forever.
// A peer that resets the connection in the window between accept(2) and the server's
// setsockopt() makes SO_NOSIGPIPE fail with EINVAL, leaving that descriptor able to raise
// SIGPIPE — whose default disposition terminates the host application. An unauthenticated
// client can hit the window in a handful of attempts by connecting and closing abortively,
// without sending a single byte.
//
// Note the failure mode: without the fix this does not report an assertion failure, it kills
// the test runner outright. xcodebuild surfaces that as a failed suite with a truncated
// "Executed N tests" count rather than a named failing test, so read the count, not the
// failure number.
- (void)testAbortiveClientResetsDoNotKillTheProcess {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"alive"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Two shapes, because the option can fail either with a request already sent or with
    // nothing sent at all — the reset only has to land in the accept window.
    for (int round = 0; round < 2; round++) {
        for (int i = 0; i < 150; i++) {
            int fd = ConnectToLocalhostPort(server.port);
            if (fd < 0) {
                continue;
            }
            if (round == 0) {
                const char* request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
                send(fd, request, strlen(request), 0);
            }
            struct linger abortive = {1, 0};  // RST rather than FIN on close
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &abortive, sizeof(abortive));
            close(fd);
        }
    }

    // Reaching here at all is most of the assertion; this proves the listener also still works.
    NSString* reply = SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([reply containsString:@"alive"], @"server stopped serving after abortive resets: %@", reply);

    [server stop];
}

- (void)testConnectionIdleTimeoutClosesSilentConnection {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"hello"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionIdleTimeout : @0.5};
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
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                     asyncProcessBlock:^(WSKRequest* request, WSKCompletionBlock completionBlock) {
                         dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * (double)NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                             completionBlock([WSKDataResponse responseWithText:@"slow-response-body"]);
                         });
                     }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionIdleTimeout : @0.5};
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
// The header block is framed on CRLFCRLF but parsed by CFHTTPMessage, which ends the
// message at a bare LF-LF: every header in between was silently discarded and the request
// still answered 200, so the server acted on a different message than the client sent.
// Demonstrated against the Host allow-list — a Host placed after an LF-LF vanished
// entirely, taking the request down the "no Host" branch. Framing must be unambiguous.
- (void)testMalformedHeaderFramingIsRefused {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Sanity: a well-formed request still works.
    XCTAssertTrue([SendRawRequest(server.port, @"GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"200"]);

    NSDictionary* cases = @{
        @"bare LF-LF hiding later headers" : @"GET /a HTTP/1.1\r\nX-Pad: p\n\nHost: evil.example\r\n\r\n",
        @"space before the colon" : @"GET /a HTTP/1.1\r\nHost: localhost\r\nContent-Length : 5\r\n\r\n",
        @"obs-fold continuation line" : @"GET /a HTTP/1.1\r\nHost: localhost\r\nContent-Length:\r\n 5\r\n\r\n",
        @"header line with no colon" : @"GET /a HTTP/1.1\r\nHost: localhost\r\nBogusLine\r\n\r\n",
        @"non-token character in the field name" : @"GET /a HTTP/1.1\r\nHost: localhost\r\nX Bad: 1\r\n\r\n",
        @"junk after the HTTP version" : @"GET /a HTTP/1.1 junk\r\nHost: localhost\r\n\r\n",
        @"space inside the request target" : @"GET /a b HTTP/1.1\r\nHost: localhost\r\n\r\n",
        @"doubled spaces in the request line" : @"GET  /a  HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };

    [cases enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSString* raw, BOOL* stop) {
        NSString* reply = SendRawRequest(server.port, raw);
        XCTAssertNotNil(reply, @"%@: no reply", name);
        XCTAssertTrue([reply containsString:@"400"], @"%@: expected 400, got: %@", name, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }];

    [server stop];
}

// An oversized header block is the client's error, not the server's: answering 500 told
// the client we had failed and invited a retry of something that can never succeed.
- (void)testOversizedHeaderBlockIsRefusedWith431 {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* huge = [@"" stringByPaddingToLength:(1024 * 1024) withString:@"A" startingAtIndex:0];
    NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /a HTTP/1.1\r\nHost: localhost\r\nX-Big: %@\r\n\r\n", huge]);
    XCTAssertNotNil(reply);
    XCTAssertTrue([reply containsString:@"431"], @"expected 431 for an oversized header block, got: %@", [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);

    [server stop];
}

// A refusal that depends only on headers must be answered before the body is read.
// Previously the connection matched a handler, read the entire body to the device's
// temp directory, and only then ran the Host allow-list and authentication — so an
// unauthenticated client could make the server write an unbounded number of bytes to
// disk (288 MB before the 401, in testing) and repeat it across the connection pool.
//
// The test declares a large Content-Length and sends NO body: if the refusal is decided
// up front the reply arrives immediately, whereas the old ordering sits waiting for
// bytes that never come until the idle timeout fires.
- (void)testHeaderOnlyRefusalsHappenBeforeTheBodyIsRead {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{
        WSKOption_Port : @0,
        WSKOption_BindToLocalhost : @YES,
        WSKOption_AuthenticationMethod : WSKAuthenticationMethod_Basic,
        WSKOption_AuthenticationAccounts : @{@"user" : @"pass"}
    };
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // (a) No credentials.
    NSString* unauthenticated = SendRawRequest(server.port, @"PUT /big.bin HTTP/1.1\r\nHost: localhost\r\nContent-Length: 104857600\r\n\r\n");
    XCTAssertTrue([unauthenticated containsString:@"401"], @"expected 401 before the body, got: %@", unauthenticated);

    // (b) Valid credentials but a Host the allow-list does not cover. "dXNlcjpwYXNz" is
    // base64 of "user:pass", so this fails only on the Host check.
    NSString* badHost = SendRawRequest(server.port, @"PUT /big.bin HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Basic dXNlcjpwYXNz\r\nContent-Length: 104857600\r\n\r\n");
    XCTAssertTrue([badHost containsString:@"421"], @"expected 421 before the body, got: %@", badHost);

    XCTAssertEqual([fm contentsOfDirectoryAtPath:dir error:NULL].count, (NSUInteger)0, @"nothing should have been stored");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

- (void)testBasicAuthEnforcedOverConnection {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"secret-body"];
                          }];
    NSDictionary* options = @{
        WSKOption_Port : @0,
        WSKOption_BindToLocalhost : @YES,
        WSKOption_AuthenticationMethod : WSKAuthenticationMethod_Basic,
        WSKOption_AuthenticationAccounts : @{@"user" : @"pass"}
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
// An error page must not be an amplifier. WebDAV reflects an unparseable request body
// into the message, and the HTML escaper expands `"` sixfold, so an unbounded message
// turned one 16 MB request into a ~96 MB response and ~540 MB of transient memory.
- (void)testErrorResponseClampsReflectedMessage {
    NSString* const payload = [@"" stringByPaddingToLength:(4 * 1024 * 1024) withString:@"\"" startingAtIndex:0];
    WSKErrorResponse* response = [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"%@", payload];
    XCTAssertNotNil(response);

    [response prepareForReading];
    NSError* error = nil;
    XCTAssertTrue([response performOpen:&error]);
    __block NSData* body = nil;
    [response performReadDataWithCompletion:^(NSData* data, NSError* readError) {
        body = data;
    }];
    [response performClose];

    // 4 MB of quotes escaped sixfold would be 24 MB; the clamp must keep it tiny.
    XCTAssertLessThan(body.length, (NSUInteger)(64 * 1024), @"error body was not clamped: %lu bytes", (unsigned long)body.length);
}

- (void)testErrorResponseEscapesReflectedMarkup {
    NSString* const payload = @"<script>alert(1)</script> a&b \"q\" 'z'";
    WSKErrorResponse* response = [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", payload];
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

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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
    WSKDataRequest* request = OpenBodyRequest([WSKDataRequest class], @{});
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
    WSKMultiPartFormRequest* request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
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

    WSKDataRequest* request = OpenBodyRequest([WSKDataRequest class], @{@"Content-Encoding": @"gzip"});
    NSError* error = nil;

    XCTAssertFalse([request performWriteData:bomb error:&error], @"gzip decoder should reject a decompression bomb");
}

// A gzip body that satisfies its Content-Length but stops part-way through the
// deflate stream must be refused on close, not reported as a complete body. The
// decoder only asserted this (a no-op in Release), so the handler ran on a partial
// body — and on WebDAV PUT that replaced the target file with the fragment.
- (void)testGZipDecoderRejectsTruncatedBody {
    NSData* full = GZipCompress([NSMutableData dataWithLength:(64 * 1024)]);
    XCTAssertGreaterThan(full.length, (NSUInteger)20);

    WSKDataRequest* request = OpenBodyRequest([WSKDataRequest class], @{@"Content-Encoding": @"gzip"});
    NSError* error = nil;

    // The first 20 bytes are a well-formed prefix, so the write itself succeeds.
    XCTAssertTrue([request performWriteData:[full subdataWithRange:NSMakeRange(0, 20)] error:&error]);
    XCTAssertFalse([request performClose:&error], @"a truncated gzip stream must not close successfully");
}

// Bytes after Z_STREAM_END are either padding or a second concatenated member;
// either way the body is not one we can reproduce, so it must be refused rather
// than silently dropped (it was a WSK_DCHECK, i.e. an abort in Debug builds).
- (void)testGZipDecoderRejectsTrailingDataAfterStreamEnd {
    NSData* full = GZipCompress([NSMutableData dataWithLength:1024]);
    WSKDataRequest* request = OpenBodyRequest([WSKDataRequest class], @{@"Content-Encoding": @"gzip"});
    NSError* error = nil;

    XCTAssertTrue([request performWriteData:full error:&error]);
    XCTAssertFalse([request performWriteData:SSEData(@"trailing") error:&error], @"trailing data after the gzip stream must be refused");
}

// The decoder must charge the process-wide budget for the buffer it is holding, not
// for everything it has ever inflated. Charging the running total parked the whole
// budget for the life of the request on memory already handed downstream and freed,
// so one cheap request locked every other connection out of every in-memory path.
// The downstream here is a file request, which streams to disk and retains nothing.
- (void)testGZipDecoderChargesOnlyLiveBuffersToTheBudget {
    const NSUInteger kTotal = 2 * 1024 * 1024;
    WSKSetMemoryLimitsForTesting(1024 * 1024, 16 * 1024 * 1024, kTotal);

    @try {
        XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0, @"budget should start empty");

        // Inflates to 8 MB — four times the whole budget — but never more than a
        // fraction of it at once, because the compressed input is fed in slices.
        NSData* compressed = GZipCompress([NSMutableData dataWithLength:(8 * 1024 * 1024)]);
        XCTAssertNotNil(compressed);

        @autoreleasepool {
            WSKFileRequest* request = OpenBodyRequest([WSKFileRequest class], @{@"Content-Encoding": @"gzip"});
            NSError* error = nil;

            for (NSUInteger offset = 0; offset < compressed.length; offset += 256) {
                NSRange slice = NSMakeRange(offset, MIN((NSUInteger)256, compressed.length - offset));
                XCTAssertTrue([request performWriteData:[compressed subdataWithRange:slice] error:&error],
                              @"inflating %lu MB through a %lu MB budget must succeed when only live buffers are charged (failed at offset %lu: %@)",
                              (unsigned long)8, (unsigned long)(kTotal / (1024 * 1024)), (unsigned long)offset, error);
                XCTAssertLessThanOrEqual(WSKReservedMemoryLength(), kTotal, @"reserved memory exceeded the ceiling");
            }

            XCTAssertTrue([request performClose:&error], @"a complete gzip stream must close cleanly: %@", error);
        }

        XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0, @"the decoder leaked its reservation");
    } @finally {
        WSKSetMemoryLimitsForTesting(0, 0, 0);
    }
}

// End-to-end: the data-destroying case. A PUT whose gzip body is truncated must
// leave the existing file byte-identical and must not answer 2xx.
- (void)testDAVPutWithTruncatedGZipBodyPreservesExistingFile {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* path = [dir stringByAppendingPathComponent:@"keep.txt"];
    NSData* original = SSEData(@"the original contents, which must survive a refused PUT");
    XCTAssertTrue([original writeToFile:path atomically:YES]);

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSData* full = GZipCompress([NSMutableData dataWithLength:(50 * 1024)]);
    NSData* truncated = [full subdataWithRange:NSMakeRange(0, 20)];
    NSMutableData* raw = [NSMutableData data];
    [raw appendData:SSEData([NSString stringWithFormat:@"PUT /keep.txt HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Length: %lu\r\n\r\n", (unsigned long)truncated.length])];
    [raw appendData:truncated];

    NSString* reply = SendRawDataRequest(server.port, raw);
    XCTAssertNotNil(reply);
    XCTAssertFalse([reply hasPrefix:@"HTTP/1.1 2"], @"a truncated gzip body must not be accepted: %@", reply);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], original, @"the existing file must be untouched; reply: %@", reply);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

#pragma mark - Crash / DoS hardening

// A COPY/MOVE carrying a Destination header but NO Host header must be rejected with
// 400, not crash the process. The destination parsing did [dst rangeOfString:Host]
// with a nil Host, which throws NSInvalidArgumentException; uncaught, that terminates
// the whole server. The server must survive and keep serving afterwards.
// libxml2 builds a DOM many times the size of an element-dense source, and that DOM is
// outside the request-side memory budget, so a 16 MB PROPFIND body of empty elements
// took the process from 5 MB to 561 MB and still answered 207. Oversized bodies must be
// refused before they are parsed.
- (void)testDAVRefusesOversizedRequestBody {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSMutableString* body = [NSMutableString stringWithString:@"<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop>"];
    while (body.length < (512 * 1024)) {
        [body appendString:@"<a/>"];
    }
    [body appendString:@"</prop></propfind>"];

    NSString* request = [NSString stringWithFormat:@"PROPFIND / HTTP/1.1\r\nHost: localhost\r\nDepth: 0\r\nContent-Type: text/xml\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)body.length, body];
    NSString* reply = SendRawRequest(server.port, request);
    XCTAssertNotNil(reply);
    XCTAssertTrue([reply containsString:@"413"], @"an oversized DAV body must be refused with 413, got: %@", [reply substringToIndex:MIN((NSUInteger)80, reply.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// A COPY whose Destination is inside the source collection made copyItemAtPath: re-enter
// the tree it was still walking, nesting directories until a path exceeded PATH_MAX. The
// request answered 403 while leaving ~250 nested directories the server could no longer
// delete — a refused transaction must leave nothing behind.
- (void)testDAVCopyIntoOwnSubtreeIsRefusedAndLeavesNothingBehind {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* sub = [dir stringByAppendingPathComponent:@"d"];
    XCTAssertTrue([fm createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([[NSMutableData dataWithLength:(2 * 1024 * 1024)] writeToFile:[sub stringByAppendingPathComponent:@"f.bin"] atomically:YES]);

    NSArray* before = [fm subpathsOfDirectoryAtPath:dir error:NULL];

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* reply = SendRawRequest(server.port, @"COPY /d HTTP/1.1\r\nHost: localhost\r\nDestination: /d/sub\r\nOverwrite: T\r\n\r\n");
    XCTAssertNotNil(reply);
    XCTAssertTrue([reply containsString:@"403"], @"copying into its own subtree must be refused: %@", reply);

    // It must be refused as a precondition, before any filesystem work. Previously the
    // only thing that stopped it was copyItemAtPath: nesting directories until a path
    // exceeded PATH_MAX and erroring out (NSCocoaErrorDomain 514) — so the refusal came
    // from ~250 levels of pointless recursion, and whether the cleanup afterwards could
    // still remove that tree depended on how long the share's own path was.
    XCTAssertTrue([reply containsString:@"into its own subtree"], @"must be refused up front, not by the copy failing: %@", reply);

    NSArray* after = [fm subpathsOfDirectoryAtPath:dir error:NULL];
    XCTAssertEqualObjects([NSSet setWithArray:after], [NSSet setWithArray:before], @"the refused COPY left entries behind (%lu vs %lu)", (unsigned long)after.count, (unsigned long)before.count);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

- (void)testDAVMoveWithoutHostHeaderDoesNotCrash {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* path = [dir stringByAppendingPathComponent:@"a.txt"];
    XCTAssertTrue([@"data" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"POST"
                          requestClass:[WSKDataRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionIdleTimeout : @5.0};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Shrink the bound so the property is proven with a few hundred kilobytes rather than
    // by pushing 16 MB through the server. That volume was slow, and under the suite's
    // AddressSanitizer build it was itself enough to lose the whole test runner — which
    // reports as "0 failures" and silently takes the next test with it.
    WSKSetMemoryLimitsForTesting(64 * 1024, 64 * 1024, 1024 * 1024);
    [self addTeardownBlock:^{
        WSKSetMemoryLimitsForTesting(0, 0, 0);
    }];

    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(fd, 0);
    const char* head = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n";
    XCTAssertEqual(send(fd, head, strlen(head), 0), (ssize_t)strlen(head));

    // Stream 'a' bytes (all valid hex, no CRLF) so the chunk-size line can never complete,
    // exceeding the framing bound. Send on a background queue so the main thread can read
    // the server's rejection promptly — a blocking send of the whole payload would deadlock
    // against a server that has stopped reading. A rejecting server produces an HTTP error;
    // a server that buffered without bound would send nothing and the read would time out.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char chunk[16 * 1024];
        memset(chunk, 'a', sizeof(chunk));
        NSUInteger toSend = 4 * (WSKMaxInMemoryBodyLength() + (64 * 1024));

        for (NSUInteger sent = 0; sent < toSend; sent += sizeof(chunk)) {
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
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"hello"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionIdleTimeout : @0.5};
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
    WSKMultiPartFormRequest* shallow = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=top"});
    NSError* error = nil;
    XCTAssertTrue([shallow performWriteData:NestedMultipartMixedBody(@"top", 2) error:&error], @"shallow nesting should parse: %@", error);
    XCTAssertTrue([shallow performClose:&error], @"shallow nesting should finish cleanly: %@", error);

    // Beyond the cap: rejected rather than recursing to the crash depth.
    WSKMultiPartFormRequest* deep = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=top"});
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
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"secret-body"];
                          }];
    NSDictionary* options = @{
        WSKOption_Port : @0,
        WSKOption_BindToLocalhost : @YES,
        WSKOption_AuthenticationMethod : WSKAuthenticationMethod_DigestAccess,
        WSKOption_AuthenticationRealm : @"test",
        WSKOption_AuthenticationAccounts : @{@"user" : @"pass"}
    };
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Anonymous request -> 401 with a Digest challenge; capture the server-issued nonce.
    NSString* challenge = SendRawRequest(server.port, @"GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([challenge containsString:@"401"], @"expected 401 challenge, got: %@", challenge);
    NSString* nonce = QuotedParam(challenge, @"nonce");
    XCTAssertNotNil(nonce, @"no nonce in challenge: %@", challenge);

    // Compute a valid Digest response for GET /secret and authenticate.
    NSString* ha1 = WSKComputeMD5Digest(@"%@:%@:%@", @"user", @"test", @"pass");
    NSString* ha2Secret = WSKComputeMD5Digest(@"%@:%@", @"GET", @"/secret");
    NSString* response = WSKComputeMD5Digest(@"%@:%@:%@", ha1, nonce, ha2Secret);
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

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    server.allowedFileExtensions = @[ @"txt" ];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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

// An SSE stream is only ever released when the client that is reading it goes away. A HEAD
// mapped to GET has no reader at all — the connection layer discards the body unsent — so the
// channel the handler registered was held by nobody and freed only by the heartbeat reaper,
// two ticks (~30s) later. That made sixteen HEADs a complete denial of live updates for every
// real client, and unusually cheap to sustain: each request *completes*, so the sender holds
// no connection slot and can repeat the burst every 30s from anywhere on the network.
// Measured before the fix: 16 HEADs, then a genuine EventSource is refused for 30s.
- (void)testAbortedRequestCarriesItsAddressesAndHEADFlag {
    gAbortRequestPeer = nil;
    gAbortRequestSawVirtualHEAD = NO;

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addHandlerForMethod:@"GET"
                           path:@"/ok"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse*(WSKRequest* request) {
                       return [WSKDataResponse responseWithText:@"ok"];
                   }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionClass : [AbortProbeConnection class]};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // HEAD, so the method has been rewritten to GET before matching; no handler claims
    // "/nope", so this takes the 501 branch that builds its own request.
    NSString* reply = SendRawRequest(server.port, @"HEAD /nope HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 501"], @"expected 501 for an unclaimed path: %@", reply);

    XCTAssertNotNil(gAbortRequestPeer, @"the aborted request carried no peer address");
    XCTAssertTrue([gAbortRequestPeer hasPrefix:@"127.0.0.1"], @"peer address is wrong: %@", gAbortRequestPeer);
    XCTAssertTrue(gAbortRequestSawVirtualHEAD, @"a mapped HEAD must be distinguishable from a real GET on this path");

    [server stop];
}

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

// The uploader's bundle contains index.html, and the base-path handler serves that bundle at
// "/", so "/index.html" returned the raw template — the same UI, with none of the framing
// headers the "/" handler sets. Framing that path instead of "/" therefore defeated the
// clickjacking defence outright, on a UI whose one-click buttons delete and move files.
- (void)testUploaderTemplatePathCannotBypassFramingHeaders {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    NSString* host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port];

    NSString* (^get)(NSString*) = ^(NSString* path) {
        return SendRawRequest(server.port, [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\n\r\n", path, host]);
    };

    for (NSString* path in @[ @"/", @"/index.html" ]) {
        NSString* reply = get(path);
        XCTAssertTrue([reply containsString:@"X-Frame-Options: DENY"], @"\"%@\" is framable: %@", path, reply);
        XCTAssertTrue([reply containsString:@"frame-ancestors 'none'"], @"\"%@\" has no frame-ancestors: %@", path, reply);
        XCTAssertTrue([reply containsString:@"X-Content-Type-Options: nosniff"], @"\"%@\" may be sniffed: %@", path, reply);
    }

    // No spelling may reach the template. Excluding it by path is not enough — the base path
    // handler normalizes, so the last two here still reached the raw file when the fix was an
    // exact-path alias sitting in front of it. The unsubstituted placeholder is what identifies
    // the template, independently of which headers happen to be on the reply.
    for (NSString* path in @[ @"/", @"/index.html", @"/INDEX.HTML", @"/./index.html", @"/x/../index.html" ]) {
        XCTAssertFalse([get(path) containsString:@"%device%"], @"\"%@\" served the raw template", path);
    }

    // ...and the page's own assets must still be served, or this has merely broken the UI.
    // Asked for with HEAD: a font body is not UTF-8, so a GET would come back as a nil string
    // here and read as a failure whether or not the asset was served.
    for (NSString* asset in @[ @"/css/index.css", @"/js/index.js", @"/fonts/glyphicons-halflings-regular.ttf" ]) {
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"HEAD %@ HTTP/1.1\r\nHost: %@\r\n\r\n", asset, host]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 200"], @"asset \"%@\" is no longer served: %@", asset, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }

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

- (void)testUploaderRejectsCrossOriginMutation {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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
// A nil path survived every guard (WSKNormalizePath(nil) is @"", so the
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

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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

// WSKFileResponse must serve only regular files. S_IFREG is a value inside the
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
    WSKFileResponse* ok = [WSKFileResponse responseWithFile:realPath];
    XCTAssertNotNil(ok, @"a regular file must still be servable");
    XCTAssertEqual(ok.contentLength, (NSUInteger)7);

    // A symlink to a file inside the directory must be refused.
    NSString* insideLink = [dir stringByAppendingPathComponent:@"inside.txt"];
    XCTAssertTrue([fm createSymbolicLinkAtPath:insideLink withDestinationPath:realPath error:NULL]);
    XCTAssertNil([WSKFileResponse responseWithFile:insideLink], @"a symlink must not be accepted as a regular file");

    // A symlink escaping the directory must be refused too. Previously this built a
    // response whose Content-Length came from the link rather than its target, and was
    // only stopped later by O_NOFOLLOW failing with ELOOP.
    NSString* outsidePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    XCTAssertTrue([@"secret" writeToFile:outsidePath atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSString* escapingLink = [dir stringByAppendingPathComponent:@"escape.txt"];
    XCTAssertTrue([fm createSymbolicLinkAtPath:escapingLink withDestinationPath:outsidePath error:NULL]);
    XCTAssertNil([WSKFileResponse responseWithFile:escapingLink], @"a symlink out of the served directory must not be accepted");

    // A directory is still refused, as before.
    XCTAssertNil([WSKFileResponse responseWithFile:dir]);

    [fm removeItemAtPath:outsidePath error:NULL];
    [fm removeItemAtPath:dir error:NULL];
}

#pragma mark - Symlink-resolved path containment

// The textual containment checks cannot see symlinks: WSKNormalizePath strips
// ".." before any file is touched, and WSKPathIsInsideDirectory compares path
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
    XCTAssertTrue(WSKResolvedPathIsWithinDirectory(dir, dir));
    XCTAssertTrue(WSKResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"a.txt"], dir));
    XCTAssertTrue(WSKResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Sub"], dir));

    // A destination that does not exist yet resolves through its parent, so uploads and
    // MKCOL keep working.
    XCTAssertTrue(WSKResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"new.txt"], dir));
    XCTAssertTrue(WSKResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Sub/new.txt"], dir));

    // A symlink that stays inside the directory is still usable.
    XCTAssertTrue([fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"Inside"] withDestinationPath:[dir stringByAppendingPathComponent:@"Sub"] error:NULL]);
    XCTAssertTrue(WSKResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Inside/new.txt"], dir));

    // A symlink pointing out of the directory is rejected, both as the leaf and as an
    // intermediate component (the case that string comparison misses entirely).
    XCTAssertTrue([fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"Escape"] withDestinationPath:outside error:NULL]);
    NSString* throughLink = [dir stringByAppendingPathComponent:@"Escape/secret.txt"];
    XCTAssertTrue(WSKPathIsInsideDirectory(throughLink, dir), @"precondition: the textual check does not catch this");
    XCTAssertFalse(WSKResolvedPathIsWithinDirectory(throughLink, dir), @"a path traversing a symlink out of the directory must be rejected");
    XCTAssertFalse(WSKResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Escape"], dir));
    XCTAssertFalse(WSKResolvedPathIsWithinDirectory([outside stringByAppendingPathComponent:@"secret.txt"], dir));

    // Unresolvable input fails closed.
    XCTAssertFalse(WSKResolvedPathIsWithinDirectory(@"", dir));
    XCTAssertFalse(WSKResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Nope/deeper/x.txt"], dir));

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

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"OPTIONS"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"handler-reached"];
                          }];
    NSDictionary* options = @{
        WSKOption_Port : @0,
        WSKOption_BindToLocalhost : @YES,
        WSKOption_AuthenticationMethod : WSKAuthenticationMethod_Basic,
        WSKOption_AuthenticationAccounts : @{@"user" : @"pass"}
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

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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
    WSKMultiPartFormRequest* request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
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
    WSKMultiPartFormRequest* request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});

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
    WSKMultiPartFormRequest* request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    NSMutableData* body = [NSMutableData data];
    [body appendData:SSEData(@"--X\r\nContent-Disposition: form-data; filename=\"a.txt\"\r\n\r\npayload\r\n--X--\r\n")];

    NSError* error = nil;
    XCTAssertFalse([request performWriteData:body error:&error], @"a part with no control name should be rejected");
}

// A request target whose percent-escapes are invalid or not valid UTF-8 cannot be
// decoded. That is the client's error: it must be answered 400 and must never abort.
- (void)testMalformedPercentEncodedPathIsRejectedNotFatal {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"hello"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"POST"
                          requestClass:[WSKDataRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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

    XCTAssertNil([[WSKRequest alloc] initWithMethod:@"POST" url:url headers:headers(@"5abc") path:@"/" query:@{}]);
    XCTAssertNil([[WSKRequest alloc] initWithMethod:@"POST" url:url headers:headers(@"-1") path:@"/" query:@{}]);
    XCTAssertNil([[WSKRequest alloc] initWithMethod:@"POST" url:url headers:headers(@"") path:@"/" query:@{}]);
    XCTAssertNil([[WSKRequest alloc] initWithMethod:@"POST" url:url headers:headers(@"99999999999999999999999") path:@"/" query:@{}]);

    WSKRequest* valid = [[WSKRequest alloc] initWithMethod:@"POST" url:url headers:headers(@"5") path:@"/" query:@{}];
    XCTAssertNotNil(valid);
    XCTAssertEqual(valid.contentLength, (NSUInteger)5);
}

// A header parameter name must match at a token boundary. A plain substring search finds
// "name=" inside "filename=" and "nonce=" inside "cnonce=", so a client could pick which
// value the server read just by reordering the parameters — which broke Digest auth for
// any RFC 2617 client sending cnonce before nonce.
- (void)testHeaderValueParameterMatchesOnlyAtTokenBoundary {
    XCTAssertEqualObjects(WSKExtractHeaderValueParameter(@"form-data; filename=\"EVIL.txt\"; name=\"upload\"", @"name"), @"upload");
    XCTAssertEqualObjects(WSKExtractHeaderValueParameter(@"Digest realm=\"r\", cnonce=\"CLIENT\", nonce=\"REAL\"", @"nonce"), @"REAL");
    XCTAssertEqualObjects(WSKExtractHeaderValueParameter(@"Digest realm=\"r\", nonce=\"N\", myuri=\"/shadow\", uri=\"/real\"", @"uri"), @"/real");
    XCTAssertNil(WSKExtractHeaderValueParameter(@"form-data; filename=\"only.txt\"", @"name"));

    // Ordinary cases must be unaffected.
    XCTAssertEqualObjects(WSKExtractHeaderValueParameter(@"form-data; name=\"upload\"; filename=\"a.txt\"", @"name"), @"upload");
    XCTAssertEqualObjects(WSKExtractHeaderValueParameter(@"form-data; name=\"upload\"; filename=\"a.txt\"", @"filename"), @"a.txt");
    XCTAssertEqualObjects(WSKExtractHeaderValueParameter(@"multipart/form-data; boundary=ABC", @"boundary"), @"ABC");
    XCTAssertEqualObjects(WSKExtractHeaderValueParameter(@"text/plain; charset=utf-8", @"charset"), @"utf-8");
    XCTAssertEqualObjects(WSKExtractHeaderValueParameter(@"form-data; name=upload; filename=a.txt", @"name"), @"upload");

    // RFC 2046 allows "," in a boundary, so an unquoted value must NOT terminate there —
    // truncating "ab,cd" to "ab" makes every upload from such a client fail to parse.
    XCTAssertEqualObjects(WSKExtractHeaderValueParameter(@"multipart/form-data; boundary=ab,cd", @"boundary"), @"ab,cd");
    XCTAssertEqualObjects(WSKExtractHeaderValueParameter(@"multipart/form-data; boundary=ab,cd; charset=utf-8", @"boundary"), @"ab,cd");
}

// The idle timeout's zero-progress rule is defeated by a client that dribbles one byte
// per tick: it always looks like it is "making progress" while pinning a connection slot
// for as long as it likes. While a request body is still arriving the server must demand
// real throughput, not merely non-zero throughput.
- (void)testConnectionIdleTimeoutClosesDribblingBodyClient {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"POST"
                          requestClass:[WSKDataRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionIdleTimeout : @0.5};
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

// RFC 9110 §13.1.3: If-Modified-Since MUST be ignored when If-None-Match is present.
// Evaluating the date first meant a revalidation carrying a *stale* ETag still got a 304
// whenever the replacement's mtime was not strictly newer — and the client then stores the
// old body under the new ETag, so the stale copy is pinned for good.
- (void)testStaleETagIsNotValidatedByAnOlderModificationDate {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* path = [root stringByAppendingPathComponent:@"f.txt"];
    XCTAssertTrue([@"ORIGINAL" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* first = SendRawRequest(server.port, @"GET /f.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([first containsString:@"200"], @"%@", first);

    // Replace the contents and give the file an *older* mtime, the case that made the date
    // comparison validate. The ETag changes because the inode/mtime do.
    XCTAssertTrue([@"REPLACED" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSDate* old = [NSDate dateWithTimeIntervalSince1970:1000000];
    XCTAssertTrue([fm setAttributes:@{NSFileModificationDate : old} ofItemAtPath:path error:NULL]);

    // A revalidation quoting the ETag of the *first* version, plus a recent date.
    NSString* reply = SendRawRequest(server.port, @"GET /f.txt HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: \"1/1/1\"\r\nIf-Modified-Since: Thu, 01 Jan 2099 00:00:00 GMT\r\n\r\n");
    XCTAssertNotNil(reply);
    XCTAssertFalse([reply containsString:@"304"], @"a stale ETag must not be validated by the date: %@", [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    XCTAssertTrue([reply containsString:@"REPLACED"], @"the new contents must be served: %@", reply);

    [server stop];
    [fm removeItemAtPath:root error:NULL];
}

// "Send me this range only if the representation is unchanged". Ignoring If-Range meant a
// resumed download spliced bytes from two versions of a file together under a 206 that
// asserted they belonged to the same one.
// If-Range requires a strong validator. st_mtime has one-second resolution, so a file
// modified within the current second could change again without the timestamp moving — the
// case where a build is rewritten under a client that is downloading it. RFC 9110 8.8.2.2
// lets the origin treat the timestamp as strong only once it is at least a second old.
//
// Both directions are asserted here, because the obvious "just never honour a date" is a real
// compatibility regression: macOS Finder's WebDAV client resumes with a date and nothing else
// (Tests/WebDAV-Finder/059), so refusing outright turns every Finder resume into a full
// re-download.
- (void)testIfRangeDateIsHonouredOnlyWhenTheTimestampIsStrong {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* path = [root stringByAppendingPathComponent:@"build.bin"];

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // (a) Settled file: the timestamp is at least a second old, so it is strong and a resume
    // must still work. This is the Finder case.
    XCTAssertTrue([@"AAAAAAAAAAAAAAAAAAAA" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSDate* settled = [NSDate dateWithTimeIntervalSince1970:1400000000];
    XCTAssertTrue([fm setAttributes:@{NSFileModificationDate : settled} ofItemAtPath:path error:NULL]);
    NSString* settledRequest = [NSString stringWithFormat:@"GET /build.bin HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-4\r\nIf-Range: %@\r\n\r\n", WSKFormatRFC822(settled)];
    XCTAssertTrue([SendRawRequest(server.port, settledRequest) hasPrefix:@"HTTP/1.1 206"], @"a settled timestamp must still allow a resume");

    // (b) Just-written file: the timestamp is inside the current second, so it is weak and a
    // range must NOT be served from it — the file could be rewritten again without the
    // timestamp moving, which splices two builds together under a 206 that claims otherwise.
    // The write and the request have to land in the same wall-clock second for that to be the
    // regime under test, so a run that straddles a second boundary is retried rather than
    // asserted on — otherwise this flakes roughly once in a few hundred runs.
    NSString* fresh = nil;
    for (NSUInteger attempt = 0; attempt < 5; attempt++) {
        time_t const before = time(NULL);
        XCTAssertTrue([@"BBBBBBBBBBBBBBBBBBBB" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        NSDate* justNow = [[fm attributesOfItemAtPath:path error:NULL] fileModificationDate];
        NSString* freshRequest = [NSString stringWithFormat:@"GET /build.bin HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-4\r\nIf-Range: %@\r\n\r\n", WSKFormatRFC822(justNow)];
        fresh = SendRawRequest(server.port, freshRequest);
        if (time(NULL) == before) {
            break;
        }
    }
    XCTAssertTrue([fresh hasPrefix:@"HTTP/1.1 200"], @"a timestamp inside the current second is weak and must not yield a partial response: %@", [fresh substringToIndex:MIN((NSUInteger)40, fresh.length)]);
    XCTAssertTrue([fresh containsString:@"BBBBBBBBBBBBBBBBBBBB"], @"the whole current representation must be served");

    [server stop];
    [fm removeItemAtPath:root error:NULL];
}

// If-Modified-Since answered 304 whenever mtime was equal *or older*. Restoring a previous
// build then pins a date-only client on stale bytes forever: it is told 304, keeps the old
// body, and adopts the current ETag from that 304 — so every later revalidation matches too.
- (void)testStaleDateDoesNotPinAClientOnAnOlderRepresentation {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* path = [root stringByAppendingPathComponent:@"build.bin"];

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:NO];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // The client holds build B, dated later. The server is rolled back to build A, dated earlier.
    NSDate* clientHolds = [NSDate dateWithTimeIntervalSince1970:1500000000];
    XCTAssertTrue([@"ROLLED-BACK-BUILD-A" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm setAttributes:@{NSFileModificationDate : [NSDate dateWithTimeIntervalSince1970:1400000000]} ofItemAtPath:path error:NULL]);

    NSString* stale = [NSString stringWithFormat:@"GET /build.bin HTTP/1.1\r\nHost: localhost\r\nIf-Modified-Since: %@\r\n\r\n", WSKFormatRFC822(clientHolds)];
    NSString* reply = SendRawRequest(server.port, stale);
    XCTAssertFalse([reply containsString:@"304"], @"an older representation must not be reported unchanged: %@", [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    XCTAssertTrue([reply containsString:@"ROLLED-BACK-BUILD-A"], @"the current bytes must be served: %@", reply);

    // A future date must not validate anything either.
    NSString* future = [NSString stringWithFormat:@"GET /build.bin HTTP/1.1\r\nHost: localhost\r\nIf-Modified-Since: %@\r\n\r\n", WSKFormatRFC822([NSDate dateWithTimeIntervalSince1970:4000000000])];
    XCTAssertFalse([SendRawRequest(server.port, future) containsString:@"304"], @"a future If-Modified-Since must not validate");

    // The ordinary unchanged-file revalidation must still work, or this is a cache regression.
    NSString* first = SendRawRequest(server.port, @"GET /build.bin HTTP/1.1\r\nHost: localhost\r\n\r\n");
    NSRange r = [first rangeOfString:@"last-modified: " options:NSCaseInsensitiveSearch];
    XCTAssertNotEqual(r.location, (NSUInteger)NSNotFound, @"%@", first);
    NSString* echoed = [[[first substringFromIndex:(r.location + r.length)] componentsSeparatedByString:@"\r\n"] firstObject];
    NSString* same = [NSString stringWithFormat:@"GET /build.bin HTTP/1.1\r\nHost: localhost\r\nIf-Modified-Since: %@\r\n\r\n", echoed];
    XCTAssertTrue([SendRawRequest(server.port, same) containsString:@"304"], @"echoing back the served Last-Modified must still revalidate");

    [server stop];
    [fm removeItemAtPath:root error:NULL];
}

- (void)testIfRangeMismatchServesTheWholeRepresentation {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* path = [root stringByAppendingPathComponent:@"f.txt"];
    XCTAssertTrue([@"AAAAAAAAAAAAAAAAAAAA" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // A matching If-Range still yields a partial response...
    NSString* full = SendRawRequest(server.port, @"GET /f.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    NSRange etagRange = [full rangeOfString:@"etag: " options:NSCaseInsensitiveSearch];
    XCTAssertNotEqual(etagRange.location, (NSUInteger)NSNotFound, @"no ETag in: %@", full);
    if (etagRange.location == NSNotFound) {
        [server stop];
        return;
    }
    NSString* tail = [full substringFromIndex:(etagRange.location + etagRange.length)];
    NSString* etag = [[tail componentsSeparatedByString:@"\r\n"] firstObject];

    // Assert on the status line, not containsString:@"206" — the ETag embeds the inode, whose
    // digits contain "206" often enough to make that assertion flaky in both directions.
    NSString* matching = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /f.txt HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-4\r\nIf-Range: %@\r\n\r\n", etag]);
    XCTAssertTrue([matching hasPrefix:@"HTTP/1.1 206"], @"a matching If-Range must still serve the range: %@", matching);

    // ...but a stale one must serve the entire representation, not a slice of a file the
    // client has never seen.
    NSString* stale = SendRawRequest(server.port, @"GET /f.txt HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-4\r\nIf-Range: \"0/0/0\"\r\n\r\n");
    XCTAssertNotNil(stale);
    XCTAssertTrue([stale hasPrefix:@"HTTP/1.1 200"], @"a stale If-Range must not produce a partial response: %@", [stale substringToIndex:MIN((NSUInteger)40, stale.length)]);
    XCTAssertTrue([stale containsString:@"AAAAAAAAAAAAAAAAAAAA"], @"the whole representation must be served: %@", stale);

    [server stop];
    [fm removeItemAtPath:root error:NULL];
}

// The "filename*" parameter was percent-encoded with a URL *query* escaper, which leaves
// ";" intact — and ";" ends a header parameter, so "evil.command;ok.txt" reached the
// browser as a filename of "evil.command", bypassing whatever extension allow-list let the
// name through on the way in.
- (void)testAttachmentFilenameEscapesParameterDelimiters {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* name = @"evil.command;ok.txt";
    XCTAssertTrue([@"data" writeToFile:[root stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKFileResponse* response = [WSKFileResponse responseWithFile:[root stringByAppendingPathComponent:name] isAttachment:YES];
    XCTAssertNotNil(response);
    NSString* disposition = [response valueForAdditionalHeader:@"Content-Disposition"];
    XCTAssertNotNil(disposition);

    NSRange extRange = [disposition rangeOfString:@"filename*=UTF-8''"];
    XCTAssertNotEqual(extRange.location, (NSUInteger)NSNotFound, @"%@", disposition);
    NSString* extValue = [disposition substringFromIndex:(extRange.location + extRange.length)];
    XCTAssertFalse([extValue containsString:@";"], @"';' must be percent-encoded in filename*: %@", disposition);
    XCTAssertTrue([extValue containsString:@"%3B"], @"expected a percent-encoded ';': %@", disposition);

    [fm removeItemAtPath:root error:NULL];
}

// Everything else in this suite asserts that one transaction is correct. This asserts that
// ten thousand of them leave nothing behind, which is a different property and the one that
// matters for a server left running for weeks rather than minutes: a descriptor or a memory
// reservation leaked once per request is invisible in a four-minute session and fatal in a
// four-week one. The aggregate budget is the sharpest edge — it is process-wide static state
// with no reset, so a single reservation that never releases permanently disables every
// in-memory endpoint until the process is relaunched.
- (void)testSustainedServingDoesNotAccumulateResources {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    // Big enough to be streamed from disk in several chunks rather than served in one go.
    XCTAssertTrue([[NSMutableData dataWithLength:(4 * 1024 * 1024)] writeToFile:[root stringByAppendingPathComponent:@"build.bin"] atomically:YES]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    [server addDefaultHandlerForMethod:@"POST"
                          requestClass:[WSKDataRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Warm up first: the first requests populate caches and date formatters, so a baseline
    // taken before them would report that one-time setup as a leak.
    for (int i = 0; i < 10; i++) {
        (void)SendRawRequest(server.port, @"GET /build.bin HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-1023\r\n\r\n");
    }

    NSUInteger const baselineFDs = OpenFileDescriptorCount();
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0, @"budget should be idle at the baseline");

    NSString* const body = [@"" stringByPaddingToLength:4096 withString:@"x" startingAtIndex:0];
    NSString* const post = [NSString stringWithFormat:@"POST /submit HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)body.length, body];

    for (int i = 0; i < 150; i++) {
        @autoreleasepool {
            // A ranged read, the shape an interrupted download resumes with.
            NSString* ranged = SendRawRequest(server.port, @"GET /build.bin HTTP/1.1\r\nHost: localhost\r\nRange: bytes=1048576-1049599\r\n\r\n");
            XCTAssertTrue([ranged containsString:@"206"], @"iteration %i: %@", i, [ranged substringToIndex:MIN((NSUInteger)40, ranged.length)]);

            // An in-memory body, which is what takes a reservation from the shared budget.
            NSString* posted = SendRawRequest(server.port, post);
            XCTAssertTrue([posted containsString:@"200"], @"iteration %i: %@", i, [posted substringToIndex:MIN((NSUInteger)40, posted.length)]);

            // A refusal, so the failure paths are exercised too rather than only the happy ones.
            (void)SendRawRequest(server.port, @"GET /nope.bin HTTP/1.1\r\nHost: localhost\r\n\r\n");
        }
    }

    // Connections close asynchronously, so give the last few a moment to unwind before
    // counting; otherwise this measures timing rather than leakage.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];

    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0, @"the shared memory budget did not return to zero after 150 rounds");

    NSUInteger const finalFDs = OpenFileDescriptorCount();
    XCTAssertLessThanOrEqual(finalFDs, baselineFDs + 5, @"descriptors accumulated: %lu at baseline, %lu after 450 requests", (unsigned long)baselineFDs, (unsigned long)finalFDs);

    [server stop];
    [fm removeItemAtPath:root error:NULL];
}

// The NAT-PMP callbacks arrive on the main run loop and used to mutate _dnsService /
// _dnsAddress / _dnsPort with no confinement, racing -_stop's DNSServiceRefDeallocate and
// every -publicServerURL read. They now take _stateQueue, which introduces a dispatch_sync
// from the main thread into the lifecycle queue — so the thing to prove is that repeated
// start/stop cycles still complete rather than deadlocking.
- (void)testNATPortMappingStartStopCyclesDoNotDeadlock {
    for (int i = 0; i < 5; i++) {
        @autoreleasepool {
            WSKWebServer* server = [[WSKWebServer alloc] init];
            [server addDefaultHandlerForMethod:@"GET"
                                  requestClass:[WSKRequest class]
                                  processBlock:^WSKResponse*(WSKRequest* request) {
                                      return [WSKDataResponse responseWithText:@"ok"];
                                  }];
            NSDictionary* options = @{
                WSKOption_Port : @0,
                WSKOption_BindToLocalhost : @YES,
                WSKOption_RequestNATPortMapping : @YES
            };
            XCTAssertTrue([server startWithOptions:options error:NULL], @"cycle %i failed to start", i);

            // Reading publicServerURL takes _stateQueue, the same queue the callbacks now
            // take; doing it while the mapping request is in flight is the interesting case.
            (void)server.publicServerURL;
            XCTAssertTrue([SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"200"]);

            [server stop];
            XCTAssertFalse(server.isRunning, @"cycle %i did not stop", i);
        }
    }
}

// Chunked transfer coding is HTTP/1.1 only. Sending it to a 1.0 client makes it read the
// chunk-size lines as part of the entity body — silent corruption rather than an error.
// Identity framing is safe here because every response carries "Connection: Close" and the
// connection serves one request, so end-of-body by close is well defined.
- (void)testStreamedResponseIsNotChunkedForHTTP10Clients {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              __block int remaining = 3;
                              return [WSKStreamedResponse responseWithContentType:@"text/plain"
                                                                               asyncStreamBlock:^(WSKBodyReaderCompletionBlock completionBlock) {
                                                                                   completionBlock(remaining-- > 0 ? SSEData(@"PIECE|") : [NSData data], nil);
                                                                               }];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* reply10 = SendRawRequest(server.port, @"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(reply10);
    XCTAssertFalse([reply10 containsString:@"Transfer-Encoding"], @"an HTTP/1.0 client must not be sent chunked framing: %@", reply10);
    XCTAssertTrue([reply10 hasSuffix:@"PIECE|PIECE|PIECE|"], @"the body must be the raw bytes with no chunk headers: %@", reply10);

    // An HTTP/1.1 client must still get chunked framing, since there is no Content-Length.
    NSString* reply11 = SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([reply11 containsString:@"Transfer-Encoding: chunked"], @"HTTP/1.1 must still be chunked: %@", reply11);
    XCTAssertTrue([reply11 containsString:@"\r\n0\r\n\r\n"], @"chunked body must be terminated: %@", reply11);

    [server stop];
}

// -addGETHandlerForBasePath: was the one file-serving path with no containment check: it
// only stripped ".." textually, and lstat/O_NOFOLLOW refuse a symlink solely as the *final*
// component. Any symlinked directory under the served root therefore served whatever it
// pointed at.
// -addGETHandlerForBasePath: was the one file-vending path with no hidden-item concept,
// while its own directory listing skips every dot-entry — so the browsable index advertised
// a smaller tree than the one actually served, and an operator checking in a browser would
// never notice. Both subclasses already refuse hidden items.
- (void)testBasePathHandlerRefusesHiddenItems {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    XCTAssertTrue([fm createDirectoryAtPath:[root stringByAppendingPathComponent:@".git"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"url = https://user:TOKEN@example.com/x.git" writeToFile:[root stringByAppendingPathComponent:@".git/config"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"SECRET=1" writeToFile:[root stringByAppendingPathComponent:@".env"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"public" writeToFile:[root stringByAppendingPathComponent:@"build.ipa"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    XCTAssertTrue([SendRawRequest(server.port, @"GET /build.ipa HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"200"], @"ordinary files must still be served");

    // A dotfile at the root, and a file *inside* a dot-directory — the latter is where the
    // interesting secrets live, so the check has to walk every component, not just the leaf.
    NSString* env = SendRawRequest(server.port, @"GET /.env HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([env containsString:@"404"], @"a dotfile must not be served: %@", [env substringToIndex:MIN((NSUInteger)40, env.length)]);
    XCTAssertFalse([env containsString:@"SECRET"], @"the dotfile's contents leaked");

    NSString* git = SendRawRequest(server.port, @"GET /.git/config HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([git containsString:@"404"], @"a file inside a dot-directory must not be served: %@", [git substringToIndex:MIN((NSUInteger)40, git.length)]);
    XCTAssertFalse([git containsString:@"TOKEN"], @"the credential leaked");

    [server stop];
    [fm removeItemAtPath:root error:NULL];
}

// The listing HTML-escapes each entry's link *text* but built the href from percent-encoding
// alone. URLPathAllowedCharacterSet leaves "&" and ";" intact and an HTML parser decodes named
// character references inside attribute values, so "javascript&colon;alert(1)" became a live
// javascript: URL in the server's own origin.
- (void)testDirectoryListingEscapesHrefEntities {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* hostile = @"javascript&colon;alert(1)";
    XCTAssertTrue([@"x" writeToFile:[root stringByAppendingPathComponent:hostile] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:NO];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* listing = SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertNotNil(listing);
    XCTAssertTrue([listing containsString:@"&amp;colon;"], @"href entity not escaped: %@", listing);
    XCTAssertFalse([listing containsString:@"\"javascript&colon;"], @"a raw entity survived into the href attribute: %@", listing);

    [server stop];
    [fm removeItemAtPath:root error:NULL];
}

- (void)testBasePathHandlerRefusesSymlinkEscape {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* outside = MakeTempDirectory();
    XCTAssertTrue([@"PUBLIC" writeToFile:[root stringByAppendingPathComponent:@"app.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"TOP-SECRET" writeToFile:[outside stringByAppendingPathComponent:@"secret.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"linkdir"] withDestinationPath:outside error:NULL]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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
    WSKRequest* (^make)(NSString*) = ^(NSString* transferEncoding) {
        return [[WSKRequest alloc] initWithMethod:@"PUT"
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
    WSKRequest* identity = make(@"identity");
    XCTAssertNotNil(identity);
    XCTAssertFalse(identity.usesChunkedTransferEncoding);
}

// Range halves get the same strict parsing Content-Length received: -integerValue read
// "0x10" as 0 and " 5"/"+5"/"5abc" as 5.
- (void)testByteRangeIsParsedStrictly {
    NSURL* url = [NSURL URLWithString:@"http://localhost/"];
    NSRange (^rangeFor)(NSString*) = ^(NSString* value) {
        return [[[WSKRequest alloc] initWithMethod:@"GET" url:url headers:@{@"Range" : value} path:@"/" query:@{}] byteRange];
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
        XCTAssertFalse(WSKIsValidByteRange(r), @"expected \"%@\" to be rejected, got {%lu,%lu}", bad, (unsigned long)r.location, (unsigned long)r.length);
    }
}

// The MD5 helper hashed via -UTF8String + strlen, so an embedded NUL (which survives from
// the wire into request.headers) ended the hashed input early — for a Digest nonce that
// meant the per-process secret never reached the digest and its tag became forgeable.
- (void)testMD5DigestHashesPastEmbeddedNUL {
    unichar nul = 0;
    NSString* withNUL = [NSString stringWithFormat:@"abc%@def", [NSString stringWithCharacters:&nul length:1]];
    XCTAssertNotEqualObjects(WSKComputeMD5Digest(@"%@", withNUL), WSKComputeMD5Digest(@"%@", @"abc"),
                             @"input must not be truncated at the first NUL");
}

#pragma mark - Aggregate in-memory budget

// Every in-memory limit is per-request, and per-request limits do not compose: with the
// connection cap the real ceiling was their product — gigabytes, far past what a phone
// survives. A process-wide budget bounds the sum, and a reservation returns its bytes when
// it is deallocated so a connection dying mid-body cannot permanently shrink the budget.
- (void)testTotalInMemoryBudgetIsBoundedAndReturned {
    WSKSetMemoryLimitsForTesting(64 * 1024, 64 * 1024, 256 * 1024);
    [self addTeardownBlock:^{
        WSKSetMemoryLimitsForTesting(0, 0, 0);
    }];
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0, @"budget should start empty");

    // The pool matters: the requests are autoreleased, so they are only deallocated — and
    // their reservations only returned — once it drains.
    NSUInteger accepted = 0;

    @autoreleasepool {
        // More concurrent bodies than the total budget can hold at once.
        NSMutableArray<WSKDataRequest*>* requests = [NSMutableArray array];
        NSMutableData* payload = [NSMutableData dataWithLength:(32 * 1024)];

        for (int i = 0; i < 16; i++) {
            WSKDataRequest* request = OpenBodyRequest([WSKDataRequest class], @{});
            [requests addObject:request];
            NSError* error = nil;

            if ([request performWriteData:payload error:&error]) {
                accepted += 1;
            }
        }

        XCTAssertGreaterThan(accepted, (NSUInteger)0, @"the budget refused everything; it is too tight to be usable");
        XCTAssertLessThan(accepted, (NSUInteger)16, @"the budget accepted every body; the aggregate ceiling is not enforced");
        XCTAssertLessThanOrEqual(WSKReservedMemoryLength(), (NSUInteger)(256 * 1024), @"reserved memory exceeded the ceiling");
    }

    // Every holder is gone, so every byte must have come back.
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0, @"reservations leaked after their holders were released");
}

#pragma mark - Host validation (DNS rebinding)

// A page on evil.example that repoints its DNS at this server is, to the browser, genuinely
// same-origin: CORS, Origin comparison and CSRF tokens are all satisfied. The one thing that
// still differs is the name the browser puts in Host, which is why this check exists and why
// nothing else substitutes for it.
- (void)testHostValidationRefusesRebindingButAllowsRealNames {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"served"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
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
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"served"];
                          }];
    NSDictionary* options = @{
        WSKOption_Port : @0,
        WSKOption_BindToLocalhost : @YES,
        WSKOption_AllowedHostNames : @[ @"files.example", @"pinned.example:8080" ]
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

    // A trailing dot is the DNS root label, so "name." is the same host as "name". A user
    // typing a fully-qualified name, a canonicalizing client, or curl all send it, and
    // refusing it presented as the server simply not working.
    // Assert on the status line, not the word "served": the 421 body itself says "is not
    // served here", so containsString:@"served" matches a refusal too — which is exactly
    // how these three first passed against code that had no root-label handling at all.
    XCTAssertTrue([get(@"files.example.") hasPrefix:@"HTTP/1.1 200"], @"a fully-qualified name should be accepted: %@", get(@"files.example."));
    XCTAssertTrue([get(@"localhost.") hasPrefix:@"HTTP/1.1 200"], @"a fully-qualified default should be accepted");
    XCTAssertTrue([get(@"pinned.example.:8080") hasPrefix:@"HTTP/1.1 200"], @"root label plus a pinned port");
    XCTAssertTrue([get(@"other.example.") hasPrefix:@"HTTP/1.1 421"], @"stripping the root label must not accept an unknown name");

    [server stop];
}

// A control character below 0x20 cannot appear in an XML 1.0 document at all — there is no
// escape for it — but a Unix filename may contain one. Emitting it raw produced a document
// we declare as application/xml that no conforming parser accepts, breaking that resource
// for every client.
- (void)testDAVResponseOmitsCharactersIllegalInXML {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* name = [NSString stringWithFormat:@"a%Cb.txt", (unichar)0x01];
    XCTAssertTrue([@"data" writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // LOCK is the case that reaches the wire raw: PROPFIND percent-encodes its href, but
    // <D:lockroot> interpolates the relative path through _XMLEscape only.
    NSString* lockBody = @"<?xml version=\"1.0\" encoding=\"utf-8\"?><D:lockinfo xmlns:D=\"DAV:\"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>";
    // Percent-encoded, because a raw control byte in the request-target is now itself a 400.
    NSString* request = [NSString stringWithFormat:@"LOCK /a%%01b.txt HTTP/1.1\r\nHost: localhost\r\nUser-Agent: WebDAVFS/3.0.0\r\nDepth: 0\r\nContent-Type: text/xml\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)lockBody.length, lockBody];
    NSString* reply = SendRawRequest(server.port, request);
    XCTAssertNotNil(reply);
    XCTAssertTrue([reply containsString:@"200"], @"%@", [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);

    NSRange body = [reply rangeOfString:@"\r\n\r\n"];
    XCTAssertNotEqual(body.location, (NSUInteger)NSNotFound);
    NSString* xml = [reply substringFromIndex:(body.location + body.length)];
    NSString* illegal = [NSString stringWithFormat:@"%C", (unichar)0x01];
    XCTAssertFalse([xml containsString:illegal], @"the emitted XML must not contain a raw 0x01");

    NSXMLParser* parser = [[NSXMLParser alloc] initWithData:[xml dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertTrue([parser parse], @"the emitted document must be well-formed XML: %@", parser.parserError);

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

#pragma mark - gzip response encoding

// A gzip-encoded response body must decompress back to exactly what the handler produced.
- (void)testGZipEncodedDataResponseRoundTrips {
    NSString* text = @"the quick brown fox jumps over the lazy dog";
    WSKDataResponse* response = [WSKDataResponse responseWithText:text];
    response.gzipContentEncodingEnabled = YES;

    NSData* encoded = DrainResponseBody(response);
    XCTAssertNotNil(encoded);
    NSData* decoded = GZipDecompress(encoded);
    XCTAssertNotNil(decoded, @"response body was not a valid gzip stream");
    XCTAssertEqualObjects([[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding], text);
}

// The encoder pulled its source through the synchronous -readData: only, so a response
// that implements just the async reader — every WSKStreamedResponse — silently
// encoded an empty body and never ran its stream block at all.
- (void)testGZipEncodedStreamedResponseRoundTrips {
    NSArray<NSString*>* chunks = @[ @"first-", @"second-", @"third" ];
    __block NSUInteger index = 0;
    WSKStreamedResponse* response =
        [WSKStreamedResponse responseWithContentType:@"text/plain"
                                             asyncStreamBlock:^(WSKBodyReaderCompletionBlock completionBlock) {
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
    WSKStreamedResponse* response =
        [WSKStreamedResponse responseWithContentType:@"text/plain"
                                             asyncStreamBlock:^(WSKBodyReaderCompletionBlock completionBlock) {
                                                 NSData* data = (index < 3) ? SSEData(@"chunk") : [NSData data];
                                                 index += 1;
                                                 completionBlock(data, nil);
                                             }];

    NSData* body = DrainResponseBody(response);
    XCTAssertEqualObjects([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding], @"chunkchunkchunk");
}

@end
