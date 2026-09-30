# WebServerKit

A fork of GCDWebServer with additional features for iOS/macOS web serving.

This is the CONDENSED institutional memory (condensed 2026-08-17 from the full 21-pass audit
record; a 22nd pass — spec conformance, 2026-09-02 — a 23rd — fresh-eyes, multi-core and packaging,
2026-09-02/03 — its re-verification of 2026-09-04, and a second fuzzing pass of 2026-09-05 are all
folded in place rather than appended; the unfixed remainder is grouped under "Still open at tip").
Lightly re-condensed 2026-09-05: entries closed during that week were collapsed to a line naming the
fix and the invariant that now carries it, KEEPING in each case the correction the original finding
needed — that is the part git history alone will not surface. No invariant, lesson, settled decision
or refutation was touched.
The complete record — every measurement, justification, and the pass-by-pass appendix — lives in
git history: `git show 09416c2:CLAUDE.md`, and the pre-re-condense text one commit before this one.
Consult it before re-auditing a subsystem or reversing anything under "Settled decisions".

**How to read this file.** "Core invariants" are rules the code currently upholds and that a change
must not break. "Settled decisions" are deliberate and must not be re-fixed. "Still open at tip" is
a backlog, and every entry there is stale until re-measured — roughly one in three evaporates, and
in the 2026-09-04 re-check none of eleven did. "Lessons" and "Recurring defect shapes" are about
METHOD, and have paid better than any individual finding: most defects here were found by a
technique from that list, and several were nearly missed by an oracle that could not fail.

## Build Commands

```bash
# Build Mac framework
xcodebuild -project WebServerKit.xcodeproj -scheme "WebServerKit (Mac)" -configuration Debug build

# Build iOS framework
xcodebuild -project WebServerKit.xcodeproj -scheme "WebServerKit (iOS)" -configuration Debug -destination 'generic/platform=iOS Simulator' build

# Build tvOS framework
xcodebuild -project WebServerKit.xcodeproj -scheme "WebServerKit (tvOS)" -configuration Debug -destination 'generic/platform=tvOS Simulator' build
```

## Project Structure

- `Sources/WebServerKit/` - Core web server implementation
- `Sources/WebServerKitUploader/` - File upload/download web interface
- `Sources/WebServerKitDAV/` - WebDAV server implementation
- `Examples/iOS/` - iOS example app
- `Examples/macOS/` - macOS example app
- `Framework/` - Framework configuration files

## Deployment shapes and priorities

- **Shape A (priority): long-lived vending.** Weeks-long uptime on localhost behind Tailscale
  Serve (TLS terminated upstream), vending multi-hundred-MB iOS builds. Depends on: zero
  accumulation (the aggregate in-memory budget is process-wide static state with NO reset —
  one leaked reservation permanently disables every in-memory endpoint; monitor
  `+[WSKWebServer reservedInMemoryByteCount]`), and Range/If-Range correctness (interrupted
  large downloads are a main path; a range served against a changed file splices two builds).
- **Shape B: ephemeral LAN sharing (iComics).** Start/stop correctness matters most.
- **Throughput is settled by measurement (2026-08-18, Release, localhost): ~920 MB/s single
  stream (300 MB in 0.34 s), ~1.2 s CPU per GB served (per-chunk verification included),
  200×50 KB thumbnail burst in 140 ms cold / 30 ms with keep-alive, 0 leaks.** The server
  cannot be the bottleneck behind Tailscale (WireGuard) or LAN Wi-Fi — do not spend on
  performance work. App-side note: keep-alive is 5× on many-small-file pages and defaults
  OFF; a thumbnail-page client should set `WSKOption_ConnectionKeepAliveTimeout` (bodiless
  GETs are exactly the class the anti-smuggling restriction permits).
- **Both:** refuse clearly rather than half-succeed; a refused or failed transaction leaves
  nothing behind (no staging files, temp files, held descriptors, or connection slots).
- **Threat model:** small trusted network. No rate limiting, no auth backoff, 128-connection
  cap. Plaintext transport is settled (TLS terminates upstream).
  **OWNER RULING 2026-09-05: this library will NEVER face the open internet — it is for local
  networks only, always.** That is a standing constraint, not a current state of affairs, and it
  is what decides trade-offs between refusing a suspicious client and serving a slow real one:
  serve the real one. The older "re-audit with an internet-facing lens before ever exposing
  publicly" line stands only as a description of what such an audit WOULD have to revisit — the
  response-phase stall allowance below is the first item on that list — not as an expected event.
- **Publish builds atomically** (`rename`/`mv`/`ditto` — never `cp` or `cat >` in place, which
  reuse the inode and feed the new bytes into in-flight downloads); per-chunk verification
  refuses a torn read but cannot make it whole. Avoid republishing while downloads are
  plausibly in flight — parallel-Range clients can splice client-side; no server fix exists.

## Deployment requirements

- Tailscale: set `WSKOption_AllowedHostNames` to the MagicDNS name; the built-in Host
  allow-list admits only localhost, IP literals, own hostname and `.local` (else 421). An
  entry without a port matches ANY port (needed behind port-translating hops); a request with
  no `Host` header at all is allowed.
- Startup hostname discovery must not resolve DNS: `NSProcessInfo.hostName` blocked a
  physical iPhone launch until the 19.96 s watchdog killed it (2026-09-30). Use bounded
  `gethostname` with explicit termination/UTF-8 checks. The current Bonjour service's
  resolved target is admitted asynchronously before success notification; iOS can advertise
  a different name from its kernel hostname. Publish immutable host sets under their short
  dedicated lock. Accept-time reads must NOT enter `_stateQueue`, because stop waits for
  accept handlers to finish. Connections retain their accepted snapshot; stale Bonjour
  callbacks cannot publish names for a replacement listener. Other canonical DNS aliases
  require explicit `AllowedHostNames` configuration.
- `WSKOption_ConnectionIdleTimeout` default 30 s; 0 disables — without it, 128 idle sockets
  is a permanent denial of service.
- Both connection timeout options must be finite and in 0...2147483647 seconds; a positive
  idle timeout must also represent at least one nanosecond. Invalid settings fail through
  `startWithOptions:error:` before listeners or saved configuration are created. Explicit zero
  stays supported, including idle zero with keep-alive enabled. The common upper bound leaves
  headroom when dispatch adds uptime and fits the Keep-Alive header's integer seconds.
  Verified 2026-09-16: three focused tests cover rejection before socket creation, configuration
  changes or start callbacks; the same instance can then start and serve with valid options.
  Both invalid-option tests fail on the previous source, while the zero/fraction/boundary control
  passes on both. Exact adjacent floating-point values pin the 1 ns floor and upper limit.
  `Run-Tests.sh` passes: 257 ASan tests, eight trace suites, Mac/iOS/tvOS Release builds and both
  Swift consumers. A separate live startup probe accepts all 11 invalid configurations before
  the fix and rejects all 11 afterwards. Fractional timeouts reclaim silent and kept-alive
  sockets, explicit idle zero leaves them open until the client closes, and the maximum
  keep-alive value is advertised correctly. Across those three controls, four concurrent workers
  complete 96 requests with the expected body; connections and reserved bytes return to zero at rest.
