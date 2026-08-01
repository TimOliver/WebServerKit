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

#if __has_include(<WebServerKit/WSKHTTPStatusCodes.h>)
#import <WebServerKit/WSKHTTPStatusCodes.h>
#else
#import "WSKHTTPStatusCodes.h"
#endif

#include <sys/stat.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/**
 *  Converts a file extension to the corresponding MIME type.
 *  If there is no match, "application/octet-stream" is returned.
 *
 *  Overrides allow to customize the built-in mapping from extensions to MIME
 *  types. Keys of the dictionary must be lowercased file extensions without
 *  the period, and the values must be the corresponding MIME types.
 */
NSString *WSKGetMimeTypeForExtension(NSString *extension, NSDictionary<NSString *, NSString *> *_Nullable overrides);

/**
 *  Add percent-escapes to a string so it can be used in a URL.
 *  The legal characters ":@/?&=+" are also escaped to ensure compatibility
 *  with URL encoded forms and URL queries.
 */
NSString *_Nullable WSKEscapeURLString(NSString *string);

/**
 *  Unescapes a URL percent-encoded string.
 */
NSString *_Nullable WSKUnescapeURLString(NSString *string);

/**
 *  Extracts the unescaped names and values from an
 *  "application/x-www-form-urlencoded" form.
 *  http://www.w3.org/TR/html401/interact/forms.html#h-17.13.4.1
 */
NSDictionary<NSString *, NSString *> *WSKParseURLEncodedForm(NSString *form);

/**
 *  On OS X, returns the IPv4 or IPv6 address as a string of the primary
 *  connected service or nil if not available.
 *
 *  On iOS, returns the IPv4 or IPv6 address as a string of the WiFi
 *  interface if connected or nil otherwise.
 */
NSString *_Nullable WSKGetPrimaryIPAddress(BOOL useIPv6);

/**
 *  Converts a date into a string using RFC822 formatting.
 *  https://tools.ietf.org/html/rfc822#section-5
 *  https://tools.ietf.org/html/rfc1123#section-5.2.14
 */
NSString *WSKFormatRFC822(NSDate *date);

/**
 *  Converts a RFC822 formatted string into a date.
 *  https://tools.ietf.org/html/rfc822#section-5
 *  https://tools.ietf.org/html/rfc1123#section-5.2.14
 *
 *  @warning Timezones other than GMT are not supported by this function.
 */
NSDate *_Nullable WSKParseRFC822(NSString *string);

/**
 *  Converts a date into a string using IOS 8601 formatting.
 *  http://tools.ietf.org/html/rfc3339#section-5.6
 */
NSString *WSKFormatISO8601(NSDate *date);

/**
 *  Converts a ISO 8601 formatted string into a date.
 *  http://tools.ietf.org/html/rfc3339#section-5.6
 *
 *  @warning Only "calendar" variant is supported at this time and timezones
 *  other than GMT are not supported either.
 */
NSDate *_Nullable WSKParseISO8601(NSString *string);

/**
 *  Returns YES if `path` contains an embedded NUL.
 *
 *  WSKNormalizePath() truncates at a NUL, because the filesystem's C-string APIs do and the
 *  mismatch is exploitable — "secret.dat\0.png" otherwise passes an extension allow-list and
 *  then opens "secret.dat". But truncating means the server goes on to honour a request the
 *  client did not make: "/Keep\0/nonexistent" named nothing, and deleted "/Keep".
 *
 *  So a client-supplied path carrying a NUL should be REFUSED at the point it arrives, not
 *  quietly rewritten. Normalization keeps truncating as a second line for any path that reaches
 *  it by another route.
 */
BOOL WSKPathContainsNULByte(NSString *_Nullable path);




/**
 *  Does a single name satisfy an extension allow-list? A nil list means "no restriction".
 *
 *  The rule itself, in one place: both servers' -_checkFileExtension: delegate here.
 */
BOOL WSKNamePassesExtensionAllowList(NSString *name, NSArray<NSString *> *_Nullable allowedExtensions);

/**
 *  Does an ENTRY satisfy the allow-list, judged by BOTH names it presents?
 *
 *  A symlink has two: the name the client used, and the name the bytes actually live under. Those
 *  were judged inconsistently — listings vetted the alias, access vetted the resolved target — so
 *  with a list of ["txt"], "alias.txt -> real.bin" was advertised and then refused 403, while
 *  "alias.bin -> real.txt" was hidden and then served 200.
 *
 *  BOTH must pass. That is the fail-closed reading and the owner's decision: judging the alias
 *  alone would make "alias.txt -> id_rsa" servable, which turns the allow-list into decoration for
 *  reads; judging the target alone contradicts the "symlinks are aliases" semantics a destructive
 *  verb already follows. Pass nil for resolvedName when there is no second name (a regular file, or
 *  a caller with only one to offer), which is exactly the single-name rule.
 */
