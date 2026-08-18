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

#import <os/lock.h>

#import "WSKMemoryReservation.h"
#import "WSKPrivate.h"

// Guards every field below. Contended only when a buffer grows, never per byte.
static os_unfair_lock _memoryLock = OS_UNFAIR_LOCK_INIT;
static NSUInteger _memoryReserved = 0;
static NSUInteger _memoryCapacity = kWSKMaxTotalInMemoryLength;
static NSUInteger _memoryPerRequestLimit = kWSKMaxInMemoryBodyLength;
static NSUInteger _memoryDecompressedLimit = kWSKMaxDecompressedBodyLength;

NSUInteger WSKMaxInMemoryBodyLength(void) {
    os_unfair_lock_lock(&_memoryLock);
    NSUInteger value = _memoryPerRequestLimit;
    os_unfair_lock_unlock(&_memoryLock);
    return value;
}

NSUInteger WSKMaxDecompressedBodyLength(void) {
    os_unfair_lock_lock(&_memoryLock);
    NSUInteger value = _memoryDecompressedLimit;
    os_unfair_lock_unlock(&_memoryLock);
    return value;
}

void WSKSetMemoryLimitsForTesting(NSUInteger perRequest, NSUInteger decompressed, NSUInteger total) {
    os_unfair_lock_lock(&_memoryLock);
    _memoryPerRequestLimit = perRequest ? perRequest : (NSUInteger)kWSKMaxInMemoryBodyLength;
    _memoryDecompressedLimit = decompressed ? decompressed : (NSUInteger)kWSKMaxDecompressedBodyLength;
    _memoryCapacity = total ? total : (NSUInteger)kWSKMaxTotalInMemoryLength;
    os_unfair_lock_unlock(&_memoryLock);
}

NSUInteger WSKReservedMemoryLength(void) {
    os_unfair_lock_lock(&_memoryLock);
    NSUInteger value = _memoryReserved;
    os_unfair_lock_unlock(&_memoryLock);
    return value;
}

@implementation WSKMemoryReservation {
    NSUInteger _bytes;
}

- (BOOL)reserveBytes:(NSUInteger)bytes {
    BOOL granted = YES;
    os_unfair_lock_lock(&_memoryLock);

    if (bytes > _bytes) {
        NSUInteger increase = bytes - _bytes;

        // Refuse rather than partially grant: the caller fails the request cleanly, which
        // is the whole point — the alternative is every connection buffering a little more
        // until the process is killed.
        if (_memoryReserved + increase > _memoryCapacity) {
            granted = NO;
        } else {
            _memoryReserved += increase;
            _bytes = bytes;
        }
    } else {
        _memoryReserved -= (_bytes - bytes);
        _bytes = bytes;
    }

    os_unfair_lock_unlock(&_memoryLock);
    return granted;
}

- (void)dealloc {
    os_unfair_lock_lock(&_memoryLock);
    _memoryReserved -= _bytes;  // Cannot underflow: _bytes only ever moves through -reserveBytes:
    os_unfair_lock_unlock(&_memoryLock);
}

@end
