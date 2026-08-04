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
#error WSKWebDAVServer requires ARC
#endif

// WebDAV specifications: http://webdav.org/specs/rfc4918.html

// Requires "HEADER_SEARCH_PATHS = $(SDKROOT)/usr/include/libxml2" in Xcode build settings
#import "WSKPrivate.h"
#import "WSKWebDAVServer.h"

#import <sys/xattr.h>

#import <libxml/parser.h>

#import "WSKDataRequest.h"
#import "WSKDataResponse.h"
#import "WSKErrorResponse.h"
#import "WSKFileRequest.h"
#import "WSKFileResponse.h"
#import "WSKFunctions.h"

#define kXMLParseOptions (XML_PARSE_NONET | XML_PARSE_RECOVER | XML_PARSE_NOBLANKS | XML_PARSE_COMPACT | XML_PARSE_NOWARNING | XML_PARSE_NOERROR)

// A DAV request body is a property list or a lock description: real clients send a few
// hundred bytes. libxml2 builds a DOM many times the size of an element-dense source,
// and that DOM is not covered by the request-side memory budget — which bounds the bytes
// we receive, not what a handler subsequently builds out of them. A 16 MB PROPFIND body
// of empty elements took the process from 5 MB to 561 MB and still answered 207.
#define kDAVMaxRequestBodyLength (256 * 1024)

// What a PROPFIND body asked for. The old model was a bitmask of the four live properties and an
// unrecognised name was logged and dropped — which is why a requested-but-unavailable property got
// no acknowledgement at all, and why <propname/> could not be answered. RFC 4918 §9.1 requires both:
// a property that cannot be returned is reported in its own propstat with 404, and propname returns
// the NAMES with empty values. Remembering the request is what makes either expressible.
typedef NS_ENUM(NSInteger, DAVPropFindKind) {
    kDAVPropFind_AllProp = 0,
    kDAVPropFind_PropName,
    kDAVPropFind_Named
};

typedef NS_ENUM(NSInteger, DAVProperties) {
    kDAVProperty_ResourceType = (1 << 0),
    kDAVProperty_CreationDate = (1 << 1),
    kDAVProperty_LastModified = (1 << 2),
    kDAVProperty_ContentLength = (1 << 3),
    kDAVAllProperties = kDAVProperty_ResourceType | kDAVProperty_CreationDate | kDAVProperty_LastModified | kDAVProperty_ContentLength
};

NS_ASSUME_NONNULL_BEGIN

@interface WSKWebDAVServer (Methods)
- (nullable WSKResponse *)performOPTIONS:(WSKRequest *)request;
- (nullable WSKResponse *)performGET:(WSKRequest *)request;
- (nullable WSKResponse *)performPUT:(WSKFileRequest *)request;
- (nullable WSKResponse *)performDELETE:(WSKRequest *)request;
- (nullable WSKResponse *)performMKCOL:(WSKDataRequest *)request;
- (nullable WSKResponse *)performCOPY:(WSKRequest *)request isMove:(BOOL)isMove;
- (nullable WSKResponse *)performPROPFIND:(WSKDataRequest *)request;
- (nullable WSKResponse *)performPROPPATCH:(WSKDataRequest *)request;
- (nullable WSKResponse *)performLOCK:(WSKDataRequest *)request;
- (nullable WSKResponse *)performUNLOCK:(WSKRequest *)request;
@end

NS_ASSUME_NONNULL_END

@implementation WSKWebDAVServer

@dynamic delegate;

- (instancetype)initWithUploadDirectory:(NSString *)path {
    if ((self = [super init])) {
        // Standardize once. Every request resolves the served root with realpath(3) to
        // check containment, and that fails outright for a host-app path carrying a tilde
        // or a trailing separator — which fails closed, i.e. every request gets a 403.
        _uploadDirectory = [[path stringByStandardizingPath] copy];
        WSKWebDAVServer *const __unsafe_unretained server = self;

        // 9.1 PROPFIND method
        [self addDefaultHandlerForMethod:@"PROPFIND"
                            requestClass:[WSKDataRequest class]
                            processBlock:^WSKResponse *(WSKRequest *request) {
                                return [server performPROPFIND:(WSKDataRequest *)request];
                            }];

        // 9.2 PROPPATCH method
        [self addDefaultHandlerForMethod:@"PROPPATCH"
                            requestClass:[WSKDataRequest class]
                            processBlock:^WSKResponse *(WSKRequest *request) {
                                return [server performPROPPATCH:(WSKDataRequest *)request];
                            }];

        // 9.3 MKCOL Method
        [self addDefaultHandlerForMethod:@"MKCOL"
                            requestClass:[WSKDataRequest class]
                            processBlock:^WSKResponse *(WSKRequest *request) {
                                return [server performMKCOL:(WSKDataRequest *)request];
                            }];

        // 9.4 GET & HEAD methods
        [self addDefaultHandlerForMethod:@"GET"
                            requestClass:[WSKRequest class]
                            processBlock:^WSKResponse *(WSKRequest *request) {
                                return [server performGET:request];
                            }];

        // 9.6 DELETE method
        [self addDefaultHandlerForMethod:@"DELETE"
                            requestClass:[WSKRequest class]
                            processBlock:^WSKResponse *(WSKRequest *request) {
                                return [server performDELETE:request];
                            }];

        // 9.7 PUT method
        [self addDefaultHandlerForMethod:@"PUT"
                            requestClass:[WSKFileRequest class]
                            processBlock:^WSKResponse *(WSKRequest *request) {
                                return [server performPUT:(WSKFileRequest *)request];
                            }];

        // 9.8 COPY method
        [self addDefaultHandlerForMethod:@"COPY"
                            requestClass:[WSKRequest class]
                            processBlock:^WSKResponse *(WSKRequest *request) {
                                return [server performCOPY:request isMove:NO];
                            }];

        // 9.9 MOVE method
        [self addDefaultHandlerForMethod:@"MOVE"
                            requestClass:[WSKRequest class]
                            processBlock:^WSKResponse *(WSKRequest *request) {
                                return [server performCOPY:request isMove:YES];
                            }];

        // 9.10 LOCK method
        [self addDefaultHandlerForMethod:@"LOCK"
                            requestClass:[WSKDataRequest class]
                            processBlock:^WSKResponse *(WSKRequest *request) {
                                return [server performLOCK:(WSKDataRequest *)request];
                            }];

        // 9.11 UNLOCK method
        [self addDefaultHandlerForMethod:@"UNLOCK"
                            requestClass:[WSKRequest class]
                            processBlock:^WSKResponse *(WSKRequest *request) {
                                return [server performUNLOCK:request];
                            }];

        // 10.1 OPTIONS method / DAV Header
        [self addDefaultHandlerForMethod:@"OPTIONS"
                            requestClass:[WSKRequest class]
                            processBlock:^WSKResponse *(WSKRequest *request) {
                                return [server performOPTIONS:request];
                            }];
    }

    return self;
}

@end

@implementation WSKWebDAVServer (Methods)

// RFC 4918 §1.4 adopts the ABNF of RFC 2616 §2.1, in which a quoted literal is case-insensitive.
// "T", "F" and "infinity" are all such literals, so "f" and "Infinity" are conformant spellings
// and must mean what the client meant. Comparing them with -isEqualToString: made the exact byte
// "F" the ONLY spelling that meant "do not overwrite", and every other one — "f", "False", "no",
// an empty value — permission to destroy the destination, answered 204. That direction fails
// OPEN, which is why it mattered; the Depth pair has the identical shape and fails closed.
static inline BOOL _HeaderTokenIs(NSString *value, NSString *token) {
    return (value != nil) && ([value caseInsensitiveCompare:token] == NSOrderedSame);
}

// "*" matches any existing representation. Otherwise the list is compared entry by entry.
// If-Match requires the STRONG comparison (RFC 9110 §13.1.1), where a "W/" tag can never match;
// If-None-Match uses the weak one, where the prefix is stripped from both sides. Tags this
// server issues are always strong, so only the client's side can carry the prefix.
static BOOL _EntityTagMatchesList(BOOL resourceExists, NSString *currentTag, NSString *list, BOOL strong) {
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

// RFC 9110 §13.1.1 requires an origin server NOT to perform the method when If-Match evaluates
// false. Nothing here did: preconditions were evaluated only in -overrideResponse:forRequest:,
// which runs AFTER the handler has already written, and compares against a response ETag that a
// 201/204 does not carry — so no 412 could ever be produced. If-Match was not parsed anywhere in
// the tree at all. The lost-update protection a WebDAV client believes it has did not exist, so
// two clients editing one file each silently overwrote the other.
//
// Called from every verb that replaces or destroys the resource it addresses — PUT, DELETE, MOVE
// and COPY — rather than only from PUT where it was found. Evaluated against the resource as it
// is on disk, before any destructive step, and against the same tag WSKFileResponse issues.
- (nullable WSKResponse *)_preconditionFailureForRequest:(WSKRequest *)request atPath:(NSString *)absolutePath {
    NSString *const ifMatch = request.headers[@"If-Match"];
    NSString *const ifNoneMatch = request.headers[@"If-None-Match"];
    // The date form of the same guarantee, and it was not read anywhere in the tree: a client that
    // said "If-Unmodified-Since: <a date the file is newer than>" had its resource destroyed and was
    // told the method succeeded. Same lost-update failure the entity-tag form was fixed for, left
    // open in the spelling a date-only client uses.
    NSString *const ifUnmodifiedSince = request.headers[@"If-Unmodified-Since"];

    if ((ifMatch == nil) && (ifNoneMatch == nil) && (ifUnmodifiedSince == nil)) {
        return nil;
    }

    struct stat info;
    // `stated` covers collections too, which the entity-tag path never reached because a tag is
    // only minted for a regular file. A date condition is meaningful for a collection — DELETE of
    // one is a destructive method like any other — so this deliberately admits a new refusal there.
    BOOL const stated = (stat([absolutePath fileSystemRepresentation], &info) == 0);
    BOOL const exists = stated && ((info.st_mode & S_IFMT) == S_IFREG);
    NSString *const currentTag = exists ? WSKEntityTagForFileInfo(&info) : nil;

    // Evaluation order is RFC 9110 §13.2.2: If-Match, then If-Unmodified-Since only in its
    // absence, then If-None-Match. If-Modified-Since plays no part in a state-changing method.
    if (ifMatch != nil) {
        if (!_EntityTagMatchesList(stated, currentTag, ifMatch, YES)) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_PreconditionFailed message:@"\"If-Match\" precondition failed for \"%@\"", request.path];
        }
    } else if (ifUnmodifiedSince != nil) {
        NSDate *const limit = WSKParseRFC822(ifUnmodifiedSince);

        // A date this server cannot parse is ignored rather than treated as failed, per RFC 9110
        // §13.1.4. NOTE the cap that leaves: WSKParseRFC822 reads only the RFC 1123 form, so the
        // RFC 850 and asctime spellings §5.6.7 also requires a server to accept parse to nil and
        // the method PROCEEDS. That is shared with If-Modified-Since and If-Range rather than
        // introduced here, so this closes the common spelling and not the whole class.
        // Truncated to whole seconds through a named local rather than casting the call directly:
        // -Weverything's -Wbad-function-cast flags a cast applied to a function result, and this
        // project builds Debug with it.
        double const limitSeconds = floor(limit.timeIntervalSince1970);

        if (stated && (limit != nil) && ((time_t)limitSeconds < info.st_mtimespec.tv_sec)) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_PreconditionFailed message:@"\"If-Unmodified-Since\" precondition failed for \"%@\"", request.path];
        }
    } else if (_EntityTagMatchesList(stated, currentTag, ifNoneMatch, NO)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_PreconditionFailed message:@"\"If-None-Match\" precondition failed for \"%@\"", request.path];
    }

    return nil;
}

