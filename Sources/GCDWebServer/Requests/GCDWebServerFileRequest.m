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

@implementation GCDWebServerFileRequest {
    int _file;
}

- (instancetype)initWithMethod:(NSString *)method url:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers path:(NSString *)path query:(NSDictionary<NSString *, NSString *> *)query {
    if ((self = [super initWithMethod:method url:url headers:headers path:path query:query])) {
        _file = -1;  // Not 0, which is a legal descriptor -close: must not close by accident
        _temporaryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    }

    return self;
}

- (void)dealloc {
    unlink([_temporaryPath fileSystemRepresentation]);
}

- (BOOL)open:(NSError **)error {
    _file = open([_temporaryPath fileSystemRepresentation], O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);

    // 0 is a legal descriptor (it is handed out whenever stdin has been closed), so only a
    // negative result means failure. Treating 0 as one both reported a stale errno and
    // leaked the descriptor, and the body would then be written to whatever stdin became.
    if (_file < 0) {
        if (error) {
            *error = GCDWebServerMakePosixError(errno);
        }

        return NO;
    }

    return YES;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;

    // write(2) is allowed to stop short of the whole buffer — interrupted by a signal
    // (EINTR) or simply writing fewer bytes than asked — and neither case means the upload
    // failed. The single unchecked call this replaces aborted the request on both, so a
    // signal arriving mid-body lost an otherwise healthy upload.
    while (remaining > 0) {
        const ssize_t result = write(_file, bytes, remaining);

        if (result < 0) {
            if (errno == EINTR) {
                continue;
            }

            if (error) {
                *error = GCDWebServerMakePosixError(errno);
            }

            return NO;
        }

        if (result == 0) {
            // Cannot happen for a regular file with a non-zero count, but a write that
            // reports no progress and no error would otherwise spin here forever.
            if (error) {
                *error = GCDWebServerMakePosixError(EIO);
            }

            return NO;
        }

        bytes += result;
        remaining -= (size_t)result;
    }

    return YES;
}

- (BOOL)close:(NSError **)error {
    // Take the descriptor out of the ivar first: a second -close: must not hand the same
    // number back to close(2) after the kernel has recycled it onto an unrelated file. A
    // negative value means -open: never ran (or already failed), which is reported as
    // EBADF rather than closing descriptor 0.
    const int file = _file;
    _file = -1;

    if ((file < 0) || (close(file) < 0)) {
        if (error) {
            *error = GCDWebServerMakePosixError((file < 0) ? EBADF : errno);
        }

        return NO;
    }

#ifdef __GCDWEBSERVER_ENABLE_TESTING__
    NSString *const creationDateHeader = self.headers[@"X-GCDWebServer-CreationDate"];

    if (creationDateHeader) {
        NSDate *const date = GCDWebServerParseISO8601(creationDateHeader);

        if (!date || ![[NSFileManager defaultManager] setAttributes:@{NSFileCreationDate: date} ofItemAtPath:_temporaryPath error:error]) {
            return NO;
        }
    }

    NSString *const modifiedDateHeader = self.headers[@"X-GCDWebServer-ModifiedDate"];

    if (modifiedDateHeader) {
        NSDate *const date = GCDWebServerParseRFC822(modifiedDateHeader);

        if (!date || ![[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: date} ofItemAtPath:_temporaryPath error:error]) {
            return NO;
        }
    }

#endif /* ifdef __GCDWEBSERVER_ENABLE_TESTING__ */
    return YES;
}

- (NSString *)description {
    NSMutableString *description = [NSMutableString stringWithString:[super description]];

    [description appendFormat:@"\n\n{%@}", _temporaryPath];
    return description;
}

@end
