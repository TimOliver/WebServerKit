// Entity tags, Last-Modified, and every conditional request that turns on them.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import "TestsSupport.h"

@interface WSKValidatorTests : XCTestCase
@end

@implementation WSKValidatorTests

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

// "Accept-Encoding" was matched with a case-sensitive SUBSTRING search for "gzip", so a client that
// wrote "gzip;q=0" — explicitly refusing it — was recorded as accepting, "GZIP" and "*" were
// recorded as refusing, and any token merely containing the letters counted. The property is
// public API that a host app is invited to gate compression on, so it has to mean what it says.
- (void)testAcceptEncodingIsParsedAsTokensWithQualityValues {
    NSDictionary<NSString*, NSNumber*>* const cases = @{
        @"gzip" : @YES,
        @"GZIP" : @YES,             // Tokens are case-insensitive
        @"x-gzip" : @YES,           // RFC 9110 §8.4.1 synonym
        @"*" : @YES,                // A wildcard permits it
        @"deflate, gzip" : @YES,
        @"gzip;q=0.5" : @YES,
        @"gzip;q=0" : @NO,          // Explicitly not acceptable
        @"gzip;q=0.0" : @NO,
        @"*;q=0" : @NO,
        @"deflate" : @NO,
        @"xgzipy" : @NO,            // Not a gzip token at all
        @"identity" : @NO,
    };

    for (NSString* header in cases) {
        WSKRequest* request = [[WSKRequest alloc] initWithMethod:@"GET"
                                                             url:[NSURL URLWithString:@"http://localhost/"]
                                                         headers:@{@"Accept-Encoding" : header}
                                                            path:@"/"
                                                           query:@{}];
        XCTAssertNotNil(request, @"header %@ should still build a request", header);
        XCTAssertEqual(request.acceptsGzipContentEncoding, cases[header].boolValue, @"Accept-Encoding: %@", header);
    }

    // No header at all is not an acceptance.
    WSKRequest* bare = [[WSKRequest alloc] initWithMethod:@"GET" url:[NSURL URLWithString:@"http://localhost/"] headers:@{} path:@"/" query:@{}];
    XCTAssertFalse(bare.acceptsGzipContentEncoding, @"an absent Accept-Encoding is not an acceptance");
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

// RFC 9110 s5.6.7 requires a recipient to accept all three HTTP-date formats. Only
// IMF-fixdate parsed, so If-Modified-Since / If-Unmodified-Since / If-Range carrying the
// obsolete spellings parsed to nil and the precondition was treated as ABSENT — a
// conditional request failing open, which is the wrong direction for a validator.
- (void)testHTTPDateParsingAcceptsAllThreeFormatsRFC9110Requires {
    NSDate* expected = [NSDate dateWithTimeIntervalSince1970:784111777.0];  // Sun, 06 Nov 1994 08:49:37 GMT

    NSDate* imf = WSKParseRFC822(@"Sun, 06 Nov 1994 08:49:37 GMT");
    XCTAssertNotNil(imf, @"IMF-fixdate must parse");
    XCTAssertEqualWithAccuracy([imf timeIntervalSince1970], [expected timeIntervalSince1970], 0.5);

    NSDate* rfc850 = WSKParseRFC822(@"Sunday, 06-Nov-94 08:49:37 GMT");
    XCTAssertNotNil(rfc850, @"RFC 850 date must parse");
    XCTAssertEqualWithAccuracy([rfc850 timeIntervalSince1970], [expected timeIntervalSince1970], 0.5);

    NSDate* asctime = WSKParseRFC822(@"Sun Nov  6 08:49:37 1994");
    XCTAssertNotNil(asctime, @"asctime() date must parse");
    XCTAssertEqualWithAccuracy([asctime timeIntervalSince1970], [expected timeIntervalSince1970], 0.5);

    // Garbage must still be refused, or "accept everything" would pass the above.
    XCTAssertNil(WSKParseRFC822(@"not a date at all"));
    XCTAssertNil(WSKParseRFC822(@""));
}

// RFC 9110 §13.2.1 requires preconditions to be IGNORED when the unconditional response would
// be anything other than 2xx or 412 — so a conditional DELETE of a resource that does not exist
// must answer 404, not 412. PUT is the opposite case: it would create (201), so the condition is
// evaluated and a missing resource fails "If-Match: *". Pinned in both directions because the
// obvious "fix" for the 404 would break the rule this test exists to state.
- (void)testConditionalRequestsOnAMissingResourceFollowTheEvaluationRule {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dir = MakeTempDirectory();
    WSKWebDAVServer* server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary* options = @{WSKOption_Port : @0, WSKOption_BindToLocalhost : @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSString* deleted = SendRawRequest(server.port, @"DELETE /gone.txt HTTP/1.1\r\nHost: localhost\r\nIf-Match: *\r\n\r\n");
    XCTAssertTrue([deleted containsString:@" 404"], @"DELETE of a missing resource must ignore the precondition and 404: %@", [deleted substringToIndex:MIN((NSUInteger)40, deleted.length)]);

    NSString* put = SendRawRequest(server.port, @"PUT /gone.txt HTTP/1.1\r\nHost: localhost\r\nIf-Match: *\r\nContent-Length: 2\r\n\r\nhi");
    XCTAssertTrue([put containsString:@" 412"], @"PUT would create, so \"If-Match: *\" on a missing resource must fail 412: %@", [put substringToIndex:MIN((NSUInteger)40, put.length)]);
    XCTAssertFalse([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"gone.txt"]], @"a 412 must not have written anything");

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// RFC 9110 §13.1.4: a recipient MUST IGNORE a precondition whose value is not a valid HTTP-date.
// Batch A's new RFC 850 and asctime patterns are parsed by ICU, which accepts 1-3 digits for a
// "yyyy" field and 1 for "yy" — so a malformed value parsed to a first- or second-century date
// instead of nil. That date precedes every real mtime, so If-Unmodified-Since failed and NO retry
// could ever succeed. A validator that failed OPEN was replaced by one that fails CLOSED.
- (void)testMalformedHTTPDatesAreIgnoredRatherThanParsedToAncientYears {
    XCTAssertNil(WSKParseRFC822(@"Sun Nov  6 08:49:37 94"), @"a 2-digit asctime year is not an HTTP-date");
    XCTAssertNil(WSKParseRFC822(@"Sun Nov  6 08:49:37 199"), @"a 3-digit asctime year is not an HTTP-date");
    XCTAssertNil(WSKParseRFC822(@"Sunday, 06-Nov-9 08:49:37 GMT"), @"a 1-digit RFC 850 year is not an HTTP-date");

    // The three legal spellings must still parse, or this closes the hole by breaking the feature.
    NSDate* expected = [NSDate dateWithTimeIntervalSince1970:784111777.0];
    for (NSString* legal in @[ @"Sun, 06 Nov 1994 08:49:37 GMT", @"Sunday, 06-Nov-94 08:49:37 GMT", @"Sun Nov  6 08:49:37 1994" ]) {
        NSDate* parsed = WSKParseRFC822(legal);
        XCTAssertNotNil(parsed, @"must still parse: %@", legal);
        XCTAssertEqualWithAccuracy([parsed timeIntervalSince1970], [expected timeIntervalSince1970], 0.5, @"%@", legal);
    }
}

// Batch A's two extra formatter passes and a whole-string double-space collapse made rejecting a
// non-date LINEAR in its length — 74x at the 64 KB header cap — inside the single process-wide
// serial queue that also serializes the Date header of every response. If-Modified-Since is parsed
// for every request, so no handler and no authentication is needed to reach it.
//
// The bound is deliberately loose (a 74x regression is ~1.5 ms per call, so 2000 calls would take
// ~3 s) because timing assertions flake under load; it catches the class, not a percentage.
- (void)testRejectingALongNonDateStaysCheap {
    NSMutableString* padding = [NSMutableString string];
    while (padding.length < 60000) {
        [padding appendString:@"  "];  // Double spaces: the input that triggered the collapse.
    }

    NSDate* started = [NSDate date];
    for (NSUInteger i = 0; i < 2000; i++) {
        XCTAssertNil(WSKParseRFC822(padding));
    }
    NSTimeInterval elapsed = -[started timeIntervalSinceNow];
    XCTAssertLessThan(elapsed, 2.0, @"2000 rejections of a 60 KB non-date took %.2fs; rejection must not be linear in length", elapsed);
}

@end