- (BOOL)_checkFileExtension:(NSString *)fileName {
    return WSKNamePassesExtensionAllowList(fileName, _allowedFileExtensions);
}

// Both names an entry presents must satisfy the allow-list; see WSKEntryPassesExtensionAllowList.
// `resolvedName` is nil for anything that is not a link, which reduces to the single-name rule.
- (BOOL)_checkFileExtensionForName:(NSString *)namedName resolvedName:(nullable NSString *)resolvedName {
    return WSKEntryPassesExtensionAllowList(namedName, resolvedName, _allowedFileExtensions);
}

// Whatever an operation is about to destroy has to be something the client could have destroyed
// by naming it directly, or one request means two different things. Returns the first item that
// fails the allow-list — the item itself for a file, or the offending subpath for a collection —
// and nil when the whole thing may go.
//
// Both destructive shapes go through here, because each has been a hole in turn. DELETE of a
// collection removes its whole subtree, and a folder was a spelling that bypassed the allow-list
// entirely (measured: with an allow-list of "txt", DELETE /Folder answered 204 and destroyed both
// "id_rsa" and ".env"). MOVE and COPY destroy exactly as much through Overwrite, and their two
// extension checks are both gated behind !srcIsDirectory, so a collection source skipped them
// altogether — and a collection *destination* named "Backup.txt" satisfies the file-source form.
// Measured before this, 5/5: all four spellings answered 204 and destroyed the target.
//
// This mirrors -[WSKWebUploader deleteItem:], deliberately including its two judgement calls.
// Dot-names and everything under them are skipped whatever -allowHiddenItems says: they are
// incidental metadata rather than content the allow-list protects, and a ".DS_Store" sits in
// every macOS folder with an empty pathExtension that is in no allow-list, so vetting them would
// make ordinary folders permanently undeletable. And an extensionless file ("README") is vetted
// like any other, because addressing it directly is already refused.
- (nullable NSString *)_firstUnvettableItemAtPath:(NSString *)absolutePath isDirectory:(BOOL)isDirectory {
    return WSKFirstUnvettableItemAtPath(absolutePath, isDirectory, _allowedFileExtensions);
}

// Hidden-item protection has to cover every component of the path, not only the leaf:
// refusing "/.git" while serving "/.git/config" protects nothing. Normalizing first means
// a benign "." or ".." is resolved away rather than read as a name starting with a period.
// See the identical helper in WSKWebUploader: resolve once, judge both rules on that single
// observation, and act on the returned path rather than the one the client sent. A symlink
// retargeted between two independent resolutions served content from outside the share and
// landed a PUT outside it.
// The same resolution, but yielding the entry the client NAMED rather than what it points at —
// see WSKResolveNamedEntryWithinDirectory(). Used by the verbs that REMOVE or RELOCATE an entry
// (DELETE, and MOVE/COPY on both their source and their destination), because `rm latest` removes
// the alias and `mv a latest` replaces it; only reads follow a link. The NUL guard, the
// containment check, the hidden-item rule and the refusal to act on the root all still apply, and
// all still come from a single resolution.
- (nullable NSString *)_namedEntryPathForRelativePath:(NSString *)relativePath hidden:(BOOL *)outHidden {
    return WSKNamedEntryPathForRelativePath(relativePath, _uploadDirectory, _allowHiddenItems, outHidden);
}

- (nullable NSString *)_resolvedPathForRelativePath:(NSString *)relativePath hidden:(BOOL *)outHidden {
    return WSKResolvedPathForRelativePath(relativePath, _uploadDirectory, _allowHiddenItems, outHidden);
}

// A unique, hidden sibling of `path`. Building a replacement here — rather than removing
// what is already at `path` and writing over it — keeps the destination intact until the
// new content is complete on disk, and keeps the final swap a rename(2) within a single
// directory, which is atomic and cannot fail for being cross-volume.
// Dead properties — the arbitrary name/value pairs PROPPATCH stores — live in a single extended
// attribute holding a property list keyed in Clark notation ("{namespace}localname"). One blob
// rather than one xattr per property so the key never has to be escaped into an xattr name, and so
// a set of properties is written in one call and cannot half-apply.
//
// Deliberately NOT added to WSKFunctions: this is WebDAV's business, and that header is public, so
// putting it there would widen the API for a build-graph reason. See the structural-cleanup note.
static NSString *const kDAVDeadPropertyAttribute = @"com.webserverkit.dav.deadproperties";

static NSDictionary<NSString *, NSString *> *_DeadPropertiesAtPath(NSString *path) {
    const char *const filePath = [path fileSystemRepresentation];
    ssize_t const size = getxattr(filePath, [kDAVDeadPropertyAttribute UTF8String], NULL, 0, 0, 0);

    if (size <= 0) {
        return @{};  // None stored, or the filesystem does not keep them.
    }

    NSMutableData *const data = [NSMutableData dataWithLength:(NSUInteger)size];

    if (getxattr(filePath, [kDAVDeadPropertyAttribute UTF8String], data.mutableBytes, (size_t)size, 0, 0) != size) {
        return @{};
    }

    NSObject *const stored = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];

    // Whatever was in the attribute is not necessarily what we put there — another tool can write
    // this xattr — so the shape is checked rather than assumed.
    return [stored isKindOfClass:[NSDictionary class]] ? (NSDictionary<NSString *, NSString *> *)stored : @{};
}

// NO on failure, with errno left as the filesystem set it. Filesystems that cannot store extended
// attributes at all — exFAT among them, which this project has now measured rather than assumed —
// report ENOTSUP, and the caller turns that into a per-property 403 rather than pretending the
// property was stored.
static BOOL _SetDeadPropertiesAtPath(NSString *path, NSDictionary<NSString *, NSString *> *properties) {
    const char *const filePath = [path fileSystemRepresentation];

    if (properties.count == 0) {
        return (removexattr(filePath, [kDAVDeadPropertyAttribute UTF8String], 0) == 0) || (errno == ENOATTR);
    }

    NSData *const data = [NSPropertyListSerialization dataWithPropertyList:properties format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];

    if (data == nil) {
        errno = EINVAL;
        return NO;
    }

    return setxattr(filePath, [kDAVDeadPropertyAttribute UTF8String], data.bytes, data.length, 0, 0) == 0;
}

// "{namespace}localname", the unambiguous spelling of a qualified name, and the element markup to
// echo it back with. A property in no namespace is keyed by its bare name.
static NSString *_DeadPropertyKey(NSString *namespaceHref, NSString *localName) {
    return namespaceHref.length ? [NSString stringWithFormat:@"{%@}%@", namespaceHref, localName] : localName;
}

static NSString *_DeadPropertyElement(NSString *key) {
    NSRange const close = [key rangeOfString:@"}"];

    if (![key hasPrefix:@"{"] || (close.location == NSNotFound)) {
        return [NSString stringWithFormat:@"<%@/>", _XMLEscape(key)];
    }

    NSString *const href = [key substringWithRange:NSMakeRange(1, close.location - 1)];
    NSString *const name = [key substringFromIndex:(close.location + 1)];

    if ([href isEqualToString:@"DAV:"]) {
        return [NSString stringWithFormat:@"<D:%@/>", _XMLEscape(name)];
    }

    return [NSString stringWithFormat:@"<W:%@ xmlns:W=\"%@\"/>", _XMLEscape(name), _XMLEscape(href)];
}

static WSKErrorResponse *_ResponseIfRequestBodyTooLarge(WSKDataRequest *request) {
    if (request.data.length <= kDAVMaxRequestBodyLength) {
        return nil;
    }

    return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_RequestEntityTooLarge message:@"Request body is too large (%lu bytes)", (unsigned long)request.data.length];
}

// Is `path` inside `directory`, compared the way the volume would? Case-insensitive on
// purpose: over-refusing a COPY costs nothing, whereas under-refusing one lets
// copyItemAtPath: recurse into the tree it is still walking.
static BOOL _PathIsInsideDirectoryOnDisk(NSString *path, NSString *directory) {
    if ((path.length == 0) || (directory.length == 0)) {
        return NO;
    }

    NSString *const prefix = [directory hasSuffix:@"/"] ? directory : [directory stringByAppendingString:@"/"];
    return [path rangeOfString:prefix options:(NSCaseInsensitiveSearch | NSAnchoredSearch)].location != NSNotFound;
}

static NSString *_StagingPathForPath(NSString *path) {
    NSString *const name = [@"." stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]];
    return [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:name];
}

// Swap the staged item into `path`, replacing whatever is already there. rename(2) does
// that atomically, which -moveItemAtPath: cannot (it refuses an existing destination); it
// will not replace a *non-empty directory*, so that one case still needs an explicit
// removal first — safe here, because by then the replacement is already complete on disk.
// `expected` is the identity the caller vetted, or NULL when the caller established that nothing
// was there. The fallback removal below is recursive and used to run against whatever occupied the
// path at that instant rather than against the item any check had looked at — so a PUT that
// -performPUT: had already cleared (405 if the destination is a collection) destroyed a collection
// that arrived in the ~30 lines between, and answered 204 No Content. Comparing dev+ino makes the
// removal refuse anything the caller did not authorise.
- (BOOL)_replaceItemAtPath:(NSString *)path withStagedItemAtPath:(NSString *)stagingPath expecting:(nullable const struct stat *)expected error:(NSError **)error {
    // With nothing vetted at the destination the swap must not replace anything: an item that
    // appeared during the window belongs to whoever created it. RENAME_EXCL fails rather than
    // clobbering, which is what lets the caller refuse and leave the newcomer alone.
    if (expected == NULL) {
        if (renamex_np([stagingPath fileSystemRepresentation], [path fileSystemRepresentation], RENAME_EXCL) == 0) {
            return YES;
        }

        int const exclusiveError = errno;

        // Not every filesystem implements an exclusive rename. macOS 15's FSKit exFAT returns
        // ENOTSUP, and with no fallback that made WebDAV MOVE and COPY to any NEW name answer 403
        // on an exFAT-backed share — 10/10, files and collections alike, i.e. rename and duplicate
        // simply did not work. APFS, FAT32 and HFS+ all implement it, which is why nothing caught
        // it until the share was put on a USB stick.
        //
        // Reserve the name ourselves instead, which gets the same exclusivity from O_EXCL/mkdir:
        // both fail with EEXIST if anything occupies the name, so an item that appeared in the
        // window still survives and the request still refuses. ONLY on ENOTSUP/ENOSYS — every
        // other errno, EEXIST above all, must keep failing, or the racing newcomer this branch
        // exists to protect gets clobbered.
        if ((exclusiveError == ENOTSUP) || (exclusiveError == ENOSYS)) {
            struct stat stagedInfo;
            BOOL const stagedIsDirectory = (lstat([stagingPath fileSystemRepresentation], &stagedInfo) == 0) &&
                                           ((stagedInfo.st_mode & S_IFMT) == S_IFDIR);
            BOOL reserved;

            if (stagedIsDirectory) {
                reserved = (mkdir([path fileSystemRepresentation], 0755) == 0);
            } else {
                int const descriptor = open([path fileSystemRepresentation], O_WRONLY | O_CREAT | O_EXCL, 0644);
                reserved = (descriptor >= 0);

                if (reserved) {
                    close(descriptor);
                }
            }

            if (reserved) {
                if (rename([stagingPath fileSystemRepresentation], [path fileSystemRepresentation]) == 0) {
                    return YES;
                }

                // Reclaim the reservation. Without this a failed rename leaves a zero-byte file or
                // an empty directory at a name the request then refuses — a brand-new residue class
                // on the failure path, which is exactly what this library says a transaction must
                // never do. The original errno is what the client is told about.
                int const renameError = errno;

                if (stagedIsDirectory) {
                    rmdir([path fileSystemRepresentation]);
                } else {
                    unlink([path fileSystemRepresentation]);
                }

                if (error) {
                    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:renameError userInfo:nil];
                }

                return NO;
            }
        }

        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:exclusiveError userInfo:nil];
        }

        return NO;
    }

    if (rename([stagingPath fileSystemRepresentation], [path fileSystemRepresentation]) == 0) {
        return YES;
    }

    // rename(2) refuses here only when the destination is a non-empty directory, which means the
    // path is no longer the item that was vetted — a plain file cannot become one in place. Verify
    // before destroying anything.
    struct stat current;

    if ((lstat([path fileSystemRepresentation], &current) != 0) ||
        (current.st_dev != expected->st_dev) || (current.st_ino != expected->st_ino)) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTEMPTY userInfo:@{NSLocalizedDescriptionKey: @"The destination changed while the replacement was being built"}];
        }

        return NO;
    }

    if (![[NSFileManager defaultManager] removeItemAtPath:path error:error]) {
        return NO;
    }

    if (rename([stagingPath fileSystemRepresentation], [path fileSystemRepresentation]) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }

        return NO;
    }

    return YES;
}

