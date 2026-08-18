// Connection lifetime, request framing, and the limits that bound one connection.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import "TestsSupport.h"

@interface WSKConnectionTests : XCTestCase
@end

@implementation WSKConnectionTests

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
    // Tightened from "500 or 400": the framing bound is a size limit, so 413 is what it owes, and
    // that is now what it sends. The loose form was written when every body failure was 500.
    XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 413"], @"server did not reject unbounded chunk framing with 413 (reply: %@)", reply);
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
    //
    // ⚠️ The dribbler MUST be waited for before the descriptor is closed. It used to run
    // detached for up to 10 s while the test closed `fd` and returned — so a later test's
    // connect() could be handed the same descriptor NUMBER and the still-running dribbler would
    // write a stray byte into SOMEONE ELSE'S connection. That corrupted the next request on the
    // wire, and the server correctly answered 400 "malformed request line". It surfaced as an
    // intermittent failure in an unrelated keep-alive test, which is the worst possible place to
    // go looking. This is a use-after-close on a recycled descriptor — the same class this
    // project fixed in the server itself, here in the suite that guards it.
    dispatch_semaphore_t const dribbleDone = dispatch_semaphore_create(0);
    __block BOOL stopDribbling = NO;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (int i = 0; (i < 40) && !stopDribbling; i++) {  // up to ~10 s; stops early on EPIPE
            usleep(250 * 1000);
            const char space = ' ';

            if (send(fd, &space, 1, 0) < 0) {
                break;
            }
        }

        dispatch_semaphore_signal(dribbleDone);
    });

    BOOL sawEOF = NO;
    ReadToEOF(fd, &sawEOF);  // returns when the server closes the connection (or the recv timeout)
    XCTAssertTrue(sawEOF, @"header-phase deadline did not close a slowloris dribbling under one tick");

    stopDribbling = YES;
    long const dribbleFinished = dispatch_semaphore_wait(dribbleDone, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));
    XCTAssertEqual(dribbleFinished, (long)0, @"the dribbler must finish before its descriptor is closed and reused");
    close(fd);
    [server stop];
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