BOOL WSKEntryPassesExtensionAllowList(NSString *namedName, NSString *_Nullable resolvedName, NSArray<NSString *> *_Nullable allowedExtensions);

/**
 *  Resolves a client-supplied relative path to an absolute one inside `directory`, FOLLOWING a
 *  final symlink, or nil if it may not be acted on.
 *
 *  Refuses a NUL-bearing path, and refuses a path that resolves to the share root itself unless the
 *  client named the root directly. `outHidden` reports whether the path is hidden by either the
 *  spelling the client used or the one it resolved to; it is only computed when
 *  `allowHiddenItems` is NO.
 *
 *  Both refusals live HERE, at the one point every path-taking verb passes through, so a verb added
 *  later cannot forget them.
 */
NSString *_Nullable WSKResolvedPathForRelativePath(NSString *relativePath, NSString *directory, BOOL allowHiddenItems, BOOL *_Nullable outHidden);

/**
 *  As above, but resolves the PARENT and appends the raw leaf, so a final symlink is preserved
 *  rather than followed — the entry the client named, which is what a destructive verb acts on.
 *  Naming the root itself is refused: there is no final component to preserve.
 */
NSString *_Nullable WSKNamedEntryPathForRelativePath(NSString *relativePath, NSString *directory, BOOL allowHiddenItems, BOOL *_Nullable outHidden);

/**
 *  The first subtree member a destructive verb must NOT be allowed to destroy, or nil if the whole
 *  tree is safe to remove.
 *
 *  A recursive DELETE, or an overwrite, must refuse anything a DIRECT request would refuse — or the
 *  same request means two different things depending on how it is spelled. That class has recurred
 *  FOUR times in this project (eighth, tenth, thirteenth and fifteenth passes), most recently
 *  measured at 60/60 destroyed, so the walk lives in one place now rather than once per server.
 *
 *  Two judgement calls are baked in, both load-bearing. Dot-names and their descendants are skipped
 *  whatever `allowHiddenItems` says: a ".DS_Store" sits in every macOS folder and its empty
 *  pathExtension is in no allow-list, so vetting them would make ordinary directories permanently
 *  undeletable. And an extensionless file IS vetted, because a direct DELETE of it is already
 *  refused.
 */
NSString *_Nullable WSKFirstUnvettableItemAtPath(NSString *absolutePath, BOOL isDirectory, NSArray<NSString *> *_Nullable allowedExtensions);

/**
 *  Do two paths name the same file on disk?
 *
 *  Compares file resource identifiers (inode + volume), so it also catches the case-variant pair
 *  "File.txt"/"file.txt" that is ONE file on a case-insensitive volume. That is the whole of the
 *  protection against a self-move: an unconditional "remove the destination, then move" with
 *  `Overwrite: T` deleted the only copy of the file when the two paths resolved to it.
 */
BOOL WSKPathsNameTheSameFile(NSString *path1, NSString *path2);

/**
 *  Maps a filesystem NSError onto the server-error status that describes it honestly.
 *
 *  RFC 4918 §11.5: 507 Insufficient Storage means the method could not be performed because
 *  the server cannot store the representation. A full volume or an exceeded quota is exactly
 *  that, and answering 500 invites the client to retry an operation that cannot succeed until
 *  something is freed. Everything else stays 500.
 */
WSKServerErrorHTTPStatusCode WSKServerErrorStatusCodeForError(NSError *_Nullable error);

/**
 *  Removes "//", "/./" and "/../" components from path as well as any trailing slash.
 */
NSString *WSKNormalizePath(NSString *path);

/**
 *  Returns YES only if `path` resolves to a location strictly inside `directory`
 *  (i.e. neither the directory itself nor outside it). Used to keep destructive
 *  file operations from ever targeting the served root directory, e.g. when a
 *  client-supplied relative path collapses to the empty string.
 *
 *  @warning This is a purely textual comparison and does not resolve symlinks, so it is NOT a
 *  containment check on its own. For a path that came from a client, use
 *  WSKResolveWithinDirectory() — it resolves once and reports containment from that single
 *  observation, which is what the two-observation pattern this warning used to recommend got
 *  wrong.
 */
BOOL WSKPathIsInsideDirectory(NSString *path, NSString *directory);


/**
 *  Resolves `path` ONCE and reports everything a caller needs from that single observation:
 *  returns the fully resolved absolute location if it is inside `directory` (or is `directory`
 *  itself), nil otherwise, and writes the same location expressed relative to the resolved
 *  `directory` into `outRelativePath` when that is non-NULL.
 *
 *  Prefer this to calling the two predicates below in sequence. Each of those performs its own
 *  realpath(3), so a caller that checks containment with one and hiddenness with the other is
 *  acting on two observations of a filesystem that need not agree — and then usually operates on
 *  a *third*, the unresolved path the client sent. A symlink retargeted between those steps was
 *  measured serving content from outside the served root in 24% of requests.
 *
 *  Act on the returned path, not on the caller's own: a resolved path contains no symlinks, so
 *  retargeting one cannot redirect the operation that follows. This narrows the window rather
 *  than closing it — a real directory renamed between resolution and use would still slip
 *  through, and closing that needs an openat(2) component walk or O_NOFOLLOW_ANY, which would
 *  also refuse the benign intermediate symlinks that work today.
 */