// A control character below 0x20 other than tab, LF and CR cannot appear in an XML 1.0
// document *at all* — there is no escape for it, and a numeric reference to one is equally
// illegal. A Unix filename may legally contain one, so escaping the five metacharacters was
// not enough: a file named "a\x01b.txt" made us emit a document we declare as
// application/xml that no conforming parser will accept ("not well-formed (invalid token)"),
// which broke that resource for every client. Drop them, since there is nothing else a
// well-formed document can do with them.
static NSString *_XMLEscape(NSString *string) {
    NSMutableString *const escaped = [string mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];  // Must run first.
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"'" withString:@"&apos;" options:0 range:NSMakeRange(0, escaped.length)];

    NSMutableString *const sanitized = [NSMutableString stringWithCapacity:escaped.length];

    [escaped enumerateSubstringsInRange:NSMakeRange(0, escaped.length)
                                options:NSStringEnumerationByComposedCharacterSequences
                             usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
                                 unichar const character = [substring characterAtIndex:0];

                                 if ((character >= 0x20) || (character == '\t') || (character == '\n') || (character == '\r')) {
                                     [sanitized appendString:substring];
                                 }
                             }];

    return sanitized;
}

static inline BOOL _IsMacFinder(WSKRequest *request) {
    NSString *const userAgentHeader = request.headers[@"User-Agent"];

    return ([userAgentHeader hasPrefix:@"WebDAVFS/"] || [userAgentHeader hasPrefix:@"WebDAVLib/"]);  // OS X WebDAV client
}

// Every method this server implements. RFC 9110 §15.5.6 requires an Allow header on a 405, and
// §10.2.1 recommends one on OPTIONS; a client discovering capabilities from OPTIONS otherwise has
// to guess. Kept beside performOPTIONS: so adding a verb without advertising it is visible here.
// PROPPATCH was implemented by the class-1 work and never added here, so capability discovery
// disagreed with routing: a client reading OPTIONS concluded the method was unavailable and never
// tried it, while the server would have answered it perfectly well.
static NSString *const kDAVAllowedMethods = @"OPTIONS, HEAD, GET, PUT, DELETE, MKCOL, PROPFIND, PROPPATCH, COPY, MOVE, LOCK, UNLOCK";

// RFC 9110 §15.5.6 makes Allow mandatory on a 405. Every site answering one goes through here so
// a refusal added later cannot forget it — the omission this replaces was in two of the four.
static WSKResponse *_MethodNotAllowed(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static WSKResponse *_MethodNotAllowed(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *const message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    WSKResponse *const response = [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_MethodNotAllowed message:@"%@", message];
    [response setValue:kDAVAllowedMethods forAdditionalHeader:@"Allow"];
    return response;
}

- (WSKResponse *)performOPTIONS:(WSKRequest *)request {
    WSKResponse *response = [WSKResponse response];
    [response setValue:kDAVAllowedMethods forAdditionalHeader:@"Allow"];

    if (_IsMacFinder(request)) {
        [response setValue:@"1, 2" forAdditionalHeader:@"DAV"];  // Classes 1 and 2
    } else {
        [response setValue:@"1" forAdditionalHeader:@"DAV"];  // Class 1
    }

    return response;
}

- (WSKResponse *)performGET:(WSKRequest *)request {
    NSString *const relativePath = request.path;
    NSString *absolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];
    BOOL isDirectory = NO;

    // Containment comes before the item is stat'ed: answering 404-vs-403 from a path that
    // has not been checked yet is an existence oracle for the whole filesystem. Verify the
    // resolved location, not just the path text — a symlink inside the share can point out
    // of it, and the textual normalize/prefix checks cannot see that.
    BOOL isHidden = NO;
    NSString *const resolvedPath = [self _resolvedPathForRelativePath:relativePath hidden:&isHidden];

    if (resolvedPath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Downloading \"%@\" is not allowed", relativePath];
    }

    absolutePath = resolvedPath;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    // absolutePath is the RESOLVED location by now, so its leaf is the target's name. The name the
    // client actually used has to be judged too, or a link is vetted by a different name here than
    // in the listing that advertised it — measured as advertise-then-403 in one direction and
    // hidden-then-200 in the other.
    NSString *const itemName = [relativePath lastPathComponent];
    NSString *const resolvedName = [absolutePath lastPathComponent];

    if (isHidden || (!isDirectory && ![self _checkFileExtensionForName:itemName resolvedName:resolvedName])) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Downloading \"%@\" is not allowed", relativePath];
    }

    // Because HEAD requests are mapped to GET ones, we need to handle directories but it's OK to return nothing per http://webdav.org/specs/rfc4918.html#rfc.section.9.4
    if (isDirectory) {
        return [WSKResponse response];
    }

    if ([self.delegate respondsToSelector:@selector(davServer:didDownloadFileAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Re-read and re-check inside the block. The property is weak AND mutable, so the
            // object checked above need not be the one messaged here — a host app that swaps
            // its delegate for another LIVE object implementing a different subset of these
            // optional methods raises unrecognized-selector, and nothing in Sources/ catches an
            // NSException. (Setting it to nil, or letting it deallocate, was always safe: the
            // weak read yields nil and the message is a no-op.) The strong local also removes a
            // second weak load between this check and the send. Deliberately NOT a strong
            // capture at check time: that would keep a delegate the host app has released alive
            // and deliver into an object mid-teardown.
            id<WSKWebDAVServerDelegate> const delegate = self.delegate;

            if ([delegate respondsToSelector:@selector(davServer:didDownloadFileAtPath:)]) {
                [delegate davServer:self didDownloadFileAtPath:absolutePath];
            }
        });
    }

    // Serve as an attachment so a browser pointed at a PUT'd file (e.g. an ".html" or
    // ".svg") downloads it instead of rendering it inline as active content on our own
    // origin. WebDAV clients read the body regardless of the disposition, so this does
    // not affect normal file access.
    if ([request hasByteRange]) {
        return [WSKFileResponse responseWithFile:absolutePath byteRange:request.byteRange isAttachment:YES ifRange:request.ifRange];
    }

    return [WSKFileResponse responseWithFile:absolutePath isAttachment:YES];
}

- (WSKResponse *)performPUT:(WSKFileRequest *)request {
    if ([request hasByteRange]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Range uploads not supported"];
    }

    // The uploaded body only exists on disk once the connection has recognized the
    // request's framing and opened the request — -temporaryPath names a file that is never
    // created when -hasBody is NO. Reject that here, before any filesystem work: a PUT
    // whose framing we cannot read has nothing to store, and the alternative is to
    // discover it only after the destination has already been replaced.
    if (![request hasBody]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_LengthRequired message:@"Missing or unsupported body framing for PUT"];
    }

    NSString *const relativePath = request.path;
    NSString *absolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];
    BOOL isDirectory;

    if (!WSKPathIsInsideDirectory(absolutePath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Operating on the root directory is not allowed"];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:[absolutePath stringByDeletingLastPathComponent] isDirectory:&isDirectory] || !isDirectory) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Conflict message:@"Missing intermediate collection(s) for \"%@\"", relativePath];
    }

    // Checked after the parent-exists test above so a genuinely missing collection still
    // reports 409 rather than 403. The destination itself need not exist: the resolver
    // falls back to resolving the parent, so intermediate symlinks are still caught.
    BOOL isHidden = NO;
    NSString *const resolvedPath = [self _resolvedPathForRelativePath:relativePath hidden:&isHidden];

    if (resolvedPath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Uploading to \"%@\" is not allowed", relativePath];
    }

    absolutePath = resolvedPath;

    BOOL existing = [[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory];

    if (existing && isDirectory) {
        return _MethodNotAllowed(@"PUT not allowed on existing collection \"%@\"", relativePath);
    }

    NSString *const fileName = [absolutePath lastPathComponent];

    if (isHidden || ![self _checkFileExtension:fileName]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Uploading to \"%@\" is not allowed", relativePath];
    }

    WSKResponse *const preconditionFailure = [self _preconditionFailureForRequest:request atPath:absolutePath];

    if (preconditionFailure) {
        return preconditionFailure;
    }

    if (![self shouldUploadFileAtPath:absolutePath withTemporaryFile:request.temporaryPath]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Uploading file to \"%@\" is not permitted", relativePath];
    }

    // Never remove the destination before its replacement is in hand. The body was
    // streamed into NSTemporaryDirectory(), possibly on another volume, so land it beside
    // the destination first and only then swap it in; an overwrite that fails at any point
    // therefore leaves the existing file exactly as it was.
    NSFileManager *const fileManager = [NSFileManager defaultManager];
    NSString *const stagingPath = existing ? _StagingPathForPath(absolutePath) : nil;
    NSString *const writePath = stagingPath ? stagingPath : absolutePath;
    NSError *error = nil;

    // The identity the 405 check above cleared, so the swap can refuse to destroy anything else.
    // Without it a collection created in the window between that check and the swap was removed
    // recursively by the fallback inside -_replaceItemAtPath:, and the client was told 204.
    struct stat vetted;
    BOOL const haveVetted = existing && (lstat([absolutePath fileSystemRepresentation], &vetted) == 0);

    if (![fileManager moveItemAtPath:request.temporaryPath toPath:writePath error:&error]) {
        return [WSKErrorResponse responseWithServerError:WSKServerErrorStatusCodeForError(error) underlyingError:error message:@"Failed moving uploaded file to \"%@\"", relativePath];
    }

    if (stagingPath && ![self _replaceItemAtPath:absolutePath withStagedItemAtPath:stagingPath expecting:(haveVetted ? &vetted : NULL) error:&error]) {
        [fileManager removeItemAtPath:stagingPath error:NULL];
        return [WSKErrorResponse responseWithServerError:WSKServerErrorStatusCodeForError(error) underlyingError:error message:@"Failed moving uploaded file to \"%@\"", relativePath];
    }

    if ([self.delegate respondsToSelector:@selector(davServer:didUploadFileAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Re-read and re-check inside the block. The property is weak AND mutable, so the
            // object checked above need not be the one messaged here — a host app that swaps
            // its delegate for another LIVE object implementing a different subset of these
            // optional methods raises unrecognized-selector, and nothing in Sources/ catches an
            // NSException. (Setting it to nil, or letting it deallocate, was always safe: the
            // weak read yields nil and the message is a no-op.) The strong local also removes a
            // second weak load between this check and the send. Deliberately NOT a strong
            // capture at check time: that would keep a delegate the host app has released alive
            // and deliver into an object mid-teardown.
            id<WSKWebDAVServerDelegate> const delegate = self.delegate;

            if ([delegate respondsToSelector:@selector(davServer:didUploadFileAtPath:)]) {
                [delegate davServer:self didUploadFileAtPath:absolutePath];
            }
        });
    }

    return [WSKResponse responseWithStatusCode:(existing ? kWSKHTTPStatusCode_NoContent : kWSKHTTPStatusCode_Created)];
}

