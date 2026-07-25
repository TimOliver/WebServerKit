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
#error GCDWebServer requires ARC
#endif

#import <zlib.h>

#import "GCDWebServerPrivate.h"

NSString *const GCDWebServerRequestAttribute_RegexCaptures = @"GCDWebServerRequestAttribute_RegexCaptures";

#define kZlibErrorDomain @"ZlibErrorDomain"
#define kGZipInitialBufferSize (256 * 1024)

@interface GCDWebServerBodyDecoder : NSObject <GCDWebServerBodyWriter>
@end

@interface GCDWebServerGZipDecoder : GCDWebServerBodyDecoder
@end

@implementation GCDWebServerBodyDecoder {
    GCDWebServerRequest *__unsafe_unretained _request;
    id<GCDWebServerBodyWriter> __unsafe_unretained _writer;
}

- (instancetype)initWithRequest:(GCDWebServerRequest *_Nonnull)request writer:(id<GCDWebServerBodyWriter> _Nonnull)writer {
    if ((self = [super init])) {
        _request = request;
        _writer = writer;
    }

    return self;
}

- (BOOL)open:(NSError **)error {
    return [_writer open:error];
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    return [_writer writeData:data error:error];
}

- (BOOL)close:(NSError **)error {
    return [_writer close:error];
}

@end

@implementation GCDWebServerGZipDecoder {
    z_stream _stream;
    BOOL _finished;
    NSUInteger _totalDecoded;
    GCDWebServerMemoryReservation *_reservation;
}

- (BOOL)open:(NSError **)error {
    int result = inflateInit2(&_stream, 15 + 16);

    if (result != Z_OK) {
        if (error) {
            *error = [NSError errorWithDomain:kZlibErrorDomain code:result userInfo:nil];
        }

        return NO;
    }

    if (![super open:error]) {
        inflateEnd(&_stream);
        return NO;
    }

    _reservation = [[GCDWebServerMemoryReservation alloc] init];
    return YES;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    // The stream already reported Z_STREAM_END, so these bytes are either padding
    // after the member or a second concatenated member. Refuse rather than discard:
    // silently dropping them hands the handler less data than the client sent while
    // still answering with a success status, and the client has no way to tell.
    // (This was a GWS_DCHECK, which aborts a Debug build on a remote request.)
    if (_finished) {
        if (data.length) {
            GWS_LOG_ERROR(@"Trailing data after the end of the gzip request body");

            if (error) {
                *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Trailing data after end of gzip request body"}];
            }

            return NO;
        }

        return YES;
    }

    _stream.next_in = (Bytef *)data.bytes;
    _stream.avail_in = (uInt)data.length;
    NSMutableData *decodedData = [[NSMutableData alloc] initWithLength:kGZipInitialBufferSize];

    if (decodedData == nil) {
        GWS_DNOT_REACHED();
        return NO;
    }

    // Charge the working buffer against the process-wide budget as soon as it exists,
    // and again below whenever it grows — see the note at the release site for why the
    // charge tracks the live buffer rather than the running total.
    if (![_reservation reserveBytes:decodedData.length]) {
        GWS_LOG_ERROR(@"Refusing to inflate: the server is already holding its %lu byte in-memory limit across all connections", (unsigned long)kGCDWebServerMaxTotalInMemoryLength);

        if (error) {
            *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Server is at its total in-memory capacity"}];
        }

        return NO;
    }

    NSUInteger length = 0;

    while (1) {
        NSUInteger maxLength = decodedData.length - length;
        _stream.next_out = (Bytef *)((char *)decodedData.mutableBytes + length);
        _stream.avail_out = (uInt)maxLength;
        int result = inflate(&_stream, Z_NO_FLUSH);

        if ((result != Z_OK) && (result != Z_STREAM_END)) {
            if (error) {
                *error = [NSError errorWithDomain:kZlibErrorDomain code:result userInfo:nil];
            }

            return NO;
        }

        length += maxLength - _stream.avail_out;

        // Bound total inflated output so a small highly-compressible body (a "zip
        // bomb") cannot balloon the output buffer and exhaust memory. Checked inside
        // the loop, before the next doubling, so we stop growing as soon as the cap
        // is crossed rather than after allocating past it.
        if (_totalDecoded + length > GCDWebServerMaxDecompressedBodyLength()) {
            GWS_LOG_ERROR(@"Decompressed request body exceeds the %lu byte limit", (unsigned long)GCDWebServerMaxDecompressedBodyLength());

            if (error) {
                *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Decompressed request body exceeds maximum size"}];
            }

            return NO;
        }

        if (_stream.avail_out > 0) {
            if (result == Z_STREAM_END) {
                _finished = YES;
            }

            break;
        }

        // zlib has used all the output buffer, so grow it and try again in case more
        // data is available — but never beyond the decompressed-size budget still
        // remaining for this stream (plus one byte, so the next inflate can cross the
        // cap and be rejected by the check above). Without this clamp a body that
        // inflates to just over the cap first doubles the buffer to twice the cap
        // (128 MB for the 64 MB cap) and commits it before the next check rejects it.
        NSUInteger maxBufferLength = GCDWebServerMaxDecompressedBodyLength() - _totalDecoded + 1;
        NSUInteger newBufferLength = 2 * decodedData.length;
        NSUInteger targetBufferLength = (newBufferLength < maxBufferLength) ? newBufferLength : maxBufferLength;

        // Charge the larger buffer before committing to it, not after, so the budget is
        // never briefly exceeded by an allocation we have already made.
        if (![_reservation reserveBytes:targetBufferLength]) {
            GWS_LOG_ERROR(@"Refusing to inflate further: the server is already holding its %lu byte in-memory limit across all connections", (unsigned long)kGCDWebServerMaxTotalInMemoryLength);

            if (error) {
                *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Server is at its total in-memory capacity"}];
            }

            return NO;
        }

        decodedData.length = targetBufferLength;
    }
    _totalDecoded += length;
    decodedData.length = length;
    BOOL success = length ? [super writeData:decodedData error:error] : YES;  // No need to call writer if we have no data yet

    // Release the working buffer's charge now that the downstream writer has taken
    // whatever it intends to keep and charged that itself. The reservation must track
    // the buffer we are *holding*, not the running total we have inflated: charging
    // `_totalDecoded` parked the whole process-wide budget for the remaining life of
    // the request on memory that had already been handed on and freed, so one cheap
    // request could lock every other connection out of every in-memory path.
    [_reservation reserveBytes:0];
    return success;
}