NSString *_Nullable WSKResolveWithinDirectory(NSString *path, NSString *directory, NSString *_Nullable __autoreleasing *_Nullable outRelativePath);

/**
 *  Like WSKResolveWithinDirectory(), but returns the entry the client NAMED rather than what that
 *  entry points at: the parent is resolved, and the final component is appended raw.
 *
 *  Read paths want the target — `GET /latest/app.ipa` should follow the link, and does. Verbs that
 *  REMOVE or RELOCATE an entry want the entry, because that is what `rm`, `mv` and `cp -P` do and
 *  what a user means: `DELETE /latest` used to remove the multi-hundred-megabyte build directory
 *  the link pointed at and leave the dangling link behind, answering 204. No shell tool behaves
 *  that way, and the residue was then invisible to every listing and removable by nothing.
 *
 *  The PARENT is resolved, and the containment and hidden-item verdicts are both derived from that
 *  one observation, exactly as WSKResolveWithinDirectory() does for the full path. That matters:
 *  resolving once for the verdict and again for the path to act on is the two-observations shape
 *  the eighth pass closed and this file names as the form that will recur. It also keeps the
 *  eighth pass's protection intact — `PUT /link/x` where `link` retargets outside is still refused,
 *  because the escape is in the parent and the parent is still resolved.
 *
 *  Unlinking or renaming a symlink never touches its target, so a link pointing outside the share
 *  is safe to remove: the entry itself lives inside. Returns nil when the parent does not resolve
 *  inside `directory`, or when `path` names the directory itself (which has no final component to
 *  keep, and which every destructive verb must refuse anyway).
 */
NSString *_Nullable WSKResolveNamedEntryWithinDirectory(NSString *path, NSString *directory, NSString *_Nullable __autoreleasing *_Nullable outRelativePath);

/**
 *  The NSFileType an enumeration should CLASSIFY `path` as, which for a symlink is the type of what
 *  it points at — or nil when nothing servable is there.
 *
 *  `-attributesOfItemAtPath:` does not follow links, so a symlink is neither NSFileTypeRegular nor
 *  NSFileTypeDirectory and fell out of all three listings while the same servers happily served
 *  through it. That disagreement is the one this project has now fixed twice in the opposite
 *  direction, and through a real mounted client it is data loss rather than cosmetics: `mv` returns
 *  0 having copied only what the listing reported, then deletes the source, so the entries it never
 *  saw are gone.
 *
 *  A link is only classified when its target resolves INSIDE `directory` — otherwise it would be
 *  advertised and then refused on access, which is the same disagreement with the sign flipped. A
 *  dangling link resolves to nothing and is likewise not classified.
 */
NSString *_Nullable WSKServableFileTypeAtPath(NSString *path, NSString *directory, BOOL allowHiddenItems, NSString *_Nullable __autoreleasing *_Nullable outResolvedName);



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

/**
 *  Returns the first item at or under `absolutePath` that could not be removed, expressed relative
 *  to `absolutePath` (or `absolutePath`'s own last component if it is the blocker), or nil when the
 *  whole tree can go.
 *
 *  `-[NSFileManager removeItemAtPath:]` walks a tree deleting as it goes and stops at the first
 *  member it cannot unlink — leaving everything it already removed removed, and reporting only a
 *  failure. So a collection holding one locked file (`chflags uchg`, which is exactly what Finder's
 *  "Locked" checkbox sets) or one unwritable subdirectory answered 500, or 403 through an overwrite,
 *  with most of its contents destroyed. Measured: 21 files in, 9 left, status 500, and on the
 *  MOVE/COPY surface the source was left in place too — a failed operation AND a gutted destination.
 *
 *  Asking first turns that into an untouched tree and a refusal that names the offending item, which
 *  is what this library's "refuse clearly rather than half-succeed" priority requires. RFC 4918
 *  §9.6.1's 207 Multi-Status is the conformant alternative and is strictly worse here: it reports
 *  the damage rather than preventing it.
 *
 *  This cannot be folded into the extension-allow-list walk, tempting as that is: that walk returns
 *  immediately when no allow-list is configured, which is the default and where all of this is
 *  reachable. Removability has to be checked unconditionally.
 *
 *  Inherently advisory: flags and modes can change between this walk and the removal. Nothing in
 *  this library changes either, so that window needs a local process, and closing it would need a
 *  transactional filesystem.
 */
NSString *_Nullable WSKFirstUnremovableItemAtPath(NSString *absolutePath);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