- (WSKResponse *)performDELETE:(WSKRequest *)request {
    NSString *const depthHeader = request.headers[@"Depth"];

    // "Depth: 0" is accepted as well as "infinity". For a resource with no internal members it cannot
    // mean anything else, and refusing it meant a client that sets Depth uniformly could not delete
    // or copy a single FILE at all — 400 for an operation that is trivially satisfiable. RFC 4918
    // §9.6.1 fixes DELETE's depth at infinity regardless, so accepting "0" costs nothing.
    if (depthHeader && !_HeaderTokenIs(depthHeader, @"infinity") && !_HeaderTokenIs(depthHeader, @"0")) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Unsupported 'Depth' header: %@", depthHeader];
    }

    NSString *const relativePath = request.path;
    NSString *absolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];
    BOOL isDirectory = NO;

    // Refuse to operate on the upload directory itself: "DELETE /" collapses to it
    // and would remove the entire share.
    if (!WSKPathIsInsideDirectory(absolutePath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Operating on the root directory is not allowed"];
    }

    // Deleting is destructive, so also confirm the resolved target is inside the share
    // rather than whatever a symlink points to outside it.
    BOOL isHidden = NO;
    NSString *const resolvedPath = [self _namedEntryPathForRelativePath:relativePath hidden:&isHidden];

    if (resolvedPath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not allowed", relativePath];
    }

    absolutePath = resolvedPath;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    if (isHidden) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not allowed", relativePath];
    }

    NSString *const undeletable = [self _firstUnvettableItemAtPath:absolutePath isDirectory:isDirectory];

    if (undeletable) {
        if (isDirectory) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not allowed: it contains \"%@\"", relativePath, undeletable];
        }

        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not allowed", relativePath];
    }

    // A removal that only partly succeeds is the worst outcome this library recognises, and
    // -removeItemAtPath: produces one by design: it deletes as it walks and stops at the first
    // member it cannot unlink, keeping everything it already destroyed and reporting a bare
    // failure. Refuse before touching anything instead.
    NSString *const unremovable = WSKFirstUnremovableItemAtPath(absolutePath);

    if (unremovable) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not allowed: \"%@\" cannot be removed", relativePath, unremovable];
    }

    WSKResponse *const preconditionFailure = [self _preconditionFailureForRequest:request atPath:absolutePath];

    if (preconditionFailure) {
        return preconditionFailure;
    }

    if (![self shouldDeleteItemAtPath:absolutePath]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not permitted", relativePath];
    }

    NSError *error = nil;

    if (![[NSFileManager defaultManager] removeItemAtPath:absolutePath error:&error]) {
        return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed deleting \"%@\"", relativePath];
    }

    if ([self.delegate respondsToSelector:@selector(davServer:didDeleteItemAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Re-read and re-check inside the block. The property is weak AND mutable, so the
            // object checked above need not be the one messaged here — a host app that swaps
            // its delegate for another LIVE object implementing a different subset of these
            // optional methods raises unrecognized-selector, and nothing in Sources/ catches an
            // NSException. (Setting it to nil, or letting it deallocate, was always safe: the
            // weak read yields nil and the message is a no-op.) The strong local also removes a
            // second weak load between this check and the send. Deliberately NOT a strong
            // capture at check time: that would keep a delegate the host app has released alive
            // and deliver into an object mid-teardown.
            id<WSKWebDAVServerDelegate> const delegate = self.delegate;

            if ([delegate respondsToSelector:@selector(davServer:didDeleteItemAtPath:)]) {
                [delegate davServer:self didDeleteItemAtPath:absolutePath];
            }
        });
    }

    return [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_NoContent];
}

- (WSKResponse *)performMKCOL:(WSKDataRequest *)request {
    if ([request hasBody] && (request.contentLength > 0)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_UnsupportedMediaType message:@"Unexpected request body for MKCOL method"];
    }

    NSString *const relativePath = request.path;
    NSString *absolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];
    BOOL isDirectory;

    if (!WSKPathIsInsideDirectory(absolutePath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Operating on the root directory is not allowed"];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:[absolutePath stringByDeletingLastPathComponent] isDirectory:&isDirectory] || !isDirectory) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Conflict message:@"Missing intermediate collection(s) for \"%@\"", relativePath];
    }

    // After the parent-exists test, so a missing collection still reports 409 not 403.
    BOOL isHidden = NO;
    NSString *const resolvedPath = [self _resolvedPathForRelativePath:relativePath hidden:&isHidden];

    if (resolvedPath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Creating \"%@\" is not allowed", relativePath];
    }

    absolutePath = resolvedPath;

    if (isHidden) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Creating \"%@\" is not allowed", relativePath];
    }

    if (![self shouldCreateDirectoryAtPath:absolutePath]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Creating directory \"%@\" is not permitted", relativePath];
    }

    // RFC 4918 §9.3.1: a URL that already identifies a resource MUST answer 405, not a 5xx.
    // createDirectoryAtPath:withIntermediateDirectories:NO reports EEXIST as
    // NSFileWriteFileExistsError, which WSKServerErrorStatusCodeForError does not recognise, so it
    // fell through to 500 — and "MKCOL each ancestor, treat 405 as already-exists" is how every
    // client creates a tree, so a 5xx reads as "the server broke" and the whole copy aborts.
    // Keyed on the RESOLVED path so it asks about the same entry creation will attempt, and placed
    // after the permission checks so an existing item the caller may not touch still reports the
    // refusal rather than its existence. Tested against an existing FILE as well as a collection:
    // §9.3.1 says "resource", not "collection", and both took the 500 branch.
    if ([[NSFileManager defaultManager] fileExistsAtPath:absolutePath]) {
        return _MethodNotAllowed(@"Collection \"%@\" already exists", relativePath);
    }

    NSError *error = nil;

    if (![[NSFileManager defaultManager] createDirectoryAtPath:absolutePath withIntermediateDirectories:NO attributes:nil error:&error]) {
        // The preflight above cannot close the window between asking and creating, so an entry
        // that appears in it must still answer 405 rather than the 500 the mapping would give.
        for (NSError *candidate = error; candidate != nil; candidate = candidate.userInfo[NSUnderlyingErrorKey]) {
            BOOL const cocoaExists = [candidate.domain isEqualToString:NSCocoaErrorDomain] && (candidate.code == NSFileWriteFileExistsError);
            BOOL const posixExists = [candidate.domain isEqualToString:NSPOSIXErrorDomain] && (candidate.code == EEXIST);

            if (cocoaExists || posixExists) {
                return _MethodNotAllowed(@"Collection \"%@\" already exists", relativePath);
            }
        }

        return [WSKErrorResponse responseWithServerError:WSKServerErrorStatusCodeForError(error) underlyingError:error message:@"Failed creating directory \"%@\"", relativePath];
    }

#ifdef __WEBSERVERKIT_ENABLE_TESTING__
    NSString *const creationDateHeader = request.headers[@"X-WebServerKit-CreationDate"];

    if (creationDateHeader) {
        NSDate *const date = WSKParseISO8601(creationDateHeader);

        if (!date || ![[NSFileManager defaultManager] setAttributes:@{NSFileCreationDate: date} ofItemAtPath:absolutePath error:&error]) {
            // This step runs AFTER the collection exists, so returning here used to answer 500
            // having already created it: the client is told the method failed, and a retry then
            // gets 405 because the collection is there. "A refused transaction leaves nothing
            // behind" applies to the failure paths too.
            [[NSFileManager defaultManager] removeItemAtPath:absolutePath error:NULL];
            return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed setting creation date for directory \"%@\"", relativePath];
        }
    }

#endif

    if ([self.delegate respondsToSelector:@selector(davServer:didCreateDirectoryAtPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Re-read and re-check inside the block. The property is weak AND mutable, so the
            // object checked above need not be the one messaged here — a host app that swaps
            // its delegate for another LIVE object implementing a different subset of these
            // optional methods raises unrecognized-selector, and nothing in Sources/ catches an
            // NSException. (Setting it to nil, or letting it deallocate, was always safe: the
            // weak read yields nil and the message is a no-op.) The strong local also removes a
            // second weak load between this check and the send. Deliberately NOT a strong
            // capture at check time: that would keep a delegate the host app has released alive
            // and deliver into an object mid-teardown.
            id<WSKWebDAVServerDelegate> const delegate = self.delegate;

            if ([delegate respondsToSelector:@selector(davServer:didCreateDirectoryAtPath:)]) {
                [delegate davServer:self didCreateDirectoryAtPath:absolutePath];
            }
        });
    }

    return [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_Created];
}

// Whether two paths refer to the same underlying file — either identical strings, or
// (on a case-insensitive volume) different spellings that resolve to a single inode.
- (BOOL)_fileAtPath:(NSString *)path1 isSameAsPath:(NSString *)path2 {
    return WSKPathsNameTheSameFile(path1, path2);
}

