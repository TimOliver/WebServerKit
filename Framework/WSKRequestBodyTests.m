// Reading a request body: multipart, gzip, the per-request caps and the aggregate budget.
//
// Split out of the single Tests.m that held all 159 tests; the grouping is by subject, not by
// the pass that added each test.

#import "TestsSupport.h"

// Binary values make the accounting oracle the exact sum of retained payload lengths, without
// a decoded NSString copy. Framing is deliberately separate: parser working bytes must go away
// at close even when the completed fields remain alive.
static NSData *MultipartArgumentPart(NSString *boundary, NSString *name, NSUInteger length) {
    NSMutableData *const part = [NSMutableData data];
    NSString *const headers = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\nContent-Type: application/octet-stream\r\n\r\n", boundary, name];
    [part appendData:UTF8Data(headers)];
    NSMutableData *const value = [NSMutableData dataWithLength:length];
    memset(value.mutableBytes, 'v', value.length);
    [part appendData:value];
    [part appendData:UTF8Data(@"\r\n")];
    return part;
}

static NSData *MultipartArgumentBody(NSString *boundary, NSArray<NSNumber *> *lengths) {
    NSMutableData *const body = [NSMutableData data];
    for (NSUInteger index = 0; index < lengths.count; index++) {
        NSString *const name = [NSString stringWithFormat:@"a%lu", (unsigned long)index];
        [body appendData:MultipartArgumentPart(boundary, name, lengths[index].unsignedIntegerValue)];
    }
    [body appendData:UTF8Data([NSString stringWithFormat:@"--%@--\r\n", boundary])];
    return body;
}

static BOOL WriteMultipartInSlices(WSKMultiPartFormRequest *request, NSData *body, NSError **error) {
    // A small write cannot hit the working-buffer cap before the argument-sum cap being tested.
    for (NSUInteger offset = 0; offset < body.length; offset += 128) {
        NSRange const range = NSMakeRange(offset, MIN((NSUInteger)128, body.length - offset));
        if (![request performWriteData:[body subdataWithRange:range] error:error]) {
            return NO;
        }
    }
    return YES;
}

@interface WSKRequestBodyTests : XCTestCase
@end

@implementation WSKRequestBodyTests

// A body buffered entirely in memory (e.g. a DAV PROPFIND/LOCK body or a data
// request) must be rejected once it exceeds the in-memory cap, rather than
// growing unbounded and exhausting memory on the device.
- (void)testDataRequestRejectsBodyExceedingInMemoryCap {
    WSKDataRequest *request = OpenBodyRequest([WSKDataRequest class], @{});
    XCTAssertTrue([request hasBody]);

    NSData *chunk = [NSMutableData dataWithLength:(1024 * 1024)];  // 1 MB
    NSError *error = nil;
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
    WSKMultiPartFormRequest *request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    XCTAssertTrue([request hasBody]);

    // A file part header, then content that begins with the boundary token "--X"
    // followed by 'y' (not CRLF) — the parser stalls on this forever.
    NSMutableData *head = [NSMutableData data];
    [head appendData:SSEData(@"--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n\r\n")];
    [head appendData:SSEData(@"--Xy")];
    NSError *error = nil;
    XCTAssertTrue([request performWriteData:head error:&error]);

    NSData *filler = [NSMutableData dataWithLength:(1024 * 1024)];  // zeros: no boundary token
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
    NSData *bomb = GZipCompress([NSMutableData dataWithLength:(80 * 1024 * 1024)]);  // inflates to 80 MB
    XCTAssertNotNil(bomb);
    XCTAssertLessThan(bomb.length, (NSUInteger)(1024 * 1024));  // sanity: compressed form is tiny

    WSKDataRequest *request = OpenBodyRequest([WSKDataRequest class], @{@"Content-Encoding": @"gzip"});
    NSError *error = nil;

    XCTAssertFalse([request performWriteData:bomb error:&error], @"gzip decoder should reject a decompression bomb");
}

// A gzip body that satisfies its Content-Length but stops part-way through the
// deflate stream must be refused on close, not reported as a complete body. The
// decoder only asserted this (a no-op in Release), so the handler ran on a partial
// body — and on WebDAV PUT that replaced the target file with the fragment.
- (void)testGZipDecoderRejectsTruncatedBody {
    NSData *full = GZipCompress([NSMutableData dataWithLength:(64 * 1024)]);
    XCTAssertGreaterThan(full.length, (NSUInteger)20);

    WSKDataRequest *request = OpenBodyRequest([WSKDataRequest class], @{@"Content-Encoding": @"gzip"});
    NSError *error = nil;

    // The first 20 bytes are a well-formed prefix, so the write itself succeeds.
    XCTAssertTrue([request performWriteData:[full subdataWithRange:NSMakeRange(0, 20)] error:&error]);
    XCTAssertFalse([request performClose:&error], @"a truncated gzip stream must not close successfully");
}

