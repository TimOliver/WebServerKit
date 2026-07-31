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

#if __has_include(<WebServerKit/WSKResponse.h>)
#import <WebServerKit/WSKResponse.h>
#else
#import "WSKResponse.h"
#endif

NS_ASSUME_NONNULL_BEGIN

/**
 *  The WSKFileResponse subclass of WSKResponse reads the body
 *  of the HTTP response from a file on disk.
 *
 *  It will automatically set the contentType, lastModifiedDate and eTag
 *  properties of the WSKResponse according to the file extension and
 *  metadata.
 */
@interface WSKFileResponse : WSKResponse

/**
 *  ⚠️ BREAKING CHANGE. These three were redeclared here as NON-NULL, and the code cannot keep that
 *  promise, so the redeclarations are gone and WSKResponse's own `nullable` declarations apply.
 *
 *  Two cases make it false, both reachable without any host-app opt-in. `lastModifiedDate` is
 *  deliberately nil while the file's mtime is still inside its filesystem's timestamp bucket — a
 *  validator may only be ISSUED once the instant it names can no longer be written again, which is
 *  what stops two representations going out under one date. And an unsatisfiable byte range answers
 *  416 with none of the three set, so one remote `Range: bytes=999999999-` handed a host app three
 *  nils from properties its own header said could not be nil.
 *
 *  In Objective-C that was a nil into whatever the caller did next — this codebase's named recurring
 *  crash is a nil reaching a dictionary literal, and nothing in Sources/ catches an NSException. In
 *  Swift `lastModifiedDate` imported as a non-optional `Date` and TRAPPED.
 *
 *  Swift callers will now need `if let` or `?`; that is the point. A header that lies to the type
 *  system is worse than one that changes.
 */

/**
 *  Creates a response with the contents of a file.
 */
+ (nullable instancetype)responseWithFile:(NSString *)path;

/**
 *  Creates a response like +responseWithFile: and sets the "Content-Disposition"
 *  HTTP header for a download if the "attachment" argument is YES.
 */
+ (nullable instancetype)responseWithFile:(NSString *)path isAttachment:(BOOL)attachment;

/**
 *  Creates a response like +responseWithFile: but restricts the file contents
 *  to a specific byte range.
 *
 *  See -initWithFile:byteRange: for details.
 */
+ (nullable instancetype)responseWithFile:(NSString *)path byteRange:(NSRange)range;

/**
 *  Creates a response like +responseWithFile:byteRange: and sets the
 *  "Content-Disposition" HTTP header for a download if the "attachment"
 *  argument is YES.
 */
+ (nullable instancetype)responseWithFile:(NSString *)path byteRange:(NSRange)range isAttachment:(BOOL)attachment;

/**
 *  Creates a response like +responseWithFile:byteRange:isAttachment: that also honours
 *  the request's "If-Range" header. Pass the ifRange property of the current
 *  WSKRequest.
 *
 *  See -initWithFile:byteRange:isAttachment:ifRange:mimeTypeOverrides: for details.
 */
+ (nullable instancetype)responseWithFile:(NSString *)path byteRange:(NSRange)range isAttachment:(BOOL)attachment ifRange:(nullable NSString *)ifRange;

/**
 *  Initializes a response with the contents of a file.
 */
- (nullable instancetype)initWithFile:(NSString *)path;

/**
 *  Initializes a response like +responseWithFile: and sets the
 *  "Content-Disposition" HTTP header for a download if the "attachment"
 *  argument is YES.
 */
- (nullable instancetype)initWithFile:(NSString *)path isAttachment:(BOOL)attachment;

/**
 *  Initializes a response like -initWithFile: but restricts the file contents
 *  to a specific byte range. This range should be set to (NSUIntegerMax, 0) for
 *  the full file, (offset, length) if expressed from the beginning of the file,
 *  or (NSUIntegerMax, length) if expressed from the end of the file. The "offset"
 *  and "length" values will be automatically adjusted to be compatible with the
 *  actual size of the file.
 *
 *  This argument would typically be set to the value of the byteRange property
 *  of the current WSKRequest.
 *
 *  If the range is valid but cannot be satisfied by the file (it starts at or past
 *  the end of it), the returned response is a bodyless "416 Requested Range Not
 *  Satisfiable" carrying a "Content-Range" header with the current file size,
 *  rather than nil.
 */
- (nullable instancetype)initWithFile:(NSString *)path byteRange:(NSRange)range;

/**
 *  Initializes a response like -initWithFile:byteRange: without honouring "If-Range",
 *  i.e. equivalent to passing nil for it below.
 *
 *  If MIME type overrides are specified, they allow to customize the built-in
 *  mapping from extensions to MIME types. Keys of the dictionary must be lowercased
 *  file extensions without the period, and the values must be the corresponding
 *  MIME types.
 */
- (nullable instancetype)initWithFile:(NSString *)path byteRange:(NSRange)range isAttachment:(BOOL)attachment mimeTypeOverrides:(nullable NSDictionary<NSString *, NSString *> *)overrides;

/**
 *  This method is the designated initializer for the class.
 *
 *  If MIME type overrides are specified, they allow to customize the built-in
 *  mapping from extensions to MIME types. Keys of the dictionary must be lowercased
 *  file extensions without the period, and the values must be the corresponding
 *  MIME types.
 *
 *  If "ifRange" is non-nil — it would typically be the ifRange property of the current
 *  WSKRequest — the byte range is honoured only while the file still matches
 *  that validator, and the whole file is served otherwise. This is what stops a resumed
 *  download from splicing bytes of a changed file onto the prefix the client already
 *  holds and reporting success.
 */
- (nullable instancetype)initWithFile:(NSString *)path byteRange:(NSRange)range isAttachment:(BOOL)attachment ifRange:(nullable NSString *)ifRange mimeTypeOverrides:(nullable NSDictionary<NSString *, NSString *> *)overrides;

@end

NS_ASSUME_NONNULL_END
