// WebDAV method semantics, status conformance, and the destructive verbs.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import "TestsSupport.h"

@interface WSKWebDAVTests : XCTestCase
@end

@implementation WSKWebDAVTests

- (void)testDAVServer {
    WSKWebDAVServer *server = [[WSKWebDAVServer alloc] init];

    XCTAssertNotNil(server);
}

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

// PROPPATCH, the last class-1 MUST this server did not meet: it was 501 while OPTIONS advertised
// "DAV: 1". Dead properties are stored in one extended attribute holding a plist keyed in Clark
// notation, so a set of them is written in a single call and cannot half-apply.
- (void)testDAVProppatchStoresAndRemovesDeadProperties {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"data" writeToFile:[dir stringByAppendingPathComponent:@"f.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* (^send)(NSString*, NSString*) = ^(NSString* method, NSString* body) {
        return SendRawRequest(server.port, [NSString stringWithFormat:@"%@ /f.txt HTTP/1.1\r\nHost: localhost\r\nDepth: 0\r\nContent-Type: application/xml\r\nContent-Length: %lu\r\n\r\n%@", method, (unsigned long)body.length, body]);
    };

    // Set two dead properties, one in a foreign namespace.
    NSString* set = send(@"PROPPATCH", @"<?xml version=\"1.0\"?><D:propertyupdate xmlns:D=\"DAV:\" xmlns:X=\"urn:example\"><D:set><D:prop><X:colour>blue</X:colour><X:rating>5</X:rating></D:prop></D:set></D:propertyupdate>");
    XCTAssertTrue([set hasPrefix:@"HTTP/1.1 207"], @"PROPPATCH should answer 207: %@", [set substringToIndex:MIN((NSUInteger)40, set.length)]);
    XCTAssertTrue([set containsString:@"200 OK"], @"the set should have applied: %@", set);

    // ...and read them back, by name and via allprop.
    NSString* named = send(@"PROPFIND", @"<?xml version=\"1.0\"?><D:propfind xmlns:D=\"DAV:\" xmlns:X=\"urn:example\"><D:prop><X:colour/></D:prop></D:propfind>");
    XCTAssertTrue([named containsString:@"blue"], @"a stored property must be readable by name: %@", named);
    XCTAssertFalse([named containsString:@"404"], @"a stored property must not be reported missing: %@", named);

    NSString* all = send(@"PROPFIND", @"<?xml version=\"1.0\"?><D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>");
    XCTAssertTrue([all containsString:@"blue"], @"allprop must include stored properties: %@", all);
    XCTAssertTrue([all containsString:@"urn:example"], @"the namespace must survive the round trip");

    // Remove one; the other survives.
    NSString* removed = send(@"PROPPATCH", @"<?xml version=\"1.0\"?><D:propertyupdate xmlns:D=\"DAV:\" xmlns:X=\"urn:example\"><D:remove><D:prop><X:colour/></D:prop></D:remove></D:propertyupdate>");
    XCTAssertTrue([removed hasPrefix:@"HTTP/1.1 207"], @"remove should answer 207");
    NSString* after = send(@"PROPFIND", @"<?xml version=\"1.0\"?><D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>");
    XCTAssertFalse([after containsString:@"blue"], @"the removed property is still there: %@", after);
    XCTAssertTrue([after containsString:@"5"], @"removing one property destroyed the other: %@", after);

    // A live property is derived from the filesystem and cannot be set: 403, and ATOMIC, so the
    // dead property alongside it must NOT have been stored either.
    NSString* live = send(@"PROPPATCH", @"<?xml version=\"1.0\"?><D:propertyupdate xmlns:D=\"DAV:\" xmlns:X=\"urn:example\"><D:set><D:prop><D:getcontentlength>99</D:getcontentlength><X:sneaked>yes</X:sneaked></D:prop></D:set></D:propertyupdate>");
    XCTAssertTrue([live containsString:@"403 Forbidden"], @"a live property must be refused: %@", live);
    XCTAssertTrue([live containsString:@"424 Failed Dependency"], @"the rest of an atomic update must report 424: %@", live);
    NSString* unchanged = send(@"PROPFIND", @"<?xml version=\"1.0\"?><D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>");
    XCTAssertFalse([unchanged containsString:@"sneaked"], @"a refused PROPPATCH still stored a property — it is not atomic: %@", unchanged);

    // propname lists the stored names, and the live ones.
    NSString* names = send(@"PROPFIND", @"<?xml version=\"1.0\"?><D:propfind xmlns:D=\"DAV:\"><D:propname/></D:propfind>");
    XCTAssertTrue([names containsString:@"rating"], @"propname must list stored property names: %@", names);
    XCTAssertTrue([names containsString:@"getcontentlength"], @"propname must still list the live names");

    // And a property this server has never been told about is still a 404, not a silent omission.
    NSString* missing = send(@"PROPFIND", @"<?xml version=\"1.0\"?><D:propfind xmlns:D=\"DAV:\" xmlns:X=\"urn:example\"><D:prop><X:nosuch/></D:prop></D:propfind>");
    XCTAssertTrue([missing containsString:@"404 Not Found"], @"an unknown property must still be reported missing: %@", missing);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// RFC 4918 class 1 completeness, minus PROPPATCH which needs storage of its own. Each of these was
// a documented MUST that this server did not meet while OPTIONS advertised "DAV: 1".
- (void)testDAVClassOnePropfindAndDepthSemantics {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"data" writeToFile:[dir stringByAppendingPathComponent:@"f.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"coll"] withIntermediateDirectories:YES attributes:nil error:NULL]);

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* (^propfind)(NSString*, NSString*) = ^(NSString* depth, NSString* body) {
        return SendRawRequest(server.port, [NSString stringWithFormat:@"PROPFIND /f.txt HTTP/1.1\r\nHost: localhost\r\nDepth: %@\r\nContent-Type: application/xml\r\nContent-Length: %lu\r\n\r\n%@", depth, (unsigned long)body.length, body]);
    };

    // A property that cannot be returned gets its own propstat with 404, rather than being dropped
    // from a <prop> the response then declares "200 OK".
    NSString* mixed = propfind(@"0", @"<?xml version=\"1.0\"?><D:propfind xmlns:D=\"DAV:\"><D:prop><D:getcontentlength/><D:getetag/><X:custom xmlns:X=\"urn:example\"/></D:prop></D:propfind>");
    XCTAssertTrue([mixed hasPrefix:@"HTTP/1.1 207"], @"PROPFIND stopped working: %@", [mixed substringToIndex:MIN((NSUInteger)40, mixed.length)]);
    XCTAssertTrue([mixed containsString:@"getcontentlength"], @"the supported property is missing");
    XCTAssertTrue([mixed containsString:@"404 Not Found"], @"an unavailable property must be reported in a 404 propstat: %@", mixed);
    XCTAssertTrue([mixed containsString:@"getetag"], @"the unavailable property must be named back");
    XCTAssertTrue([mixed containsString:@"urn:example"], @"a foreign namespace must survive into the 404 propstat");

    // <propname/> returns the names with empty values, and used to be refused with 400.
    NSString* names = propfind(@"0", @"<?xml version=\"1.0\"?><D:propfind xmlns:D=\"DAV:\"><D:propname/></D:propfind>");
    XCTAssertTrue([names hasPrefix:@"HTTP/1.1 207"], @"propname should be supported: %@", [names substringToIndex:MIN((NSUInteger)40, names.length)]);
    XCTAssertTrue([names containsString:@"getcontentlength"], @"propname must list the property names");
    XCTAssertFalse([names containsString:@"404"], @"propname reports names, not failures: %@", names);

    // Depth: infinity is refused with the machine-readable precondition RFC 4918 §9.1 defines.
    NSString* infinite = propfind(@"infinity", @"<?xml version=\"1.0\"?><D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>");
    XCTAssertTrue([infinite hasPrefix:@"HTTP/1.1 403"], @"an infinite-depth PROPFIND should be 403: %@", [infinite substringToIndex:MIN((NSUInteger)40, infinite.length)]);
    XCTAssertTrue([infinite containsString:@"propfind-finite-depth"], @"the refusal must carry the precondition element: %@", infinite);

    // Depth: 0 is meaningless for a plain file, so it must not make DELETE or COPY unusable.
    XCTAssertTrue([SendRawRequest(server.port, @"COPY /f.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /copy.txt\r\nDepth: 0\r\n\r\n") hasPrefix:@"HTTP/1.1 201"], @"COPY of a file with Depth: 0 should be allowed");
    XCTAssertTrue([SendRawRequest(server.port, @"DELETE /copy.txt HTTP/1.1\r\nHost: localhost\r\nDepth: 0\r\n\r\n") hasPrefix:@"HTTP/1.1 204"], @"DELETE with Depth: 0 should be allowed");
    // ...and a nonsense Depth is still refused.
    XCTAssertTrue([SendRawRequest(server.port, @"DELETE /f.txt HTTP/1.1\r\nHost: localhost\r\nDepth: 7\r\n\r\n") hasPrefix:@"HTTP/1.1 400"], @"an unrecognised Depth should still be refused");

    // Allow, on OPTIONS and on the 405.
    NSString* opts = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([opts containsString:@"Allow:"], @"OPTIONS should advertise Allow: %@", opts);
    XCTAssertTrue([opts containsString:@"PROPFIND"], @"Allow should name the DAV methods");
    NSString* onCollection = SendRawRequest(server.port, @"PUT /coll HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\nx");
    XCTAssertTrue([onCollection hasPrefix:@"HTTP/1.1 405"], @"PUT onto a collection should still be 405");
    XCTAssertTrue([onCollection containsString:@"Allow:"], @"a 405 must carry Allow (RFC 9110 §15.5.6): %@", onCollection);

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

// RFC 4918 §9.3.1: MKCOL on a URL that already identifies a resource MUST answer 405. This
// answered 500, because createDirectoryAtPath:withIntermediateDirectories:NO fails with
// NSFileWriteFileExistsError and the error mapping recognises only the full-volume cases, so
// EEXIST fell through to the 500 fallback. The cost is not cosmetic: "MKCOL each ancestor and
// treat 405 as already-exists" is the universal way a client creates a directory tree, and a 5xx
// says the SERVER broke rather than "it is already there" — so rclone and anything shaped like it
// cannot copy into a folder that exists. An existing FILE at the name takes the same path and is
// also a 405 case, which the finding as reported missed.
- (void)testDAVMKCOLOnAnExistingResourceAnswersMethodNotAllowed {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"Coll"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"FILE" writeToFile:[dir stringByAppendingPathComponent:@"file.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Both spellings of "something is already here" answer 405, and RFC 9110 §15.5.6 makes Allow
    // mandatory on one.
    for (NSString* existing in @[ @"/Coll", @"/file.txt" ]) {
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"MKCOL %@ HTTP/1.1\r\nHost: localhost\r\n\r\n", existing]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 405"], @"MKCOL on the existing %@ should be 405: %@", existing, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
        XCTAssertTrue([reply containsString:@"Allow:"], @"a 405 must carry Allow (RFC 9110 §15.5.6): %@", existing);
    }

    // The collection must be untouched — a refusal that destroyed it would be far worse than the
    // wrong status it replaces.
    BOOL isDirectory = NO;
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Coll"] isDirectory:&isDirectory] && isDirectory, @"MKCOL on an existing collection must leave it alone");
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"file.txt"] encoding:NSUTF8StringEncoding error:NULL], @"FILE", @"MKCOL on an existing file must leave it alone");

    // And what must keep working: a brand-new name is still created. This is the half a guard
    // written for one failure mode is most likely to break.
    NSString* created = SendRawRequest(server.port, @"MKCOL /Fresh HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([created hasPrefix:@"HTTP/1.1 201"], @"a brand-new collection must still be created: %@", [created substringToIndex:MIN((NSUInteger)40, created.length)]);
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Fresh"] isDirectory:&isDirectory] && isDirectory);

    // A missing intermediate collection is 409 and must NOT be absorbed into the new 405 branch;
    // the two answers mean different things to a client walking a tree.
    NSString* orphan = SendRawRequest(server.port, @"MKCOL /Nope/Deep HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([orphan hasPrefix:@"HTTP/1.1 409"], @"a missing parent is still 409: %@", [orphan substringToIndex:MIN((NSUInteger)40, orphan.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// RFC 4918 §9.1: an absent Depth on PROPFIND means "infinity". This server deliberately refuses
// infinite traversal and answers 403 with the machine-readable DAV:propfind-finite-depth
// precondition — but only for the EXPLICIT spelling. The absent case fell through to a bare 400,
// telling a client its perfectly legal request was malformed rather than that it should retry with
// a bounded depth. Same rule, one of its two spellings, which is this codebase's signature shape.
- (void)testDAVPropfindWithoutDepthRefusesAsIfInfinite {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"DATA" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Absent must answer exactly as explicit "infinity" does, precondition element and all.
    NSString* absent = SendRawRequest(server.port, @"PROPFIND / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([absent hasPrefix:@"HTTP/1.1 403"], @"an absent Depth means infinity, so 403: %@", [absent substringToIndex:MIN((NSUInteger)40, absent.length)]);
    XCTAssertTrue([absent containsString:@"propfind-finite-depth"], @"the refusal must carry the precondition that tells the client what to do instead");

    NSString* infinite = SendRawRequest(server.port, @"PROPFIND / HTTP/1.1\r\nHost: localhost\r\nDepth: infinity\r\n\r\n");
    XCTAssertTrue([infinite hasPrefix:@"HTTP/1.1 403"], @"explicit infinity is unchanged");
    XCTAssertTrue([infinite containsString:@"propfind-finite-depth"]);

    // The depths every real client actually sends must keep working — this is what a careless
    // reordering of the branch would break.
    for (NSString* depth in @[ @"0", @"1" ]) {
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"PROPFIND / HTTP/1.1\r\nHost: localhost\r\nDepth: %@\r\n\r\n", depth]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 207"], @"Depth: %@ must still enumerate: %@", depth, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
    }

    // A genuinely unparseable Depth is still malformed, and must not be folded into the 403.
    NSString* garbage = SendRawRequest(server.port, @"PROPFIND / HTTP/1.1\r\nHost: localhost\r\nDepth: sideways\r\n\r\n");
    XCTAssertTrue([garbage hasPrefix:@"HTTP/1.1 400"], @"an unrecognised Depth is still 400: %@", [garbage substringToIndex:MIN((NSUInteger)40, garbage.length)]);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// Two halves of the same rule: what the server says it can do, and what it says when it refuses.
// PROPPATCH has been implemented since the class-1 work but was never added to the shared Allow
// value, so capability discovery disagreed with routing — a client reading OPTIONS concluded
// PROPPATCH was unavailable and never tried it. And the non-Finder LOCK/UNLOCK refusals answered
// 405 with no Allow at all, which RFC 9110 §15.5.6 makes mandatory.
- (void)testDAVAllowAdvertisesEveryImplementedMethodAndAccompaniesEvery405 {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([@"DATA" writeToFile:[dir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* discovered = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    XCTAssertTrue([discovered containsString:@"PROPPATCH"], @"OPTIONS must advertise PROPPATCH, which this server implements: %@", discovered);

    // Every method named in Allow must actually route, or the advertisement is the lie in the
    // other direction. PROPPATCH with an empty body is refused on its merits, not with 501.
    NSString* proppatch = SendRawRequest(server.port, @"PROPPATCH /a.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n");
    XCTAssertFalse([proppatch hasPrefix:@"HTTP/1.1 501"], @"a method named in Allow must be routed: %@", [proppatch substringToIndex:MIN((NSUInteger)40, proppatch.length)]);

    // The LOCK/UNLOCK 405s: this client is not Finder, so both refuse — and both must say what is
    // allowed instead.
    for (NSString* method in @[ @"LOCK", @"UNLOCK" ]) {
        NSString* reply = SendRawRequest(server.port, [NSString stringWithFormat:@"%@ /a.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n", method]);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 405"], @"%@ is refused for a non-Finder client: %@", method, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
        XCTAssertTrue([reply containsString:@"Allow:"], @"the %@ 405 must carry Allow (RFC 9110 §15.5.6)", method);
    }

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// RFC 4918 §9.8.3: COPY of a collection with "Depth: 0" copies the collection itself WITHOUT its
// members. The header was accepted and then ignored — the implementation always did a recursive
// filesystem copy — so a client asking for a shallow copy was told 201 and silently given the whole
// subtree. That is precisely the "silently doing an approximation of what was asked" this project
// refuses everywhere else, and for Shape A a collection of builds is not a cheap thing to duplicate
// by accident.
- (void)testDAVShallowCopyOfCollectionOmitsMembers {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    XCTAssertTrue([fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"Coll/Inner"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"MEMBER" writeToFile:[dir stringByAppendingPathComponent:@"Coll/member.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"DEEP" writeToFile:[dir stringByAppendingPathComponent:@"Coll/Inner/deep.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* shallow = SendRawRequest(server.port, @"COPY /Coll HTTP/1.1\r\nHost: localhost\r\nDestination: /Shallow\r\nDepth: 0\r\n\r\n");
    XCTAssertTrue([shallow hasPrefix:@"HTTP/1.1 201"], @"a shallow collection copy still succeeds: %@", [shallow substringToIndex:MIN((NSUInteger)40, shallow.length)]);

    BOOL isDirectory = NO;
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Shallow"] isDirectory:&isDirectory] && isDirectory, @"the collection itself is created");
    XCTAssertFalse([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Shallow/member.txt"]], @"Depth: 0 must NOT copy members");
    XCTAssertFalse([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Shallow/Inner"]], @"Depth: 0 must NOT copy member collections");

    // Depth: infinity and an absent header both still copy everything (§9.8.3 makes absent mean
    // infinity), which is what a naive fix that shallow-copied unconditionally would destroy.
    NSString* deep = SendRawRequest(server.port, @"COPY /Coll HTTP/1.1\r\nHost: localhost\r\nDestination: /Deep\r\nDepth: infinity\r\n\r\n");
    XCTAssertTrue([deep hasPrefix:@"HTTP/1.1 201"], @"a deep copy still succeeds: %@", [deep substringToIndex:MIN((NSUInteger)40, deep.length)]);
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"Deep/Inner/deep.txt"] encoding:NSUTF8StringEncoding error:NULL], @"DEEP", @"Depth: infinity must copy the whole subtree");

    NSString* absent = SendRawRequest(server.port, @"COPY /Coll HTTP/1.1\r\nHost: localhost\r\nDestination: /Absent\r\n\r\n");
    XCTAssertTrue([absent hasPrefix:@"HTTP/1.1 201"], @"an absent Depth still succeeds: %@", [absent substringToIndex:MIN((NSUInteger)40, absent.length)]);
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"Absent/member.txt"] encoding:NSUTF8StringEncoding error:NULL], @"MEMBER", @"an absent Depth means infinity, so members are copied");

    // Depth: 0 on a plain FILE is meaningless and must keep working — a resource with no internal
    // members cannot mean anything else, and refusing it would break a client that sets Depth
    // uniformly. This is the case the thirteenth pass deliberately opened up.
    NSString* file = SendRawRequest(server.port, @"COPY /Coll/member.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /leaf.txt\r\nDepth: 0\r\n\r\n");
    XCTAssertTrue([file hasPrefix:@"HTTP/1.1 201"], @"Depth: 0 on a plain file is still fine: %@", [file substringToIndex:MIN((NSUInteger)40, file.length)]);
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"leaf.txt"] encoding:NSUTF8StringEncoding error:NULL], @"MEMBER");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
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

// The creation-date block runs AFTER the collection exists, so a failure there answered 500
// having already created it — the client is told the method failed and a retry then gets 405
// because the collection is there. "A transaction leaves nothing behind" applies to the
// failure paths too, so the collection is removed before the error goes out.
- (void)testMKCOLLeavesNothingBehindWhenItFailsAfterCreating {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // An unparseable creation date fails the step that runs after the directory is made.
    NSString* response = SendRawRequest(server.port, @"MKCOL /NewFolder HTTP/1.1\r\nHost: localhost\r\nX-WebServerKit-CreationDate: not-a-date\r\n\r\n");
    BOOL const refused = ![response containsString:@" 201"];
    BOOL const present = [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"NewFolder"]];

    NSString* const detail = [NSString stringWithFormat:@"refused=%d present=%d response=%@", refused, present, [response substringToIndex:MIN((NSUInteger)40, response.length)]];
    XCTAssertFalse(refused && present, @"a refused MKCOL must not leave the collection behind: %@", detail);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// RFC 4918 §11.5: a volume that cannot store the representation is 507, not 500. Answering 500
// invites the client to retry an operation that cannot succeed until something is freed. Both
// spellings have to be read — NSFileManager reports a full volume as a Cocoa error, while
// EDQUOT only ever arrives as a POSIX errno under NSUnderlyingError.
- (void)testFullVolumeErrorsMapToInsufficientStorage {
    NSError* cocoa = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:nil];
    XCTAssertEqual(WSKServerErrorStatusCodeForError(cocoa), kWSKHTTPStatusCode_InsufficientStorage);

    NSError* posix = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:nil];
    XCTAssertEqual(WSKServerErrorStatusCodeForError(posix), kWSKHTTPStatusCode_InsufficientStorage);

    NSError* quota = [NSError errorWithDomain:NSPOSIXErrorDomain code:EDQUOT userInfo:nil];
    XCTAssertEqual(WSKServerErrorStatusCodeForError(quota), kWSKHTTPStatusCode_InsufficientStorage);

    // The errno is usually buried under a Cocoa wrapper rather than at the top level.
    NSDictionary* wrapped = @{NSUnderlyingErrorKey : [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:nil]};
    NSError* nested = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:wrapped];
    XCTAssertEqual(WSKServerErrorStatusCodeForError(nested), kWSKHTTPStatusCode_InsufficientStorage);

    // Everything else must stay 500, or this would relabel every failure as a full disk.
    NSError* permissions = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];
    XCTAssertEqual(WSKServerErrorStatusCodeForError(permissions), kWSKHTTPStatusCode_InternalServerError);
    XCTAssertEqual(WSKServerErrorStatusCodeForError(nil), kWSKHTTPStatusCode_InternalServerError);
}

// The recursive-vetting class, at the last two verbs it never reached. With an allow-list set,
// DELETE of a collection is refused when it would destroy something a direct request refuses, and
// so is an overwrite -- but MOVE and COPY to a NEW destination were never vetted at all, so a
// collection carrying a file the client may not touch could be relocated or duplicated wholesale.
// Measured before this: every DIRECT operation on Coll/sub/secret.pem 403, recursive DELETE 403,
// MOVE onto an EXISTING destination 403 -- and MOVE and COPY to a new destination 201.
//
// The victim is deliberately ONE LEVEL DOWN. The top level of the addressed collection is immune
// to the -skipDescendants bug this class keeps recurring through, which is why three earlier tests
// passed against unfixed code.
//
// The cost is real and is asserted below rather than discovered later: a collection holding
// anything outside the allow-list becomes unmovable, not just undeletable. That is the same cost
// already accepted for DELETE, and consistency with it is the argument -- a client told it may not
// move a file must not be able to move it by naming its parent.
- (void)testCollectionMoveAndCopyAreVettedLikeTheDeleteThatWouldDestroyTheSameFiles {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* coll = [dir stringByAppendingPathComponent:@"Coll"];
    XCTAssertTrue([fm createDirectoryAtPath:[coll stringByAppendingPathComponent:@"sub"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"k" writeToFile:[coll stringByAppendingPathComponent:@"sub/secret.pem"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"t" writeToFile:[coll stringByAppendingPathComponent:@"ok.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    // A second collection holding ONLY allow-listed content: the half that must keep working.
    NSString* clean = [dir stringByAppendingPathComponent:@"Clean"];
    XCTAssertTrue([fm createDirectoryAtPath:[clean stringByAppendingPathComponent:@"sub"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([@"t" writeToFile:[clean stringByAppendingPathComponent:@"sub/fine.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    server.allowedFileExtensions = @[ @"txt" ];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};  // Hoisted: commas split the macro
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Control: the direct spelling is already refused, which is what makes the collection spelling
    // an inconsistency rather than a policy choice.
    NSString* direct = SendRawRequest(server.port, @"MOVE /Coll/sub/secret.pem HTTP/1.1\r\nHost: localhost\r\nDestination: /taken.pem\r\nOverwrite: T\r\n\r\n");
    XCTAssertTrue([direct hasPrefix:@"HTTP/1.1 403"], @"CONTROL: a direct MOVE of the file must already be refused: %@", direct);

    NSString* moved = SendRawRequest(server.port, @"MOVE /Coll HTTP/1.1\r\nHost: localhost\r\nDestination: /Moved\r\nOverwrite: T\r\n\r\n");
    XCTAssertTrue([moved hasPrefix:@"HTTP/1.1 403"], @"MOVE of a collection must be vetted like the DELETE that would destroy the same files: %@", moved);
    XCTAssertTrue([fm fileExistsAtPath:[coll stringByAppendingPathComponent:@"sub/secret.pem"]], @"a refused MOVE must leave the file where it was");
    XCTAssertFalse([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Moved"]], @"a refused MOVE must not create the destination");

    NSString* copied = SendRawRequest(server.port, @"COPY /Coll HTTP/1.1\r\nHost: localhost\r\nDestination: /Copied\r\nOverwrite: T\r\n\r\n");
    XCTAssertTrue([copied hasPrefix:@"HTTP/1.1 403"], @"COPY of a collection must be vetted too -- it duplicates what a direct request may not read: %@", copied);
    XCTAssertFalse([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Copied"]], @"a refused COPY must leave nothing behind");

    // The half that must keep working, or the fix is "refuse every collection operation".
    NSString* okMove = SendRawRequest(server.port, @"MOVE /Clean HTTP/1.1\r\nHost: localhost\r\nDestination: /CleanMoved\r\nOverwrite: T\r\n\r\n");
    XCTAssertTrue([okMove hasPrefix:@"HTTP/1.1 201"] || [okMove hasPrefix:@"HTTP/1.1 204"], @"a collection holding only allow-listed content must still move: %@", okMove);
    XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"CleanMoved/sub/fine.txt"]], @"the permitted move must actually have happened");

    NSString* okCopy = SendRawRequest(server.port, @"COPY /CleanMoved HTTP/1.1\r\nHost: localhost\r\nDestination: /CleanCopy\r\nOverwrite: T\r\n\r\n");
    XCTAssertTrue([okCopy hasPrefix:@"HTTP/1.1 201"] || [okCopy hasPrefix:@"HTTP/1.1 204"], @"and must still copy: %@", okCopy);

    // And a plain allow-listed FILE is unaffected in both directions.
    NSString* fileMove = SendRawRequest(server.port, @"MOVE /Coll/ok.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /ok2.txt\r\nOverwrite: T\r\n\r\n");
    XCTAssertTrue([fileMove hasPrefix:@"HTTP/1.1 201"] || [fileMove hasPrefix:@"HTTP/1.1 204"], @"an allow-listed file must still move: %@", fileMove);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// COPY, DELETE and PROPFIND all validate the Depth token and answer 400 for a value they cannot
// honour. MOVE reads the header not at all -- measured, every spelling including "banana" answered
// 201 and did a full recursive relocation. MOVE and COPY share performCOPY:isMove:, and the
// validation sits inside an `if (!isMove)`, so this is recurring defect shape #2 once more: the
// rule is present at three of the four verbs it applies to.
//
// Deliberately NOT taken here: RFC 4918 section 9.9.2 says a client MUST NOT send any Depth but
// infinity on a MOVE of a COLLECTION, so a strict server would refuse "0" there too. COPY and
// DELETE both accept "0" on a plain file for the good reason that it means the same as infinity
// when there are no internal members, and inventing an asymmetry MOVE alone enforces would refuse
// requests real clients send. Matching COPY exactly is the fix; the stricter rule is a separate
// judgement with its own client risk.
- (void)testMoveValidatesItsDepthHeaderLikeEveryOtherVerb {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};  // Hoisted: commas split the macro
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Values MOVE must refuse, because every sibling verb refuses them.
    for (NSString* bad in @[ @"banana", @"2", @"0,", @"infinite" ]) {
        XCTAssertTrue([@"x" writeToFile:[dir stringByAppendingPathComponent:@"m.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        NSString* request = [NSString stringWithFormat:@"MOVE /m.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /moved.txt\r\nOverwrite: T\r\nDepth: %@\r\n\r\n", bad];
        NSString* reply = SendRawRequest(server.port, request);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 400"], @"MOVE with Depth: %@ must be refused as COPY refuses it: %@", bad, [reply substringToIndex:MIN((NSUInteger)32, reply.length)]);
        // "Refuse rather than half-succeed": the refusal must also have moved nothing.
        XCTAssertTrue([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"m.txt"]], @"a refused MOVE must leave the source in place (Depth: %@)", bad);
        XCTAssertFalse([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"moved.txt"]], @"a refused MOVE must not create the destination (Depth: %@)", bad);
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:@"m.txt"] error:NULL];
    }

    // And the spellings that MUST keep working, so the fix cannot be "refuse Depth on MOVE".
    for (NSString* good in @[ @"infinity", @"0", @"Infinity" ]) {
        XCTAssertTrue([@"x" writeToFile:[dir stringByAppendingPathComponent:@"k.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        NSString* request = [NSString stringWithFormat:@"MOVE /k.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /kept.txt\r\nOverwrite: T\r\nDepth: %@\r\n\r\n", good];
        NSString* reply = SendRawRequest(server.port, request);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 201"] || [reply hasPrefix:@"HTTP/1.1 204"], @"MOVE with Depth: %@ must still succeed: %@", good, [reply substringToIndex:MIN((NSUInteger)32, reply.length)]);
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:@"kept.txt"] error:NULL];
    }

    // No Depth header at all is the ordinary case and means infinity.
    XCTAssertTrue([@"x" writeToFile:[dir stringByAppendingPathComponent:@"n.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSString* plain = SendRawRequest(server.port, @"MOVE /n.txt HTTP/1.1\r\nHost: localhost\r\nDestination: /plain.txt\r\nOverwrite: T\r\n\r\n");
    XCTAssertTrue([plain hasPrefix:@"HTTP/1.1 201"] || [plain hasPrefix:@"HTTP/1.1 204"], @"MOVE with no Depth must still succeed: %@", plain);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// The class-2 façade is Finder-only by design: OPTIONS answers "DAV: 1, 2" and the LOCK stub
// works only for a WebDAVFS/WebDAVLib user agent; everyone else gets class 1 and a 405 for
// LOCK. The Allow header must tell the same story — RFC 9110 §10.2.1 makes Allow on a 405 the
// list of the target's CURRENTLY SUPPORTED methods, and one shared constant meant the 405 a
// non-Finder LOCK received listed LOCK inside its own refusal.
- (void)testNonFinderClientsAreNotOfferedTheLockMethods {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* (^headerLine)(NSString*, NSString*) = ^NSString*(NSString* reply, NSString* name) {
        NSRange start = [reply rangeOfString:[name stringByAppendingString:@": "] options:NSCaseInsensitiveSearch];
        if (start.location == NSNotFound) {
            return nil;
        }
        NSString* rest = [reply substringFromIndex:NSMaxRange(start)];
        return [rest substringToIndex:[rest rangeOfString:@"\r\n"].location];
    };

    NSString* genericOptions = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    NSString* genericAllow = headerLine(genericOptions, @"Allow");
    XCTAssertNotNil(genericAllow, @"OPTIONS must carry Allow: %@", genericOptions);
    XCTAssertFalse([genericAllow containsString:@"LOCK"], @"a client whose LOCK answers 405 must not be offered it: %@", genericAllow);
    XCTAssertTrue([genericAllow containsString:@"PROPPATCH"], @"trimming LOCK must not drop the methods everyone gets: %@", genericAllow);

    NSString* genericLock = SendRawRequest(server.port, @"LOCK / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n");
    XCTAssertTrue([genericLock hasPrefix:@"HTTP/1.1 405"], @"non-Finder LOCK stays 405: %@", [genericLock substringToIndex:MIN((NSUInteger)40, genericLock.length)]);
    NSString* refusalAllow = headerLine(genericLock, @"Allow");
    XCTAssertNotNil(refusalAllow, @"RFC 9110 §15.5.6: the 405 must carry Allow: %@", genericLock);
    XCTAssertFalse([refusalAllow containsString:@"LOCK"], @"the 405 for LOCK listed LOCK as allowed: %@", refusalAllow);

    NSString* finderOptions = SendRawRequest(server.port, @"OPTIONS / HTTP/1.1\r\nHost: localhost\r\nUser-Agent: WebDAVFS/3.0.1 (03018000) Darwin/13.1.0 (x86_64)\r\n\r\n");
    NSString* finderAllow = headerLine(finderOptions, @"Allow");
    XCTAssertTrue([finderAllow containsString:@"UNLOCK"], @"Finder must keep being offered the lock methods: %@", finderAllow);
    NSString* finderDAV = headerLine(finderOptions, @"DAV");
    XCTAssertEqualObjects(finderDAV, @"1, 2", @"Finder must keep seeing class 2: %@", finderOptions);

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// RFC 4918 §9.10: a LOCK that creates a new lock MUST return the token in a Lock-Token response
// header, not only inside the lockdiscovery body. Finder happens to read the body — the trace
// corpus predates this header — but a conforming client is entitled to the header.
- (void)testANewLockCarriesTheLockTokenResponseHeader {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    NSString* path = [dir stringByAppendingPathComponent:@"f.txt"];
    XCTAssertTrue([@"LOCKED" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* body = @"<?xml version=\"1.0\" encoding=\"utf-8\"?><D:lockinfo xmlns:D=\"DAV:\"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>";
    NSString* request = [NSString stringWithFormat:@"LOCK /f.txt HTTP/1.1\r\nHost: localhost\r\nUser-Agent: WebDAVFS/3.0.1 (03018000) Darwin/13.1.0 (x86_64)\r\nDepth: 0\r\nContent-Type: application/xml\r\nX-WebServerKit-LockToken: urn:uuid:AUDIT-LOCK-TOKEN\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)body.length, body];
    NSString* reply = SendRawRequest(server.port, request);
    XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 200"], @"the Finder-shaped LOCK must succeed: %@", [reply substringToIndex:MIN((NSUInteger)60, reply.length)]);

    NSRange start = [reply rangeOfString:@"Lock-Token: " options:NSCaseInsensitiveSearch];
    XCTAssertNotEqual(start.location, (NSUInteger)NSNotFound, @"a new lock owes a Lock-Token response header: %@", reply);

    if (start.location == NSNotFound) {  // The assertion above has already failed; don't throw on top of it
        [server stop];
        [fm removeItemAtPath:dir error:NULL];
        return;
    }

    NSString* rest = [reply substringFromIndex:NSMaxRange(start)];
    NSString* token = [rest substringToIndex:[rest rangeOfString:@"\r\n"].location];
    XCTAssertEqualObjects(token, @"<urn:uuid:AUDIT-LOCK-TOKEN>", @"the header must carry the minted token as a Coded-URL: %@", token);
    XCTAssertTrue([reply containsString:@"urn:uuid:AUDIT-LOCK-TOKEN"], @"the same token must appear in the lockdiscovery body");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

@end