// Bytes after Z_STREAM_END are either padding or a second concatenated member;
// either way the body is not one we can reproduce, so it must be refused rather
// than silently dropped (it was a WSK_DCHECK, i.e. an abort in Debug builds).
- (void)testGZipDecoderRejectsTrailingDataAfterStreamEnd {
    NSData *full = GZipCompress([NSMutableData dataWithLength:1024]);
    WSKDataRequest *request = OpenBodyRequest([WSKDataRequest class], @{@"Content-Encoding": @"gzip"});
    NSError *error = nil;

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
        NSData *compressed = GZipCompress([NSMutableData dataWithLength:(8 * 1024 * 1024)]);
        XCTAssertNotNil(compressed);

        @autoreleasepool {
            WSKFileRequest *request = OpenBodyRequest([WSKFileRequest class], @{@"Content-Encoding": @"gzip"});
            NSError *error = nil;

            for (NSUInteger offset = 0; offset < compressed.length; offset += 256) {
                NSRange slice = NSMakeRange(offset, MIN((NSUInteger)256, compressed.length - offset));
                XCTAssertTrue([request performWriteData:[compressed subdataWithRange:slice] error:&error],
                              @"inflating %lu MB through a %lu MB budget must succeed when only live buffers are charged (failed at offset %lu: %@)",
                              (unsigned long)8,
                              (unsigned long)(kTotal / (1024 * 1024)),
                              (unsigned long)offset,
                              error);
                XCTAssertLessThanOrEqual(WSKReservedMemoryLength(), kTotal, @"reserved memory exceeded the ceiling");
            }

            XCTAssertTrue([request performClose:&error], @"a complete gzip stream must close cleanly: %@", error);
        }

        XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0, @"the decoder leaked its reservation");
    } @finally {
        WSKSetMemoryLimitsForTesting(0, 0, 0);
    }
}

// Nested multipart/mixed parts are fed to a synchronously-recursing sub-parser, so
// unbounded nesting overflows the worker-thread stack. Nesting within the depth cap is
// accepted; nesting beyond it is rejected (before it can recurse deeply and crash).
- (void)testMultiPartRejectsDeeplyNestedMixed {
    // Within the cap: parses successfully.
    WSKMultiPartFormRequest *shallow = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=top"});
    NSError *error = nil;
    XCTAssertTrue([shallow performWriteData:NestedMultipartMixedBody(@"top", 2) error:&error], @"shallow nesting should parse: %@", error);
    XCTAssertTrue([shallow performClose:&error], @"shallow nesting should finish cleanly: %@", error);

    // Beyond the cap: rejected rather than recursing to the crash depth.
    WSKMultiPartFormRequest *deep = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=top"});
    XCTAssertFalse([deep performWriteData:NestedMultipartMixedBody(@"top", 20) error:&error], @"deeply nested multipart/mixed must be rejected");
}

