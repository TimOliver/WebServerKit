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

#if __has_include(<WebServerKit/WebServerKit.h>)
#import <WebServerKit/WSKStreamedResponse.h>
#else
#import "WSKStreamedResponse.h"
#endif

NS_ASSUME_NONNULL_BEGIN

/**
 *  A streamed SSE response that tells its owner the moment the stream is over.
 *
 *  WSKConnection calls -performClose on a response as soon as its body write chain ends, including
 *  the write that fails because the client has gone. Nothing listened for that, so a channel
 *  outlived its own connection by a full 30 seconds: the server learned of the departure only when
 *  a heartbeat write failed (15-30s), and only then did the reaper start counting its two idle
 *  ticks. Sixteen abandoned streams therefore denied live updates to a real client for 45-60s — a
 *  browser tab navigating away is enough, no hostility required.
 *
 *  `onClose` fires exactly once, after the superclass has closed.
 */
@interface WSKWebUploaderSSEResponse : WSKStreamedResponse
@property (nonatomic, copy, nullable) dispatch_block_t onClose;
@end

NS_ASSUME_NONNULL_END
