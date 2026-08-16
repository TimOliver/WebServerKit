// Building a response: file bodies, error pages, encodings, and the headers they carry.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import "TestsSupport.h"

@interface WSKResponseTests : XCTestCase
@end

@implementation WSKResponseTests

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

// gzip over a FILE response, which neither round-trip above covers: WSKFileResponse ends its
// body through the `} else if (_size > 0)` branch in -readData:, and a zero-length NSData is
// the end-of-stream sentinel WSKGZipEncoder needs to select Z_FINISH. A regression there
// (returning nil at normal end) produced an unterminated, undecodable gzip stream at every
// size — while identity file responses hid it completely, because Content-Length had already
// framed the body. This is the identity-hidden half, so it needs its own pin.
- (void)testGZipEncodedFileResponseRoundTrips {
    NSString* dir = MakeTempDirectory();

    // One file smaller than the 32 KiB read buffer, one spanning several reads with an
    // unaligned tail, so both the single-chunk and multi-chunk paths reach the sentinel.
    for (NSNumber* sizeNumber in @[ @117, @100000 ]) {
        NSUInteger size = sizeNumber.unsignedIntegerValue;
        NSMutableData* original = [NSMutableData dataWithLength:size];
        uint8_t* bytes = original.mutableBytes;
        for (NSUInteger i = 0; i < size; i++) {
            bytes[i] = (uint8_t)(i * 31 + 7);
        }

        NSString* path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu.bin", (unsigned long)size]];
        XCTAssertTrue([original writeToFile:path atomically:YES]);

        WSKFileResponse* response = [WSKFileResponse responseWithFile:path];
        XCTAssertNotNil(response);
        response.gzipContentEncodingEnabled = YES;

        NSData* encoded = DrainResponseBody(response);
        XCTAssertNotNil(encoded, @"gzip file response never completed at %lu bytes", (unsigned long)size);
        NSData* decoded = GZipDecompress(encoded);
        XCTAssertNotNil(decoded, @"file response body was not a valid gzip stream at %lu bytes", (unsigned long)size);
        XCTAssertEqualObjects(decoded, original, @"gzip round-trip corrupted the body at %lu bytes", (unsigned long)size);
    }

    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
}

// A file truncated while it is being served: read(2) returns 0 with bytes still owed against
// the Content-Length already promised. That must surface as an ERROR — the transfer dies
// visibly — never as the zero-length success sentinel, which would tell the client a short
// body is complete.
- (void)testFileTruncatedWhileServedIsReportedAsAnErrorNotACleanEnd {
    NSString* dir = MakeTempDirectory();
    NSString* path = [dir stringByAppendingPathComponent:@"shrinking.bin"];
    const NSUInteger kSize = 96 * 1024;  // Three 32 KiB reads
    XCTAssertTrue([[NSMutableData dataWithLength:kSize] writeToFile:path atomically:YES]);

    WSKFileResponse* response = [WSKFileResponse responseWithFile:path];
    XCTAssertNotNil(response);
    XCTAssertEqual(response.contentLength, kSize);

    [response prepareForReading];
    XCTAssertTrue([response performOpen:NULL]);

    NSData* (^readChunk)(NSError**) = ^NSData*(NSError** outError) {
        __block NSData* chunk = nil;
        __block NSError* chunkError = nil;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [response performReadDataWithCompletion:^(NSData* data, NSError* readError) {
            chunk = data;
            chunkError = readError;
            dispatch_semaphore_signal(semaphore);
        }];
        XCTAssertEqual(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC))), 0L, @"reader never completed");
        if (outError) {
            *outError = chunkError;
        }
        return chunk;
    };

    // First chunk arrives normally.
    NSError* error = nil;
    NSData* first = readChunk(&error);
    XCTAssertEqual(first.length, (NSUInteger)(32 * 1024));
    XCTAssertNil(error);

    // Truncate below the offset already consumed: the next read(2) hits EOF with
    // two chunks still owed.
    XCTAssertEqual(truncate(path.fileSystemRepresentation, 16 * 1024), 0);

    NSData* next = readChunk(&error);
    XCTAssertNil(next, @"a truncated-under-us file must not deliver data or the success sentinel");
    XCTAssertNotNil(error, @"premature EOF with bytes owed must be reported as an error");

    [response performClose];
    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
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

// +responseWithFile: is declared nullable, so a path it cannot use must come back nil.
// -fileSystemRepresentation RAISES for an empty or NUL-bearing receiver, and the raise
// escapes through a host app's handler into the connection, so this is a process kill
// reachable from any handler that builds a path from client input. Same shape the
// eleventh pass fixed in +responseWithJSONObject:, at a site that fix did not reach.
- (void)testFileResponseReturnsNilRatherThanRaisingForAnUnusablePath {
    XCTAssertNoThrow([WSKFileResponse responseWithFile:@""]);
    XCTAssertNil([WSKFileResponse responseWithFile:@""]);

    unichar const nulBearing[] = {'/', 't', 'm', 'p', '/', 0, 'x'};
    NSString* nulPath = [NSString stringWithCharacters:nulBearing length:(sizeof(nulBearing) / sizeof(nulBearing[0]))];
    XCTAssertNoThrow([WSKFileResponse responseWithFile:nulPath]);
    XCTAssertNil([WSKFileResponse responseWithFile:nulPath]);

    // The ordinary path must still work, or this could pass by refusing everything.
    NSString* dir = MakeTempDirectory();
    NSString* file = [dir stringByAppendingPathComponent:@"ok.txt"];
    [@"hello" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    XCTAssertNotNil([WSKFileResponse responseWithFile:file]);
    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
}

// An empty field name serializes as ": value", which is not a field-line at all. The request
// parser already refuses one; this is the response side, which did not.
- (void)testResponseRefusesAnEmptyAdditionalHeaderName {
    WSKResponse* response = [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_OK];
    [response setValue:@"x" forAdditionalHeader:@""];
    XCTAssertNil([response valueForAdditionalHeader:@""], @"an empty header name must be refused, not stored");

    // A legitimate name must still work, or this could pass by refusing everything.
    [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
    XCTAssertEqualObjects([response valueForAdditionalHeader:@"Accept-Ranges"], @"bytes");
}

// The batch B guard cited RFC 9112 §5 field-name = 1*tchar and then rejected only the EMPTY
// spelling. A name beginning with a space serializes as an obs-fold continuation line, so it is
// appended to the PRECEDING header's value — measured against the real Date header. Closing one
// spelling of a rule while quoting the whole rule is this codebase's most repeated shape.
- (void)testResponseRefusesAHeaderNameThatIsNotAToken {
    WSKResponse* response = [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_OK];

    for (NSString* illegal in @[ @"", @" X-Folded", @"X-A B", @"X-Tab\tName", @"X-Üni", @"X-Trailing " ]) {
        [response setValue:@"INJECTED" forAdditionalHeader:illegal];
        XCTAssertNil([response valueForAdditionalHeader:illegal], @"a non-token header name must be refused: \"%@\"", illegal);
    }

    // Every character the token rule allows must still work.
    for (NSString* legal in @[ @"Accept-Ranges", @"X-Custom_Header", @"X-A.B", @"X-1234", @"!#$%&'*+-.^_`|~" ]) {
        [response setValue:@"ok" forAdditionalHeader:legal];
        XCTAssertEqualObjects([response valueForAdditionalHeader:legal], @"ok", @"a legal token name must be accepted: \"%@\"", legal);
    }
}

@end
