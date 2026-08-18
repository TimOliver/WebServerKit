// The upload interface: its endpoints, its page, and its cross-origin defences.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import "TestsSupport.h"

#import <objc/runtime.h>

// A full volume or exhausted quota must reach the client as 507, not 500 — a 5xx server-fault code
// invites the client to retry an upload that cannot succeed until space is freed. The mapping
// function WSKServerErrorStatusCodeForError was always correct and is unit-tested separately; what
// this pins is that the uploader's write ENDPOINTS actually ROUTE their moveItem failures through
// it. They hardcoded 500, so the mapping existed but /upload, /move and /create never consulted it.
//
// The error is INJECTED rather than reproduced with a real small volume: hdiutil in a unit test is
// slow and fragile on CI, and the thing under test is the call-site routing, not the filesystem.
// Only -moveItemAtPath:toPath:error: is swizzled and only while armed, so the multipart temp write
// (raw open/write/close) and all test setup are untouched.
static BOOL gWSKInjectOutOfSpace = NO;
static IMP gWSKOriginalMoveIMP = NULL;

static BOOL WSKInjectingMove(id self, SEL _cmd, NSString* src, NSString* dst, NSError** err) {
    if (gWSKInjectOutOfSpace) {
        if (err) {
            *err = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:nil];
        }
        return NO;
    }
    // Cast through void * : -Wcast-function-type-strict rejects a direct IMP-to-prototype cast,
    // which is unavoidable for a swizzle that must call the original.
    return ((BOOL (*)(id, SEL, NSString*, NSString*, NSError**))(void *)gWSKOriginalMoveIMP)(self, _cmd, src, dst, err);
}

@interface WSKUploaderTests : XCTestCase
@end

@implementation WSKUploaderTests

- (void)testWebUploader {
    NSString *const dir = MakeTempDirectory();
    WSKWebUploader *const server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];

    XCTAssertNotNil(server);
    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
}

