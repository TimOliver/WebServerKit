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

#import "WSKPrivate.h"

@interface WSKDataRequest ()
@property (nonatomic) NSMutableData *data;
@end

@implementation WSKDataRequest {
    NSString *_text;
    id _jsonObject;
    WSKMemoryReservation *_reservation;
}

- (BOOL)open:(NSError **)error {
    _reservation = [[WSKMemoryReservation alloc] init];

    if (self.contentLength != NSUIntegerMax) {
        // Only a capacity hint — -writeData: enforces the real in-memory cap — so clamp
        // it to that cap rather than trusting the attacker-declared Content-Length,
        // which could otherwise request a huge (or failed) up-front allocation.
        NSUInteger const capacity = MIN(self.contentLength, WSKMaxInMemoryBodyLength());
        _data = [[NSMutableData alloc] initWithCapacity:capacity];
    } else {
        _data = [[NSMutableData alloc] init];
    }

    if (_data == nil) {
        if (error) {
            *error = [NSError errorWithDomain:kWSKErrorDomain code:kWSKRequestBodyError_Internal userInfo:@{NSLocalizedDescriptionKey: @"Failed allocating memory"}];
        }

        return NO;
    }

    return YES;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    NSUInteger const total = _data.length + data.length;

    if (total > WSKMaxInMemoryBodyLength()) {
        WSK_LOG_ERROR(@"Request body exceeds the %lu byte in-memory limit", (unsigned long)WSKMaxInMemoryBodyLength());

        if (error) {
            *error = [NSError errorWithDomain:kWSKErrorDomain code:kWSKRequestBodyError_TooLarge userInfo:@{NSLocalizedDescriptionKey: @"Request body exceeds maximum in-memory size"}];
        }

        return NO;
    }

    // Per-request limits do not compose: this body also has to fit alongside every other
    // connection's, or a flood of individually-legal requests still exhausts the process.
    if (![_reservation reserveBytes:total]) {
        WSK_LOG_ERROR(@"Refusing request body: the server is already holding its %lu byte in-memory limit across all connections", (unsigned long)kWSKMaxTotalInMemoryLength);

        if (error) {
            *error = [NSError errorWithDomain:kWSKErrorDomain code:kWSKRequestBodyError_ServerAtCapacity userInfo:@{NSLocalizedDescriptionKey: @"Server is at its total in-memory capacity"}];
        }

        return NO;
    }

    [_data appendData:data];
    return YES;
}

- (BOOL)close:(NSError **)error {
    return YES;
}

- (NSString *)description {
    NSMutableString *const description = [NSMutableString stringWithString:[super description]];

    if (_data) {
        [description appendString:@"\n\n"];
        [description appendString:WSKDescribeData(_data, (NSString *)self.contentType)];
    }

    return description;
}

@end

@implementation WSKDataRequest (Extensions)

- (NSString *)text {
    if (_text == nil) {
        // Returns nil rather than asserting. WSK_DNOT_REACHED() is abort() in Debug, so the one
        // case this property's `nullable` declaration tells a host app to check for was the one
        // case that killed the process — and a Content-Type is client input, which makes it
        // remote-triggerable rather than API misuse. Nothing here is unreachable: a bare POST
        // sends no Content-Type at all.
        if (![self.contentType hasPrefix:@"text/"]) {
            return nil;
        }

        NSString *const charset = WSKExtractHeaderValueParameter(self.contentType, @"charset");
        _text = [[NSString alloc] initWithData:self.data encoding:WSKStringEncodingFromCharset(charset)];
    }

    return _text;
}

- (id)jsonObject {
    if (_jsonObject == nil) {
        NSString *const mimeType = WSKTruncateHeaderValue(self.contentType);

        // Same reasoning as -text above: nil is what the header promises, and the content type
        // that decides this comes off the wire. -JSONObjectWithData: already returns nil for a
        // body that is not valid JSON, which is the other half of the documented contract.
        if (![mimeType isEqualToString:@"application/json"] && ![mimeType isEqualToString:@"text/json"] && ![mimeType isEqualToString:@"text/javascript"]) {
            return nil;
        }

        _jsonObject = [NSJSONSerialization JSONObjectWithData:_data options:0 error:NULL];
    }

    return _jsonObject;
}

@end