// Whether a gzip body with a concatenated second member was accepted or refused depended only on
// how the client split its writes: sent in one write the trailing member was silently dropped and
// the request answered 200, handing the handler less data than was sent; split at the member
// boundary the same bytes answered 500. The client chose which. The fifth pass fixed the
// later-read half and this file recorded the case as closed; the same-read half was still open.
- (void)testGZipTrailingDataIsRefusedRegardlessOfHowItIsSplit {
    WSKWebServer *server = [[WSKWebServer alloc] init];
    __block NSString *received = nil;
    [server addHandlerForMethod:@"POST"
                           path:@"/data"
                   requestClass:[WSKDataRequest class]
                   processBlock:^WSKResponse *(WSKDataRequest *request) {
                       received = [[NSString alloc] initWithData:request.data encoding:NSUTF8StringEncoding];
                       return [WSKDataResponse responseWithText:@"ok"];
                   }];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSData *first = GZipCompress([@"AAAAAAAAAAAAAAAA" dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *second = GZipCompress([@"BBBBBBBBBBBBBBBB" dataUsingEncoding:NSUTF8StringEncoding]);
    NSMutableData *twoMembers = [first mutableCopy];
    [twoMembers appendData:second];

    NSData * (^request)(NSData *) = ^(NSData *body) {
        NSString *head = [NSString stringWithFormat:@"POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Type: text/plain\r\nContent-Length: %lu\r\n\r\n", (unsigned long)body.length];
        NSMutableData *full = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [full appendData:body];
        return (NSData *)full;
    };

    // A single well-formed member is the control: it must still be accepted and delivered whole.
    received = nil;
    XCTAssertTrue([SendRawDataRequest(server.port, request(first)) hasPrefix:@"HTTP/1.1 200"], @"a single gzip member stopped being accepted");
    XCTAssertEqualObjects(received, @"AAAAAAAAAAAAAAAA", @"the handler did not receive the whole body");

    // Two members in one write: previously 200 with the second silently dropped.
    received = nil;
    NSString *whole = SendRawDataRequest(server.port, request(twoMembers));
    XCTAssertFalse([whole hasPrefix:@"HTTP/1.1 200"], @"a concatenated second member was accepted and silently dropped: handler got %@", received);

    // And with trailing bytes that are not a member at all.
    NSMutableData *withGarbage = [first mutableCopy];
    [withGarbage appendBytes:"GARBAGE!" length:8];
    received = nil;
    XCTAssertFalse([SendRawDataRequest(server.port, request(withGarbage)) hasPrefix:@"HTTP/1.1 200"], @"trailing garbage after a gzip member was accepted");

    [server stop];
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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();

    WSKWebUploader *server = [[WSKWebUploader alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    XCTAssertTrue(fcntl(0, F_GETFD) != -1, @"descriptor 0 should be open before the request");

    NSString *body = @"--x\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--x--\r\n";
    for (NSString *contentType in @[@"multipart/form-data",
                                    @"multipart/form-data; boundary=",
                                    @"multipart/form-data; boundary=\u00e9\u00e9\u00e9"]) {
        SendRawRequest(server.port, [NSString stringWithFormat:@"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: %@\r\nContent-Length: %lu\r\n\r\n%@", contentType, (unsigned long)body.length, body]);
        XCTAssertTrue(fcntl(0, F_GETFD) != -1, @"\"%@\" closed descriptor 0", contentType);
    }

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// A well-formed single-member gzip body whose inflated length exactly fills the decoder's buffer
// (256 KiB * 2^k) was refused with 500 whenever the 8-byte trailer arrived in a later read: at
// exact fill avail_out is 0, so the loop grew the buffer and called inflate() again with no input
// left, which returns Z_BUF_ERROR. Reachable by any chunked streaming client using those block
// sizes. The ninth pass's own commit claimed the gzip verdict no longer depends on segmentation;
// for valid bodies at these sizes it still did.
- (void)testValidGZipBodyIsAcceptedWhateverItsInflatedSize {
    WSKWebServer *server = [[WSKWebServer alloc] init];
    __block NSUInteger receivedLength = 0;
    [server addHandlerForMethod:@"POST"
                           path:@"/data"
                   requestClass:[WSKDataRequest class]
                   processBlock:^WSKResponse *(WSKDataRequest *request) {
                       receivedLength = request.data.length;
                       return [WSKDataResponse responseWithText:@"ok"];
                   }];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // Either side of the initial buffer size, and two doublings past it.
    for (NSNumber *size in @[@261120, @262144, @263168, @524288, @1048576]) {
        NSUInteger const length = size.unsignedIntegerValue;
        NSMutableData *payload = [NSMutableData dataWithLength:length];
        memset(payload.mutableBytes, 'Z', length);
        NSData *body = GZipCompress(payload);

        NSString *head = [NSString stringWithFormat:@"POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Type: application/octet-stream\r\nContent-Length: %lu\r\n\r\n", (unsigned long)body.length];
        NSMutableData *whole = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [whole appendData:body];

        receivedLength = 0;
        XCTAssertTrue([SendRawDataRequest(server.port, whole) hasPrefix:@"HTTP/1.1 200"], @"a valid %lu-byte body was refused when sent whole", (unsigned long)length);
        XCTAssertEqual(receivedLength, length, @"the handler received the wrong length for a %lu-byte body", (unsigned long)length);

        // The same bytes with the trailer in a later read must give the same answer — that
        // invariance is the whole point, and it has to hold for VALID bodies too.
        receivedLength = 0;
        NSString *split = SendRawDataRequestSplit(server.port, whole, whole.length - 4);
        XCTAssertTrue([split hasPrefix:@"HTTP/1.1 200"], @"a valid %lu-byte body was refused when its trailer arrived in a later read: %@", (unsigned long)length, [split substringToIndex:MIN((NSUInteger)40, split.length)]);
        XCTAssertEqual(receivedLength, length, @"the split send delivered the wrong length for %lu bytes", (unsigned long)length);
    }

    [server stop];
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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = MakeTempDirectory();

    WSKWebDAVServer *server = [[WSKWebDAVServer alloc] initWithUploadDirectory:dir];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    NSData *const plain = [@"THE-REAL-PAYLOAD" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *const gzipped = GZipCompress(plain);
    XCTAssertNotNil(gzipped);

    NSString * (^put)(NSString *, NSString *, NSData *) = ^(NSString *name, NSString *encoding, NSData *body) {
        NSString *head = [NSString stringWithFormat:@"PUT /%@ HTTP/1.1\r\nHost: localhost\r\n%@Content-Length: %lu\r\n\r\n", name, encoding.length ? [NSString stringWithFormat:@"Content-Encoding: %@\r\n", encoding] : @"", (unsigned long)body.length];
        NSMutableData *request = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [request appendData:body];
        return SendRawDataRequest(server.port, request);
    };
    NSData * (^stored)(NSString *) = ^(NSString *name) {
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
    for (NSString *coding in @[@"deflate", @"br", @"gzip, gzip", @"bogus"]) {
        NSString *reply = put(@"bad.txt", coding, plain);
        XCTAssertTrue([reply hasPrefix:@"HTTP/1.1 415"], @"Content-Encoding: %@ should be refused: %@", coding, [reply substringToIndex:MIN((NSUInteger)40, reply.length)]);
        XCTAssertFalse([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"bad.txt"]], @"Content-Encoding: %@ stored the encoded octets as the entity", coding);
    }

    [server stop];
    [fm removeItemAtPath:dir error:NULL];
}

// Every way a request body could be refused answered 500. The fixed-length and chunked readers
// report failure as a plain BOOL, and every error they carried was `code:-1` distinguished only by
// its localized description, so the connection had nothing to key on.
//
// 500 is a claim that the SERVER broke. It tells a client to retry something that can never succeed
// (malformed chunk framing, a corrupt gzip stream) and makes it give up on something that could (a
// momentarily exhausted budget). Each of these now answers what it owes.
- (void)testRequestBodyRefusalsAnswerTheirOwnStatus {
    WSKWebServer *server = [[WSKWebServer alloc] init];
    [server addHandlerForMethod:@"POST"
                           path:@"/echo"
                   requestClass:[WSKDataRequest class]
                   processBlock:^WSKResponse *(WSKRequest *request) {
                       return [WSKDataResponse responseWithText:@"OK"];
                   }];
    [server addHandlerForMethod:@"POST"
                           path:@"/form"
                   requestClass:[WSKMultiPartFormRequest class]
                   processBlock:^WSKResponse *(WSKRequest *request) {
                       return [WSKDataResponse responseWithText:@"OK"];
                   }];
    NSDictionary *options = @{WSKOption_Port: @0, WSKOption_BindToLocalhost: @YES};
    XCTAssertTrue([server startWithOptions:options error:NULL]);

    // A chunk-size line that is not a hex number at all. The client's framing is wrong, so 400.
    NSString *badChunk = SendRawRequest(server.port, @"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabcd\r\n0\r\n\r\n");
    XCTAssertTrue([badChunk hasPrefix:@"HTTP/1.1 400"], @"a malformed chunk length is the client's error: %@", [badChunk substringToIndex:MIN((NSUInteger)40, badChunk.length)]);

    // A gzip stream that satisfies its Content-Length but stops part-way through. Also the client's.
    NSData *full = GZipCompress([NSMutableData dataWithLength:(64 * 1024)]);
    XCTAssertGreaterThan(full.length, (NSUInteger)20);
    NSData *prefix = [full subdataWithRange:NSMakeRange(0, 20)];
    NSMutableData *truncated = [[[NSString stringWithFormat:@"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/octet-stream\r\nContent-Encoding: gzip\r\nContent-Length: %lu\r\n\r\n", (unsigned long)prefix.length] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [truncated appendData:prefix];
    NSString *truncatedReply = SendRawDataRequest(server.port, truncated);
    XCTAssertTrue([truncatedReply hasPrefix:@"HTTP/1.1 400"], @"a truncated gzip body is the client's error: %@", [truncatedReply substringToIndex:MIN((NSUInteger)40, truncatedReply.length)]);

    // A body larger than the in-memory cap is a size problem, so 413 — not "the server broke".
    WSKSetMemoryLimitsForTesting(4 * 1024, 4 * 1024, 1024 * 1024);
    [self addTeardownBlock:^{
        WSKSetMemoryLimitsForTesting(0, 0, 0);
    }];

    NSMutableString *big = [NSMutableString string];

    while (big.length < 32 * 1024) {
        [big appendString:@"0123456789abcdef"];
    }

    NSString *oversized = SendRawRequest(server.port, [NSString stringWithFormat:@"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/octet-stream\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)big.length, big]);
    XCTAssertTrue([oversized hasPrefix:@"HTTP/1.1 413"], @"an oversized body owes 413: %@", [oversized substringToIndex:MIN((NSUInteger)40, oversized.length)]);

    // A chunk whose DATA is not followed by CRLF. A different branch from the bad size line above,
    // seventeen lines away in the same loop, and it was the one left answering 500 — which is why
    // both spellings are asserted rather than trusting that one covers the class.
    NSString *badTerminator = SendRawRequest(server.port, @"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcdXX\r\n0\r\n\r\n");
    XCTAssertTrue([badTerminator hasPrefix:@"HTTP/1.1 400"], @"a chunk not terminated by CRLF is the client's error: %@", [badTerminator substringToIndex:MIN((NSUInteger)40, badTerminator.length)]);

    // A multipart body with no usable boundary fails in -open:, whose error both readers used to
    // discard before aborting with a hardcoded 500.
    NSString *noBoundary = SendRawRequest(server.port, @"POST /form HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data\r\nContent-Length: 4\r\n\r\nxxxx");
    XCTAssertTrue([noBoundary hasPrefix:@"HTTP/1.1 400"], @"a multipart body with no boundary is malformed: %@", [noBoundary substringToIndex:MIN((NSUInteger)40, noBoundary.length)]);

    // The multipart parser fails for seven unrelated reasons through one `return NO`. Coding them
    // all as "malformed" — which the first version of this change did — turns a full disk and an
    // exhausted budget into 400, the status that says NEVER SEND THIS AGAIN. It is the same
    // mistake as answering 403 for ENOSPC, which this project fixed once already. A size cap must
    // read as a size problem.
    NSMutableString *part = [NSMutableString stringWithString:@"--B\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\n"];

    while (part.length < 32 * 1024) {
        [part appendString:@"0123456789abcdef"];
    }

    [part appendString:@"\r\n--B--\r\n"];
    NSString *oversizedPart = SendRawRequest(server.port, [NSString stringWithFormat:@"POST /form HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: %lu\r\n\r\n%@", (unsigned long)part.length, part]);
    XCTAssertTrue([oversizedPart hasPrefix:@"HTTP/1.1 413"], @"a multipart body over the size cap owes 413, not a permanent 400: %@", [oversizedPart substringToIndex:MIN((NSUInteger)40, oversizedPart.length)]);

    // And the half that must keep working: a body inside the cap is still served normally. A
    // status-mapping change is exactly where an over-refusal would hide.
    NSString *fine = SendRawRequest(server.port, @"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/octet-stream\r\nContent-Length: 5\r\n\r\nhello");
    XCTAssertTrue([fine hasPrefix:@"HTTP/1.1 200"], @"an ordinary body is unaffected: %@", [fine substringToIndex:MIN((NSUInteger)40, fine.length)]);
    XCTAssertTrue([fine hasSuffix:@"OK"], @"…and reaches the handler");

    [server stop];
}

// Every non-file part of a multipart body is retained in memory for the life of the
// request, so the parser's working-buffer cap does not bound them: a body made of many
// individually-legal argument parts grew without limit (200 MB of parts took the process
// to 626 MB) until the device killed the app.
- (void)testMultiPartRejectsUnboundedArgumentAccumulation {
    WSKMultiPartFormRequest *request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    XCTAssertTrue([request hasBody]);

    NSMutableData *filler = [NSMutableData dataWithLength:(512 * 1024)];
    memset(filler.mutableBytes, 'A', filler.length);

    NSError *error = nil;
    BOOL rejected = NO;

    // 64 x 512 KB is 32 MB of argument data, twice the in-memory cap.
    for (int i = 0; i < 64; i++) {
        NSMutableData *part = [NSMutableData data];
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
    WSKMultiPartFormRequest *request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});

    NSMutableString *hugeName = [NSMutableString string];
    while (hugeName.length < (64 * 1024)) {
        [hugeName appendString:@"AAAAAAAAAAAAAAAA"];
    }

    NSMutableData *part = [NSMutableData data];
    [part appendData:SSEData([NSString stringWithFormat:@"--X\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n\r\n", hugeName])];

    NSError *error = nil;
    XCTAssertFalse([request performWriteData:part error:&error], @"a part whose header block exceeds the cap should be rejected");
}

// A part whose Content-Disposition carries no "name" is malformed client input, not an
// unreachable state: it must fail the parse rather than abort the process.
- (void)testMultiPartRejectsPartWithoutControlNameWithoutAborting {
    WSKMultiPartFormRequest *request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    NSMutableData *body = [NSMutableData data];
    [body appendData:SSEData(@"--X\r\nContent-Disposition: form-data; filename=\"a.txt\"\r\n\r\npayload\r\n--X--\r\n")];

    NSError *error = nil;
    XCTAssertFalse([request performWriteData:body error:&error], @"a part with no control name should be rejected");
}

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
        NSMutableArray<WSKDataRequest *> *requests = [NSMutableArray array];
        NSMutableData *payload = [NSMutableData dataWithLength:(32 * 1024)];

        for (int i = 0; i < 16; i++) {
            WSKDataRequest *request = OpenBodyRequest([WSKDataRequest class], @{});
            [requests addObject:request];
            NSError *error = nil;

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

// Closing the parser releases its temporary buffers, but a handler can retain the completed
// request indefinitely. Its argument payloads must still occupy the process-wide budget.
- (void)testMultiPartArgumentsRemainChargedAfterClose {
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0);
    @autoreleasepool {
        WSKMultiPartFormRequest *const request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
        NSData *const body = MultipartArgumentBody(@"X", @[@257, @1024]);
        NSError *error = nil;
        XCTAssertTrue(WriteMultipartInSlices(request, body, &error), @"%@", error);
        XCTAssertTrue([request performClose:&error], @"%@", error);
        XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)1281, @"closing a parser must not uncharge its still-live arguments");
        XCTAssertEqual(request.arguments.count, (NSUInteger)2);
        XCTAssertEqual([request firstArgumentForControlName:@"a0"].data.length, (NSUInteger)257);
        XCTAssertEqual([request firstArgumentForControlName:@"a1"].data.length, (NSUInteger)1024);
    }
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0, @"the completed request released all of its fields");
}

// Reservation ownership follows each argument independently, not the request or one shared
// parser budget: retaining a 73-byte field must not pin its discarded 4 KB sibling's charge.
- (void)testMultiPartRetainedArgumentsReleaseTheirOwnBytes {
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0);
    WSKMultiPartArgument *small = nil;
    WSKMultiPartArgument *large = nil;
    __weak WSKMultiPartFormRequest *releasedRequest = nil;
    @autoreleasepool {
        WSKMultiPartFormRequest *const request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
        releasedRequest = request;
        NSError *error = nil;
        XCTAssertTrue(WriteMultipartInSlices(request, MultipartArgumentBody(@"X", @[@73, @4096]), &error), @"%@", error);
        XCTAssertTrue([request performClose:&error], @"%@", error);
        small = [request firstArgumentForControlName:@"a0"];
        large = [request firstArgumentForControlName:@"a1"];
    }
    XCTAssertNil(releasedRequest, @"retaining arguments must not keep their request alive");
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)4169, @"both detached argument payloads are still live");
    XCTAssertEqual(small.data.length, (NSUInteger)73);
    XCTAssertEqual(large.data.length, (NSUInteger)4096);
    large = nil;
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)73, @"a small argument must not pin a sibling's reservation");
    XCTAssertEqual(small.data.length, (NSUInteger)73, @"the remaining field is still usable");
    small = nil;
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0, @"the final field must return exactly its own bytes");
}