// The uploader's /download built its response with +responseWithFile:isAttachment:, which passes
// NSMakeRange(NSUIntegerMax, 0) — no range at all — so a "Range" header was ignored and the whole
// file came back 200. The base-path handler and DAV's GET have both passed request.byteRange and
// request.ifRange for several passes; this endpoint never did. For Shape A that means an
// interrupted download of a multi-hundred-megabyte build cannot resume, and it is also why a
// <video> cannot seek. Going through the ifRange: variant is what brings the If-Range protection
// with it, so a resume against a REPLACED file is refused rather than spliced.
- (void)testUploaderDownloadHonoursRangeRequests {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"0123456789" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* partial = SendRawRequest(server.port, @"GET /download?path=%2Fa.txt HTTP/1.1\r\nHost: localhost\r\nRange: bytes=2-5\r\n\r\n");
    XCTAssertTrue([partial hasPrefix:@"HTTP/1.1 206"], @"a Range request must be answered with 206: %@", [partial substringToIndex:MIN((NSUInteger)40, partial.length)]);
    XCTAssertTrue([partial containsString:@"Content-Range: bytes 2-5/10"], @"the 206 must describe which bytes it carries: %@", partial);
    XCTAssertTrue([partial hasSuffix:@"2345"], @"the 206 must carry exactly the requested bytes: %@", partial);

    // An open-ended range is how a resume is actually spelled.
    NSString* resume = SendRawRequest(server.port, @"GET /download?path=%2Fa.txt HTTP/1.1\r\nHost: localhost\r\nRange: bytes=7-\r\n\r\n");
    XCTAssertTrue([resume hasPrefix:@"HTTP/1.1 206"], @"an open-ended resume must be 206: %@", [resume substringToIndex:MIN((NSUInteger)40, resume.length)]);
    XCTAssertTrue([resume hasSuffix:@"789"], @"the resume must carry the tail: %@", resume);

    // Unsatisfiable is 416 with the total, not a silent whole-file 200.
    NSString* beyond = SendRawRequest(server.port, @"GET /download?path=%2Fa.txt HTTP/1.1\r\nHost: localhost\r\nRange: bytes=999-\r\n\r\n");
    XCTAssertTrue([beyond hasPrefix:@"HTTP/1.1 416"], @"an unsatisfiable range is 416: %@", [beyond substringToIndex:MIN((NSUInteger)40, beyond.length)]);

    // And what must keep working: no Range header still serves the whole file as an attachment.
    NSString* whole = SendRawRequest(server.port, @"GET /download?path=%2Fa.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([whole hasPrefix:@"HTTP/1.1 200"], @"an ordinary download is unchanged: %@", [whole substringToIndex:MIN((NSUInteger)40, whole.length)]);
    XCTAssertTrue([whole containsString:@"attachment"], @"an ordinary download is still an attachment");
    XCTAssertTrue([whole hasSuffix:@"0123456789"], @"an ordinary download still carries the whole file");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// Rendering a shared file INLINE puts it in the server's own origin, and this UI's one-click
// buttons delete and move files — so an uploaded .html or .svg served inline is stored XSS against
// the share itself. That is the whole reason /download forces "attachment", and it is also why a
// media-rich UI cannot simply drop the flag: <img src="/download?..."> triggers a save dialog
// rather than rendering.
//
// /preview is the narrow, inert-only alternative: an allow-list of types a browser cannot execute,
// plus nosniff so a .png full of markup cannot be sniffed into active content, plus a CSP that
// denies everything even if a type ever slips through. SVG is deliberately excluded despite being
// an image — it carries script, and it is the exact trap an "images are safe" allow-list springs.
- (void)testUploaderPreviewServesInertMediaInlineAndRefusesActiveContent {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    // Deliberately ASCII rather than real PNG bytes: the type is derived from the EXTENSION, so
    // the content is irrelevant to what is being tested, and binary would make the reply
    // undecodable as a string and every assertion below read "(null)".
    XCTAssertTrue([@"PIXELS" writeToFile:[dir stringByAppendingPathComponent:@"pic.png"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"<script>alert(1)</script>" writeToFile:[dir stringByAppendingPathComponent:@"evil.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>" writeToFile:[dir stringByAppendingPathComponent:@"evil.svg"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@".hidden"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"SECRET" writeToFile:[dir stringByAppendingPathComponent:@".hidden/secret.png"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* image = SendRawRequest(server.port, @"GET /preview?path=%2Fpic.png HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([image hasPrefix:@"HTTP/1.1 200"], @"an inert image must render: %@", [image substringToIndex:MIN((NSUInteger)40, image.length)]);
    XCTAssertTrue([image containsString:@"Content-Disposition: inline"], @"the whole point is inline disposition: %@", image);
    XCTAssertFalse([image containsString:@"attachment"], @"an inline preview must not also say attachment");
    XCTAssertTrue([image containsString:@"X-Content-Type-Options: nosniff"], @"inline content must never be sniffable");
    XCTAssertTrue([image containsString:@"Content-Type: image/png"], @"the type must be stated so nosniff has something to pin: %@", image);
    XCTAssertTrue([image containsString:@"Content-Security-Policy:"], @"inline content gets a policy that denies everything");

    // Active content is refused outright — including SVG, which is an image and is NOT inert.
    for (NSString* active in @[ @"%2Fevil.html", @"%2Fevil.svg" ]) {
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /preview?path=%@ HTTP/1.1\r\nHost: localhost\r\n\r\n", active]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 403"], @"%@ must not be served inline: %@", active, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
        XCTAssertFalse([reply containsString:@"alert(1)"], @"%@ must not have its body reflected either", active);
    }

    // But /download still serves them, as attachments — refusing inline must not remove the file
    // from the share, only from the inline surface.
    NSString* downloaded = SendRawRequest(server.port, @"GET /download?path=%2Fevil.svg HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([downloaded hasPrefix:@"HTTP/1.1 200"], @"the file is still downloadable: %@", [downloaded substringToIndex:MIN((NSUInteger)40, downloaded.length)]);
    XCTAssertTrue([downloaded containsString:@"attachment"], @"…as an attachment");

    // Every refusal /download makes, /preview makes too: it is a second door to the same files.
    XCTAssertTrue([SendRawRequest(server.port, @"GET /preview?path=%2F.hidden%2Fsecret.png HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 403"], @"a hidden path is refused on the preview surface too");
    XCTAssertTrue([SendRawRequest(server.port, @"GET /preview?path=%2Fnope.png HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 404"], @"a missing file is still 404");

    // Range works here too, because that is what a <video> needs to seek.
    NSString* ranged = SendRawRequest(server.port, @"GET /preview?path=%2Fpic.png HTTP/1.1\r\nHost: localhost\r\nRange: bytes=1-3\r\n\r\n");
    XCTAssertTrue([ranged hasPrefix:@"HTTP/1.1 206"], @"preview must honour Range: %@", [ranged substringToIndex:MIN((NSUInteger)40, ranged.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// Caching is opt-in, and the default must stay as it was. A share is mutable — files are uploaded,
// moved and deleted through this very UI — so a max-age the caller did not ask for would hand a
// browser a window in which it serves content the share no longer holds, with no request to notice
// it. Left at 0, every response still says no-cache, which does NOT mean "do not store": the
// browser keeps the body and revalidates with If-None-Match, so a thumbnail grid already costs 304s
// rather than bodies. What max-age buys is removing the request itself, which is the caller's call.
- (void)testUploaderFileCacheControlMaxAgeIsOptIn {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"PIXELS" writeToFile:[dir stringByAppendingPathComponent:@"pic.png"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    XCTAssertEqual(server.fileCacheControlMaxAge, (NSUInteger)0, @"the default must be no caching directive");

    for (NSString* endpoint in @[ @"download", @"preview" ]) {
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /%@?path=%%2Fpic.png HTTP/1.1\r\nHost: localhost\r\n\r\n", endpoint]);
        XCTAssertTrue([reply containsString:@"Cache-Control: no-cache"], @"/%@ must revalidate by default: %@", endpoint, reply);
    }

    [server stop];

    server.fileCacheControlMaxAge = 3600;
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    for (NSString* endpoint in @[ @"download", @"preview" ]) {
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /%@?path=%%2Fpic.png HTTP/1.1\r\nHost: localhost\r\n\r\n", endpoint]);
        XCTAssertTrue([reply containsString:@"max-age=3600"], @"/%@ must honour the configured age: %@", endpoint, reply);
    }

    // A revalidation still works and still answers 304, so a client that asks anyway is told the
    // truth rather than handed the body again.
    // CFHTTPMessage standardizes the field name, so it goes out as "Etag" rather than the "ETag"
    // the source spells — match case-insensitively rather than pinning CF's choice.
    NSString* first = SendRawRequest(server.port, @"GET /preview?path=%2Fpic.png HTTP/1.1\r\nHost: localhost\r\n\r\n");
    NSRange const tagRange = [first rangeOfString:@"etag: " options:NSCaseInsensitiveSearch];
    XCTAssertNotEqual(tagRange.location, (NSUInteger)NSNotFound, @"a file response carries an entity tag: %@", first);

    if (tagRange.location != NSNotFound) {
        NSString* tail = [first substringFromIndex:NSMaxRange(tagRange)];
        NSString* tag = [tail substringToIndex:[tail rangeOfString:@"\r\n"].location];
        NSString* revalidated = SendRawRequest(server.port, [NSString stringWithFormat:@"GET /preview?path=%%2Fpic.png HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: %@\r\n\r\n", tag]);
        XCTAssertTrue([revalidated hasPrefix:@"HTTP/1.1 304"], @"an unchanged preview revalidates to 304: %@", [revalidated substringToIndex:MIN((NSUInteger)40, revalidated.length)]);
    }

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
    //
    // This used to assert "not 404", which worked only while an unmatched request answered 501.
    // Now that an unmatched request answers 404 when the method exists elsewhere — and the
    // uploader does register POST handlers — that proxy cannot tell "the catch-all declined" from
    // "the catch-all claimed it". Assert the property directly instead: a POST to a path the
    // catch-all WOULD serve for a GET must not come back with that path's contents.
    NSString* postedToRealAsset = SendRawRequest(server.port, [NSString stringWithFormat:@"POST /css/index.css HTTP/1.1\r\nHost: %@\r\nContent-Length: 0\r\n\r\n", host]);
    XCTAssertFalse([postedToRealAsset hasPrefix:@"HTTP/1.1 200"], @"the catch-all must not serve a non-GET method: %@", [postedToRealAsset substringToIndex:MIN((NSUInteger)40, postedToRealAsset.length)]);

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

// Batch C added realpath([_uploadDirectory fileSystemRepresentation], ...) to the initializer with
// no guard — and -fileSystemRepresentation RAISES for an empty or NUL-bearing receiver. That is
// precisely the class batch A existed to close, re-opened three files from the comment explaining
// it. Fifth recurrence of this codebase's most repeated defect, and the first self-inflicted one.
- (void)testUploaderInitDoesNotRaiseForAnUnusablePath {
    XCTAssertNoThrow([[WSKWebUploader alloc] initWithUploadDirectory:@""]);

    unichar const nulBearing[] = {'/', 't', 'm', 'p', '/', 0, 'x'};
    NSString* nulPath = [NSString stringWithCharacters:nulBearing length:(sizeof(nulBearing) / sizeof(nulBearing[0]))];
    XCTAssertNoThrow([[WSKWebUploader alloc] initWithUploadDirectory:nulPath]);

    // An ordinary share must still resolve, or this could pass by refusing everything.
    NSString* dir = MakeTempDirectory();
    WSKWebUploader* ok = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    XCTAssertNotNil(ok);
    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
}

- (void)testUploadOntoAFullVolumeIs507NotServerError {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    WSKWebUploader* server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    Method move = class_getInstanceMethod([NSFileManager class], @selector(moveItemAtPath:toPath:error:));
    gWSKOriginalMoveIMP = method_getImplementation(move);
    method_setImplementation(move, (IMP)(void *)WSKInjectingMove);

    NSString* boundary = @"----wskfulltest";
    NSString* head = [NSString stringWithFormat:
        @"--%@\r\nContent-Disposition: form-data; name=\"files[]\"; filename=\"x.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n", boundary];
    NSString* tail = [NSString stringWithFormat:@"\r\n--%@--\r\n", boundary];
    NSString* payload = @"some bytes that cannot land";
    NSString* body = [NSString stringWithFormat:@"%@%@%@", head, payload, tail];
    NSString* request = [NSString stringWithFormat:
        @"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=%@\r\nContent-Length: %lu\r\n\r\n%@",
        boundary, (unsigned long)strlen(body.UTF8String), body];

    gWSKInjectOutOfSpace = YES;
    NSString* reply = SendRawRequest(server.port, request);
    gWSKInjectOutOfSpace = NO;

    // Restore before any assertion can bail, or a failure leaves the whole suite swizzled.
    method_setImplementation(move, gWSKOriginalMoveIMP);

    XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 507"], @"a full volume must be 507 Insufficient Storage, not a server fault: %@",
                  [reply substringToIndex:MIN((NSUInteger)50, reply.length)]);
    // Nothing may have landed, and the injected failure must not have left the temp behind — the
    // reliability half of the same guarantee.
    XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:dir error:NULL], @[], @"a refused upload left residue in the share");

    // And the endpoint still works once space is available, so the routing change did not break the
    // success path.
    NSString* ok = SendRawRequest(server.port, request);
    XCTAssertTrue([ok hasPrefix:@"HTTP/1.1 200"], @"an ordinary upload must still succeed: %@", [ok substringToIndex:MIN((NSUInteger)50, ok.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

@end
