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

#import "WSKWebUploaderSSEChannel.h"

#import <Foundation/Foundation.h>

@implementation WSKWebUploaderSSEChannel {
    NSUInteger _capacity;
    NSMutableArray<NSData *> *_buffer;
    void (^_parkedReader)(NSData *data);
}

- (instancetype)init {
    return [self initWithCapacity:100];
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    if ((self = [super init])) {
        _capacity = capacity > 0 ? capacity : 1;
        _buffer = [[NSMutableArray alloc] init];
    }
    return self;
}

- (NSUInteger)capacity {
    return _capacity;
}

- (BOOL)hasParkedReader {
    return _parkedReader != nil;
}

- (NSUInteger)bufferedCount {
    return _buffer.count;
}

- (void)enqueueData:(NSData *)data {
    if (_closed) {
        return;
    }
    if (_parkedReader) {
        void (^reader)(NSData *) = _parkedReader;
        _parkedReader = nil;
        reader(data);
        return;
    }
    [_buffer addObject:data];
    if (_buffer.count > _capacity) {
        [_buffer removeObjectAtIndex:0];  // Drop oldest to stay bounded.
    }
}

- (void)parkReader:(void (^)(NSData *data))reader {
    if (_closed) {
        reader([NSData data]);  // End-of-stream: complete immediately, never park.
        return;
    }
    _idleHeartbeats = 0;  // The client came back to read: it is alive.
    if (_buffer.count > 0) {
        NSData *data = _buffer.firstObject;
        [_buffer removeObjectAtIndex:0];
        reader(data);
        return;
    }
    _parkedReader = [reader copy];
}

- (void)close {
    if (_closed) {
        return;
    }
    _closed = YES;
    [_buffer removeAllObjects];
    if (_parkedReader) {
        void (^reader)(NSData *) = _parkedReader;
        _parkedReader = nil;
        reader([NSData data]);  // End-of-stream sentinel: lets the connection finish cleanly.
    }
}

@end