// Refusal must release parser scratch space without pretending that completed prefix fields
// disappeared. Exercise both a truncated body and a later part rejected while parsing headers.
- (void)testMultiPartFailedBodiesKeepRetainedPrefixArgumentsCharged {
    for (NSNumber *malformed in @[@NO, @YES]) {
        XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0);
        WSKMultiPartArgument *retained = nil;
        @autoreleasepool {
            WSKMultiPartFormRequest *const request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
            NSMutableData *const body = [MultipartArgumentPart(@"X", @"complete", 513) mutableCopy];
            NSString *const tail = malformed.boolValue ? @"--X\r\nContent-Disposition: form-data\r\n\r\nbad\r\n--X--\r\n" : @"--X\r\nContent-Disposition: form-data; name=\"unfinished\"\r\n\r\npartial";
            [body appendData:UTF8Data(tail)];
            NSError *error = nil;
            BOOL const wrote = WriteMultipartInSlices(request, body, &error);
            XCTAssertEqual(wrote, !malformed.boolValue, @"the fixture must reach the intended failure phase: %@", error);
            retained = [request firstArgumentForControlName:@"complete"];
            XCTAssertNotNil(retained, @"the first field must have completed before the later failure");
            BOOL const closed = [request performClose:&error];
            XCTAssertFalse(wrote && closed, @"either the write or close must refuse the malformed or truncated form");
            XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)513, @"failed close dropped a live prefix field's charge");
        }
        XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)513, @"a retained prefix argument must survive request teardown with its charge");
        XCTAssertEqual(retained.data.length, (NSUInteger)513);
        retained = nil;
        XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0);
    }
}