- (BOOL)close:(NSError **)error {
    // A body that satisfied its Content-Length but stopped part-way through the gzip
    // stream arrives here with _finished == NO. Reporting success would hand the
    // handler a truncated body that looks complete — on WebDAV PUT that silently
    // replaces the target with the partial content — so refuse instead. Close the
    // downstream writer regardless, or its descriptor and staging file outlive the
    // refused transaction. (This was a GWS_DCHECK, i.e. an abort in Debug builds.)
    inflateEnd(&_stream);

    if (!_finished) {
        GWS_LOG_ERROR(@"Truncated gzip request body");
        [super close:NULL];

        if (error) {
            *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Truncated gzip request body"}];
        }

        return NO;
    }

    return [super close:error];
}

@end

// Parse an unsigned header value strictly: ASCII digits only, at least one, no overflow.
// Used for "Content-Length" and for the two halves of a "Range".
// -integerValue accepts "5abc" as 5, silently clamps an over-large value to NSIntegerMax
// and tolerates a leading sign, so the framing the server uses could differ from what the
// header literally says. NSUIntegerMax itself is refused because it is the "no body"
// sentinel for _contentLength.
static BOOL _ParseUnsignedHeaderValue(NSString *header, NSUInteger *outLength) {
    if (header.length == 0) {
        return NO;
    }

    unsigned long long value = 0;

    for (NSUInteger i = 0; i < header.length; i++) {
        unichar character = [header characterAtIndex:i];

        if ((character < '0') || (character > '9')) {
            return NO;
        }

        unsigned long long digit = (unsigned long long)(character - '0');

        if (value > (ULLONG_MAX - digit) / 10) {
            return NO;
        }

        value = value * 10 + digit;
    }

    if (value >= (unsigned long long)NSUIntegerMax) {
        return NO;
    }

    *outLength = (NSUInteger)value;
    return YES;
}

