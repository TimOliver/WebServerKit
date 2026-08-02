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
                                                         url:[NSURL URLWithString:@"http://localhost/x"]
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

@end