// Parent and nested parsers append to one request. Moving global reservations onto arguments
// must preserve the shared per-request sum, or nesting multiplies the permitted body size.
- (void)testMultiPartNestedArgumentsShareTheLimitAndKeepTheirCharges {
    WSKSetMemoryLimitsForTesting(1024, 4096, 16 * 1024);
    [self addTeardownBlock:^{ WSKSetMemoryLimitsForTesting(0, 0, 0); }];
    for (NSNumber *oversized in @[@NO, @YES]) {
        XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0);
        @autoreleasepool {
            NSUInteger const length = oversized.boolValue ? 600 : 400;
            NSMutableData *const body = [MultipartArgumentPart(@"X", @"outer", length) mutableCopy];
            [body appendData:UTF8Data(@"--X\r\nContent-Disposition: form-data; name=\"mixed\"\r\nContent-Type: multipart/mixed; boundary=Y\r\n\r\n")];
            [body appendData:MultipartArgumentBody(@"Y", @[@(length)])];
            [body appendData:UTF8Data(@"\r\n--X--\r\n")];
            WSKMultiPartFormRequest *const request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
            NSError *error = nil;
            BOOL const wrote = WriteMultipartInSlices(request, body, &error);
            BOOL const closed = [request performClose:&error];
            XCTAssertEqual(wrote && closed, !oversized.boolValue, @"parent and nested fields must share the 1 KB limit: %@", error);
            NSUInteger const expectedFields = oversized.boolValue ? 1 : 2;
            XCTAssertEqual(request.arguments.count, expectedFields, @"the first field must complete before the nested field is considered");
            XCTAssertEqual(WSKReservedMemoryLength(), expectedFields * length, @"only completed argument payloads should remain after close");
            XCTAssertEqual([request firstArgumentForControlName:@"outer"].data.length, length);
        }
        XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0);
    }
}

