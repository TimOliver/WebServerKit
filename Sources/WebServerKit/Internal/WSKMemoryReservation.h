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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 *  Upper bounds on how much request data may be held in memory at once, to keep
 *  a malicious or broken client from exhausting memory on a constrained device.
 *  These cap in-memory buffering only; bodies streamed to disk (uploaded files,
 *  WebDAV PUT) are not limited by these. Like kHeadersMaxLength and
 *  kWSKMaxConnections, they are fixed safety limits, not options.
 *
 *  kWSKMaxInMemoryBodyLength bounds any single in-memory body buffer
 *  (a data request body, a multipart argument part or the parser's working
 *  buffer, a single chunked-transfer chunk). kWSKMaxDecompressedBodyLength
 *  bounds the total output a gzip-encoded request body may inflate to.
 */
#define kWSKMaxInMemoryBodyLength (16 * 1024 * 1024)
#define kWSKMaxDecompressedBodyLength (64 * 1024 * 1024)

/**
 *  Ceiling on request data held in memory across *all* live connections at once.
 *
 *  The two limits above are per-request, and they do not compose: with
 *  kWSKMaxConnections concurrent requests the real ceiling was their product —
 *  around 2 GB of chunked framing buffers, or 8 GB of inflated gzip output — many times
 *  what any phone survives. Each per-request limit still applies; this bounds the sum.
 *
 *  Sized so that legitimate traffic never approaches it: real uploads stream to disk and
 *  hold only a read-sized buffer in memory, so only a client deliberately parking large
 *  in-memory bodies gets close.
 */
#define kWSKMaxTotalInMemoryLength (64 * 1024 * 1024)

/**
 *  A share of the process-wide in-memory ceiling, held by whatever is doing the buffering.
 *
 *  Deliberately an object: the bytes are returned in -dealloc, so a connection that dies
 *  mid-body — dropped, reset, timed out — cannot leak budget and permanently shrink what
 *  the server can serve afterwards. A holder resizes its reservation as its buffer grows.
 */
@interface WSKMemoryReservation : NSObject

/**
 *  Resizes this reservation. Returns NO when the process-wide ceiling would be exceeded,
 *  leaving the existing reservation untouched so the caller can fail the request cleanly.
 *  Shrinking always succeeds.
 */
- (BOOL)reserveBytes:(NSUInteger)bytes;

@end

/**
 *  Current limits. These read the testing overrides below, so consult them rather than the
 *  kWSK... constants directly.
 */
extern NSUInteger WSKMaxInMemoryBodyLength(void);
extern NSUInteger WSKMaxDecompressedBodyLength(void);

/**
 *  Shrinks the limits so a test can prove a bound is enforced without moving tens of
 *  megabytes through the server — which is slow, and under AddressSanitizer is itself
 *  enough to lose the test runner. Pass 0 for either to restore its default.
 */
extern void WSKSetMemoryLimitsForTesting(NSUInteger perRequest, NSUInteger decompressed, NSUInteger total);

/**
 *  Bytes currently reserved across all live reservations. For tests and diagnostics.
 */
extern NSUInteger WSKReservedMemoryLength(void);

NS_ASSUME_NONNULL_END
