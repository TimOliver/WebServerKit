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

// As SendRawDataRequest, but split into two writes with a pause, so the tail arrives in a
// separate socket read. Used to prove a verdict does not depend on how the client segmented.
static NSString* SendRawDataRequestSplit(NSUInteger port, NSData* request, NSUInteger splitAt) {
    int fd = ConnectToLocalhostPort(port);
    if (fd < 0) {
        return nil;
    }
    send(fd, request.bytes, splitAt, 0);
    usleep(150000);
    send(fd, (const char*)request.bytes + splitAt, request.length - splitAt, 0);
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
// WSKNormalizePath truncates at an embedded NUL, because the filesystem's C-string APIs do and
// the mismatch is otherwise exploitable ("secret.dat\0.png" passes an extension allow-list and
// opens "secret.dat"). But truncating meant the server then honoured a request the client never
// made. Two consequences, both measured: "/list?path=\0" passed every guard on the truncated
// path and built a per-entry dictionary literal from the RAW one, where
// -stringByAppendingPathComponent: returns nil for a NUL-bearing receiver — NSInvalidArgumentException,
// uncaught, process gone, from one unauthenticated GET in Debug and Release alike. And
// "/delete?path=/Keep\0/nonexistent" named nothing that exists, yet deleted "/Keep".
//
// NOTE: against the unfixed source the first half does not fail, it ABORTS the test process,
// which xctest reports as "0 failures". Read the executed count.
// A symlink whose target resolves to the share root turned every destructive endpoint into
// "destroy everything". The "not the root directory" guards are correct, but they are evaluated
// on the path the CLIENT typed; the resolve-once work then substituted the resolved path — which
// is the root — with no re-check. Measured: one unauthenticated request emptied the share through
// DAV DELETE, DAV MOVE and the uploader's /delete alike, each answering 204 or 200.
//
// The lesson generalises past this instance: resolving once and acting on the resolved path is
// right, but every rule stated about the unresolved path has to be restated about the resolved
// one. This is refused centrally, in the resolver, so a destructive site added later cannot
// forget it.
// The NUL guards added for the query and form fields missed the two values that arrive through
// the multipart parser. A NUL in the multipart "filename" reached
// -stringByAppendingPathComponent:, which returns nil for a NUL-bearing receiver, and the nil
// then reached -[NSFileManager moveItemAtPath:toPath:error:] as its destination —
// NSInvalidArgumentException, uncaught, process gone, from one unauthenticated POST /upload.
//
// NOTE: against the unfixed source this aborts the test process rather than failing. Read the
// executed count.
- (void)testMultipartFilenameAndPathRefuseNULRatherThanCrashing {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // The uploader takes its file part under the control name "files[]".
    NSData* (^upload)(NSString*, BOOL, NSString*, BOOL) = ^(NSString* fileName, BOOL nulInName, NSString* pathField, BOOL nulInPath) {
        NSMutableData* body = [NSMutableData data];
        void (^add)(NSString*) = ^(NSString* text) {
            [body appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
        };
        add(@"--B\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n");
        add(pathField);
        if (nulInPath) {
            [body appendBytes:"\0" length:1];
        }
        add(@"\r\n--B\r\nContent-Disposition: form-data; name=\"files[]\"; filename=\"");
        add(fileName);
        if (nulInName) {
            [body appendBytes:"\0" length:1];
        }
        add(@".txt\"\r\nContent-Type: text/plain\r\n\r\nPAYLOAD\r\n--B--\r\n");

        NSString* head = [NSString stringWithFormat:@"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: %lu\r\n\r\n", (unsigned long)body.length];
        NSMutableData* request = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [request appendData:body];
        return (NSData*)request;
    };

    // An ordinary upload must work, or the assertions below prove nothing — this is exactly the
    // trap that made an earlier version of this probe report success against unfixed code.
    XCTAssertTrue([SendRawDataRequest(server.port, upload(@"ok", NO, @"/", NO)) hasPrefix:@"HTTP/1.1 200"], @"an ordinary upload stopped working");

    NSString* badName = SendRawDataRequest(server.port, upload(@"evil", YES, @"/", NO));
    XCTAssertTrue([badName hasPrefix:@"HTTP/1.1 403"], @"a NUL in the multipart filename: %@", [badName substringToIndex:MIN((NSUInteger)40, badName.length)]);

    NSString* badPath = SendRawDataRequest(server.port, upload(@"ok2", NO, @"/sub", YES));
    XCTAssertTrue([badPath hasPrefix:@"HTTP/1.1 400"], @"a NUL in the multipart path field: %@", [badPath substringToIndex:MIN((NSUInteger)40, badPath.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The multipart filename is reduced to a leaf with -lastPathComponent, and "/" is the one input
// for which that does not yield a leaf: it returns "/" unchanged. The name then passes every
// guard (non-empty, no NUL, not "." or "..", no leading dot, and an empty pathExtension is
// allowed when no allow-list is set — the default), and
// -[NSString stringByAppendingPathComponent:@"/"] collapses straight back to the upload
// directory. -_uniquePathForPath: then sees that directory already exists and renames *its own
// leaf* in its PARENT, so the body lands beside the share as "Share (1)". Measured before this:
// 200 OK, repeatable and unbounded. Same class as the eighth pass's symlink write — a file
// landing outside the shared directory — arriving through the filename instead.
- (void)testUploaderRefusesAFileNameThatIsNotASingleComponent {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* parent = MakeTempDirectory();
    NSString* share = [parent stringByAppendingPathComponent:@"Share"];
    XCTAssertTrue([fm createDirectoryAtPath:share withIntermediateDirectories:YES attributes:nil error:NULL]);

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:share];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSData* (^upload)(NSString*) = ^(NSString* fileName) {
        NSString* body = [NSString stringWithFormat:@"--B\r\nContent-Disposition: form-data; name=\"files[]\"; filename=\"%@\"\r\nContent-Type: text/plain\r\n\r\nESCAPED\r\n--B--\r\n", fileName];
        NSString* head = [NSString stringWithFormat:@"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: %lu\r\n\r\n", (unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
        NSMutableData* request = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [request appendData:[body dataUsingEncoding:NSUTF8StringEncoding]];
        return (NSData*)request;
    };

    // An ordinary upload must still work, or the refusals below prove nothing.
    XCTAssertTrue([SendRawDataRequest(server.port, upload(@"ok.txt")) hasPrefix:@"HTTP/1.1 200"], @"an ordinary upload stopped working");
    XCTAssertTrue([fm fileExistsAtPath:[share stringByAppendingPathComponent:@"ok.txt"]], @"the ordinary upload did not land in the share");

    for (NSString* name in @[ @"/", @"//", @"///" ]) {
        NSString* reply = SendRawDataRequest(server.port, upload(name));
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 403"], @"filename \"%@\" should be refused: %@", name, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);

        // The assertion that matters is not the status but that nothing appeared outside the
        // served directory.
        NSMutableArray* strays = [[fm contentsOfDirectoryAtPath:parent error:NULL] mutableCopy];
        [strays removeObject:@"Share"];
        XCTAssertEqual(strays.count, (NSUInteger)0, @"filename \"%@\" wrote outside the share: %@", name, [strays componentsJoinedByString:@", "]);
    }

    [server stop];
    [fm removeItemAtPath:parent error:NULL];
}

// Whether a gzip body with a concatenated second member was accepted or refused depended only on
// how the client split its writes: sent in one write the trailing member was silently dropped and
// the request answered 200, handing the handler less data than was sent; split at the member
// boundary the same bytes answered 500. The client chose which. The fifth pass fixed the
// later-read half and this file recorded the case as closed; the same-read half was still open.
- (void)testGZipTrailingDataIsRefusedRegardlessOfHowItIsSplit {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    __block NSString* received = nil;
    [server addHandlerForMethod:@"POST"
                           path:@"/data"
                   requestClass:[WSKDataRequest class]
                   processBlock:^WSKResponse*(WSKDataRequest* request) {
                       received = [[NSString alloc] initWithData:request.data encoding:NSUTF8StringEncoding];
                       return [WSKDataResponse responseWithText:@"ok"];
                   }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSData* first = GZipCompress([@"AAAAAAAAAAAAAAAA" dataUsingEncoding:NSUTF8StringEncoding]);
    NSData* second = GZipCompress([@"BBBBBBBBBBBBBBBB" dataUsingEncoding:NSUTF8StringEncoding]);
    NSMutableData* twoMembers = [first mutableCopy];
    [twoMembers appendData:second];

    NSData* (^request)(NSData*) = ^(NSData* body) {
        NSString* head = [NSString stringWithFormat:@"POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Type: text/plain\r\nContent-Length: %lu\r\n\r\n", (unsigned long)body.length];
        NSMutableData* full = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [full appendData:body];
        return (NSData*)full;
    };

    // A single well-formed member is the control: it must still be accepted and delivered whole.
    received = nil;
    XCTAssertTrue([SendRawDataRequest(server.port, request(first)) hasPrefix:@"HTTP/1.1 200"], @"a single gzip member stopped being accepted");
    XCTAssertEqualObjects(received, @"AAAAAAAAAAAAAAAA", @"the handler did not receive the whole body");

    // Two members in one write: previously 200 with the second silently dropped.
    received = nil;
    NSString* whole = SendRawDataRequest(server.port, request(twoMembers));
    XCTAssertFalse([whole hasPrefix:@"HTTP/1.1 200"], @"a concatenated second member was accepted and silently dropped: handler got %@", received);

    // And with trailing bytes that are not a member at all.
    NSMutableData* withGarbage = [first mutableCopy];
    [withGarbage appendBytes:"GARBAGE!" length:8];
    received = nil;
    XCTAssertFalse([SendRawDataRequest(server.port, request(withGarbage)) hasPrefix:@"HTTP/1.1 200"], @"trailing garbage after a gzip member was accepted");

    [server stop];
}

// The entity tag was inode + mtime only, so a rewrite in place that restores the timestamp —
// utimes(2), and what rsync -a, cp -p and tar -x all do — produced a byte-identical tag for
// different bytes. Measured: a 900-byte build replaced by a 916-byte one answered 304 to a
// revalidation (the client keeps the stale copy indefinitely) and 206 to a resume (the new
// build's bytes spliced onto the old one's prefix), which is the exact failure the If-Range work
// exists to prevent, arriving through the strong validator rather than the weak one.
- (void)testETagChangesWhenContentChangesUnderAPreservedTimestamp {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* path = [root stringByAppendingPathComponent:@"build.bin"];

    XCTAssertTrue([[@"" stringByPaddingToLength:900 withString:@"A" startingAtIndex:0] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    struct timeval times[2];
    times[0].tv_sec = 1600000000;
    times[0].tv_usec = 123456;
    times[1] = times[0];
    XCTAssertEqual(utimes(path.fileSystemRepresentation, times), 0);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/f/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* (^etagOf)(NSString*) = ^(NSString* reply) {
        for (NSString* line in [reply componentsSeparatedByString:@"\r\n"]) {
            if ([line hasPrefix:@"Etag: "]) {
                return [line substringFromIndex:6];
            }
        }
        return (NSString*)nil;
    };

    NSString* oldETag = etagOf(SendRawRequest(server.port, @"HEAD /f/build.bin HTTP/1.1\r\nHost: localhost\r\n\r\n"));
    XCTAssertNotNil(oldETag);

    // Same inode, different content and length, timestamp restored to the nanosecond.
    XCTAssertTrue([[@"" stringByPaddingToLength:916 withString:@"B" startingAtIndex:0] writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertEqual(utimes(path.fileSystemRepresentation, times), 0);

    NSString* newETag = etagOf(SendRawRequest(server.port, @"HEAD /f/build.bin HTTP/1.1\r\nHost: localhost\r\n\r\n"));
    XCTAssertNotNil(newETag);
    XCTAssertNotEqualObjects(oldETag, newETag, @"the entity tag did not move when the content did");

    NSString* revalidated = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /f/build.bin HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: %@\r\n\r\n", oldETag]);
    XCTAssertFalse([revalidated hasPrefix:@"HTTP/1.1 304"], @"a stale validator was told Not Modified: %@", [revalidated substringToIndex:MIN((NSUInteger)40, revalidated.length)]);

    NSString* resumed = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /f/build.bin HTTP/1.1\r\nHost: localhost\r\nRange: bytes=100-199\r\nIf-Range: %@\r\n\r\n", oldETag]);
    XCTAssertFalse([resumed hasPrefix:@"HTTP/1.1 206"], @"a range was served against a changed representation: %@", [resumed substringToIndex:MIN((NSUInteger)40, resumed.length)]);

    // Revalidating with the CURRENT tag must still produce a cheap 304, or this has simply
    // disabled caching.
    NSString* fresh = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /f/build.bin HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: %@\r\n\r\n", newETag]);
    XCTAssertTrue([fresh hasPrefix:@"HTTP/1.1 304"], @"an up-to-date validator no longer revalidates: %@", [fresh substringToIndex:MIN((NSUInteger)40, fresh.length)]);

    [server stop];
    [fm removeItemAtPath:root error:NULL];
}

- (void)testSymlinkResolvingToTheShareRootCannotDestroyIt {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};

    NSString* (^fixture)(NSString*) = ^(NSString* name) {
        NSString* root = [MakeTempDirectory() stringByAppendingPathComponent:name];
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSUInteger i = 0; i < 4; i++) {
            [[NSString stringWithFormat:@"build %lu", (unsigned long)i] writeToFile:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"build%lu.txt", (unsigned long)i]] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
        symlink(".", [[root stringByAppendingPathComponent:@"self"] fileSystemRepresentation]);
        return root;
    };
    NSUInteger (^count)(NSString*) = ^(NSString* dir) {
        return [[fm contentsOfDirectoryAtPath:dir error:NULL] count];
    };

    NSString* davRoot = fixture(@"dav");
    WSKWebDAVServer* dav = [[WSKWebDAVServer alloc] initWithUploadDirectory:davRoot];
    XCTAssertTrue([dav startWithOptions:options error:NULL]);
    NSString* deleted = SendRawRequest(dav.port, @"DELETE /self HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([deleted hasPrefix:@"HTTP/1.1 403"], @"DELETE through a self-referential link: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);
    XCTAssertEqual(count(davRoot), (NSUInteger)5, @"the share was emptied by a DELETE through a link resolving to its root");

    NSString* moved = SendRawRequest(dav.port, [NSString stringWithFormat:@"MOVE /build0.txt HTTP/1.1\r\nHost: localhost:%lu\r\nDestination: http://localhost:%lu/self\r\nOverwrite: T\r\n\r\n", (unsigned long)dav.port, (unsigned long)dav.port]);
    XCTAssertTrue([moved hasPrefix:@"HTTP/1.1 403"], @"MOVE onto a self-referential link: %@", [moved substringToIndex:MIN((NSUInteger)40, moved.length)]);
    XCTAssertEqual(count(davRoot), (NSUInteger)5, @"the share was replaced by a MOVE onto a link resolving to its root");

    // The ordinary destructive operation must still work, or this has just disabled the feature.
    XCTAssertTrue([SendRawRequest(dav.port, @"DELETE /build1.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 204"], @"an ordinary DELETE stopped working");
    XCTAssertEqual(count(davRoot), (NSUInteger)4);
    [dav stop];

    NSString* upRoot = fixture(@"up");
    WSKWebUploader* uploader = [[WSKWebUploader alloc] initWithUploadDirectory:upRoot];
    XCTAssertTrue([uploader startWithOptions:options error:NULL]);
    NSString* body = @"path=%2Fself";
    NSString* reply = SendRawRequest(uploader.port, [NSString stringWithFormat:@"POST /delete HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)body.length, body]);
    XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 403"], @"the uploader deleted through a self-referential link: %@", [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    XCTAssertEqual(count(upRoot), (NSUInteger)5, @"the share was emptied by /delete through a link resolving to its root");

    // Listing the root by name is still an ordinary operation and must not be caught by this.
    XCTAssertTrue([SendRawRequest(uploader.port, @"GET /list?path=/ HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 200"], @"listing the share root stopped working");
    [uploader stop];
}

// -[WSKMIMEStreamParser initWithBoundary:...] returned nil for malformed input BEFORE running
// [super init] and setting the fd sentinel. Under ARC a nil-returning initializer still
// deallocates its receiver, so -dealloc ran on a zeroed object where _tmpFile is 0 — making its
// close(_tmpFile) a close(0) of a descriptor the parser never owned. Once freed, that slot goes
// to the next accept(), so a later malformed request tears down a live connection mid-serve.
//
// NOTE: against the unfixed source this closes the test process's own stdin. Read the executed
// count, not the failure count.
- (void)testMalformedMultipartBoundaryDoesNotCloseDescriptorZero {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    XCTAssertTrue(fcntl(0, F_GETFD) != -1, @"descriptor 0 should be open before the request");

    NSString* body = @"--x\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--x--\r\n";
    for (NSString* contentType in @[ @"multipart/form-data",
                                     @"multipart/form-data; boundary=",
                                     @"multipart/form-data; boundary=\u00e9\u00e9\u00e9" ]) {
        SendRawRequest(server.port, [NSString stringWithFormat:@"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: %@\r\nContent-Length: %lu\r\n\r\n%@", contentType, (unsigned long)body.length, body]);
        XCTAssertTrue(fcntl(0, F_GETFD) != -1, @"\"%@\" closed descriptor 0", contentType);
    }

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The eighth pass closed this in the uploader and the record said the class was closed. It was
// not: WebDAV had no NUL guard at all, and the base-path handler served through one. All three
// servers must agree, because a client that gets a different answer per server is exactly how
// this class survived four sweeps.
- (void)testAllServersRefusePathsContainingNUL {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* victim = [root stringByAppendingPathComponent:@"Victim"];
    XCTAssertTrue([fm createDirectoryAtPath:victim withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"precious" writeToFile:[victim stringByAppendingPathComponent:@"data.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"SECRETBUILD" writeToFile:[root stringByAppendingPathComponent:@"build.ipa"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};

    // WebDAV: a destructive request must never be honoured against the truncated prefix.
    WSKWebDAVServer* dav = [[WSKWebDAVServer alloc] initWithUploadDirectory:root];
    XCTAssertTrue([dav startWithOptions:options error:NULL]);
    NSString* deleted = SendRawRequest(dav.port, @"DELETE /Victim%00/does-not-exist HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertFalse([deleted hasPrefix:@"HTTP/1.1 204"], @"a NUL-bearing DELETE was honoured: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);
    XCTAssertTrue([fm fileExistsAtPath:victim], @"WebDAV destroyed the truncated prefix instead of refusing");

    NSString* put = SendRawRequest(dav.port, @"PUT /new%00.exe HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\ndata");
    XCTAssertFalse([put hasPrefix:@"HTTP/1.1 201"], @"a NUL-bearing PUT created a file: %@", [put substringToIndex:MIN((NSUInteger)40, put.length)]);
    XCTAssertFalse([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"new"]], @"WebDAV wrote to the truncated prefix");

    // ...and the ordinary requests must be untouched by all of this.
    XCTAssertTrue([SendRawRequest(dav.port, @"GET /build.ipa HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"SECRETBUILD"], @"an ordinary WebDAV GET stopped working");
    XCTAssertTrue([SendRawRequest(dav.port, @"PROPFIND / HTTP/1.1\r\nHost: localhost\r\nDepth: 1\r\nContent-Length: 0\r\n\r\n") hasPrefix:@"HTTP/1.1 207"], @"PROPFIND stopped working");
    [dav stop];

    // The base-path handler: read-only, but serving "build.ipa\0.txt" is the extension confusion
    // the truncation exists to prevent.
    WSKWebServer* basePath = [[WSKWebServer alloc] init];
    [basePath addGETHandlerForBasePath:@"/f/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    XCTAssertTrue([basePath startWithOptions:options error:NULL]);
    XCTAssertFalse([SendRawRequest(basePath.port, @"GET /f/build.ipa%00.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"SECRETBUILD"], @"the base-path handler served a file through a NUL");
    XCTAssertTrue([SendRawRequest(basePath.port, @"GET /f/build.ipa HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"SECRETBUILD"], @"an ordinary base-path GET stopped working");
    [basePath stop];

    [fm removeItemAtPath:root error:NULL];
}

// A well-formed single-member gzip body whose inflated length exactly fills the decoder's buffer
// (256 KiB * 2^k) was refused with 500 whenever the 8-byte trailer arrived in a later read: at
// exact fill avail_out is 0, so the loop grew the buffer and called inflate() again with no input
// left, which returns Z_BUF_ERROR. Reachable by any chunked streaming client using those block
// sizes. The ninth pass's own commit claimed the gzip verdict no longer depends on segmentation;
// for valid bodies at these sizes it still did.
- (void)testValidGZipBodyIsAcceptedWhateverItsInflatedSize {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    __block NSUInteger receivedLength = 0;
    [server addHandlerForMethod:@"POST"
                           path:@"/data"
                   requestClass:[WSKDataRequest class]
                   processBlock:^WSKResponse*(WSKDataRequest* request) {
                       receivedLength = request.data.length;
                       return [WSKDataResponse responseWithText:@"ok"];
                   }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Either side of the initial buffer size, and two doublings past it.
    for (NSNumber* size in @[ @261120, @262144, @263168, @524288, @1048576 ]) {
        NSUInteger const length = size.unsignedIntegerValue;
        NSMutableData* payload = [NSMutableData dataWithLength:length];
        memset(payload.mutableBytes, 'Z', length);
        NSData* body = GZipCompress(payload);

        NSString* head = [NSString stringWithFormat:@"POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Type: application/octet-stream\r\nContent-Length: %lu\r\n\r\n", (unsigned long)body.length];
        NSMutableData* whole = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [whole appendData:body];

        receivedLength = 0;
        XCTAssertTrue([SendRawDataRequest(server.port, whole) hasPrefix:@"HTTP/1.1 200"], @"a valid %lu-byte body was refused when sent whole", (unsigned long)length);
        XCTAssertEqual(receivedLength, length, @"the handler received the wrong length for a %lu-byte body", (unsigned long)length);

        // The same bytes with the trailer in a later read must give the same answer — that
        // invariance is the whole point, and it has to hold for VALID bodies too.
        receivedLength = 0;
        NSString* split = SendRawDataRequestSplit(server.port, whole, whole.length - 4);
        XCTAssertTrue([split hasPrefix:@"HTTP/1.1 200"], @"a valid %lu-byte body was refused when its trailer arrived in a later read: %@", (unsigned long)length, [split substringToIndex:MIN((NSUInteger)40, split.length)]);
        XCTAssertEqual(receivedLength, length, @"the split send delivered the wrong length for %lu bytes", (unsigned long)length);
    }

    [server stop];
}

- (void)testUploaderRefusesPathsContainingNULRatherThanTruncating {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* keep = [dir stringByAppendingPathComponent:@"Keep"];
    XCTAssertTrue([fm createDirectoryAtPath:keep withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"precious" writeToFile:[keep stringByAppendingPathComponent:@"data.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    NSString* host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port];

    // The listing endpoint, which is where the nil reached the dictionary literal.
    for (NSString* encoded in @[ @"%00", @"/Keep%00", @"%00/Keep", @"/%00" ]) {
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /list?path=%@ HTTP/1.1\r\nHost: %@\r\n\r\n", encoded, host]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 400"], @"\"%@\" should be refused: %@", encoded, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }

    // A destructive request must never be honoured against a truncated prefix.
    NSString* body = @"path=%2FKeep%00%2Fnonexistent";
    NSString* deleted = SendRawRequest(server.port, [NSString stringWithFormat:@"POST /delete HTTP/1.1\r\nHost: %@\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n\r\n%@", host, (unsigned long)body.length, body]);
    XCTAssertTrue([deleted hasPrefix:@"HTTP/1.1 400"], @"a NUL-bearing delete should be refused: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);
    XCTAssertTrue([fm fileExistsAtPath:keep], @"the truncated prefix was deleted instead of the path the client sent");

    // And the ordinary paths must be untouched by all of this.
    XCTAssertTrue([SendRawRequest(server.port, [NSString stringWithFormat:@"GET /list?path=/ HTTP/1.1\r\nHost: %@\r\n\r\n", host]) hasPrefix:@"HTTP/1.1 200"], @"an ordinary listing stopped working");
    XCTAssertTrue([SendRawRequest(server.port, [NSString stringWithFormat:@"GET /list?path=/Keep HTTP/1.1\r\nHost: %@\r\n\r\n", host]) containsString:@"data.txt"], @"listing a subdirectory stopped working");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The uploader vets a subtree before destroying it; WebDAV did not, so a folder was a spelling
// that bypassed the allow-list entirely. Measured: with allowedFileExtensions=[txt],
// DELETE /Folder answered 204 and destroyed both "id_rsa" and ".env" — each of which the same
// server refuses with 403 when addressed directly.
- (void)testDAVRecursiveDeleteRespectsExtensionAllowList {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    server.allowedFileExtensions = @[ @"txt" ];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* guarded = [dir stringByAppendingPathComponent:@"Guarded"];
    XCTAssertTrue([fm createDirectoryAtPath:guarded withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"ok" writeToFile:[guarded stringByAppendingPathComponent:@"note.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"KEYDATA" writeToFile:[guarded stringByAppendingPathComponent:@"id_rsa"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    // The same file, addressed directly, is refused — so the recursive form must be too, or one
    // request means two different things.
    XCTAssertTrue([SendRawRequest(server.port, @"DELETE /Guarded/id_rsa HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 403"], @"a direct delete of a disallowed file should be refused");

    NSString* refused = SendRawRequest(server.port, @"DELETE /Guarded HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([refused hasPrefix:@"HTTP/1.1 403"], @"expected 403 for a collection holding a disallowed file: %@", [refused substringToIndex:MIN((NSUInteger)40, refused.length)]);
    XCTAssertTrue([fm fileExistsAtPath:[guarded stringByAppendingPathComponent:@"id_rsa"]], @"the recursive delete destroyed a file a direct delete refuses");

    // A folder whose only extra entry is filesystem noise must still be deletable, or every
    // macOS folder becomes permanently undeletable by its own .DS_Store.
    NSString* ordinary = [dir stringByAppendingPathComponent:@"Ordinary"];
    XCTAssertTrue([fm createDirectoryAtPath:ordinary withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"ok" writeToFile:[ordinary stringByAppendingPathComponent:@"note.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"junk" writeToFile:[ordinary stringByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSString* allowed = SendRawRequest(server.port, @"DELETE /Ordinary HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertFalse([allowed hasPrefix:@"HTTP/1.1 403"], @"a .DS_Store must not make an ordinary folder undeletable: %@", [allowed substringToIndex:MIN((NSUInteger)40, allowed.length)]);
    XCTAssertFalse([fm fileExistsAtPath:ordinary], @"the deletable folder was not removed: %@", allowed);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The eighth pass closed the recursive DELETE and this file's design priorities then claimed the
// whole property — "a recursive delete refuses when it would destroy a file a direct delete would
// have refused". MOVE and COPY destroy just as much through Overwrite, and their two extension
// checks are both gated behind !srcIsDirectory, so a directory source skipped them entirely and
// nothing vetted the destination being replaced. Measured before this, with
// allowedFileExtensions=[txt] and 5/5 reproductions: MOVE and COPY of a directory over "Dst"
// (holding id_rsa) and over "secret.pem" all answered 204 and destroyed the target — each of
// which this same server refuses with 403 when addressed directly.
//
// The uploader needs no equivalent: -moveItem: routes around a collision with
// -_uniquePathForPath: and never overwrites, so it has no destructive-overwrite path at all.
- (void)testDAVOverwriteRespectsExtensionAllowList {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    server.allowedFileExtensions = @[ @"txt" ];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* (^overwrite)(NSString*, NSString*, NSString*) = ^(NSString* method, NSString* source, NSString* destination) {
        return SendRawRequest(server.port, [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: localhost\r\nDestination: %@\r\nOverwrite: T\r\n\r\n", method, source, destination]);
    };

    NSString* source = [dir stringByAppendingPathComponent:@"Src"];
    NSString* guarded = [dir stringByAppendingPathComponent:@"Dst"];
    NSString* key = [guarded stringByAppendingPathComponent:@"id_rsa"];
    NSString* secret = [dir stringByAppendingPathComponent:@"secret.pem"];

    void (^rebuild)(void) = ^{
        [fm removeItemAtPath:source error:NULL];
        [fm removeItemAtPath:guarded error:NULL];
        [fm removeItemAtPath:secret error:NULL];
        XCTAssertTrue([fm createDirectoryAtPath:source withIntermediateDirectories:YES attributes:nil error:NULL]);
        XCTAssertTrue([@"payload" writeToFile:[source stringByAppendingPathComponent:@"ok.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        XCTAssertTrue([fm createDirectoryAtPath:guarded withIntermediateDirectories:YES attributes:nil error:NULL]);
        XCTAssertTrue([@"KEYDATA" writeToFile:key atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        XCTAssertTrue([@"KEYDATA" writeToFile:secret atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    };

    // The controls: both targets are refused when addressed directly, so the overwrite forms must
    // be refused too, or one request means two different things.
    rebuild();
    XCTAssertTrue([SendRawRequest(server.port, @"DELETE /secret.pem HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 403"], @"a direct delete of a disallowed file should be refused");
    XCTAssertTrue([SendRawRequest(server.port, @"DELETE /Dst HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 403"], @"a recursive delete of a collection holding a disallowed file should be refused");

    for (NSString* method in @[ @"MOVE", @"COPY" ]) {
        rebuild();
        NSString* ontoCollection = overwrite(method, @"/Src", @"/Dst");
        XCTAssertTrue([ontoCollection hasPrefix:@"HTTP/1.1 403"], @"%@ over a collection holding a disallowed file should be refused: %@", method, [ontoCollection substringToIndex:MIN((NSUInteger)40, ontoCollection.length)]);
        XCTAssertEqualObjects([NSString stringWithContentsOfFile:key encoding:NSUTF8StringEncoding error:NULL], @"KEYDATA", @"%@ destroyed a file a direct delete refuses", method);

        rebuild();
        NSString* ontoFile = overwrite(method, @"/Src", @"/secret.pem");
        XCTAssertTrue([ontoFile hasPrefix:@"HTTP/1.1 403"], @"%@ over a disallowed file should be refused: %@", method, [ontoFile substringToIndex:MIN((NSUInteger)40, ontoFile.length)]);
        // The path survives a rename-over as a *directory*, so assert the type as well as the
        // bytes — merely existing does not mean the file is still there.
        BOOL secretIsDirectory = NO;
        XCTAssertTrue([fm fileExistsAtPath:secret isDirectory:&secretIsDirectory] && !secretIsDirectory, @"%@ replaced a disallowed file with a directory", method);
        XCTAssertEqualObjects([NSString stringWithContentsOfFile:secret encoding:NSUTF8StringEncoding error:NULL], @"KEYDATA", @"%@ destroyed a file a direct delete refuses", method);
    }

    // The same hole with the checks the other way round: a *file* source does run the
    // destination-name check, but a destination *collection* named "Backup.txt" passes it — and
    // the collection being destroyed holds a file the allow-list refuses.
    for (NSString* method in @[ @"MOVE", @"COPY" ]) {
        rebuild();
        NSString* backup = [dir stringByAppendingPathComponent:@"Backup.txt"];
        XCTAssertTrue([fm createDirectoryAtPath:backup withIntermediateDirectories:YES attributes:nil error:NULL]);
        XCTAssertTrue([@"KEYDATA" writeToFile:[backup stringByAppendingPathComponent:@"id_rsa"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

        NSString* ontoNamedCollection = overwrite(method, @"/Src/ok.txt", @"/Backup.txt");
        XCTAssertTrue([ontoNamedCollection hasPrefix:@"HTTP/1.1 403"], @"%@ over a collection whose name passes the allow-list should be refused: %@", method, [ontoNamedCollection substringToIndex:MIN((NSUInteger)40, ontoNamedCollection.length)]);
        XCTAssertEqualObjects([NSString stringWithContentsOfFile:[backup stringByAppendingPathComponent:@"id_rsa"] encoding:NSUTF8StringEncoding error:NULL], @"KEYDATA", @"%@ destroyed a file a direct delete refuses", method);
        [fm removeItemAtPath:backup error:NULL];
    }

    // What must keep working. Moving a collection to a fresh name overwrites nothing, and a
    // destination whose only extra entry is filesystem noise stays replaceable — the same two
    // judgement calls the recursive DELETE makes, for the same reasons.
    rebuild();
    NSString* renamed = overwrite(@"MOVE", @"/Src", @"/Fresh");
    XCTAssertTrue([renamed hasPrefix:@"HTTP/1.1 201"], @"moving a collection to an unused name stopped working: %@", [renamed substringToIndex:MIN((NSUInteger)40, renamed.length)]);
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Fresh/ok.txt"]], @"the moved collection did not arrive");
    [fm removeItemAtPath:[dir stringByAppendingPathComponent:@"Fresh"] error:NULL];

    rebuild();
    XCTAssertTrue([@"junk" writeToFile:[guarded stringByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm removeItemAtPath:key error:NULL]);
    NSString* ordinary = overwrite(@"MOVE", @"/Src", @"/Dst");
    XCTAssertFalse([ordinary hasPrefix:@"HTTP/1.1 403"], @"a .DS_Store must not make an ordinary folder unreplaceable: %@", [ordinary substringToIndex:MIN((NSUInteger)40, ordinary.length)]);
    XCTAssertTrue([fm fileExistsAtPath:[guarded stringByAppendingPathComponent:@"ok.txt"]], @"the permitted overwrite did not happen: %@", ordinary);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// CFURLCopyPath() treats '#' as a fragment delimiter and returns only the prefix, and every verb was
// then honoured against that prefix. '#' is a legal filename character and "MyApp#42.ipa" is an
// ordinary CI build-number convention, so this needs no malice: three builds published that way
// collapsed into ONE file under 201/204/204, and a GET naming build 42 answered 200 with build 43's
// bytes. Same class as the NUL truncation the eighth pass refused rather than honoured.
//
// Guarded in two places, because HTTP stacks sanitize a request line but never a header value —
// curl strips '#' from the target and passes it through in Destination untouched. With only the
// request-target guard, a COPY still destroyed a collection through Destination.
- (void)testFragmentInRequestTargetIsRefusedRatherThanTruncated {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* collection = [dir stringByAppendingPathComponent:@"Builds"];
    void (^rebuild)(void) = ^{
        [fm removeItemAtPath:collection error:NULL];
        XCTAssertTrue([fm createDirectoryAtPath:collection withIntermediateDirectories:YES attributes:nil error:NULL]);
        XCTAssertTrue([@"BUILD" writeToFile:[collection stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        XCTAssertTrue([@"SRC" writeToFile:[dir stringByAppendingPathComponent:@"src.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    };

    // A fragment in the request-target must be refused, not silently dropped.
    rebuild();
    NSString* deleted = SendRawRequest(server.port, @"DELETE /Builds/#nonexistent HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([deleted hasPrefix:@"HTTP/1.1 400"], @"a '#' in the request-target should be refused: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);
    XCTAssertTrue([fm fileExistsAtPath:collection], @"the request destroyed a collection the client never named");

    rebuild();
    NSString* put = SendRawRequest(server.port, @"PUT /src.txt#new.ipa HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9\r\n\r\nCLOBBERED");
    XCTAssertTrue([put hasPrefix:@"HTTP/1.1 400"], @"a '#' in a PUT target should be refused: %@", [put substringToIndex:MIN((NSUInteger)40, put.length)]);
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"src.txt"] encoding:NSUTF8StringEncoding error:NULL], @"SRC", @"the PUT overwrote a different file than the one named");

    // The same defect through the Destination header, which no HTTP stack sanitizes.
    rebuild();
    NSString* copied = SendRawRequest(server.port, @"COPY /src.txt HTTP/1.1\r\nHost: localhost\r\nDestination: http://localhost/Builds#nonexistent.txt\r\nOverwrite: T\r\n\r\n");
    XCTAssertTrue([copied hasPrefix:@"HTTP/1.1 400"], @"a '#' in Destination should be refused: %@", [copied substringToIndex:MIN((NSUInteger)40, copied.length)]);
    XCTAssertTrue([fm fileExistsAtPath:[collection stringByAppendingPathComponent:@"a.txt"]], @"the COPY replaced a collection named only by a discarded fragment");

    // What must keep working: %23 is how a '#'-bearing filename is legitimately addressed, and a
    // naive fix breaks exactly this.
    rebuild();
    NSString* encoded = SendRawRequest(server.port, @"PUT /MyApp%2342.ipa HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nBUILD");
    XCTAssertTrue([encoded hasPrefix:@"HTTP/1.1 201"], @"%%23 must still address a '#'-bearing name: %@", [encoded substringToIndex:MIN((NSUInteger)40, encoded.length)]);
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"MyApp#42.ipa"]], @"the percent-encoded name did not land on disk");
    XCTAssertTrue([SendRawRequest(server.port, @"GET /MyApp%2342.ipa HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"BUILD"], @"a '#'-bearing file could not be read back");
    XCTAssertTrue([SendRawRequest(server.port, @"GET /src.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 200"], @"an ordinary GET stopped working");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// Two regressions from the twelfth pass's own fixes, both in the default configuration.
//
// The removability walk required W_OK on every directory in the subtree, but unlink(2) and rmdir(2)
// need write permission on the PARENT, not on the item — so an EMPTY directory is removable whatever
// its own mode says. `chmod 555` on one therefore made its whole ancestry permanently undeletable,
// and both unzip and `ditto -x -k` preserve 0555, so it arrives through ordinary archive extraction.
//
// And `If-Match: *` was keyed on the entity tag, which is only minted for a regular file, so it
// always failed for a collection: a conditional DELETE/MOVE/COPY of a folder could never succeed.
- (void)testTwelfthPassFixesDoNotOverRefuse {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // An extracted archive leaving a read-only EMPTY directory behind.
    NSString* build = [dir stringByAppendingPathComponent:@"Build"];
    NSString* empty = [build stringByAppendingPathComponent:@"Empty"];
    XCTAssertTrue([fm createDirectoryAtPath:empty withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"data" writeToFile:[build stringByAppendingPathComponent:@"f.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertEqual(chmod(empty.fileSystemRepresentation, 0555), 0, @"could not make the directory read-only");

    NSString* deleted = SendRawRequest(server.port, @"DELETE /Build HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([deleted hasPrefix:@"HTTP/1.1 204"], @"a read-only EMPTY directory must not make its parent undeletable: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);
    XCTAssertFalse([fm fileExistsAtPath:build], @"the tree was not removed");

    // A read-only NON-empty directory genuinely cannot be emptied, so it must still be refused.
    NSString* guarded = [dir stringByAppendingPathComponent:@"Guarded"];
    NSString* inner = [guarded stringByAppendingPathComponent:@"Inner"];
    XCTAssertTrue([fm createDirectoryAtPath:inner withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"data" writeToFile:[inner stringByAppendingPathComponent:@"stuck.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertEqual(chmod(inner.fileSystemRepresentation, 0555), 0);

    NSString* refused = SendRawRequest(server.port, @"DELETE /Guarded HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([refused hasPrefix:@"HTTP/1.1 403"], @"a genuinely unremovable tree must still be refused: %@", [refused substringToIndex:MIN((NSUInteger)40, refused.length)]);
    XCTAssertTrue([fm fileExistsAtPath:[inner stringByAppendingPathComponent:@"stuck.txt"]], @"the refused delete still destroyed part of the tree");
    chmod(inner.fileSystemRepresentation, 0755);

    // If-Match: * must succeed against a collection, which has no entity tag.
    NSString* coll = [dir stringByAppendingPathComponent:@"Coll"];
    XCTAssertTrue([fm createDirectoryAtPath:coll withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSString* conditional = SendRawRequest(server.port, @"DELETE /Coll HTTP/1.1\r\nHost: localhost\r\nIf-Match: *\r\n\r\n");
    XCTAssertTrue([conditional hasPrefix:@"HTTP/1.1 204"], @"If-Match: * should succeed against an existing collection: %@", [conditional substringToIndex:MIN((NSUInteger)40, conditional.length)]);
    XCTAssertFalse([fm fileExistsAtPath:coll], @"the conditional delete did not happen");

    // And must still fail against something that does not exist.
    NSString* absent = SendRawRequest(server.port, @"DELETE /Nope HTTP/1.1\r\nHost: localhost\r\nIf-Match: *\r\n\r\n");
    XCTAssertFalse([absent hasPrefix:@"HTTP/1.1 2"], @"If-Match: * should not succeed against an absent resource: %@", [absent substringToIndex:MIN((NSUInteger)40, absent.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The date form of the lost-update guarantee. If-Match was fixed in the tenth pass;
// If-Unmodified-Since was not parsed ANYWHERE in the tree, so a client that explicitly said
// "only if it has not changed since <date the file is newer than>" had its resource destroyed and
// was told the method succeeded.
- (void)testDAVIfUnmodifiedSinceIsEnforcedBeforeTheWrite {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* target = [dir stringByAppendingPathComponent:@"f.txt"];
    NSString* stale = @"If-Unmodified-Since: Thu, 01 Jan 1970 00:00:00 GMT\r\n";
    void (^rebuild)(void) = ^{
        XCTAssertTrue([@"ORIGINAL" writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    };
    NSString* (^contents)(void) = ^{
        return [NSString stringWithContentsOfFile:target encoding:NSUTF8StringEncoding error:NULL];
    };

    rebuild();
    NSString* put = SendRawRequest(server.port, [NSString stringWithFormat:@"PUT /f.txt HTTP/1.1\r\nHost: localhost\r\n%@Content-Length: 3\r\n\r\nNEW", stale]);
    XCTAssertTrue([put hasPrefix:@"HTTP/1.1 412"], @"a stale If-Unmodified-Since should refuse a PUT: %@", [put substringToIndex:MIN((NSUInteger)40, put.length)]);
    XCTAssertEqualObjects(contents(), @"ORIGINAL", @"the PUT happened despite a failed If-Unmodified-Since");

    rebuild();
    NSString* deleted = SendRawRequest(server.port, [NSString stringWithFormat:@"DELETE /f.txt HTTP/1.1\r\nHost: localhost\r\n%@\r\n", stale]);
    XCTAssertTrue([deleted hasPrefix:@"HTTP/1.1 412"], @"a stale If-Unmodified-Since should refuse a DELETE: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);
    XCTAssertTrue([fm fileExistsAtPath:target], @"the DELETE happened despite a failed If-Unmodified-Since");

    rebuild();
    NSString* moved = SendRawRequest(server.port, [NSString stringWithFormat:@"MOVE /f.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /moved.txt\r\n%@\r\n", stale]);
    XCTAssertTrue([moved hasPrefix:@"HTTP/1.1 412"], @"a stale If-Unmodified-Since should refuse a MOVE: %@", [moved substringToIndex:MIN((NSUInteger)40, moved.length)]);
    XCTAssertTrue([fm fileExistsAtPath:target], @"the MOVE happened despite a failed If-Unmodified-Since");

    // What must keep working: a date the file is NOT newer than, and no precondition at all.
    rebuild();
    NSString* future = @"If-Unmodified-Since: Sat, 01 Jan 2050 00:00:00 GMT\r\n";
    NSString* allowed = SendRawRequest(server.port, [NSString stringWithFormat:@"PUT /f.txt HTTP/1.1\r\nHost: localhost\r\n%@Content-Length: 3\r\n\r\nNEW", future]);
    XCTAssertTrue([allowed hasPrefix:@"HTTP/1.1 204"], @"a satisfied If-Unmodified-Since should be honoured: %@", [allowed substringToIndex:MIN((NSUInteger)40, allowed.length)]);
    XCTAssertEqualObjects(contents(), @"NEW", @"a satisfied If-Unmodified-Since did not write");

    rebuild();
    XCTAssertTrue([SendRawRequest(server.port, @"PUT /plain.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nNEW") hasPrefix:@"HTTP/1.1 201"], @"a PUT with no precondition stopped working");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// A recursive removal stops at the first member it cannot unlink and keeps everything it already
// destroyed, reporting only a failure — so a collection holding one locked file (chflags uchg,
// which is what Finder's "Locked" checkbox sets) answered 500 with most of its contents gone. On
// the overwrite surface it was worse: a failed MOVE that also gutted the destination.
- (void)testDestructiveVerbsRefuseATreeTheyCannotFullyRemove {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* dav = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([dav startWithOptions:options error:NULL]);
    WSKWebUploader* uploader = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    XCTAssertTrue([uploader startWithOptions:options error:NULL]);

    NSString* folder = [dir stringByAppendingPathComponent:@"Folder"];
    NSString* locked = [folder stringByAppendingPathComponent:@"locked.txt"];
    NSUInteger (^countFiles)(void) = ^{
        return (NSUInteger)[[fm subpathsOfDirectoryAtPath:folder error:NULL] count];
    };
    void (^rebuild)(void) = ^{
        chflags(locked.fileSystemRepresentation, 0);
        [fm removeItemAtPath:folder error:NULL];
        XCTAssertTrue([fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL]);
        for (NSUInteger i = 0; i < 4; i++) {
            NSString* name = [NSString stringWithFormat:@"f%lu.txt", (unsigned long)i];
            NSString* member = [folder stringByAppendingPathComponent:name];
            XCTAssertTrue([@"data" writeToFile:member atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        }
        XCTAssertTrue([@"data" writeToFile:locked atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        XCTAssertEqual(chflags(locked.fileSystemRepresentation, UF_IMMUTABLE), 0, @"could not lock the member");
    };

    rebuild();
    NSUInteger const before = countFiles();
    XCTAssertEqual(before, (NSUInteger)5);

    NSString* davReply = SendRawRequest(dav.port, @"DELETE /Folder HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([davReply hasPrefix:@"HTTP/1.1 403"], @"DAV DELETE of a partly-removable tree should refuse: %@", [davReply substringToIndex:MIN((NSUInteger)40, davReply.length)]);
    XCTAssertEqual(countFiles(), before, @"DAV DELETE destroyed part of a tree it could not fully remove");

    rebuild();
    NSString* uploaderHost = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)uploader.port];
    NSString* body = @"path=/Folder";
    NSString* uploaderReply = SendRawRequest(uploader.port, [NSString stringWithFormat:@"POST /delete HTTP/1.1\r\nHost: %@\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n\r\n%@", uploaderHost, (unsigned long)body.length, body]);
    XCTAssertTrue([uploaderReply containsString:@"403"], @"uploader /delete of a partly-removable tree should refuse: %@", uploaderReply);
    XCTAssertEqual(countFiles(), before, @"uploader /delete destroyed part of a tree it could not fully remove");

    rebuild();
    XCTAssertTrue([@"src" writeToFile:[dir stringByAppendingPathComponent:@"src.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSString* overwrite = SendRawRequest(dav.port, @"MOVE /src.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /Folder\r\nOverwrite: T\r\n\r\n");
    XCTAssertTrue([overwrite hasPrefix:@"HTTP/1.1 403"], @"an overwrite of a partly-removable destination should refuse: %@", [overwrite substringToIndex:MIN((NSUInteger)40, overwrite.length)]);
    XCTAssertEqual(countFiles(), before, @"the overwrite gutted a destination it could not fully remove");
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"src.txt"]], @"the source vanished too");

    // A fully removable tree must still be removable, or this is just an over-refusal.
    rebuild();
    XCTAssertEqual(chflags(locked.fileSystemRepresentation, 0), 0);
    NSString* ok = SendRawRequest(dav.port, @"DELETE /Folder HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([ok hasPrefix:@"HTTP/1.1 204"], @"an ordinary recursive delete stopped working: %@", [ok substringToIndex:MIN((NSUInteger)40, ok.length)]);
    XCTAssertFalse([fm fileExistsAtPath:folder], @"the deletable folder was not removed");

    [dav stop];
    [uploader stop];
    chflags(locked.fileSystemRepresentation, 0);
    [fm removeItemAtPath:dir error:NULL];
}

// WSKFileResponse withholds Last-Modified while mtime is still inside its own timestamp bucket, so
// no client is ever handed a date that cannot identify one representation. PROPFIND applied no such
// test and published exactly that date — and it emits no getetag, so the unsealed date was the ONLY
// validator a PROPFIND-driven client could obtain. A later If-Range resume with it spliced two
// builds under one 206.
- (void)testDAVPropfindWithholdsAnUnsealedLastModified {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* propfind = @"PROPFIND /fresh.txt HTTP/1.1\r\nHost: localhost\r\nDepth: 0\r\n\r\n";

    // Written and asked for in the same instant: the GET path would withhold the date here, so
    // PROPFIND must too, or the two surfaces disagree about what may be issued.
    XCTAssertTrue([@"BUILD-A" writeToFile:[dir stringByAppendingPathComponent:@"fresh.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSString* unsealed = SendRawRequest(server.port, propfind);
    XCTAssertTrue([unsealed hasPrefix:@"HTTP/1.1 207"], @"PROPFIND stopped working: %@", [unsealed substringToIndex:MIN((NSUInteger)40, unsealed.length)]);
    XCTAssertFalse([unsealed containsString:@"getlastmodified"], @"PROPFIND published a Last-Modified the GET path withholds");
    // The rest of the property set must be unaffected.
    XCTAssertTrue([unsealed containsString:@"getcontentlength"], @"PROPFIND dropped more than the date");

    // Once the bucket has closed the date must be published again, or this is a permanent
    // regression rather than a one-second delay. Two seconds, because FAT's bucket is two.
    [NSThread sleepForTimeInterval:2.2];
    NSString* sealed = SendRawRequest(server.port, propfind);
    XCTAssertTrue([sealed containsString:@"getlastmodified"], @"PROPFIND never publishes a Last-Modified at all: %@", sealed);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// CLAUDE.md's design priorities say "Puck rewrites builds while they may be downloading —
// WSKFileResponse opening once and deriving everything from fstat on that descriptor is what keeps
// an in-flight download consistent". That is true for a REPLACEMENT and false for a rewrite in
// place: rename(2) gives the new content a new inode and the held descriptor keeps reading the old
// bytes, but cp(1) and `cat >` open the destination O_TRUNC and write through the SAME inode, so
// the descriptor starts yielding the new build's bytes mid-body. Measured before this: one 200 OK,
// one ETag naming the old build, a Content-Length that matched exactly, and a body that was half
// one build and half another — undetectable by any client.
//
// The byte at offset i is (i & 0x7f) | (rep ? 0x80 : 0), so the low seven bits pin the absolute
// offset and the top bit names which representation each byte came from.
- (void)testFileResponseRefusesToSpliceAFileRewrittenInPlace {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* path = [dir stringByAppendingPathComponent:@"build.bin"];
    const NSUInteger kSize = 48 * 1024 * 1024;  // Must exceed the socket buffer, or the whole body is sent before the client can stall

    NSMutableData* (^representation)(BOOL) = ^(BOOL second) {
        NSMutableData* d = [NSMutableData dataWithLength:kSize];
        uint8_t* b = d.mutableBytes;
        for (NSUInteger i = 0; i < kSize; i++) {
            b[i] = (uint8_t)((i & 0x7f) | (second ? 0x80 : 0x00));
        }
        return d;
    };

    XCTAssertTrue([representation(NO) writeToFile:path atomically:YES]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/f/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    int socket = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(socket, 0);
    NSString* request = @"GET /f/build.bin HTTP/1.1\r\nHost: localhost\r\n\r\n";
    XCTAssertGreaterThan(write(socket, request.UTF8String, strlen(request.UTF8String)), 0);

    // Drain a little, then stall — an ordinary slow client — and rewrite the file IN PLACE,
    // keeping the inode, exactly as cp(1) does.
    NSMutableData* received = [NSMutableData data];
    uint8_t buffer[64 * 1024];
    while (received.length < 128 * 1024) {
        ssize_t n = read(socket, buffer, sizeof(buffer));
        if (n <= 0) {
            break;
        }
        [received appendBytes:buffer length:(NSUInteger)n];
    }
    XCTAssertGreaterThan(received.length, (NSUInteger)0, @"the server sent nothing at all");

    usleep(300 * 1000);  // Let the server park with the body unfinished.

    int rewrite = open(path.fileSystemRepresentation, O_WRONLY | O_TRUNC);
    XCTAssertGreaterThanOrEqual(rewrite, 0, @"could not reopen the file for an in-place rewrite");
    NSData* second = representation(YES);
    XCTAssertEqual(write(rewrite, second.bytes, second.length), (ssize_t)second.length);
    close(rewrite);

    ssize_t n;
    while ((n = read(socket, buffer, sizeof(buffer))) > 0) {
        [received appendBytes:buffer length:(NSUInteger)n];
    }
    close(socket);

    // Find the body and check every byte came from ONE representation.
    NSData* marker = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange headerEnd = [received rangeOfData:marker options:0 range:NSMakeRange(0, received.length)];
    XCTAssertNotEqual(headerEnd.location, (NSUInteger)NSNotFound, @"no header terminator in the reply");

    const uint8_t* body = (const uint8_t*)received.bytes + NSMaxRange(headerEnd);
    NSUInteger bodyLength = received.length - NSMaxRange(headerEnd);
    NSUInteger spliced = 0;
    for (NSUInteger i = 0; i < bodyLength; i++) {
        if ((body[i] & 0x80) != 0) {
            spliced++;
        }
    }

    // Either the whole body is the representation that was promised, or the response was cut
    // short — both are honest. What must never happen is delivering the new build's bytes under
    // the old build's ETag and Content-Length.
    XCTAssertEqual(spliced, (NSUInteger)0, @"%lu of %lu body bytes came from the replacement representation — two builds were spliced into one response", (unsigned long)spliced, (unsigned long)bodyLength);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// performCOPY: derived its staging path only when the destination already existed, so when the
// destination looked absent `writePath` WAS the destination — and the cleanup written for "a
// failed tree copy leaves a partial tree behind" then recursively removed whatever occupied that
// name by the time the copy failed, i.e. an item this request never created.
//
// The deterministic form: -fileExistsAtPath: FOLLOWS symlinks, so a dangling link at the
// destination reads as absent while -copyItemAtPath: (which lstats) refuses because the name is
// taken. The cleanup then unlinked the client's link and the request answered 403 — a refusal
// that mutates the tree, which the design priorities forbid outright.
- (void)testDAVCopyOntoADanglingSymlinkRefusesWithoutRemovingIt {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    XCTAssertTrue([@"PAYLOAD" writeToFile:[dir stringByAppendingPathComponent:@"src.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSString* link = [dir stringByAppendingPathComponent:@"latest"];
    XCTAssertTrue([fm createSymbolicLinkAtPath:link withDestinationPath:@"builds/current" error:NULL], @"could not create the dangling link");

    NSString* reply = SendRawRequest(server.port, @"COPY /src.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /latest\r\n\r\n");
    XCTAssertFalse([reply hasPrefix:@"HTTP/1.1 2"], @"a COPY onto an occupied name should refuse: %@", [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);

    // The assertion that matters: the refusal left the tree exactly as it was. -fileExistsAtPath:
    // follows the link and would report NO for a link that is still there, so ask lstat.
    struct stat info;
    XCTAssertEqual(lstat(link.fileSystemRepresentation, &info), 0, @"the refused COPY unlinked a pre-existing symlink it was never asked to remove");

    // A COPY onto a genuinely free name must still work, or the assertion above is satisfied by a
    // server that refuses everything.
    NSString* ok = SendRawRequest(server.port, @"COPY /src.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /copy.txt\r\n\r\n");
    XCTAssertTrue([ok hasPrefix:@"HTTP/1.1 201"], @"an ordinary COPY stopped working: %@", [ok substringToIndex:MIN((NSUInteger)40, ok.length)]);
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"copy.txt"] encoding:NSUTF8StringEncoding error:NULL], @"PAYLOAD");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The racing form of the same defect: a COPY whose destination is created by someone else between
// the existence check and the copy destroyed the newcomer and answered 403, while the creating
// client was told 201. Measured before the fix at 209 of 483 collections destroyed.
//
// This asserts a SAFETY property — nothing that was created is ever destroyed — so a machine too
// slow to produce the interleaving yields a false negative, never a false failure. That matters
// because two wall-clock-sensitive tests in this suite already fail under parallel load.
- (void)testDAVCopyRacingACreationNeverDestroysTheWinner {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    XCTAssertTrue([@"PAYLOAD" writeToFile:[dir stringByAppendingPathComponent:@"src.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSUInteger port = server.port;
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    NSUInteger destroyed = 0;
    NSUInteger created = 0;

    for (NSUInteger round = 0; round < 60; round++) {
        NSString* name = [NSString stringWithFormat:@"Target-%lu", (unsigned long)round];
        __block NSString* copyReply = nil;
        __block NSString* mkcolReply = nil;

        dispatch_group_t group = dispatch_group_create();
        dispatch_group_async(group, queue, ^{
            copyReply = SendRawRequest(port, [NSString stringWithFormat:@"COPY /src.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /%@\r\n\r\n", name]);
        });
        dispatch_group_async(group, queue, ^{
            mkcolReply = SendRawRequest(port, [NSString stringWithFormat:@"MKCOL /%@ HTTP/1.1\r\nHost: localhost\r\n\r\n", name]);
        });
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

        // Whichever of the two was told it succeeded must still be there afterwards. Only the
        // MKCOL is checked, because a 201 from it names a collection nobody asked to remove.
        if ([mkcolReply hasPrefix:@"HTTP/1.1 201"]) {
            created++;
            if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:name]]) {
                destroyed++;
            }
        }
    }

    XCTAssertGreaterThan(created, (NSUInteger)0, @"no MKCOL ever succeeded — the probe proved nothing");
    XCTAssertEqual(destroyed, (NSUInteger)0, @"%lu of %lu collections created with 201 were destroyed by a racing COPY", (unsigned long)destroyed, (unsigned long)created);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// +responseWithJSONObject: is declared `nullable`, and -initWithJSONObject:contentType: even had a
// `data == nil` guard for the failure — but +[NSJSONSerialization dataWithJSONObject:] RAISES
// NSInvalidArgumentException for an object that is not JSON-serialisable rather than returning
// nil, so the guard was dead code and the exception escaped. There is no @try/@catch anywhere in
// Sources/, so a host-app handler doing the obvious `return [WSKDataResponse responseWithJSONObject:
// dict]` with an NSDate in the dictionary terminated the process — Debug and Release alike, and
// `resp ?: fallback` did not save it because the raise happens first.
//
// NOTE: against the unfixed source this does not fail, it TERMINATES the test process. Read the
// executed count.
- (void)testJSONResponseRefusesAnInvalidObjectInsteadOfRaising {
    // The shapes a host app actually hits: dates and URLs out of a model object, a NAN from a
    // division, a non-string key, and raw bytes.
    NSArray* invalid = @[
        @{@"created" : [NSDate date]},
        @{@"url" : [NSURL URLWithString:@"http://example.com"]},
        @{@"n" : @(NAN)},
        @{@"n" : @(INFINITY)},
        @{@42 : @"v"},
        @{@"data" : [NSData data]},
        @{@"nested" : @{@"when" : [NSDate date]}},
    ];

    for (id object in invalid) {
        XCTAssertNil([WSKDataResponse responseWithJSONObject:object], @"an unserialisable object must return nil, not raise: %@", object);
    }

    // What must keep working, or the assertions above are satisfied by a method that always fails.
    WSKDataResponse* valid = [WSKDataResponse responseWithJSONObject:@{@"a" : @1, @"b" : @[ @"x" ]}];
    XCTAssertNotNil(valid, @"a valid JSON object stopped working");
    XCTAssertEqualObjects(valid.contentType, @"application/json");

    WSKDataResponse* custom = [WSKDataResponse responseWithJSONObject:@[ @1, @2 ] contentType:@"application/vnd.x+json"];
    XCTAssertNotNil(custom, @"a valid top-level array stopped working");
    XCTAssertEqualObjects(custom.contentType, @"application/vnd.x+json");
}

// Preconditions were evaluated in exactly one place, -overrideResponse:forRequest:, which runs
// AFTER the handler has produced its response — so for a write the file was already on disk. It
// also compares against response.eTag, which a 201/204 does not carry, so _CompareResources
// returned NO and no 412 was ever produced. If-Match was not parsed anywhere in the tree at all.
// RFC 9110 §13.1.1 requires the origin NOT to perform the method when If-Match evaluates false;
// the lost-update protection a WebDAV client believes it has therefore did not exist, and two
// clients editing one file each silently overwrote the other.
//
// Enforced for every DAV verb that destroys or replaces the resource it addresses — PUT, DELETE,
// MOVE and COPY — rather than only for PUT where it was found, because "closed at one of the
// sites the rule applies to" is this codebase's most reliable defect shape.
- (void)testDAVPreconditionsAreEnforcedBeforeTheWrite {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* target = [dir stringByAppendingPathComponent:@"f.txt"];
    XCTAssertTrue([@"ORIGINAL" writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    // The tag the client legitimately holds, taken from the server's own GET.
    NSString* get = SendRawRequest(server.port, @"GET /f.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    // CFHTTPMessage normalizes the field name, so it goes out as "Etag" — match it the way the
    // wire defines it, case-insensitively, rather than the way the source spells it.
    NSRange tagStart = [get rangeOfString:@"Etag: " options:NSCaseInsensitiveSearch];
    XCTAssertNotEqual(tagStart.location, (NSUInteger)NSNotFound, @"the server did not send an ETag: %@", get);
    NSString* rest = [get substringFromIndex:NSMaxRange(tagStart)];
    NSString* eTag = [rest substringToIndex:[rest rangeOfString:@"\r\n"].location];
    XCTAssertTrue(eTag.length > 2, @"unexpected ETag %@", eTag);

    NSString* (^put)(NSString*, NSString*) = ^(NSString* name, NSString* precondition) {
        NSString* body = @"REPLACEMENT";
        NSString* head = [NSString stringWithFormat:@"PUT /%@ HTTP/1.1\r\nHost: localhost\r\n%@Content-Length: %lu\r\n\r\n%@", name, precondition, (unsigned long)body.length, body];
        return SendRawRequest(server.port, head);
    };
    NSString* (^contents)(void) = ^{
        return [NSString stringWithContentsOfFile:target encoding:NSUTF8StringEncoding error:NULL];
    };

    // A stale If-Match must refuse and must not write.
    NSString* stale = put(@"f.txt", @"If-Match: \"0/0/0/0\"\r\n");
    XCTAssertTrue([stale hasPrefix:@"HTTP/1.1 412"], @"a stale If-Match should be refused: %@", [stale substringToIndex:MIN((NSUInteger)40, stale.length)]);
    XCTAssertEqualObjects(contents(), @"ORIGINAL", @"the write happened despite a failed If-Match");

    // If-None-Match: * means "only if it does not exist".
    NSString* exists = put(@"f.txt", @"If-None-Match: *\r\n");
    XCTAssertTrue([exists hasPrefix:@"HTTP/1.1 412"], @"If-None-Match: * against an existing resource should be refused: %@", [exists substringToIndex:MIN((NSUInteger)40, exists.length)]);
    XCTAssertEqualObjects(contents(), @"ORIGINAL", @"the write happened despite If-None-Match: *");

    // DELETE, MOVE and COPY carry the same guarantee.
    NSString* deleted = SendRawRequest(server.port, @"DELETE /f.txt HTTP/1.1\r\nHost: localhost\r\nIf-Match: \"0/0/0/0\"\r\n\r\n");
    XCTAssertTrue([deleted hasPrefix:@"HTTP/1.1 412"], @"a stale If-Match should refuse a DELETE: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);
    XCTAssertTrue([fm fileExistsAtPath:target], @"the delete happened despite a failed If-Match");

    NSString* moved = SendRawRequest(server.port, @"MOVE /f.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /moved.txt\r\nIf-Match: \"0/0/0/0\"\r\n\r\n");
    XCTAssertTrue([moved hasPrefix:@"HTTP/1.1 412"], @"a stale If-Match should refuse a MOVE: %@", [moved substringToIndex:MIN((NSUInteger)40, moved.length)]);
    XCTAssertTrue([fm fileExistsAtPath:target], @"the move happened despite a failed If-Match");

    // What must keep working: the matching tag, and the absence of any precondition at all.
    NSString* matching = put(@"f.txt", [NSString stringWithFormat:@"If-Match: %@\r\n", eTag]);
    XCTAssertTrue([matching hasPrefix:@"HTTP/1.1 204"], @"a matching If-Match should be honoured: %@", [matching substringToIndex:MIN((NSUInteger)40, matching.length)]);
    XCTAssertEqualObjects(contents(), @"REPLACEMENT", @"a matching If-Match did not write");

    XCTAssertTrue([put(@"fresh.txt", @"If-None-Match: *\r\n") hasPrefix:@"HTTP/1.1 201"], @"If-None-Match: * should allow creating a new resource");
    XCTAssertTrue([put(@"plain.txt", @"") hasPrefix:@"HTTP/1.1 201"], @"a PUT with no precondition stopped working");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// -prepareForWriting installed the gzip decoder for the exact token "gzip" and had no else
// branch, so every OTHER content coding left the raw sink in place and the still-ENCODED octets
// were stored as the entity — with a success status. The file on disk is then not what the
// client sent and nothing says so, which is the half-succeed outcome the design priorities call
// the worst one. This project already applies the opposite rule one screen up, in
// _ParseTransferEncoding: "storing the still-encoded bytes as if they were the body is worse
// than refusing."
//
// "x-gzip" must be ACCEPTED and decoded rather than refused: RFC 9110 §8.4.1 makes it equivalent
// to "gzip", so refusing it would swap a silent-corruption bug for an interop one.
- (void)testUnsupportedContentEncodingIsRefusedRatherThanStored {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSData* const plain = [@"THE-REAL-PAYLOAD" dataUsingEncoding:NSUTF8StringEncoding];
    NSData* const gzipped = GZipCompress(plain);
    XCTAssertNotNil(gzipped);

    NSString* (^put)(NSString*, NSString*, NSData*) = ^(NSString* name, NSString* encoding, NSData* body) {
        NSString* head = [NSString stringWithFormat:@"PUT /%@ HTTP/1.1\r\nHost: localhost\r\n%@Content-Length: %lu\r\n\r\n", name, encoding.length ? [NSString stringWithFormat:@"Content-Encoding: %@\r\n", encoding] : @"", (unsigned long)body.length];
        NSMutableData* request = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [request appendData:body];
        return SendRawDataRequest(server.port, request);
    };
    NSData* (^stored)(NSString*) = ^(NSString* name) {
        return [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
    };

    // The codings that ARE supported must keep working, or the refusals below prove nothing.
    XCTAssertTrue([put(@"plain.txt", nil, plain) hasPrefix:@"HTTP/1.1 201"], @"an unencoded PUT stopped working");
    XCTAssertEqualObjects(stored(@"plain.txt"), plain, @"an unencoded PUT stored the wrong bytes");

    XCTAssertTrue([put(@"gz.txt", @"gzip", gzipped) hasPrefix:@"HTTP/1.1 201"], @"a gzip PUT stopped working");
    XCTAssertEqualObjects(stored(@"gz.txt"), plain, @"a gzip PUT did not decode");

    XCTAssertTrue([put(@"xgz.txt", @"x-gzip", gzipped) hasPrefix:@"HTTP/1.1 201"], @"x-gzip is a synonym for gzip and must be accepted");
    XCTAssertEqualObjects(stored(@"xgz.txt"), plain, @"x-gzip was not decoded");

    // Anything we cannot decode must be refused, and must leave nothing behind.
    for (NSString* coding in @[ @"deflate", @"br", @"gzip, gzip", @"bogus" ]) {
        NSString* reply = put(@"bad.txt", coding, plain);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 415"], @"Content-Encoding: %@ should be refused: %@", coding, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
        XCTAssertFalse([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"bad.txt"]], @"Content-Encoding: %@ stored the encoded octets as the entity", coding);
    }

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// "Overwrite" was compared with -isEqualToString:@"F", so only that exact byte meant "do not
// overwrite" and EVERY other spelling was taken as permission to destroy the destination —
// including "f", which RFC 4918 §10.6 makes a conformant spelling (its ABNF is RFC 2616 §2.1,
// where quoted literals are case-insensitive). Measured before this: "F" gave 412 and preserved
// the file, while "f", "False", "no", "0" and an empty value all gave 204 and clobbered it. A
// client that explicitly said "do not overwrite" lost its data and was told it succeeded.
//
// The Depth comparison two methods up has the identical shape but fails CLOSED (an unrecognised
// spelling refuses the request), so it is an interop nuisance rather than data loss; it is
// case-folded here too, in the same edit, because leaving one of a matched pair is how the next
// pass finds it.
- (void)testDAVOverwriteAndDepthAreCaseInsensitive {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* destination = [dir stringByAppendingPathComponent:@"dst.txt"];
    void (^rebuild)(void) = ^{
        XCTAssertTrue([@"SOURCE" writeToFile:[dir stringByAppendingPathComponent:@"src.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        XCTAssertTrue([@"ORIGINAL" writeToFile:destination atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    };

    // Both spellings of "do not overwrite" must refuse and leave the destination alone.
    for (NSString* no in @[ @"F", @"f" ]) {
        rebuild();
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"COPY /src.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /dst.txt\r\nOverwrite: %@\r\n\r\n", no]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 412"], @"Overwrite: %@ should refuse: %@", no, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
        XCTAssertEqualObjects([NSString stringWithContentsOfFile:destination encoding:NSUTF8StringEncoding error:NULL], @"ORIGINAL", @"Overwrite: %@ clobbered the destination", no);
    }

    // Both spellings of "overwrite" must still work, or this becomes an over-refusal.
    for (NSString* yes in @[ @"T", @"t" ]) {
        rebuild();
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"MOVE /src.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /dst.txt\r\nOverwrite: %@\r\n\r\n", yes]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 204"], @"Overwrite: %@ should replace: %@", yes, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
        XCTAssertEqualObjects([NSString stringWithContentsOfFile:destination encoding:NSUTF8StringEncoding error:NULL], @"SOURCE", @"Overwrite: %@ did not replace the destination", yes);
    }

    // Depth: the RFC's own spelling with a capital I must be accepted, not refused.
    rebuild();
    XCTAssertTrue([fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"Coll"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSString* deleted = SendRawRequest(server.port, @"DELETE /Coll HTTP/1.1\r\nHost: localhost\r\nDepth: Infinity\r\n\r\n");
    XCTAssertTrue([deleted hasPrefix:@"HTTP/1.1 204"], @"Depth: Infinity should be accepted: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The browsable index has to describe the tree that is actually being vended. With
// allowHiddenItems:YES the handler served a dot-file while the listing omitted it — the same
// disagreement the sixth pass fixed in the opposite direction, when the listing hid items the
// handler would happily serve.
- (void)testDirectoryIndexAgreesWithWhatIsServed {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    XCTAssertTrue([fm createDirectoryAtPath:[root stringByAppendingPathComponent:@".hidden"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"HIDDENDATA" writeToFile:[root stringByAppendingPathComponent:@".hidden/secret.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"PUBLIC" writeToFile:[root stringByAppendingPathComponent:@"plain.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};

    WSKWebServer* refusing = [[WSKWebServer alloc] init];
    [refusing addGETHandlerForBasePath:@"/f/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:NO];
    XCTAssertTrue([refusing startWithOptions:options error:NULL]);
    XCTAssertFalse([SendRawRequest(refusing.port, @"GET /f/ HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@".hidden"], @"the default listing must not advertise a hidden item");
    XCTAssertFalse([SendRawRequest(refusing.port, @"GET /f/.hidden/secret.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"HIDDENDATA"], @"the default handler must not serve a hidden item");
    XCTAssertTrue([SendRawRequest(refusing.port, @"GET /f/ HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"plain.txt"], @"ordinary entries must still be listed");
    [refusing stop];

    WSKWebServer* permissive = [[WSKWebServer alloc] init];
    [permissive addGETHandlerForBasePath:@"/f/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:NO allowHiddenItems:YES];
    XCTAssertTrue([permissive startWithOptions:options error:NULL]);
    XCTAssertTrue([SendRawRequest(permissive.port, @"GET /f/.hidden/secret.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"HIDDENDATA"], @"allowHiddenItems:YES must serve a hidden item");
    XCTAssertTrue([SendRawRequest(permissive.port, @"GET /f/ HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@".hidden"], @"the listing must advertise what the handler will serve");
    [permissive stop];

    [fm removeItemAtPath:root error:NULL];
}

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

// Hiddenness and containment are independent rules, and the hidden-item walk saw only the path
// the client typed. A symlink named "pub" pointing at ".git" makes "/pub/config" carry no dot,
// while containment passes because the target is inside the served root — so both rules were
// satisfied by a path whose bytes live inside a dot-directory. Read through the base-path
// handler, read AND enumerated through the uploader, and written through DAV PUT, which refuses
// the same write spelled "/.git/hooks/x".
- (void)testHiddenItemsAreRefusedThroughSymlinksToo {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    XCTAssertTrue([fm createDirectoryAtPath:[root stringByAppendingPathComponent:@".git/hooks"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"data/sub"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"SECRETGITCONFIG" writeToFile:[root stringByAppendingPathComponent:@".git/config"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"PUBLICOK" writeToFile:[root stringByAppendingPathComponent:@"data/normal.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"NESTEDOK" writeToFile:[root stringByAppendingPathComponent:@"data/sub/deep.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    // The hostile link, a chain of them, and a benign one that must keep working.
    XCTAssertTrue([fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"pub"] withDestinationPath:@".git" error:NULL]);
    XCTAssertTrue([fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"hop"] withDestinationPath:@"pub" error:NULL]);
    XCTAssertTrue([fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"latest"] withDestinationPath:@"data/sub" error:NULL]);

    WSKWebServer* basePath = [[WSKWebServer alloc] init];
    [basePath addGETHandlerForBasePath:@"/files/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([basePath startWithOptions:options error:NULL]);

    for (NSString* path in @[ @"/files/pub/config", @"/files/hop/config", @"/files/.git/config" ]) {
        NSString* reply = SendRawRequest(basePath.port, [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: localhost\r\n\r\n", path]);
        XCTAssertFalse([reply containsString:@"SECRETGITCONFIG"], @"\"%@\" served a file inside a dot-directory", path);
    }
    // Neither over-refusal: an ordinary file, and a benign symlink staying inside the root.
    XCTAssertTrue([SendRawRequest(basePath.port, @"GET /files/data/normal.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"PUBLICOK"], @"an ordinary file stopped being served");
    XCTAssertTrue([SendRawRequest(basePath.port, @"GET /files/latest/deep.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"NESTEDOK"], @"a benign in-root symlink stopped being served");
    [basePath stop];

    // The opt-out has to actually opt in, or it is not an escape hatch.
    WSKWebServer* permissive = [[WSKWebServer alloc] init];
    [permissive addGETHandlerForBasePath:@"/files/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES allowHiddenItems:YES];
    XCTAssertTrue([permissive startWithOptions:options error:NULL]);
    XCTAssertTrue([SendRawRequest(permissive.port, @"GET /files/pub/config HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"SECRETGITCONFIG"], @"allowHiddenItems:YES did not permit a hidden item");
    [permissive stop];

    WSKWebUploader* uploader = [[WSKWebUploader alloc] initWithUploadDirectory:root];
    XCTAssertTrue([uploader startWithOptions:options error:NULL]);
    XCTAssertFalse([SendRawRequest(uploader.port, @"GET /download?path=/pub/config HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"SECRETGITCONFIG"], @"the uploader downloaded through the symlink");
    XCTAssertFalse([SendRawRequest(uploader.port, @"GET /list?path=/pub HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"config"], @"the uploader enumerated a dot-directory through the symlink");
    XCTAssertTrue([SendRawRequest(uploader.port, @"GET /download?path=/data/normal.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"PUBLICOK"], @"the uploader stopped serving an ordinary file");
    [uploader stop];

    WSKWebDAVServer* dav = [[WSKWebDAVServer alloc] initWithUploadDirectory:root];
    XCTAssertTrue([dav startWithOptions:options error:NULL]);
    XCTAssertFalse([SendRawRequest(dav.port, @"GET /pub/config HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"SECRETGITCONFIG"], @"WebDAV read through the symlink");
    // The write is the sharpest one: the same PUT spelled "/.git/hooks/x" is refused.
    SendRawRequest(dav.port, @"PUT /pub/hooks/x HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nevil");
    XCTAssertFalse([fm fileExistsAtPath:[root stringByAppendingPathComponent:@".git/hooks/x"]], @"WebDAV wrote inside a dot-directory through the symlink");
    NSString* legitimate = SendRawRequest(dav.port, @"PUT /data/ok.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\ngood");
    XCTAssertTrue([legitimate hasPrefix:@"HTTP/1.1 201"], @"WebDAV stopped accepting an ordinary PUT: %@", [legitimate substringToIndex:MIN((NSUInteger)40, legitimate.length)]);
    [dav stop];

    [fm removeItemAtPath:root error:NULL];
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

// Scoping the asset handlers removed the catch-all that used to serve the bundle root, and with
// it the incidental 404 every unmatched GET fell through to — so "/favicon.ico", which browsers
// request unprompted, started answering 501 Not Implemented. 501 is a statement about the
// method, which the server implements perfectly well.
- (void)testUploaderAnswersNotFoundRatherThanNotImplemented {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);
    NSString* host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port];

    for (NSString* path in @[ @"/favicon.ico", @"/apple-touch-icon.png", @"/nope.txt", @"/css/missing.css" ]) {
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\n\r\n", path, host]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 404"], @"\"%@\" should be Not Found: %@", path, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }

    // The catch-all matches GET only, exactly as the base path handler it replaces did, so no
    // other method's status is affected by it.
    NSString* posted = SendRawRequest(server.port, [NSString stringWithFormat:@"POST /nope.txt HTTP/1.1\r\nHost: %@\r\nContent-Length: 0\r\n\r\n", host]);
    XCTAssertFalse([posted hasPrefix:@"HTTP/1.1 404"], @"the catch-all must not claim non-GET methods: %@", [posted substringToIndex:MIN((NSUInteger)40, posted.length)]);

    // And it must sit behind every real handler, not in front of them.
    NSString* page = SendRawRequest(server.port, [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: %@\r\n\r\n", host]);
    XCTAssertTrue([page hasPrefix:@"HTTP/1.1 200"], @"the catch-all shadowed the page handler: %@", [page substringToIndex:MIN((NSUInteger)40, page.length)]);
    NSString* asset = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /css/index.css HTTP/1.1\r\nHost: %@\r\n\r\n", host]);
    XCTAssertTrue([asset hasPrefix:@"HTTP/1.1 200"], @"the catch-all shadowed the asset handlers: %@", [asset substringToIndex:MIN((NSUInteger)40, asset.length)]);

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

// The sixth pass tested the strength deduction at *redemption* time, which closes nothing: by
// the time any resume arrives the second has always shut, so the guard reported "strong" for
// precisely the representation that was not. Reproduced 5/5 before this fix. The deduction now
// happens where it means something — when the validator is issued — so a date naming a second
// that is still open is never handed out, and the splice has no date to travel on.
- (void)testIfRangeRefusesADateMintedInsideItsOwnSecond {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* path = [root stringByAppendingPathComponent:@"build.ipa"];

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Publish build A, let a client take a prefix, then republish inside the SAME wall-clock
    // second — the case a build server hits when it rewrites a file in place. Retried rather
    // than asserted on if the sequence straddles a boundary, so this measures the intended
    // regime instead of racing the clock.
    NSString* resumed = nil;
    time_t sealedSecond = 0;
    NSString* lastModified = nil;
    for (NSUInteger attempt = 0; attempt < 5; attempt++) {
        XCTAssertTrue([[@"" stringByPaddingToLength:4096 withString:@"A" startingAtIndex:0] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        time_t const before = time(NULL);
        NSString* prefix = SendRawRequest(server.port, @"GET /build.ipa HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-1023\r\n\r\n");

        lastModified = nil;
        for (NSString* line in [prefix componentsSeparatedByString:@"\r\n"]) {
            if ([line hasPrefix:@"Last-Modified: "]) {
                lastModified = [line substringFromIndex:15];
            }
        }
        XCTAssertTrue([[[prefix componentsSeparatedByString:@"\r\n"] firstObject] hasPrefix:@"HTTP/1.1 206"], @"the prefix fetch itself must succeed: %@", prefix);

        XCTAssertTrue([[@"" stringByPaddingToLength:4096 withString:@"B" startingAtIndex:0] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        if (time(NULL) != before) {
            continue;  // Straddled a second: not the regime under test.
        }

        // No date may have been issued for a second that was still open when it was served.
        XCTAssertNil(lastModified, @"a date validator was issued for the still-open current second, so a client can present it later");

        // And a client presenting that date anyway — fabricated, or held from elsewhere — must
        // not be given a range against the *replacement*.
        NSString* const attempted = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /build.ipa HTTP/1.1\r\nHost: localhost\r\nRange: bytes=1024-2047\r\nIf-Range: %@\r\n\r\n", WSKFormatRFC822([NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)before])]);

        // The clock has to be re-checked AFTER the resume, not only before it. The guard below is
        // evaluated when the resume *arrives*, so a resume that lands in the next second sees a
        // sealed timestamp and honours the date — which is correct behaviour (see the note at the
        // end of this test) but is not the regime under test. Checking only up to the write made
        // this test pass locally and fail on a slower CI runner.
        if (time(NULL) != before) {
            continue;
        }

        resumed = attempted;
        sealedSecond = before;
        break;
    }

    XCTAssertNotNil(resumed, @"could not land the whole sequence inside one second in five attempts");
    NSString* status = [[resumed componentsSeparatedByString:@"\r\n"] firstObject];
    XCTAssertTrue([status hasPrefix:@"HTTP/1.1 200"], @"a 206 spliced build B onto build A's prefix: %@", status);

    // The inherent limit, pinned so a later pass does not re-find it and try to "fix" it. Once
    // the second has closed, the server WOULD issue that date for the current bytes, so a date a
    // client legitimately holds and one it fabricated are byte-identical — nothing derived from
    // stat(2) can separate them, exactly as for a replacement that preserves mtime. What protects
    // a conformant client is that no such date is ever issued while the second is open (asserted
    // above); the redemption-time check is not a second line of defence and must not be described
    // as one.
    [NSThread sleepForTimeInterval:1.1];
    NSString* afterTheSecondClosed = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /build.ipa HTTP/1.1\r\nHost: localhost\r\nRange: bytes=1024-2047\r\nIf-Range: %@\r\n\r\n", WSKFormatRFC822([NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)sealedSecond])]);
    XCTAssertTrue([[[afterTheSecondClosed componentsSeparatedByString:@"\r\n"] firstObject] hasPrefix:@"HTTP/1.1 206"], @"a date naming a closed second is honoured; if this ever changes, the change is deliberate and this comment is wrong");

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

// Containment was decided on one realpath, hiddenness on a second, and the file was then opened
// by a THIRD path — the one the client typed, symlinks and all. Those are three observations of a
// filesystem that need not agree. Retargeting a symlink between them served content from outside
// the served root in 24% of requests measured, with no concurrency on the client side at all.
// Serving the resolved path closes that: a resolved path contains no symlinks, so retargeting one
// cannot redirect the open.
//
// This asserts the property, not a timing: the request is issued while a helper flips the link,
// and the invariant is that NO response ever carries content from outside the root. Against the
// unfixed source it fails within a few hundred iterations.
// The same single-resolution property for the two servers that write. WebDAV was the sharpest:
// with a symlink retargeted underneath it, 228 of 600 PUTs landed files OUTSIDE the share, and
// 25.7% of GETs served content from outside it. The uploader's /download leaked 18.4%.
- (void)testRetargetedSymlinkCannotEscapeTheUploaderOrWebDAV {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* base = MakeTempDirectory();
    NSString* root = [base stringByAppendingPathComponent:@"root"];
    NSString* outside = [base stringByAppendingPathComponent:@"outside"];
    XCTAssertTrue([fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"good"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([fm createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"PUBLIC_MARKER" writeToFile:[root stringByAppendingPathComponent:@"good/target.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"SECRET_OUTSIDE_MARKER" writeToFile:[outside stringByAppendingPathComponent:@"target.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSString* link = [root stringByAppendingPathComponent:@"link"];
    NSString* staging = [root stringByAppendingPathComponent:@".flip"];
    XCTAssertEqual(symlink("good", link.fileSystemRepresentation), 0);

    __block BOOL stop = NO;
    dispatch_queue_t flipper = dispatch_queue_create("flip", DISPATCH_QUEUE_SERIAL);
    dispatch_async(flipper, ^{
        NSUInteger i = 0;
        while (!stop) {
            unlink(staging.fileSystemRepresentation);
            if (symlink((i++ & 1) ? "good" : "../outside", staging.fileSystemRepresentation) == 0) {
                rename(staging.fileSystemRepresentation, link.fileSystemRepresentation);
            }
        }
    });

    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};

    WSKWebUploader* uploader = [[WSKWebUploader alloc] initWithUploadDirectory:root];
    XCTAssertTrue([uploader startWithOptions:options error:NULL]);
    NSUInteger uploaderLeaks = 0;
    for (NSUInteger i = 0; i < 400; i++) {
        if ([SendRawRequest(uploader.port, @"GET /download?path=/link/target.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"SECRET_OUTSIDE_MARKER"]) {
            uploaderLeaks++;
        }
    }
    [uploader stop];

    WSKWebDAVServer* dav = [[WSKWebDAVServer alloc] initWithUploadDirectory:root];
    XCTAssertTrue([dav startWithOptions:options error:NULL]);
    NSUInteger davLeaks = 0;
    NSUInteger escapedWrites = 0;
    for (NSUInteger i = 0; i < 400; i++) {
        if ([SendRawRequest(dav.port, @"GET /link/target.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"SECRET_OUTSIDE_MARKER"]) {
            davLeaks++;
        }
        NSString* name = [NSString stringWithFormat:@"pwn%lu.txt", (unsigned long)i];
        SendRawRequest(dav.port, [NSString stringWithFormat:@"PUT /link/%@ HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nPWNED", name]);
        if ([fm fileExistsAtPath:[outside stringByAppendingPathComponent:name]]) {
            escapedWrites++;
        }
    }
    [dav stop];

    stop = YES;
    dispatch_sync(flipper, ^{
    });

    XCTAssertEqual(uploaderLeaks, (NSUInteger)0, @"%lu uploader downloads served content from outside the share", (unsigned long)uploaderLeaks);
    XCTAssertEqual(davLeaks, (NSUInteger)0, @"%lu WebDAV GETs served content from outside the share", (unsigned long)davLeaks);
    XCTAssertEqual(escapedWrites, (NSUInteger)0, @"%lu WebDAV PUTs wrote files outside the share", (unsigned long)escapedWrites);

    // The honest cases must still work through both servers.
    unlink(link.fileSystemRepresentation);
    XCTAssertEqual(symlink("good", link.fileSystemRepresentation), 0);
    WSKWebUploader* settled = [[WSKWebUploader alloc] initWithUploadDirectory:root];
    XCTAssertTrue([settled startWithOptions:options error:NULL]);
    XCTAssertTrue([SendRawRequest(settled.port, @"GET /download?path=/link/target.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"PUBLIC_MARKER"], @"a stable in-root symlink stopped being served");
    [settled stop];

    [fm removeItemAtPath:base error:NULL];
}

- (void)testRetargetedSymlinkCannotEscapeTheServedRoot {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* base = MakeTempDirectory();
    NSString* root = [base stringByAppendingPathComponent:@"root"];
    NSString* outside = [base stringByAppendingPathComponent:@"outside"];
    XCTAssertTrue([fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"good"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([fm createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"PUBLIC_MARKER" writeToFile:[root stringByAppendingPathComponent:@"good/target.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"SECRET_OUTSIDE_MARKER" writeToFile:[outside stringByAppendingPathComponent:@"target.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSString* link = [root stringByAppendingPathComponent:@"link"];
    NSString* staging = [root stringByAppendingPathComponent:@".flip"];
    XCTAssertEqual(symlink("good", link.fileSystemRepresentation), 0);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/files/" directoryPath:root indexFilename:nil cacheAge:0 allowRangeRequests:NO];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Retarget atomically via rename(2), so the link is never absent — an unlink/symlink pair
    // would leave ENOENT windows and make the run look cleaner than it is.
    __block BOOL stop = NO;
    dispatch_queue_t flipper = dispatch_queue_create("flip", DISPATCH_QUEUE_SERIAL);
    dispatch_async(flipper, ^{
        NSUInteger i = 0;
        while (!stop) {
            unlink(staging.fileSystemRepresentation);
            if (symlink((i++ & 1) ? "good" : "../outside", staging.fileSystemRepresentation) == 0) {
                rename(staging.fileSystemRepresentation, link.fileSystemRepresentation);
            }
        }
    });

    NSUInteger escapes = 0;
    for (NSUInteger i = 0; i < 600; i++) {
        NSString* reply = SendRawRequest(server.port, @"GET /files/link/target.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
        if ([reply containsString:@"SECRET_OUTSIDE_MARKER"]) {
            escapes++;
        }
    }
    stop = YES;
    dispatch_sync(flipper, ^{
    });

    XCTAssertEqual(escapes, (NSUInteger)0, @"%lu of 600 responses served content from outside the served root", (unsigned long)escapes);

    // And the honest case must still work, or this has just broken symlinks entirely.
    unlink(link.fileSystemRepresentation);
    XCTAssertEqual(symlink("good", link.fileSystemRepresentation), 0);
    XCTAssertTrue([SendRawRequest(server.port, @"GET /files/link/target.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"PUBLIC_MARKER"], @"a stable in-root symlink stopped being served");

    [server stop];
    [fm removeItemAtPath:base error:NULL];
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
    // A mismatched port is deliberately NOT refused any more, and this assertion was inverted on
    // purpose — see testHostValidationMatchesAnyPortUnlessAnEntryPinsOne. It used to be refused,
    // which contradicted WSKOption_AllowedHostNames' own documentation and broke every deployment
    // behind a port-translating hop. It protected nothing: Host is derived from the request URL,
    // not from the page's origin, so a browser fetching this server can only ever state THIS
    // server's port — a differing one comes from a forwarder, or from a non-browser client that
    // could state any Host it liked and for which rebinding (which needs a browser) does not apply.
    // The name is what carries the defence, and the assertions above still prove it does.
    XCTAssertFalse([get([NSString stringWithFormat:@"localhost:%lu", (unsigned long)server.port + 1]) containsString:@"421"], @"a differing port on an accepted name should no longer be refused");

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
// WSKOption_AllowedHostNames documents that an entry "may include a port ... without one, any port
// matches". The code did the opposite: a Host stating ANY port was refused unless that port equalled
// the one the connection arrived on, checked before the name was even consulted. Every deployment
// behind a port-translating hop was therefore 421 for every request — which is the priority
// deployment, since Tailscale Serve terminates TLS on 443 and forwards to a local port.
//
// Dropping the comparison costs no security: the DNS-rebinding defence turns entirely on the NAME,
// and an attacker controls the port he targets either way. An entry that DOES pin a port is still
// honoured verbatim, which this pins in both directions.
- (void)testHostValidationMatchesAnyPortUnlessAnEntryPinsOne {
    NSString* dir = MakeTempDirectory();
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:NO];
    NSDictionary* options = @{
        WSKOption_Port : @0,
        WSKOption_BindToLocalhost : @YES,
        WSKOption_AllowedHostNames : @[ @"files.example", @"pinned.example:9999" ]
    };
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* (^get)(NSString*) = ^(NSString* host) {
        return SendRawRequest(server.port, [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: %@\r\n\r\n", host]);
    };

    // An entry with no port matches whatever port the client states, including none.
    for (NSString* host in @[ @"files.example", @"files.example:80", @"files.example:443", @"files.example:8080" ]) {
        XCTAssertFalse([get(host) hasPrefix:@"HTTP/1.1 421"], @"an unpinned entry should match any port, but \"%@\" was refused", host);
    }

    // The same for the names accepted without configuration — a forwarded localhost or IP literal
    // arrives carrying the port the client dialled, not the one being listened on.
    for (NSString* host in @[ @"localhost", @"localhost:8080", @"127.0.0.1:8080", @"[::1]:8080" ]) {
        XCTAssertFalse([get(host) hasPrefix:@"HTTP/1.1 421"], @"\"%@\" should be accepted whatever port it states", host);
    }

    // An entry that pins a port still means it, and a name not on the list is still refused —
    // the rebinding defence must be exactly as strong as before.
    XCTAssertFalse([get(@"pinned.example:9999") hasPrefix:@"HTTP/1.1 421"], @"a pinned entry should match its own port");
    XCTAssertTrue([get(@"pinned.example:1234") hasPrefix:@"HTTP/1.1 421"], @"a pinned entry must not match a different port");
    XCTAssertTrue([get(@"evil.example") hasPrefix:@"HTTP/1.1 421"], @"an unlisted name must still be refused");
    XCTAssertTrue([get(@"evil.example:8080") hasPrefix:@"HTTP/1.1 421"], @"an unlisted name must still be refused whatever port it states");
    // A syntactically impossible port is still a malformed Host.
    XCTAssertTrue([get(@"files.example:notaport") hasPrefix:@"HTTP/1.1 421"], @"a non-numeric port should still be refused");

    [server stop];
    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
}

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