// Previously every successful close reset this accounting to zero while the requests still
// owned their fields, so completed forms could grow without ever filling the aggregate budget.
- (void)testMultiPartCompletedRequestsSaturateAndRecoverTheAggregateBudget {
    NSUInteger const valueLength = 2048;
    NSUInteger const totalLimit = 12 * 1024;
    WSKSetMemoryLimitsForTesting(8 * 1024, 8 * 1024, totalLimit);
    [self addTeardownBlock:^{ WSKSetMemoryLimitsForTesting(0, 0, 0); }];
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0);
    NSMutableArray<WSKMultiPartFormRequest *> *const held = [NSMutableArray array];
    NSData *const body = MultipartArgumentBody(@"X", @[@(valueLength)]);
    NSUInteger refused = 0;
    for (NSUInteger attempt = 0; attempt < 12; attempt++) {
        @autoreleasepool {
            WSKMultiPartFormRequest *const request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
            NSError *error = nil;
            BOOL const wrote = WriteMultipartInSlices(request, body, &error);
            if (wrote) {
                XCTAssertTrue([request performClose:&error], @"%@", error);
                [held addObject:request];
            } else {
                refused += 1;
                XCTAssertEqualObjects(error.domain, kWSKErrorDomain);
                XCTAssertEqual(error.code, (NSInteger)kWSKRequestBodyError_ServerAtCapacity, @"aggregate exhaustion must remain distinguishable from a malformed form");
                [request performClose:NULL];
            }
        }
        XCTAssertEqual(WSKReservedMemoryLength(), held.count * valueLength, @"only completed fields should remain charged between requests");
        XCTAssertLessThanOrEqual(WSKReservedMemoryLength(), totalLimit);
    }
    XCTAssertGreaterThan(held.count, (NSUInteger)0, @"the budget must allow an ordinary form");
    XCTAssertGreaterThan(refused, (NSUInteger)0, @"completed forms must eventually fill the budget");
    if (held.count) {
        @autoreleasepool {
            [held removeLastObject];
        }
        XCTAssertEqual(WSKReservedMemoryLength(), held.count * valueLength);
        @autoreleasepool {
            WSKMultiPartFormRequest *const replacement = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
            NSError *error = nil;
            XCTAssertTrue(WriteMultipartInSlices(replacement, body, &error), @"releasing one completed request must make room for its replacement: %@", error);
            XCTAssertTrue([replacement performClose:&error], @"%@", error);
            [held addObject:replacement];
        }
        XCTAssertEqual(WSKReservedMemoryLength(), held.count * valueLength);
    }
    [held removeAllObjects];
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0, @"all successfully parsed and refused forms released their reservations");
}

// Separate parsers can finish on different connection queues. The final charge must equal
// the payloads retained across all of them; checking after dispatch_apply avoids sampling a
// transient working-buffer reservation as though it were a completed argument.
- (void)testMultiPartConcurrentCompletedRequestsKeepTheirAggregateCharges {
    NSUInteger const valueLength = 1024;
    NSUInteger const totalLimit = 64 * 1024;  // Room for all 24 payloads AND every parser working buffer.
    WSKSetMemoryLimitsForTesting(4 * 1024, 4 * 1024, totalLimit);
    [self addTeardownBlock:^{ WSKSetMemoryLimitsForTesting(0, 0, 0); }];
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0);
    NSMutableArray<WSKMultiPartFormRequest *> *const held = [NSMutableArray array];
    NSData *const body = MultipartArgumentBody(@"X", @[@(valueLength)]);
    dispatch_apply(24, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
        @autoreleasepool {
            WSKMultiPartFormRequest *const request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
            BOOL const wrote = WriteMultipartInSlices(request, body, NULL);
            BOOL const closed = [request performClose:NULL];
            if (wrote && closed) {
                @synchronized(held) {
                    [held addObject:request];
                }
            }
        }
    });
    XCTAssertEqual(held.count, (NSUInteger)24, @"the generous budget must admit every concurrent form");
    XCTAssertEqual(WSKReservedMemoryLength(), held.count * valueLength, @"every completed request still owns its argument");
    XCTAssertLessThanOrEqual(held.count * valueLength, totalLimit, @"live payload bytes exceeded the global limit");
    [held removeAllObjects];
    XCTAssertEqual(WSKReservedMemoryLength(), (NSUInteger)0);
}

