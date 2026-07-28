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

#import <sys/stat.h>

#import "WSKPrivate.h"

#define kFileReadBufferSize (32 * 1024)

@implementation WSKFileResponse {
    NSString *_path;
    NSUInteger _offset;
    NSUInteger _size;
    int _file;
}

@dynamic contentType, lastModifiedDate, eTag;

+ (instancetype)responseWithFile:(NSString *)path {
    return [(WSKFileResponse *)[[self class] alloc] initWithFile:path];
}

+ (instancetype)responseWithFile:(NSString *)path isAttachment:(BOOL)attachment {
    return [(WSKFileResponse *)[[self class] alloc] initWithFile:path isAttachment:attachment];
}

+ (instancetype)responseWithFile:(NSString *)path byteRange:(NSRange)range {
    return [(WSKFileResponse *)[[self class] alloc] initWithFile:path byteRange:range];
}

+ (instancetype)responseWithFile:(NSString *)path byteRange:(NSRange)range isAttachment:(BOOL)attachment {
    return [(WSKFileResponse *)[[self class] alloc] initWithFile:path byteRange:range isAttachment:attachment mimeTypeOverrides:nil];
}

+ (instancetype)responseWithFile:(NSString *)path byteRange:(NSRange)range isAttachment:(BOOL)attachment ifRange:(NSString *)ifRange {
    return [(WSKFileResponse *)[[self class] alloc] initWithFile:path byteRange:range isAttachment:attachment ifRange:ifRange mimeTypeOverrides:nil];
}

- (instancetype)initWithFile:(NSString *)path {
    return [self initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:NO mimeTypeOverrides:nil];
}

- (instancetype)initWithFile:(NSString *)path isAttachment:(BOOL)attachment {
    return [self initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:attachment mimeTypeOverrides:nil];
}

- (instancetype)initWithFile:(NSString *)path byteRange:(NSRange)range {
    return [self initWithFile:path byteRange:range isAttachment:NO mimeTypeOverrides:nil];
}

// Truncated to whole seconds, which is all "Last-Modified" (RFC 822) can express. Keeping
// the nanoseconds made the response date strictly newer than the "If-Modified-Since" value
// the client echoed back from it, so -_CompareResources never validated and nothing on an
// APFS volume (where the nanoseconds are practically never zero) could ever be revalidated
// by date. The nanoseconds are still used for the ETag, which has no such quantization.
static inline NSDate *_NSDateFromTimeSpec(const struct timespec *t) {
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)t->tv_sec];
}

