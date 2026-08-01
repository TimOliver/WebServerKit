/*
   Copyright (c) 2012-2019, Pierre-Olivier Latour
   All rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
   or promote products derived from this software without specific
   prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
   ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
   WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
   DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
   DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
   (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
   LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
   ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#if !__has_feature(objc_arc)
#error WSKWebServer requires ARC
#endif

#import <zlib.h>

#import "WSKPrivate.h"

#define kGZipInitialBufferSize (256 * 1024)

@interface WSKBodyEncoder : NSObject <WSKBodyReader>
- (BOOL)hasAsyncReader;
@end

@interface WSKGZipEncoder : WSKBodyEncoder
@end

@implementation WSKBodyEncoder {
    WSKResponse *__unsafe_unretained _response;
    id<WSKBodyReader> __unsafe_unretained _reader;
}

- (instancetype)initWithResponse:(WSKResponse *_Nonnull)response reader:(id<WSKBodyReader> _Nonnull)reader {
    if ((self = [super init])) {
        _response = response;
        _reader = reader;
    }

    return self;
}

- (BOOL)open:(NSError **)error {
    return [_reader open:error];
}

- (NSData *)readData:(NSError **)error {
    return [_reader readData:error];
}

// The encoder chain must expose the asynchronous path as well: a reader that only
// implements -asyncReadDataWithCompletion: (WSKStreamedResponse does) would
// otherwise fall through to the base -readData:, which returns empty data — encoding
// an empty body and never running the stream block at all.
- (void)asyncReadDataWithCompletion:(WSKBodyReaderCompletionBlock)block {
    if ([_reader respondsToSelector:@selector(asyncReadDataWithCompletion:)]) {
        [_reader asyncReadDataWithCompletion:[block copy]];  // The reader may park the block, so it must live on the heap
    } else {
        NSError *error = nil;
        NSData *const data = [_reader readData:&error];
        block(data, error);
    }
}

- (BOOL)hasAsyncReader {
    return [_reader respondsToSelector:@selector(asyncReadDataWithCompletion:)];
}

- (void)close {
    [_reader close];
}

@end

@implementation WSKGZipEncoder {
    z_stream _stream;
    BOOL _finished;
}

- (instancetype)initWithResponse:(WSKResponse *_Nonnull)response reader:(id<WSKBodyReader> _Nonnull)reader {
    if ((self = [super initWithResponse:response reader:reader])) {
        response.contentLength = NSUIntegerMax;  // Make sure "Content-Length" header is not set since we don't know it
        [response setValue:@"gzip" forAdditionalHeader:@"Content-Encoding"];
    }

    return self;
}

- (BOOL)open:(NSError **)error {
    int result = deflateInit2(&_stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);

    if (result != Z_OK) {
        if (error) {
            *error = [NSError errorWithDomain:kZlibErrorDomain code:result userInfo:nil];
        }

        return NO;
    }

    if (![super open:error]) {
        deflateEnd(&_stream);
        return NO;
    }

    return YES;
}

// Deflates one source chunk into "encodedData" starting at "*length", growing the buffer
// as zlib fills it and advancing "*length" by the bytes produced. The caller picks the
// flush mode: Z_FINISH for the final (empty) chunk, Z_NO_FLUSH to let zlib buffer.
- (BOOL)_deflateData:(NSData *)data flush:(int)flush into:(NSMutableData *)encodedData length:(NSUInteger *)length error:(NSError **)error {
    _stream.next_in = (Bytef *)data.bytes;
    _stream.avail_in = (uInt)data.length;

    while (1) {
        NSUInteger maxLength = encodedData.length - *length;
        _stream.next_out = (Bytef *)((char *)encodedData.mutableBytes + *length);
        _stream.avail_out = (uInt)maxLength;
        int result = deflate(&_stream, flush);

        if (result == Z_STREAM_END) {
            _finished = YES;
        } else if (result != Z_OK) {
            if (error) {
                *error = [NSError errorWithDomain:kZlibErrorDomain code:result userInfo:nil];
            }

            return NO;
        }

        *length += maxLength - _stream.avail_out;

        if (_stream.avail_out > 0) {
            break;
        }

        encodedData.length = 2 * encodedData.length;  // zlib has used all the output buffer so resize it and try again in case more data is available
    }
    WSK_DCHECK(_stream.avail_in == 0);
    return YES;
}

// A 256 KB allocation can genuinely fail under memory pressure on a device, so this is an
// ordinary runtime error and not a WSK_DNOT_REACHED() assertion (which aborts in Debug).
- (NSMutableData *)_allocateEncodingBuffer:(NSError **)error {
    NSMutableData *const encodedData = [[NSMutableData alloc] initWithLength:kGZipInitialBufferSize];

    if (encodedData == nil) {
        WSK_LOG_ERROR(@"Failed allocating gzip encoding buffer of %i bytes", kGZipInitialBufferSize);

        if (error) {
            *error = WSKMakePosixError(ENOMEM);
        }
    }

    return encodedData;
}

- (NSData *)readData:(NSError **)error {
    NSMutableData *encodedData;

    if (_finished) {
        encodedData = [[NSMutableData alloc] init];
    } else {
        encodedData = [self _allocateEncodingBuffer:error];

        if (encodedData == nil) {
            return nil;
        }

        NSUInteger length = 0;
        do {
            NSData *data = [super readData:error];

            if (data == nil) {
                return nil;
            }

            const int flush = data.length ? Z_NO_FLUSH : Z_FINISH;

            if (![self _deflateData:data flush:flush into:encodedData length:&length error:error]) {
                return nil;
            }
        } while (length == 0);  // Make sure we don't return an empty NSData if not in finished state
        encodedData.length = length;
    }

    return encodedData;
}

- (void)asyncReadDataWithCompletion:(WSKBodyReaderCompletionBlock)block {
    if (![self hasAsyncReader]) {
        // The reader below is synchronous, so keep using the synchronous loop: it reads
        // more input when a chunk buffers to nothing instead of forcing a flush, which
        // compresses marginally better.
        NSError *error = nil;
        NSData *const data = [self readData:&error];
        block(data, error);
        return;
    }

    if (_finished) {
        block([NSData data], nil);
        return;
    }

    NSError *bufferError = nil;
    NSMutableData *const encodedData = [self _allocateEncodingBuffer:&bufferError];

    if (encodedData == nil) {
        block(nil, bufferError);
        return;
    }

    [super asyncReadDataWithCompletion:^(NSData *data, NSError *readError) {
        if (data == nil) {
            block(nil, readError);
            return;
        }

        NSError *encodeError = nil;
        NSUInteger length = 0;
        const int flush = data.length ? Z_NO_FLUSH : Z_FINISH;

        if (![self _deflateData:data flush:flush into:encodedData length:&length error:&encodeError]) {
            block(nil, encodeError);
            return;
        }

        if ((length == 0) && !self->_finished) {
            // zlib buffered the whole chunk. Empty data is the connection's end-of-body
            // sentinel, and unlike the synchronous loop this path cannot read more input
            // without recursing once per chunk, so force the pending output out instead.
            if (![self _deflateData:[NSData data] flush:Z_SYNC_FLUSH into:encodedData length:&length error:&encodeError]) {
                block(nil, encodeError);
                return;
            }
        }

        encodedData.length = length;
        block(encodedData, nil);
    }];
}

- (void)close {
    deflateEnd(&_stream);
    [super close];
}

@end

@implementation WSKResponse {
    BOOL _opened;
    NSMutableArray<WSKBodyEncoder *> *_encoders;
    id<WSKBodyReader> __unsafe_unretained _reader;
}

+ (instancetype)response {
    return [(WSKResponse *)[[self class] alloc] init];
}

- (instancetype)init {
    if ((self = [super init])) {
        _contentType = nil;
        _contentLength = NSUIntegerMax;
        _statusCode = kWSKHTTPStatusCode_OK;
        _cacheControlMaxAge = 0;
        _additionalHeaders = [[NSMutableDictionary alloc] init];
        _encoders = [[NSMutableArray alloc] init];
    }

    return self;
}

- (void)setValue:(NSString *)value forAdditionalHeader:(NSString *)header {
    // CFHTTPMessageSetHeaderFieldValue drops a header whose *value* contains CR or LF, but
    // it happily serializes those characters in a header *name* — so a name assembled from
    // untrusted input would split the response and inject headers of the attacker's
    // choosing. No caller in this library does that, but this is the chokepoint, and a host
    // app naming a header after request data should not be able to forge a response.
    // RFC 9112 §5: field-name = 1*tchar. The previous guard quoted that rule and then enforced
    // only the EMPTY spelling of it, which left every other violation reachable — most sharply a
    // name beginning with a space, which serializes as an obs-fold continuation line and is
    // therefore appended to the PRECEDING header's value (measured against the real Date header).
    // An interior space, a tab and a non-ASCII name all went out verbatim too.
    //
    // WSKIsHeaderTokenString is the request parser's own rule, shared rather than restated: a
    // second implementation of a rule beside the live one is what this file keeps getting wrong.
    if (!WSKIsHeaderTokenString(header)) {
        WSK_LOG_ERROR(@"Ignoring additional response header with an invalid name \"%@\"", header);
        return;
    }

    [_additionalHeaders setValue:value forKey:header];
}

- (NSString *)valueForAdditionalHeader:(NSString *)header {
    return [_additionalHeaders objectForKey:header];
}

- (BOOL)hasBody {
    return _contentType ? YES : NO;
}

- (BOOL)usesChunkedTransferEncoding {
    return (_contentType != nil) && (_contentLength == NSUIntegerMax);
}

- (BOOL)open:(NSError **)error {
    return YES;
}

- (NSData *)readData:(NSError **)error {
    return [NSData data];
}

- (void)close {
}

- (void)prepareForReading {
    _reader = self;

    if (_gzipContentEncodingEnabled) {
        // A Content-Range describes offsets into the *selected representation*, so it is
        // only true of the identity coding. Compressing a partial response left the 206
        // asserting identity offsets for a gzip body, and a client reassembling ranges
        // then concatenates independent gzip members at offsets that do not line up.
        // Serve the range honestly rather than half-honouring both.
        if ((_statusCode == kWSKHTTPStatusCode_PartialContent) || [self valueForAdditionalHeader:@"Content-Range"]) {
            WSK_LOG_ERROR(@"Not gzip-encoding a partial response: its Content-Range describes the identity coding");
        } else {
            WSKGZipEncoder *const encoder = [[WSKGZipEncoder alloc] initWithResponse:self reader:_reader];
            [_encoders addObject:encoder];
            _reader = encoder;
        }
    }
}

- (BOOL)performOpen:(NSError **)error {
    WSK_DCHECK(_contentType);
    WSK_DCHECK(_reader);

    if (_opened) {
        WSK_DNOT_REACHED();
        return NO;
    }

    _opened = YES;
    return [_reader open:error];
}

- (void)performReadDataWithCompletion:(WSKBodyReaderCompletionBlock)block {
    WSK_DCHECK(_opened);

    // Guard against a body reader (typically a stream block) that invokes its completion
    // more than once: a second call would start a second write chain on the same socket,
    // interleaving the chunk framing, and would run -performClose twice — a double
    // deflateEnd() for a gzip chain and a double close() of the file descriptor for a
    // file response. Mirrors the same guard on the handler completion in
    // -[WSKConnection _startProcessingRequest].
    __block BOOL read = NO;
    const WSKBodyReaderCompletionBlock guardedBlock = ^(NSData *data, NSError *error) {
        if (read) {
            WSK_LOG_ERROR(@"Ignoring extra body reader completion block invocation");
            return;
        }

        read = YES;
        block(data, error);
    };

    if ([_reader respondsToSelector:@selector(asyncReadDataWithCompletion:)]) {
        [_reader asyncReadDataWithCompletion:[guardedBlock copy]];
    } else {
        NSError *error = nil;
        NSData *const data = [_reader readData:&error];
        guardedBlock(data, error);
    }
}

- (void)performClose {
    WSK_DCHECK(_opened);
    [_reader close];
}

- (NSString *)description {
    NSMutableString *description = [NSMutableString stringWithFormat:@"Status Code = %i", (int)_statusCode];

    if (_contentType) {
        [description appendFormat:@"\nContent Type = %@", _contentType];
    }

    if (_contentLength != NSUIntegerMax) {
        [description appendFormat:@"\nContent Length = %lu", (unsigned long)_contentLength];
    }

    [description appendFormat:@"\nCache Control Max Age = %lu", (unsigned long)_cacheControlMaxAge];

    if (_lastModifiedDate) {
        [description appendFormat:@"\nLast Modified Date = %@", _lastModifiedDate];
    }

    if (_eTag) {
        [description appendFormat:@"\nETag = %@", _eTag];
    }

    if (_additionalHeaders.count) {
        [description appendString:@"\n"];

        for (NSString *header in [[_additionalHeaders allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            [description appendFormat:@"\n%@: %@", header, _additionalHeaders[header]];
        }
    }

    return description;
}

@end

@implementation WSKResponse (Extensions)

+ (instancetype)responseWithStatusCode:(NSInteger)statusCode {
    return [(WSKResponse *)[self alloc] initWithStatusCode:statusCode];
}

+ (instancetype)responseWithRedirect:(NSURL *)location permanent:(BOOL)permanent {
    return [(WSKResponse *)[self alloc] initWithRedirect:location permanent:permanent];
}

- (instancetype)initWithStatusCode:(NSInteger)statusCode {
    if ((self = [self init])) {
        self.statusCode = statusCode;
    }

    return self;
}

- (instancetype)initWithRedirect:(NSURL *)location permanent:(BOOL)permanent {
    if ((self = [self init])) {
        self.statusCode = permanent ? kWSKHTTPStatusCode_MovedPermanently : kWSKHTTPStatusCode_TemporaryRedirect;
        [self setValue:[location absoluteString] forAdditionalHeader:@"Location"];
    }

    return self;
}

@end
