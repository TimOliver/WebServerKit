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

#import "WSKPathResolution.h"

#import <stdlib.h>
#import <sys/param.h>
#import <sys/stat.h>
#import <unistd.h>

#import "WSKPrivate.h"

BOOL WSKPathContainsNULByte(NSString *path) {
    // NSLiteralSearch, because the default search honours composed character sequences: a
    // combining mark straight after the NUL absorbs it into a grapheme cluster and the NUL goes
    // unseen. That blinded this guard AND the truncation below — both documented defences of the
    // NUL line at once. See WSKPathComponentsSeparatedBySlash for the same trap in splitting.
    unichar nul = 0;
    return (path != nil) &&
           ([path rangeOfString:[NSString stringWithCharacters:&nul length:1] options:NSLiteralSearch].location != NSNotFound);
}

NSArray<NSString *> *WSKPathComponentsSeparatedBySlash(NSString *path) {
    // Built once: this runs for every path-taking request, and rebuilding a character set per
    // call would put an allocation on that path for no reason.
    static NSCharacterSet *separators = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        separators = [NSCharacterSet characterSetWithCharactersInString:@"/"];
    });

    return [path componentsSeparatedByCharactersInSet:separators];
}

NSString *WSKNormalizePath(NSString *path) {
    // Treat an embedded NUL as a path terminator, the way the filesystem's C-string APIs do.
    // Otherwise -pathExtension reads past the NUL while -fileSystemRepresentation truncates at
    // it, so "secret.dat\0.png" would pass an extension allow-list yet open "secret.dat".
    unichar nul = 0;
    NSRange const nulRange = [path rangeOfString:[NSString stringWithCharacters:&nul length:1] options:NSLiteralSearch];
    if (nulRange.location != NSNotFound) {
        path = [path substringToIndex:nulRange.location];
    }

    NSMutableArray *const components = [[NSMutableArray alloc] init];

    for (NSString *component in WSKPathComponentsSeparatedBySlash(path)) {
        if ([component isEqualToString:@".."]) {
            if (components.count) {  // Guard: -removeLastObject on an empty array is documented to raise; surplus ".." are simply dropped.
                [components removeLastObject];
            }
        } else if (component.length && ![component isEqualToString:@"."]) {
            [components addObject:component];
        }
    }

    if (path.length && ([path characterAtIndex:0] == '/')) {
        return [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];  // Preserve initial slash
    }

    return [components componentsJoinedByString:@"/"];
}

BOOL WSKNameIsHidden(NSString *name) {
    // The first code unit, never -hasPrefix:@"." — see the header for the measurement. Guarded
    // because -characterAtIndex: raises on an empty string, and nothing in Sources/ catches that.
    return (name.length > 0) && ([name characterAtIndex:0] == '.');
}

