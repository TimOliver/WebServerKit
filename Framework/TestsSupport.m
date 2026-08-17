// Shared support for the test suites.
//
// The suite used to be one 6,000-line Tests.m holding every test in a single XCTestCase. It is now
// one file per subject, and everything they share lives here: the socket and HTTP helpers, the gzip
// pair, the temp-directory helper, and the probe classes that exist only to observe the server from
// the inside.
//
// These were `static` in the old single file. They are external now because more than one suite
// needs them; nothing else changed.

#import "TestsSupport.h"

#import <netinet/in.h>
#import <sys/socket.h>
#import <zlib.h>

#pragma clang diagnostic ignored "-Weverything"

NSData* SSEData(NSString* string) {
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

// The two nonnull-laundering helpers for fixture literals. -dataUsingEncoding: and +URLWithString:
// are nullable, which is true in general and never true for the literals tests are built from —
// but an inline cast at every call site is a lie with no witness, so the assertion lives here
// instead: a fixture that genuinely fails to convert stops the test at the point of failure.
NSData* UTF8Data(NSString* string) {
    NSData* data = [string dataUsingEncoding:NSUTF8StringEncoding];
    NSCAssert(data != nil, @"fixture string did not encode as UTF-8: %@", string);
    return data;
}

NSURL* LiteralURL(NSString* string) {
    NSURL* url = [NSURL URLWithString:string];
    NSCAssert(url != nil, @"fixture URL literal did not parse: %@", string);
    return url;
}

// Opens a raw TCP connection to localhost:port with a 5 second receive timeout,
// so tests can exercise server behavior below the HTTP-client abstraction.
int ConnectToLocalhostPort(NSUInteger port) {
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

// Drains to EOF at a deliberate pace: read a chunk, pause, repeat. Counting the bytes is all the
// caller wants, so nothing is accumulated.
//
// The pacing is the whole point and a plain sleep will not do. A client that simply stops reading
// stalls the server's pending write, and the ordinary response-phase idle rule reclaims it after
// two tickless — correctly. Pacing keeps bytes moving on every tick, so that rule can never fire,
// while the transfer still spans several ticks. Anything that cuts the response short under those
// conditions is a deadline being applied where it does not belong.
NSUInteger DrainToEOFAtPace(int fd, NSUInteger chunkSize, useconds_t pauseMicroseconds) {
    void* const buffer = malloc(chunkSize);
    NSUInteger total = 0;

    if (buffer == NULL) {
        return 0;
    }

    while (1) {
        ssize_t const got = recv(fd, buffer, chunkSize, 0);

        if (got <= 0) {
            break;  // 0 is EOF; negative is the reset a reclaimed connection produces, or the timeout
        }

        total += (NSUInteger)got;
        usleep(pauseMicroseconds);
    }

    free(buffer);
    return total;
}

// Reads until the peer closes the connection (EOF) or the receive timeout fires.
// Returns the accumulated bytes; *sawEOF reports whether EOF was actually seen.
NSData* ReadToEOF(int fd, BOOL* sawEOF) {
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
NSData* GZipDecompress(NSData* input) {
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
NSData* DrainResponseBody(WSKResponse* response) {
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
NSData* GZipCompress(NSData* input) {
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
__kindof WSKRequest* OpenBodyRequest(Class requestClass, NSDictionary* extraHeaders) {
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
NSString* SendRawRequest(NSUInteger port, NSString* request) {
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

// Sends several requests over ONE connection, returning each reply separately. Unlike
// SendRawRequest it cannot read to EOF between requests — on a reused connection there is no EOF
// until the last one — so each reply is delimited by its own framing: the header block is read,
// then exactly Content-Length bytes. A reply that never completes ends the run rather than
// hanging, and the count of replies returned is what the caller asserts on.
NSArray<NSString*>* SendRawRequestsOnOneConnection(NSUInteger port, NSArray<NSString*>* requests) {
    int fd = ConnectToLocalhostPort(port);
    if (fd < 0) {
        return @[];
    }

    struct timeval tv = {2, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    NSMutableArray<NSString*>* replies = [NSMutableArray array];
    NSMutableData* buffered = [NSMutableData data];

    for (NSString* request in requests) {
        const char* bytes = [request UTF8String];
        if (send(fd, bytes, strlen(bytes), 0) < 0) {
            break;
        }

        // A HEAD response carries the Content-Length a GET would have produced, and no body.
        // Waiting for those bytes stalls until the receive timeout, and the write that follows
        // then races the server's keep-alive teardown — which surfaced as an intermittent 400
        // under full-suite load, from the server parsing a partially-written request.
        BOOL const expectsNoBody = [request hasPrefix:@"HEAD "];

        // Read until this reply's header block plus its declared body are both in hand.
        NSData* terminator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange headerEnd = NSMakeRange(NSNotFound, 0);
        NSInteger expected = -1;
        BOOL stalled = NO;

        while (!stalled) {
            if (headerEnd.location == NSNotFound) {
                headerEnd = [buffered rangeOfData:terminator options:0 range:NSMakeRange(0, buffered.length)];

                if (headerEnd.location != NSNotFound) {
                    NSString* head = [[NSString alloc] initWithData:[buffered subdataWithRange:NSMakeRange(0, NSMaxRange(headerEnd))] encoding:NSUTF8StringEncoding];
                    NSRange lengthRange = [head rangeOfString:@"Content-Length: " options:NSCaseInsensitiveSearch];
                    expected = 0;

                    if ((lengthRange.location != NSNotFound) && !expectsNoBody) {
                        expected = [[head substringFromIndex:NSMaxRange(lengthRange)] integerValue];
                    }
                }
            }

            if ((headerEnd.location != NSNotFound) && ((NSInteger)(buffered.length - NSMaxRange(headerEnd)) >= expected)) {
                break;
            }

            char chunk[4096];
            ssize_t got = recv(fd, chunk, sizeof(chunk), 0);

            if (got <= 0) {
                stalled = YES;
            } else {
                [buffered appendBytes:chunk length:(NSUInteger)got];
            }
        }

        if (headerEnd.location == NSNotFound) {
            break;  // No complete reply arrived; the caller sees a short array.
        }

        NSUInteger const total = NSMaxRange(headerEnd) + (NSUInteger)MAX((NSInteger)0, expected);
        NSUInteger const take = MIN(total, buffered.length);
        NSString* reply = [[NSString alloc] initWithData:[buffered subdataWithRange:NSMakeRange(0, take)] encoding:NSUTF8StringEncoding];
        [replies addObject:(reply ? reply : @"")];
        [buffered replaceBytesInRange:NSMakeRange(0, take) withBytes:NULL length:0];
    }

    close(fd);
    return replies;
}

// As SendRawDataRequest, but split into two writes with a pause, so the tail arrives in a
// separate socket read. Used to prove a verdict does not depend on how the client segmented.
NSString* SendRawDataRequestSplit(NSUInteger port, NSData* request, NSUInteger splitAt) {
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
NSString* SendRawDataRequest(NSUInteger port, NSData* request) {
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
NSString* SendRawRequestUntilMarker(NSUInteger port, NSString* request, NSString* marker, NSTimeInterval seconds) {
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
NSUInteger OpenFileDescriptorCount(void) {
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/dev/fd" error:NULL].count;
}

NSString* MakeTempDirectory(void) {
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
NSString* gAbortRequestPeer = nil;
BOOL gAbortRequestSawVirtualHEAD = NO;

@implementation AbortProbeConnection

- (void)abortRequest:(WSKRequest*)request withStatusCode:(NSInteger)statusCode {
    gAbortRequestPeer = request.remoteAddressString;
    gAbortRequestSawVirtualHEAD = request.isVirtualHEAD;
    [super abortRequest:request withStatusCode:statusCode];
}

@end


NSMutableArray<NSString*>* gConnectionEvents = nil;

@implementation LifecycleProbeConnection

// Appended to from the connection queue, read from the test thread only after the server has
// stopped, which is a full barrier over every connection queue.
- (BOOL)open {
    BOOL const opened = [super open];
    @synchronized(gConnectionEvents) {
        [gConnectionEvents addObject:@"open"];
    }
    return opened;
}

- (void)abortRequest:(WSKRequest*)request withStatusCode:(NSInteger)statusCode {
    @synchronized(gConnectionEvents) {
        [gConnectionEvents addObject:[NSString stringWithFormat:@"abort %i", (int)statusCode]];
    }
    [super abortRequest:request withStatusCode:statusCode];
}

- (void)close {
    @synchronized(gConnectionEvents) {
        [gConnectionEvents addObject:@"close"];
    }
    [super close];
}

@end


// Two delegates for the weak-delegate swap test below. The distinction that matters is that BOTH
// conform to the protocol and BOTH are alive: WSKFullDelegate implements the optional callback,
// WSKPartialDelegate does not. Every method in these protocols is @optional, so an object
// implementing a subset is the designed-for case, not an abuse.
@implementation WSKFullDelegate
- (void)webServerDidStart:(WSKWebServer*)server {
    _sawStart = YES;
}
@end

@implementation WSKPartialDelegate
// Deliberately implements a DIFFERENT optional method, so it conforms and is a plausible delegate
// while not responding to -webServerDidStart:.
- (void)webServerDidConnect:(WSKWebServer*)server {
    _sawConnect = YES;
}
@end

// Builds `levels` nested "multipart/mixed" wrappers around a single text leaf part.
// Boundaries: `top` for the outermost part, then mix1..mix{levels} for the nested
// parts; the leaf lives inside boundary mix{levels}.
NSData* NestedMultipartMixedBody(NSString* top, NSUInteger levels) {
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

// Extracts a quoted directive value (e.g. nonce="…") from a header line.
NSString* QuotedParam(NSString* header, NSString* name) {
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