// An unmatched request always answered 501 Not Implemented — a statement about the METHOD — even
// when the method was one the server implements perfectly well and only the target was unknown. A
// browser asking for /favicon.ico was told the server does not implement GET. 501 is also
// heuristically cacheable (RFC 9111 §4.2.2), so an intermediary may remember it for a path that
// later gains a handler.
//
// The distinction the server CAN make is "does any handler claim this method". The one it cannot
// is "which methods does this path accept", which is what a 405 with Allow would need — a handler
// is an opaque match block. So 405 is deliberately not attempted, and this test pins the two
// answers that are honest rather than a third that would be guessed.
- (void)testUnmatchedRequestDistinguishesUnknownTargetFromUnimplementedMethod {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addHandlerForMethod:@"GET"
                           path:@"/ok"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse*(WSKRequest* request) {
                       return [WSKDataResponse responseWithText:@"ok"];
                   }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // GET is implemented, so an unknown target is 404 — not "this server does not do GET".
    NSString* unknownTarget = SendRawRequest(server.port, @"GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([unknownTarget hasPrefix:@"HTTP/1.1 404"], @"an unknown target under an implemented method is 404: %@", [unknownTarget substringToIndex:MIN((NSUInteger)40, unknownTarget.length)]);

    // A method NO handler claims is genuinely not implemented, and 501 still says so.
    NSString* unknownMethod = SendRawRequest(server.port, @"PROPFIND /ok HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n");
    XCTAssertTrue([unknownMethod hasPrefix:@"HTTP/1.1 501"], @"a method no handler claims is still 501: %@", [unknownMethod substringToIndex:MIN((NSUInteger)40, unknownMethod.length)]);

    // A HEAD is rewritten to GET before matching, so it inherits GET's implemented-ness.
    NSString* head = SendRawRequest(server.port, @"HEAD /nope HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([head hasPrefix:@"HTTP/1.1 404"], @"a mapped HEAD follows GET: %@", [head substringToIndex:MIN((NSUInteger)40, head.length)]);

    // And the handler that does exist is untouched.
    XCTAssertTrue([SendRawRequest(server.port, @"GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 200"], @"the registered handler still serves");

    [server stop];
}

// Connection reuse, and the restriction that makes it safe. A client normally pays a TCP handshake
// per request because every response carried "Connection: Close" and the connection served exactly
// one request — fine for a few large downloads, wasteful for an interface fetching many small
// images.
//
// Reuse is allowed ONLY for requests carrying no body framing at all. Request smuggling is a
// disagreement about where one request's body ends and the next begins, so a connection on which no
// body is ever read cannot be desynchronized — the property is structural rather than a matter of
// parsing carefully. This test pins both halves: that eligible requests really do share one
// connection, and that every ineligible shape still closes.
- (void)testConnectionKeepAliveCarriesBodylessRequestsAndClosesOnEverythingElse {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"ALPHA" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"BETA" writeToFile:[dir stringByAppendingPathComponent:@"b.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/f/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    // Hoisted: a dictionary literal's commas split XCTAssertTrue's macro arguments. Fourth time
    // this project has hit that.
    NSDictionary* keepAliveOptions = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionKeepAliveTimeout : @5.0};
    XCTAssertTrue([server startWithOptions:keepAliveOptions error:NULL]);

    NSString* const getA = @"GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\n\r\n";
    NSString* const getB = @"GET /f/b.txt HTTP/1.1\r\nHost: localhost\r\n\r\n";

    NSArray<NSString*>* replies = SendRawRequestsOnOneConnection(server.port, @[ getA, getB, getA ]);
    XCTAssertEqual(replies.count, (NSUInteger)3, @"three bodyless GETs must all be answered on one connection");

    if (replies.count == 3) {
        XCTAssertTrue([replies[0] containsString:@"ALPHA"], @"first reply: %@", replies[0]);
        XCTAssertTrue([replies[1] containsString:@"BETA"], @"second reply — proves the connection was reused: %@", replies[1]);
        XCTAssertTrue([replies[2] containsString:@"ALPHA"], @"third reply: %@", replies[2]);
        XCTAssertTrue([replies[0] rangeOfString:@"Connection: keep-alive" options:NSCaseInsensitiveSearch].location != NSNotFound, @"the reply must announce reuse: %@", replies[0]);

        // State must not leak across requests on one connection — a class this connection could not
        // previously have, since it never served a second request. Serving b.txt after a.txt with
        // the first request's body or validators would show up here.
        XCTAssertFalse([replies[1] containsString:@"ALPHA"], @"the second reply must not carry the first's body");
    }

    // A HEAD followed by a GET: _virtualHEAD is per-request state, and inheriting it would suppress
    // the following GET's body entirely.
    NSArray<NSString*>* mixed = SendRawRequestsOnOneConnection(server.port, @[ @"HEAD /f/a.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", getB ]);
    XCTAssertEqual(mixed.count, (NSUInteger)2, @"a HEAD may be followed by a GET on the same connection");

    if (mixed.count == 2) {
        XCTAssertFalse([mixed[0] containsString:@"ALPHA"], @"a HEAD carries no body");
        XCTAssertTrue([mixed[1] containsString:@"BETA"], @"the GET after a HEAD must still get its body — _virtualHEAD must not leak: %@", mixed[1]);
    }

    // A request that was REFUSED ends the connection: a refusal can happen before the body is read,
    // so bytes may be left in flight that would otherwise be parsed as the next request line.
    NSArray<NSString*>* refused = SendRawRequestsOnOneConnection(server.port, @[ @"GET /f/nope.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", getA ]);
    XCTAssertTrue(refused.count >= 1, @"the refusal itself is answered");
    XCTAssertTrue([refused.firstObject hasPrefix:@"HTTP/1.1 404"], @"…as a 404: %@", refused.firstObject);
    XCTAssertTrue([refused.firstObject rangeOfString:@"keep-alive" options:NSCaseInsensitiveSearch].location == NSNotFound, @"a refusal must not offer to keep the connection: %@", refused.firstObject);

    // A request WITH a body is answered and the connection closes, whatever the body is. This is
    // the restriction the whole design rests on.
    NSArray<NSString*>* withBody = SendRawRequestsOnOneConnection(server.port, @[ @"GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n", getB ]);
    XCTAssertTrue(withBody.count >= 1, @"the request carrying framing is still answered");
    XCTAssertTrue([withBody.firstObject rangeOfString:@"keep-alive" options:NSCaseInsensitiveSearch].location == NSNotFound, @"a request declaring Content-Length must not be reused: %@", withBody.firstObject);

    // "Transfer-Encoding: identity" sets no content type, so -[WSKRequest hasBody] answers NO for
    // it — keying reuse on that instead of on the raw header names would have made exactly the
    // shape a TE.CL desync is built from eligible. It must not be.
    NSArray<NSString*>* identity = SendRawRequestsOnOneConnection(server.port, @[ @"GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: identity\r\n\r\n", getB ]);
    XCTAssertTrue(identity.count >= 1);
    XCTAssertTrue([identity.firstObject rangeOfString:@"keep-alive" options:NSCaseInsensitiveSearch].location == NSNotFound, @"a Transfer-Encoding of any kind must not be reused: %@", identity.firstObject);

    // A client that asks to close is obeyed.
    NSArray<NSString*>* asked = SendRawRequestsOnOneConnection(server.port, @[ @"GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", getB ]);
    XCTAssertTrue(asked.count >= 1);
    XCTAssertTrue([asked.firstObject rangeOfString:@"keep-alive" options:NSCaseInsensitiveSearch].location == NSNotFound, @"Connection: close must be honoured: %@", asked.firstObject);

    // HTTP/1.0 has no persistent connections by default and may be framed by connection close.
    NSArray<NSString*>* old = SendRawRequestsOnOneConnection(server.port, @[ @"GET /f/a.txt HTTP/1.0\r\nHost: localhost\r\n\r\n", getB ]);
    XCTAssertTrue(old.count >= 1);
    XCTAssertTrue([old.firstObject rangeOfString:@"keep-alive" options:NSCaseInsensitiveSearch].location == NSNotFound, @"an HTTP/1.0 client must not be given a persistent connection: %@", old.firstObject);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The option defaults to off, so every existing deployment keeps serving exactly one request per
// connection until it opts in. Worth pinning: the whole feature is new machinery in the most
// security-critical file in the library, and "the default did not change" is the property that
// makes landing it safe.
- (void)testConnectionKeepAliveIsOffByDefault {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"ALPHA" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/f/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* defaultOptions = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:defaultOptions error:NULL]);

    NSString* single = SendRawRequest(server.port, @"GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([single containsString:@"ALPHA"], @"the response is unchanged: %@", single);
    XCTAssertTrue([single rangeOfString:@"Connection: Close" options:NSCaseInsensitiveSearch].location != NSNotFound, @"the default is still one request per connection: %@", single);

    NSArray<NSString*>* replies = SendRawRequestsOnOneConnection(server.port, @[ @"GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\n\r\n" ]);
    XCTAssertEqual(replies.count, (NSUInteger)1, @"a second request on the same connection must go unanswered by default");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// A connection held open for reuse is holding one of kWSKMaxConnections slots, so it has to be
// given back. This is the half of keep-alive that matters most for a server measured in weeks: a
// reused connection that is never reclaimed is a slot leak, and 128 of them are a permanent denial
// of service with no error anywhere.
//
// The reclaim rides on the existing idle timer, which means the effective hold is rounded up to the
// next tick — the test uses a short idle timeout so it measures in seconds rather than in the
// 30-second default. What it pins is that the connection IS closed while idle, and that the
// slowloris deadline for a request in progress was not weakened to achieve it.
- (void)testConnectionKeepAliveReclaimsAnIdleConnection {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"ALPHA" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/f/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionKeepAliveTimeout : @1.0, WSKOption_ConnectionIdleTimeout : @1.0};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertTrue(fd >= 0);

    const char* request = "GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\n\r\n";
    XCTAssertTrue(send(fd, request, strlen(request), 0) > 0);

    // Drain the reply, then go quiet and let the reaper find it.
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    // Drain the WHOLE reply — header block plus exactly Content-Length bytes. A single recv
    // returns only what has arrived, so stopping there leaves the body in the socket and the
    // "did the server close?" read below picks THAT up instead of EOF.
    char buffer[8192];
    NSMutableData* reply = [NSMutableData data];
    NSData* const terminator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange headerEnd = NSMakeRange(NSNotFound, 0);
    NSInteger expected = 0;

    while (true) {
        headerEnd = [reply rangeOfData:terminator options:0 range:NSMakeRange(0, reply.length)];

        if (headerEnd.location != NSNotFound) {
            NSString* head = [[NSString alloc] initWithData:[reply subdataWithRange:NSMakeRange(0, NSMaxRange(headerEnd))] encoding:NSUTF8StringEncoding];
            NSRange lengthRange = [head rangeOfString:@"Content-Length: " options:NSCaseInsensitiveSearch];
            expected = (lengthRange.location == NSNotFound) ? 0 : [[head substringFromIndex:NSMaxRange(lengthRange)] integerValue];

            if ((NSInteger)(reply.length - NSMaxRange(headerEnd)) >= expected) {
                break;
            }
        }

        ssize_t chunk = recv(fd, buffer, sizeof(buffer), 0);

        if (chunk <= 0) {
            break;
        }

        [reply appendBytes:buffer length:(NSUInteger)chunk];
    }

    XCTAssertTrue(reply.length > 0, @"the first request is answered");
    XCTAssertTrue([[[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding] rangeOfString:@"keep-alive" options:NSCaseInsensitiveSearch].location != NSNotFound, @"…and the connection is offered for reuse");

    // Now read again without sending anything. A reclaimed connection gives EOF; one that is never
    // reclaimed sits here until the receive timeout above, which is what the assertion catches.
    NSDate* const started = [NSDate date];
    ssize_t const after = recv(fd, buffer, sizeof(buffer), 0);
    NSTimeInterval const waited = -[started timeIntervalSinceNow];
    close(fd);

    XCTAssertEqual(after, (ssize_t)0, @"an idle kept-alive connection must be closed by the server, not held forever");
    XCTAssertLessThan(waited, 4.5, @"…and reclaimed promptly rather than at the receive timeout (waited %.1fs)", waited);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The companion to the reclaim test above, and the one that actually discriminates. That test
// passes even with the keep-alive idle branch removed, because the pre-existing header-phase
// deadline (kMaxHeaderPhaseTicks idle ticks, a slowloris defence) closes the connection anyway —
// so it pins "nothing leaks" but says nothing about the configured timeout being honoured.
//
// This one sets a keep-alive longer than that deadline and shows the connection survives past it.
// Without the branch, an idle reused connection is cut after two idle ticks no matter what
// WSKOption_ConnectionKeepAliveTimeout says, and the option's documented meaning would be a lie.
- (void)testConnectionKeepAliveHoldsForTheConfiguredTimeNotTheSlowlorisDeadline {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"ALPHA" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/f/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    // Idle ticks of 2s, so the header-phase deadline (kMaxHeaderPhaseTicks = 2 ticks) would cut an
    // idle connection at ~4s; a keep-alive of 12s must override that, and the 5s pause below sits
    // between the two so the assertion can only pass if the keep-alive branch is what held it.
    //
    // Deliberately NOT 1s ticks, which is what this used first: that leaves the header phase only
    // 2s to receive and match a request, and a loaded machine trips it — measured flaking 2 runs in
    // 6 under the full suite. The margin, not the property, was the problem.
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionKeepAliveTimeout : @12.0, WSKOption_ConnectionIdleTimeout : @2.0};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertTrue(fd >= 0);
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    NSString* (^exchange)(void) = ^NSString* {
        const char* request = "GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\n\r\n";

        if (send(fd, request, strlen(request), 0) <= 0) {
            return nil;
        }

        NSMutableData* reply = [NSMutableData data];
        NSData* const terminator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        char buffer[8192];

        while (true) {
            NSRange headerEnd = [reply rangeOfData:terminator options:0 range:NSMakeRange(0, reply.length)];

            if (headerEnd.location != NSNotFound) {
                NSString* head = [[NSString alloc] initWithData:[reply subdataWithRange:NSMakeRange(0, NSMaxRange(headerEnd))] encoding:NSUTF8StringEncoding];
                NSRange lengthRange = [head rangeOfString:@"Content-Length: " options:NSCaseInsensitiveSearch];
                NSInteger expected = (lengthRange.location == NSNotFound) ? 0 : [[head substringFromIndex:NSMaxRange(lengthRange)] integerValue];

                if ((NSInteger)(reply.length - NSMaxRange(headerEnd)) >= expected) {
                    break;
                }
            }

            ssize_t chunk = recv(fd, buffer, sizeof(buffer), 0);

            if (chunk <= 0) {
                break;
            }

            [reply appendBytes:buffer length:(NSUInteger)chunk];
        }

        return [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding];
    };

    XCTAssertTrue([exchange() containsString:@"ALPHA"], @"the first request is answered");

    // Go quiet for longer than the header-phase deadline would tolerate, then use the connection.
    [NSThread sleepForTimeInterval:5.0];

    NSString* second = exchange();
    XCTAssertTrue([second containsString:@"ALPHA"], @"the connection must survive an idle period shorter than the configured keep-alive: %@", second);

    close(fd);
    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// A pipelining client writes its next request before reading the previous reply, so the second
// request's bytes arrive in the SAME socket read as the first's header block. Those bytes are
// carried over rather than dropped — and the header reader has to notice it already holds a
// complete block instead of issuing a read for bytes the client has no reason to send, which would
// hang until the idle timeout. That hazard is the reason this is a refactor and not a one-line loop.
- (void)testConnectionKeepAliveAnswersPipelinedRequestsInOrder {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"ALPHA" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"BETA" writeToFile:[dir stringByAppendingPathComponent:@"b.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/f/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    // Hoisted: a dictionary literal's commas split XCTAssertTrue's macro arguments. Fourth time
    // this project has hit that.
    NSDictionary* keepAliveOptions = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionKeepAliveTimeout : @5.0};
    XCTAssertTrue([server startWithOptions:keepAliveOptions error:NULL]);

    // Both requests in a single write, so the second lands in the first's read.
    NSArray<NSString*>* replies = SendRawRequestsOnOneConnection(server.port, @[ @"GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\n\r\nGET /f/b.txt HTTP/1.1\r\nHost: localhost\r\n\r\n" ]);
    XCTAssertTrue(replies.count >= 1, @"the first pipelined request is answered");
    XCTAssertTrue([replies.firstObject containsString:@"ALPHA"], @"…and in order: %@", replies.firstObject);

    // Then drain the second reply, which must have been produced from the carried-over bytes
    // without waiting for anything further from the client.
    NSArray<NSString*>* both = SendRawRequestsOnOneConnection(server.port, @[ @"GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\n\r\nGET /f/b.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"" ]);
    XCTAssertEqual(both.count, (NSUInteger)2, @"a pipelined pair must produce two replies");

    if (both.count == 2) {
        XCTAssertTrue([both[0] containsString:@"ALPHA"], @"first: %@", both[0]);
        XCTAssertTrue([both[1] containsString:@"BETA"], @"second, from carried-over bytes: %@", both[1]);
    }

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The reaper that reclaims an IDLE reused connection must not fire on one that is busy. A request
// arriving in the previous request's final read is served without a single further byte being read,
// and the "has the next request started arriving?" test was a read-count comparison — which such a
// request can never satisfy, because its bytes were counted against the request before it. So the
// connection was still marked idle while its response was streaming, and the keep-alive deadline
// cut the body off mid-transfer under a Content-Length it then never reached.
//
// That is the worst shape a bug can take here: a complete, well-formed, WRONG response. The
// deployment this library is aimed at pulls multi-hundred-megabyte builds, so a body that stops
// early and claims not to have is an IPA that installs and crashes.
- (void)testPipelinedRequestIsNotReclaimedWhileItsResponseIsStillStreaming {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSUInteger const bigLength = 8 * 1024 * 1024;
    XCTAssertTrue([@"ALPHA" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([[NSMutableData dataWithLength:bigLength] writeToFile:[dir stringByAppendingPathComponent:@"big.bin"] atomically:YES]);

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/f/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    // A short keep-alive and a matching tick, so the reaper's deadline lands about one second in —
    // comfortably inside the paced transfer below, which takes roughly 2.5 s.
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionKeepAliveTimeout : @0.5, WSKOption_ConnectionIdleTimeout : @0.5};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* const first = @"GET /f/a.txt HTTP/1.1\r\nHost: localhost\r\n\r\n";
    NSString* const second = @"GET /f/big.bin HTTP/1.1\r\nHost: localhost\r\n\r\n";

    // PIPELINED: both requests in one write, so the second is served entirely from carried-over
    // bytes and the connection performs no read at all while answering it.
    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertTrue(fd >= 0);
    NSString* const both = [first stringByAppendingString:second];
    XCTAssertEqual(send(fd, both.UTF8String, strlen(both.UTF8String), 0), (ssize_t)strlen(both.UTF8String));
    NSUInteger const pipelinedBytes = DrainToEOFAtPace(fd, 32 * 1024, 10000);
    close(fd);

    // SEQUENTIAL CONTROL: the same two requests, but the second written after the first reply is
    // read, so its bytes DO arrive as a socket read. This exercises everything the pipelined case
    // does except the carried-over path, and it must pass whether or not the bug is present — if it
    // fails too, the test is measuring the ordinary response-phase idle rule and proves nothing.
    fd = ConnectToLocalhostPort(server.port);
    XCTAssertTrue(fd >= 0);
    XCTAssertEqual(send(fd, first.UTF8String, strlen(first.UTF8String), 0), (ssize_t)strlen(first.UTF8String));
    char reply[4096];
    XCTAssertTrue(recv(fd, reply, sizeof(reply), 0) > 0, @"the first reply must arrive before the second request is sent");
    XCTAssertEqual(send(fd, second.UTF8String, strlen(second.UTF8String), 0), (ssize_t)strlen(second.UTF8String));
    NSUInteger const sequentialBytes = DrainToEOFAtPace(fd, 32 * 1024, 10000);
    close(fd);

    XCTAssertGreaterThan(sequentialBytes, bigLength, @"CONTROL FAILED: a sequential reused connection lost bytes too, so this test is measuring the ordinary idle rule rather than the keep-alive reaper");
    XCTAssertGreaterThan(pipelinedBytes, bigLength, @"a pipelined response was cut short at %lu of %lu bytes: the connection was treated as idle while it was streaming", (unsigned long)pipelinedBytes, (unsigned long)bigLength);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// Everything past the header block was required to fit inside Content-Length, and anything more was
// answered 400. TCP makes no such promise: a client that writes a body-bearing request and whatever
// follows it in one segment lands both in one read. Refusing that is honouring a guess about
// segmentation, and it made the verdict depend on how the client happened to split its writes —
// the same split-dependence class this project already has an oracle for.
//
// The trailing bytes are still never INTERPRETED: a request carrying body framing is not eligible
// for reuse, so the connection closes after it and the remainder is dropped exactly as before.
// Nothing here widens what may be framed on a reused connection.
- (void)testRequestWithBytesTrailingItsBodyIsServedRatherThanRefused {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addHandlerForMethod:@"POST"
                           path:@"/echo"
                   requestClass:[WSKDataRequest class]
                   processBlock:^WSKResponse*(WSKRequest* request) {
                       return [WSKDataResponse responseWithData:[(WSKDataRequest*)request data] contentType:@"text/plain"];
                   }];
    [server addHandlerForMethod:@"GET"
                           path:@"/ok"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse*(WSKRequest* request) {
                       return [WSKDataResponse responseWithText:@"OK"];
                   }];

    // DEFAULT configuration — no keep-alive. This is not a reuse defect: the check predates
    // connection reuse entirely, and a single write is all it takes to reach it.
    NSDictionary* defaultOptions = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};  // Hoisted: the commas would split the macro's arguments
    XCTAssertTrue([server startWithOptions:defaultOptions error:NULL]);
    NSString* const trailing = @"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nBODYGET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n";
    NSString* reply = SendRawRequest(server.port, trailing);
    XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 200"], @"a request whose body is followed by more bytes in the same read must still be served: %@", [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    XCTAssertTrue([reply containsString:@"BODY"], @"the body must be exactly Content-Length bytes, with the trailing bytes excluded: %@", reply);
    [server stop];

    // And with reuse enabled, where a pipelining client produces the same shape deliberately.
    NSDictionary* keepAliveOptions = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionKeepAliveTimeout : @5.0};
    XCTAssertTrue([server startWithOptions:keepAliveOptions error:NULL]);
    NSArray<NSString*>* replies = SendRawRequestsOnOneConnection(server.port, @[ [@"GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n" stringByAppendingString:trailing], @"" ]);
    XCTAssertTrue(replies.count >= 1);
    XCTAssertTrue([replies.firstObject hasPrefix:@"HTTP/1.1 200"], @"first: %@", replies.firstObject);
    XCTAssertFalse([replies.firstObject containsString:@"400"], @"a pipelined body-bearing request must not be refused: %@", replies.firstObject);
    [server stop];
}

// -open and -close are the documented connection-lifecycle pair: -open is "called when the
// connection is opened" and may return NO to REJECT it, which is only meaningful once per
// connection. A host app pairing them — allocate in one, release in the other — is following the
// header. Reuse called -close once per REQUEST, so two requests on one connection produced one
// open and two closes, and the second release had nothing left to release.
//
// The same sequence pins the other half: a persistent connection ending because the client went
// away is the designed end of one, not a failure, and must not manufacture a response for a
// request that does not exist.
- (void)testReusedConnectionOpensAndClosesOnceAndInventsNoResponseAtTheEnd {
    gConnectionEvents = [NSMutableArray array];

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addHandlerForMethod:@"GET"
                           path:@"/ok"
                   requestClass:[WSKRequest class]
                   processBlock:^WSKResponse*(WSKRequest* request) {
                       return [WSKDataResponse responseWithText:@"OK"];
                   }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_ConnectionKeepAliveTimeout : @5.0, WSKOption_ConnectionClass : [LifecycleProbeConnection class]};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSArray<NSString*>* replies = SendRawRequestsOnOneConnection(server.port, @[ @"GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\nGET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n", @"" ]);
    XCTAssertEqual(replies.count, (NSUInteger)2, @"both requests must be answered before the pairing is judged");

    [server stop];

    // -stop is NOT a barrier for connection teardown: it waits on _sourceGroup, which covers the
    // LISTENING sources' cancel handlers, and never on _activeConnections. -close now runs from
    // -dealloc for the last request on a connection, so its timing is tied to when the last block
    // holding the connection unwinds, not to -stop. Asserting straight after it passed on this
    // machine 6/6 in isolation and under CPU load, and failed on CI with closes=0 — the race, won
    // locally and lost there. Wait for the event instead of assuming the ordering.
    //
    // This cannot mask the defect it is guarding: the unfixed code calls -close once per REQUEST,
    // so `closes` reaches 2 before -stop is even called and the poll returns immediately with the
    // wrong value still in hand.
    NSDate* const deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];

    while ([deadline timeIntervalSinceNow] > 0) {
        @synchronized(gConnectionEvents) {
            if ([gConnectionEvents containsObject:@"close"]) {
                break;
            }
        }

        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }

    NSArray<NSString*>* events = nil;

    @synchronized(gConnectionEvents) {
        events = [gConnectionEvents copy];
    }

    XCTAssertTrue([events containsObject:@"close"], @"the connection never closed within 10 s: %@", events);
    NSUInteger opens = 0, closes = 0, aborts = 0;

    for (NSString* event in events) {
        if ([event isEqualToString:@"open"]) {
            opens += 1;
        } else if ([event isEqualToString:@"close"]) {
            closes += 1;
        } else if ([event hasPrefix:@"abort"]) {
            aborts += 1;
        }
    }

    XCTAssertEqual(opens, (NSUInteger)1, @"one connection, so one -open: %@", events);
    XCTAssertEqual(closes, opens, @"-close must pair with -open, not run once per request: %@", events);
    XCTAssertEqual(aborts, (NSUInteger)0, @"a client closing a persistent connection is its designed end, not a request to refuse: %@", events);

    gConnectionEvents = nil;
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
    // 404 rather than the 501 this once asserted: a GET handler is registered above, and the HEAD
    // was rewritten to GET before matching, so the METHOD is implemented and only the target is
    // missing. The branch under test — the one that builds its own request — is the same either
    // way; the status is incidental to what this test is actually about.
    XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 404"], @"expected 404 for an unclaimed path on a server that does implement GET: %@", reply);

    XCTAssertNotNil(gAbortRequestPeer, @"the aborted request carried no peer address");
    XCTAssertTrue([gAbortRequestPeer hasPrefix:@"127.0.0.1"], @"peer address is wrong: %@", gAbortRequestPeer);
    XCTAssertTrue(gAbortRequestSawVirtualHEAD, @"a mapped HEAD must be distinguishable from a real GET on this path");

    [server stop];
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

// A WSKMatchBlock builds the request, and the connection only populates its addresses
// AFTER the block returns — so inside the block they are nil. Reading them there fed a
// NULL sockaddr to WSKStringFromSockAddr, which dereferences addr->sa_len before it can
// fail, i.e. SEGV rather than a nil. Inspecting the request is the match block's job.
- (void)testRequestAddressAccessorsAreSafeBeforeTheServerPopulatesThem {
    WSKRequest* request = [[WSKRequest alloc] initWithMethod:@"GET"
                                                         url:LiteralURL(@"http://localhost/x")
                                                     headers:@{}
                                                        path:@"/x"
                                                       query:@{}];
    XCTAssertNoThrow([request remoteAddressString]);
    XCTAssertNoThrow([request localAddressString]);
}

// CFHTTPMessageCreateResponse's reason-phrase table predates every status registered after
// HTTP/1.1, so it answered the class default for fourteen of the codes this library declares.
// 421 is the Host allow-list refusal — the DNS-rebinding defence — and it went out labelled
// "Bad Request", which is a different claim about why the request was refused.
- (void)testStatusLinesCarryTheirOwnReasonPhrase {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES];

    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_AllowedHostNames : @[@"allowed.example"]};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* misdirected = SendRawRequest(server.port, @"GET / HTTP/1.1\r\nHost: evil.example\r\n\r\n");
    XCTAssertTrue([misdirected hasPrefix:@"HTTP/1.1 421 Misdirected Request"], @"421 must name itself: %@", [misdirected substringToIndex:MIN((NSUInteger)40, misdirected.length)]);

    // A code CoreFoundation already gets right must be untouched — the recorded-trace corpus
    // compares response bytes, so a phrase changing there would be a corpus break.
    NSString* notFound = SendRawRequest(server.port, @"GET /nope.txt HTTP/1.1\r\nHost: allowed.example\r\n\r\n");
    XCTAssertTrue([notFound hasPrefix:@"HTTP/1.1 404 Not Found"], @"404's phrase must be unchanged: %@", [notFound substringToIndex:MIN((NSUInteger)40, notFound.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// RFC 9110 §5.5: a recipient of CR, LF, or NUL within a field VALUE must either reject the
// message or replace the byte with SP. The validating pass already refuses a bare CR, a bare LF
// and obs-fold, and the tchar check refuses a NUL in a field NAME — the value bytes were the one
// place the class stayed open (measured answering 200 with the NUL delivered intact into
// request.headers). obs-text (0x80–0xFF) is legal field content and HTAB is legal whitespace,
// so both must keep being served: this is a control-byte refusal, not an ASCII allow-list.
- (void)testControlBytesInHeaderValuesAreRefused {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSData* (^requestWithValueByte)(unsigned char) = ^(unsigned char byte) {
        NSMutableData* raw = [[@"GET /a HTTP/1.1\r\nHost: localhost\r\nX-A: a" dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
        [raw appendBytes:&byte length:1];
        [raw appendData:UTF8Data(@"b\r\n\r\n")];
        return (NSData*)raw;
    };

    const unsigned char refused[] = {0x00, 0x01, 0x1F, 0x7F};
    for (size_t i = 0; i < sizeof(refused); i++) {
        NSString* reply = SendRawDataRequest(server.port, requestWithValueByte(refused[i]));
        XCTAssertTrue([reply containsString:@"400"], @"byte 0x%02X in a field value must be refused, got: %@", refused[i], [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }

    const unsigned char served[] = {0x09, 0xE9};  // HTAB, and an obs-text byte
    for (size_t i = 0; i < sizeof(served); i++) {
        NSString* reply = SendRawDataRequest(server.port, requestWithValueByte(served[i]));
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 200"], @"byte 0x%02X is legal field content and must be served, got: %@", served[i], [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }

    [server stop];
}

// RFC 9112 §2.3 / RFC 9110 §2.5: a major version this server does not implement is refused with
// 505, and a message with a HIGHER MINOR version than the server implements is processed as the
// highest minor version the server is conformant to — i.e. HTTP/1.2 is served as HTTP/1.1, not
// refused. Both previously collapsed into 400, which tells the client its message was malformed
// when it was not. Grammar violations (a version that is not HTTP/DIGIT.DIGIT) must stay 400.
- (void)testUnsupportedHTTPVersionAnswers505AndAHigherMinorIsServedAs11 {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSArray<NSString*>* unsupported = @[@"HTTP/2.0", @"HTTP/3.0", @"HTTP/0.9"];
    for (NSString* version in unsupported) {
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /a %@\r\nHost: localhost\r\n\r\n", version]);
        XCTAssertTrue([reply containsString:@"505"], @"%@ must answer 505, got: %@", version, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }

    NSString* higherMinor = SendRawRequest(server.port, @"GET /a HTTP/1.2\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([higherMinor hasPrefix:@"HTTP/1.1 200"], @"HTTP/1.2 must be processed as HTTP/1.1, got: %@", [higherMinor substringToIndex:MIN((NSUInteger)40, higherMinor.length)]);

    NSArray<NSString*>* malformed = @[@"http/1.1", @"HTTP/1.x", @"HTTP/11.1"];
    for (NSString* version in malformed) {
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /a %@\r\nHost: localhost\r\n\r\n", version]);
        XCTAssertTrue([reply containsString:@"400"], @"%@ is a grammar violation and must stay 400, got: %@", version, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }

    [server stop];
}

// RFC 9112 §2.2: a server SHOULD ignore at least one empty line received before the
// request-line. The validator treated a leading CRLF as an empty block terminating at the
// request line's expense and refused the whole message.
- (void)testALeadingEmptyLineBeforeTheRequestLineIsIgnored {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* reply = SendRawRequest(server.port, @"\r\nGET /a HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 200"], @"a single leading CRLF must be ignored, got: %@", [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);

    [server stop];
}

// RFC 9112 §3.2: a request with more than one Host header line, or a Host whose field value is
// syntactically invalid, MUST answer 400. Both previously fell through to the allow-list and
// answered 421 — a refusal either way, but 421 invites the client to retry the same bytes at
// another origin, which a malformed message does not deserve. A well-formed name that is simply
// not on the allow-list must KEEP answering 421: that split is the point of this test.
- (void)testMultipleOrSyntacticallyInvalidHostHeadersAnswer400 {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSDictionary* badCases = @{
        @"two identical Host lines" : @"GET /a HTTP/1.1\r\nHost: localhost\r\nHost: localhost\r\n\r\n",
        @"two differing Host lines" : @"GET /a HTTP/1.1\r\nHost: localhost\r\nHost: evil.example\r\n\r\n",
        @"space inside the Host value" : @"GET /a HTTP/1.1\r\nHost: bad host value\r\n\r\n",
    };
    [badCases enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSString* raw, BOOL* stop) {
        NSString* reply = SendRawRequest(server.port, raw);
        XCTAssertTrue([reply containsString:@"400"], @"%@: expected 400, got: %@", name, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }];

    NSString* sane = SendRawRequest(server.port, @"GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([sane hasPrefix:@"HTTP/1.1 200"], @"a single valid Host must still be served: %@", [sane substringToIndex:MIN((NSUInteger)40, sane.length)]);

    NSString* misdirected = SendRawRequest(server.port, @"GET /a HTTP/1.1\r\nHost: other.example\r\n\r\n");
    XCTAssertTrue([misdirected containsString:@"421"], @"a well-formed but unrecognized name must stay 421, got: %@", [misdirected substringToIndex:MIN((NSUInteger)40, misdirected.length)]);

    [server stop];
}

// RFC 9112 §3.2.2: an origin server receiving an absolute-form request-target MUST ignore the
// Host header and use the target's authority instead. The authority was discarded and Host
// consulted, i.e. the more attacker-controlled of the two won. Not reachable from a browser
// (absolute-form is only sent to proxies), so the rebinding defence never depended on it — but
// the two positive assertions here pin the required direction both ways.
- (void)testAbsoluteFormTargetAuthorityOverridesTheHostHeader {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* foreignAuthority = SendRawRequest(server.port, @"GET http://evil.example/a HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([foreignAuthority containsString:@"421"], @"the absolute-form authority must be validated, not the Host header: %@", [foreignAuthority substringToIndex:MIN((NSUInteger)40, foreignAuthority.length)]);

    NSString* localAuthority = SendRawRequest(server.port, @"GET http://localhost/a HTTP/1.1\r\nHost: evil.example\r\n\r\n");
    XCTAssertTrue([localAuthority hasPrefix:@"HTTP/1.1 200"], @"with absolute-form the Host header must be ignored entirely: %@", [localAuthority substringToIndex:MIN((NSUInteger)40, localAuthority.length)]);

    NSString* originForm = SendRawRequest(server.port, @"GET /a HTTP/1.1\r\nHost: evil.example\r\n\r\n");
    XCTAssertTrue([originForm containsString:@"421"], @"origin-form must keep validating the Host header: %@", [originForm substringToIndex:MIN((NSUInteger)40, originForm.length)]);

    [server stop];
}

// RFC 9110 §15.5.15: a request-target longer than the server is willing to parse owes 414, not
// the 431 that covers an oversized header BLOCK. The two are distinguishable at refusal time:
// if no line terminator has arrived inside the whole block budget, it is the request line
// itself that is oversized. An oversized block whose request line is ordinary must stay 431.
- (void)testARequestTargetLongerThanTheHeaderCapAnswers414 {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* hugeTarget = [@"/" stringByPaddingToLength:(80 * 1024) withString:@"a" startingAtIndex:0];
    NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: localhost\r\n\r\n", hugeTarget]);
    XCTAssertTrue([reply containsString:@"414"], @"an oversized request-target owes 414, got: %@", [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);

    NSString* hugeHeader = [@"" stringByPaddingToLength:(80 * 1024) withString:@"A" startingAtIndex:0];
    NSString* blockReply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /a HTTP/1.1\r\nHost: localhost\r\nX-Big: %@\r\n\r\n", hugeHeader]);
    XCTAssertTrue([blockReply containsString:@"431"], @"an oversized block with an ordinary request line must stay 431, got: %@", [blockReply substringToIndex:MIN((NSUInteger)40, blockReply.length)]);

    [server stop];
}

// RFC 9112 §6.1: a transfer coding the server does not understand answers 501 Not Implemented —
// the request is well-formed, the server just cannot decode it, and 400 tells the client its
// message was broken when it was not. A malformed APPLICATION of a coding the server does
// implement ("chunked, chunked", or Content-Length alongside chunked) is the client's framing
// error and must stay 400.
- (void)testATransferCodingTheServerDoesNotImplementAnswers501 {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"ok"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSDictionary* notImplemented = @{
        @"gzip ahead of chunked" : @"GET /a HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        @"gzip alone" : @"GET /a HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\n\r\n",
    };
    [notImplemented enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSString* raw, BOOL* stop) {
        NSString* reply = SendRawRequest(server.port, raw);
        XCTAssertTrue([reply containsString:@"501"], @"%@: an unimplemented coding owes 501, got: %@", name, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }];

    NSDictionary* stillMalformed = @{
        @"chunked applied twice" : @"GET /a HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, chunked\r\n\r\n",
        @"Content-Length alongside chunked" : @"GET /a HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n",
    };
    [stillMalformed enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSString* raw, BOOL* stop) {
        NSString* reply = SendRawRequest(server.port, raw);
        XCTAssertTrue([reply containsString:@"400"], @"%@: a framing error must stay 400, got: %@", name, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }];

    [server stop];
}

// close(2) on a socket with unread inbound data makes the kernel send RST instead of FIN, and an
// RST destroys bytes already handed to TCP — including a response already delivered into the
// client's buffer. This predicate is the cheap guard that decides whether a connection needs to
// linger at all, so the ordinary case (nothing unread) keeps closing exactly as it always has.
- (void)testUnreadInboundDataIsDetected {
    int fds[2] = { -1, -1 };
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);

    XCTAssertFalse(WSKSocketHasUnreadInboundData(fds[0]), @"an idle socket has nothing unread");

    XCTAssertEqual(write(fds[1], "x", 1), (ssize_t)1);

    // Delivery through the socket layer is not instantaneous; poll briefly rather than sleeping a
    // fixed amount, so this cannot flake on a loaded machine.
    BOOL sawData = NO;
    for (int i = 0; (i < 200) && !sawData; i++) {
        sawData = WSKSocketHasUnreadInboundData(fds[0]);
        if (!sawData) {
            usleep(1000);
        }
    }
    XCTAssertTrue(sawData, @"a byte sitting in the receive queue must be reported");

    char scratch = 0;
    XCTAssertEqual(read(fds[0], &scratch, 1), (ssize_t)1);
    XCTAssertFalse(WSKSocketHasUnreadInboundData(fds[0]), @"draining the byte clears the condition");

    // A closed descriptor must answer NO rather than assert or report garbage: the caller uses this
    // to decide whether to do MORE work, so "cannot tell" has to mean "behave exactly as before".
    close(fds[0]);
    close(fds[1]);
    XCTAssertFalse(WSKSocketHasUnreadInboundData(fds[0]), @"an unusable descriptor must fail to NO");
}

// A header-time refusal answered while the client is still uploading is the measured case: the
// server writes a complete 400 and closes, but the client is still sending, so the receive queue is
// non-empty and close(2) emits RST — which destroys the response the client has not read yet.
// Measured on unfixed source: 391 bytes complete on one run, 167 bytes truncated mid-headers on the
// next. Because it is a race, this runs K trials and requires ALL of them to be clean.
- (void)testRefusalSurvivesWhileClientIsStillSending {
    NSString* directory = MakeTempDirectory();
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:directory];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSUInteger const trials = 20;
    NSUInteger clean = 0;
    NSMutableArray<NSString*>* failures = [NSMutableArray array];

    for (NSUInteger trial = 0; trial < trials; trial++) {
        int fd = ConnectToLocalhostPort(server.port);
        XCTAssertGreaterThan(fd, 0);

        // Content-Range on PUT is refused 400 in the connection layer, before any body is spooled,
        // so the server answers immediately while the body is still arriving. WebDAV is used
        // because it HANDLES PUT — on a server with no PUT handler this is a bodiless 501 abort
        // instead, which has no error page to lose and would make this test prove nothing.
        NSString* header = @"PUT /x.bin HTTP/1.1\r\nHost: localhost\r\nContent-Range: bytes 0-2/10\r\nContent-Length: 67108864\r\n\r\n";
        const char* headerBytes = [header UTF8String];
        XCTAssertEqual(send(fd, headerBytes, strlen(headerBytes), 0), (ssize_t)strlen(headerBytes));

        // Keep pushing body from another thread so the receive queue stays non-empty while the
        // server refuses and closes. SIGPIPE is disabled on this socket so a send after the peer
        // goes away fails rather than killing the test process.
        int const noSignal = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        dispatch_semaphore_t pumpDone = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char* chunk = malloc(65536);
            memset(chunk, 'Z', 65536);
            for (int i = 0; i < 1024; i++) {
                if (send(fd, chunk, 65536, 0) < 0) {
                    break;
                }
            }
            free(chunk);
            dispatch_semaphore_signal(pumpDone);
        });

        BOOL sawEOF = NO;
        NSData* reply = ReadToEOF(fd, &sawEOF);
        dispatch_semaphore_wait(pumpDone, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        close(fd);

        NSString* text = [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding];
        NSRange const separator = (text != nil) ? [text rangeOfString:@"\r\n\r\n"] : NSMakeRange(NSNotFound, 0);
        BOOL const rightStatus = (text != nil) && [text hasPrefix:@"HTTP/1.1 400"];

        // The ORACLE IS THE BODY, and this is the whole subtlety of this test. When the RST lands,
        // the reply truncates to exactly its 167 bytes of headers and loses the 224-byte error
        // page. A truncated reply therefore STILL starts "HTTP/1.1 400" and STILL contains the
        // header terminator — asserting on those two passes 80/80 against unfixed source and
        // detects nothing. Measured: 391 bytes with the body, 167 without, never anything between.
        NSUInteger const bodyLength = (separator.location == NSNotFound) ? 0 : (text.length - NSMaxRange(separator));

        if (rightStatus && (separator.location != NSNotFound) && (bodyLength > 0)) {
            clean += 1;
        } else if (failures.count < 3) {
            [failures addObject:[NSString stringWithFormat:@"trial %lu: %lu bytes, body=%lu, sawEOF=%@",
                                 (unsigned long)trial, (unsigned long)reply.length,
                                 (unsigned long)bodyLength, sawEOF ? @"YES" : @"NO"]];
        }
    }

    XCTAssertEqual(clean, trials, @"a refusal must reach the client intact every time: %@",
                   [failures componentsJoinedByString:@"; "]);

    [server stop];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

// Covers the OTHER linger call site, -abortRequest:withStatusCode:, which the test above never
// reaches (a Content-Range refusal is answered through -_finishProcessingRequest: instead). A PUT
// to a server registering only GET takes the unmatched-handler branch, which aborts 501 from inside
// the HEADER read, so the answer is written while the client is still uploading and the receive
// queue is non-empty at close.
//
// READ THIS BEFORE TRUSTING IT AS LINGER COVERAGE. This test does NOT discriminate the lingering
// close, and that was established by experiment rather than assumed: with
// -_beginLingeringCloseIfNeeded deleted from -abortRequest:withStatusCode: it still passes 20/20,
// and it still passes 20/20 with a 300 ms delay inserted before the client reads. The reason is
// structural — an abort response is bodiless by construction (110 bytes here), so it is handed to
// TCP in a single write and fully transmitted before close(2), leaving the RST nothing to destroy.
// The measured defect needed a SECOND write (the 224-byte error page) still sitting in the send
// buffer when the socket was closed.
//
// What it does prove: the abort path is driven end to end while a body is in flight, and its reply
// arrives complete rather than truncated mid-status. Server debug logs confirm the linger genuinely
// engages here — 18 of 20 trials log "Lingering before close" and hit the discard cap — so the call
// site is live and exercised; there is simply nothing left to lose by the time it runs.
- (void)testBodilessAbortIsDeliveredCompleteWhileClientIsStillSending {
    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[WSKRequest class]
                          processBlock:^WSKResponse*(WSKRequest* request) {
                              return [WSKDataResponse responseWithText:@"alive"];
                          }];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSUInteger const trials = 20;
    NSUInteger clean = 0;
    NSMutableArray<NSString*>* failures = [NSMutableArray array];

    for (NSUInteger trial = 0; trial < trials; trial++) {
        int fd = ConnectToLocalhostPort(server.port);
        XCTAssertGreaterThan(fd, 0);

        // No PUT handler is registered, so this is refused 501 before any body is spooled.
        NSString* header = @"PUT /x.bin HTTP/1.1\r\nHost: localhost\r\nContent-Length: 67108864\r\n\r\n";
        const char* headerBytes = [header UTF8String];
        XCTAssertEqual(send(fd, headerBytes, strlen(headerBytes), 0), (ssize_t)strlen(headerBytes));

        // Keep the receive queue non-empty while the server answers and closes.
        int const noSignal = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        dispatch_semaphore_t pumpDone = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char* chunk = malloc(65536);
            memset(chunk, 'Z', 65536);
            for (int i = 0; i < 1024; i++) {
                if (send(fd, chunk, 65536, 0) < 0) {
                    break;
                }
            }
            free(chunk);
            dispatch_semaphore_signal(pumpDone);
        });

        BOOL sawEOF = NO;
        NSData* reply = ReadToEOF(fd, &sawEOF);
        dispatch_semaphore_wait(pumpDone, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        close(fd);

        NSString* text = [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding];
        BOOL const rightStatus = (text != nil) && [text hasPrefix:@"HTTP/1.1 501"];
        BOOL const terminated = (text != nil) && ([text rangeOfString:@"\r\n\r\n"].location != NSNotFound);

        if (rightStatus && terminated) {
            clean += 1;
        } else if (failures.count < 3) {
            [failures addObject:[NSString stringWithFormat:@"trial %lu: %lu bytes, status=%@, terminated=%@",
                                 (unsigned long)trial, (unsigned long)reply.length,
                                 rightStatus ? @"YES" : @"NO", terminated ? @"YES" : @"NO"]];
        }
    }

    XCTAssertEqual(clean, trials, @"a bodiless abort must reach the client complete every time: %@",
                   [failures componentsJoinedByString:@"; "]);

    [server stop];
}

// A client that stops sending but never closes must not pin a connection slot for the whole idle
// timeout. Asserted through the SLOT returning, not wall-clock: this suite already has two timing
// tests that flake under load and must not gain a third. Descriptor count is the observable proxy —
// it returns to baseline only once the connection object is gone, which is what releases the slot.
//
// Two things about this oracle were wrong in earlier drafts and are recorded here rather than
// silently fixed, per this project's own rule about not re-importing a corrected story:
//
// 1) The baseline must be taken before connecting, AND the poll must compare against baseline + 1,
//    never baseline itself. fd (this test's own client socket) stays open until after the
//    assertion, so it is always one descriptor beyond whatever existed before the connection —
//    that "+1" is not slack, it is the known, permanent cost of the client's own socket, exactly
//    like -testSustainedServingDoesNotAccumulateResources tolerates its own bounded overhead
//    rather than demanding an exact return to baseline. Capturing the baseline AFTER connecting
//    was tried and measured worse, not better: accept() on this listening socket can complete fast
//    enough that the SERVER's own accepted-connection descriptor already exists by the time the
//    next line executes, silently folding it into "baseline" too — the assertion then trivially
//    passed on the FIRST poll regardless of whether the connection under test had released
//    anything, which is a worse failure mode (a bound that cannot help but hold) than the
//    always-fails-by-one shape a plain pre-connect baseline has without the "+1".
// 2) A single write immediately after the header races the server's OWN header read, which (like
//    the drain) hands over whatever has already arrived rather than waiting for more. On this
//    machine the two land together often enough that the write is read as PART OF the header parse
//    instead of staying unread for the lingering check to find: measured directly, one 4KB write
//    right after the header made "WSKSocketHasUnreadInboundData" answer NO and the connection close
//    the ordinary way, never lingering at all — the log showed "received 4191 bytes" (header +
//    filler) as ONE read. Many small writes in a tight loop (still comfortably under
//    kLingerDiscardCap, so the discard-cap exit is never hit either) reliably avoid this: the
//    per-call overhead of hundreds of separate send()s gives the server's header read time to fire
//    and complete on the header alone first.
- (void)testLingeringCloseReleasesItsSlotWhenTheClientGoesQuiet {
    NSString* directory = MakeTempDirectory();
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:directory];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSUInteger const baseline = OpenFileDescriptorCount();

    int fd = ConnectToLocalhostPort(server.port);
    XCTAssertGreaterThan(fd, 0);

    // Declare a huge body, send a little of it, then go silent WITHOUT closing. The refusal is
    // written immediately, the receive queue is non-empty, so the connection lingers — and then
    // nothing more ever arrives.
    NSString* header = @"PUT /x.bin HTTP/1.1\r\nHost: localhost\r\nContent-Range: bytes 0-2/10\r\nContent-Length: 67108864\r\n\r\n";
    const char* headerBytes = [header UTF8String];
    XCTAssertEqual(send(fd, headerBytes, strlen(headerBytes), 0), (ssize_t)strlen(headerBytes));

    int const noSignal = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    char filler[64];
    memset(filler, 'Z', sizeof(filler));
    for (int i = 0; i < 400; i++) {
        if (send(fd, filler, sizeof(filler), 0) < 0) {
            break;
        }
    }

    // Well inside the 30s idle timeout, so passing this cannot be the idle timer doing the work.
    // "baseline + 1" -- not "baseline" -- because fd itself is one descriptor beyond baseline for
    // as long as this test holds it open, which is deliberately until after this assertion; see the
    // comment above the method.
    BOOL released = NO;
    for (int i = 0; (i < 100) && !released; i++) {
        usleep(50 * 1000);
        released = (OpenFileDescriptorCount() <= baseline + 1);
    }

    XCTAssertTrue(released, @"a lingering connection must release its slot once the client goes quiet");

    close(fd);
    [server stop];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

@end