// RFC 8187 ext-value: percent-encode everything outside attr-char. WSKEscapeURLString
// is a *query* escaper and leaves ";" intact — but ";" ends a header parameter, so a file
// named "evil.command;ok.txt" reached the browser as a filename of "evil.command". That
// truncation also defeats whatever extension allow-list accepted the name on upload, since
// the name that lands on the victim's disk is not the name that was checked.
static NSString *_EscapeExtValue(NSString *string) {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~"];
    });
    return [string stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

// The inherited initializer is reachable (+response, or a direct -init) and leaves every
// ivar zeroed — and 0 is a perfectly good descriptor number, which -dealloc would then
// close out from under whoever actually owns it. Every path that produces an instance of
// this class has to establish the -1 sentinel before anything can deallocate it.
- (instancetype)init {
    if ((self = [super init])) {
        _file = -1;
    }

    return self;
}

// A bodyless 416 for a syntactically valid but unsatisfiable range (RFC 7233 §4.4): no
// contentType is set, so -hasBody is NO and the file-reading path is never entered.
// Returning nil here instead — as this used to — makes callers report either 500 (the
// WebDAV GET handler) or 404 (-addGETHandlerForBasePath:) for a file that exists, which
// is what "curl -C -" gets when resuming an already-complete download.
- (void)_configureAsUnsatisfiableRangeForFileSize:(NSUInteger)fileSize {
    self.statusCode = kWSKHTTPStatusCode_RequestedRangeNotSatisfiable;
    [self setValue:[NSString stringWithFormat:@"bytes */%lu", (unsigned long)fileSize] forAdditionalHeader:@"Content-Range"];
}

- (instancetype)initWithFile:(NSString *)path byteRange:(NSRange)range isAttachment:(BOOL)attachment mimeTypeOverrides:(NSDictionary<NSString *, NSString *> *)overrides {
    return [self initWithFile:path byteRange:range isAttachment:attachment ifRange:nil mimeTypeOverrides:overrides];
}

- (instancetype)initWithFile:(NSString *)path byteRange:(NSRange)range isAttachment:(BOOL)attachment ifRange:(NSString *)ifRange mimeTypeOverrides:(NSDictionary<NSString *, NSString *> *)overrides {
    // [super init] and the sentinel come first so that every failure below can simply
    // "return nil": ARC deallocates a nil-returning initializer's receiver, so -dealloc is
    // what closes the descriptor on those paths, and it must never see a zeroed _file.
    if (!(self = [super init])) {
        return nil;
    }

    _file = -1;  // Not 0, which is a legal descriptor -close must not close by accident

    // Open the file *once*, here, and derive contentLength, lastModifiedDate and the ETag
    // from an fstat() of that descriptor. The old lstat()-here plus open()-in--open: pair
    // walked the path twice with the whole runtime of the request handler in between, so a
    // file replaced in that window (PUT racing a GET) was served as the new inode's bytes
    // under the old size, ETag and Last-Modified: a body truncated at the old length that
    // looks complete on the wire and gets cached under a stale validator. One open also
    // makes the regular-file check and the open atomic instead of two separate path walks.
    // O_NONBLOCK because open(2) on a FIFO or a device node blocks until the other end
    // shows up — the lstat-first order used to rule those out before opening them, and a
    // blocked open would wedge the connection's serial queue for good.
    _file = open([path fileSystemRepresentation], O_RDONLY | O_NOFOLLOW | O_NONBLOCK);

    // 0 is a legal descriptor (it is handed out whenever stdin has been closed), so only a
    // negative result means failure. O_NOFOLLOW makes a symlink fail here with ELOOP,
    // which preserves the refusal the lstat() type check used to provide.
    if (_file < 0) {
        WSK_LOG_ERROR(@"Refusing to serve \"%@\": %s (%i)", path, strerror(errno), errno);
        return nil;
    }

    struct stat info;

    // Compare the whole file-type field, not a single bit: S_IFREG (0100000) is a value
    // within the S_IFMT field, not a flag, so "st_mode & S_IFREG" is also non-zero for
    // symlinks (S_IFLNK, 0120000) and sockets (S_IFSOCK, 0140000), which share that bit.
    // Not WSK_DNOT_REACHED(): this is reachable on ordinary remote input (a request naming
    // a directory, a device node, or an item removed since the caller's existence check),
    // and that macro aborts in Debug builds. Callers turn the nil into a 500.
    if (fstat(_file, &info) || ((info.st_mode & S_IFMT) != S_IFREG)) {
        WSK_LOG_ERROR(@"Refusing to serve \"%@\": not a regular file", path);
        return nil;
    }

    // Past the type check nothing can block in open(2) anymore, so restore the blocking
    // read semantics the body reader was written against. Failure is not fatal: O_NONBLOCK
    // has no effect on reads from a regular file, this is only belt and braces.
    const int flags = fcntl(_file, F_GETFL, 0);

    if ((flags < 0) || (fcntl(_file, F_SETFL, flags & ~O_NONBLOCK) < 0)) {
        WSK_LOG_ERROR(@"Failed clearing O_NONBLOCK on \"%@\": %s (%i)", path, strerror(errno), errno);
    }

#ifndef __LP64__

    if (info.st_size >= (off_t)4294967295) {  // In 32 bit mode, we can't handle files greater than 4 GiBs (don't use "NSUIntegerMax" here to avoid potential unsigned to signed conversion issues)
        // As with the file-type check above: an oversized file on disk is an ordinary
        // condition a remote request can name, not a programmer error, so it must not
        // reach WSK_DNOT_REACHED() and abort a Debug build. Callers turn the nil into a 500.
        WSK_LOG_ERROR(@"Refusing to serve \"%@\": too large for a 32 bit build", path);
        return nil;
    }

#endif
    NSUInteger fileSize = (NSUInteger)info.st_size;

    // Derive the validators here, from the same fstat the range decision uses, so If-Range
    // can be answered against the representation we are actually about to serve.
    NSDate *const lastModified = _NSDateFromTimeSpec(&info.st_mtimespec);
    NSString *const entityTag = [NSString stringWithFormat:@"\"%llu/%li/%li\"", info.st_ino, info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec];

    BOOL hasByteRange = WSKIsValidByteRange(range);

    // "Send me this range only if the representation is unchanged" (RFC 9110 §13.1.5).
    // Ignoring it meant a resumed download spliced bytes from two different versions of
    // the file together and returned 206 asserting they belonged to the same one — silent
    // corruption on a server whose whole purpose is that files change. When it does not
    // match we must serve the entire representation instead, which is what dropping the
    // range does. If-Range uses *strong* comparison, so a weak tag never matches.
    if (hasByteRange && ifRange.length) {
        NSString *const trimmedIfRange = [ifRange stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        BOOL matches = NO;

        if ([trimmedIfRange hasPrefix:@"\""]) {
            matches = [trimmedIfRange isEqualToString:entityTag];
        } else if (![trimmedIfRange hasPrefix:@"W/"]) {
            // A date is only usable here if it is a *strong* validator, which If-Range requires
            // (RFC 9110 §13.1.5). st_mtime has one-second resolution, so a file modified within
            // the current second could be modified again inside that same second without the
            // timestamp changing — exactly the case where a build is rewritten under a client
            // that is downloading it, and the server would then splice the tail of one
            // representation onto the prefix of another and assert with a 206 that they belong
            // together. §8.8.2.2 gives the deduction that makes it strong: the origin may treat
            // the timestamp as strong once it is at least one second in the past, because no
            // further change can land in that second any more.
            //
            // Not simply refused, because real clients resume this way: macOS Finder's WebDAV
            // client sends "If-Range: <HTTP-date>" and nothing else (see
            // Tests/WebDAV-Finder/059), so ignoring dates outright turns every Finder resume
            // into a full re-download. What remains unclosed is a replacement that *preserves*
            // mtime (rsync -a, cp -p, tar -x): no date-based scheme can detect that, here or in
            // any other server. A client that has this server's strong ETag — which this
            // initializer always sets — is unaffected either way, since the branch above
            // decides it.
            NSDate *const ifRangeDate = WSKParseRFC822(trimmedIfRange);
            BOOL const timestampIsStrong = (time(NULL) - info.st_mtimespec.tv_sec) >= 1;
            matches = ifRangeDate && timestampIsStrong && ((long)ifRangeDate.timeIntervalSince1970 == (long)info.st_mtimespec.tv_sec);
        }

        if (!matches) {
            WSK_LOG_DEBUG(@"Ignoring byte range for \"%@\": If-Range does not match the current representation", path);
            hasByteRange = NO;
        }
    }

    if (hasByteRange) {
        if (range.location != NSUIntegerMax) {
            range.location = MIN(range.location, fileSize);
            range.length = MIN(range.length, fileSize - range.location);
        } else {
            range.length = MIN(range.length, fileSize);
            range.location = fileSize - range.length;
        }

        if (range.length == 0) {
            // The 416 carries no body, so release the descriptor now instead of holding it
            // for the life of the response.
            close(_file);
            _file = -1;
            [self _configureAsUnsatisfiableRangeForFileSize:fileSize];
            return self;
        }
    } else {
        range.location = 0;
        range.length = fileSize;
    }

    _path = [path copy];
    _offset = range.location;
    _size = range.length;

    if (hasByteRange) {
        [self setStatusCode:kWSKHTTPStatusCode_PartialContent];
        [self setValue:[NSString stringWithFormat:@"bytes %lu-%lu/%lu", (unsigned long)_offset, (unsigned long)(_offset + _size - 1), (unsigned long)fileSize] forAdditionalHeader:@"Content-Range"];
        WSK_LOG_DEBUG(@"Using content bytes range [%lu-%lu] for file \"%@\"", (unsigned long)_offset, (unsigned long)(_offset + _size - 1), path);
    }

    if (attachment) {
        NSString *const fileName = [path lastPathComponent];
        // Strip control characters (notably CR/LF) from the quoted filename before
        // building the header. A bare CR/LF in the value makes CFNetwork drop the
        // entire Content-Disposition header, which would serve the file inline (e.g. an
        // uploaded ".html" as text/html on our own origin) instead of as a download — a
        // stored-XSS vector. The quote is removed too so it cannot close the field
        // early, and the backslash with it: "evil\" would otherwise be emitted as
        // filename="evil\" where \" reads as an escaped quote, leaving the quoted
        // string unterminated and swallowing the parameters that follow. The RFC 5987
        // filename* below is percent-encoded, so it is unaffected.
        NSString *safeName = [[fileName componentsSeparatedByCharactersInSet:[NSCharacterSet controlCharacterSet]] componentsJoinedByString:@""];
        safeName = [safeName stringByReplacingOccurrencesOfString:@"\"" withString:@""];
        safeName = [safeName stringByReplacingOccurrencesOfString:@"\\" withString:@""];
        NSData *const data = [safeName dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES];
        NSString *const lossyFileName = data ? [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] : nil;

        if (lossyFileName) {
            NSString *value = [NSString stringWithFormat:@"attachment; filename=\"%@\"; filename*=UTF-8''%@", lossyFileName, _EscapeExtValue(fileName)];
            [self setValue:value forAdditionalHeader:@"Content-Disposition"];
        } else {
            // The name is remote-controlled, so a transcoding failure here is not a
            // programmer error to assert on. Emit the disposition without the legacy
            // filename parameter rather than no disposition at all: dropping the header
            // entirely would serve the file inline, which is exactly what it exists to
            // prevent.
            WSK_LOG_ERROR(@"Failed encoding attachment file name \"%@\" as ISO-8859-1", fileName);
            NSString *value = [NSString stringWithFormat:@"attachment; filename*=UTF-8''%@", _EscapeExtValue(fileName)];
            [self setValue:value forAdditionalHeader:@"Content-Disposition"];
        }
        // Defense in depth: never let a browser MIME-sniff a download into active content.
        [self setValue:@"nosniff" forAdditionalHeader:@"X-Content-Type-Options"];
    }

    self.contentType = WSKGetMimeTypeForExtension([_path pathExtension], overrides);
    self.contentLength = _size;
    self.lastModifiedDate = lastModified;
    // Quoted, as RFC 7232 requires of an entity-tag: an unquoted value is not a valid
    // opaque-tag and clients are free to reject it. The comparison in
    // -_CompareResources is literal and clients echo the value back verbatim, so the
    // quotes travel with it in "If-None-Match" and still match.
    self.eTag = entityTag;

    return self;
}

- (BOOL)open:(NSError **)error {
    // Deliberately does not open anything: the descriptor comes from the initializer, which
    // fstat'd this exact one to produce Content-Length, Last-Modified and the ETag. Opening
    // the path again here — this runs after the handler has returned, an unbounded gap for
    // an async handler — could pick up a different inode and serve a body the headers no
    // longer describe. A negative _file means the initializer never handed one over (or
    // -close already ran), which lseek would report as EBADF anyway; say so explicitly.
    if (_file < 0) {
        if (error) {
            *error = WSKMakePosixError(EBADF);
        }

        return NO;
    }

    if (lseek(_file, _offset, SEEK_SET) != (off_t)_offset) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }

        return NO;
    }

    return YES;
}

