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
#import <sys/stat.h>

NS_ASSUME_NONNULL_BEGIN

/**
 *  Returns the strong entity tag this server issues for a file, derived from `stat(2)` fields.
 *
 *  There is exactly one of these because a validator only works if every path agrees on it: the
 *  tag a client is handed by a GET is the tag it presents back in `If-Match`, so a second
 *  implementation that formatted the same fields differently would make every precondition fail
 *  and every revalidation miss.
 *
 *  Size is part of the tag deliberately — inode and mtime alone do not identify the bytes, since
 *  a rewrite in place that restores the timestamp keeps both. See `WSKFileResponse` for the
 *  measurement behind that.
 */
NSString *WSKEntityTagForFileInfo(const struct stat *info);

/**
 *  Evaluates an `If-Match` / `If-None-Match` style entity-tag list against the current tag.
 *
 *  `"*"` matches any existing representation — `resourceExists` answers that question, and it is
 *  deliberately NOT keyed on `currentTag` being non-nil: a tag is only minted for a regular file,
 *  and keying `*` on it made every conditional operation on a collection fail forever. `strong`
 *  selects the RFC 9110 §8.8.3.2 comparison: strong (required for `If-Match`), where a `W/` tag
 *  can never match, or weak (for `If-None-Match`), where the prefix is stripped from the
 *  client's side — tags this server issues are always strong.
 *
 *  One home shared by the WebDAV write-verb preconditions and the connection's read-side
 *  evaluation, so the tag a GET hands out is judged by the same rule everywhere it comes back.
 */
BOOL WSKEntityTagMatchesList(BOOL resourceExists, NSString *_Nullable currentTag, NSString *list, BOOL strong);

/**
 *  Returns YES if the modification time in `info` may be ISSUED as a `Last-Modified` validator for
 *  the file open on `descriptor`.
 *
 *  A date validator is only strong once the instant it names can no longer be written again. While
 *  mtime still falls inside the filesystem's current timestamp bucket the file can be rewritten
 *  without the timestamp moving, so two representations would go out under one date and nothing
 *  downstream could separate them. The rule therefore has to be applied where the validator is
 *  MINTED, never where a resume redeems it — by redemption time the bucket has always closed, so
 *  the test would report "strong" for precisely the representation that is not.
 *
 *  The bucket is not always one second. APFS records nanoseconds, HFS+ and exFAT a second or
 *  better, but **FAT/msdos stores mtime in TWO-second units and truncates downward**, so on a USB
 *  stick or SD card a timestamp one second old can still take another write. `descriptor` is asked
 *  what it is actually sitting on; anything unrecognised — including `smbfs` and `nfs`, which may
 *  be backed by FAT — is assumed coarse, because failing closed here costs a date-only client one
 *  second of caching and failing open splices two builds together.
 *
 *  Both surfaces that hand out a modification date share this, so they cannot drift: withholding
 *  it in one while the other publishes it is how a client obtained an unsealed date from PROPFIND
 *  after the GET path had been fixed to refuse to issue one.
 */
BOOL WSKLastModifiedDateIsSealed(int descriptor, const struct stat *info);

NS_ASSUME_NONNULL_END