- (WSKResponse *)performCOPY:(WSKRequest *)request isMove:(BOOL)isMove {
    // RFC 4918 §9.8.3: "Depth: 0" copies the collection itself WITHOUT its members, and an absent
    // header means infinity. The value was validated and then discarded — the implementation
    // always did a recursive copy — so a client asking for a shallow copy was answered 201 and
    // silently handed the whole subtree. Silently doing an approximation of what was asked is the
    // outcome this project refuses everywhere else, and for Shape A a collection of builds is not
    // a cheap thing to duplicate by accident.
    BOOL shallowCopy = NO;

    // Validated for BOTH verbs. This check used to live inside the `if (!isMove)` below, so MOVE
    // read the header not at all: every spelling — including "banana" and "0," — answered 201 and
    // performed a full recursive relocation, while COPY, DELETE and PROPFIND all answered 400 for
    // the same values. One rule present at three of the four verbs it applies to is this
    // codebase's signature defect shape.
    //
    // Deliberately NOT stricter: RFC 4918 §9.9.2 says a client MUST NOT send any Depth but
    // infinity on a MOVE of a COLLECTION, so "0" there could be refused too. COPY and DELETE
    // both accept "0" on a plain file because it means the same as infinity with no internal
    // members, and an asymmetry only MOVE enforces would refuse requests real clients send.
    NSString *const depthHeader = request.headers[@"Depth"];

    if (depthHeader && !_HeaderTokenIs(depthHeader, @"infinity") && !_HeaderTokenIs(depthHeader, @"0")) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Unsupported 'Depth' header: %@", depthHeader];
    }

    if (!isMove) {
        shallowCopy = _HeaderTokenIs(depthHeader, @"0");
    }

    NSString *const srcRelativePath = request.path;
    NSString * srcAbsolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(srcRelativePath)];

    NSString *const destinationHeader = request.headers[@"Destination"];
    NSString *const hostHeader = request.headers[@"Host"];

    // Host is required because HTTP/1.1 requires it, and nothing else here enforces that;
    // its *value* is deliberately never consulted below. The destination used to be parsed
    // by searching for the Host value anywhere inside it and taking whatever followed as
    // the path, so a Host of "x" turned "/victim.txt" into "/t" and silently relocated the
    // file — any short, common, or ".local" host that happened to appear in a name did it.
    if ((destinationHeader.length == 0) || (hostHeader.length == 0)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Malformed 'Destination' header: %@", destinationHeader];
    }

    // The same fragment truncation the request-line validator refuses, at the one place it can
    // still arrive: HTTP stacks sanitize a URL they put in the request line but never a header
    // value, so curl strips '#' from the target and passes it through here untouched. Measured with
    // the request-target guard alone in place: `COPY /tiny.txt` with `Destination: http://h/Builds#x`
    // still answered 204 and still replaced a three-build collection with a 4-byte file. Guarding
    // only the target and calling the class closed would be exactly the "fixed at one of the sites
    // it occurs at" pattern this file keeps recording.
    if ([destinationHeader rangeOfString:@"#"].location != NSNotFound) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Malformed 'Destination' header: a fragment is not part of a request target: %@", destinationHeader];
    }

    // RFC 4918 lets Destination be an absolute URI or an absolute path. Take the path
    // component of the URI form, and the value itself otherwise — then percent-decode
    // exactly once, since CFURLCopyPath leaves the escapes in place (the same split
    // WSKConnection uses to derive request.path).
    NSString *dstRelativePath = nil;

    if ([destinationHeader hasPrefix:@"/"]) {
        dstRelativePath = WSKUnescapeURLString(destinationHeader);
    } else {
        NSURL *const destinationURL = [NSURL URLWithString:destinationHeader];
        NSString *const escapedPath = destinationURL.scheme.length ? CFBridgingRelease(CFURLCopyPath((__bridge CFURLRef)destinationURL)) : nil;  // Not -[NSURL path], which strips a trailing slash
        dstRelativePath = escapedPath ? WSKUnescapeURLString(escapedPath) : nil;
    }

    if (dstRelativePath.length == 0) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Malformed 'Destination' header: %@", destinationHeader];
    }

    NSString * dstAbsolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(dstRelativePath)];

    // Neither source nor destination may be the upload directory itself: a Destination
    // that collapses to the root (e.g. "/" or "/..") would otherwise let a MOVE with
    // Overwrite:T remove the whole share before failing.
    if (!WSKPathIsInsideDirectory(srcAbsolutePath, _uploadDirectory) || !WSKPathIsInsideDirectory(dstAbsolutePath, _uploadDirectory)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Operating on the root directory is not allowed"];
    }

    BOOL isDirectory;

    if (![[NSFileManager defaultManager] fileExistsAtPath:[dstAbsolutePath stringByDeletingLastPathComponent] isDirectory:&isDirectory] || !isDirectory) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Conflict message:@"Invalid destination \"%@\"", dstRelativePath];
    }

    // The extension allow-list applies to files, not directories, so derive that from
    // the SOURCE item. The previous code reused the destination-parent's isDirectory
    // (always a directory), so `!isDirectory` was always false and the extension check
    // never ran on COPY/MOVE — letting an allowed file be renamed to any extension.
    BOOL srcIsDirectory = NO;

    if (![[NSFileManager defaultManager] fileExistsAtPath:srcAbsolutePath isDirectory:&srcIsDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", srcRelativePath];
    }

    // Both endpoints must resolve inside the share. Checked after the destination's
    // parent and the source's existence are established above, so those errors keep
    // their own status codes; the destination itself need not exist, since the resolver
    // falls back to its parent.
    BOOL srcIsHidden = NO;
    BOOL dstIsHidden = NO;
    NSString *const resolvedSrcPath = [self _namedEntryPathForRelativePath:srcRelativePath hidden:&srcIsHidden];
    NSString *const resolvedDstPath = [self _namedEntryPathForRelativePath:dstRelativePath hidden:&dstIsHidden];

    if ((resolvedSrcPath == nil) || (resolvedDstPath == nil)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"%@ \"%@\" to \"%@\" is not allowed", isMove ? @"Moving" : @"Copying", srcRelativePath, dstRelativePath];
    }

    srcAbsolutePath = resolvedSrcPath;
    dstAbsolutePath = resolvedDstPath;

    NSString *const srcName = [srcAbsolutePath lastPathComponent];

    if (srcIsHidden || (!srcIsDirectory && ![self _checkFileExtension:srcName])) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"%@ from \"%@\" is not allowed", isMove ? @"Moving" : @"Copying", srcRelativePath];
    }

    NSString *const dstName = [dstAbsolutePath lastPathComponent];

    if (dstIsHidden || (!srcIsDirectory && ![self _checkFileExtension:dstName])) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"%@ to \"%@\" is not allowed", isMove ? @"Moving" : @"Copying", dstRelativePath];
    }

    // The precondition names the resource the Request-URI addresses, i.e. the SOURCE.
    WSKResponse *const preconditionFailure = [self _preconditionFailureForRequest:request atPath:srcAbsolutePath];

    if (preconditionFailure) {
        return preconditionFailure;
    }

    NSString *const overwriteHeader = request.headers[@"Overwrite"];
    BOOL dstIsDirectory = NO;
    BOOL existing = [[NSFileManager defaultManager] fileExistsAtPath:dstAbsolutePath isDirectory:&dstIsDirectory];

    if (existing && ((isMove && !_HeaderTokenIs(overwriteHeader, @"T")) || (!isMove && _HeaderTokenIs(overwriteHeader, @"F")))) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_PreconditionFailed message:@"Destination \"%@\" already exists", dstRelativePath];
    }

    // The SOURCE has to clear the same bar as a DELETE of it would, and for the same reason: a
    // client told it may not touch "Coll/sub/secret.pem" must not be able to relocate or duplicate
    // that file by naming its PARENT. Both extension checks above are gated behind
    // !srcIsDirectory, so a collection source skipped every allow-list rule — measured, MOVE and
    // COPY of such a collection to a new destination both answered 201 and carried the file with
    // them, while the direct spelling, a recursive DELETE, and an overwrite were all 403.
    //
    // This is the fourth and fifth site of the class this codebase keeps re-finding: a recursive
    // operation doing what a direct request refuses. Note it is deliberately vetted for COPY too,
    // which destroys nothing — duplicating a file the client may not read is still acting on it.
    //
    // The COST, accepted and pinned by the test: a collection holding anything outside the
    // allow-list becomes unmovable, not merely undeletable. That is exactly the cost already
    // accepted for DELETE, and the inconsistency was the defect.
    if (srcIsDirectory) {
        NSString *const unvettable = [self _firstUnvettableItemAtPath:srcAbsolutePath isDirectory:YES];

        if (unvettable) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"%@ \"%@\" is not allowed: it contains \"%@\"", isMove ? @"Moving" : @"Copying", srcRelativePath, unvettable];
        }
    }

    // An overwrite destroys the destination just as a DELETE would, so it has to clear the same
    // bar. The two extension checks above cannot stand in for this: both are skipped when the
    // source is a collection, and the destination form only ever judges a *name*, which says
    // nothing about what a collection named "Backup.txt" contains. Checked here, before any
    // filesystem work, so a refusal leaves the destination exactly as it was.
    if (existing) {
        NSString *const undeletable = [self _firstUnvettableItemAtPath:dstAbsolutePath isDirectory:dstIsDirectory];

        if (undeletable) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"%@ to \"%@\" is not allowed: it would destroy \"%@\"", isMove ? @"Moving" : @"Copying", dstRelativePath, undeletable];
        }

        // The overwrite removes the destination, so it inherits the partial-removal problem too:
        // measured at 7 files in the destination down to 1, answered 403, with the source also left
        // in place — a failed operation AND a gutted destination.
        NSString *const unremovable = WSKFirstUnremovableItemAtPath(dstAbsolutePath);

        if (unremovable) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"%@ to \"%@\" is not allowed: \"%@\" cannot be removed", isMove ? @"Moving" : @"Copying", dstRelativePath, unremovable];
        }
    }

    if (isMove) {
        if (![self shouldMoveItemFromPath:srcAbsolutePath toPath:dstAbsolutePath]) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Moving \"%@\" to \"%@\" is not permitted", srcRelativePath, dstRelativePath];
        }
    } else {
        if (![self shouldCopyItemFromPath:srcAbsolutePath toPath:dstAbsolutePath]) {
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Copying \"%@\" to \"%@\" is not permitted", srcRelativePath, dstRelativePath];
        }
    }

    NSError *error = nil;
    NSFileManager *const fileManager = [NSFileManager defaultManager];

    // Reject a MOVE/COPY whose destination resolves to the source file itself — an exact
    // self-move, or a case-only rename on a case-insensitive volume (different path
    // strings, one underlying inode). Replacing the "destination" below would otherwise
    // destroy the source, i.e. the only copy of the file. RFC 4918 forbids this.
    if ([self _fileAtPath:srcAbsolutePath isSameAsPath:dstAbsolutePath]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"%@ \"%@\" onto itself is not allowed", isMove ? @"Moving" : @"Copying", srcRelativePath];
    }

    // Refuse a copy or move into the source's own subtree, which RFC 4918 §9.8.5 requires
    // to be a 403. Without it -[NSFileManager copyItemAtPath:] creates the destination
    // inside the tree it is still walking and re-enters it, nesting directories until a
    // path exceeds PATH_MAX. The copy then fails — and its own cleanup fails for the same
    // reason — so a request that answers 403 still leaves ~250 nested directories in the
    // share that the server can no longer delete through its own API. Checked before the
    // staging path is derived, since a staging sibling of the destination is inside the
    // source too.
    if (_PathIsInsideDirectoryOnDisk(dstAbsolutePath, srcAbsolutePath)) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"%@ \"%@\" into its own subtree \"%@\" is not allowed", isMove ? @"Moving" : @"Copying", srcRelativePath, dstRelativePath];
    }

    // Overwriting is only reachable when the precondition check above permitted it (MOVE
    // needs Overwrite:T, COPY needs Overwrite!=F). Build the replacement under a staging
    // name rather than removing the destination first: copying a tree takes as long as the
    // tree is big, and a failure part way through the old destroy-then-create left the
    // client with neither the old item nor a whole new one.
    // Staged unconditionally, which the `existing ? ... : nil` form was not. When the destination
    // looked absent, writePath WAS the destination — so the cleanup below, written for "a failed
    // tree copy leaves a partial tree behind", recursively removed whatever occupied that name by
    // the time the copy failed. Measured: a COPY racing a MKCOL destroyed 209 of 483 collections
    // the other client had just created, answering 403 to one and 201 to the other, in the default
    // configuration. The same line unlinked a pre-existing dangling symlink at the destination,
    // which -fileExistsAtPath: reports as absent because it follows links.
    //
    // Staging always means writePath is never a path this request did not create, so the cleanup
    // is safe by construction rather than by the caller remembering which branch it is in. The
    // swap then decides whether replacing is allowed: `expecting` is NULL when nothing was vetted,
    // which makes it exclusive, so an item that appeared in the window survives and the request
    // refuses. Simply staging unconditionally WITHOUT that — the fix originally proposed — is
    // worse than the defect: it moves the destruction into the swap's fallback and answers 201
    // Created, measured at 83/144 against 25/95 unfixed.
    struct stat vettedDst;
    BOOL const haveVettedDst = existing && (lstat([dstAbsolutePath fileSystemRepresentation], &vettedDst) == 0);
    NSString *const stagingPath = _StagingPathForPath(dstAbsolutePath);
    NSString *const writePath = stagingPath;

    if (isMove) {
        if (![fileManager moveItemAtPath:srcAbsolutePath toPath:writePath error:&error]) {
            // A full volume is not a permission problem, and 403 tells the client it is never
            // allowed to do this rather than that there is no room for it right now.
            if (WSKServerErrorStatusCodeForError(error) == kWSKHTTPStatusCode_InsufficientStorage) {
                return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InsufficientStorage underlyingError:error message:@"Failed moving \"%@\" to \"%@\"", srcRelativePath, dstRelativePath];
            }

            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden underlyingError:error message:@"Failed moving \"%@\" to \"%@\"", srcRelativePath, dstRelativePath];
        }
    } else if (shallowCopy && srcIsDirectory) {
        // The collection without its members. Built under the same staging name and swapped in by
        // the same exclusive path as every other spelling, so the destination is replaced only if
        // it was vetted — a separate "just mkdir it" shortcut here would sidestep that.
        // Deliberately NOT applied to a plain file: it has no internal members, so Depth: 0 and
        // Depth: infinity mean the same thing and copying the bytes is the only sensible reading.
        if (![fileManager createDirectoryAtPath:writePath withIntermediateDirectories:NO attributes:nil error:&error]) {
            if (WSKServerErrorStatusCodeForError(error) == kWSKHTTPStatusCode_InsufficientStorage) {
                return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InsufficientStorage underlyingError:error message:@"Failed copying \"%@\" to \"%@\"", srcRelativePath, dstRelativePath];
            }

            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden underlyingError:error message:@"Failed copying \"%@\" to \"%@\"", srcRelativePath, dstRelativePath];
        }
    } else {
        if (![fileManager copyItemAtPath:srcAbsolutePath toPath:writePath error:&error]) {
            [fileManager removeItemAtPath:writePath error:NULL];  // A failed tree copy leaves a partial tree behind.

            if (WSKServerErrorStatusCodeForError(error) == kWSKHTTPStatusCode_InsufficientStorage) {
                return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InsufficientStorage underlyingError:error message:@"Failed copying \"%@\" to \"%@\"", srcRelativePath, dstRelativePath];
            }

            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden underlyingError:error message:@"Failed copying \"%@\" to \"%@\"", srcRelativePath, dstRelativePath];
        }
    }

    if (![self _replaceItemAtPath:dstAbsolutePath withStagedItemAtPath:stagingPath expecting:(haveVettedDst ? &vettedDst : NULL) error:&error]) {
        // The swap is the only step that can fail with the replacement already built, so
        // unwind it: put a MOVE's source back rather than stranding it under the staging
        // name, and drop a COPY's staged duplicate. Either way the destination is intact.
        if (isMove) {
            [fileManager moveItemAtPath:stagingPath toPath:srcAbsolutePath error:NULL];
        } else {
            [fileManager removeItemAtPath:stagingPath error:NULL];
        }

        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden underlyingError:error message:@"Failed replacing \"%@\"", dstRelativePath];
    }

    if (isMove) {
        if ([self.delegate respondsToSelector:@selector(davServer:didMoveItemFromPath:toPath:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // Re-read and re-check inside the block. The property is weak AND mutable, so the
                // object checked above need not be the one messaged here — a host app that swaps
                // its delegate for another LIVE object implementing a different subset of these
                // optional methods raises unrecognized-selector, and nothing in Sources/ catches an
                // NSException. (Setting it to nil, or letting it deallocate, was always safe: the
                // weak read yields nil and the message is a no-op.) The strong local also removes a
                // second weak load between this check and the send. Deliberately NOT a strong
                // capture at check time: that would keep a delegate the host app has released alive
                // and deliver into an object mid-teardown.
                id<WSKWebDAVServerDelegate> const delegate = self.delegate;

                if ([delegate respondsToSelector:@selector(davServer:didMoveItemFromPath:toPath:)]) {
                    [delegate davServer:self didMoveItemFromPath:srcAbsolutePath toPath:dstAbsolutePath];
                }
            });
        }
    } else {
        if ([self.delegate respondsToSelector:@selector(davServer:didCopyItemFromPath:toPath:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // Re-read and re-check inside the block. The property is weak AND mutable, so the
                // object checked above need not be the one messaged here — a host app that swaps
                // its delegate for another LIVE object implementing a different subset of these
                // optional methods raises unrecognized-selector, and nothing in Sources/ catches an
                // NSException. (Setting it to nil, or letting it deallocate, was always safe: the
                // weak read yields nil and the message is a no-op.) The strong local also removes a
                // second weak load between this check and the send. Deliberately NOT a strong
                // capture at check time: that would keep a delegate the host app has released alive
                // and deliver into an object mid-teardown.
                id<WSKWebDAVServerDelegate> const delegate = self.delegate;

                if ([delegate respondsToSelector:@selector(davServer:didCopyItemFromPath:toPath:)]) {
                    [delegate davServer:self didCopyItemFromPath:srcAbsolutePath toPath:dstAbsolutePath];
                }
            });
        }
    }

    return [WSKResponse responseWithStatusCode:(existing ? kWSKHTTPStatusCode_NoContent : kWSKHTTPStatusCode_Created)];
}