- (NSData *)readData:(NSError **)error {
    size_t length = MIN((NSUInteger)kFileReadBufferSize, _size);
    NSMutableData *data = [[NSMutableData alloc] initWithLength:length];
    ssize_t result;

    // A signal delivered mid-read is not a transfer failure: without the retry the
    // response is silently truncated at whatever had been sent so far.
    do {
        result = read(_file, data.mutableBytes, length);
    } while ((result < 0) && (errno == EINTR));

    if (result < 0) {
        if (error) {
            *error = WSKMakePosixError(errno);
        }

        return nil;
    }

    if (result > 0) {
        [data setLength:result];
        _size -= result;
    } else {
        // result == 0 is a premature EOF (e.g. the file was truncated or replaced
        // mid-download). Return empty data to end the response rather than a buffer
        // of zeros with _size never decremented, which would stream 32 KB zero
        // chunks forever and exceed the declared Content-Length.
        [data setLength:0];
        _size = 0;
    }

    return data;
}

- (void)close {
    // Reset the descriptor so a second -close (a body reader completing twice used to be
    // able to cause one) cannot close an unrelated file that has since been given the
    // same number.
    if (_file >= 0) {
        close(_file);
        _file = -1;
    }
}

- (void)dealloc {
    // The descriptor is acquired in the initializer, but plenty of responses are destroyed
    // without their body ever being read: a HEAD (the connection sets hasBody to NO and so
    // never calls -performOpen:/-performClose), a 304 substituted by -overrideResponse:,
    // a handler that simply drops the response, and every failure path of the initializer
    // itself — ARC deallocates the receiver when an initializer returns nil. None of those
    // reach -close, so without this each one leaks a descriptor per request.
    if (_file >= 0) {
        close(_file);
    }
}

- (NSString *)description {
    NSMutableString *description = [NSMutableString stringWithString:[super description]];

    [description appendFormat:@"\n\n{%@}", _path];
    return description;
}

@end
