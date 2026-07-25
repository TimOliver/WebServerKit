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

#import "GCDWebServerPrivate.h"

@interface GCDWebServerDataRequest ()
@property (nonatomic) NSMutableData *data;
@end

@implementation GCDWebServerDataRequest {
    NSString *_text;
    id _jsonObject;
    GCDWebServerMemoryReservation *_reservation;
}

- (BOOL)open:(NSError **)error {
    _reservation = [[GCDWebServerMemoryReservation alloc] init];

    if (self.contentLength != NSUIntegerMax) {
        // Only a capacity hint — -writeData: enforces the real in-memory cap — so clamp
        // it to that cap rather than trusting the attacker-declared Content-Length,
        // which could otherwise request a huge (or failed) up-front allocation.
        NSUInteger capacity = MIN(self.contentLength, GCDWebServerMaxInMemoryBodyLength());
        _data = [[NSMutableData alloc] initWithCapacity:capacity];
    } else {
        _data = [[NSMutableData alloc] init];
    }

    if (_data == nil) {
        if (error) {
            *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Failed allocating memory"}];
        }

        return NO;
    }

    return YES;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    NSUInteger total = _data.length + data.length;

    if (total > GCDWebServerMaxInMemoryBodyLength()) {
        GWS_LOG_ERROR(@"Request body exceeds the %lu byte in-memory limit", (unsigned long)GCDWebServerMaxInMemoryBodyLength());

        if (error) {
            *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Request body exceeds maximum in-memory size"}];
        }

        return NO;
    }

    // Per-request limits do not compose: this body also has to fit alongside every other
    // connection's, or a flood of individually-legal requests still exhausts the process.
    if (![_reservation reserveBytes:total]) {
        GWS_LOG_ERROR(@"Refusing request body: the server is already holding its %lu byte in-memory limit across all connections", (unsigned long)kGCDWebServerMaxTotalInMemoryLength);

        if (error) {
            *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Server is at its total in-memory capacity"}];
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
    NSMutableString *description = [NSMutableString stringWithString:[super description]];

    if (_data) {
        [description appendString:@"\n\n"];
        [description appendString:GCDWebServerDescribeData(_data, (NSString *)self.contentType)];
    }

    return description;
}

@end

@implementation GCDWebServerDataRequest (Extensions)

- (NSString *)text {
    if (_text == nil) {
        if ([self.contentType hasPrefix:@"text/"]) {
            NSString *const charset = GCDWebServerExtractHeaderValueParameter(self.contentType, @"charset");
            _text = [[NSString alloc] initWithData:self.data encoding:GCDWebServerStringEncodingFromCharset(charset)];
        } else {
            GWS_DNOT_REACHED();
        }
    }

    return _text;
}

- (id)jsonObject {
    if (_jsonObject == nil) {
        NSString *const mimeType = GCDWebServerTruncateHeaderValue(self.contentType);

        if ([mimeType isEqualToString:@"application/json"] || [mimeType isEqualToString:@"text/json"] || [mimeType isEqualToString:@"text/javascript"]) {
            _jsonObject = [NSJSONSerialization JSONObjectWithData:_data options:0 error:NULL];
        } else {
            GWS_DNOT_REACHED();
        }
    }

    return _jsonObject;
}

@end