static inline xmlNodePtr _XMLChildWithName(xmlNodePtr child, const xmlChar *name) {
    while (child) {
        if ((child->type == XML_ELEMENT_NODE) && !xmlStrcmp(child->name, name)) {
            return child;
        }

        child = child->next;
    }
    return NULL;
}

// The closing tag matching _DeadPropertyElement()'s opening one, so a stored value can be wrapped.
- (NSString *)_closingElementForDeadPropertyKey:(NSString *)key {
    NSRange const close = [key rangeOfString:@"}"];

    if (![key hasPrefix:@"{"] || (close.location == NSNotFound)) {
        return [NSString stringWithFormat:@"</%@>", _XMLEscape(key)];
    }

    NSString *const href = [key substringWithRange:NSMakeRange(1, close.location - 1)];
    NSString *const name = [key substringFromIndex:(close.location + 1)];
    return [NSString stringWithFormat:@"</%@:%@>", [href isEqualToString:@"DAV:"] ? @"D" : @"W", _XMLEscape(name)];
}

- (void)_addPropertyResponseForItem:(NSString *)itemPath resource:(NSString *)resourcePath properties:(DAVProperties)properties kind:(DAVPropFindKind)kind unsupported:(NSArray<NSString *> *)unsupported xmlString:(NSMutableString *)xmlString {
    NSMutableCharacterSet *const allowed = [[NSCharacterSet URLPathAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"<&>?+"];
    NSString *const escapedPath = [resourcePath stringByAddingPercentEncodingWithAllowedCharacters:allowed];

    if (escapedPath) {
        NSDictionary *const attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:itemPath error:NULL];
        // Classified by what a symlink points at, so the listing describes what is actually served.
        NSString *resolvedName = nil;
        NSString *const type = WSKServableFileTypeAtPath(itemPath, _uploadDirectory, _allowHiddenItems, &resolvedName);
        BOOL isFile = [type isEqualToString:NSFileTypeRegular];
        BOOL isDirectory = [type isEqualToString:NSFileTypeDirectory];

        if ((isFile && [self _checkFileExtensionForName:[itemPath lastPathComponent] resolvedName:resolvedName]) || isDirectory) {
            [xmlString appendString:@"<D:response>"];
            [xmlString appendFormat:@"<D:href>%@</D:href>", escapedPath];

            // <propname/> asks which properties EXIST, not what they hold, so the names go out as
            // empty elements. RFC 4918 §9.1 makes it part of the method; it used to be refused with
            // 400 by the body parser, which told a client the request was malformed.
            if (kind == kDAVPropFind_PropName) {
                [xmlString appendString:@"<D:propstat><D:prop>"];
                [xmlString appendString:@"<D:resourcetype/>"];
                [xmlString appendString:@"<D:creationdate/>"];

                if (isFile) {
                    [xmlString appendString:@"<D:getlastmodified/>"];
                    [xmlString appendString:@"<D:getcontentlength/>"];
                }

                for (NSString *key in _DeadPropertiesAtPath(itemPath)) {
                    [xmlString appendString:_DeadPropertyElement(key)];
                }

                [xmlString appendString:@"</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>"];
                [xmlString appendString:@"</D:response>\n"];
                return;
            }

            [xmlString appendString:@"<D:propstat>"];
            [xmlString appendString:@"<D:prop>"];

            if (properties & kDAVProperty_ResourceType) {
                if (isDirectory) {
                    [xmlString appendString:@"<D:resourcetype><D:collection/></D:resourcetype>"];
                } else {
                    [xmlString appendString:@"<D:resourcetype/>"];
                }
            }

            if ((properties & kDAVProperty_CreationDate) && attributes[NSFileCreationDate]) {
                [xmlString appendFormat:@"<D:creationdate>%@</D:creationdate>", WSKFormatISO8601((NSDate *)[attributes fileCreationDate])];
            }

            if ((properties & kDAVProperty_LastModified) && isFile && attributes[NSFileModificationDate]) {  // Last modification date is not useful for directories as it changes implicitely and 'Last-Modified' header is not provided for directories anyway
                // The same rule the GET path applies when it MINTS a Last-Modified, for the same
                // reason. Without it PROPFIND handed out precisely the date WSKFileResponse exists
                // to refuse to issue — one still inside its own timestamp bucket, so a later
                // If-Range resume carrying it spliced two builds under one 206. And PROPFIND emits
                // no getetag, so that unsealed date was the ONLY validator a PROPFIND-driven client
                // could obtain. Measured 12/12 splices before this.
                //
                // Opened O_NOFOLLOW because the containment and hidden-item rules have already
                // judged the resolved path; this only needs the descriptor to ask the filesystem
                // its timestamp granularity. If it cannot be opened the property is omitted, which
                // is the same fail-closed direction as an unsealed date.
                int const descriptor = open([itemPath fileSystemRepresentation], O_RDONLY | O_NOFOLLOW);

                if (descriptor >= 0) {
                    struct stat info;

                    if ((fstat(descriptor, &info) == 0) && WSKLastModifiedDateIsSealed(descriptor, &info)) {
                        [xmlString appendFormat:@"<D:getlastmodified>%@</D:getlastmodified>", WSKFormatRFC822((NSDate *)[attributes fileModificationDate])];
                    }

                    close(descriptor);
                }
            }

            if ((properties & kDAVProperty_ContentLength) && !isDirectory && attributes[NSFileSize]) {
                [xmlString appendFormat:@"<D:getcontentlength>%llu</D:getcontentlength>", [attributes fileSize]];
            }

            // Dead properties stored by PROPPATCH. <allprop/> returns them all; a named request
            // returns the ones it asked for and reports the rest as 404 below.
            NSDictionary<NSString *, NSString *> *const dead = _DeadPropertiesAtPath(itemPath);
            NSMutableArray<NSString *> *const notFound = [NSMutableArray array];

            if (kind == kDAVPropFind_AllProp) {
                for (NSString *key in dead) {
                    [xmlString appendFormat:@"%@%@%@", [_DeadPropertyElement(key) stringByReplacingOccurrencesOfString:@"/>" withString:@">"], _XMLEscape(dead[key]), [self _closingElementForDeadPropertyKey:key]];
                }
            } else {
                for (NSString *key in unsupported) {
                    NSString *const value = dead[key];

                    if (value) {
                        [xmlString appendFormat:@"%@%@%@", [_DeadPropertyElement(key) stringByReplacingOccurrencesOfString:@"/>" withString:@">"], _XMLEscape(value), [self _closingElementForDeadPropertyKey:key]];
                    } else {
                        [notFound addObject:key];
                    }
                }
            }

            [xmlString appendString:@"</D:prop>"];
            [xmlString appendString:@"<D:status>HTTP/1.1 200 OK</D:status>"];
            [xmlString appendString:@"</D:propstat>"];

            // A property that was asked for and cannot be returned gets its OWN propstat with 404.
            // Without it the response asserted "HTTP/1.1 200 OK" over a <prop> that silently
            // omitted them, so a client asking for three properties and receiving one could not
            // tell "this property does not exist here" from "it exists and is empty" — which is
            // the distinction the propstat structure exists to draw.
            if (notFound.count > 0) {
                [xmlString appendString:@"<D:propstat><D:prop>"];

                for (NSString *key in notFound) {
                    [xmlString appendString:_DeadPropertyElement(key)];
                }

                [xmlString appendString:@"</D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>"];
            }

            [xmlString appendString:@"</D:response>\n"];
        }

    } else {
        [self logError:@"Failed escaping path: %@", itemPath];
    }
}

