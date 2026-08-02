// Basic and Digest auth, and the Host allow-list that makes an Origin check mean anything.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import "TestsSupport.h"

@interface WSKAuthenticationTests : XCTestCase
@end

@implementation WSKAuthenticationTests

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

// The MD5 helper hashed via -UTF8String + strlen, so an embedded NUL (which survives from
// the wire into request.headers) ended the hashed input early — for a Digest nonce that
// meant the per-process secret never reached the digest and its tag became forgeable.
- (void)testMD5DigestHashesPastEmbeddedNUL {
    unichar nul = 0;
    NSString* withNUL = [NSString stringWithFormat:@"abc%@def", [NSString stringWithCharacters:&nul length:1]];
    XCTAssertNotEqualObjects(WSKComputeMD5Digest(@"%@", withNUL), WSKComputeMD5Digest(@"%@", @"abc"),
                             @"input must not be truncated at the first NUL");
}

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

// The two sides of the Host allow-list disagreed: the CHECK side strips the DNS root label from
// the incoming header, the CONFIG side did not strip it from a WSKOption_AllowedHostNames entry.
// So an entry written as a fully-qualified name matched NOTHING — not even its own spelling — and
// every request answered 421. That is the one option a Tailscale deployment is required to set.
- (void)testAllowedHostNameEntryIsHonouredWithOrWithoutItsRootLabel {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    [@"served" writeToFile:[dir stringByAppendingPathComponent:@"x.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    WSKWebServer* server = [[WSKWebServer alloc] init];
    [server addGETHandlerForBasePath:@"/" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES, WSKOption_AllowedHostNames : @[ @"puck.tailnet.ts.net." ]};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* dotted = SendRawRequest(server.port, @"GET /x.txt HTTP/1.1\r\nHost: puck.tailnet.ts.net.\r\n\r\n");
    XCTAssertTrue([dotted containsString:@" 200"], @"the entry's own spelling must be admitted: %@", [dotted substringToIndex:MIN((NSUInteger)40, dotted.length)]);

    NSString* plain = SendRawRequest(server.port, @"GET /x.txt HTTP/1.1\r\nHost: puck.tailnet.ts.net\r\n\r\n");
    XCTAssertTrue([plain containsString:@" 200"], @"the spelling browsers send must be admitted: %@", [plain substringToIndex:MIN((NSUInteger)40, plain.length)]);

    // A name that is genuinely not on the list must still be refused, or this passes by admitting all.
    NSString* other = SendRawRequest(server.port, @"GET /x.txt HTTP/1.1\r\nHost: evil.example\r\n\r\n");
    XCTAssertTrue([other containsString:@" 421"], @"an unlisted name must still be refused: %@", [other substringToIndex:MIN((NSUInteger)40, other.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

@end
