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

#import "WSKValidators.h"

#import <sys/mount.h>
#import <sys/param.h>
#import <sys/stat.h>

#import "WSKPrivate.h"

NSString *WSKEntityTagForFileInfo(const struct stat *info) {
    return [NSString stringWithFormat:@"\"%llu/%lld/%li/%li\"", info->st_ino, (long long)info->st_size, info->st_mtimespec.tv_sec, info->st_mtimespec.tv_nsec];
}

// "*" matches any existing representation. Otherwise the list is compared entry by entry.
// If-Match requires the STRONG comparison (RFC 9110 §13.1.1), where a "W/" tag can never match;
// If-None-Match uses the weak one, where the prefix is stripped from the client's side. Tags
// this server issues are always strong. Hoisted here from the WebDAV write-verb preconditions
// when the connection's read verbs gained the same evaluation, so both sides judge the tag a
// GET hands out by one rule.
BOOL WSKEntityTagMatchesList(BOOL resourceExists, NSString *currentTag, NSString *list, BOOL strong) {
    NSString *const trimmed = [list stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    // "*" asks whether the origin has a current representation AT ALL (RFC 9110 §13.1.1), which is
    // not the same question as "does it have an entity tag". Keying it on the tag made `If-Match: *`
    // always FAIL for a collection, since no tag is minted for a directory — so a conditional
    // DELETE, MOVE or COPY of a folder could never succeed.
    if ([trimmed isEqualToString:@"*"]) {
        return resourceExists;
    }

    if (currentTag == nil) {
        return NO;
    }

    for (NSString *candidate in [trimmed componentsSeparatedByString:@","]) {
        NSString *value = [candidate stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if ([value hasPrefix:@"W/"]) {
            if (strong) {
                continue;
            }

            value = [value substringFromIndex:2];
        }

        if ([value isEqualToString:currentTag]) {
            return YES;
        }
    }

    return NO;
}

// FAT truncates mtime into two-second buckets, so a timestamp one second old there can still take
// another write without moving. Unrecognised types fail CLOSED at two seconds — smbfs and nfs can
// be backed by FAT and cannot be probed from here, and the cost of being wrong that way is one
// extra second of caching rather than a spliced representation. Do not "optimize" this to one.
static time_t _ModificationTimeGranularity(int descriptor) {
    struct statfs info;

    if (fstatfs(descriptor, &info) != 0) {
        return 2;
    }

    if ((strcmp(info.f_fstypename, "apfs") == 0) || (strcmp(info.f_fstypename, "hfs") == 0) ||
        (strcmp(info.f_fstypename, "exfat") == 0)) {
        return 1;
    }

    return 2;
}

BOOL WSKLastModifiedDateIsSealed(int descriptor, const struct stat *info) {
    // A future mtime — clock skew, or an archive restored with tomorrow's timestamp — is unsealed
    // by the same comparison, which is the safe direction and also stops the server advertising a
    // Last-Modified newer than its own Date header.
    return (time(NULL) - info->st_mtimespec.tv_sec) >= _ModificationTimeGranularity(descriptor);
}