// RFC 4918 §9.2. Class 1 lists this as a MUST, and it was 501 while OPTIONS advertised "DAV: 1" —
// a promise the code did not keep. Live properties are derived from the filesystem and cannot be
// set, so they are refused with 403; everything else is a dead property and is stored.
//
// The method is ATOMIC (§9.2): either every instruction applies or none does. So the whole update is
// computed against a copy first, and only written if nothing was refused — a client told 424 Failed
// Dependency for the rest can retry the whole document without having to work out what half-landed.
- (WSKResponse *)performPROPPATCH:(WSKDataRequest *)request {
    WSKErrorResponse *const tooLarge = _ResponseIfRequestBodyTooLarge(request);

    if (tooLarge) {
        return tooLarge;
    }

    NSString *const relativePath = request.path;
    BOOL isHidden = NO;
    NSString *const absolutePath = [self _resolvedPathForRelativePath:relativePath hidden:&isHidden];

    if (absolutePath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Setting properties on \"%@\" is not allowed", relativePath];
    }

    BOOL isDirectory = NO;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    if (isHidden || (!isDirectory && ![self _checkFileExtension:[absolutePath lastPathComponent]])) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Setting properties on \"%@\" is not allowed", relativePath];
    }

    WSKResponse *const preconditionFailure = [self _preconditionFailureForRequest:request atPath:absolutePath];

    if (preconditionFailure) {
        return preconditionFailure;
    }

    xmlDocPtr const document = request.data.length ? xmlReadMemory(request.data.bytes, (int)request.data.length, NULL, NULL, kXMLParseOptions) : NULL;
    xmlNodePtr const rootNode = document ? _XMLChildWithName(document->children, (const xmlChar *)"propertyupdate") : NULL;

    if (rootNode == NULL) {
        if (document) {
            xmlFreeDoc(document);
        }

        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Invalid DAV property update for \"%@\"", relativePath];
    }

    NSMutableDictionary<NSString *, NSString *> *const properties = [_DeadPropertiesAtPath(absolutePath) mutableCopy];
    NSMutableArray<NSString *> *const applied = [NSMutableArray array];
    NSMutableArray<NSString *> *const refused = [NSMutableArray array];
    BOOL changed = NO;

    for (xmlNodePtr instruction = rootNode->children; instruction != NULL; instruction = instruction->next) {
        if (instruction->type != XML_ELEMENT_NODE) {
            continue;
        }

        BOOL const isSet = !xmlStrcmp(instruction->name, (const xmlChar *)"set");
        BOOL const isRemove = !xmlStrcmp(instruction->name, (const xmlChar *)"remove");

        if (!isSet && !isRemove) {
            continue;
        }

        xmlNodePtr const propNode = _XMLChildWithName(instruction->children, (const xmlChar *)"prop");

        for (xmlNodePtr node = propNode ? propNode->children : NULL; node != NULL; node = node->next) {
            if (node->type != XML_ELEMENT_NODE) {
                continue;
            }

            NSString *const localName = [NSString stringWithUTF8String:(const char *)node->name];
            NSString *const href = (node->ns && node->ns->href) ? [NSString stringWithUTF8String:(const char *)node->ns->href] : @"";

            if (localName.length == 0) {
                continue;
            }

            // A live property is computed from the filesystem, so it cannot be stored. RFC 4918
            // §9.2 wants that reported per-property rather than the request failing as malformed.
            if ([href isEqualToString:@"DAV:"] &&
                ([localName isEqualToString:@"resourcetype"] || [localName isEqualToString:@"creationdate"] ||
                 [localName isEqualToString:@"getlastmodified"] || [localName isEqualToString:@"getcontentlength"] ||
                 [localName isEqualToString:@"getetag"] || [localName isEqualToString:@"lockdiscovery"] ||
                 [localName isEqualToString:@"supportedlock"])) {
                [refused addObject:_DeadPropertyElement(_DeadPropertyKey(href, localName))];
                continue;
            }

            NSString *const key = _DeadPropertyKey(href, localName);

            if (isSet) {
                xmlChar *const content = xmlNodeGetContent(node);
                NSString *const value = content ? [NSString stringWithUTF8String:(const char *)content] : @"";

                if (content) {
                    xmlFree(content);
                }

                properties[key] = (value != nil) ? value : @"";
            } else {
                [properties removeObjectForKey:key];
            }

            [applied addObject:_DeadPropertyElement(key)];
            changed = YES;
        }
    }

    xmlFreeDoc(document);

    // Atomic: nothing is written when any instruction was refused, and the applied ones become 424.
    if ((refused.count == 0) && changed && !_SetDeadPropertiesAtPath(absolutePath, properties)) {
        int const failure = errno;
        [self logWarning:@"Failed storing DAV properties for \"%@\" (errno %i)", relativePath, failure];
        [refused addObjectsFromArray:applied];
        [applied removeAllObjects];
    }

    NSMutableString *const xmlString = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"utf-8\" ?>"];
    [xmlString appendString:@"<D:multistatus xmlns:D=\"DAV:\">\n"];
    [xmlString appendString:@"<D:response>"];
    [xmlString appendFormat:@"<D:href>%@</D:href>", _XMLEscape([relativePath hasPrefix:@"/"] ? relativePath : [@"/" stringByAppendingString:relativePath])];

    if (refused.count > 0) {
        [xmlString appendString:@"<D:propstat><D:prop>"];

        for (NSString *element in refused) {
            [xmlString appendString:element];
        }

        [xmlString appendString:@"</D:prop><D:status>HTTP/1.1 403 Forbidden</D:status></D:propstat>"];

        if (applied.count > 0) {
            [xmlString appendString:@"<D:propstat><D:prop>"];

            for (NSString *element in applied) {
                [xmlString appendString:element];
            }

            [xmlString appendString:@"</D:prop><D:status>HTTP/1.1 424 Failed Dependency</D:status></D:propstat>"];
        }
    } else {
        [xmlString appendString:@"<D:propstat><D:prop>"];

        for (NSString *element in applied) {
            [xmlString appendString:element];
        }

        [xmlString appendString:@"</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>"];
    }

    [xmlString appendString:@"</D:response>\n</D:multistatus>"];

    WSKDataResponse *const response = [WSKDataResponse responseWithData:(NSData * _Nonnull)[xmlString dataUsingEncoding:NSUTF8StringEncoding] contentType:@"application/xml; charset=\"utf-8\""];
    response.statusCode = kWSKHTTPStatusCode_MultiStatus;
    return response;
}

- (WSKResponse *)performPROPFIND:(WSKDataRequest *)request {
    NSInteger depth;
    NSString *const depthHeader = request.headers[@"Depth"];

    if ([depthHeader isEqualToString:@"0"]) {
        depth = 0;
    } else if ([depthHeader isEqualToString:@"1"]) {
        depth = 1;
    } else if ((depthHeader == nil) || _HeaderTokenIs(depthHeader, @"infinity")) {
        // RFC 4918 §9.1: an absent Depth on PROPFIND means "infinity". It fell through to the
        // bare 400 below, telling a client its perfectly legal request was malformed rather than
        // that it should retry with a bounded depth — the same rule as the explicit spelling,
        // enforced at only one of its two spellings.
        // RFC 4918 §9.1: a server that refuses an infinite-depth PROPFIND SHOULD answer 403 with
        // the DAV:propfind-finite-depth precondition, which is machine-readable and tells the
        // client to retry with a bounded depth. A bare 400 says only "malformed", which this is not.
        WSKDataResponse *const response = [WSKDataResponse responseWithData:(NSData * _Nonnull)[@"<?xml version=\"1.0\" encoding=\"utf-8\" ?><D:error xmlns:D=\"DAV:\"><D:propfind-finite-depth/></D:error>" dataUsingEncoding:NSUTF8StringEncoding] contentType:@"application/xml; charset=\"utf-8\""];
        response.statusCode = kWSKHTTPStatusCode_Forbidden;
        return response;
    } else {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Unsupported 'Depth' header: %@", depthHeader];
    }

    DAVProperties properties = 0;
    DAVPropFindKind kind = kDAVPropFind_AllProp;
    NSMutableArray<NSString *> *const unsupported = [NSMutableArray array];

    if (request.data.length) {
        WSKErrorResponse *const tooLarge = _ResponseIfRequestBodyTooLarge(request);

        if (tooLarge) {
            return tooLarge;
        }

        BOOL success = YES;
        xmlDocPtr document = xmlReadMemory(request.data.bytes, (int)request.data.length, NULL, NULL, kXMLParseOptions);

        if (document) {
            xmlNodePtr rootNode = _XMLChildWithName(document->children, (const xmlChar *)"propfind");
            xmlNodePtr allNode = rootNode ? _XMLChildWithName(rootNode->children, (const xmlChar *)"allprop") : NULL;
            xmlNodePtr nameNode = rootNode ? _XMLChildWithName(rootNode->children, (const xmlChar *)"propname") : NULL;
            xmlNodePtr propNode = rootNode ? _XMLChildWithName(rootNode->children, (const xmlChar *)"prop") : NULL;

            if (allNode) {
                properties = kDAVAllProperties;
            } else if (nameNode) {
                kind = kDAVPropFind_PropName;
                properties = kDAVAllProperties;
            } else if (propNode) {
                kind = kDAVPropFind_Named;
                xmlNodePtr node = propNode->children;

                while (node) {
                    if (!xmlStrcmp(node->name, (const xmlChar *)"resourcetype")) {
                        properties |= kDAVProperty_ResourceType;
                    } else if (!xmlStrcmp(node->name, (const xmlChar *)"creationdate")) {
                        properties |= kDAVProperty_CreationDate;
                    } else if (!xmlStrcmp(node->name, (const xmlChar *)"getlastmodified")) {
                        properties |= kDAVProperty_LastModified;
                    } else if (!xmlStrcmp(node->name, (const xmlChar *)"getcontentlength")) {
                        properties |= kDAVProperty_ContentLength;
                    } else if (node->type == XML_ELEMENT_NODE) {
                        // Remembered rather than dropped, so it can be reported in a 404 propstat.
                        // The namespace travels with it: a client asking for a property in its own
                        // namespace must see that name back, not a DAV:-qualified guess at it.
                        NSString *const localName = [NSString stringWithUTF8String:(const char *)node->name];
                        const char *const href = (node->ns && node->ns->href) ? (const char *)node->ns->href : NULL;

                        if (localName.length) {
                            // The SAME convention PROPPATCH keys by — a property in no namespace
                            // keys by its bare name. Defaulting to "DAV:" here instead made the two
                            // parsers disagree, so a no-namespace property could be stored and then
                            // never read back. litmus's propnullns/propget pair found it.
                            [unsupported addObject:_DeadPropertyKey(href ? [NSString stringWithUTF8String:href] : @"", localName)];
                        }
                    }

                    node = node->next;
                }
            } else {
                success = NO;
            }

            xmlFreeDoc(document);
        } else {
            success = NO;
        }

        if (!success) {
            NSString *string = [[NSString alloc] initWithData:request.data encoding:NSUTF8StringEncoding];
            return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Invalid DAV properties:\n%@", string];
        }
    } else {
        properties = kDAVAllProperties;
    }

    NSString *relativePath = request.path;
    NSString *absolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];
    BOOL isDirectory = NO;

    // As in -performGET:, containment is confirmed before the item is stat'ed so that the
    // 404-vs-403 answer is not an existence oracle for paths outside the share.
    BOOL isHidden = NO;
    NSString *const resolvedPath = [self _resolvedPathForRelativePath:relativePath hidden:&isHidden];

    if (resolvedPath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Retrieving properties for \"%@\" is not allowed", relativePath];
    }

    absolutePath = resolvedPath;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    NSString *const itemName = [absolutePath lastPathComponent];

    if (isHidden || (!isDirectory && ![self _checkFileExtension:itemName])) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Retrieving properties for \"%@\" is not allowed", relativePath];
    }

    NSArray *items = nil;

    if (isDirectory) {
        NSError *error = nil;
        items = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:absolutePath error:&error] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

        if (items == nil) {
            return [WSKErrorResponse responseWithServerError:kWSKHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed listing directory \"%@\"", relativePath];
        }
    }

    NSMutableString *const xmlString = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"utf-8\" ?>"];
    [xmlString appendString:@"<D:multistatus xmlns:D=\"DAV:\">\n"];

    if (![relativePath hasPrefix:@"/"]) {
        relativePath = [@"/" stringByAppendingString:relativePath];
    }

    [self _addPropertyResponseForItem:absolutePath resource:relativePath properties:properties kind:kind unsupported:unsupported xmlString:xmlString];

    if (depth == 1) {
        if (![relativePath hasSuffix:@"/"]) {
            relativePath = [relativePath stringByAppendingString:@"/"];
        }

        for (NSString *item in items) {
            if (_allowHiddenItems || ![item hasPrefix:@"."]) {
                [self _addPropertyResponseForItem:[absolutePath stringByAppendingPathComponent:item] resource:[relativePath stringByAppendingString:item] properties:properties kind:kind unsupported:unsupported xmlString:xmlString];
            }
        }
    }

    [xmlString appendString:@"</D:multistatus>"];

    WSKDataResponse *const response = [WSKDataResponse responseWithData:(NSData *)[xmlString dataUsingEncoding:NSUTF8StringEncoding]
                                                                             contentType:@"application/xml; charset=\"utf-8\""];
    response.statusCode = kWSKHTTPStatusCode_MultiStatus;
    return response;
}

