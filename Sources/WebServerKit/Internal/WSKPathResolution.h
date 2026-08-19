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

#pragma mark - Path resolution internals

// These were declared in the PUBLIC WSKFunctions.h and are not used outside WSKFunctions.m — with
// one exception: WSKResolvedPathIsWithinDirectory has eleven assertions in Framework/Tests.m, which
// is why these move here rather than becoming static. Declaring an internal helper publicly binds
// the library to a contract nobody asked for, and these three have security-shaped signatures that
// invite a host app to build its own containment check out of them — the exact two-observation
// pattern WSKResolveWithinDirectory() exists to replace.

/**
 *  Returns YES if `path`, with all symlinks resolved, is `directory` itself or a
 *  location inside it. Resolves intermediate path components, and works for a path
 *  that does not exist yet (e.g. an upload destination) by resolving its parent.
 *
 *  Symlinks are invisible to the textual checks: WSKNormalizePath() strips
 *  ".." before any file is touched, and WSKPathIsInsideDirectory() compares
 *  path text, but lstat(), open() and NSFileManager all follow symlinks found in
 *  intermediate components. A symlink placed inside the served directory by some other
 *  means — another app, a restored backup, a synced volume — could therefore be
 *  traversed out of it. A symlink whose target stays inside the directory still
 *  resolves inside and remains usable.
 *
 *  Returns NO if either path cannot be resolved, so callers fail closed.
 */
BOOL WSKResolvedPathIsWithinDirectory(NSString *path, NSString *directory);

NSString *_Nullable WSKResolvedPathRelativeToDirectory(NSString *path, NSString *directory);

/**
 *  Returns YES if `path`, once symlinks are resolved, lies under a component starting with "."
 *  relative to `directory`.
 *
 *  A textual test on the path a client sent cannot see this: a symlink named `pub` pointing at
 *  `.git` yields the request path "/pub/config", which carries no dot, while containment passes
 *  too because the target is inside the served root. Both servers' hidden-item rules were
 *  therefore satisfied by a path whose bytes live inside a dot-directory.
 *
 *  Returns NO for a path that does not resolve inside `directory` at all — that is containment's
 *  business, and reporting it as "hidden" here would mislabel an escape attempt.
 */
BOOL WSKResolvedPathHasHiddenComponent(NSString *path, NSString *directory);

#pragma mark - Header-field and host-name internals

// Also formerly public. No caller outside the core target and no plausible host-app use: these are
// the rules the request parser and the response serializer BOTH have to spell the same way, which
// is why they are shared at all. WSKResolveWithinDirectory stays public for now despite belonging
// here, because three public doc comments name it as the resolve-once alternative — it moves with
// the rest of the resolver cluster so those references never point at a private symbol.

/**
 *  Is this byte legal in an HTTP field-name or method? RFC 9112 §5: field-name = 1*tchar.
 *
 *  Shared so the request parser and the response header setter cannot drift. A second
 *  implementation of this rule beside the live one is the trap this codebase keeps falling into.
 */
BOOL WSKIsHeaderTokenCharacter(unsigned char character);

/**
 *  Does this string consist only of tchar, with at least one character? The whole field-name rule,
 *  in one place.
 */
BOOL WSKIsHeaderTokenString(NSString *_Nullable string);

/**
 *  Strips one trailing DNS root-label dot. "name.local." and "name.local" are the same host.
 *
 *  Shared because the two sides of the Host allow-list disagreed: the CHECK side stripped it from
 *  the incoming header while the CONFIG side did not strip it from a WSKOption_AllowedHostNames
 *  entry, so an entry written as a fully-qualified name — which is how DNS writes one — matched
 *  nothing at all and every request answered 421.
 */
NSString *WSKHostNameWithoutRootLabel(NSString *host);

/**
 *  Splits an authority ("name", "name:8080", "[::1]:8080") into its lowercased, root-label-stripped
 *  host name and its port text. Returns NO for a malformed bracketed form — an unclosed `[`, or
 *  junk between `]` and the port — in which case no out-param is written.
 *
 *  One home, shared by the Host allow-list in `WSKConnection` and WebDAV's `Destination` check.
 *  The two ask the same question of the same grammar and differ only in the status they refuse
 *  with (421/400 versus 502), so a second parser here would be this codebase's signature defect.
 *
 *  NOTE the port is returned unvalidated: whether digits are required, and whether the port
 *  participates in the comparison at all, is the caller's ruling. It is deliberately NOT compared
 *  by either current caller — a port-translating hop is the priority deployment.
 */
BOOL WSKSplitAuthority(NSString *authority, NSString *_Nullable __autoreleasing *_Nullable outName, NSString *_Nullable __autoreleasing *_Nullable outPort, BOOL *_Nullable outBracketed);

/**
 *  Returns YES when a `Transfer-Encoding` header names a transfer coding this server does not
 *  implement at all — the case RFC 9112 §6.1 assigns 501 rather than the 400 owed to a malformed
 *  APPLICATION of an implemented coding ("chunked, chunked", Content-Length alongside chunked).
 *
 *  Shares its tokenizer with the framing decision in WSKRequest's initializer, which has already
 *  collapsed both cases into a nil request by the time the connection writes the refusal.
 */
BOOL WSKTransferEncodingIsUnsupported(NSString *header);

#pragma mark - Path, validator and vetting internals

// The audit-shaped half of what used to be WSKFunctions.h. These carry contracts that changed
// repeatedly through the audit programme — WSKServableFileTypeAtPath gained two parameters, the
// resolvers were merged from four copies, the allow-list predicate learned a second name — and
// every one of those was a source break for anyone who had bound to them. They were only public
// because the sibling targets could not see this header; they can now.
//
// Both reasons the manifest gave for that not being possible were MEASURED and did not reproduce:
// a Swift consumer builds with WSKPrivate.h in the symlink farm, and a sibling reaching Core/ by a
// second search path does not hit "duplicate interface definition". Both may have been true when
// written; neither constrains the layout now.

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
 *  Splits `path` at every literal "/" — the separators the FILESYSTEM sees.
 *
 *  -componentsSeparatedByString:@"/" must not be used for this, which is why the rule has a home
 *  of its own. That method honours composed character sequences, so a combining mark immediately
 *  after a "/" makes the slash part of a grapheme cluster and the split silently skips it:
 *  "../" + U+030C + "/d" came back as two components with the ".." still glued to the first, and
 *  WSKNormalizePath therefore left the ".." in place. The same string's -pathComponents DOES
 *  split there, so one string was being cut two different ways by two APIs that read alike. A
 *  client can put such a byte on the wire, because request paths are percent-decoded.
 *
 *  -pathComponents is not the fix: it collapses "//", prepends "/" for an absolute path and
 *  keeps a trailing "/" as a component. Splitting on a character SET was measured to match
 *  -componentsSeparatedByString: byte-for-byte on every input WITHOUT a combining mark, so it
 *  changes only the case that was wrong.
 */
NSArray<NSString *> *WSKPathComponentsSeparatedBySlash(NSString *_Nullable path);

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

NS_ASSUME_NONNULL_END
