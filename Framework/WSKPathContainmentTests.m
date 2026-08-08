// Path resolution and containment: symlinks, hidden items, NUL bytes, the extension allow-list.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import "TestsSupport.h"

@interface WSKPathContainmentTests : XCTestCase
@end

@implementation WSKPathContainmentTests

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
    // The catastrophe this test exists for is the share being EMPTIED — the ninth pass measured one
    // unauthenticated request taking a five-entry share to zero. That is now impossible by
    // construction rather than by a special-case refusal: a destructive verb resolves the PARENT and
    // acts on the entry the client named, so the share root is never the thing operated on. Removing
    // the alias itself is the correct answer to "DELETE /self" and is what `rm self` does; the
    // assertions below therefore check that the CONTENTS survive, not that the request was refused.
    NSString* deleted = SendRawRequest(dav.port, @"DELETE /self HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([deleted hasPrefix:@"HTTP/1.1 204"], @"DELETE of a self-referential link should remove the link: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);

    for (NSUInteger i = 0; i < 4; i++) {
        NSString* build = [davRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"build%lu.txt", (unsigned long)i]];
        XCTAssertTrue([fm fileExistsAtPath:build], @"the share was emptied by a DELETE through a link resolving to its root");
    }

    XCTAssertEqual(count(davRoot), (NSUInteger)4, @"exactly the alias should have gone");

    // Moving onto the alias replaces the alias. The share's other contents must be untouched.
    symlink(".", [[davRoot stringByAppendingPathComponent:@"self"] fileSystemRepresentation]);
    NSString* moved = SendRawRequest(dav.port, [NSString stringWithFormat:@"MOVE /build0.txt HTTP/1.1\r\nHost: localhost:%lu\r\nDestination: http://localhost:%lu/self\r\nOverwrite: T\r\n\r\n", (unsigned long)dav.port, (unsigned long)dav.port]);
    XCTAssertTrue([moved hasPrefix:@"HTTP/1.1 204"], @"MOVE onto a self-referential link should replace the link: %@", [moved substringToIndex:MIN((NSUInteger)40, moved.length)]);

    for (NSUInteger i = 1; i < 4; i++) {
        NSString* build = [davRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"build%lu.txt", (unsigned long)i]];
        XCTAssertTrue([fm fileExistsAtPath:build], @"the share was replaced by a MOVE onto a link resolving to its root");
    }

    XCTAssertEqualObjects([NSString stringWithContentsOfFile:[davRoot stringByAppendingPathComponent:@"self"] encoding:NSUTF8StringEncoding error:NULL], @"build 0", @"the alias was not replaced by the moved file");

    // The ordinary destructive operation must still work, or this has just disabled the feature.
    XCTAssertTrue([SendRawRequest(dav.port, @"DELETE /build1.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 204"], @"an ordinary DELETE stopped working");
    XCTAssertFalse([fm fileExistsAtPath:[davRoot stringByAppendingPathComponent:@"build1.txt"]], @"an ordinary DELETE did not remove the file");
    [dav stop];

    NSString* upRoot = fixture(@"up");
    WSKWebUploader* uploader = [[WSKWebUploader alloc] initWithUploadDirectory:upRoot];
    XCTAssertTrue([uploader startWithOptions:options error:NULL]);
    NSString* body = @"path=%2Fself";
    NSString* reply = SendRawRequest(uploader.port, [NSString stringWithFormat:@"POST /delete HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)body.length, body]);
    XCTAssertTrue([reply containsString:@"200"], @"the uploader should remove the alias: %@", [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);

    for (NSUInteger i = 0; i < 4; i++) {
        NSString* build = [upRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"build%lu.txt", (unsigned long)i]];
        XCTAssertTrue([fm fileExistsAtPath:build], @"the share was emptied by /delete through a link resolving to its root");
    }

    // Listing the root by name is still an ordinary operation and must not be caught by this.
    XCTAssertTrue([SendRawRequest(uploader.port, @"GET /list?path=/ HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 200"], @"listing the share root stopped working");
    [uploader stop];
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

// A symlink is an alias, so the verbs that REMOVE or RELOCATE one act on the entry the client named
// rather than on what it points at — `rm latest` removes the link, `mv a latest` replaces it — while
// reads still follow it. DELETE used to remove the multi-hundred-megabyte build directory and leave
// the dangling link behind, answering 204; no shell tool behaves that way, and the residue was then
// invisible to every listing and removable by nothing.
//
// And a symlink is now LISTED, classified by what it points at. It was served but omitted from all
// three enumerations, which through a real mounted client is data loss rather than cosmetics: `mv`
// returns 0 having copied only what the listing reported, then deletes the source.
//
// The dangerous part of this change is that it must not weaken containment, so that is asserted
// hardest: the parent is still resolved, so an escape through an intermediate link is still refused.
- (void)testSymlinksAreAliasesToDestructiveVerbsAndAppearInListings {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* parent = MakeTempDirectory();
    NSString* dir = [parent stringByAppendingPathComponent:@"share"];
    NSString* outside = [parent stringByAppendingPathComponent:@"outside"];
    XCTAssertTrue([fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([fm createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"SECRET" writeToFile:[outside stringByAppendingPathComponent:@"o.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSString* build = [dir stringByAppendingPathComponent:@"build"];
    XCTAssertTrue([fm createDirectoryAtPath:build withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"BUILD" writeToFile:[build stringByAppendingPathComponent:@"app.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"latest"] withDestinationPath:@"build" error:NULL]);
    XCTAssertTrue([fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"escape"] withDestinationPath:outside error:NULL]);

    WSKWebDAVServer* dav = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([dav startWithOptions:options error:NULL]);

    // Reading still FOLLOWS the link — that is what a link is for.
    XCTAssertTrue([SendRawRequest(dav.port, @"GET /latest/app.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"BUILD"], @"reading through a symlink stopped working");

    // The listing now advertises it, classified as the directory it points at.
    NSString* listing = SendRawRequest(dav.port, @"PROPFIND / HTTP/1.1\r\nHost: localhost\r\nDepth: 1\r\n\r\n");
    XCTAssertTrue([listing containsString:@"latest"], @"a served symlink must appear in the listing: %@", [listing substringToIndex:MIN((NSUInteger)200, listing.length)]);
    // ...but one pointing OUT of the share is not servable, so it is not advertised either.
    XCTAssertFalse([listing containsString:@"escape"], @"a symlink out of the share must not be advertised");

    // DELETE removes the ALIAS and preserves the target.
    NSString* deleted = SendRawRequest(dav.port, @"DELETE /latest HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([deleted hasPrefix:@"HTTP/1.1 204"], @"deleting a symlink should succeed: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);
    struct stat info;
    XCTAssertNotEqual(lstat([[dir stringByAppendingPathComponent:@"latest"] fileSystemRepresentation], &info), 0, @"the link itself was not removed");
    XCTAssertTrue([fm fileExistsAtPath:[build stringByAppendingPathComponent:@"app.txt"]], @"deleting the alias destroyed the target it pointed at");

    // MOVE renames the alias rather than the target.
    XCTAssertTrue([fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"current"] withDestinationPath:@"build" error:NULL]);
    NSString* moved = SendRawRequest(dav.port, @"MOVE /current HTTP/1.1\r\nHost: localhost\r\nDestination: /renamed\r\n\r\n");
    XCTAssertTrue([moved hasPrefix:@"HTTP/1.1 201"], @"moving a symlink should succeed: %@", [moved substringToIndex:MIN((NSUInteger)40, moved.length)]);
    XCTAssertEqual(lstat([[dir stringByAppendingPathComponent:@"renamed"] fileSystemRepresentation], &info), 0, @"the renamed alias is missing");
    XCTAssertTrue([fm fileExistsAtPath:build], @"the move relocated the target instead of the alias");

    // Moving ONTO an alias replaces the alias, not what it points at — the destination side.
    XCTAssertTrue([@"NEW" writeToFile:[dir stringByAppendingPathComponent:@"new.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSString* onto = SendRawRequest(dav.port, @"MOVE /new.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /renamed\r\nOverwrite: T\r\n\r\n");
    XCTAssertTrue([onto hasPrefix:@"HTTP/1.1 204"], @"moving onto a symlink should replace it: %@", [onto substringToIndex:MIN((NSUInteger)40, onto.length)]);
    XCTAssertTrue([fm fileExistsAtPath:[build stringByAppendingPathComponent:@"app.txt"]], @"moving onto an alias destroyed the directory it pointed at");
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"renamed"] encoding:NSUTF8StringEncoding error:NULL], @"NEW", @"the alias was not replaced by the moved file");

    // CONTAINMENT MUST BE EXACTLY AS STRONG. The parent is still resolved, so a write or a read
    // through a link that leaves the share is still refused, and the outside file is untouched.
    XCTAssertTrue([SendRawRequest(dav.port, @"PUT /escape/planted.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nBAD") hasPrefix:@"HTTP/1.1 403"], @"a write through an escaping symlink must still be refused");
    XCTAssertFalse([fm fileExistsAtPath:[outside stringByAppendingPathComponent:@"planted.txt"]], @"a write landed outside the share");
    XCTAssertFalse([SendRawRequest(dav.port, @"GET /escape/o.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"SECRET"], @"a read through an escaping symlink must still be refused");
    XCTAssertTrue([SendRawRequest(dav.port, @"DELETE /escape/o.txt HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 403"], @"a delete through an escaping symlink must still be refused");
    XCTAssertTrue([fm fileExistsAtPath:[outside stringByAppendingPathComponent:@"o.txt"]], @"a delete reached outside the share");

    [dav stop];
    [fm removeItemAtPath:parent error:NULL];
}

// -skipDescendants is defined for the most recently returned SUBDIRECTORY. Both subtree walks called
// it for every dot-name including regular FILES, which popped the enclosing level instead — so every
// entry after the first dot-name in that directory's readdir order was never vetted. A ".DS_Store"
// sits in every Finder-touched folder, so this was the ordinary case: DELETE of a collection holding
// "sub/{.DS_Store, id_rsa}" answered 204 and destroyed id_rsa, 60/60, while the same file addressed
// directly is refused 403 by the same server in the same configuration.
//
// NOTE THE FIXTURE. The victim MUST be one level down. testDAVRecursiveDeleteRespectsExtensionAllowList,
// testDAVOverwriteRespectsExtensionAllowList and testUploaderRecursiveDeleteRespectsExtensionAllowList
// all put theirs at the top of the collection, which is immune — all three pass against the unfixed
// code, which is exactly why this survived three passes that were looking straight at it.
- (void)testAllowListVettingSurvivesADotFileInASubdirectory {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();

    WSKWebDAVServer* dav = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    dav.allowedFileExtensions = @[ @"txt" ];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([dav startWithOptions:options error:NULL]);
    WSKWebUploader* uploader = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    uploader.allowedFileExtensions = @[ @"txt" ];
    XCTAssertTrue([uploader startWithOptions:options error:NULL]);

    NSString* vault = [dir stringByAppendingPathComponent:@"Vault"];
    NSString* sub = [vault stringByAppendingPathComponent:@"sub"];
    NSString* victim = [sub stringByAppendingPathComponent:@"id_rsa"];
    void (^rebuild)(void) = ^{
        [fm removeItemAtPath:vault error:NULL];
        XCTAssertTrue([fm createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:NULL]);
        XCTAssertTrue([@"ok" writeToFile:[vault stringByAppendingPathComponent:@"top.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        // The dot-file precedes the victim in readdir order, which is what suppressed it.
        XCTAssertTrue([@"junk" writeToFile:[sub stringByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        XCTAssertTrue([@"KEYDATA" writeToFile:victim atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    };

    // The control: addressed directly, this file is refused. The recursive forms must agree.
    rebuild();
    XCTAssertTrue([SendRawRequest(dav.port, @"DELETE /Vault/sub/id_rsa HTTP/1.1\r\nHost: localhost\r\n\r\n") hasPrefix:@"HTTP/1.1 403"], @"a direct delete of a disallowed file should be refused");

    NSString* deleted = SendRawRequest(dav.port, @"DELETE /Vault HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([deleted hasPrefix:@"HTTP/1.1 403"], @"DAV DELETE should refuse a collection holding a disallowed file one level down: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);
    XCTAssertTrue([fm fileExistsAtPath:victim], @"the recursive delete destroyed a file a direct delete refuses");

    rebuild();
    NSString* host = [NSString stringWithFormat:@"localhost:%lu", (unsigned long)uploader.port];
    NSString* body = @"path=/Vault";
    NSString* uploaderReply = SendRawRequest(uploader.port, [NSString stringWithFormat:@"POST /delete HTTP/1.1\r\nHost: %@\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n\r\n%@", host, (unsigned long)body.length, body]);
    XCTAssertTrue([uploaderReply containsString:@"403"], @"uploader /delete should refuse it too: %@", uploaderReply);
    XCTAssertTrue([fm fileExistsAtPath:victim], @"the uploader's recursive delete destroyed it");

    // The overwrite form: a collection destination whose name passes the allow-list.
    rebuild();
    XCTAssertTrue([fm moveItemAtPath:vault toPath:[dir stringByAppendingPathComponent:@"Backup.txt"] error:NULL]);
    XCTAssertTrue([@"src" writeToFile:[dir stringByAppendingPathComponent:@"src.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSString* moved = SendRawRequest(dav.port, @"MOVE /src.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /Backup.txt\r\nOverwrite: T\r\n\r\n");
    XCTAssertTrue([moved hasPrefix:@"HTTP/1.1 403"], @"an overwrite should refuse a destination holding a disallowed file one level down: %@", [moved substringToIndex:MIN((NSUInteger)40, moved.length)]);
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Backup.txt/sub/id_rsa"]], @"the overwrite destroyed it");

    // What must keep working — the eighth pass's two judgement calls, which this must not undo.
    // A folder whose only extra entry is filesystem noise stays deletable, at any depth...
    NSString* ordinary = [dir stringByAppendingPathComponent:@"Ordinary"];
    NSString* ordinarySub = [ordinary stringByAppendingPathComponent:@"sub"];
    XCTAssertTrue([fm createDirectoryAtPath:ordinarySub withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"ok" writeToFile:[ordinarySub stringByAppendingPathComponent:@"note.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"junk" writeToFile:[ordinarySub stringByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSString* allowed = SendRawRequest(dav.port, @"DELETE /Ordinary HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertFalse([allowed hasPrefix:@"HTTP/1.1 403"], @"a nested .DS_Store must not make an ordinary folder undeletable: %@", [allowed substringToIndex:MIN((NSUInteger)40, allowed.length)]);
    XCTAssertFalse([fm fileExistsAtPath:ordinary], @"the deletable folder was not removed");

    // ...and a hidden DIRECTORY and everything under it is still skipped wholesale.
    NSString* withHidden = [dir stringByAppendingPathComponent:@"WithHidden"];
    XCTAssertTrue([fm createDirectoryAtPath:[withHidden stringByAppendingPathComponent:@".git"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"ok" writeToFile:[withHidden stringByAppendingPathComponent:@"note.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"KEY" writeToFile:[withHidden stringByAppendingPathComponent:@".git/id_rsa"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSString* hiddenOK = SendRawRequest(dav.port, @"DELETE /WithHidden HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertFalse([hiddenOK hasPrefix:@"HTTP/1.1 403"], @"a hidden directory's contents must still be skipped: %@", [hiddenOK substringToIndex:MIN((NSUInteger)40, hiddenOK.length)]);

    [dav stop];
    [uploader stop];
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

// The base-path handler resolves the requested directory and enforces containment on the result,
// then appended the caller's indexFilename to it and served that WITHOUT resolving again — so a
// name containing a separator or ".." escaped the served root, since -attributesOfItemAtPath:
// follows intermediate components and WSKFileResponse's O_NOFOLLOW guards only the final one.
// Host-app configuration rather than client input, but the header states the guarantee flatly.
- (void)testIndexFilenameCannotEscapeTheServedDirectory {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* served = [root stringByAppendingPathComponent:@"served"];
    XCTAssertTrue([fm createDirectoryAtPath:served withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"INSIDE" writeToFile:[served stringByAppendingPathComponent:@"index.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"SECRET" writeToFile:[root stringByAppendingPathComponent:@"outside.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};

    // An escaping index name must not be served, and the directory listing stands in for it.
    WSKWebServer* escaping = [[WSKWebServer alloc] init];
    [escaping addGETHandlerForBasePath:@"/f/" directoryPath:served indexFilename:@"../outside.html" cacheAge:0 allowRangeRequests:NO];
    XCTAssertTrue([escaping startWithOptions:options error:NULL]);
    NSString* escaped = SendRawRequest(escaping.port, @"GET /f/ HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertFalse([escaped containsString:@"SECRET"], @"an index filename must not reach outside the served directory: %@", escaped);
    [escaping stop];

    // And the ordinary case must keep working — this is where an over-refusal would hide.
    WSKWebServer* ordinary = [[WSKWebServer alloc] init];
    [ordinary addGETHandlerForBasePath:@"/f/" directoryPath:served indexFilename:@"index.html" cacheAge:0 allowRangeRequests:NO];
    XCTAssertTrue([ordinary startWithOptions:options error:NULL]);
    XCTAssertTrue([SendRawRequest(ordinary.port, @"GET /f/ HTTP/1.1\r\nHost: localhost\r\n\r\n") containsString:@"INSIDE"], @"an ordinary index file is still served");
    [ordinary stop];

    [fm removeItemAtPath:root error:NULL];
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

    // A path several not-yet-existing components deep is WITHIN the directory, because it is: this
    // predicate answers containment, not existence. It used to answer NO purely because _RealPath
    // tolerated exactly one missing component, and this assertion pinned that cutoff as if it were
    // a rule — note the line above asserting YES for "Sub/new.txt", one level shallower, which is
    // the same question. That arbitrary boundary is what made GET, HEAD, PROPFIND, PROPPATCH and
    // DELETE answer 403 where 404 was owed.
    XCTAssertTrue(WSKResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Nope/deeper/x.txt"], dir));

    // What must NOT change: depth does not launder an escape. The same two-missing-component shape
    // through a link that leaves the directory is still refused, and so is one whose ancestor
    // escapes before the missing components even begin.
    XCTAssertFalse(WSKResolvedPathIsWithinDirectory([dir stringByAppendingPathComponent:@"Escape/nope/deeper/x.txt"], dir));
    XCTAssertFalse(WSKResolvedPathIsWithinDirectory([outside stringByAppendingPathComponent:@"nope/deeper/x.txt"], dir));

    [fm removeItemAtPath:outside error:NULL];
    [fm removeItemAtPath:dir error:NULL];
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

// The trailing-slash precondition was undocumented and enforced by WSK_DNOT_REACHED():
// abort with no diagnostic in Debug, and in Release it registered NOTHING and returned,
// so every request 404'd with the host app given no clue why.
- (void)testBasePathHandlerAcceptsABasePathWithoutATrailingSlash {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    [@"served" writeToFile:[dir stringByAppendingPathComponent:@"x.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    WSKWebServer* server = [[WSKWebServer alloc] init];
    XCTAssertNoThrow([server addGETHandlerForBasePath:@"/files" directoryPath:dir indexFilename:nil cacheAge:0 allowRangeRequests:YES]);
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* response = SendRawRequest(server.port, @"GET /files/x.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([response containsString:@"200"], @"a base path without a trailing slash must still serve: %@", [response substringToIndex:MIN((NSUInteger)40, response.length)]);
    XCTAssertTrue([response containsString:@"served"], @"the body must be the file's contents");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// "Advertise iff served": WSKServableFileTypeAtPath tested containment and not hiddenness, so a
// link whose own name carries no dot but which resolves INSIDE a dot-directory was advertised by
// all three listings and then refused 403 by every handler. Measured before the fix.
- (void)testListingDoesNotAdvertiseALinkResolvingIntoAHiddenDirectory {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* hidden = [dir stringByAppendingPathComponent:@".hidden"];
    [fm createDirectoryAtPath:hidden withIntermediateDirectories:YES attributes:nil error:NULL];
    [@"secret" writeToFile:[hidden stringByAppendingPathComponent:@"f.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"pub.txt"] withDestinationPath:[hidden stringByAppendingPathComponent:@"f.txt"] error:NULL];
    [@"ordinary" writeToFile:[dir stringByAppendingPathComponent:@"plain.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    WSKWebUploader* uploader = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([uploader startWithOptions:options error:NULL]);

    NSString* listing = SendRawRequest(uploader.port, @"GET /list?path=%2F HTTP/1.1\r\nHost: localhost\r\n\r\n");
    NSString* download = SendRawRequest(uploader.port, @"GET /download?path=%2Fpub.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");

    BOOL const advertised = [listing containsString:@"pub.txt"];
    BOOL const served = [download containsString:@" 200"];
    NSString* const detail = [NSString stringWithFormat:@"advertised=%d served=%d", advertised, served];
    XCTAssertEqual(advertised, served, @"a listing must advertise an entry if and only if the handler serves it: %@", detail);

    // An ordinary file must still be listed, or this could pass by listing nothing.
    XCTAssertTrue([listing containsString:@"plain.txt"], @"ordinary entries must still be advertised");

    [uploader stop];
    [fm removeItemAtPath:dir error:NULL];
}

// A symlink presents TWO names to the extension allow-list: the one the client used and the one the
// bytes live under. They were judged inconsistently — listings vetted the alias, access vetted the
// resolved target — so with ["txt"], "alias.txt -> real.bin" was advertised then refused 403 and
// "alias.bin -> real.txt" was hidden then served 200. Both must now pass, which is the fail-closed
// reading: judging the alias alone would make "alias.txt -> id_rsa" servable.
- (void)testExtensionAllowListJudgesBothNamesASymlinkPresents {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    [@"binary" writeToFile:[dir stringByAppendingPathComponent:@"real.bin"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"text" writeToFile:[dir stringByAppendingPathComponent:@"real.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"alias.txt"] withDestinationPath:[dir stringByAppendingPathComponent:@"real.bin"] error:NULL];
    [fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"alias.bin"] withDestinationPath:[dir stringByAppendingPathComponent:@"real.txt"] error:NULL];
    // The case that must KEEP working: both names allow-listed.
    [fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"good.txt"] withDestinationPath:[dir stringByAppendingPathComponent:@"real.txt"] error:NULL];

    WSKWebUploader* uploader = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    uploader.allowedFileExtensions = @[ @"txt" ];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([uploader startWithOptions:options error:NULL]);

    NSString* listing = SendRawRequest(uploader.port, @"GET /list?path=%2F HTTP/1.1\r\nHost: localhost\r\n\r\n");

    // Each row: name, must the listing advertise it, must the handler serve it.
    NSArray* rows = @[ @[ @"alias.txt", @NO ], @[ @"alias.bin", @NO ], @[ @"good.txt", @YES ], @[ @"real.txt", @YES ], @[ @"real.bin", @NO ] ];

    for (NSArray* row in rows) {
        NSString* name = row[0];
        BOOL expected = [row[1] boolValue];
        NSString* request = [NSString stringWithFormat:@"GET /download?path=%%2F%@ HTTP/1.1\r\nHost: localhost\r\n\r\n", name];
        NSString* download = SendRawRequest(uploader.port, request);

        BOOL const advertised = [listing containsString:name];
        BOOL const served = [download containsString:@" 200"];
        NSString* const detail = [NSString stringWithFormat:@"%@: advertised=%d served=%d expected=%d", name, advertised, served, expected];

        // The property that matters most: the listing and the handler must never disagree.
        XCTAssertEqual(advertised, served, @"listing must agree with the handler — %@", detail);
        XCTAssertEqual(served, expected, @"wrong verdict — %@", detail);
    }

    [uploader stop];
    [fm removeItemAtPath:dir error:NULL];
}

// _RealPath falls back to "resolve the parent, append the leaf" when realpath(3) fails, which is
// what lets a PUT to a not-yet-existing path resolve at all. A DANGLING symlink also fails
// realpath, so it took that branch and resolved INSIDE the share — making 404-vs-403 an existence
// oracle for the filesystem outside it: 403 when an escaping link's target existed, 404 when it
// did not. An entry that exists and cannot be resolved now fails closed.
//
// The second half of this test is the one that matters: the fallback must keep working, because a
// guard justified by one failure mode has to be checked against everything it then refuses.
- (void)testUnresolvableEntriesFailClosedWithoutBreakingCreation {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* share = [root stringByAppendingPathComponent:@"share"];
    NSString* outside = [root stringByAppendingPathComponent:@"outside"];
    [fm createDirectoryAtPath:[share stringByAppendingPathComponent:@"sub"] withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:NULL];
    [@"out" writeToFile:[outside stringByAppendingPathComponent:@"exists.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"in" writeToFile:[share stringByAppendingPathComponent:@"real.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [fm createSymbolicLinkAtPath:[share stringByAppendingPathComponent:@"esc-exists"] withDestinationPath:[outside stringByAppendingPathComponent:@"exists.txt"] error:NULL];
    [fm createSymbolicLinkAtPath:[share stringByAppendingPathComponent:@"esc-absent"] withDestinationPath:[outside stringByAppendingPathComponent:@"absent.txt"] error:NULL];

    WSKWebDAVServer* dav = [[WSKWebDAVServer alloc] initWithUploadDirectory:share];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([dav startWithOptions:options error:NULL]);

    NSString* present = SendRawRequest(dav.port, @"GET /esc-exists HTTP/1.1\r\nHost: localhost\r\n\r\n");
    NSString* absent = SendRawRequest(dav.port, @"GET /esc-absent HTTP/1.1\r\nHost: localhost\r\n\r\n");
    NSString* presentStatus = [present substringWithRange:NSMakeRange(9, 3)];
    NSString* absentStatus = [absent substringWithRange:NSMakeRange(9, 3)];
    NSString* detail = [NSString stringWithFormat:@"target-exists=%@ target-absent=%@", presentStatus, absentStatus];
    XCTAssertEqualObjects(presentStatus, absentStatus, @"the status must not reveal whether a file outside the share exists: %@", detail);
    XCTAssertEqualObjects(presentStatus, @"403", @"an escaping link must be refused: %@", detail);

    // The fallback exists so a path that does not exist yet can be created. If this regresses,
    // every PUT and MKCOL of a new name breaks — which is far worse than the oracle.
    NSArray* creations = @[ @[ @"PUT /brand-new.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\nhi", @"201" ],
                            @[ @"PUT /sub/nested.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\nhi", @"201" ],
                            @[ @"MKCOL /brand-new-dir HTTP/1.1\r\nHost: localhost\r\n\r\n", @"201" ],
                            @[ @"PUT /real.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\nhi", @"204" ],
                            @[ @"GET /real.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"200" ] ];

    for (NSArray* row in creations) {
        NSString* reply = SendRawRequest(dav.port, row[0]);
        NSString* status = (reply.length > 12) ? [reply substringWithRange:NSMakeRange(9, 3)] : reply;
        XCTAssertEqualObjects(status, row[1], @"the not-yet-exists fallback must keep working: %@ -> %@", [row[0] substringToIndex:MIN((NSUInteger)24, [row[0] length])], status);
    }

    [dav stop];
    [fm removeItemAtPath:root error:NULL];
}

// A path naming components that do not exist must answer "not found", not "forbidden". _RealPath
// tolerated exactly ONE missing trailing component; two or more returned nil and every WebDAV verb
// maps nil to 403. So the moment a client named a path two levels past anything real, "absent" and
// "refused" became the same answer -- and `rclone copy dav:/a/b` treats that 403 as fatal, the same
// way MKCOL's 500 used to break tree-building clients.
//
// Measured across the whole verb x depth matrix before the fix: GET, HEAD, PROPFIND and PROPPATCH
// answered 403 for every 2+-missing-component path, and DELETE did the same one level deeper (it
// resolves the parent itself, so it got one extra level for free). LOCK and UNLOCK answer 405 here
// and are NOT part of this class, though an earlier version of the record listed them.
//
// Three things this test pins that a narrower one would not:
//   - the WRITE verbs must keep answering 409 Conflict for a missing ancestor (RFC 4918 §9.7.1,
//     byte-identical to `rclone serve webdav`). Turning those into 404 would be a regression, and
//     it is the obvious way to overshoot this fix.
//   - a path through an escaping symlink must STILL be 403 at every depth, existence-independent.
//     The rejected fix -- a -fileExistsAtPath: parent precheck in each read verb -- reopens the
//     existence oracle precisely because that predicate answers for paths outside the share.
//   - the depth must be TWO OR MORE. A one-missing-component path already answered 404 before the
//     fix, so a test written against "/gone.txt" alone passes on unfixed code.
- (void)testAbsentPathsAnswerNotFoundRatherThanForbidden {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = MakeTempDirectory();
    NSString* share = [root stringByAppendingPathComponent:@"share"];
    NSString* outside = [root stringByAppendingPathComponent:@"outside"];
    [fm createDirectoryAtPath:[share stringByAppendingPathComponent:@"sub"] withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:NULL];
    [@"in" writeToFile:[share stringByAppendingPathComponent:@"real.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [fm createSymbolicLinkAtPath:[share stringByAppendingPathComponent:@"esc"] withDestinationPath:outside error:NULL];

    WSKWebDAVServer* dav = [[WSKWebDAVServer alloc] initWithUploadDirectory:share];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([dav startWithOptions:options error:NULL]);

    // {request, expected status, what it is}. Every read/property verb is driven at two and three
    // missing components; the destructive and creating verbs are driven for their own reasons.
    NSArray* cases = @[
        @[ @"GET /nodir/gone.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"404", @"GET, 2 missing" ],
        @[ @"GET /nodir/deeper/gone.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"404", @"GET, 3 missing" ],
        @[ @"GET /sub/nodir/gone.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"404", @"GET, 2 missing under a real dir" ],
        @[ @"HEAD /nodir/gone.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"404", @"HEAD, 2 missing" ],
        @[ @"PROPFIND /nodir/gone.txt HTTP/1.1\r\nHost: localhost\r\nDepth: 0\r\n\r\n", @"404", @"PROPFIND, 2 missing" ],
        @[ @"PROPPATCH /nodir/gone.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n", @"404", @"PROPPATCH, 2 missing" ],
        @[ @"DELETE /nodir/deeper/gone.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"404", @"DELETE, 3 missing" ],

        // Must NOT become 404: a missing ancestor is a conflict for a verb that would create.
        @[ @"PUT /nodir/gone.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\nhi", @"409", @"PUT with an absent parent" ],
        @[ @"MKCOL /nodir/deeper HTTP/1.1\r\nHost: localhost\r\n\r\n", @"409", @"MKCOL with an absent parent" ],
        @[ @"COPY /real.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /nodir/gone.txt\r\nOverwrite: T\r\n\r\n", @"409", @"COPY to an absent parent" ],
        @[ @"MOVE /real.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /nodir/gone.txt\r\nOverwrite: T\r\n\r\n", @"409", @"MOVE to an absent parent" ],

        // Must NOT become 404: depth does not launder an escape, and the answer may not depend on
        // what exists out there.
        @[ @"GET /esc/gone.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"403", @"GET through an escaping link" ],
        @[ @"GET /esc/nodir/deeper/gone.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"403", @"GET through an escaping link, 3 missing" ],
        @[ @"PUT /esc/gone.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\nhi", @"403", @"PUT through an escaping link" ],

        // The shallow case, which already worked, so a later change cannot quietly lose it.
        @[ @"GET /gone.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"404", @"GET, 1 missing" ],
        @[ @"GET /real.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", @"200", @"GET, exists" ],
    ];

    for (NSArray* row in cases) {
        NSString* reply = SendRawRequest(dav.port, row[0]);
        NSString* status = (reply.length > 12) ? [reply substringWithRange:NSMakeRange(9, 3)] : reply;
        XCTAssertEqualObjects(status, row[1], @"%@", row[2]);
    }

    // Nothing above may have written outside the share.
    XCTAssertEqualObjects([fm contentsOfDirectoryAtPath:outside error:NULL], @[], @"a refused request landed a file outside the share");

    [dav stop];
    [fm removeItemAtPath:root error:NULL];
}

@end
