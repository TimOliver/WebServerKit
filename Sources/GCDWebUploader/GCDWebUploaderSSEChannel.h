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
 *  Per-connection buffer for a single Server-Sent Events client.
 *
 *  GCDWebServer's async streaming API is a strict ping-pong: it hands the
 *  response one completion block ("reader"), waits for that block to be invoked
 *  once with a chunk of body data, writes the chunk, and only then asks for the
 *  next one. Between those calls the connection has no reader waiting, so an
 *  event broadcast in that window would be lost if it were delivered directly to
 *  "whatever reader happens to be parked right now".
 *
 *  This class decouples producing events from the reader lifecycle. Events are
 *  buffered in FIFO order (up to a bounded capacity) until a reader is parked,
 *  guaranteeing no event is dropped while a reader is momentarily absent between
 *  ping-pong cycles.
 *
 *  Instances are NOT thread-safe: callers must serialize access. The uploader
 *  drives every channel from a single serial dispatch queue.
 */
@interface GCDWebUploaderSSEChannel : NSObject

/**
 *  Maximum number of messages buffered while no reader is parked. Once the
 *  buffer is full the oldest message is dropped to make room, bounding memory
 *  use for connections that have gone away but not yet been reaped.
 */
@property (nonatomic, readonly) NSUInteger capacity;

/**
 *  YES if a reader is currently parked waiting for the next message.
 */
@property (nonatomic, readonly) BOOL hasParkedReader;

/**
 *  Number of messages currently buffered waiting for a reader.
 */
@property (nonatomic, readonly) NSUInteger bufferedCount;

/**
 *  Consecutive heartbeats observed by the owner during which no reader parked.
 *  Used to reap connections that have stopped reading without misjudging a live
 *  client that is momentarily mid-write. Reset to 0 whenever a reader parks.
 */
@property (nonatomic) NSUInteger idleHeartbeats;

- (instancetype)init;  // Uses a sensible default capacity.
- (instancetype)initWithCapacity:(NSUInteger)capacity NS_DESIGNATED_INITIALIZER;

/**
 *  Queue a message for delivery. If a reader is currently parked, the message is
 *  delivered to it immediately and the reader is consumed; otherwise the message
 *  is appended to the buffer (dropping the oldest message if at capacity).
 */
- (void)enqueueData:(NSData *)data;

/**
 *  Offer a reader for the next message. If a buffered message is available it is
 *  delivered synchronously through the reader and the reader is consumed;
 *  otherwise the reader is parked until the next enqueue.
 */
- (void)parkReader:(void (^)(NSData* data))reader;

@end

NS_ASSUME_NONNULL_END