- `-preflightRequest:` overrides must decide on headers alone (the body doesn't exist yet).
- Handlers whose response IS a long-lived resource must check `-[WSKRequest isVirtualHEAD]`
  (a mapped HEAD's body is discarded unsent).
- Inside a `WSKMatchBlock` the request's addresses are nil.
- Hidden means where the bytes live: serving through dot-directories needs the explicit
  `allowHiddenItems:` variant; a symlink into a dot-directory won't resolve by default.
- `#` in filenames must be `%23` on the wire; a raw `#` anywhere answers 400 by design.
- Network volumes (smbfs/nfs/anything `fstatfs` can't classify) get the conservative 2 s
  `Last-Modified` seal — do not "optimize" to 1 s (FAT-over-SMB is indistinguishable from the
  server side; being wrong splices builds).
- Keep advertising DAV class 2 — Finder refuses to write otherwise; that is the sole reason
  the LOCK stub exists.
- Linking: UniformTypeIdentifiers HARD-linked (present at every deployment floor);
  CoreServices no longer linked at all; UIKit weak-linked iOS/tvOS only; `-lxml2 -lz`.
- SSE wire contract: `event: change` with JSON
  `{"type":"upload"|"delete"|"create"|"external","path":...}` or
  `{"type":"move","oldPath":...,"newPath":...}`; directory paths end `/`; 15 s heartbeats.
  **CORRECTION 2026-09-02: "directory paths end `/`" is aspirational, not what ships.** Only
  `/create` and the external coalesced producer append it; `/delete` broadcasts the relative path
  verbatim (though `isDirectory` is known at that point) and `/move` broadcasts both paths bare.
  Demonstrated by one resource, two spellings: `POST /create path=/Dir2` emits `"/Dir2/"` and
  deleting that same directory moments later emits `"/Dir2"`. Unfixed — `index.js` has no test
  harness, so a client-visible contract change needs a Chromium probe against both builds.
- iOS Files app: `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`; background
  serving via `WSKOption_AutomaticallySuspendInBackground: false` (~30 s).
- **tvOS is a THIRD deployment shape (Shape C), and three of its rules invert the iOS ones.**
  Intended use is a control surface — an Apple TV app driven by iPhones on the LAN — with document
  access as a secondary offer. Verified 2026-09-02 on an Apple TV 4K simulator (tvOS 26.4): the
  framework and example build warning-free, the uploader serves its page, `/list`, `/upload` and
  `/download`, and the server is reachable from the host.
  - **Storage: use `Library/Caches`, never Documents.** tvOS guarantees an app 500 KB of
    persistent storage (via `NSUserDefaults`) and nothing more; everything else "must be purgeable
    by the operating system" when the app is not running, and on real hardware Documents is not
    reliably writable at all. Caches IS writable, so a tvOS share lives there and accepts that its
    contents can vanish between launches. **The SIMULATOR hides all of this** — it inherits the
    host Mac's filesystem, so serving Documents works there perfectly; measured doing exactly that
    before the example was corrected. Design consequence: an Apple TV can VEND what was just
    pushed to it, or anything the app can re-fetch; it cannot KEEP a library, and the Shape A
    atomic-publish model presumes durable files tvOS does not offer. (The 500 KB figure is from a
    guide archived in 2017 and is the only number Apple has ever committed to — no current page
    restates or rescinds it. The qualitative rule is well corroborated; the number is not fresh.)
  - **Do NOT set `WSKOption_AutomaticallySuspendInBackground: false` on tvOS.** The iOS recipe
    above buys a ~30 s drain window; tvOS has no grace period worth draining into, and
    `BGContinuedProcessingTask` — the iOS 26 possibility noted under Long-lived surfaces — is
    explicitly `API_UNAVAILABLE(tvos)`. Worse, per TN2277 a suspended app that still holds a
    listening socket leaves the kernel ACCEPTING connections nothing will service, so clients hang
    instead of being refused. The default (YES) is correct here and was measured: backgrounding
    the tvOS app makes connections fail instantly (connect 0.0000 s), not hang.
  - **Local network privacy does not exist on tvOS** (TN3179's platform table; no Privacy entry in
    tvOS Settings), so advertising `_http._tcp` / `_webdav._tcp` from the Apple TV needs no keys
    and no permission. Two things follow. First, the general rule this establishes for the whole
    library: LISTENING and ACCEPTING never require the permission on any platform — only outbound
    connections and Bonjour do. Second, the exposure moves to the iPhone CLIENT that browses for
    the service: it needs `NSBonjourServices` AND `NSLocalNetworkUsageDescription`, and **must be
    tested on a real device, because the simulator does not enforce local network privacy** — so
    the Bonjour verification recorded below, being simulator-only, says nothing about it. Declare
    both keys in the tvOS Info.plist anyway: zero cost, and insurance if Apple ever enforces there.
  - Bonjour failures used to be LOG-ONLY. They now reach the optional
    `webServer:didFailBonjourRegistrationWithError:` delegate method, including setup,
    registration and resolution failures. HTTP remains available. The error preserves the
    underlying domain/code and identifies the phase; apps should distinguish configuration
    errors from permission denial rather than prescribing a permission change for every error.
    Delivery is main-thread, outside the state queue, at most once per listener start. Queued
    notifications from a stopped/restarted attempt are discarded; an immediate setup failure
    can arrive before `webServerDidStart:`. No automatic retry or advertisement withdrawal.
- **Finder Network-sidebar presence is a Bonjour type, not a feature**: advertise
  `_webdav._tcp` (+ TXT `path=/`) on a WSKWebDAVServer and NetFS lists the device;
  double-click mounts via mount_webdav. `_http._tcp` only reaches Safari's Bonjour menu.
  Measured live 2026-08-18 (simulator): advert named after the device, Digest 401-challenge /
  wrong-code-401 / right-code-207 matrix all correct with a per-session on-screen pairing code
  (6 chars, unambiguous alphabet — resists LAN-speed guessing without backoff). The example
  change was REVERTED pending a proper example-app refresh; the recipe is the three Bonjour
  options plus Digest accounts on a WSKWebDAVServer.
- **The browser (WSKWebUploader) and WebDAV (WSKWebDAVServer) are two servers on two ports by
  design, but this is an implementation detail the USER must never see.** They compose cleanly
  (uploader is GET/POST only; DAV owns the WebDAV verbs), so an app runs both behind ONE "WiFi
  Sharing" toggle: start/stop as a pair, both-or-nothing on failure, one shared config (folder +
  Digest pairing code). The user sees one browser URL (QR/AirDrop/text); Finder finds the DAV
  endpoint via Bonjour, its port carried invisibly in the SRV record. Do NOT merge them into a
  single-port server — that fuses two independently-hardened security surfaces for no user-visible
  gain.
- A symlinked share is supported for live updates; the one-stream-per-browser SSE relay needs
  Web Locks + BroadcastChannel. Without them (ordinary HTTP LAN origins), visible tabs poll
  every five seconds instead of holding per-tab streams.

## Core invariants

### Path resolution and containment

- **Resolve ONCE.** Two resolvers, one shared implementation: `WSKResolveWithinDirectory()`
  (every read, and writes to a location) and `WSKResolveNamedEntryWithinDirectory()`
  (resolves the parent, appends the raw leaf — the verbs acting on the entry the client
  NAMED: DELETE, and MOVE/COPY source + destination). Containment and hiddenness derive from
  that single observation; a second resolution anywhere reopens a measured symlink escape
  (files were written outside the share). The per-server three-line wrappers exist so no call
  site is missed — do not inline them away.
- **Symlinks are aliases** (owner decision): destructive verbs act on the named entry
  (`DELETE /latest` removes the link); reads still follow. Root destruction is impossible by
  construction — the pinning test asserts contents SURVIVE, not that the request refuses.
  That held only while the target EXISTED until 2026-09-02: DELETE asked
  `-fileExistsAtPath:` about the named entry, which FOLLOWS the final link, so a DANGLING alias
  answered 404 and stayed — and every write verb then refused the name because it did exist.
  The name was wedged, clearable only from the filesystem, and a dangling alias is the ordinary
  end state of the publish-by-symlink pattern (replace the build, the alias outlives it). Now
  `lstat`; `isDirectory` comes from the same observation, so a link is never a collection and
  `DELETE /dirlink` with `Depth: 0` removes the alias instead of answering 400 for a subtree it
  never touches. Recurring shape 8.
- **"Is this name hidden?" has ONE home, `WSKNameIsHidden`, and it reads the first character.**
  `-hasPrefix:@"."` is REPRESENTATION-dependent: for `"." + U+0301 + "x.txt"` an ordinary
  `__NSCFString` answers YES and the `NSPathStore2` that `-lastPathComponent` returns answers NO,
  on byte-identical UTF-16 (measured Darwin 25.6). `/upload` asked exactly that of exactly that
  string (`[file.fileName lastPathComponent]`), so a share refusing hidden items accepted a real
  dot-file — invisible to its own listing, therefore undeletable through its own UI. All twelve
  sites swept 2026-09-02; only `/upload` was reachable (directory enumeration hands out
  `__NSCFString`), the rest are drift insurance. NINTH combining-mark recurrence, and the first
  where the blind API was a PREFIX TEST rather than a search — assume any `-hasPrefix:` on a
  path or name shares it.
- **Listings advertise iff served**: one classifier, `WSKServableFileTypeAtPath()`, feeds all
  three enumerators (PROPFIND, uploader `/list`, base-path index) so they cannot drift. It also
  hands BACK the path it observed (`outResolvedPath`, added 2026-09-02) so a caller can derive
  the metadata it publishes from the SAME observation that classified the entry — see the
  PROPFIND entry under WebDAV for what a second observation cost.
  Since 2026-09-28 the helper enforces containment for ordinary entries too, including a
  symlinked parent. One resolution supplies containment, share-relative hidden checks and the
  path classified with `lstat`; refused or unsupported entries clear both outputs. Successful
  entries return a resolved path and leaf name, including ordinary files. Benign aliases,
  symlinked shares and both-name extension checks remain supported. This closes a latent
  contract gap: current enumerators already passed resolved parents. Three direct regressions
  fail on the old helper (28 assertions), and all 29 path ASan tests pass after the fix.
  A bounded warm-file comparison (eight alternating passes, both outputs requested) measured
  median thread CPU for 5,000 ordinary entries at 314 ms before and 114 ms after. This checks
  classifier cost only, not end-to-end server throughput or other filesystems.
- The extension allow-list judges BOTH names a symlink presents — alias AND resolved target
  (`WSKEntryPassesExtensionAllowList`, one home).
- The uploader's mutating endpoints hold `_fileOperationLock` (four sites; any new
  resolve-then-act endpoint must take it too).
- Recursive-destroy vetting has one home, `WSKFirstUnvettableItemAtPath` (dot-names and their
  descendants skipped; `-skipDescendants` only for dot-named DIRECTORIES). It returns nil
  when no allow-list is set, so nothing that must run by default may live inside it. The
  removability walk `WSKFirstUnremovableItemAtPath` is UNCONDITIONAL and asks before anything
  is touched (`removeItemAtPath:` deletes as it walks and keeps what it already destroyed).
- **Destroying anything goes through `WSKRemoveItemAtPath`, which renames a collection aside
  BEFORE removing it (2026-09-03).** The removability walk above vets a SNAPSHOT, and a snapshot
  cannot close a window against a second client: a member created after the walk, into a directory
  `removeItemAtPath:` has already emptied, makes `rmdir` answer ENOTEMPTY, and the removal abandons
  the tree keeping everything it already destroyed — the exact outcome the walk exists to prevent.
  Measured on the wire at tip: a PUT ~45 ms into the DELETE of an 800-member collection left 161
  members and answered **500**, with Foundation reporting that ENOTEMPTY as
  `NSFileWriteNoPermissionError` ("you don't have permission to access it"), a diagnostic that
  sends an operator to audit file modes. Both servers shared the walk, so both shared the window,
  and the uploader's `_fileOperationLock` cannot help because the racing writer is typically the
  DAV server on the SAME folder — the two-server composition this record recommends. Recurring
  shapes 6 and 7, inside the guard built to prevent exactly this.
  A `rename(2)` into a hidden sibling makes the resource leave the namespace in one syscall; after
  it no path the server serves leads into the tree, so the removal that follows cannot be raced.
  Keep calling the vetting walk FIRST — it is what refuses a tree this server must not destroy at
  all, before anything moves. Three sites share it: DAV DELETE, DAV COPY/MOVE overwrite, uploader
  `/delete`. The one thing it trades: if the removal fails AFTER the rename, the client is told the
  truth (the resource is gone) and a dot-named remainder is logged rather than left silently — that
  needs a failure no client can now cause.
- **Losing a race is not a server fault.** A DELETE whose target another client removed first
  answered 500 — 19 of 48 concurrent DELETEs in the pinning test — which blames the server and
  invites a retry that can never succeed. `WSKStatusCodeForRemovalErrno` maps ENOENT/ENOTDIR to
  404, EACCES/EPERM/EROFS to 403, ENOTEMPTY/EEXIST/EBUSY to 409, everything else to 500. Kept
  SEPARATE from `WSKServerErrorStatusCodeForError`, which is a server-error mapper by contract —
  widening that one into a client/server mapper is still its own decision (the ENAMETOOLONG item).
- **`_RealPath` is the most security-critical function in the library; any edit needs its own
  measured pass.** It walks up past missing components so deep not-yet-existing paths resolve
  (404 vs 403 correctness), bounded by `PATH_MAX` — that bound is a load-bearing DoS guard (a
  deep path once cost 2,259 ms CPU, a 153× amplifier). Collect components by appending, join
  once (the loop spellings are quadratic). An entry that exists but won't resolve fails
  CLOSED (403) — dangling links, loops, and escaping links all answer 403.
- **Resolve and test containment BEFORE asking the filesystem anything about a path.**
  `-fileExistsAtPath:` follows symlinks, so a precheck ahead of containment is an existence
  oracle for paths outside the share (measured twice, closed both times). Run existence
  checks on the RESOLVED path, after containment.
- **NUL bytes:** refused inside the follow-resolvers (uploader/base-path 400, WebDAV 403 via
  nil resolution); `WSKNormalizePath` truncation is a deliberate second line. Six recurrences
  of this class — never claim it closed without driving every entry point.
- `[@"/" lastPathComponent]` is `@"/"` (the `filename="/"` upload escape); the upload path
  judges the composed path against the `realpath`'d directory.
- Same-file detection has one home: `WSKPathsNameTheSameFile` (protects against a self-move
  deleting the only copy, incl. case-variant pairs on case-insensitive volumes).
- **Splitting a path on "/" has one home: `WSKPathComponentsSeparatedBySlash`. NEVER
  `-componentsSeparatedByString:@"/"`** — it honours composed character sequences, so a
  combining mark directly after a "/" absorbs that slash into a grapheme cluster and the split
  skips it. `WSKNormalizePath` therefore left the `..` in front of one unstripped
  (`"../" + U+030C + "/d"` normalized to itself), while the same string's `-pathComponents`
  split correctly — one string cut two ways by two APIs that read alike. Client-reachable:
  request paths are percent-decoded (`WSKConnection.m:1207`), so `%CC%8C` arrives as a real
  mark. Found by fuzzing and FIXED 2026-08-18 at both sites (`WSKNormalizePath` and the
  base-path hidden-item walk), test `testNormalizePathStripsDotDotBeforeACombiningMark` (red
  on all four assertions before the fix). `-pathComponents` is NOT the drop-in — it collapses
  `//`, prepends `/` and keeps a trailing `/`; splitting on a character SET was measured
  byte-identical to the old spelling on every input without a mark, and 13% faster
  (926 vs 1064 ns/split), so the fix costs nothing. `-hasPrefix:` shares the behaviour, which
  is worth remembering for any future prefix test on a path — it bit the fuzz harness's own
  oracle, which called a path genuinely inside the share outside. No escape existed either
  way: realpath containment refused these paths before the fix and still does. The hidden-item
  site has NO observable behaviour change and no test can pin it — hiding a slash requires a
  mark immediately after it, which then begins the component, so it can never start with the
  "." that walk looks for; it was fixed for consistency, not for a hole.
- **The same blindness reached the NUL line, and that WAS reachable — fixed 2026-08-19.**
  `-rangeOfString:` without `NSLiteralSearch` misses a NUL that a combining mark follows, so
  BOTH documented defences went blind at once: `WSKPathContainsNULByte` (the resolver's
  first-line refusal) answered NO, and `WSKNormalizePath`'s truncation behind it left the NUL
  in place — measured making `WSKNamePassesExtensionAllowList` accept ".png" on a name the
  filesystem would read as `secret.dat`, the exact bypass the truncation comment describes.
  Nothing was exploitable end to end: composing such a path collapses it and `_RealPath`'s
  length guard refuses, so every resolver still answered nil — **refusal by accident of path
  composition, not by the guard meant to do it**. Both sites now pass `NSLiteralSearch`, pinned
  by `testNULIsDetectedAndTruncatedThroughACombiningMark` (red on all four assertions before).
  A SEVENTH recurrence of the NUL class, in a spelling none of the previous six covered.
- **The two `rangeOfString:@"/"` authority splits are NOT reachable — an earlier entry here
  said they "share the blindness", which is wrong.** `_OriginAuthority`
  (`WSKWebUploader.m`) and `_DigestURIPath` (`WSKConnection.m`) parse HEADER values, and
  CFHTTPMessage decodes those as Latin-1: the UTF-8 bytes of a combining mark arrive as two
  ordinary characters (U+00CC, U+008C), so no composed sequence can form in a header value at
  all. Measured by building a CFHTTPMessage from raw bytes, and independently by a test that
  asserted a behaviour change and PASSED against the unfixed code — it was deleted rather than
  kept green, because it could not fail for the reason it claimed. Both now use
  `NSLiteralSearch` anyway, as a statement of intent that does not depend on that decoding
  staying as it is. The distinction that decides reachability: `request.path` IS percent-decoded
  into real Unicode (`WSKConnection.m:1207`), header values are not.
- **The 2026-08-19 sweep of this class — recorded at the time as COMPLETE, which the CORRECTION
  below disproves. Read both.** What it genuinely established: the sites named here are literal
  and measured UNREACHABLE, same intent-only status as the two above, no test possible.
  Multipart part-header (`\r\n`→CRLF char-set, `:`→literal), the shared header
  helpers it calls (`WSKTruncateHeaderValue` `;`, `WSKExtractHeaderValueParameter` token,
  `WSKSplitAuthority` `]`/`:`), the DAV Clark-key `}` split, and the DAV Destination `#` guard.
  Why none is reachable: a mark after a delimiter attaches to the NEXT token's first char, so
  even the unhidden token fails its own comparison (`̌Content-Type`≠`Content-Type`) — fails
  closed. The DAV `{ns}<mark>local` key never forms: XML forbids a mark-initial localname and
  libxml2 (RECOVER) leaves the QName unbound (`n->name`=`Z:̌name`, no namespace) — probed
  directly. Header-value sites are additionally Latin-1-decoded (marks arrive as two chars).
  The Destination `#` guard was worth the most care — it is a REFUSAL that fails OPEN if a `#`
  is hidden. `componentsSeparatedByString:@"/"` is zero tree-wide.
- **CORRECTION 2026-09-02: the two sentences that used to end the entry above — "the site sweep
  for this class is COMPLETE" and "the one remaining non-literal search is the test-only trace
  comparator" — were both FALSE.** A dedicated pass found non-literal structural searches still
  live at, among others, `WSKRequest.m:302` (`componentsSeparatedByString:@","`), `:304` (`;`),
  `:376`/`:377` (Accept-Encoding), `:422` (Content-Encoding), `:523`/`:526` (Range),
  `WSKConnection.m:594` (case-insensitive `close`), `:2413` (If-None-Match `,` split),
  `WSKValidators.m:65` (entity-tag `,` split) and `WSKFunctions.m:127` — whose SIBLING
  `WSKTruncateHeaderValue` at `:141` is literal, the sharpest evidence that the sweep was
  believed complete while it was not. It is the sixth time this file has claimed a class closed
  that was not.
  **And the Latin-1 shield does NOT cover all of them.** The reflex is to say these are header
  values, which CFHTTPMessage decodes as Latin-1, so no composed sequence can form — true for
  the top-level-header sites, which stay intent-only. But MULTIPART PART-headers are decoded as
  **UTF-8** (`WSKMultiPartFormRequest.m:290`, feeding `WSKNormalizeHeaderValue` at `:305`/`:307`),
  so a real combining mark reaches the non-literal `;` at `WSKFunctions.m:127`. Measured
  end-to-end: the hidden `;` makes the search return NSNotFound, the WHOLE `Content-Disposition`
  value is lowercased instead of just its prefix, and the upload is stored under a case-mangled
  name. Fail direction checked and benign — the extension allow-list and traversal guards run on
  that same lowercased spelling (no bypass), and a hidden `;` in a part's `Content-Type` lowercases
  a nested boundary and fails the sub-parse closed. So: a small REAL defect, not just a record
  error, and unfixed (see "Still open at tip"). Note what this cost — the shielding argument was
  applied to a list without checking each entry's decoder, which is the same "closed at only some
  sites" shape one level up.

### Validators and conditional requests

- Entity tag = inode + mtime (`tv_nsec`) + size, minted ONLY by `WSKEntityTagForFileInfo`,
  shared by GET, the precondition check, and PROPFIND's `getetag`. A second formatter would
  make every precondition fail.
- `Last-Modified` is WITHHELD while mtime sits inside its filesystem's timestamp bucket
  (`WSKLastModifiedDateIsSealed`; 1 s only for apfs/hfs/exfat, 2 s otherwise) — the
  issue-time withholding is the WHOLE protection; do not try to "strengthen" the resume-path
  check. PROPFIND's `getlastmodified` shares the seal.
- `If-Modified-Since` uses EXACT equality; `If-None-Match` takes precedence (RFC 9110).
- Generated 304 responses preserve custom `Cache-Control`, `Content-Location`, `Date`, `Expires`
  and `Vary` fields, selecting additional-header names case-insensitively. ETag and Last-Modified
  still use their typed response properties. Never copy the entire additional-header dictionary:
  payload framing, encoding and unrelated headers do not belong on the substituted bodyless
  response. The cache-header copy applies only to 304, not to a generated 412.
- `If-None-Match: *` matches successful GET/HEAD representations even without an ETag or body.
  The shared tag matcher recognizes the standalone wildcard with whitespace; explicit tag
  comparison and If-Modified-Since precedence stay as before. The new wildcard path is read-only:
  judging a successful DAV creation afterwards would turn its 201 into a 412 after writing.
  Verified 2026-09-17: baseline failures pin missing custom 304 metadata and wildcard 200s;
  five regression tests cover mixed-case fields, bodyless and mapped/explicit HEAD, conditional
  precedence, keep-alive framing and DAV creation. Combined with four discarded-SSE regressions,
  `Run-Tests.sh` passes 272 ASan tests, eight traces, Mac/iOS/tvOS Release and both Swift consumers.
  A live Release probe completes 2,800 responses over 40 reused connections across four clients,
  verifies 200 MiB by SHA-256, and returns descriptors to baseline with no reserved bytes or active
  body readers. All 803 opened readers close; discarded 304/HEAD payloads never open a reader.
- **Only step 2 of RFC 9110 §13.2.2 is conditional on step 1.** If-Unmodified-Since is skipped
  when If-Match is present; If-None-Match (step 3) is evaluated whatever the earlier steps
  answered. The WebDAV write-verb chain was one `else if` ladder, so a SATISFIED If-Match
  skipped the client's If-None-Match entirely — `If-Match: <current tag>` + `If-None-Match: *`
  answered 204 and replaced the file, telling the client a condition it stated was met when it
  was not (the lost-update shape the If-Unmodified-Since gap was fixed for). Fixed 2026-09-02 at
  the one chain all three write verbs share; the nil check on the list is explicit at the call
  site rather than left to messaging nil.
- `If-Match`/`If-Unmodified-Since` are enforced BEFORE any destructive step (PUT, DELETE,
  MOVE, COPY) and ALSO on reads — gated to GET/HEAD 2xx deliberately (ungating turns every
  successful conditional write into a 412). `If-Match` on a MISSING resource answers 404 —
  RFC-REQUIRED, pinned in both directions; do not "correct" it. Tag comparison has one home:
  `WSKEntityTagMatchesList`.
- PUT rechecks parent, type and preconditions, stages every body beside the authorized
  destination, and replaces it under a per-server mutation lock. The early check alone
  admitted all eight competing `If-Match` writers AND all eight `If-None-Match: *` creators in
  the regression tests. Unconditional PUTs must share the lock. Request-body reception and
  authorization hooks stay outside it; sibling staging and its failure cleanup stay INSIDE so a
  directory MOVE cannot carry the stage away, and COPY cannot duplicate an in-progress stage.
  DELETE, COPY/MOVE, MKCOL and PROPPATCH share this lock through their filesystem transactions.
  DELETE/COPY/MOVE repeat their current-state policy and conditional checks after authorization;
  mutation paths must still resolve to the authorized paths. A large COPY, recursive removal or
  cross-volume PUT staging can delay other mutation commits. GET, PROPFIND and network transfer
  continue independently. This is per server: external writers and a second server sharing the
  same directory are not coordinated, and the accepted external directory-rename race remains.
  Reproduced 2026-09-17 on 61cccc9: after a successful PUT while authorization was parked,
  conditional DELETE removed the new bytes, MOVE relocated them, and COPY copied them (including
  overwriting an existing destination). A separate parent-directory MOVE carried away a PUT's
  hidden staging file: MOVE returned 201, PUT returned 500, and the stage remained in the moved
  directory. Five of six focused tests fail on the old source; unchanged-source controls pass.
  All six pass with the fix. A mutant retaining the final checks but separating DELETE/MOVE/COPY
  from PUT's lock fails both transaction tests on actual bytes, namespace state and staging
  residue, with all synchronization gates reached. GET still completes while a mutation waits.
  The full gate passes: 263 ASan tests, eight recorded trace suites, Mac/iOS/tvOS Release builds
  and both Swift consumers.
  Live macOS WebDAVFS overwrite and four parallel writes match their hashes; native filesystem
  copy uses read+PUT, so COPY is also exercised explicitly over HTTP. In 24 four-way conditional
  PUT/DELETE/MOVE/COPY races, exactly one destructive writer succeeds and each accepted COPY has
  the original bytes. Four paced readers complete 88 checksum-verified 32 MiB downloads (2.75 GiB)
  with 161 mutations observed while downloads are active. At rest: no temporary or hidden staging
  files, no reserved bytes or active downloads, and only the stats request's connection remains.
  The native mount, probe host and temporary share are removed afterwards.
- All three RFC 9110 date spellings parse (calendar year anchored — ICU once read `…94` as
  year 0094 and made `If-Unmodified-Since` a permanent 412); only IMF-fixdate is formatted;
  a 64-char length precheck rejects non-dates in constant time (parsed per-request on the
  process-wide serial queue).
- The DATE form of `If-Range` must keep working — Finder resumes with it (trace `059`).
- gzip is never applied to a 206. Unsatisfiable ranges: 416 + `Content-Range: bytes */N`.
- Opt-in gzip is negotiated BEFORE response preconditions, without opening a body reader.
  Missing/empty `Accept-Encoding` selects identity; explicit coding refusals override wildcards.
  If neither gzip nor identity is available and acceptable, answer 406. Partial responses,
  including any case spelling of `Content-Range`, can only select identity.
  Every opted-in variant merges `Vary: Accept-Encoding` case-insensitively, preserving `*` and
  existing fields. Set the flag on every eligible handler response, not just accepted-gzip calls.
  Actual gzip derives a DISTINCT WEAK tag from the typed source ETag: async flush boundaries
  can change encoded bytes, so a strong gzip tag would promise more than the encoder guarantees.
  It also withholds Last-Modified so a gzip client cannot use its date to resume identity bytes.
  Identity ETags, sealed dates and Finder's date-based If-Range remain unchanged. Gzip weak-tag
  If-Range falls back to a whole response; cross-encoding If-None-Match cannot produce a 304.
  Verified 2026-09-17: six new wire regressions fail on the prior source, then pass with the fix;
  an additional mutant proves that enabling gzip in a subclass before calling super is covered.
  The existing disconnect regression explicitly requests and asserts gzip, so it still exercises
  encoder cancellation. Eleven focused tests pass, followed by `Run-Tests.sh`: 278 ASan tests,
  eight traces, Mac/iOS/tvOS Release builds and both Swift consumers.
  A live Release probe completes 4,000 responses across four clients and 80 reused connections:
  2,400 status-200, 1,200 status-304 and 400 byte-exact status-206 replies. It verifies 420,659,200
  decoded bytes by SHA-256, including 800 gzip bodies split over 1,600 chunks. Descriptors return
  11→11, all 1,216 tracked readers close, reserved bytes return to zero, and only the stats
  request remains connected. The probe host and temporary share are removed afterwards.
- `WSKFileResponse` opens once with `O_NOFOLLOW` and derives everything from `fstat` on that
  descriptor; EVERY chunk is verified against the promised size/mtime BEFORE handing over.
  A zero-length NSData is the end-of-stream sentinel — the `} else if (_size > 0)` branch is
  load-bearing (removing it broke gzip at all sizes and logged false truncation errors).
- `WSKFileResponse.contentType`/`lastModifiedDate`/`eTag` are honestly `nullable` (sealed
  dates and the 416 path make nil real; breaking for Swift, deliberate).

### Headers and framing

- **Query/form fields are bounded before looking for `=`** (2026-09-28). A valueless
  `flag` maps to an empty value, empty names are preserved, and empty `&` fields are ignored.
  Only the first `=` splits a field. The `&`, `=` and `+` operations use `NSLiteralSearch`:
  Foundation's default composed-character search can hide each beside a combining mark.
  Replace literal `+` before percent-decoding; never decode twice. Existing compatibility
  policies remain: malformed escapes/invalid percent-encoded UTF-8 skip the pair, and the
  last successfully decoded duplicate wins. Four regressions cover the parser plus live
  GET queries and POST form bodies; failure cases were verified against the old parser.
- ONE validating pass over the header block: paired CRLF only, no obs-fold, `1*tchar` names,
  C0/DEL refused in field values (HTAB and obs-text pass), more than one `Host` line = 400
  (counted on RAW lines — CF merges duplicates), version grammar first (bad grammar 400,
  unimplemented major 505, higher 1.x minor patched to 1.1 in place), request-line overflow
  414 vs everything-else 431. `kHeadersMaxLength` applies to the BLOCK, not the buffer.
- Wire integers parse strictly (digits only, explicit overflow — no `-integerValue`, no bare
  `strtol`). The `tchar` predicate is SHARED with the response-side header-name check.
- `Transfer-Encoding` is parsed as a proper list: a coding the server doesn't implement
  answers 501; a malformed application of an implemented one answers 400 — never read as "no
  body". Chunked framing and `100 Continue` are never sent to HTTP/1.0 clients.
- `Content-Encoding`: gzip and x-gzip decode; everything else 415. Truncated gzip refused;
  trailing bytes refused SPLIT-INVARIANTLY (the verdict must never depend on TCP
  segmentation). The decoder's `close:` cleans up even when refusing.
- A PUT carrying `Content-Range` answers 400 — in the CONNECTION layer, before body spooling
  (RFC 9110 §9.3.4 MUST; `curl -C -` sends it).
- Refusals are evaluated on headers before the body is read (`-_responseForRejectedRequest`:
  Host allow-list, Content-Range refusal, `-preflightRequest:`).
- Host validation lives in the connection layer AHEAD of `-preflightRequest:` (a subclass
  must not be able to switch it off). IP literals accepted by SHAPE, never resolved (the
  attacker controls that DNS). An absolute-form target's authority wins over `Host`, detected
  off the RAW request line (`CFHTTPMessageCopyRequestURL` synthesizes URLs from Host, so the
  parsed URL cannot answer it). Refusal split: bad syntax 400, unserved name 421 — syntax
  judged only on the refusal path so odd allow-listed spellings keep working.
- Multipart: one shared budget (`WSKMIMEStreamBudget`) across nested parsers; part-header
  blocks capped; 1024 parts max; `[super init]` and the `_tmpFile = -1` sentinel are set
  before any failure return (a nil-returning init once closed fd 0 in dealloc).
  **Completed arguments own their own global memory reservations** (2026-09-16). The shared
  parser budget counts per-body argument bytes and parts; it must not own the global charge,
  because `-close:` drops the parser while the request still retains its fields (the audit held
  72 MiB in nine completed requests while the global counter read zero). Reserve before copying
  each argument, alongside the still-live working buffer. Each `WSKMultiPartArgument` retains
  its charge until deallocation, including after request teardown and after a later part fails;
  retaining one field must not pin sibling charges. This follows the library's owner-level
  accounting convention: it is not an RSS bound or accounting for separately retained data/text
  aliases or decoded string allocations. File parts keep streaming to disk as before.
  Six regression tests fail against the old accounting and pass with this ownership; the full
  248-test ASan suite, eight trace suites, platform builds and Swift consumers pass. The wire
  control reproduced 72 MiB held with zero reserved before the fix; afterwards six 8 MiB forms
  stay charged and the next receives 503 because its working buffer plus copy would exceed the
  64 MiB total. Releasing holders restores capacity. Eight batches of four concurrent uploads
  return exactly each released field's bytes; a verified 20 MiB file still streams to disk,
  malformed-upload temp files disappear, and 154 concurrent download controls succeed, with
  all 196 connections released, descriptors 9→9 and reserved bytes 0 after cleanup.
- **Both body parsers are linear in their input, and every scan resumes rather than restarting**
  (2026-09-03, extended 2026-09-04). Four defects of one shape. The chunked decoder dropped each
  consumed chunk from the FRONT of its buffer: 400k one-byte chunks (2.4 MB of wire) burned 4.6 s
  of CPU, and a DAV PUT streams to disk so no size cap bounded it. The multipart parser rescanned
  its whole working buffer on every append, and judged its 8 KB part-header cap only AFTER the
  terminating blank line, so an unterminated block grew to the 16 MB buffer (128 KB of header in
  1-byte segments: 8.5 s). Then the chunked cursor itself, which advances only when a chunk
  COMPLETES, left two siblings: a chunk-size line that never ends, and — once the last-chunk marker
  is seen — a trailer that never ends, each rescanned in full per read (2.80 and 1.37 ms of CPU per
  read at an 8 MB prefix, against 0.067 after; 0.35 ms at 64 KB, so cost grew with the prefix,
  which is the quadratic signature). A few hundred dribbled bytes a second owned a core.
  Every search now resumes from the last position that could still begin the token it wants
  (`_scanOffset`, `_chunkScanOffset`, `_chunkTrailerScanOffset`), the header cap is judged on bytes
  buffered, a preamble is discarded as it streams (RFC 2046 §5.1.1), and `appendBytes:` feeds
  256 KB slices so the working-buffer cap is judged on what is RETAINED — it was applied to one
  read's size before file content could drain, so a >16 MB loopback read answered 413 on a 1 GB
  upload. The stalled fake-boundary wedge is UNCHANGED by design, now at O(1) per append.
  Pinned by seven CPU-bounded tests (load-proof, unlike wall time), each proven red against its OWN
  hunk with the others in place.
  **Two lessons the numbers came with.** Getting the probe right was the whole difficulty: the
  kernel coalesces dribbled bytes into one read unless the writes are paced AND `TCP_NODELAY` is
  set, and without both the cost reads as LINEAR and the defect looks absent — the first
  measurement said exactly that. And what the fuzzing pass could not see: libFuzzer measures
  crashes and hangs, not a terminating-but-quadratic cost.
- Digest auth works over full bytes (never `-UTF8String`+`strlen`); header-parameter
  extraction requires a token boundary (`nonce=` matches inside `cnonce=` otherwise);
  `filename*` uses an escaper that covers `;`.
- **The verified digest binds the WIRE method and the WHOLE request target** (both 2026-09-02).
  HA2 was computed from `request.method`, which a mapped HEAD has already rewritten to GET
  before preflight runs — so the server compared a GET digest against the client's HEAD one and
  they could never agree: HEAD was permanently unauthenticable on both Digest servers
  (`curl --digest -I` → 401, retried → 401, while GET of the same URL → 200). Now
  `request.isVirtualHEAD ? @"HEAD" : request.method`. Separately, the target check compared only
  `_DigestURIPath(uri)` against `request.path`, and `request.path` never carries a query — so the
  query was covered by NOTHING, which on the uploader is where every operation names its target
  (`/list?path=`, `/download?path=`). A credential captured from real curl for
  `?path=/mine.txt` served `/yours.txt` on replay; now 401. Both halves compared RAW (each side is
  verbatim wire text); absent-on-both-sides is a match, spelled out rather than left to
  messaging nil. Real clients DO put the query in the uri directive — verified, no over-refusal.
- **The challenge is RFC 7616 (`qop="auth", algorithm=MD5`) since 2026-09-03**, not the RFC 2069
  form it sent before. Not a conformance nicety: every neon-based client — cadaver, davfs2,
  sitecopy, and litmus, the conformance suite this project reaches for — REFUSES a qop-less
  challenge outright rather than falling back, so not one could authenticate, while curl and
  CFNetwork accept either form and made every in-house probe pass. Verified across three client
  families with the unfixed build as the control. Which computation applies is chosen by what the
  CLIENT sent (§3.4.6), so the RFC 2069 form still verifies beside it. `auth-int` is refused (it
  folds a body hash into HA2, which this HA2 is not), and `qop` without `nc`/`cnonce` is refused
  rather than defaulted. No `opaque`: no per-nonce state exists to check one against.
  **This does NOT close the replay item**, whatever the finding said: qop supplies `nc`, but nothing
  counts it, so a captured header stays replayable for the nonce's 300 s lifetime.
  The trap, before touching any Digest parameter: `qop`, `nc` and `algorithm` arrive UNQUOTED, and
  `WSKExtractHeaderValueParameter` deliberately does NOT end an unquoted value at a comma (RFC 2046
  lets a multipart boundary contain one; terminating there truncated real uploads). It hands back
  `auth,` and `00000001,`, and every qop credential then fails on a hash of the wrong bytes.
  `_DigestToken` cuts at the comma where these are read, rather than reopening that decision.
- The `SO_NOSIGPIPE` result is checked and the socket dropped on failure — never remove
  (SIGPIPE once killed the process roughly every 15–25 abortive closes).
- `WSK_DCHECK` is a no-op in Release; `WSK_DNOT_REACHED()` aborts in Debug — remote-input
  paths must log-and-fail instead.
- Fourteen post-1999 reason phrases are supplied (421/424/431 among them); only those —
  everything CF gets right is left to CF (trace-corpus byte compatibility).
- Reflected strings are clamped at the single point they pass through; PROPFIND/LOCK bodies
  capped at `kDAVMaxRequestBodyLength` before libxml2; `_EscapeHTMLString` escapes `&` FIRST;
  hrefs are percent-encoded THEN HTML-escaped; `_XMLEscape` drops XML-1.0-illegal controls.
- ENOSPC/EDQUOT answer 507 for PUT/MKCOL/COPY/MOVE — read both `NSFileWriteOutOfSpaceError`
  and the POSIX errno under `NSUnderlyingError`. **The uploader's `/upload`, `/move` and `/create`
  route through the SAME `WSKServerErrorStatusCodeForError` now** — they hardcoded 500, so a
  disk-full upload reported a server fault (measured 500 on a real 2 MB volume) for what is "no
  room", and a 5xx invites the client to retry a request that cannot succeed. `/delete` and `/list`
  stay 500 (delete frees space, a listing failure is genuinely a server fault) — matching WebDAV,
  which also leaves its DELETE site hardcoded. The mapping FUNCTION was always right and unit-tested;
  the gap was the uploader call sites never consulting it, the "class closed at only some sites"
  shape. Regression driven by injecting `NSFileWriteOutOfSpaceError` into `-moveItemAtPath:` at the
  live `/upload` endpoint, which the pure-function test could not reach.
- **Multipart syscall errors survive logging** (2026-09-30). Save the temporary-file
  open/streamed-write errno before any logging, and use that saved value in the NSError.
  The built-in logger's first `isatty` call and application logger callbacks may change
  errno. A real ENOSPC after 131,024 streamed file bytes consequently answered 500; the
  deterministic test logger sets errno to EIO and pins the required 507. The new
  `Scripts/Endurance/storage_recovery.py` rejects the old multipart source, then passes
  twelve cases with the fix: uploader/DAV × ENOSPC write/EIO write/EIO close × new/existing
  destination. The fixture requires at least 64 KiB of real file writes, selects one
  regular temp file by fd/device/inode, and fires exactly once; close EIO follows a real
  successful close. Six existing destinations preserve inode/body/metadata. Concurrent
  verified downloads progress before release and after refusal, and every unarmed retry
  succeeds in the same process. Standalone result: 90 requests, 114 MiB hash-verified,
  all connections closed, FDs 8→8, zero reservations/temp or staging residue. The test
  uses one extra chunk then reads an early write-error response; an earlier eager sender
  hit RST, so this does NOT establish behavior for clients continuing to send after an
  early refusal. Nor does it cover real volume exhaustion, positive short writes,
  crash durability or publication/rename failures. Open errno capture is the analogous
  source-reviewed correction; live regression directly covers streamed writes. Reports
  `build/storage-recovery-{final-before,after-matrix}.json` preserve exact source/harness
  hashes. The twelve-case check is now part of `Run-Tests.sh`. Full gate passed:
  301 ASan tests, all eight traces, Mac/iOS/tvOS Release builds, both Swift consumers,
  23 harness tests, endurance and the independent twelve-case storage run.

### File serving and connection reuse

- EVERY file-vending surface honours `Range`/`If-Range`, including uploader `/download`.
  (All of them ADVERTISE `Accept-Ranges: bytes` too since 7e6e74f — measured 2026-09-03 on
  every DAV GET/HEAD/206/416 and on `/download`/`/preview`; this line claimed otherwise until then.)
- `/download` is always an attachment (stored-XSS defence — the uploader's one-click buttons
  run in the server's origin); `/preview` serves an inert-media ALLOW-list inline with
  `nosniff` + subresource-denying CSP — SVG and PDF excluded deliberately (both carry
  script; that exclusion is why it's an allow-list, not "anything image/*"). Both share one
  resolution walk.
- `fileCacheControlMaxAge` is opt-in, default 0 = `no-cache` (revalidate, not no-store).
- Keep-alive is opt-in (`WSKOption_ConnectionKeepAliveTimeout`, default 0) and restricted to
  requests carrying NO body framing — structural anti-smuggling (a connection that never
  reads a body cannot be desynchronized), not "we parse carefully". Eligibility reads the
  RAW header names, never `-hasBody` (which misses `Transfer-Encoding: identity` — exactly
  the TE.CL desync shape).
- **A 1xx, 204 or 304 delimits itself by STATUS** (RFC 9112 §6.3 rule 1: terminated at the first
  empty line "regardless of the header fields present"), so it satisfies the reuse length test
  with no `Content-Length`. Before 2026-09-02 it did not: the substituted 304 is minted bare, so
  every revalidation closed its connection — precisely the traffic reuse exists for, since files
  are `no-cache` by default and a re-viewed page of thumbnails revalidates every one of them. NOT
  widened to bare 400/404/416, which state no length and nothing in their status says so; and the
  serializer is unchanged, so a 304 gains no `Content-Length` and trace bytes are untouched.
  Soaked per the connection-layer rule: 7,200 revalidations, 0 errors, descriptors flat, and
  connections still retire at `kMaxRequestsPerConnection` (101 served, then close).
- **The handler array is part of the accept-time snapshot** (2026-09-02). It was the one piece of
  server config a live connection read from the server on every request. `-stop` does not wait on
  connections and handlers may be re-registered once stopped (the header forbids it only "while
  running", and `-stop` nils the options the assertion checks), so a kept-alive connection
  outlived the stop and enumerated an array being rewritten: a request answered by handlers
  registered AFTER that connection was accepted, and — with 24 connections live — SIGSEGV on 3 of
  3 runs. Copied at accept, the same probe survives ~1M mutation loops.
- A request served from `_carryOverData` must be marked non-idle at the point the carry-over
  is consumed, or the keep-alive reaper cuts its response off mid-body.
- Bytes past `Content-Length` are TRIMMED, never refused (TCP segmentation isn't the
  client's fault); the remainder is dropped, never interpreted.
- `-open`/`-close` fire once per CONNECTION; per-request work (access log, trace recording)
  lives in `-_flushRequestRecordAndLog`. A keep-alive client leaving is EOF, not an error —
  no fabricated 500 in the log.
- **Async callbacks own a connection only until completion or disconnect.** Handler and
  response-reader tickets are consumed/revoked on the connection queue. Saved callbacks capture
  only their ticket, using an atomic connection snapshot to reach the queue briefly; capturing
  the queue directly would keep it alive after the connection is gone. A reader ticket must
  also own its final write completion (that block captures the connection); revoking only its
  `connection` property leaves the second ownership edge alive. Clear both BEFORE calling the
  response's `-close`, which can itself invoke a saved callback. Completed callbacks retained by
  an app must neither pin a closed connection nor act on its next keep-alive request. With idle
  timeouts enabled, Darwin `poll(POLLIN)` detects FIN even behind unread pipelined bytes;
  `MSG_PEEK` alone cannot. Neither consumes a live client's next request or adds a deadline for
  a slow handler/reader. Gzip guards late/duplicate raw callbacks BEFORE deflation, synchronizes
  against close, and captures its encoder weakly so a saved callback cannot retain its resources.
  Verified 2026-09-13: four regression cases fail on the old code (plain/gzip readers are separate)
  while the live pipelined control passes; all five pass with the fix. Full gate: 242 ASan tests,
  eight trace suites, platform builds and Swift consumers. A 60-batch soak retained 1,920 callbacks
  and invoked them late/again 7,680 times alongside 6,284 verified 1 MiB downloads: all 8,265
  connections and 960 streamed responses closed/deallocated, descriptors 9→9, reserved bytes 0.
- **Lingering close.** `close(2)` with unread inbound data makes the kernel send RST, and the RST
  destroys bytes already handed to TCP — a response the client has not read yet. Measured before the
  fix on a WebDAV PUT refused for `Content-Range` while the client kept uploading: 391 B complete on
  one run, **167 B truncated mid-headers** on the next. So the old record's "the status never is
  [lost]" was WRONG, and its "last pipelined response" framing was a special case — plain pipelining
  never reproduced, because the server consumes pipelined bytes in the same read. The rule is unread
  inbound data at close time, whatever produced it.
  Fixed by `shutdown(SHUT_WR)` then a bounded drain, and ONLY when the receive queue is non-empty, so
  an ordinary GET and the whole trace corpus close byte-identically. Half-close rather than a
  drain-only `lingering_close`: draining alone still ends in RST, because a client uploading 64 MB
  never reaches EOF inside any sane bound. Bounds are 2 s total, a 500 ms silence gap, and a 64 KB
  discard cap — fixed constants. The slot cost that kept this open is negligible: the header-phase
  deadline is `kMaxHeaderPhaseTicks` (2) ticks of the 30 s idle timer, i.e. **60–90 s**, so a 2 s
  linger cannot be the cheapest way to occupy a slot. `-stop` abandons lingering; note that `-stop`
  never waited on connections anyway, so this was never about shutdown latency.
  Accumulation-soaked 2026-08-19 (the connection-layer-change rule): 101,580 drain firings under
  concurrent refuse-mid-upload load, descriptors flat (17→17), budget 0 at rest, `leaks` 0/0, no
  server errors, 440k control GETs served throughout. All firings took the discard-cap exit (the
  mid-upload case); the gap/deadline exits share the same teardown and resisted deterministic
  triggering (the header read greedily consumes front-loaded bytes, so unread-at-close needs a
  live blast). Trigger + counting via the Debug build's `Lingering before close` log.

### Limits (fixed constants, deliberately not options)

- `kWSKMaxTotalInMemoryLength` (64 MB) bounds the SUM across all connections; the reservation
  is an OBJECT whose bytes return in `-dealloc`, so a dying connection can't leak budget.
- 16 MB in-memory body; 64 MB decompressed (enforced inside the inflate loop, anti-zip-bomb).
  Consult `WSKMaxInMemoryBodyLength()`/`WSKMaxDecompressedBodyLength()`, never the `kWSK…`
  constants directly (test overrides depend on it).
- Budget exhaustion = 503 (`ServerAtCapacity`). **Correction 2026-09-16:** the old record said
  500; the connection mapper already returned 503 before the multipart ownership fix, and its
  wire probe confirms that existing behavior. A failed body read (disconnect, bad framing, cap) aborts
  the request — never process a partial body as complete. Bodies streamed to disk are
  deliberately unlimited.
- Idle timeout: hard header-phase deadline; body phase uses a byte-RATE floor (effectively ~34 B/s,
  not the nominal 32, because the timer's `interval / 10` leeway shortens a tick window); response phase
  is any-byte-is-progress (SSE-safe); handler time never counts.
- **Response-phase progress is read from the TCP layer (`tcpi_txbytes`), and the phase gets a
  ten-tick stall allowance** (2026-09-04). The rule was always "any byte is progress"; the MEASURE
  could not see one. `-didWriteBytes:` runs only when a whole `dispatch_write` COMPLETES, so a
  256 KB chunk to a reader slower than roughly buffer ÷ timeout spanned two ticks having registered
  nothing, and the starvation check closed a connection whose peer was reading throughout: at the
  default 30 s idle, 8 of 8 trials cut, a 20 KB/s client pulling a 20 MB file reset after 121 s with
  2.27 MB. A phone on a Tailscale relay is exactly that client.
  **`SO_NWRITE` cannot be the instrument**, which is worth recording because it is the obvious
  choice: it reports send-buffer OCCUPANCY, refilled as fast as it drains, so it reads identically
  for a 5 KB/s peer (491052 every tick) and one that has stopped reading (646700 every tick).
  **And the counter alone was not enough** — shipping it alone broke the gate. It advances in bursts
  of ~35 KB every 4–6 s, and once the peer's receive buffer is FULL the server cannot send at all,
  so it freezes for (that buffer ÷ the read rate): tens of seconds for a phone-shaped reader, which
  a two-tick rule still cuts inside. Hence `kMaxResponseStallTicks` (10) consecutive checks with
  nothing transmitted, reset by any transmitted byte — five minutes at the 30 s default. The header
  and body phases are deliberately unchanged: those are where a dribbling client is an actual
  attack. A DEAD peer now holds its slot for ten ticks instead of one, which is the right trade
  under the local-network-only ruling.
  **The stalled half is unpinned:** loopback keeps absorbing for a peer that never reads — a client
  with `SO_RCVBUF` 16 KB set before connect still drained 33 MB of a 64 MB body — so the write never
  stalls and nothing is starved. The server is right to keep such a connection; it just means the
  ten-tick bound has no in-suite test. The slow-reader half is pinned and deterministic.
- **Dead-property storage: 64 KB per RESOURCE** (`kDAVMaxDeadPropertyStorageLength`, 2026-09-02),
  judged on the serialized plist after the merge. `kDAVMaxRequestBodyLength` bounds one request;
  nothing bounded what those requests accumulate into, so ordinary legal PROPPATCHes grew the
  xattr without limit — 329,223 bytes on a 4-byte file across 40 requests, and the audit reached
  1.28 MB answered by a 1.29 MB allprop PROPFIND. It survives restarts and every allprop echoes
  it back amplified, which is exactly the Shape A accumulation shape. Over the cap it reports
  EDQUOT and PROPPATCH answers **507** (ENOSPC too — a full disk previously said 403, sending the
  client back to retry what could not succeed); ENOTSUP stays 403. A removal shrinks the plist so
  it can never be refused: a full store must always be emptyable (measured 57,617 → 49,402).

### WebDAV

- **File PROPFIND metadata comes from one opened inode** (2026-09-28). After containment
  and extension checks, open the classifier's resolved path with `O_NOFOLLOW | O_NONBLOCK`,
  require a regular file, and derive size, birth/modification dates, ETag and the timestamp
  seal from one `fstat`. Read stored properties through that descriptor too, then close it
  before XML generation, including propname's early return. A disappeared or nonregular
  replacement is omitted; directory metadata retains its existing behavior. This pins file
  identity during atomic publication, not a transaction across in-place writes or concurrent
  PROPPATCH on the same inode. Do not reintroduce pathname observations for individual fields.
  Two deterministic regressions replace a benign file before capture or at XML emission;
  both fail on the previous source (15 assertions), covering sizes, creation dates, ETags,
  sealed/unsealed modification dates, custom properties and stored displaynames. Descriptor
  cleanup is checked across allprop, propname, named properties, failed opens and nonregular
  replacements. The 78-test WebDAV ASan suite passes. Together with the containment change,
  the complete gate passes 301 ASan tests, all eight unchanged trace suites, Mac/iOS/tvOS
  Release builds, Swift consumers and concurrent-transfer endurance smoke. Native
  `mount_webdav` verifies 14 file readbacks, metadata for 15 resources and write/rename/delete;
  all 85 connections close, descriptors return 8→8, and reservations and temporary files are zero.
- **Named PROPFIND matches the namespace AND local name** (2026-09-28). Only the exact
  `DAV:` namespace selects a live property; arbitrary/default prefixes are equivalent.
  Foreign and unqualified names such as `getetag` use the same dead-property keys as
  PROPPATCH, so they can be stored and retrieved without colliding with built-in metadata.
  Every element's name and namespace are validated before classification.
  Each resource tracks which requested live properties it actually returned. The remainder
  gets a property-level 404 for named queries, including file-only properties requested on
  collections and a modification date withheld by the timestamp seal. Empty successful
  values count as returned. Allprop and propname behavior is unchanged; availability tracking
  is local to each resource in Depth:1 listings. Existing empty 200 propstats are retained.
  The trace update is strictly additive: 69 Finder/Transmit responses gain 404 entries for
  112 collections' requested dates and sizes, plus adjusted Content-Length. Removing those
  entries and restoring lengths reproduces every prior byte; all other traces are unchanged.
  Native `mount_webdav` reads 14 files and completes write/rename/delete after metadata checks
  across 15 resources. All 85 connections close, descriptors return 8→8, and reservations and
  temporary files are zero.
  Six new ASan cases parse expanded property names and assert exact per-resource statuses
  and values. Four fail against the old code (219 assertions); the prefix/enumeration controls
  already pass. The final ASan suite passes 295 tests. The source and fixture changes also
  pass the complete gate: eight trace suites, all platform/Swift builds and endurance smoke.
- **PROPFIND and PROPPATCH share `_DAVResourceHref`** (2026-09-28). The decoded resource
  path is percent-encoded once, then escaped for its XML context. PROPPATCH formerly only
  XML-escaped the decoded path, so spaces, fragments, queries and literal percent sequences
  could publish a different resource identity. The shared allowlist preserves prior PROPFIND
  bytes. Two regressions cover successful and atomic-refused updates across 14 names each,
  including reserved characters, NFC/NFD, emoji, literal `%20`/`%2F` and a nested path. They
  parse the XML, check explicit URI spellings and fetch each returned href unchanged.
  Combined with the query/form fix, `Run-Tests.sh` passes 289 ASan tests, all eight trace
  suites, Mac/iOS/tvOS Release builds, SwiftPM and both Swift consumers, five endurance
  oracle tests and the concurrent-transfer smoke check. A native macOS `mount_webdav`
  check reads all 14 names and writes, renames and deletes another reserved-character name;
  after unmount, all 85 connections are closed, reservations and temporary files are zero.
- Class 1 is complete; PROPFIND publishes nine properties. `getetag`/`getcontenttype` come
  from the SAME functions GET uses (never a second derivation) and are FILE-only —
  collections have no entity tag. `displayname` prefers a stored (PROPPATCH-set) value,
  skipped by BOTH dead-property loops (allprop and `<propname/>`); the derived fallback comes
  from the resource path the client used, which arrives ALREADY unescaped — do not unescape
  again (`50%.txt` once published EMPTY). The root's displayname is deliberately empty.
- **A Depth:1 entry describes what a GET of it SERVES, which for a symlink is the target.**
  The enumeration hands the property builder a raw child name, and its observers split three
  ways on it: `-attributesOfItemAtPath:` does not follow a FINAL link (so size and dates came
  from the link inode), `stat()` does (so the TARGET's entity tag went out beside them), and
  `open(O_NOFOLLOW)` failed ELOOP so `getlastmodified` was omitted entirely. Measured: a 3 MB
  build behind an alias published `getcontentlength` 9 — the length of "build.ipa" — with the
  target's etag. A PROPFIND-driven client sizes its copy from the listing, so mount_webdav and
  rclone truncated the build silently, with no date validator published to notice by. Depth:0 was
  always right (performPROPFIND hands in the follow-resolver's answer); Depth:1 now reads
  `WSKServableFileTypeAtPath`'s `outResolvedPath`. Fixed 2026-09-02; this selected the right
  target path, but separate metadata calls could still mix atomic replacements of that path.
  The descriptor snapshot above closes that remaining gap. The old code comments asserted
  the opposite of the measured behaviour. Recurring shape 6.
- **A property name carrying an UNDECLARED namespace prefix is refused 400 by both parsers.**
  libxml2 runs with `XML_PARSE_RECOVER` (settled), so `<Z:note>` with no `xmlns:Z` survives with
  the prefix baked into the local name — `node->name` is literally `"Z:note"`, `node->ns` NULL.
  Emitting that is not XML, and STORING it poisons persistently: every later allprop PROPFIND of
  the resource re-emits it, INCLUDING the Depth:1 listing of its parent, so one poisoned file
  makes the whole folder unparseable. Three paths were affected (PROPPATCH response, allprop
  readback, the 404 propstat of a PROPFIND naming one). Both parsers judge it alike — teaching
  one and not the other just moves the way in. `_DeadPropertyElement` also returns nil for a key
  it cannot represent and every call site skips it, so a share poisoned by an OLDER build heals
  on upgrade (verified by staging with the old binary and serving with the new).
- **A property key is validated on BOTH halves, by asking libxml2 rather than by blacklisting**
  (2026-09-03 → 09-05, four rounds; the blacklist was wrong three times).
  The key is `{href}localname`, read back by splitting at the FIRST `}`. So `xmlns:Z="urn:a}b"`
  stored `{urn:a}b}note` and emitted `<W:b}note xmlns:W="urn:a"/>` — the prefix IS declared, so the
  undeclared-prefix fix's own oracle passed it, but `b}note` is not an XML name and a NAME cannot be
  escaped into legality the way a value can. One PROPPATCH made the file's allprop AND its parent's
  Depth:1 listing unparseable, persistently (xattr).
  Fixing only `}` was still too narrow: **NSXMLDocument — what a Cocoa client parses a 207 with —
  refuses the whole document** for a namespace containing space, tab, newline, NBSP, `>`, `%`, `^`,
  `` ` ``, `{`, `|`, `\` or any non-ASCII character, while NSXMLParser, WebDAVFS, neon and rclone
  tolerate every one (which is why only `}` was caught first). So the namespace is judged by
  `xmlParseURI` — measured against NSXMLDocument on 19 spellings, they agree on 17, and the two
  where it is stricter are excluded from a URI by RFC 3986 anyway — and the local name by
  `xmlValidateNCName`. The explicit `}` test stays in FRONT of the URI check: it protects the KEY
  encoding, which would still need it if libxml2 loosened. `_DeadPropertyElement` returns nil for a
  key it cannot represent and every call site skips it, so a store poisoned by an older build heals
  on upgrade — one property lost instead of a whole listing. Recurring shapes 2 and 13.
  **Two things only a round-trip test could show.** libxml2 writes every `&` in `node->ns->href` as
  `&#38;` and does that to nothing else (measured across `&`, `<`, `>`, `"`, `'`, tab, newline), so
  `urn:a&b` was stored and published as `urn:a&#38;b` — well-formed, but not the namespace the
  client named, so the property could never be named again. `_PropertyNamespaceHref` undoes it in ONE
  home both parsers share; the inverse is exact, so a URI whose literal text is `&#38;` still
  round-trips. A key written by an OLDER build keeps its mangled namespace — deliberately not
  healed, since decoding on READ would corrupt the now-storable literal. And both validators judged
  `-UTF8String`, which stops at the first NUL, so they validated a PREFIX while the whole string was
  emitted; `_IsWholeUTF8String` is the one home for that question. Seventh recurrence of the
  truncation class, found by re-fuzzing these functions the day after writing them.
- A `Destination` naming another server answers 502; compared by host NAME only — scheme and
  port deliberately ignored (TLS terminates upstream, ports may translate). A value starting
  `//` is a network-path reference and CARRIES an authority; `///path` parses with an EMPTY
  authority and is this server.
- DELETE refuses `Depth: 0` on a COLLECTION (400); on a plain file `0` ≡ `infinity` and is
  accepted (also for COPY and MOVE — an asymmetry only MOVE enforces would refuse real
  clients).
- MKCOL on an existing name = 405 with `Allow` (`EEXIST` mapped at the creation site too);
  all four 405 sites route through `_MethodNotAllowed()`. PROPFIND with no `Depth` = 403 +
  `propfind-finite-depth`. COPY `Depth: 0` genuinely shallow-copies a collection.
- PROPPATCH: dead properties live in ONE xattr plist keyed by Clark notation
  (`{ns}localname`), atomic per §9.2 (424 retryable); live properties 403; a no-xattr
  filesystem becomes a per-property 403, not fake storage.
- PUT preserves that DAV xattr (including stored `displayname`) byte-for-byte on its staged
  replacement. Its final precondition check, bounded property copy and rename share one
  per-server lock with PROPPATCH's final precondition check and read/merge/write and the other
  DAV mutations. Body reception and upload authorization stay outside the lock. Missing/unsupported
  attributes need no copy; other read/write errors refuse before replacement, and a store over 64 KB
  refuses with 507. Never use the lenient PROPFIND reader for this copy: it converts errors
  and malformed blobs into an empty dictionary, silently discarding metadata.
  Verified 2026-09-16: six focused tests pass (five fail on the old source; the sixth is the
  create/bare-file/conditional-refusal control). Splitting the lock while retaining the copy
  makes both queued-PROPPATCH tests fail on lost properties or stale conditional acceptance.
  macOS `mount_webdav` preserved the exact 145-byte property store and displayname through a
  1 MiB overwrite; four concurrent native writes round-tripped with matching SHA-256 hashes
  and no hidden staging residue.
- The LOCK stub is deliberately a stub: Finder-only class-2 façade (`_IsMacFinder`; everyone
  else gets `DAV: 1` and 405), requires `Depth: 0` exactly, returns the `Lock-Token` header,
  stores nothing; `lockdiscovery` is always empty (the honest answer). Not made real:
  single-user deployments, stateless `If-Match` protection already exists, and the `If:`
  grammar needs a parser — the richest defect source here.
- MOVE/COPY stage unconditionally and swap EXCLUSIVELY (`renamex_np(RENAME_EXCL)`); the
  replace-swap fallback carries the vetted `dev`+`ino` into the destructive step. The exFAT
  fallback fires ONLY on ENOTSUP/ENOSYS; every other errno must keep failing.
- `Overwrite` is case-folded via `_HeaderTokenIs`. MOVE refuses without `T` when the
  destination EXISTS (deliberate RFC deviation; fresh destination = 201 with no header);
  COPY refuses only on `F` — also deliberate (absent means `T` per §10.6, so a third value
  grants nothing).
- MKCOL removes the collection if a later step fails. COPY with `Destination` inside the
  source is refused as a precondition, before filesystem work.
- The uploader's `/upload`/`/move` have NO overwrite path (unique names via
  `-_uniquePathForPath:`) — deliberate asymmetry; only WebDAV implements `Overwrite`.
- MOVE/COPY of a collection are vetted by the allow-list at all three sites (both servers) —
  a collection holding non-allow-listed content is unmovable, same accepted cost as DELETE.

### Long-lived surfaces (SSE, Bonjour, lifecycle)

- SSE is per-connection FIFO buffering (`WSKWebUploaderSSEChannel`); EVERY stop path must
  call `-close` on the channel (heartbeat reap, `-stop`, disabling SSE, losing the
  registration race) or a retain cycle strands the connection forever. The channel dies with
  its connection.
- `WSKWebUploaderSSEResponse` also runs its owner cleanup once if discarded before opening,
  including substitution by a conditional 304 or 412. Normal close consumes the callback;
  deallocation invokes only a remaining callback, never the unopened body reader's close.
  Without this fallback, conditional requests filled all 16 slots until heartbeat reclamation.
  Regression bursts of 24 requests per condition must immediately admit a real subscriber,
  before the heartbeat can conceal a leak; explicit close followed by deallocation notifies once.
- One stream per BROWSER via Web Locks + BroadcastChannel; `kMaxSSEChannels` (16) bounds
  browsers, not tabs (six per-tab EventSources once deadlocked the whole UI). HTTP LAN origins
  lack Web Locks because they are not secure contexts; missing or rejected sharing APIs use
  five-second visible-tab polling with zero EventSources. Polls skip busy reloads/editors,
  target `_requestedPath`, and do not overwrite an editor/navigation begun while in flight.
  Background requests time out after ten seconds and fail silently; their timer stops on
  pagehide and resumes on a persisted pageshow. Closing SSE on `visibilitychange` was
  MEASURED worse — do not swap it in.
  Reproduced 2026-09-16 in Chromium 153.0.8010.48 at an actual HTTP LAN address: six old tabs
  held six streams, blocked a download and prevented a seventh tab from loading. Fixed: seven
  tabs hold zero streams, four uploads run alongside a download, and all 8 MiB uploaded match.
  Deep links, edits opened before/during a poll, pending navigation, hidden tabs, timeout/failure
  recovery and actual BFCache restoration pass. Five missing/denied API controls enter polling;
  seven secure-origin tabs still share one stream and relay changes.
  The combined polling/property-preservation change passes `Run-Tests.sh`: 254 ASan tests,
  all eight recorded trace suites, Mac/iOS/tvOS Release builds and both Swift consumer builds.
- `/events` defence: the Origin check PLUS `Sec-Fetch-Mode`/`Sec-Fetch-Site` PLUS
  `Accept: text/event-stream` (Sec-Fetch alone fails open on older browsers).
- Event paths resolve symlinks with `realpath(3)` on BOTH sides — the `/var` vs
  `/private/var` mismatch has bitten THREE methods; treat any new prefix comparison as
  suspect. `-presentedItemURL` hands out the once-captured RESOLVED root and must not
  re-resolve per call (NSFilePresenter needs it stable); `-_relativePathForAbsolutePath:`
  re-resolves on a miss WITHOUT caching back, and compares against `root + "/"`.
- `-bonjourName` reads `_registrationService` (the service that actually registered, which
  carries an auto-rename).
- Bonjour service operations and callback state are confined to `_stateQueue`. Each start
  has a CF-retained callback token with a weak server, so callbacks retained after cancellation
  cannot pin a stopped server or affect a replacement listener. Delegate delivery rechecks the
  token and captures the current weak delegate once on main, after leaving `_stateQueue`.
  Five deterministic tests cover all setup stages, asynchronous errors and success, stale
  events/notifications, delegate replacement/reentrant stop, and callback-context release.
  Notification, generation-guard, stale-service, and strong-context mutants all fail the tests.
- **The iOS background task is acquired at the didEnterBackground TRANSITION, iff connected —
  never at connect time** (a browser holding `/events` open used to pin a task through ordinary
  foreground use, tripping the OS's 30 s advisory). Both suspension modes observe the
  transition. Foreground handlers release via `_releaseBackgroundTask`, never
  `_endBackgroundTask` — the app state still reads background inside willEnterForeground, so
  the latter's suspend-mode stop would kill a server that just survived the round trip.
  Unbuilt possibility, noted 2026-08-18: iOS 26's `BGContinuedProcessingTask` (user-initiated,
  progress-reporting, system progress UI) could extend the drain window for a large in-flight
  transfer. It cannot hold an idle listener or SSE stream open — no progress, no runtime.
  **TLS: considered and parked 2026-08-18.** The shim seam exists (the two dispatch_read/write
  calls), but SecureTransport is deprecated, Network.framework means rewriting the raced-est
  code in the tree, and no CA issues LAN/.local certs — the trust-bootstrap UX is the real
  problem. Tailscale covers Shape A; Digest + the on-screen pairing code covers the LAN threat.
- **Unbuilt design, agreed 2026-08-18 — suspension notice in the uploader page.** On
  didEnterBackground the uploader (observing the UIKit notification itself, iOS-gated)
  broadcasts `{"type":"suspending","secondsRemaining":N}` with N sampled from
  `backgroundTimeRemaining` — the grant is typically ~30 s but NOT guaranteed, so never
  hardcode it. The page shows a corner toast counting down, then a fullscreen blur modal at
  LOCAL zero (accuracy deliberately traded for simplicity); a failed request shows the modal
  early, one liveness fetch on modal-show dismisses a false block, and EventSource reconnect
  dismisses everything. Key constraint that shaped this: **EventSource never surfaces SSE
  comments to JS**, so the `:heartbeat` keep-alives are invisible client-side and silence
  cannot be detected — the farewell event is the only prompt signal. Additive event type
  (unknown names are ignored by old clients). Costs when built: index.js has no test harness
  (Chromium probe against both builds) and the iOS half is simulator-verified. A Live
  Activity cannot hold or receive a connection — display-only, no process.
- All lifecycle mutation and `isRunning`/`serverURL` funnel through the serial `_stateQueue`;
  delegate callbacks are main-thread and OUTSIDE the queue (reading `-serverURL` inside the
  callback would deadlock). Each connection SNAPSHOTS server config at accept. NAT-PMP
  callbacks are confined to `_stateQueue`; `_DNSServiceCallBack` must not re-dispatch.
- **`index.js` has NO test harness** — XCTest is structurally blind to it; every JS change
  must be verified by a Chromium probe against the unfixed AND fixed builds. Do not
  reintroduce a shared reload counter (DOM-derived editor state is the design; the counter
  wedged the page permanently twice, and the "obvious repair" goes negative).
- The rename box is seeded with the real name from `/list` (jeditable otherwise re-escapes
  `&` on every pass).

### Performance (first profiled 2026-08-18; Release, loopback, M-series)

- Baseline after tuning: single-stream GET **~1.8 GB/s** (was 830 MB/s at the old 32 KB read
  buffer; `kFileReadBufferSize` is now 256 KB — the measured knee; 1 MB bought 1.5% for 4× the
  transient memory). PUT ~920 MB/s. Small files 1.3k/3.4k req/s serial (keep-alive off/on) —
  keep-alive remains the cheapest 2.6× any deployment can flip on.
- PROPFIND Depth:1 × 1,000 entries: **~530 ms warm** (was 987) after memoizing the UTType MIME
  lookup in a BOUNDED NSCache (clients mint arbitrary extensions; an unbounded memo is Shape A
  accumulation). The remaining ~0.5 ms/entry is the per-entry xattr probe plus the resolver's
  realpath — the latter is the resolve-once security rule; do not optimize it without its own
  measured pass.
- The buffer change was re-soaked per the response-layer rule: 120 s, 3,349 complete +
  ~8k abortive transfers — descriptors flat, budget 0 at rest, RSS peak 31 MB. Eight
  concurrent 512 MiB streams: 1,587 MB/s aggregate at 20 MB RSS. (That aggregate being LOWER
  than one stream is the kernel loopback path, not the server: a null C server containing no
  WebServerKit falls from 5.07 to 2.87 GB/s across 1 → 8 streams, and WSK converges on the same
  ceiling from 4 streams — measured 2026-09-03. Do not re-investigate it as a server property.) litmus and mount_webdav
  re-taken on the tuned tree, unchanged.
- Perspective: Puck's network ceiling (Tailscale over WiFi) is ~30–60 MB/s; the server is not
  the bottleneck. Benchmarks live in the scratch harness (`bench.py` + `wskhost.m`).
- **Repeatable endurance coverage (2026-09-28):** `Scripts/Endurance/run.py` now checks in
  the mixed-transfer workload. It owns a loopback-only Release host, separate uploader/DAV
  shares and isolated Foundation temp storage. Four incomplete uploads must coexist before
  downloads can complete; hashes, keep-alive reuse, cancellation, If-Range resume and
  changed-file fallback are checked. Stdio metrics add no HTTP connection. Fixed post-warmup
  baselines require zero live connections/reservations, no residual files and no FD growth;
  `phys_footprint` gets an explicit allocator allowance. Ordinary rounds keep the same PID
  and server instances; lifecycle rounds run afterwards and never reset the baselines.
  Reports use append-only JSONL samples and a bounded summary. `Run-Tests.sh` adds a short
  smoke and five fault-fixture checks, including a real-socket transaction-deadline test
  proven red when a close-framed response prematurely cancels its timer.
  Measured: 120 seconds, 65 continuous rounds, 528 completed uploads, 132 cancelled uploads,
  132 resumed downloads, 264 reused connections and 7,952,400,384 hash-verified bytes
  (counts include warmup and the final lifecycle phase). All 2,532 connections released;
  running FDs 8→8, stopped FDs 4→4, reserved bytes zero and no temp/staging residue.
  This is repeatable local evidence, not an overnight or physical-device run. The new Bonjour
  behavior passes five new ASan regressions within the 283-test suite, eight traces, all
  platform/Swift builds, and three real Bonjour registration/stop cycles.
- **Physical iPhone smoke (2026-09-30, hostname fixes `80e64d4` / `714b034`):**
  `Scripts/DeviceSmoke` builds a dedicated synthetic-data host, serves both protocols from
  one share, and copies metrics from its app container instead of an HTTP endpoint.
  iPhone Air / iOS 27.0 (24A437), signed Release with SDK 27.1, Mac Python client on actual
  Wi-Fi: four held multipart uploads and four held DAV PUTs in separate phases, simultaneous
  full/If-Range downloads, cross-server hashes, cancellation, exact named-property listings
  and COPY/MOVE/DELETE all pass. Foreground: 57 requests, 10 uploads including warmups,
  two cancellations, 63,700,992 verified bytes. Idle background/resume: 16 requests,
  34,078,720 bytes; both listeners refuse while backgrounded, same PID/ports serve again,
  and Bonjour Host names work before/after resume. All 75 connections close; idle FDs 11→11,
  reservations zero, no temp/staging residue. Both hostname regressions fail against their
  preceding source; the 303-test ASan suite and lint pass. This is not Windows client,
  permission-toggle, Wi-Fi-loss, active-background-transfer or overnight coverage, and the
  full multi-platform gate was not repeated. Reports: `build/native-device-{transfers,lifecycle}.json`.
- **Shared-folder/listing audit (2026-09-30, production tip `a3799a9`):**
  `Scripts/Endurance/audit.py --seconds 10` runs both servers over one disposable root,
  four mixed uploads and cross-server read/move/copy/delete workflows on distinct names.
  GET, Range and listing completions must occur during client body sends; four-body
  overlap also needs temp files and reserved multipart memory. Immutable catalogs of
  100/1,000/5,000 files are checked for exact JSON/DAV contents. Two repeats alternate
  baseline/listing order after warming the largest directory; metrics sample live
  `phys_footprint` rather than just idle snapshots. Passed: 63,535 completed requests,
  2,817 uploads, two cancellations, 10.56 GiB hash-verified; all 63,537 connections closed,
  descriptors 8→8, zero reservations/residue. Sampled footprint peaked at 59.1 MiB including
  warmup and finished at 8.6 MiB. At 5,000 entries, uploader median 251–262 ms and two-property
  DAV median 850–914 ms; only 11 DAV samples per phase, so no p95 claim. Probe GET/Range p95
  stayed below 1.6 ms in every measured phase. Eighteen runner-oracle tests cover malformed
  local result fixtures, exact resources and concurrency evidence. An earlier warmup had
  an unclassified timeout; simulator/installer and scanner activity were present, but
  causality is NOT established by the passing rerun. Reports now retain request failure
  stage/status/length/bytes/timing, traceback, partial phase metrics and load averages.
  Phase evidence survives sampler/concurrency/settling failures. Both runners now mark PASS
  only AFTER all owned contexts close; cleanup errors are separate and cannot replace an
  earlier failure (including startup and initial upload sends). Follow-up at 5,000 entries:
  23,884 completed requests, 1,073 uploads, two cancellations, 4.02 GiB hash-verified;
  all 23,886 connections closed, FDs 8→8, zero reservations/residue. No repeat timeout,
  but DAV medians varied 1.16–4.46 s (eight/three samples), max 6.69 s; probe GET/Range p95
  stayed below 2 ms. Footprint peaked at 72.7 MiB and finished at 72.2 MiB, 60.7 MiB above
  the fixed warm baseline, within its 64 MiB allowance. Do not call this memory recovery
  or infer allocator caching versus a leak from this short run: latency variability,
  retention and the original timeout remain unclassified. This does not establish same-path
  transaction atomicity, changing-list snapshot semantics, storage-failure recovery or
  physical-client behavior. No production/library or browser changes were made.
- **Serial DAV profile (2026-09-30, same production tip `a3799a9`):**
  `Scripts/Endurance/profile_listings.py` adds bounded listing/idle cycles, all-malloc-zone
  live bytes/blocks and reserved capacity, process CPU, and a separate own-PID stack/leaks
  mode. It keeps the fixed resource baseline and performs optional diagnostic inspection
  before an endpoint-only allocator pressure-relief control. Release arm64 macOS 27.0.1,
  `MallocNanoZone=0`: 45 validated immutable 5,000-entry listings; eight measured batch
  medians 695–707 ms, max 785 ms, 0.380–0.391 CPU s/listing. Warmup still included 6.712 s
  almost entirely before headers; the later warm stacks cannot explain it or the earlier
  timeout. Baseline→final ten-second idle: live bytes 511,344→528,800 (+17,456), blocks
  2,951→2,950, footprint 17.1→16.5 MiB. Idle live bytes first rose to 542,064, then fell.
  Allocator capacity reached 84 MiB in measured cycle three and plateaued (baseline 68);
  pressure relief released zero. This is a bounded serial result, NOT a classification
  of the earlier 72.2 MiB mixed-workload footprint or proof against slower/reachable growth.
  Separate 15-listing instrumented run: zero leaks reported; active PROPFIND stacks most
  often show per-file open, then realpath/classification, with fewer xattr/string/sort
  observations. Sampling includes idle and kernel waits; do not equate its counts with
  uninstrumented CPU percentages. All connections closed, FDs returned to each run's own
  baseline (8/9), no reservations/residual files. Reports and sidecars under
  `build/listing-profile-{timing,diagnostic}.*` retain harness hashes. Twenty-one harness
  tests, the transfer/restart smoke and ObjC lint pass. No production defect established;
  measure individual stages before optimizing, preserving containment and descriptor-based
  metadata coherence. Complete XML plus UTF-8 buffer overlap is temporary by construction
  and these data do not show it leaking. See the endurance README for repeatable commands.

### Style (enforced by `Scripts/lint-objc.py`, run first by Run-Tests.sh)

- clang-format clean (the Xcode toolchain's binary via `xcrun --find` — a bare `clang-format`
  is NOT on PATH here and greps against its absent output read as zero drift once); every `.m`
  paired with a `.h`; every header carries an NS_ASSUME_NONNULL region; an undeclared private
  method must be `_`-prefixed (a method other instances call is a seam — DECLARE it instead).
- Immutable locals are `const` (2026-08-18 sweep: over-apply, let three build flavors reject,
  revert the rejects). **The compiler oracle has a HOLE the sweep fell into**: a consted local
  written through a VARIADIC out-param (`ioctl(fd, FIONREAD, &pending)`) draws no qualifier
  warning, and the optimizer then folds the variable to its initializer —
  `WSKSocketHasUnreadInboundData` silently always answered NO and two drain tests caught it.
  The rule since: no `const` on any local whose address is taken, checked by sweep, not by
  compiler. No compiler rule enforces future const at all; it is convention.
- Designated initializers are annotated; bare `-init`/`+new` are NS_UNAVAILABLE on
  WSKWebDAVServer/WSKWebUploader (source-breaking, deliberate — an uploader without a
  directory is a broken instance).

### API shape

- Public `WSKFunctions.h` is 11 declarations; the fourteen audit-shaped functions (resolvers,
  vetting walks, predicates) live in `WSKPrivate.h`. SPM siblings see it via ONE extra
  `headerSearchPath`; `Framework/Tests.m` needs `WSKResolvedPathIsWithinDirectory` linkable —
  not `static`. The symlink farm, hand-written modulemap and `SWIFT_PACKAGE` bundle accessor
  are load-bearing.
- Implementations split by topic (2026-08-18, pure moves): `WSKPathResolution` (containment,
  `_RealPath`, resolvers, vetting/removability walks), `WSKValidators` (entity tag, seal),
  `WSKMemoryReservation` (budget), `WSKHandler`, `WSKWebServerOptions`; `WSKFunctions` keeps
  the general utilities. Every `.m` has a matching `.h`. The non-user-facing pairs plus
  `WSKPrivate.h` live in `Sources/WebServerKit/Internal/` (quoted imports only — never
  installed in the framework), aggregated by `WSKPrivate.h` so it remains the one prelude
  every `.m` imports. Xcode resolves the cross-folder quoted imports via its headermap;
  SPM needs the explicit `headerSearchPath("Internal")` entries in Package.swift (the
  sibling targets' extra path now points at `Internal/`, not `Core/`). One home per rule is
  unchanged.
- Nullability tells the truth, source-breaking for Swift deliberately (`WSKFileResponse`'s
  three properties, `allowedFileExtensions`, the uploader's five strings, match-block
  addresses) — nil is meaningful in every case.
- **Every public block typedef is `NS_SWIFT_SENDABLE` (2026-09-03, 23rd pass).** Swift 6
  language mode treats a block formed in a main-actor context — top-level code, any view
  controller — as main-actor-isolated unless its type is Sendable, and inserts an executor check
  that traps (`_dispatch_assert_queue_fail`) when a connection queue calls it: every Swift 6 host
  app crashed on its first request to a handler it registered. Swift 5 mode and `{ @Sendable … }`
  closures never saw it. The blocks run on connection queues by design; the attribute states that
  contract. `WSKRequest`/`WSKResponse` themselves are NOT marked Sendable — a nested closure that
  captures the request still warns, honestly.
- **The SwiftPM resource-bundle accessor is named differently by the two generators** (same
  pass): command-line SwiftPM emits `WebServerKitUploader_SWIFTPM_MODULE_BUNDLE`, Xcode emits
  `WebServerKit_WebServerKitUploader_SWIFTPM_MODULE_BUNDLE`, and the code hard-coded the first,
  so an app that added the package in Xcode could not link the uploader at all — while `swift
  build`, the record's "external consumer building clean", never links a library target and
  stayed green. `WSKWebUploader.m` now imports the generated `resource_bundle_accessor.h` when
  the generator puts it on the include path (Xcode does; the old comment claiming SwiftPM never
  does was half right — it is absent under `swift build`, hence the fallback declaration) and
  uses its `SWIFTPM_MODULE_BUNDLE` macro. **The gate for both is `Scripts/SwiftConsumer`**: a
  Swift-6-mode executable package depending on the repo by path, which `Run-Tests.sh` runs under
  SwiftPM's generator and builds under Xcode's. It registers a sync and an async handler from
  top-level code and drives a request through each, plus the page and a CSS asset from the
  resource bundle. Red on the unfixed tree in both flavours (SIGTRAP; undefined symbol). The
  library's own manifest stays at swift-tools-version 5.9; only that check needs Swift 6.
- CocoaPods published every `Internal/*.h` as PUBLIC, `WSKPrivate.h` included: the podspec's
  `private_header_files` still named `Core/WSKPrivate.h` after the 2026-08-18 move and matched
  nothing (`pod lib lint` said so, as a warning). Now `Internal/*.h` and both uploader SSE headers
  are private, and the SPM modulemap no longer exports `WSKWebUploaderSSEChannel`. The version
  strings agree at last: pbxproj `BUNDLE_VERSION_STRING` 3.5.4 → 4.0.0 to match the podspec, and
  the README's SwiftPM line pointed at tag 3.5.5, a pre-rename tree with no manifest. **The 4.0.0
  tag itself does not exist yet** — the podspec's `:tag` and the README's `from:` both need it
  cut on the restructured tree before either install path works.
- `+responseWithFile:` returns nil for empty/NUL paths (`-fileSystemRepresentation` RAISES —
  guard every new call site); `+responseWithJSONObject:` asks `+isValidJSONObject:` FIRST
  (`dataWithJSONObject:` raises, so a nil-guard after the call is dead code).
- The four public date functions initialize via `dispatch_once` — callable before any server
  exists, safe off the main thread.
- Handler registration order is REVERSE match order: register the catch-all FIRST so it
  matches LAST.
- The uploader's clickjacking control is serving ONLY the `css`/`js`/`fonts` asset
  directories — an exact path is never a containment boundary.
- `WSKStreamedResponse` releases its block on `-close` (breaks handler retain cycles).
- `__WEBSERVERKIT_ENABLE_TESTING__` is defined at project level in Debug only, PLUS both
  configurations of the `WebServerKit Example (Mac)` target (Run-Tests.sh builds it Release).
  Do not tidy it to project level (that shipped client-settable timestamps in Release) and do
  not remove it wholesale (that broke all eight trace suites for three passes).

## Settled decisions — do not re-fix

Each was deliberate; full reasons in the archived record (`git show 09416c2:CLAUDE.md`).

- MOVE with no `Overwrite` answers 412 when the destination exists (fresh destination: 201).
- The `//` status disagreement (501 base-path vs 404 DAV) stays — both refuse; cosmetic.
- The directory-rename TOCTOU stays open and was knowingly WIDENED to close the write-verb
  existence oracle (an any-client info leak outranks a race needing rename access inside the
  share). The real fix is an `openat(2)` walk / `O_NOFOLLOW_ANY`, which would also refuse the
  benign intermediate symlinks that work today — do not re-order the checks back instead.
- Collection hrefs advertised without a trailing slash; GET on a collection is a bodiless
  200; a file is also served under a `dir/`-style URI; litmus `propfind_invalid2` fails
  (libxml2 runs `XML_PARSE_RECOVER` by choice).
- Symlink-to-root listing: 200 from base-path, 403 from the other two — adjudicated.
- Case-variant PUT on case-insensitive volumes is inherent (rclone behaves identically);
  a case-only rename via MOVE is refused 403 (an unconditional remove once deleted the only
  copy).
- The lock stub stays a stub; budget exhaustion stays 503 (corrected under Limits); the HEAD-body RFC violation
  (HEAD-map option NO + registered HEAD handler) is recorded, not fixed — fix off the WIRE
  method if it ever becomes reachable.
- Host validation: IP literals by shape, never resolved; no-Host allowed; port comparison
  removed (browsers can only state this server's port).
- The 2 s seal window for unclassifiable filesystems; `x-gzip` decodes, every other
  unsupported coding is 415.
- The trace corpus is never re-recorded wholesale (that blesses current behaviour in bulk);
  fixture rewrites must be PROVEN additive byte-for-byte. WebDAV changes are also driven
  against a real `mount_webdav` client.
- `bootstrap.css` glyphicon 404s are cosmetic. Genuine host-app API-misuse assertions stay
  abort-in-Debug. The out-of-process date oracle lives in the scratch harness, not the suite.

## Still open at tip

Re-measure before fixing any of these — aged findings evaporate roughly 1 in 3.

- **iOS example scene lifecycle (confirmed 2026-09-30):** the example's original app
  lifecycle, when built with SDK 27.1 and launched on iOS 27.0, terminates in
  `UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`. The separate DeviceSmoke
  generator supplies a scene manifest/delegate; the shipping `Examples/iOS` still needs
  that migration. Keep UIKit application notifications for the library's lifecycle handling.
- **The allow-list vetting walk judges a symlink's TARGET, not the alias** — fail-closed
  over-refusal contradicting "symlinks are aliases"; needs an OWNER RULING, not a fix (the
  obvious `lstat` fix re-refuses via `_checkFileExtension:` for extensionless link names).
  Invisible in the default configuration (no allow-list ⇒ walk returns nil).
- **Lingering close** (Core invariants → File serving and connection reuse) fixes the body-loss
  case this line named, and corrects its claim that the status was always safe.
- **From the 2026-09-02 audit: confirmed on the wire, deliberately NOT fixed.** Each was
  reproduced against a live Release build and judged low-value for these deployments; the ten
  that WERE fixed are recorded in the invariant sections above. Grouped so a future pass can pick
  a theme rather than a line.
  - *Advertisement and negotiation.* ~~Neither DAV GET nor uploader `/download`/`/preview` sends
    `Accept-Ranges: bytes`~~ — fixed in 7e6e74f, verified on the wire 2026-09-03. `HEAD` + `Range` answers 206 + `Content-Range` (§14.2
    defines Range for GET only; internally consistent, and `curl -I -r` expects exactly this).
    Opt-in gzip negotiation and variant validators are fixed (see Validators and conditional
    requests). 415 for an undecodable `Content-Encoding` omits `Accept-Encoding`.
  - *Cache metadata.* Generated 304 cache fields are now preserved (see Validators), including
    custom directives and `Vary`; arbitrary additional headers deliberately are not. Other
    non-2xx responses carry no cache metadata, leaving error pages heuristically cacheable;
    `public` is emitted unconditionally with any positive max-age; max-age formats through an
    `(int)` cast (negative above INT_MAX).
  - *Conditionals.* ETag-less wildcard GET/HEAD is fixed (see Validators). On non-GET/HEAD the
    response-side check still runs AFTER the handler, so a 412 can follow a side effect that
    already happened; that check still requires an ETag for If-None-Match matching.
    An unsatisfiable Range bypasses precondition evaluation entirely (416 even when If-Match
    fails).
  - *exFAT + an NFC-spelled name: DELETE answers 500 and the file SURVIVES.* Found 2026-09-02 by
    the normalization pass the audit never owned; PRE-EXISTING (identical on a0de1ac), both
    servers. A file created with an NFC name is stored NFD by exFAT and HFS+ alike. Everything
    else resolves the client's NFC spelling — `GET` 200, `MOVE` 201, `DELETE` of a DIRECTORY 204,
    and HFS+ deletes files correctly too — but on exFAT `-[NSFileManager removeItemAtPath:]`
    answers `NSFileNoSuchFileError` for a path that `lstat(2)` AND `unlink(2)` both resolve
    (proved directly). Foundation and POSIX disagree about whether the name exists: recurring
    shape 6, one layer below where it usually appears. The file is listed and readable but
    undeletable through that spelling, and 500 blames the server for something no retry fixes.
    Finder is unaffected (it deletes via the PROPFIND href, which is the on-disk NFD spelling);
    a client that builds the NFC name itself is not, and NFC is what most web clients normalize
    to. **THE PROPOSED FIX IS REFUTED (2026-09-03).** This entry used to say "remove via
    `unlink(2)`/`rmdir(2)` on the already-resolved path", on the strength of the original probe's
    claim that `lstat(2)` AND `unlink(2)` both resolve the name. `unlink(2)` does NOT. Measured on
    a fresh exFAT image under macOS 26.4's FSKit driver, in pure C, one isolated directory per
    trial, creating by RAW BYTES and looking up by the bytes `readdir(3)` hands back: an ASCII name
    and a CJK name (no decomposition) are removed by BOTH `unlink(2)` and `removeItemAtPath:`; a
    name containing a decomposable character is removed by NEITHER, while `lstat(2)` on the same
    bytes succeeds every time. APFS is clean on all six. So the two primitives fail identically and
    no choice at this layer can fix it — it is an OS defect, not one of ours. The tree now calls
    `unlink(2)` anyway (see `WSKRemoveItemAtPath`), which changes only the reported status: the
    errno is ENOENT, so such a DELETE now answers 404 rather than 500. Both are wrong about a file
    that demonstrably exists — a GET of it answers 200 — but 404 is what the OS said and stops
    blaming the server. A DIRECTORY containing such a member now answers 204 with the tree renamed
    aside and a logged, dot-named remainder that the driver will not let anything delete. **OWNER
    RULING 2026-09-02, and now better founded: not worth fixing.** It needs three things at once — an exFAT share (APFS
    and HFS+ are both fine), a name with decomposable non-ASCII characters, and a client that
    builds the NFC spelling itself rather than using the one the server listed. Neither deployment
    shape can reach it: Shape A vends from APFS, and Shape B is iOS, which has been APFS-only
    since 10.3. Against that, the fix swaps the primitive under the most destructive verb in the
    library, behind a partial-destruction guard built precisely because `removeItemAtPath:`
    deletes as it walks — and this codebase's measured rate is ~1 new defect per 5 fixed,
    clustered in what the fix touched. Revisit only if a share on removable media becomes a real
    configuration, and then together with the ENAMETOOLONG status question, which is the same
    "a filesystem error is not a server fault" decision.
  - *Multipart part-header normalisation.* Already fixed: `WSKNormalizeHeaderValue` uses
    `NSLiteralSearch` for `;`, preserving filename case beside a combining mark. The uploader
    regression remains in place; this stale finding was corrected on 2026-09-28.
  - *Framing and dispatch corners.* `Transfer-Encoding: identity` alone is processed as "no body"
    rather than the 400 §6.3 rule 3 owes (both in-tree handlers fail closed: 411/403). Legal BWS
    before a chunk extension (`5 ;x=y`) answers 400. Two or more empty lines before the request
    line answer 400 (one is skipped, per §2.2's "at least one"). An authority-form or opaque
    target (`GET example.com:443`) is dispatched as `/` rather than refused. `Expect` is compared
    as a whole value, not a list. Client EOF mid-request is answered and LOGGED as a fabricated
    500 rather than treated as the disconnect it is.
  - *Security-adjacent, judged acceptable on a trusted LAN.* **Unmatched requests (the 404/501
    path) bypass Host validation, the auth preflight and the PUT `Content-Range` refusal** — on an
    auth-enabled server an unauthenticated client can still distinguish "method registered" from
    "no handler anywhere" (404 vs 501) and reach DAV OPTIONS. Digest is qop-less RFC 2069 (so no
    nc/cnonce, so no replay counting — a captured header is reusable for the nonce's 300 s
    lifetime), `stale=TRUE` is asserted without validating the presented credential, the
    auth-scheme token is compared case-sensitively, non-ASCII usernames cannot work (Latin-1
    header decode vs UTF-8 HA1), and unknown-username short-circuits measurably.
  - *WebDAV.* Named PROPFIND namespace matching and unavailable-property statuses were
    fixed on 2026-09-28 (see WebDAV invariants above). PROPPATCH flattens dead-property
    VALUES to text (child elements, attributes, `xml:lang` lost); duplicate instructions for one
    property repeat the element inside one propstat; PROPFIND of a FIFO/socket returns a 207 with
    zero responses instead of 404; COPY/MOVE never produce the §9.8.3 207 for a member failure
    (every non-ENOSPC errno becomes 403, and a partial destination can be left behind); Depth:0
    COPY of a collection drops its dead properties; a path-absolute `Destination` treats a query
    string as literal filename characters; LOCK refresh (bodiless LOCK) answers 400; PUT carrying
    a `Range` header answers 400 where §14.2 wants it ignored; MKCOL evaluates no preconditions;
    `getlastmodified` publishes a date from one stat while judging the seal on a second.
  - *Uploader and lifecycle.* `/events`' triple defence is bypassable by a pre-Sec-Fetch browser
    (a no-cors GET with `referrerPolicy: no-referrer` sends neither Origin nor Referer, and the
    Origin check only refuses when an authority was extracted); the `Accept` gate passes when the
    header is ABSENT (zeroed-NSRange shape). The 129th connection at the cap is accepted and hard
    -closed (usually RST, never an HTTP status). The Bonjour registration callback's former
    `_resolutionService` race is fixed with state-queue confinement and per-start callback
    identity (see Long-lived surfaces). Response-phase progress is
    measured per write-buffer completion, so a reader slower than ~bufferSize/timeout can be cut.
    ~~Promoted to a P1 for Shape A.~~ **Fixed 2026-09-04** — see the invariant under Limits. The
    quantification below stands as the reproduction recipe:
    at the default 30 s idle, readers
    at 5–8 KB/s on a 20 MB file are cut at ~120 s after ~0.6–0.95 MB — exactly the socket send
    high-water mark at that instant — while reading continuously; `-idle 5` moves the band to
    20–40 KB/s (it scales as buffer ÷ timeout); race-dependent, so non-monotonic (5 KB/s survived
    one run and died the next). Mechanism, confirmed with `netstat -anv`: the kernel send buffer
    auto-grows toward 4 MB, and a `dispatch_write` that stays pending across two ticks registers
    zero progress because progress is counted at write COMPLETION. A phone on a Tailscale relay
    path pulling a build is exactly this client; it is also the cause of the CI flake. Fix: count
    movement of `_totalBytesWritten` (bytes the socket accepted), or exempt a connection whose
    only pending I/O is a partially drained outbound write.
    The query/form parsing findings were fixed on 2026-09-28; see Headers and framing.
- **ENAMETOOLONG answers 500, both servers.** A filename ≥ NAME_MAX (a 300-char component
  measured 500 on `/upload` AND WebDAV PUT) is client-supplied input the filesystem cannot store,
  so 4xx is owed, not a server fault. Not fixed with the disk-full pass deliberately: the status is
  a genuine choice (400 vs 414 — the name is in the URI for WebDAV but in the body for the uploader,
  so one shared answer is 400), and adding it to `WSKServerErrorStatusCodeForError` turns that
  function from "server error mapper" into a client/server mapper, which is a contract change worth
  its own decision. No leak — measured 0 temp residue, fds flat, server alive across 15 in a row.
- **The uploader answers 404/501 for a wrong method on an existing endpoint, never 405+`Allow`.**
  Measured: `GET /upload` 404, `POST /list` 404 (methods with SOME handler fall through a catch-all),
  `PUT`/`DELETE`/`OPTIONS`/`TRACE` and `OPTIONS *` all 501 (no handler anywhere). RFC 9110 wants
  405 with `Allow` when the resource exists but the method is not supported. Low value here —
  trusted network, the uploader's own JS client always uses the right method, and it rejects
  cross-origin so OPTIONS preflight is not part of its design — and a real fix means per-path
  `Allow` generation in the match-block router (WSKWebServer core), which is disproportionate.
  Recorded, not fixed. The WebDAV server already does 405+`Allow` via `_MethodNotAllowed`; this is
  the uploader surface only.
- Phase 2's low-value structural tail: URI-to-path derivation; the limits/constants.
- ~~litmus `props` not re-run since the five new PROPFIND properties~~ — **done 2026-08-18**,
  against a live tip server (litmus 0.14 built from source; build recipe:
  `./configure CFLAGS=-Wno-implicit-function-declaration`, run the suite binaries directly —
  `make check` stops at the first failing suite): basic 16/16, copymove 13/13, **props 29/30
  with the sole failure the settled `propfind_invalid2`**, locks 3/3, http 4/4. The nine
  published properties are now conformance-verified, not merely measured-correct. The same
  pass drove the 19th/20th/21st-pass fixes live with a 39-check matrix proven sensitive
  against pre-fix builds (18 failures at 58b7469, exactly the `<propname/>` duplicate at
  ca07ce8), verified the uploader's 507 on a genuinely full 4 MB HFS+ image (zero residue,
  controls green), and exercised the post-refactor SSE machinery (16-channel bound, 200 +
  `retry: 30000` refusal stream, reclaim on next failed write).
- Verification gap: the duplicate-`webServerDidStop:` fix is `#if TARGET_OS_IPHONE` and the
  Mac suite is structurally blind to it; only the single delivery site is established.
- **REFUTED 2026-09-02 — plausible on paper, killed by measurement. Do not re-find these.**
  - *HTTP date formatters are NOT vulnerable to the user's 12/24-hour override.* The four
    formatters use `en_US` rather than `en_US_POSIX`, which looks like the classic QA1480 bug,
    but the ICU rewrite consults the preference snapshot attached to the formatter's LOCALE
    OBJECT and an explicitly-allocated locale carries no user prefs — POSIX-ness is not the
    operative distinction. Proven with the oracle validated first: under
    `AppleICUForce12HourTime=1` a current-locale control corrupted to "2:23:45 PM" and failed to
    parse, while the shipped construction stayed byte-correct on macOS and on iOS 18.6 and 27.0
    simulators. A `th_TH` Buddhist-calendar control was likewise unaffected.
  - *Exact-case header subscripting is safe.* `CFHTTPMessageCopyAllHeaderFields` canonicalizes
    every parsed tchar name generically, so `if-match:`, `iF-nOnE-mAtCh:` and `range:` all reach
    the exact-spelling lookups (wire-proved: lowercase `if-match` still produced 412, lowercase
    `if-range` still suppressed the range). The two in-code comments claiming otherwise overstate
    CF's behaviour. **Mechanism corrected 2026-09-03 (outcome unchanged):** CF canonicalizes only
    names it KNOWS — `depth`, `destination`, `overwrite`, `te`, `if-unmodified-since` keep the wire
    spelling, and a case-variant duplicate keeps the LAST spelling. The lookups work because the
    returned `__NSCFDictionary` has case-insensitive key callbacks, which `-copy`/`-mutableCopy`
    preserve and `+dictionaryWithDictionary:` (a re-hash into a plain NSDictionary) or a Swift
    `[String: String]` silently drop — any such copy makes every exact-spelling lookup
    case-sensitive. The tree never re-hashes today; the comment at `WSKConnection.m:1217` ("will
    standardize the common ones") is the accurate statement.
  - *EMFILE does not busy-spin the accept source.* GCD's READ source fires once per arrival, not
    per level condition: 200 connections held in a starved backlog for 10 s produced exactly 200
    error lines and 20 ms of CPU. XNU's `accept` also dequeues and CLOSES the pending connection
    on EMFILE, so nothing survives to refire on. Self-recovering.
  - *U+FFFE/U+FFFF in a filename cannot reach the XML writer.* APFS refuses creation (EILSEQ),
    and exFAT/HFS+ percent-encode the name in the kernel, so the enumerator never sees one.
  - The `If:` header being ignored, LOCK on an unmapped URL answering 404, and UNLOCK answering
    204 for any token are RESTATEMENTS of the settled lock-stub decision, not findings.
- **From the 23rd pass (2026-09-02/03; eight agents with live rigs, every P1 reproduced twice) —
  confirmed on the wire; the two WebDAV P1s are fixed, the remainder is not.** Full report: the
  "WebServerKit 23rd Pass" artifact.
  **Both WebDAV P1s are now FIXED and merged (2026-09-03)** — the `}`-in-namespace poisoning and the
  qop-less Digest challenge; each is recorded as an invariant, under WebDAV and under Headers and
  framing respectively, and each was re-measured live at tip before being touched (0 of the 11
  items probed that day had evaporated, and the PROPPATCH race was WORSE than recorded). Also
  already fixed: the two quadratic parsers and the loopback 413 (`fix/parsers-linear`, under
  Headers and framing) and the Xcode-generator link failure, the Swift 6 trap, the pod's public
  Internal headers and the version strings (`fix/packaging`, under API shape). One correction the
  P1 work forced: the Digest finding claimed its fix "also closes the recorded no-nc/cnonce replay
  item" — it does NOT, and the invariant entry says why. **Re-verified 2026-09-04 against 49084f0** (four agents re-ran every original probe on a
  host built from tip; the orchestrator reproduced the P1 verdicts): all four merged fixes HOLD with
  no over-refusal (24 namespace spellings, 45 Digest cases, both SwiftPM generators with each oracle
  proven sensitive on the pre-fix tree), every unfixed item below is STILL PRESENT and unchanged in
  mechanism, every regression sweep held, and the pass surfaced the NEW items marked ★ plus the
  calibrations in the last sub-bullet. What remains, in the suggested order:
  - *WebDAV.* ~~(P1) A property namespace URI containing `}` poisons the dead-property store.~~ ~~(P1) The
    qop-less RFC 2069 Digest challenge.~~ Fixed 2026-09-03; invariants under WebDAV and under Headers
    and framing. Both findings needed a correction: the namespace one blamed this code for what is
    libxml2's own escaping of `&` inside `ns->href`, and the Digest one did not mention that
    `qop`/`nc` arrive UNQUOTED, which is what actually broke the first attempt.
    ~~★ (P2) A namespace URI containing WHITESPACE.~~ Fixed 2026-09-04, and the finding was NARROWER
    than the defect: whitespace is six of the twelve spellings NSXMLDocument refuses, so the rule is
    "is it a URI" (`xmlParseURI`), not a character list. Invariant under WebDAV.
    ~~(P2) Concurrent PROPPATCHes lose updates while both answer 200.~~ Fixed 2026-09-05 with a
    per-server lock; 60 concurrent patches stored 1 before, 60 after. ~~(P2) MOVE/COPY do not honour alias semantics for a DANGLING alias.~~ Fixed 2026-09-05 via
    `_NamedEntryExistsAtPath`; it also corrected a pinned expectation that only held because the
    destination read as absent. ~~(P2) Bodiless 2xx responses state no
    `Content-Length`.~~ Fixed 2026-09-05, narrower than proposed: it keys on `-hasBody` (an
    unknown-length body to an HTTP/1.0 client is framed by the close, so announcing 0 over it
    desyncs) and on 2xx only (a bodiless 404 stating its length became keep-alive-eligible,
    breaking the settled "every refusal closes" property). The trace corpus cannot see
    `Content-Length` in either direction — verified — so its 31 updated fixtures are documentation,
    not enforcement. Original finding: (`WSKConnection.m:939`; `_StatusDelimitsItself` `:573` covers 1xx/204/304
    only), so on a keep-alive server every DAV OPTIONS, MKCOL, COPY/MOVE 201 and collection GET
    closes the connection — the sibling of the 304 fix one status class over; Finder's own
    `Content-Length: 0` on OPTIONS/MKCOL/MOVE/DELETE additionally excludes those requests on the
    request side (the deliberate structural line). Fix: `Content-Length: 0` on a bodiless
    response whose status is not 1xx/204/304 (a serializer change → the proven-additive corpus
    edit). P3: LOCK `lockroot` href is `http://host//path` (`:2273`) and `<D:timeout>` echoes
    the whole list (`:2265`); RFC 4331 quota properties answer 404 so `df` and Finder's Get Info
    show a zero-byte volume (fix: `statfs` on the share root); chunked empty-body MKCOL → 415
    (`:1010` tests `contentLength > 0`, the chunked sentinel); `PUT /` and `MKCOL /` → 403 while
    other collections get 405; a named PROPFIND matching no live property emits an empty 200
    propstat before the 404 one; no `MS-Author-Via`. Hypotheses, unmeasured: a case-only MOVE
    may be safe to allow now that MOVE stages (`:1340` predates staging); `-allowHidden` mount
    sessions would litter `._*` AppleDouble files; the allow-list vetting walk reaches THROUGH a
    symlink-to-directory destination on overwrite (a fourth site of the "walk judges the
    target" ruling).
  - *Connection.* ~~**(P1 for Shape A) The slow-reader cut.**~~ Fixed 2026-09-04; the CI flake it
    was also causing should go with it (`testPipelinedRequestIsNotReclaimedWhileItsResponseIsStillStreaming`
    failed half its runs on its own control assertion, which was this cut on a slow runner).
    ~~★ (P2) An UNTERMINATED chunk-size line is rescanned in full on every read.~~ Fixed 2026-09-04
    with a trailer sibling the finding did not name; 2.80 ms/read, not the ~6 ms first recorded (a
    loaded machine). Invariant under Headers and framing.
    ~~(P2) An async handler that KEEPS its completion block and never calls it holds its slot
    until process exit even after the client disconnects.~~ **Fixed 2026-09-06, and the recorded fix
    direction was wrong.** "Post a one-byte read while a handler is outstanding" would have detected
    the EOF and changed nothing: the descriptor is closed and `-didEndConnection:` sent from
    `-dealloc`, and during an async handler the completion block is the connection's ONLY strong
    reference — which is exactly why a handler that DROPS its block already frees the slot and one
    that keeps it never does. Detecting is not reclaiming.
    That ownership is right (a legitimately slow handler must keep its connection alive), so it was
    made REVOCABLE instead: the block captures a `WSKConnectionTicket` holding the strong reference,
    the connection holds the ticket weakly, and the idle timer revokes it when `recv(MSG_PEEK)`
    reports the peer has gone. Revoking drops the last reference and the connection deallocates as
    if the block had been dropped; a later call finds nil and does nothing. `MSG_PEEK` so a
    pipelined next request is not consumed. Measured: 120 clients requesting such a route and
    disconnecting left **122 sockets held before and 2 after**. Safe to revoke from inside the timer
    because its handler reads a WEAK self, which ARC holds strongly for the call.
    **Correction 2026-09-13:** that fix covered only a pending handler with an empty receive
    queue. Three P2 siblings remained: completed callbacks kept their tickets, response-reader
    callbacks captured both the connection and its final write completion, and queued next-request
    bytes hid FIN from `MSG_PEEK`. The async-callback invariant under File serving and connection
    reuse now covers all three; response cancellation also guards late gzip callbacks before
    they can encode against a closed stream.
    The one thing it costs: a client that half-closes and still expects its response. That shape was
    already treated this way wherever a read was outstanding, and this is the phase where no read
    exists to carry the same outcome. "Handler time never counts" stays right for the idle timer. (P2)
    Three lifecycle edges: `[::]:port` held elsewhere while `0.0.0.0:port` is free aborts the
    whole start with EADDRINUSE and closes the good v4 listener, never naming the family
    (`WSKWebServer.m:829-840`; fix: v4-only with a warning, or name the family);
    ~~a NEGATIVE `ConnectionIdleTimeout`/`ConnectionKeepAliveTimeout` passes `_ValidateOptions`
    and can disable idle reclamation~~ — **fixed 2026-09-16**, together with nonfinite and
    out-of-range values; supported bounds are under Deployment requirements. `addHandler…`/
    `removeAllHandlers` while running SIGSEGVs in Release (3/3) because the unlocked
    `_handlers` mutation (`:448-457`) races the accept-time copy (`WSKConnection.m:1435`) —
    Debug aborts by design; fix: guard both under `_syncQueue` so misuse is a benign no-op.
    (P3) `webServerDidCompleteBonjourRegistration:` fires 2–3× per start, once per resolved
    address (`:477-493`). (P3, efficiency, not defects) `_dateFormatterQueue` is a measurable
    serialization point (~280k formats/s cap; one worker in six waiting at saturation) but
    costs ≤6 % at any reachable rate; ~470 µs of CPU per static 4 KB GET, dominated by
    `attributesOfItemAtPath:` (getattrlist/xattr 18 %) and per-chunk 256 KB buffer churn —
    invisible at LAN or tailnet rates. (P3) In-memory request classes send `100 Continue` for
    a declared `Content-Length` they cannot hold and accept up to the cap before 413; a 4 GiB
    declaration parks the slot until the idle window with no status at all
    (`WSKDataRequest.m:44-51`, `WSKConnection.m:1297-1301`; fix: refuse in `-[WSKDataRequest
    open:]` before the `Expect` branch, beside the Content-Encoding check). (P3) Request-target
    leniencies, none browser-reachable: `GET ?q=1` dispatched as `/`; `//sub/file` parsed as
    authority + path; `https://`, `ftp://` and userinfo absolute-forms accepted; `Host:
    [1.2.3.4]` and port 99999 admitted (`WSKConnection.m:1612, 1229, 315, 420`). Nits:
    `Connection: disclose` closes (substring test at `:605`); `Keep-Alive: max=100` but 101
    served; base-path text/html and text/plain carry no charset; chunked trailers are not
    validated; the header goes out as `Etag`; `Range: bytes=0-18446744073709551615` is ignored
    (the sentinel).
  - *Host-app safety, docs, hygiene.* ~~**(P1) Changing a host-settable property while the server
    runs is a use-after-free.**~~ Fixed 2026-09-05: the six object-typed properties are `atomic` AND
    read through the getter, which is the half that matters. Scalars stay `nonatomic` — nothing to
    free. Verified by DISASSEMBLY, not by a crash: a million walks against forty thousand frees
    under MallocScribble and then guard malloc never faulted, while the read went from a bare ivar
    load to five retain/getProperty calls. Verify future changes here the same way. Original
    finding: `allowedFileExtensions`, `allowHiddenItems`, `title`/`header`/
    `prologue`/`epilogue`/`footer`, `fileCacheControlMaxAge`, `serverSentEventsEnabled` are
    plain nonatomic ivars read on connection threads (`WSKWebUploader.m:880-1633`,
    `WSKWebDAVServer.m:285-2107`) and the headers state no set-before-start rule. Release, a
    thread flipping `allowedFileExtensions` every 1 ms under 16 listing clients: dead in 4–6 s
    (SIGSEGV or uncaught NSException in `WSKEntryPassesExtensionAllowList` ← `listDirectory:`);
    every 1 s → roughly 1 % per flip. Not remotely triggerable; a Shape B settings screen is the
    exposure. Fix: atomic accessors or a per-request snapshot for the object-typed properties,
    or document set-before-start and assert in the setters. (P2) Access-log CRLF/ANSI injection
    via the percent-decoded path: `-_flushRequestRecordAndLog` (`WSKConnection.m:2655`) logs
    `_request.path` unsanitised, so `/a%0d%0aFAKE…` forges a line and `%1b%5b31m` drives the
    operator's terminal (the HTML reflection of the same path IS escaped). Fix: strip or
    re-encode C0 and DEL at that one site. (P2) A sandboxed macOS host fails to start with a
    bare `NSPOSIXErrorDomain 1` and nothing documents `com.apple.security.network.server` (plus
    `network.client` for NAT-PMP and Bonjour resolution) — Shape A is a sandboxed GUI app.
    (P2, UX) The uploader's trash icon deletes on ONE click with no confirmation and no undo
    (`index.js` has no confirm anywhere), beside the move icon, on a phone. (P3) Uploader
    `/create`, `/upload`, `/move` answer 500 for a client-named missing parent — ENOENT is not
    in `WSKServerErrorStatusCodeForError` (`WSKWebUploader.m:1747, 1391, 1538`); DAV answers
    409 for the same. (P3) The extension allow-list (uploader `:1324`, DAV PUT
    `WSKWebDAVServer.m:791`) and `_rejectIfCrossOrigin:` (`:1293`) run only AFTER the whole
    body: with `Expect: 100-continue` a refused 100 MB PUT or upload and a cross-origin POST all
    receive `100 Continue` and stream everything before the 403, while auth, 415 and
    Content-Range refuse with 0 body bytes; the DAV PUT name and the Origin are knowable
    pre-body, so move those two into `-preflightRequest:` (the uploader's filename genuinely is
    not). (P3) Bundle assets are `cacheAge:0` (`WSKWebUploader.m:230-234`) and
    `fileCacheControlMaxAge` never reaches them; nothing is gzipped (jquery.min.js 87 KB raw);
    the JS client shows only the reason phrase on failure (`_showError(…, errorThrown)` discards
    `responseText`), and uploads are one un-chunked, un-resumable POST per file, strictly
    sequential, with no retry. (P3) `-[WSKDataResponse initWithHTMLTemplate:variables:]`
    substitutes verbatim with no HTML escaping and the header does not say so
    (`WSKDataResponse.m:137`; the uploader defends by hand). ~~(P3) A huge idle timeout
    saturates the nanosecond conversion and keep-alive ≥ 2^31 overflows its integer header~~ —
    **fixed 2026-09-16** by validating the timeout range before startup.
    `_ScanHexNumber`'s "cannot overflow" holds only on LP64. (P3) `Examples/tvOS/
    Info.plist` lacks `NSBonjourServices`/`NSLocalNetworkUsageDescription` although the example
    advertises Bonjour; `Examples/iOS/Info.plist` declares `UIRequiredDeviceCapabilities =
    armv7` on an arm64-only app; the Mac example hard-codes port 8080, and its Debug `Delete
    WSKWebUploader.bundle` script phase (no outputs) alternates with CopyFiles so every SECOND
    Debug build ships without the bundle and `-mode webUploader` exits −1 silently. Warnings:
    the two dead flags `-Wno-implicit-int-enum-cast`/`-Wno-implicit-void-ptr-cast` (four
    `WARNING_CFLAGS` blocks) emit 2 per compiled file, hiding 4 real framework warnings and 2 in
    the tests (`WSKServerLifecycleTests.m:413` shadow, `WSKAuthenticationTests.m:206` gnu `?:`);
    CI's warning step counts them but is `continue-on-error`. Docs: README carries ~20 stale
    statements (swisspol URLs, `WSKWebServer` pod names, `import WSKWebServer`, `runWithPort:`,
    "keep-alive not supported", a Carthage section, samples at L451/L470 that do not compile)
    and nothing on `AllowedHostNames`, the idle/keep-alive timeouts, hidden items,
    `isVirtualHEAD`, `#` → `%23`, atomic publishing, iOS client local-network keys, App Sandbox,
    the tvOS storage rule, background serving, the two-server composition, `_webdav._tcp`, or
    `reservedInMemoryByteCount` as the Shape A health metric — a "Deployment" section
    transcribed from "Deployment requirements" above would cover it. Hygiene:
    `docs/superpowers/` (two tool-generated plan/spec files) is TRACKED against the
    never-commit-tool-artefacts rule; `Serve.xcodeproj/` is an unignored rename leftover that
    `git status` hides because its only contents match ignore rules; `Tests (Mac)` deployment
    target is 14.6 against 12.0 everywhere else; LICENSE years disagree with the headers; CI
    runs macos-15/Xcode 16.4 with `actions/checkout@v4` deprecation warnings and no caching; the
    4.0.0 tag the podspec and README now both name does not exist yet.
  - *Found by the 2026-09-04 re-verification, not in the original report.* ★ (P3) Swift can call
    the OPTIONAL `-asyncReadDataWithCompletion:` on any `WSKResponse` subclass unconditionally —
    `WSKBodyReader` marks it `@optional` (`WSKResponse.h:74-83`) and the library's own callers guard
    with `respondsToSelector:` (`WSKResponse.m:72,82,384`), but Swift imports the requirement onto
    the conforming class without an optional chain, so `response.asyncReadData { … }` on a
    `WSKDataResponse` raises `NSInvalidArgumentException: unrecognized selector` (exit 134). A host
    writing its own body-reader chain (an encoder, a progress wrapper) meets it; the Sendable
    attribute on that very block is what now invites the call. Fix: **NOT the base implementation on
    `WSKResponse` this first suggested** — the three guards read `[_reader respondsToSelector:]`
    (`WSKResponse.m:72,82,384`), so adding one makes `hasAsyncReader` true for EVERY response and
    flips the connection layer onto the async path for all of them, with a synchronous callback per
    chunk; that is the stack-recursion shape the multipart parser already carries a lesson about.
    Document `responds(to:)`, or give the async path a signal that is not "does it respond". (nit) A multipart EPILOGUE larger than 16 MB after the closing
    boundary accumulates in the End state and answers 413 rather than 200; no residue, unreachable in
    practice. (nit) `Scripts/SwiftConsumer` leaves its temp directory behind on a RED run only
    (`defer` does not run past `exit(1)`). **Calibrations, each measured:** the body-drip floor is
    ~34 B/s, not "exactly 32" — `kMinReceiveBytesPerSecond` (32) × the tick, minus the idle timer's
    `interval / 10` leeway (`WSKConnection.m:1451`), so a deadline-scheduled 33 B/s sender was cut
    and 34 survived; a test pinned to 32 will flake by exactly this. A gzip request bomb answers
    **503**, not the 413 the security report recorded — the decompressed-length check is a strict
    `>` at 64 MB, so the buffer tries one more growth step and the process-wide reservation fails
    first (`ServerAtCapacity`); refused either way, reserved returns to 0. The F7 `-idle 5` survival
    boundary moved from "52 KB/s survives" to "52 KB/s cut" under load 300 — the threshold is a
    race, so verify any fix by MECHANISM (progress counted at bytes the socket accepted), never by
    a rate table. Scaling re-taken on a quiet machine (load 4.5): 3,983 / 14,997 / 11,346 req/s at
    1.0 / 6.7 / 7.1 cores for c = 1 / 8 / 32 — the same shape as the pass.

## Lessons (the ones that cost real time)

- **The record itself is the most dangerous artefact**: this file asserted properties the
  code did not have at least six times. When closing a class, check EVERY site it can occur
  at before writing "closed"; a correction is worth more than the claim it corrects; never
  quietly delete the history of being wrong.
- **Fixes are hypotheses**: ~1 new defect per 5 fixed, clustered in exactly what the fix
  touched. Ask what a fix now REFUSES, DUPLICATES, or COSTS (one correctness fix introduced
  a 153× CPU DoS). Apply the fix and re-run the ORIGINAL probe, never just the suite.
- Re-measure before acting on any recorded finding — findings age against a moving tree.
- Run every new regression test against the UNFIXED source first; for new capability, delete
  the specific line the test is about and confirm it fails. A test whose subject can be
  deleted while it stays green is measuring something adjacent.
- **A status assertion written as `containsString:@"304"` searches the WHOLE response** — headers
  and body — so it also matches an entity tag (`"85948824/6/1788413461/54649089"`), a
  `Content-Length`, or a date. Found 2026-09-05 when two `WSKValidatorTests` assertions failed a
  full-suite run and passed in isolation, reporting `HTTP/1.1 200 OK` as their evidence that the
  reply "contained 304". The nine NEGATIVE assertions built this way (the ones that fail at random)
  now use `ReplyHasStatus(reply, 304)`, which reads the status line only. **The 73 positive ones were converted
  2026-09-05** (`XCTAssertTrue([reply containsString:@"200"])` and friends): those failed the other
  way — they PASSED when the digits appeared somewhere else, hiding a defect rather than inventing
  one. Two categories were deliberately NOT converted, and that distinction is the useful part: an
  assertion naming a status WITH its reason phrase (`containsString:@"403 Forbidden"`) is checking a
  `<D:status>` line inside a 207 multistatus BODY, which is a different question from the response
  status, and the reason phrase makes it unambiguous where a bare three-digit string is not. The one
  site that had to be reverted proves it: the 507 in
  `testDAVProppatchBoundsCumulativeDeadPropertyStorage` is reported inside the 207, not as the
  response status, so converting it broke the test. A test oracle that can match anywhere
  in its input is the same shape as the library defects this record keeps finding.
- **Read the executed count, never the failure count** — a crashed runner reports
  "Executed 0 tests, with 0 failures". A test total that doesn't match expectation is a STOP
  signal (a four-day-old stale log once read as a passing run — use fresh log filenames).
  `Run-Tests.sh` stops at the first failure, so "the suite ran" ≠ "the corpus ran".
- A green oracle you have not proved sensitive proves nothing — inject the defect first. A
  RED from an unvalidated oracle is worth exactly as much as a green. Ask what configuration
  the defect NEEDS (a real defect read 0 at realistic timeouts until the reads were paced).
  **The library you reach for to CHECK conformance may not check it.** `NSXMLParser` accepts an
  undeclared namespace prefix even with `shouldProcessNamespaces = YES`, so it stayed green
  against a response that was not XML at all — the exact defect under test. The replacement
  asserts every prefix used in the body is declared in it, and was proven sensitive (3 failures
  became 6, the new ones being the corrupted listings). Prefer an oracle you can state as a rule
  over one you inherit from a framework.
- **A predicate can answer differently on the same bytes.** `-hasPrefix:@"."` depends on which
  NSString subclass holds the string: `NSPathStore2` (what `-lastPathComponent` returns) says NO
  where `__NSCFString` says YES, on identical UTF-16. Nothing warns, both look correct in
  isolation, and the disagreement only appears where the two representations meet. When a rule
  must hold everywhere, read the primary source (a code unit, a `struct stat`) rather than asking
  a convenience API — and give the rule one home so the question is asked once.
- Verify batches together, not per-fix; periodically run every technique family against tip.
- `-stop` is NOT a barrier over connection teardown — poll for the event, never read state
  straight after `-stop`. Two timing tests flake under load — and a THIRD,
  `testPipelinedRequestIsNotReclaimedWhileItsResponseIsStillStreaming`, is the one that actually
  fails CI (8 of the last 30 runs as of 2026-09-03, half of them on its CONTROL assertion: the
  slow-reader cut on a slow runner; it passes locally 3/3). Re-run a failure in isolation
  before believing it. Don't overlap `Run-Tests.sh` with a running soak (SIGSTOP it).
- **`Run-Tests.sh` can exit 70 with every test green.** Xcode's tvOS destination enumeration
  flaps on a machine with no tvOS SIMULATOR RUNTIME installed (the SDK alone is not enough):
  `generic/platform=tvOS Simulator` intermittently resolves to nothing and the script fails after
  the test phase. Observed alternating on the SAME tree within minutes, and the tvOS Release build
  succeeds when invoked directly. Diagnose it the way any other failure is diagnosed — run the
  step standalone, and run it on a clean `main` worktree as a control — rather than assuming
  either "environment" or "my change". Installing the runtime restores the gate's meaning.
- **A comma inside `[]` splits an XCTest macro's arguments** (parentheses protect, brackets do
  not), so `XCTAssertFalse([x containsString:[NSString stringWithFormat:@"a%lu", n]], …)` fails to
  compile with errors pointing anywhere but the comma. Hoist the expression into a local. Fifth
  recurrence; the existing tests carry the same warning about dictionary literals.
- Warning counts need a clean `-derivedDataPath` and must include the TESTS target; the bar
  is ZERO compile warnings across `build-for-testing`.
- Measure memory with `phys_footprint` or `leaks(1)`, never `resident_size` (page cache grew
  it to 3 GB in a provably leak-free process).
- The recorded WebDAV sessions are STATEFUL — replay them in sequence or the oracle lies.
- When a subsystem's finding yield flattens (3 → 3 → 1, later findings self-inflicted), STOP
  auditing and buy an independent oracle (litmus) instead of writing another probe.
- Orchestration: `git stash` is repo-wide — never stash with a fleet live; stage by naming
  paths, never `git add -A`; writing agents need worktree isolation; concurrent builds need
  their own `-derivedDataPath`.
- A second-opinion agent is differently blind, not more reliable (~1-in-3 finding survival);
  it gets the MECHANISM wrong more often than the symptom — re-verify before relaying.
- Extensive negative results exist (soaks, split-invariance, conformance, TSan triage — the
  4 `-stop` races are FALSE positives, do not "fix" them). Added 2026-08-18: clang static
  analyzer CLEAN (Mac + iOS, all 22 `.m` files walked) and ASan+UBSan CLEAN over the 197-test
  suite AND all 8 trace suites (401 replayed requests) — both oracles injection-proven
  sensitive first (a garbage-return probe for the analyzer; a signed-overflow probe for
  UBSan). Two probe lessons: under ARC an uninitialized OBJECT local is nil, not garbage —
  scalar defects are the valid probe; and UBSan reports do NOT fail the run (suite exits 0
  while reporting), so grep the log for `runtime error`, never trust exit codes. The scheme
  runs ASan already; UBSan is not wired into `Run-Tests.sh`.
- **Spec-conformance audit, 2026-09-02 (22nd pass; 30 agents, ~4.5M tokens).** Twelve dimension
  finders (RFC 9110/9111/9112 message syntax, framing, codings, methods, conditionals, Range,
  connection management, caching, concurrency, the uploader surface, RFC 4918 properties and
  namespace operations), then sixteen adversarial verifiers with a LIVE probe rig — every
  finding reproduced on the wire or refuted, none accepted on reading alone. 92 raw findings →
  **63 confirmed, 6 adjusted, 9 refuted** (an 11% kill rate, consistent with the ~1-in-3 lore for
  UNVERIFIED findings). Ten were fixed and merged; the rest are grouped under "Still open at
  tip", the refutations above them. What the pass ESTABLISHED, beyond the defects: no
  smuggling-class or corruption-class defect exists at tip (CL+TE, duplicate/list/negative
  Content-Length, obs-fold, bare LF, space-before-colon all refused; chunked decodes correctly
  and hostile chunk trailers are discarded); the §13 conditional matrix behaves; `curl -C -`
  resume is byte-exact; XXE is dead at every libxml2 site; hrefs percent-encode and round-trip
  including NFC/NFD spellings; and browser-shaped concurrency is clean — 4,100+ checksum-verified
  fetches over 6 keep-alive connections at ~9 ms per page (1 HTML + 40 images), byte-exact
  concurrent Range chunks against a 64 MB file, three 48-way cold-start bursts, 140 connections
  degrading gracefully, descriptors flat throughout. The torn-read defence was confirmed live: an
  in-place rewrite mid-download cut the stream at 524 KB of a promised 64 MB.
- **The gaps that pass left open were then closed, 2026-09-02 (same day, after the fixes landed).**
  A completeness critic listed what the audit had NOT touched; all but one is now measured, and
  the results are NEGATIVE except where noted. Recorded so nobody re-runs them speculatively.
  - *Real WebDAV client at tip.* Mounted with macOS's own `mount_webdav` and driven as a
    filesystem. `ls -l` reports the ALIAS at its target's size (10,485,760 B) and copying it out
    yields a byte-identical 10 MB file — the PROPFIND-metadata fix confirmed through the real
    client stack, on the exact operation that used to truncate. Write, move, mkdir, rmdir and
    delete all round-trip. `cp` reports "could not copy extended attributes": WebDAVFS implements
    no `setxattr` at all (`xattr -w` on a mounted file fails EPERM), identical on the pre-fix
    build — a client limitation, not ours.
  - *Server lifecycle under load* (Shape B's stated priority, previously unowned): 200 start/stop
    cycles on one port while 6 readers and 2 refused-mid-upload (lingering-close) clients ran
    against it — 0 start failures, 2,447 GETs and 168 refusals completed, descriptors 5 → 4,
    reserved budget 0 at rest after EVERY cycle.
  - *Reverse-proxy topology* (Shape A always has Tailscale Serve in front): caddy in front,
    keep-alive HTTP/1.1 to the backend. Status, body and `Content-Range` agree direct vs proxied
    on every case; 16 MB reassembled from Range chunks over reused backend connections with zero
    errors; 12 concurrent clients × 6 ranged requests clean. No desync where a framing defect
    would show.
  - *iOS runtime* (all previous rigs were macOS): framework builds warning-free; the example app
    serves its page, `/list` and `/upload` from the simulator. Backgrounding while IDLE suspends
    at once — correct, since the task is taken "iff connected". With a transfer in flight a 5 MB
    download at 100 KB/s completed BYTE-IDENTICAL across ~45 s of background, and the log names
    the mechanism: `taskName = Called by WebServerKit, from -[WSKWebServer _didEnterBackground:]`.
  - *Evidence tier of the 249 "verified correct" properties*: a stratified 10% sample (25 claims)
    was re-verified adversarially. **20 HOLD, 5 PARTIAL, 0 FAIL.** Every narrowing is a claim
    stated more broadly than the behaviour, not a defect: `displayname` is deliberately settable
    (§15.2) so "live properties are refused" is false as written, and refusal is by a fixed NAME
    list — an undefined `DAV:`-namespace name like `<D:foo>` stores as a dead property under
    `{DAV:}foo`; `Range: bytes=-0` is ignored (200) rather than 416, which §14.2 permits since
    ignoring Range is always allowed; the HEAD-body case needs `AutomaticallyMapHEADToGET: NO`,
    already recorded as a known deviation; `Content-Encoding: identity` is accepted rather than
    415 (RFC-correct — identity is the no-op coding) and the coding check sits inside the
    has-body branch, so a BODILESS request carrying one answers 200; and the accept-time snapshot
    covers the eleven ivars `-initWithServer:` captures, not a subclass's own mutable properties.
    Useful as a calibration: claims written from reading tend to be too broad rather than wrong.
  - *Wire corners*: a chunked trailer carrying a hostile `Content-Length` smuggles nothing;
    absolute-form target 200; duplicate `Host` 400; NUL in a header value 400; 64 KB header 431;
    `Expect: 100-continue` on a bodiless GET 200.
  - **STILL not covered: litmus** — and OWNER RULING 2026-09-02: not worth chasing. Both source
    URLs 404 from this environment, so the last conformance run remains 2026-08-18, before the
    lingering-close change and before the ten fixes of that day; rclone and a real browser are
    likewise unexercised. What makes the gap acceptable rather than merely unclosed: the DAV
    surface HAS since been driven by a real client (mount_webdav, above), every one of the ten
    fixes carries its own pinning test, and the wire matrices were replayed both directly and
    through a reverse proxy. Do not spend a future pass obtaining litmus on general principle —
    re-run it only if the DAV property or namespace code changes substantially.
- **Fuzzing, second pass, 2026-09-05 — run because the layers the first pass covered had all been
  rewritten** (the linear-parsers work, the chunked cursors, the removal primitive, the property
  validators). Two targets, both with the oracle proven sensitive first by injecting a defect: a
  one-byte overread in the multipart boundary search was caught in under 5,000 runs.
  - *Multipart parser*, driven through `performWriteData:` in pseudo-random slices because every
    defect this parser has had was about what happens ACROSS appends: **1,164,121 + 415,758 runs
    CLEAN**, coverage 181, asserting `WSKReservedMemoryLength() == 0` after every teardown.
  - *Dead-property key round trip* (`_DeadPropertyKey` → `_DeadPropertyElement`), asserting that any
    key the server will STORE comes back as parseable XML — recurring shape 13 as an invariant.
    **Two real findings, both in validators written the day before**, then **103,236,933 runs clean**.
    (1) The local-name blacklist rejected `:` and `}` but not `{`, and a legacy key like `{urn:a}b{c`
    derives the name `b{c` — reachable through the healing path, since `{` in a namespace was
    allowed until 2026-09-04. (2) Both validators judged `-UTF8String`, which stops at the first
    NUL, so they validated a PREFIX while the whole string was emitted — the truncation class,
    **seventh recurrence**, found twice within minutes in `_PropertyLocalNameIsRepresentable` and
    `_PropertyNamespaceIsRepresentable`. Fixes: ask libxml2 (`xmlValidateNCName`) instead of
    blacklisting characters, the same move the namespace check made with `xmlParseURI`; and one home,
    `_IsWholeUTF8String`, that both validators consult. Pinned by legacy-store cases in
    `testDAVRefusesAPropertyNamespaceThatCannotBeWrittenBack`, red against the old blacklist.
  - What this pass did NOT cover, and why: the chunked decoder's cursors. `readNextBodyChunk:` is a
    method on a live `WSKConnection` needing a real socket, so it is not reachable in-process the
    way the pure parsers are; its cursors are covered by the two CPU-bounded tests instead. A
    socket-driven fuzzer would be a different tool.
  - Recipe additions to the 2026-08-18 notes below: Homebrew LLVM 23 puts the runtime at
    `/opt/homebrew/opt/llvm/lib/clang/23/lib/darwin/libclang_rt.fuzzer_osx.a`; a target that
    `#import`s a `.m` still links the rest of the module's sources, so pass the source globs
    UNQUOTED or the shell hands clang one long filename; and `grep -c "error:"` over a clang log
    counts every `error:` in an Objective-C method signature, which reads as a failed build when
    the build succeeded.
- **Fuzzing, one bounded pass, 2026-08-18 (~79M executions, harness deliberately NOT kept).**
  libFuzzer + ASan + UBSan, 10 in-process targets over the pure parsers, the containment
  resolvers against a symlink/dot-dir fixture farm, and the framing parsers. CLEAN at:
  header-block validator 41.2M (anti-smuggling rule independently re-derived per input),
  entity-tag list 18.0M, gzip decode 7.7M, header-value/param machinery 6.3M, Range 1.9M,
  both date parsers 1.6M, multipart 1.2M, named-entry+classifier 146k, follow-resolver 113k.
  Zero memory errors, zero UB, zero hangs. The gzip and multipart targets asserted
  `WSKReservedMemoryLength() == 0` after every single request teardown, so the priority-one
  Shape A "zero accumulation" property is now measured across ~8.9M request lifecycles rather
  than argued. Two findings, both above under "Still open at tip"; both fail closed.
  Rebuild recipe if ever repeated: Apple's clang ships NO libFuzzer runtime
  (`libclang_rt.fuzzer_osx.a` absent) — use Homebrew LLVM with `-isysroot $(xcrun
  --show-sdk-path)`; `-fno-sanitize-recover=all` is load-bearing (UBSan otherwise logs and
  continues, so libFuzzer never sees a finding); `-fno-sanitize=builtin` suppresses a
  toolchain false positive that fires on the SDK's own `dispatch_once` in programs containing
  no WebServerKit code; and reach `static` functions by `#import`-ing the `.m` into the
  harness and omitting it from the link line. **A libFuzzer dictionary accepts ONLY `\xNN`
  escapes — a `"\r\n"` entry aborts the whole run at startup**, which cost six targets a
  silent no-run whose empty logs read exactly like clean passes (the project's own "read the
  executed count" rule, caught only because the count was checked). See "Verified clean" in the
  archived record before re-testing anything speculatively; re-run only when the layer a
  result covers changes.
- **Fresh-eyes audit, 2026-09-02/03 (23rd pass; eight agents with live probe rigs, ~3.0M
  tokens, every P1 reproduced a second time by the orchestrator on a fresh host, plus a real
  Chromium session against the uploader).** Report: the "WebServerKit 23rd Pass" artifact; the
  findings sit above under "Still open at tip" and, where fixed, in the invariant sections.
  What it ESTABLISHED beyond the defects — do not re-measure speculatively: the request path
  scales linearly to the eight P-cores under keep-alive (4,360 → 16,700 req/s on 4 KB files,
  1.0 → 7.9 cores busy; the 1,000-entry `/list` and `PROPFIND` scale the same way) and nothing
  in the library serializes it (accept path, `_syncQueue`, `@synchronized`: 0 % of a saturated
  profile); one connection is one serial queue and so one core at most (2.28 GB/s single
  stream, 0.47 s CPU/GB); blocking file reads do NOT starve the GCD pool (120 downloads from an
  emulated 5 MB/s volume grew the pool to 129 threads and a new connection still answered in
  ~1 ms — XNU charges only runnable threads against the 64 constrained allowance); serving never
  depends on the main thread (10 s block: all three servers answer in 1–9 ms, delegates arrive
  when it unblocks; no `dispatch_sync` to main exists); `DispatchQueuePriority` changes
  throughput ≤3 %; TSan over the suite and ~5 minutes of mixed traffic against an instrumented
  host reported zero races in `Sources/`; containment held on every entry point including from
  a real browser, and COPY of an outside-pointing symlink yields an inert alias, never the
  target's bytes; every 2026-09-02 fix holds on the wire; WebDAVFS, cadaver (anonymous) and
  rclone all round-trip; 500 start/stop cycles with 0 failures; reserved bytes 0 at rest after
  every experiment; the 2026-08-01 external audit's "likely P0" nil-scanner crash answers 403
  with the server alive. **Corrections to this record it produced** (each measured, each
  applied above): "Mac framework is warning-clean" is false on Xcode 26.3 (48 in Mac Debug, 44
  from two dead flags, 4 real, plus 2 in the tests; Release is clean everywhere); the test that
  fails CI is a THIRD timing test, not one of the recorded two; "an external SwiftPM consumer
  building clean" caught nothing under Xcode's generator; "Internal/ never installed" was true
  of the framework and false of the pod; the "8 × 512 MiB < one stream" figure is the kernel
  loopback path; the header-subscripting refutation's MECHANISM was wrong; the
  `WSKMultiPartFormRequest.m` "only limits data genuinely held" comment was false for a read
  above 16 MB; the exit-70 tvOS flap did not reproduce with runtimes installed and never
  happened in CI. Harness lessons: `proc_pidinfo(PROC_PIDLISTFDS, NULL, 0)` returns the
  fd-TABLE capacity (120 → 220 → 420, never shrinks), not open descriptors — count real entries
  or use `lsof`, and read every "fds flat" claim from that day as "the table did not grow"; a
  `pkill wskhost` from one agent killed every other agent's servers mid-run (kill by PID); the
  harness refuses a subagent's report-file write, so require the report in the final message;
  Xcode 26's script sandbox refuses its own script phase when derived data lives under /tmp
  (`ENABLE_USER_SCRIPT_SANDBOXING=NO`); `WSKLogMessage` is gated on `isatty(STDERR)`, so capture
  the access log under `script -q -F`; a probe host that registers two default POST handlers
  routes multipart bodies to the LAST registered one (reverse match order). Not covered: the
  iOS example at runtime (the simulator wedged under fleet load), Cyberduck/Transmit/davfs2/
  litmus, a reverse proxy in front for the slow-reader cut, E-core participation, exFAT/HFS+/
  network volumes, 10,000-deep MKCOL, and the four recorded `-stop` TSan false positives (not
  re-observed).
- **Re-verification of the 23rd pass, 2026-09-04 (four agents, every original probe re-run against
  49084f0).** Verdicts and the three new siblings are in the "From the 23rd pass" block. Lessons
  it added: (1) **the built-in logger prints ONLY when stderr is a TTY or a logger block is set**
  (`WSKWebServer.m:79-94`) — a "no log line" claim made with stderr redirected to a file is vacuous;
  drive the host under `script -q -F` or a pty, and say so in the finding. (2) A `pkill -f` on the
  shared binary path from one agent again reached another agent's hosts (twice in two days); kill
  by PID or by port range, never by binary path. (3) On a machine at load 250–350 (a parallel
  fleet), wall-clock and req/s figures are meaningless while CPU-time deltas (`getrusage`,
  `/__wskstats`) stay usable — every timing verdict in the re-check rests on the latter, and the
  scaling curve was re-taken alone. (4) A fix's own neighbourhood is where its siblings hide: the
  cursor rewrite closed the chunk-count quadratic and left the never-completing chunk-size line
  untouched, and the `}` refusal left whitespace in — both found only by asking "what else has
  this shape" against the FIXED code.

## Recurring defect shapes (check all new code against these)

1. The same rule spelled two ways in two places — give every rule ONE home.
2. A class closed at only some of the sites it applies to — sweep every site before
   recording closure (NUL: six recurrences; recursive vetting: four).
3. nil/NUL reaching Foundation APIs that raise or return nil — nothing in `Sources/` catches
   NSExceptions.
4. Honouring a truncated prefix of what was asked (NUL, then `#` — same class).
5. Fail-open vs fail-closed mix-ups — judge every case-comparison and parse failure by which
   way it fails (an unparseable date must fail OPEN by RFC).
6. Two observations of the filesystem that need not agree — resolve once; restate rules
   against the resolved path.
7. Vet-then-act windows — carry the vetted `dev`+`ino` into the destructive step.
8. A derived predicate standing in for the real one (`-hasBody` vs raw framing headers) —
   framing/containment/authz decisions must read the primary source.
9. A check and the action it guards must observe the SAME object (re-read weak delegates
   into a strong local and re-check inside the block).
10. Messaging nil returns a ZEROED struct — guard nil before any NSRange/NSRect/NSSize test
    on a possibly-nil receiver.
11. A status that differs by what the filesystem holds is an answer about the filesystem —
    ask the question after resolution, on the RESOLVED path.
12. A predicate whose answer depends on WHICH REPRESENTATION holds the bytes
    (`-hasPrefix:@"."` on `NSPathStore2` vs `__NSCFString`) — read the primary source, and give
    the rule one home so two spellings of the question cannot coexist.
13. Storing what cannot be read back. A value accepted into persistent state must survive the
    round trip: an unrepresentable XML name stored as a dead property made every later listing
    of that resource — and of its PARENT — unparseable. Validate on the way IN, and keep the
    writer able to skip what an older build let through.