// Parse a "Transfer-Encoding" list (RFC 7230 §3.3.1). Returns YES when the body uses
// chunked framing; sets *outRejected when the framing cannot be honoured at all.
//
// This used to be an exact string comparison against "chunked", which quietly answered
// "this message has no body" for every legal spelling that isn't the bare token —
// "chunked;a=b", "gzip, chunked", "identity, chunked". The server then replied 200 while
// silently discarding the body, and WebDAV PUT (which unlinks the destination before
// writing) destroyed the target file outright. Anything we cannot frame or decode must be
// refused instead, so the caller never mistakes an unread body for an empty one.
static BOOL _ParseTransferEncoding(NSString *header, BOOL *outRejected) {
    *outRejected = NO;
    NSMutableArray<NSString *> *const codings = [[NSMutableArray alloc] init];

    for (NSString *coding in [header componentsSeparatedByString:@","]) {
        NSString *token = coding;
        NSRange parameters = [token rangeOfString:@";"];  // Transfer-parameters play no part in framing

        if (parameters.location != NSNotFound) {
            token = [token substringToIndex:parameters.location];
        }

        token = [[token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];

        if (token.length) {
            [codings addObject:token];
        }
    }

    if (codings.count == 0) {
        *outRejected = YES;
        return NO;
    }

    // Only "chunked" (as the sole and final coding) and "identity" can be honoured. A
    // content coding such as "gzip" would have to be decoded to recover the payload, and
    // storing the still-encoded bytes as if they were the body is worse than refusing.
    if (codings.count == 1) {
        if ([codings.firstObject isEqualToString:@"chunked"]) {
            return YES;
        }

        if ([codings.firstObject isEqualToString:@"identity"]) {
            return NO;  // Framing comes from Content-Length
        }
    }

    *outRejected = YES;
    return NO;
}

@implementation GCDWebServerRequest {
    BOOL _opened;
    NSMutableArray<GCDWebServerBodyDecoder *> *_decoders;
    id<GCDWebServerBodyWriter> __unsafe_unretained _writer;
    NSMutableDictionary<NSString *, id> *_attributes;
}

- (instancetype)initWithMethod:(NSString *)method url:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers path:(NSString *)path query:(NSDictionary<NSString *, NSString *> *)query {
    if ((self = [super init])) {
        _method = [method copy];
        _URL = url;
        _headers = headers;
        _path = [path copy];
        _query = query;

        _contentType = GCDWebServerNormalizeHeaderValue(_headers[@"Content-Type"]);
        NSString *const transferEncodingHeader = _headers[@"Transfer-Encoding"];

        if (transferEncodingHeader) {
            BOOL rejected = NO;
            _usesChunkedTransferEncoding = _ParseTransferEncoding(transferEncodingHeader, &rejected);

            if (rejected) {
                GWS_LOG_WARNING(@"Unsupported 'Transfer-Encoding' header '%@' for '%@' request on \"%@\"", transferEncodingHeader, _method, _URL);
                return nil;
            }
        }

        NSString *const lengthHeader = _headers[@"Content-Length"];

        if (lengthHeader) {
            NSUInteger length = 0;

            // Both a "Content-Length" and a chunked "Transfer-Encoding" is a framing
            // conflict the client controls entirely, so reject it — but without aborting in
            // debug, since it is remote input rather than an unreachable state.
            if (_usesChunkedTransferEncoding || !_ParseUnsignedHeaderValue(lengthHeader, &length)) {
                GWS_LOG_WARNING(@"Invalid 'Content-Length' header '%@' for '%@' request on \"%@\"", lengthHeader, _method, _URL);
                return nil;
            }

            _contentLength = length;

            if (_contentType == nil) {
                _contentType = kGCDWebServerDefaultMimeType;
            }
        } else if (_usesChunkedTransferEncoding) {
            if (_contentType == nil) {
                _contentType = kGCDWebServerDefaultMimeType;
            }

            _contentLength = NSUIntegerMax;
        } else {
            if (_contentType) {
                GWS_LOG_WARNING(@"Ignoring 'Content-Type' header for '%@' request on \"%@\"", _method, _URL);
                _contentType = nil;  // Content-Type without Content-Length or chunked-encoding doesn't make sense
            }

            _contentLength = NSUIntegerMax;
        }

        NSString *const modifiedHeader = _headers[@"If-Modified-Since"];

        if (modifiedHeader) {
            _ifModifiedSince = [GCDWebServerParseRFC822(modifiedHeader) copy];
        }

        _ifNoneMatch = _headers[@"If-None-Match"];
        _ifRange = _headers[@"If-Range"];

        _byteRange = NSMakeRange(NSUIntegerMax, 0);
        NSString *const rangeHeader = GCDWebServerNormalizeHeaderValue(_headers[@"Range"]);

        if (rangeHeader) {
            if ([rangeHeader hasPrefix:@"bytes="]) {
                NSArray *components = [[rangeHeader substringFromIndex:6] componentsSeparatedByString:@","];

                if (components.count == 1) {
                    components = [(NSString *)[components firstObject] componentsSeparatedByString:@"-"];

                    if (components.count == 2) {
                        // Both halves are parsed strictly, the same way Content-Length is:
                        // -integerValue read "0x10" as 0, " 5"/"+5"/"5abc" as 5 and clamped an
                        // over-large value to NSIntegerMax, so the range the server served
                        // could differ from the one the header literally asked for.
                        NSString *const startString = components[0];
                        NSString *const endString = components[1];
                        NSUInteger startValue = 0;
                        NSUInteger endValue = 0;
                        BOOL hasStart = _ParseUnsignedHeaderValue(startString, &startValue);
                        BOOL hasEnd = _ParseUnsignedHeaderValue(endString, &endValue);

                        if (hasStart && hasEnd && (endValue >= startValue)) {  // The second 500 bytes: "500-999"
                            _byteRange.location = startValue;
                            _byteRange.length = endValue - startValue + 1;  // endValue < NSUIntegerMax, so this cannot overflow
                        } else if (hasStart && (endString.length == 0)) {  // The bytes after 9500 bytes: "9500-"
                            _byteRange.location = startValue;
                            _byteRange.length = NSUIntegerMax;
                        } else if (hasEnd && (startString.length == 0) && (endValue > 0)) {  // The final 500 bytes: "-500"
                            _byteRange.location = NSUIntegerMax;
                            _byteRange.length = endValue;
                        }
                    }
                }
            }

            if ((_byteRange.location == NSUIntegerMax) && (_byteRange.length == 0)) {  // Ignore "Range" header if syntactically invalid
                GWS_LOG_WARNING(@"Failed to parse 'Range' header \"%@\" for url: %@", rangeHeader, url);
            }
        }

        if ([_headers[@"Accept-Encoding"] rangeOfString:@"gzip"].location != NSNotFound) {
            _acceptsGzipContentEncoding = YES;
        }

        _decoders = [[NSMutableArray alloc] init];
        _attributes = [[NSMutableDictionary alloc] init];
    }

    return self;
}

- (BOOL)hasBody {
    return _contentType ? YES : NO;
}

- (BOOL)hasByteRange {
    return GCDWebServerIsValidByteRange(_byteRange);
}

- (id)attributeForKey:(NSString *)key {
    return _attributes[key];
}

- (BOOL)open:(NSError **)error {
    return YES;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    return YES;
}

- (BOOL)close:(NSError **)error {
    return YES;
}

- (void)prepareForWriting {
    _writer = self;

    if ([GCDWebServerNormalizeHeaderValue(self.headers[@"Content-Encoding"]) isEqualToString:@"gzip"]) {
        GCDWebServerGZipDecoder *const decoder = [[GCDWebServerGZipDecoder alloc] initWithRequest:self writer:_writer];
        [_decoders addObject:decoder];
        _writer = decoder;
    }
}

- (BOOL)performOpen:(NSError **)error {
    GWS_DCHECK(_contentType);
    GWS_DCHECK(_writer);

    if (_opened) {
        GWS_DNOT_REACHED();
        return NO;
    }

    _opened = YES;
    return [_writer open:error];
}

- (BOOL)performWriteData:(NSData *)data error:(NSError **)error {
    GWS_DCHECK(_opened);
    return [_writer writeData:data error:error];
}

- (BOOL)performClose:(NSError **)error {
    GWS_DCHECK(_opened);
    return [_writer close:error];
}

- (void)setAttribute:(id)attribute forKey:(NSString *)key {
    [_attributes setValue:attribute forKey:key];
}

- (NSString *)localAddressString {
    return GCDWebServerStringFromSockAddr(_localAddressData.bytes, YES);
}

- (NSString *)remoteAddressString {
    return GCDWebServerStringFromSockAddr(_remoteAddressData.bytes, YES);
}

- (NSString *)description {
    NSMutableString *description = [NSMutableString stringWithFormat:@"%@ %@", _method, _path];

    for (NSString *argument in [[_query allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [description appendFormat:@"\n  %@ = %@", argument, _query[argument]];
    }

    [description appendString:@"\n"];

    for (NSString *header in [[_headers allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [description appendFormat:@"\n%@: %@", header, _headers[header]];
    }

    return description;
}

@end