// Both properties are declared nullable and documented as returning nil when the body cannot be
// interpreted -- and both called WSK_DNOT_REACHED(), which is abort() in Debug. So the one case the
// header tells a host app to check for was the one case that killed the process instead.
//
// Against the unfixed tree this does not "fail": it takes the whole runner down and the output
// reads "Executed 0 tests, with 0 failures". Read the executed count, never the failure count --
// four of batch A's six fixes had exactly this signature.
- (void)testDataRequestTextAndJSONReturnNilRatherThanAbortingOnTheDocumentedCase {
    NSDictionary *octetStream = @{@"Content-Type": @"application/octet-stream", @"Content-Length": @"4"};
    WSKDataRequest *binary = OpenBodyRequest([WSKDataRequest class], octetStream);
    XCTAssertNotNil(binary);
    XCTAssertTrue([binary writeData:UTF8Data(@"data") error:NULL]);
    XCTAssertTrue([binary close:NULL]);

    // Not text/*, so -text has nothing to decode: the header says nil, so nil it must be.
    XCTAssertNil(binary.text, @"-text must honour its nullable declaration for a non-text content type");
    // Not a JSON type either.
    XCTAssertNil(binary.jsonObject, @"-jsonObject must honour its nullable declaration for a non-JSON content type");

    // A request with NO Content-Type at all -- the shape a bare POST produces.
    WSKDataRequest *untyped = OpenBodyRequest([WSKDataRequest class], @{@"Content-Length": @"2"});

    if (untyped) {
        XCTAssertTrue([untyped writeData:UTF8Data(@"hi") error:NULL]);
        XCTAssertTrue([untyped close:NULL]);
        XCTAssertNil(untyped.text, @"-text must return nil when there is no content type to judge");
        XCTAssertNil(untyped.jsonObject, @"-jsonObject must return nil when there is no content type to judge");
    }

    // The positive half: the cases that MUST keep working, so the fix cannot be "always return nil".
    NSDictionary *jsonHeaders = @{@"Content-Type": @"application/json", @"Content-Length": @"13"};
    WSKDataRequest *json = OpenBodyRequest([WSKDataRequest class], jsonHeaders);
    XCTAssertNotNil(json);
    XCTAssertTrue([json writeData:UTF8Data(@"{\"ok\":true}xx") error:NULL]);
    XCTAssertTrue([json close:NULL]);
    XCTAssertNil(json.jsonObject, @"malformed JSON is also a documented nil, not an abort");

    NSDictionary *textHeaders = @{@"Content-Type": @"text/plain; charset=utf-8", @"Content-Length": @"5"};
    WSKDataRequest *text = OpenBodyRequest([WSKDataRequest class], textHeaders);
    XCTAssertNotNil(text);
    XCTAssertTrue([text writeData:UTF8Data(@"hello") error:NULL]);
    XCTAssertTrue([text close:NULL]);
    XCTAssertEqualObjects(text.text, @"hello", @"a genuine text/* body must still decode");
}

// The Headers state refuses a part whose Content-Disposition carries no name= before the
// Content state is ever entered — the invariant the part constructors' nonnull control-name
// contracts stand on (the content-state guard added with the analyzer cleanup restates it
// locally). An empty VALUE, by contrast, is an ordinary blank form field and must parse to
// an argument holding empty data, not be confused with the nameless case.
- (void)testMultipartRefusesANamelessPartAndAcceptsAnEmptyValue {
    NSError *error = nil;

    WSKMultiPartFormRequest *nameless = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    NSData *namelessBody = SSEData(@"--X\r\nContent-Disposition: form-data\r\n\r\nvalue\r\n--X--\r\n");
    BOOL const namelessAccepted = [nameless performWriteData:namelessBody error:&error] && [nameless performClose:&error];
    XCTAssertFalse(namelessAccepted, @"a part with no control name must fail the parse");

    WSKMultiPartFormRequest *blank = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    NSData *blankBody = SSEData(@"--X\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\n\r\n--X--\r\n");
    XCTAssertTrue([blank performWriteData:blankBody error:&error], @"an empty value is an ordinary blank field: %@", error);
    XCTAssertTrue([blank performClose:&error], @"%@", error);
    WSKMultiPartArgument *argument = [blank firstArgumentForControlName:@"note"];
    XCTAssertNotNil(argument, @"the blank field must still be delivered");
    XCTAssertEqual(argument.data.length, (NSUInteger)0, @"a blank field's value is empty data");
}

// The 8 KB cap on a part's header block was checked only once the blank line ending the block
// had been seen, so a block that never ends grew to the 16 MB working buffer — and every
// appended byte rescanned all of it, which is quadratic and reachable by any client that
// segments the body. The cap must be judged on the bytes buffered, terminator or not.
- (void)testMultiPartRefusesAnUnterminatedPartHeaderBlockAtTheHeaderCap {
    WSKMultiPartFormRequest *request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    NSError *error = nil;
    XCTAssertTrue([request performWriteData:SSEData(@"--X\r\n") error:&error]);

    NSData *one = SSEData(@"a");  // a header block that never reaches its blank line
    NSUInteger accepted = 0;
    while (accepted < 9000 && [request performWriteData:one error:&error]) {
        accepted++;
    }

    XCTAssertGreaterThanOrEqual(accepted, (NSUInteger)8000, @"a header block within the cap must be accepted");
    XCTAssertLessThan(accepted, (NSUInteger)9000, @"the header block grew past the cap without being refused");
}