- (WSKResponse *)performLOCK:(WSKDataRequest *)request {
    // ⚠️ THIS DOES NOT LOCK ANYTHING, and the name is the only thing about it that says otherwise.
    // It mints a token, returns a well-formed lockdiscovery document, and stores NO state: there is
    // no lock table, no timeout, no reaping, and the "If:" header is not parsed anywhere in this
    // file. A second client is neither blocked nor told about the first.
    //
    // It exists solely because macOS Finder refuses to write to a share that does not advertise
    // class 2, which is also why OPTIONS answers "1, 2" for Finder alone. Deliberately not made
    // real: locking exists to stop concurrent writers losing each other's updates, the deployments
    // here are single-user, and the same protection is now available statelessly through If-Match
    // and If-Unmodified-Since — which every client can use, not only ones that lock. Real class 2
    // would need the "If:" header grammar (tagged and untagged lists, Not, tokens versus ETags),
    // which is a parser, and parsers have been by far the richest source of defects in this
    // codebase; plus long-lived lock state, which is the accumulation hazard the design priorities
    // single out. If a genuinely concurrent client ever matters, the cheap version is an in-memory
    // path -> token map enforced on the destructive verbs, accepting only "If: (<token>)".
    if (!_IsMacFinder(request)) {
        return _MethodNotAllowed(@"LOCK method only allowed for Mac Finder");
    }

    // The Host header is required because it is interpolated into the <D:lockroot>
    // href below, and -stringByAppendingString: raises NSInvalidArgumentException on a
    // nil argument. Uncaught, that terminates the whole server process — the same
    // one-request kill already fixed for COPY/MOVE, which this method missed. Host is
    // mandatory in HTTP/1.1 but nothing else here enforces it.
    NSString *const hostHeader = request.headers[@"Host"];

    if (hostHeader.length == 0) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Missing 'Host' header"];
    }

    NSString *const relativePath = request.path;
    NSString *absolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];
    BOOL isDirectory = NO;

    // Locking neither reads nor writes content, but the resolved location is checked here
    // — before the item is stat'ed — so that no path-handling entry point is left without
    // one, and so the 404-vs-403 answer is not an existence oracle outside the share.
    BOOL isHidden = NO;
    NSString *const resolvedPath = [self _resolvedPathForRelativePath:relativePath hidden:&isHidden];

    if (resolvedPath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Locking \"%@\" is not allowed", relativePath];
    }

    absolutePath = resolvedPath;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    NSString *const depthHeader = request.headers[@"Depth"];
    NSString *const timeoutHeader = request.headers[@"Timeout"];
    NSString *scope = nil;
    NSString *type = nil;
    NSString *owner = nil;
    NSString *token = nil;
    WSKErrorResponse *const tooLarge = _ResponseIfRequestBodyTooLarge(request);

    if (tooLarge) {
        return tooLarge;
    }

    BOOL success = YES;
    xmlDocPtr document = xmlReadMemory(request.data.bytes, (int)request.data.length, NULL, NULL, kXMLParseOptions);

    if (document) {
        xmlNodePtr node = _XMLChildWithName(document->children, (const xmlChar *)"lockinfo");

        if (node) {
            xmlNodePtr scopeNode = _XMLChildWithName(node->children, (const xmlChar *)"lockscope");

            if (scopeNode && scopeNode->children && scopeNode->children->name) {
                scope = [NSString stringWithUTF8String:(const char *)scopeNode->children->name];
            }

            xmlNodePtr typeNode = _XMLChildWithName(node->children, (const xmlChar *)"locktype");

            if (typeNode && typeNode->children && typeNode->children->name) {
                type = [NSString stringWithUTF8String:(const char *)typeNode->children->name];
            }

            xmlNodePtr ownerNode = _XMLChildWithName(node->children, (const xmlChar *)"owner");

            if (ownerNode) {
                ownerNode = _XMLChildWithName(ownerNode->children, (const xmlChar *)"href");

                if (ownerNode && ownerNode->children && ownerNode->children->content) {
                    owner = [NSString stringWithUTF8String:(const char *)ownerNode->children->content];
                }
            }
        } else {
            success = NO;
        }

        xmlFreeDoc(document);
    } else {
        success = NO;
    }

    if (!success) {
        NSString *string = [[NSString alloc] initWithData:request.data encoding:NSUTF8StringEncoding];
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Invalid DAV properties:\n%@", string];
    }

    if (![scope isEqualToString:@"exclusive"] || ![type isEqualToString:@"write"] || ![depthHeader isEqualToString:@"0"]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Locking request \"%@/%@/%@\" for \"%@\" is not allowed", scope, type, depthHeader, relativePath];
    }

    NSString *const itemName = [absolutePath lastPathComponent];

    if (isHidden || (!isDirectory && ![self _checkFileExtension:itemName])) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Locking \"%@\" is not allowed", relativePath];
    }

#ifdef __WEBSERVERKIT_ENABLE_TESTING__
    NSString *const lockTokenHeader = request.headers[@"X-WebServerKit-LockToken"];

    if (lockTokenHeader) {
        token = lockTokenHeader;
    }

#endif

    if (!token) {
        CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
        CFStringRef string = CFUUIDCreateString(kCFAllocatorDefault, uuid);
        token = [NSString stringWithFormat:@"urn:uuid:%@", (__bridge NSString *)string];
        CFRelease(string);
        CFRelease(uuid);
    }

    NSMutableString *const xmlString = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"utf-8\" ?>"];
    [xmlString appendString:@"<D:prop xmlns:D=\"DAV:\">\n"];
    [xmlString appendString:@"<D:lockdiscovery>\n<D:activelock>\n"];
    [xmlString appendFormat:@"<D:locktype><D:%@/></D:locktype>\n", type];
    [xmlString appendFormat:@"<D:lockscope><D:%@/></D:lockscope>\n", scope];
    [xmlString appendFormat:@"<D:depth>%@</D:depth>\n", depthHeader];

    if (owner) {
        [xmlString appendFormat:@"<D:owner><D:href>%@</D:href></D:owner>\n", _XMLEscape(owner)];
    }

    if (timeoutHeader) {
        [xmlString appendFormat:@"<D:timeout>%@</D:timeout>\n", _XMLEscape(timeoutHeader)];
    }

    // Escaped like every other interpolated value here: the token is server-generated in
    // production, but the testing-only header above lets a client supply it verbatim.
    [xmlString appendFormat:@"<D:locktoken><D:href>%@</D:href></D:locktoken>\n", _XMLEscape(token)];
    // -stringWithFormat: renders a nil argument as "(null)" rather than raising, so this
    // stays safe even if the Host guard above is ever moved or removed.
    NSString *const lockroot = [NSString stringWithFormat:@"http://%@/%@", hostHeader, relativePath];
    [xmlString appendFormat:@"<D:lockroot><D:href>%@</D:href></D:lockroot>\n", _XMLEscape(lockroot)];
    [xmlString appendString:@"</D:activelock>\n</D:lockdiscovery>\n"];
    [xmlString appendString:@"</D:prop>"];

    [self logVerbose:@"WebDAV pretending to lock \"%@\"", relativePath];
    WSKDataResponse *response = [WSKDataResponse responseWithData:(NSData *)[xmlString dataUsingEncoding:NSUTF8StringEncoding]
                                                                        contentType:@"application/xml; charset=\"utf-8\""];
    return response;
}

- (WSKResponse *)performUNLOCK:(WSKRequest *)request {
    if (!_IsMacFinder(request)) {
        return _MethodNotAllowed(@"UNLOCK method only allowed for Mac Finder");
    }

    NSString *const relativePath = request.path;
    NSString *absolutePath = [_uploadDirectory stringByAppendingPathComponent:WSKNormalizePath(relativePath)];
    BOOL isDirectory = NO;

    // As in -performLOCK:, checked so that no path-handling entry point lacks one, and
    // ahead of the stat so the 404-vs-403 answer reveals nothing outside the share.
    BOOL isHidden = NO;
    NSString *const resolvedPath = [self _resolvedPathForRelativePath:relativePath hidden:&isHidden];

    if (resolvedPath == nil) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Unlocking \"%@\" is not allowed", relativePath];
    }

    absolutePath = resolvedPath;

    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
    }

    NSString *const tokenHeader = request.headers[@"Lock-Token"];

    if (!tokenHeader.length) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_BadRequest message:@"Missing 'Lock-Token' header"];
    }

    NSString *const itemName = [absolutePath lastPathComponent];

    if (isHidden || (!isDirectory && ![self _checkFileExtension:itemName])) {
        return [WSKErrorResponse responseWithClientError:kWSKHTTPStatusCode_Forbidden message:@"Unlocking \"%@\" is not allowed", relativePath];
    }

    [self logVerbose:@"WebDAV pretending to unlock \"%@\"", relativePath];
    return [WSKResponse responseWithStatusCode:kWSKHTTPStatusCode_NoContent];
}

@end

@implementation WSKWebDAVServer (Subclassing)

- (BOOL)shouldUploadFileAtPath:(NSString *)path withTemporaryFile:(NSString *)tempPath {
    return YES;
}

- (BOOL)shouldMoveItemFromPath:(NSString *)fromPath toPath:(NSString *)toPath {
    return YES;
}

- (BOOL)shouldCopyItemFromPath:(NSString *)fromPath toPath:(NSString *)toPath {
    return YES;
}

- (BOOL)shouldDeleteItemAtPath:(NSString *)path {
    return YES;
}

- (BOOL)shouldCreateDirectoryAtPath:(NSString *)path {
    return YES;
}

@end