BOOL WSKPathIsInsideDirectory(NSString *path, NSString *directory) {
    if ((path.length == 0) || (directory.length == 0)) {
        return NO;
    }
    if ([path isEqualToString:directory]) {
        return NO;  // The directory itself is not "inside" it.
    }
    NSString *const prefix = [directory hasSuffix:@"/"] ? directory : [directory stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

// Fully resolve `path` with realpath(3). If the item does not exist yet — an upload or
// MKCOL destination — resolve its parent instead and re-attach the leaf, so intermediate
// symlinks are still resolved without requiring the target to exist. Returns nil when
// nothing along the path can be resolved.
static NSString *_RealPath(NSString *path) {
    if (path.length == 0) {
        return nil;
    }

    char buffer[PATH_MAX];
    NSFileManager *const fileManager = [NSFileManager defaultManager];
    char const *const representation = [path fileSystemRepresentation];

    // Nothing at or beyond PATH_MAX can name a filesystem entry: realpath(3), lstat(2) and every
    // other path call answer ENAMETOOLONG, so such a path can neither exist nor be created. Refuse
    // it here rather than letting the walk below discover it one component at a time.
    //
    // This is a BOUND, not an optimization: the walk below does work per missing component and is
    // driven by client input capped only by the header block, so without this guard a deep path is
    // a CPU amplifier — a denial of service on a server with a 128-connection cap and no rate
    // limiting. Fail CLOSED (nil, so callers answer 403). It reveals nothing: the verdict depends
    // only on the length the client sent, never on what the filesystem holds.
    if (strlen(representation) >= PATH_MAX) {
        return nil;
    }

    if (realpath(representation, buffer)) {
        return [fileManager stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
    }

    // realpath(3) failed. Normally the path just does not exist YET — a PUT or MKCOL to a new name —
    // and resolving the parent then appending the leaf is right for it. That is why this fallback
    // exists at all, so it MUST keep working.
    //
    // An entry that EXISTS and still fails realpath is different: a dangling link, a loop, or an
    // untraversable component. Treating one as "a new path inside the share" makes the answer depend
    // on whether the link's target exists (403 when it does, 404 when it does not) — an existence
    // oracle for the filesystem OUTSIDE the share, reachable through any escaping link in the served
    // content. Fail CLOSED. Dangling links and loops answer 403 rather than 404; neither was ever
    // served, so no working operation is lost.
    //
    // The walk climbs until an ancestor resolves rather than trying the parent ONCE: tolerating
    // exactly one missing component makes "absent" and "refused" the same answer two levels past
    // anything real — 403 where 404 is owed, which `rclone copy` treats as fatal.
    //
    // It does NOT reopen that oracle, and that distinction is why this lives here rather than in the
    // verbs. The REJECTED alternative — a -fileExistsAtPath: parent precheck per read verb — answers
    // YES/NO for paths outside the share, which IS the oracle. Here an escaping path resolves outside
    // the root and is refused by the caller's containment test whether or not anything exists there,
    // and a component that exists but will not resolve still fails closed each iteration.
    //
    // The write verbs are deliberately untouched: PUT, MKCOL and a MOVE/COPY destination answer 409
    // for a missing ancestor (RFC 4918 §9.7.1) from their own precheck, which this only lets them
    // reach. 409 is correct there and must not become 404.
    NSMutableArray<NSString *> *const missingComponents = [NSMutableArray array];
    NSString *cursor = path;

    while (YES) {
        struct stat entryInfo;

        if (lstat([cursor fileSystemRepresentation], &entryInfo) == 0) {
            return nil;
        }

        NSString *const parent = [cursor stringByDeletingLastPathComponent];
        NSString *const leaf = [cursor lastPathComponent];

        // Terminates: every iteration strictly shortens the path, and "/" is its own parent.
        if ((parent.length == 0) || (leaf.length == 0) || [parent isEqualToString:cursor]) {
            return nil;
        }

        // APPENDED, not inserted at index 0, and joined in a single pass below. Both spellings of
        // the obvious version are quadratic in the component count — -insertObject:atIndex:0
        // shifts the whole array on every component, and -stringByAppendingPathComponent: in a
        // loop copies the whole prefix on every component. Bounded by PATH_MAX above AND linear
        // here; if that ever matters, the lever is a component cap well below PATH_MAX.
        [missingComponents addObject:leaf];

        if (realpath([parent fileSystemRepresentation], buffer)) {
            NSString *const resolvedParent = [fileManager stringWithFileSystemRepresentation:buffer length:strlen(buffer)];

            if (resolvedParent == nil) {
                return nil;
            }

            NSMutableString *const resolved = [resolvedParent mutableCopy];

            // Collected leaf-first, so walk back out. "/" is the one parent that already ends in a
            // separator, hence the suffix test rather than an unconditional append.
            for (NSString *const component in [missingComponents reverseObjectEnumerator]) {
                if (![resolved hasSuffix:@"/"]) {
                    [resolved appendString:@"/"];
                }

                [resolved appendString:component];
            }

            return resolved;
        }

        cursor = parent;
    }
}

NSString *WSKResolveWithinDirectory(NSString *path, NSString *directory, NSString *__autoreleasing *outRelativePath) {
    NSString *const resolvedPath = _RealPath(path);
    NSString *const resolvedDirectory = _RealPath(directory);

    if (outRelativePath) {
        *outRelativePath = nil;
    }

    if ((resolvedPath == nil) || (resolvedDirectory == nil)) {
        return nil;  // Fail closed rather than acting on a path we could not verify.
    }

    if (![resolvedPath isEqualToString:resolvedDirectory] && !WSKPathIsInsideDirectory(resolvedPath, resolvedDirectory)) {
        return nil;
    }

    if (outRelativePath) {
        *outRelativePath = [resolvedPath isEqualToString:resolvedDirectory]
                               ? @""
                               : [resolvedPath substringFromIndex:(resolvedDirectory.length + ([resolvedDirectory hasSuffix:@"/"] ? 0 : 1))];
    }

    return resolvedPath;
}

NSString *WSKServableFileTypeAtPath(NSString *path, NSString *directory, BOOL allowHiddenItems, NSString *__autoreleasing *outResolvedName, NSString *__autoreleasing *outResolvedPath) {
    if (outResolvedName) {
        *outResolvedName = nil;
    }

    if (outResolvedPath) {
        *outResolvedPath = nil;
    }

    NSDictionary *const attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    NSString *const type = attributes[NSFileType];

    if (![type isEqualToString:NSFileTypeSymbolicLink]) {
        // Not a link: the type was observed at `path` itself, so that IS the resolved path.
        if (outResolvedPath) {
            *outResolvedPath = path;
        }

        return type;
    }

    // Judge the link by what it points at, and only when that is something this server would
    // actually serve: inside the directory, and a regular file or a directory itself.
    if (!WSKResolvedPathIsWithinDirectory(path, directory)) {
        return nil;
    }

    // Hiddenness as well as containment: a link whose own name carries no dot but which resolves
    // inside a dot-directory would otherwise be ADVERTISED by all three listings and then refused
    // 403 by every handler. "Advertise iff served" is the rule, in both directions.
    if (!allowHiddenItems && WSKResolvedPathHasHiddenComponent(path, directory)) {
        return nil;
    }

    struct stat info;

    if (stat([path fileSystemRepresentation], &info) != 0) {
        return nil;  // Dangling, or a loop: there is nothing to advertise.
    }

    // Derived here and handed out precisely so no caller resolves a second time: two observations
    // of a filesystem that need not agree is the class behind the retargeted-symlink escapes.
    if (outResolvedName || outResolvedPath) {
        char resolvedBuffer[PATH_MAX];

        if (realpath([path fileSystemRepresentation], resolvedBuffer) != NULL) {
            NSString *const resolved = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:resolvedBuffer length:strlen(resolvedBuffer)];

            if (outResolvedName) {
                *outResolvedName = [resolved lastPathComponent];
            }

            if (outResolvedPath) {
                *outResolvedPath = resolved;
            }
        }
    }

    if ((info.st_mode & S_IFMT) == S_IFDIR) {
        return NSFileTypeDirectory;
    }

    if ((info.st_mode & S_IFMT) == S_IFREG) {
        return NSFileTypeRegular;
    }

    return nil;
}

// The two path resolvers every path-taking verb in this library goes through. ONE implementation,
// deliberately: these were four near-verbatim copies, and copies drifting — a rule closed in one
// server and left open in another — is this codebase's single most reliable defect class. Each
// server keeps a three-line method wrapping these so every call site binds the result to the
// variable it already used, which makes "I missed one" structurally impossible. Do not inline
// the wrappers away, and do not add a resolver copy.

BOOL WSKPathsNameTheSameFile(NSString *path1, NSString *path2) {
    if ([path1 isEqualToString:path2]) {
        return YES;
    }

    id identifier1 = nil;
    id identifier2 = nil;
    return [[NSURL fileURLWithPath:path1] getResourceValue:&identifier1 forKey:NSURLFileResourceIdentifierKey error:NULL] &&
           [[NSURL fileURLWithPath:path2] getResourceValue:&identifier2
                                                    forKey:NSURLFileResourceIdentifierKey
                                                     error:NULL] &&
           identifier1 && [(NSObject *)identifier1 isEqual:identifier2];
}

NSString *WSKFirstUnvettableItemAtPath(NSString *absolutePath, BOOL isDirectory, NSArray<NSString *> *allowedExtensions) {
    if (allowedExtensions == nil) {
        return nil;  // No restriction configured: nothing to vet against.
    }

    if (!isDirectory) {
        NSString *const itemName = [absolutePath lastPathComponent];
        return WSKNamePassesExtensionAllowList(itemName, allowedExtensions) ? nil : itemName;
    }

    NSDirectoryEnumerator<NSString *> *const enumerator = [[NSFileManager defaultManager] enumeratorAtPath:absolutePath];

    for (NSString *subpath in enumerator) {
        NSString *const subpathType = [enumerator fileAttributes][NSFileType];

        if (WSKNameIsHidden([subpath lastPathComponent])) {
            // -skipDescendants is defined for the most recently returned SUBDIRECTORY. Calling it
            // for a dot-named FILE pops the enclosing level instead, switching the allow-list off
            // for everything after the first dot-name in readdir order — and a ".DS_Store" sits
            // in every Finder-touched folder, sorting early. Only a dot-named DIRECTORY may be
            // skipped wholesale.
            if ([subpathType isEqualToString:NSFileTypeDirectory]) {
                [enumerator skipDescendants];
            }

            continue;
        }

        // An extensionless file ("README", "LICENSE") is vetted like any other: a direct DELETE of
        // it is already refused, so letting a recursive delete destroy it would make the same
        // request mean two different things.
        if ([subpathType isEqualToString:NSFileTypeRegular] && !WSKNamePassesExtensionAllowList(subpath, allowedExtensions)) {
            return subpath;
        }
    }

    return nil;
}

NSString *WSKNamedEntryPathForRelativePath(NSString *relativePath, NSString *directory, BOOL allowHiddenItems, BOOL *outHidden) {
    if (WSKPathContainsNULByte(relativePath)) {
        return nil;
    }

    NSString *const normalizedPath = WSKNormalizePath(relativePath);

    if (outHidden) {
        *outHidden = NO;
    }

    // Naming the root itself is not something a destructive verb may act on, and there is no
    // final component to preserve either.
    if ((normalizedPath.length == 0) || [normalizedPath isEqualToString:@"/"]) {
        return nil;
    }

    NSString *namedRelativePath = nil;
    NSString *const namedPath = WSKResolveNamedEntryWithinDirectory([directory stringByAppendingPathComponent:normalizedPath], directory, &namedRelativePath);

    if (namedPath == nil) {
        return nil;
    }

    if (outHidden && !allowHiddenItems) {
        for (NSString *component in [normalizedPath pathComponents]) {
            if (WSKNameIsHidden(component)) {
                *outHidden = YES;
                return namedPath;
            }
        }

        for (NSString *component in [namedRelativePath pathComponents]) {
            if (WSKNameIsHidden(component)) {
                *outHidden = YES;
                return namedPath;
            }
        }
    }

    return namedPath;
}

NSString *WSKResolvedPathForRelativePath(NSString *relativePath, NSString *directory, BOOL allowHiddenItems, BOOL *outHidden) {
    // Refusal is the FIRST line against an embedded NUL, and it lives here — the one point every
    // path-taking verb goes through — so a verb added later cannot forget it (acting on the
    // truncated prefix is how "DELETE /Victim\0/x" destroys /Victim). WSKNormalizePath keeps
    // truncating as the second line, so the "secret.dat\0.png" allow-list bypass stays closed.
    if (WSKPathContainsNULByte(relativePath)) {
        return nil;
    }

    NSString *const normalizedPath = WSKNormalizePath(relativePath);
    NSString *resolvedRelativePath = nil;
    NSString *const resolvedPath = WSKResolveWithinDirectory([directory stringByAppendingPathComponent:normalizedPath], directory, &resolvedRelativePath);

    if (outHidden) {
        *outHidden = NO;
    }

    if (resolvedPath == nil) {
        return nil;
    }

    // A symlink that resolves to the share root itself is never what the client meant, and
    // acting on it is catastrophic: every "not the root directory" guard is evaluated on the
    // path the client *typed*, then this resolved path is substituted for it — so "DELETE /self"
    // passes a guard about "/self" and then removes the whole share. Refused here, in the
    // resolver, so a destructive call site added later cannot forget it. Asking for the root
    // *directly* is still allowed — that is the client naming the root, not a link quietly
    // landing on it.
    BOOL const askedForRoot = (normalizedPath.length == 0) || [normalizedPath isEqualToString:@"/"];

    if ((resolvedRelativePath.length == 0) && !askedForRoot) {
        return nil;
    }

    if (outHidden && !allowHiddenItems) {
        for (NSString *component in [normalizedPath pathComponents]) {
            if (WSKNameIsHidden(component)) {
                *outHidden = YES;
                return resolvedPath;
            }
        }

        for (NSString *component in [resolvedRelativePath pathComponents]) {
            if (WSKNameIsHidden(component)) {
                *outHidden = YES;
                return resolvedPath;
            }
        }
    }

    return resolvedPath;
}

NSString *WSKResolveNamedEntryWithinDirectory(NSString *path, NSString *directory, NSString *__autoreleasing *outRelativePath) {
    if (outRelativePath) {
        *outRelativePath = nil;
    }

    NSString *const leaf = [path lastPathComponent];
    NSString *const parent = [path stringByDeletingLastPathComponent];

    // No final component to preserve — "/" and the directory itself. Every destructive verb
    // refuses the root separately, so returning nil here is the same answer by a shorter route.
    if ((leaf.length == 0) || [leaf isEqualToString:@"/"] || (parent.length == 0)) {
        return nil;
    }

    NSString *const resolvedParent = _RealPath(parent);
    NSString *const resolvedDirectory = _RealPath(directory);

    if ((resolvedParent == nil) || (resolvedDirectory == nil)) {
        return nil;  // Fail closed rather than acting on a path we could not verify.
    }

    if (![resolvedParent isEqualToString:resolvedDirectory] && !WSKPathIsInsideDirectory(resolvedParent, resolvedDirectory)) {
        return nil;
    }

    NSString *const namedPath = [resolvedParent stringByAppendingPathComponent:leaf];

    if (outRelativePath) {
        NSString *const parentRelative = [resolvedParent isEqualToString:resolvedDirectory]
                                             ? @""
                                             : [resolvedParent substringFromIndex:(resolvedDirectory.length + ([resolvedDirectory hasSuffix:@"/"] ? 0 : 1))];
        *outRelativePath = (parentRelative.length == 0) ? leaf : [parentRelative stringByAppendingPathComponent:leaf];
    }

    return namedPath;
}

NSString *WSKResolvedPathRelativeToDirectory(NSString *path, NSString *directory) {
    NSString *const resolvedPath = _RealPath(path);
    // Resolve the directory too: /var is itself a symlink to /private/var on Apple
    // platforms, so a resolved path compared against an unresolved root never matches.
    NSString *const resolvedDirectory = _RealPath(directory);

    if ((resolvedPath == nil) || (resolvedDirectory == nil)) {
        return nil;  // Fail closed rather than serving a path we could not verify.
    }

    if ([resolvedPath isEqualToString:resolvedDirectory]) {
        return @"";  // The root itself, which is inside itself but has no relative part.
    }

    if (!WSKPathIsInsideDirectory(resolvedPath, resolvedDirectory)) {
        return nil;
    }

    // Relative to the *resolved* root, which is the whole point: the root itself may sit under
    // a dot-directory — NSTemporaryDirectory() under a sandboxed app routinely does — and
    // testing the absolute resolved path for hidden components would then refuse every file
    // it serves.
    return [resolvedPath substringFromIndex:(resolvedDirectory.length + ([resolvedDirectory hasSuffix:@"/"] ? 0 : 1))];
}

BOOL WSKResolvedPathIsWithinDirectory(NSString *path, NSString *directory) {
    return (WSKResolvedPathRelativeToDirectory(path, directory) != nil);
}

BOOL WSKResolvedPathHasHiddenComponent(NSString *path, NSString *directory) {
    NSString *const relativePath = WSKResolvedPathRelativeToDirectory(path, directory);

    if (relativePath == nil) {
        // Outside the root, or unresolvable. Containment is a separate check and reports that
        // separately; answering YES here would mislabel an escape as a hidden item, so say no
        // and let containment refuse it.
        return NO;
    }

    // Resolved, so this catches what a textual test on the request path cannot: a symlink whose
    // own name carries no dot but whose target lives inside a dot-directory. Both tests are
    // needed — this one alone would miss nothing here, but it costs a realpath, so callers keep
    // their cheap textual walk in front of it.
    for (NSString *component in [relativePath pathComponents]) {
        if (WSKNameIsHidden(component)) {
            return YES;
        }
    }

    return NO;
}

// Immutable or append-only defeats unlink(2) whatever the permissions say; an unreadable directory
// cannot be walked and an unwritable one cannot have its children removed. Checked with lstat so a
// symlink is judged as the entry it is — removing one never touches its target.
static BOOL _ItemIsRemovable(NSString *path) {
    struct stat info;

    if (lstat([path fileSystemRepresentation], &info) != 0) {
        return YES;  // Gone already, or unstattable; the removal will agree either way.
    }

    if (info.st_flags & (UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)) {
        return NO;
    }

    if ((info.st_mode & S_IFMT) == S_IFDIR) {
        // A directory's own write permission is only needed to unlink its CHILDREN. Removing the
        // directory itself is rmdir(2), which needs write permission on its PARENT — so an EMPTY
        // directory is removable whatever its own mode says. Requiring W_OK unconditionally makes
        // a 0555 directory render its ancestry permanently undeletable, and unzip and `ditto -x`
        // both preserve 0555, so that arrives through ordinary archive extraction.
        //
        // A directory that cannot be listed at all is refused: its children cannot be unlinked,
        // and whether it has any cannot be established.
        if (access([path fileSystemRepresentation], R_OK | X_OK) != 0) {
            return NO;
        }

        NSArray<NSString *> *const contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];

        if (contents.count == 0) {
            return YES;
        }

        return access([path fileSystemRepresentation], W_OK) == 0;
    }

    return YES;
}

NSString *WSKFirstUnremovableItemAtPath(NSString *absolutePath) {
    if (!_ItemIsRemovable(absolutePath)) {
        return [absolutePath lastPathComponent];
    }

    NSDirectoryEnumerator<NSString *> *const enumerator = [[NSFileManager defaultManager] enumeratorAtPath:absolutePath];

    for (NSString *subpath in enumerator) {
        if (!_ItemIsRemovable([absolutePath stringByAppendingPathComponent:subpath])) {
            return subpath;
        }
    }

    return nil;
}

// Removes an item — a file, a symlink, or a whole collection — as ONE observable event, answering
// with a POSIX errno rather than a Foundation error. Two defects share this primitive.
//
// PARTIAL DESTRUCTION. -[NSFileManager removeItemAtPath:] deletes as it WALKS, and
// WSKFirstUnremovableItemAtPath can only vet a SNAPSHOT: a member another client creates after
// that walk, into a directory the removal has already emptied, makes rmdir(2) answer ENOTEMPTY,
// and the removal abandons the tree keeping everything it has already destroyed. Measured on the
// wire: a PUT into an 800-member collection ~45 ms into its DELETE left 161 members and answered
// 500 — with Foundation reporting that ENOTEMPTY as NSFileWriteNoPermissionError ("you don't have
// permission to access it"), a diagnostic that sends an operator to audit file modes. Both servers
// shared the walk, so both shared the window. A snapshot cannot close a window against a
// concurrent writer; a rename can. Moving the tree to a hidden sibling first makes the resource
// vanish from the namespace in a single syscall, and after it no path this server serves leads
// into the tree — so the removal that follows cannot be raced at all.
//
// exFAT AND NFC. -removeItemAtPath: answers NSFileNoSuchFileError on exFAT for an NFC-spelled name
// that lstat(2) and unlink(2) both resolve, so a file created with a decomposable name was listed,
// readable, and undeletable through the spelling most web clients normalise to. Both primitives
// used below are POSIX and resolve it; the collection path renames by the client's spelling and
// only then removes, by a name this function chose.
//
// The rename is within the SAME parent directory, so it cannot fail EXDEV and needs exactly the
// permissions the removal itself needs. If the rename fails nothing has been touched. If the
// removal that follows fails, the resource is nonetheless gone from every path the server serves —
// the client is told the truth — and what remains is a dot-named directory the callers' listings
// already hide. That residue is the one thing this trades for atomicity; it needs the removal to
// fail after a rename succeeded, which no client can now cause.
BOOL WSKRemoveItemAtPath(NSString *absolutePath, int *outErrno) {
    const char *const path = [absolutePath fileSystemRepresentation];
    struct stat info;

    if (lstat(path, &info) != 0) {  // lstat, not stat: a symlink is an alias, and DELETE removes the alias
        if (outErrno) {
            *outErrno = errno;
        }

        return NO;
    }

    if (!S_ISDIR(info.st_mode)) {
        if (unlink(path) != 0) {
            if (outErrno) {
                *outErrno = errno;
            }

            return NO;
        }

        return YES;
    }

    NSString *const parent = [absolutePath stringByDeletingLastPathComponent];
    NSString *const name = [@".wsk-delete-" stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]];
    NSString *const aside = [parent stringByAppendingPathComponent:name];

    if (rename(path, [aside fileSystemRepresentation]) != 0) {
        if (outErrno) {
            *outErrno = errno;
        }

        return NO;  // Nothing has been touched.
    }

    NSError *removalError = nil;

    if (![[NSFileManager defaultManager] removeItemAtPath:aside error:&removalError]) {
        // Unreachable through the server now, so this cannot be a race; report the residue rather
        // than telling the client its DELETE failed when the resource is gone.
        WSK_LOG_ERROR(@"Removed \"%@\" from the share but could not delete its contents at \"%@\": %@", absolutePath, aside, removalError);
    }

    return YES;
}

// What a failed removal means to the CLIENT. Losing a race is not a server fault: a resource
// another client deleted first answered 500, which blames the server and invites a retry that can
// never succeed. Kept separate from WSKServerErrorStatusCodeForError, which is a server-error
// mapper by contract — widening that one into a client/server mapper is its own decision (see the
// ENAMETOOLONG item in the record).
NSInteger WSKStatusCodeForRemovalErrno(int failure) {
    switch (failure) {
    case ENOENT:
    case ENOTDIR:  // A path component stopped being a directory: the resource named is not there
        return kWSKHTTPStatusCode_NotFound;
    case EACCES:
    case EPERM:
    case EROFS:
        return kWSKHTTPStatusCode_Forbidden;
    case ENOTEMPTY:
    case EEXIST:
    case EBUSY:
        return kWSKHTTPStatusCode_Conflict;  // Retryable, and not the server's doing
    default:
        return kWSKHTTPStatusCode_InternalServerError;
    }
}