// The boundary search restarted from the front of the working buffer on every append, so an
// argument value delivered a few bytes at a time — a slow client, a proxy, or a hostile one —
// cost time quadratic in its length. Only bytes that could still complete a boundary need
// re-examining. The equality check proves a boundary straddling every append edge is still
// found and the value arrives whole.
- (void)testMultiPartArgumentDeliveredOneByteAtATimeCostsLinearTime {
    WSKMultiPartFormRequest *request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    NSError *error = nil;
    XCTAssertTrue([request performWriteData:SSEData(@"--X\r\nContent-Disposition: form-data; name=\"big\"\r\n\r\n") error:&error]);

    NSMutableData *value = [NSMutableData dataWithLength:(64 * 1024)];
    memset(value.mutableBytes, 'v', value.length);
    NSMutableData *rest = [NSMutableData dataWithData:value];
    [rest appendData:SSEData(@"\r\n--X--\r\n")];

    NSTimeInterval cpuBefore = ProcessCPUSeconds();
    const unsigned char *bytes = rest.bytes;
    for (NSUInteger i = 0; i < rest.length; i++) {
        if (![request performWriteData:[NSData dataWithBytes:(bytes + i) length:1] error:&error]) {
            XCTFail(@"write %lu refused: %@", (unsigned long)i, error);
            return;
        }
    }
    XCTAssertTrue([request performClose:&error], @"%@", error);
    NSTimeInterval cpuSpent = ProcessCPUSeconds() - cpuBefore;

    WSKMultiPartArgument *argument = [request firstArgumentForControlName:@"big"];
    XCTAssertEqualObjects(argument.data, value, @"the value must arrive whole and exact");
    XCTAssertLessThan(cpuSpent, 1.0, @"a %lu byte value written one byte at a time cost %.2f s of CPU: the parser is not linear", (unsigned long)value.length, cpuSpent);
}

// Bytes before the first boundary are a preamble the RFC says to ignore, but the parser kept
// them in its working buffer and rescanned them on every append: a preamble longer than the
// in-memory cap failed the request, and a shorter one cost quadratic time. Discard it as it
// streams, keeping only enough to recognise a boundary that straddles two appends.
- (void)testMultiPartDiscardsThePreambleWithoutBufferingIt {
    WSKSetMemoryLimitsForTesting(1024 * 1024, 16 * 1024 * 1024, 64 * 1024 * 1024);
    [self addTeardownBlock:^{
        WSKSetMemoryLimitsForTesting(0, 0, 0);
    }];

    WSKMultiPartFormRequest *request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    NSError *error = nil;
    NSMutableData *junk = [NSMutableData dataWithLength:(64 * 1024)];
    memset(junk.mutableBytes, 'z', junk.length);
    for (NSUInteger written = 0; written < 4 * 1024 * 1024; written += junk.length) {  // four times the cap
        if (![request performWriteData:junk error:&error]) {
            XCTFail(@"the preamble was buffered instead of discarded: refused after %lu bytes (%@)", (unsigned long)written, error);
            return;
        }
    }

    XCTAssertTrue([request performWriteData:SSEData(@"\r\n--X\r\nContent-Disposition: form-data; name=\"k\"\r\n\r\nv\r\n--X--\r\n") error:&error], @"%@", error);
    XCTAssertTrue([request performClose:&error], @"%@", error);
    XCTAssertEqualObjects([request firstArgumentForControlName:@"k"].data, SSEData(@"v"), @"the part after the preamble must still parse");
}

// The working-buffer cap was applied to the size of a single socket read, before the file
// content in that read had drained to disk — so a 1 GB upload over loopback, or through a
// reverse proxy on the same host, answered 413 whenever the kernel handed the server more than
// 16 MB at once. Only bytes the parser genuinely retains may count against the cap.
- (void)testMultiPartAcceptsASingleWriteLargerThanTheInMemoryCapForFileContent {
    WSKSetMemoryLimitsForTesting(1024 * 1024, 16 * 1024 * 1024, 64 * 1024 * 1024);
    [self addTeardownBlock:^{
        WSKSetMemoryLimitsForTesting(0, 0, 0);
    }];

    WSKMultiPartFormRequest *request = OpenBodyRequest([WSKMultiPartFormRequest class], @{@"Content-Type": @"multipart/form-data; boundary=X"});
    NSError *error = nil;
    XCTAssertTrue([request performWriteData:SSEData(@"--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"big.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n") error:&error]);

    NSMutableData *write = [NSMutableData dataWithLength:(3 * 1024 * 1024)];  // three times the cap, in ONE write
    [write appendData:SSEData(@"\r\n--X--\r\n")];
    XCTAssertTrue([request performWriteData:write error:&error], @"a single write of file content larger than the cap must drain to disk, not be refused: %@", error);
    XCTAssertTrue([request performClose:&error], @"%@", error);

    WSKMultiPartFile *file = [request firstFileForControlName:@"f"];
    XCTAssertNotNil(file);
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:file.temporaryPath error:&error];
    XCTAssertEqual(attributes.fileSize, (unsigned long long)(3 * 1024 * 1024), @"the file part must land whole (%@)", error);
}

@end
