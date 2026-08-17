# WebServerKit

A fork of GCDWebServer with additional features for iOS/macOS web serving.

This file is the project's institutional memory across sixteen audit passes and a structural
cleanup. It is organized by **what is true now**, not by when things happened; the pass-by-pass
narrative is compressed into the appendix. When editing this file: a sentence about what some pass
DID belongs in the appendix; a sentence about what the code relies on NOW belongs in the body. The
file's own worst historical failure is asserting properties the code did not have — see "Lessons".

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

## Design priorities

This library has **two deployment shapes**, and they stress different things. Earlier notes
asserted only the first, and several decisions below were justified by that premise alone —
so check which shape a judgment call belongs to before reasoning from it.

**Shape A — long-lived vending (the priority).** A build server (Puck) that runs for *weeks*,
bound to localhost behind a Tailscale Serve tunnel that terminates TLS, vending ad-hoc iOS
builds to a handful of trusted devices on the tailnet. Low concurrency, very large responses,
and uptime measured in weeks rather than minutes.

**Shape B — ephemeral sharing (iComics).** Brought up periodically, serves on the LAN for a
while, goes away again. Many small operations through a browser UI, WebDAV and the uploader.

What each shape depends on:

- **Shape A lives or dies on not accumulating anything.** A descriptor or memory reservation
  leaked once per request is invisible in a four-minute session and fatal in a four-week one.
  The aggregate in-memory budget is the sharpest edge here: it is process-wide static state
  with **no reset**, so one reservation that outlives its request permanently disables every
  in-memory endpoint until the process is relaunched. `+[WSKWebServer reservedInMemoryByteCount]`
  exists to be monitored for exactly this, and `testSustainedServingDoesNotAccumulateResources`
  guards it (verified sensitive by injecting a leak and watching it fail).
- **Shape A also depends on large-file correctness.** Multi-hundred-megabyte builds pulled
  over WiFi mean interrupted transfers are routine, so `Range`/`If-Range` handling is a main
  path, not an edge case: serving a range against a *changed* representation would splice two
  builds together into an IPA that installs and then crashes. Note also that Puck rewrites
  builds while they may be downloading — `WSKFileResponse` opening once and deriving
  everything from `fstat` on that descriptor is what keeps an in-flight download consistent.
  **That is true only for an ATOMIC replacement** (`rename(2)`, `ditto`, `mv`), which gives the new
  content a new inode the held descriptor never sees. A rewrite *in place* — `cp` and `cat >`, both
  of which open `O_TRUNC` — reuses the inode, so the descriptor starts yielding the new build's
  bytes mid-body; the eleventh pass measured a ~48 MB response whose body bytes came
  from the replacement, under one 200 OK with a matching `Content-Length`. Each chunk is now
  verified against the size and mtime the response promised. **Publish atomically anyway** — the
  check refuses the transfer, it cannot make a torn read whole. And the guarantee holds only
  *within* a response: a client that fetches via many independent Range requests (macOS's WebDAV
  client uses ~99 × 1 MiB requests on separate connections) can splice two builds client-side while
  the server answers every request truthfully with distinct ETags. No server-side fix closes that.
- **Shape B depends on start/stop correctness**, because it happens constantly. Lifecycle
  races a daemon meets once in its life, this meets every time it wakes.
- **Both depend on refusing clearly rather than half-succeeding.** A request the server cannot
  honour exactly should fail with a status that says so, leaving prior state untouched.
  Silently accepting something and doing an approximation of it is the worst outcome. This is
  why an unsupported `Transfer-Encoding` is refused rather than read as an empty body (501 for a
  coding the server does not implement, 400 for a malformed application of one it does — the
  eighteenth pass split the two, both still refusals), why a destructive
  operation stages and swaps rather than removing first, why a truncated gzip body is refused
  rather than written, and why a recursive delete refuses when it would destroy a file a
  direct delete would have refused.
- **Both depend on a transaction leaving nothing behind.** No staging files, no temp files, no
  held descriptors, no connection slots — on the failure paths as much as the success paths.
- The one deliberate exception to "short-lived" is the SSE `/events` stream, which is
  long-lived by design and is bounded separately (heartbeats, reaping, one stream per browser).

**Threat model.** Shape A is reachable only from the tailnet (Tailscale *Serve*, not Funnel)
and binds to localhost, so the audit's assumption of a small trusted network still holds. If
that ever becomes Funnel — i.e. public internet — this needs re-auditing with an
internet-facing lens: there is no rate limiting, no auth backoff, and the 128-connection cap
is trivially saturated. Plaintext transport remains a settled choice because TLS is
terminated upstream; do not re-flag it.

## Deployment requirements

What an operator or host app MUST do (or know) to deploy this correctly.

- **Tailscale deployments must set `WSKOption_AllowedHostNames`** to the node's MagicDNS name
  (`<node>.<tailnet>.ts.net`). The Host allow-list admits localhost, IP literals, the machine's
  own host name and the Bonjour/`.local` name only; anything else is refused with 421. Both the
  root-dotted FQDN spelling (`puck.tailnet.ts.net.` — DNS's canonical form) and the undotted one
  work now via `WSKHostNameWithoutRootLabel`; before the structural cleanup the dotted spelling
  admitted nothing (measured 421/421 before, 200/200 after), presenting as "the server just
  doesn't work".
- **Host allow-list port semantics:** an entry WITHOUT a port matches any port (required behind a
  port-translating hop — do not pin the port there); an entry that PINS a port is honoured
  verbatim. A request with no `Host` header at all is allowed (HTTP/1.0 and native clients omit
  it; DNS rebinding requires a browser, which never does).
- **`WSKOption_ConnectionIdleTimeout`**: NSNumber/double, default 30.0 s, 0 disables. A connection
  whose pending socket I/O moves no bytes in either direction across two consecutive timer ticks
  is shut down via `shutdown(2)` so pending I/O unwinds through normal error paths. Without it,
  128 idle sockets (the connection cap) is a permanent denial of service.
- **Monitor `+[WSKWebServer reservedInMemoryByteCount]`** on long-lived deployments — the
  aggregate budget has no reset, so a nonzero value at rest means an in-memory endpoint is
  permanently degraded until relaunch.
- **`-preflightRequest:` overrides must decide on headers alone** — it is called before the
  request body exists (deliberately: 288 MB used to be spooled to disk before a 401/421, and
  199 MB before the uploader's 403, the last reachable from a plain auto-submitting HTML form).
- **Handlers whose response IS a long-lived resource must check `-[WSKRequest isVirtualHEAD]`** —
  a mapped HEAD's body is discarded unsent, so allocating the resource for one strands it (this is
  how 16 cheap HEADs once pinned every SSE channel for ~30 s).
- **Inside a `WSKMatchBlock` the request's addresses are nil** (the connection populates them
  after the block returns); `remoteAddressString` returns `@""` there, and
  `localAddressData`/`remoteAddressData` are `nullable` because they genuinely are.
- **Hidden content:** the five-argument `addGETHandlerForBasePath:` form delegates
  `allowHiddenItems:NO`; serving through dot-directories needs the explicit `allowHiddenItems:`
  variant, and a convenience symlink into a dot-directory (`latest -> .builds/…`) will not resolve
  under default settings — "hidden" means where the bytes live.
- **Filenames containing `#` must be addressed as `%23`** on the wire. A raw `#` anywhere in the
  request-target (including `GET /q.txt?a=1#b=2` and a bare trailing `#`) or in a WebDAV
  `Destination` answers 400 by design.
- **Avoid republishing a build while downloads are plausibly in flight** — clients fetching via
  parallel Range requests will splice on their side and only the client could detect it (measured:
  20 MiB of build A + 80 MiB of build B in one local file, every server response truthful).
- **Network volumes (smbfs, nfs, anything `fstatfs` cannot classify)** put `Last-Modified` sealing
  on the conservative two-second window; date-only clients lose up to two seconds of caching there
  by design. Do not "optimize" it back to one second — a FAT volume over SMB is indistinguishable
  from the server side, and being wrong that way splices builds.
- **The one-stream-per-browser SSE relay depends on the Web Locks API and BroadcastChannel**;
  where either is missing the client falls back to per-tab streams — and with them the
  six-connections-per-origin browser deadlock risk for 6+ tabs on such browsers.
- **A share reached through a symlink is supported for live updates**, but only since the
  `-presentedItemURL` fix — before it, such a deployment received no external-change events at all
  and the uploader's live-update feature was simply absent there. A share whose realpath changes
  while running is also handled now (the derivation re-resolves on a miss).
- **Keep advertising DAV class 2**: Finder refuses to write to a share that does not advertise it;
  that is the sole reason the LOCK stub exists.
- **iOS Files app integration** requires `UIFileSharingEnabled` and
  `LSSupportsOpeningDocumentsInPlace` in Info.plist (see `Examples/iOS/`). Background serving:
  start with `WSKOption_AutomaticallySuspendInBackground: false` for ~30 s of background
  execution before iOS suspends the app.
- **Framework linking** is via `OTHER_LDFLAGS` in project build settings: Foundation,
  SystemConfiguration, CFNetwork, **UniformTypeIdentifiers (HARD-linked, not weak** — it is present
  at every deployment floor this ships against), `-lxml2` and `-lz`; UIKit is weak-linked for the
  iOS/tvOS SDKs only. **CoreServices is no longer linked at all**: the `UTType` MIME lookup replaced
  the deprecated CoreServices fallback, so there is no availability check and no fallback path left.
- **SSE event wire format (client contract):** `event: change` with JSON data
  `{"type":"upload"|"delete"|"create"|"external","path":...}` or
  `{"type":"move","oldPath":...,"newPath":...}`; directory paths end with `/`; heartbeat comments
  every 15 s. The browser reloads only when the changed directory matches the folder it is viewing.

## What is true now

The invariants the code relies on, with the measurements that justify them. Every rule here has
ONE home wherever that was achievable — the single most reliable defect shape in this codebase is
the same rule spelled two ways in two places.

### Path resolution and containment

- **Resolve once — and know WHICH of the two resolvers you are in.** `WSKResolveWithinDirectory()`
  resolves the whole path and is what every READ, and every write to a location, goes through; it is
  the one the escape measurements below are about. `WSKResolveNamedEntryWithinDirectory()` resolves
  the PARENT and appends the raw leaf, and is used only by the verbs that act on the entry the client
  NAMED (DELETE, and MOVE/COPY on both source and destination — five call sites). In both,
  containment and hiddenness derive from that single observation. Two observations
  of a filesystem that need not agree is the class that once let a retargeted symlink escape the
  share (measured pre-fix: base-path GET 977/4000 served outside the root, uploader /download
  551/3000, WebDAV GET 772/3000, WebDAV PUT wrote **228/600 files outside the share**; control
  with the link held fixed 0/1000; zero across all surfaces after). The window is between the
  server's own steps inside one request — no client-side concurrency needed. Adding a second
  resolution anywhere reopens it.
- **Symlinks are aliases** (owner decision): a destructive verb acts on the entry the client
  NAMED — `DELETE /latest` removes the link, not the build directory; `mv` replaces it — while
  reads still FOLLOW it (`GET /latest/app.ipa` unchanged). Applied to DELETE and to MOVE/COPY on
  BOTH source and destination, in both servers. Under these semantics the share root is never the
  thing operated on, so the ninth pass's catastrophe (a five-entry share emptied by one request)
  is impossible **by construction** — `testSymlinkResolvingToTheShareRootCannotDestroyIt`
  deliberately asserts the contents *survive*, not that the request is refused; do not restore the
  refusal assertion. Containment through a link is exactly as strong: `PUT /escape/x` through a
  link out of the share is still 403 with nothing landing outside.
- **Symlinks appear in listings**, classified by what they point at, and only when the target
  resolves INSIDE the share and is a regular file or directory (advertise-iff-served; omitting
  them was data loss through a real mounted client — `mv` returns 0 having copied only what the
  listing reported, then deletes the source). One classifier, `WSKServableFileTypeAtPath()`,
  serves all three enumerators (DAV PROPFIND, uploader `/list`, base-path index) so they cannot
  drift; it hands the resolved leaf back through an out-param precisely so no caller resolves a
  second time (the base-path index, which has no allow-list, passes NULL).
- **The extension allow-list judges BOTH names a symlink presents** — the alias the client used
  AND the resolved target's name must pass (`WSKEntryPassesExtensionAllowList`, one home; both
  servers' `-_checkFileExtension:` delegate to `WSKNamePassesExtensionAllowList`). The fail-closed
  ruling: alias-alone would make `alias.txt -> id_rsa` servable; target-alone contradicts the
  alias semantics for destructive verbs. Accepted cost, recorded because it will be noticed: a
  link named `.txt` pointing at a non-allow-listed file stops being servable. The pinning test
  asserts for five entries that the LISTING and the HANDLER never disagree — the property, not any
  particular verdict.
- **The uploader's mutating endpoints hold `_fileOperationLock`.** `-_uniquePathForPath:` is a
  pick-then-create sequence and is only sound while serialized, and `/delete`'s subtree vetting
  races `/move`. Any endpoint added to `WSKWebUploader` that resolves a path and then acts on it
  must take it too — four call sites currently do.
- **Recursive-destroy vetting has one home**, `WSKFirstUnvettableItemAtPath`, called by both DAV
  and the uploader. Two judgement calls live at the shared site: dot-names and their descendants
  are skipped whatever `allowHiddenItems` says (a `.DS_Store` sits in every macOS folder with an
  empty `pathExtension` that is in no allow-list — vetting them would make ordinary directories
  permanently undeletable), and an extensionless file IS vetted (a direct DELETE of it is already
  refused). Only a dot-named DIRECTORY is skipped wholesale: `-skipDescendants` is defined for the
  most recently returned *subdirectory*, and calling it for a dot-named FILE pops the enclosing
  level — which once switched off the allow-list for everything after the first dot-name in
  readdir order (`DELETE /Vault` destroyed `sub/id_rsa` 60/60 while the same file addressed
  directly was 403). This class — a recursive DELETE or overwrite destroying what a direct
  request refuses — has recurred FOUR times (8th, 10th, 13th, 15th passes); both copies of the
  walk were wrong simultaneously the last time, which is the argument for the single home.
- **The removability walk (`WSKFirstUnremovableItemAtPath`) is UNCONDITIONAL** — it must never
  live inside `WSKFirstUnvettableItemAtPath`, which returns nil when
  `allowedFileExtensions` is unset, i.e. the default configuration. It asks before anything is
  touched, because `-[NSFileManager removeItemAtPath:]` deletes as it walks and stops at the
  first failure, keeping everything already destroyed (one `chflags uchg` file — Finder's
  "Locked" checkbox — turned `DELETE /Folder` into 21 files in, 9 left, status 500; through an
  overwrite, a destination gutted 7 files to 1 with the source left in place). Semantics:
  `unlink(2)`/`rmdir(2)` need write permission on the PARENT, not the item, so an empty 0555
  directory is removable (0555 arrives through ordinary `unzip`/`ditto -x -k` extraction); a
  directory that cannot be listed is refused; a read-only NON-empty directory is refused. The
  test pins both directions.
- **`_RealPath` is the most security-critical function in the library; any edit needs its own
  measured pass.** When `realpath(3)` fails it WALKS UP until an ancestor resolves and appends the
  missing components — the branch that lets `PUT`/`MKCOL` to a not-yet-existing name resolve at
  all, and also the branch a dangling symlink takes. It used to try the immediate parent exactly
  ONCE, which made "absent" and "refused" the same answer as soon as a client named a path two
  levels past anything real: GET, HEAD, PROPFIND and PROPPATCH answered 403 where 404 was owed, and
  DELETE the same one level deeper (it resolves the parent itself, so it got one level for free).
  Measured on an 11-verb × 7-path matrix before and after; `rclone copy dav:/a/b` treats that 403
  as fatal. **LOCK and UNLOCK are NOT part of this class** — they answer 405 at tip, though an
  earlier spelling of the record listed them. The walk does not weaken containment: an escaping
  path still resolves to a location outside the root and is refused by the caller's containment
  test whether or not anything exists there, and a component that EXISTS but will not resolve
  still fails closed at each step. **The walk is BOUNDED by `PATH_MAX`, and that bound is load-
  bearing rather than tidiness**: the request target is client input capped only by the header
  block, and the walk does work per missing component, so the first version — which also built its
  result quadratically — cost **2,259 ms of CPU for a 16,000-component path against 15 ms before
  the walk existed**, a 153× amplifier on a server with a 128-connection cap and no rate limiting.
  Nothing at or beyond `PATH_MAX` can name a filesystem entry (`ENAMETOOLONG`), so it is refused
  before the walk starts, fail-closed and independent of anything on disk. Collect components by
  APPENDING and join once; `insertObject:atIndex:0` and `stringByAppendingPathComponent:` in a loop
  are each quadratic. Measured worst case inside the bound is ~10 ms at 400 components against
  ~0.9 ms on the old code — linear, accepted, and the lever if that ever matters is a component
  cap well below `PATH_MAX`. The rejected fix — a `-fileExistsAtPath:` parent precheck in
  each read verb — is what reopens the existence oracle, because that predicate answers for paths
  outside the share. `WSKResolvedPathIsWithinDirectory` now answers YES for a deep not-yet-existing
  path inside the share, which is simply true: it reports CONTAINMENT, not existence. Its test
  previously pinned the one-level cutoff as though it were a rule, two lines below asserting YES
  for the one-level-shallower spelling of the same question.
  An entry that exists and cannot be resolved fails CLOSED
  (403), so an escaping symlink answers 403 whether its target exists or not — previously
  403-vs-404, an existence oracle for paths outside the share. Dangling links inside the share
  and symlink loops also answer 403 (neither was ever served). The regression test asserts the
  FIVE operations that must survive (PUT new path 201, PUT in subfolder 201, MKCOL 201, PUT over
  existing 204, GET 200) alongside the two that change. MOVE to a new name was measured in the probe
  and never made it into the test — the probe table in the old record listed six.
- **Resolve and test containment BEFORE asking the filesystem any question about the path.**
  `-fileExistsAtPath:` FOLLOWS SYMLINKS, so a precheck that runs ahead of containment answers a
  question about the filesystem OUTSIDE the share, and the status carries the answer back. Measured
  at five sites, all in the write verbs, all pre-existing: `PUT /esc/nodir/x` answered 409 while
  `PUT /esc/there/x` answered 403, differing only in whether `there` existed out there — and the
  same pair for MKCOL, the COPY destination, the MOVE destination, and 404-vs-403 for a COPY
  SOURCE reached through the link. Same class as the oracle
  `testUnresolvableEntriesFailClosedWithoutBreakingCreation` closed for the read verbs; this was
  the half it never covered.
  **The old order was deliberate and its comment was true when written** ("checked after the
  parent-exists test so a genuinely missing collection still reports 409 rather than 403"): while
  `_RealPath` tolerated one missing component, resolving first turned legitimate 409s into 403s.
  The walk-up removed that constraint and the correct order became available — which is why this
  is recorded here rather than as a defect someone should have seen. **The two existence tests in
  COPY/MOVE keep their original order relative to each other**, so a request wrong in both ways
  reports the status it always did. Do not "fix" a future instance by keeping the precheck and
  special-casing symlinks; move it after resolution and run it on the RESOLVED path.
- **Hidden means where the bytes live.** `WSKResolvedPathHasHiddenComponent()` tests the resolved
  path relative to the RESOLVED ROOT — relative deliberately, because the root itself may live
  under a dot-directory (`NSTemporaryDirectory()` under a sandboxed app routinely does) and an
  absolute test would refuse every file the server vends. The cheap textual walk runs FIRST (so
  `realpath` is only paid when it can change the answer) and the resolved hidden test runs AFTER
  containment (so an escape is reported as an escape, not as a hidden item). Both orderings are
  deliberate — they were restored once after being accidentally inverted.
- **NUL bytes:** the FIRST line of defence is refusal — a NUL-bearing client path answers **400
  from the uploader's endpoints and the base-path handler, and 403 from WebDAV**, which has no
  explicit check of its own: the guard lives INSIDE the follow-resolvers, so DAV surfaces it as a
  nil resolution and every caller maps that to 403. Living in the resolver is what stops a verb
  added later forgetting it (that is
  how `POST /delete path=/Keep%00/x` once destroyed `/Keep`). `WSKNormalizePath` truncating at a
  NUL is kept as a SECOND line, because the filesystem's C-string APIs truncate and the mismatch
  is otherwise exploitable (`secret.dat\0.png` passes an allow-list and opens `secret.dat`). The
  nil/NUL class is this codebase's single most repeated defect — six recurrences, each a site an
  earlier fix did not reach. **Never claim it closed without a site inventory.** The sixth site
  was a NUL in a header field VALUE, which sailed through the validating pass and into
  `request.headers` answering 200 (RFC 9110 §5.5 requires reject-or-replace; digest auth had
  been individually hardened against exactly this). Closed in the eighteenth pass at the block
  validator, alongside every other C0 control and DEL — HTAB and obs-text (0x80–0xFF) still
  pass, because that is a control-byte refusal, not an ASCII allow-list.
- **`#` is guarded at both places a URL arrives**: on the raw wire bytes in
  `_ValidateRequestLine` — ahead of any CF parsing, so a `-rewriteRequestURL:` subclass cannot
  route around it — and in `Destination`. `CFURLCopyPath()` treats `#` as a fragment delimiter,
  and `MyApp#42.ipa` is ordinary CI convention: pre-fix, three PUTs collapsed to one file holding
  the last build's bytes, and `DELETE /D1/#nope` destroyed `/D1` answering 204. HTTP stacks
  sanitize the request line but never header values (curl strips `#` from the target and passes
  it through `Destination` untouched — measured defeating a target-only guard). `%23` still
  addresses a `#`-bearing file, and the test asserts it, because breaking `%23` is what a naive
  fix does.
- **`[@"/" lastPathComponent]` is `@"/"`** — the one input for which it does not yield a leaf.
  The upload path rejects a separator in the reduced leaf AND judges the composed path against
  `resolvedDirectory` (the `realpath` result — comparing against the merely-standardized
  `_uploadDirectory` fails for every share under `/var`/`/tmp`). Pre-fix, `filename="/"` in the
  default configuration wrote the body beside the served directory and renamed the share's own
  leaf (`Share (1)`, unbounded).
- **Same-file detection has one home**, `WSKPathsNameTheSameFile` (via
  `NSURLFileResourceIdentifierKey`). It is the whole of the protection against a self-move
  deleting the only copy, including the case-variant pair that is one file on a case-insensitive
  volume; a case-only rename via MOVE is refused 403 (safe) rather than performed.
- **The uploader's read endpoints resolve BEFORE they stat** (`/list`, `/download`), agreeing
  with DAV's documented ordering and with `-deleteItem:` in the same file.
- **The four resolver copies are ONE implementation** (verified line-for-line identical before
  merging; 198 lines left the two servers). Each server keeps a three-line wrapper so every call
  site still binds the result to the variable the rest of the method already used — the device
  that makes "I missed one" structurally impossible. Do not inline it away. Five historical
  defects lived in exactly those four copies (NUL guard, hidden-item rule, recursive-delete
  vetting, If-Range, overwrite vetting — each closed in one server and left open in another).

### Validators and conditional requests

- **The entity tag is inode + mtime (with `tv_nsec`) + size**, minted by ONE function,
  `WSKEntityTagForFileInfo`, shared by `WSKFileResponse` and the precondition check so they
  cannot drift — a second formatter would make every precondition FAIL rather than protect
  anything. Size is included because a preserved-mtime rewrite (`rsync -a`, `cp -p`, `tar -x`)
  once produced identical tags for different content (a 900-byte build replaced by 916 bytes
  answered 304 to revalidation and 206 to a resume). Limit, accepted: an equal-length AND
  equal-mtime replacement remains undetectable; nothing derived from `stat(2)` can close that.
- **A `Last-Modified` is simply not issued while mtime is inside its filesystem's timestamp
  bucket** (`WSKLastModifiedDateIsSealed`), and that issue-time withholding is the WHOLE of the
  date-validator protection — the redemption-time check surviving in the resume path is NOT a
  second line of defence and cannot be made one (once the bucket closes, a date a client
  legitimately holds and a fabricated one are byte-identical). Do not try to "strengthen" the
  resume-path check. Granularity is asked of the descriptor's filesystem: 1 s only for `apfs`,
  `hfs`, `exfat` (measured at ns, 1 s, 10 ms); **everything else — `smbfs`, `nfs`, and an
  `fstatfs` failure — is assumed two-second**, because FAT stores mtime in two-second buckets,
  truncates downward, and a FAT volume over SMB reports `smbfs`. A future mtime is unsealed by
  the same test, which also stops advertising a `Last-Modified` newer than the server's own
  `Date`. PROPFIND's `<D:getlastmodified>` shares the same seal (it once published the exact
  validator the GET path refused to issue — 12/12 splices). Pinned by
  `testIfRangeRefusesADateMintedInsideItsOwnSecond`; the ETag carries `tv_nsec` and is unaffected.
- **`WSKFileResponse.contentType`/`lastModifiedDate`/`eTag` are `nullable`** (the base class's
  honest declarations; the non-null redeclarations were deleted — BREAKING for Swift, `if let`
  required). Two default-configuration cases make nil real: `lastModifiedDate` is deliberately
  nil inside the timestamp bucket, and the 416 path (`Range: bytes=999999999-`) returns with none
  of the three set. A header that lies to the type system is worse than one that changes.
- **`If-Modified-Since` uses EXACT equality** (nginx's default), with `If-None-Match` precedence
  per RFC 9110 §13.1.3. Safe because `_NSDateFromTimeSpec` truncates to whole seconds and
  `WSKParseRFC822` parses at the same precision, so echoing the served value revalidates. The old
  "not strictly newer" comparison let a rollback pin a date-only client permanently (a 304 makes
  the client adopt the CURRENT ETag per RFC 9111 §4.3.4, so nothing ever dislodged it).
- **`If-Match` and `If-Unmodified-Since` are enforced BEFORE any destructive step for PUT,
  DELETE, MOVE and COPY**, in RFC 9110 §13.2.2 order (previously the only precondition site ran
  *after* the handler, so no 412 was ever possible and WebDAV lost-update protection did not
  exist). `If-Match: *` asks whether a representation exists at all (§13.1.1) — keying it on the
  entity tag, which is only minted for regular files, made every conditional operation on a
  collection fail forever. `If-Match` on a MISSING resource answers 404, and that is REQUIRED
  (§13.2.1: ignore preconditions when the unconditional response would be neither 2xx nor 412);
  PUT is the opposite case because it would create, so there `If-Match: *` correctly fails 412.
  Both directions are pinned by a test precisely so a later pass does not re-find the 404 and
  "correct" it.
- **`If-Match` and `If-Unmodified-Since` are ALSO evaluated on reads** (GET/HEAD, every serving
  surface), in `-overrideResponse:forRequest:` ahead of the If-None-Match/If-Modified-Since
  pair — RFC 9110 §13.2.1 applies the preconditions to every method, and a mismatching
  `If-Match` on a GET answered 200 until the eighteenth pass (safe direction, so no client ever
  noticed). The site is deliberately GATED to GET/HEAD and 2xx: the DAV write verbs evaluate
  preconditions BEFORE acting and their 201/204 carries no entity tag, so an ungated re-check
  here would turn every conditional write that correctly SUCCEEDED into a 412 — the test pins a
  passing conditional PUT for exactly that trap. The tag comparison is `WSKEntityTagMatchesList`,
  ONE home shared with the DAV write-verb evaluator (hoisted there from DAV). Interplay with the
  seal: while `Last-Modified` is withheld, the response has no modification date, so
  `If-Unmodified-Since` is ignored per §13.1.4 — inside the bucket a date cannot distinguish two
  representations, so it cannot be allowed to refuse one either.
- **All three RFC 9110 date spellings parse** (IMF-fixdate, RFC 850, `asctime()`); only
  IMF-fixdate is ever FORMATTED. Sharp details: `twoDigitStartDate` is exactly a window opening
  50 years ago (§5.6.7's two-digit-year rule); `asctime()` pads a single-digit day to width two
  ("Sun Nov  6"), which the `d` pattern letter does not absorb, so runs of spaces are collapsed
  rather than the pattern loosened; and the calendar year is ANCHORED because ICU accepts 1–3
  digits for `yyyy` and 1 for `yy` — without the anchor, `…94` parsed to year 0094, which
  precedes every real mtime and turned `If-Unmodified-Since` into a permanent 412 no retry could
  satisfy (RFC 9110 §13.1.4 requires an unparseable date to be IGNORED — fail open, precondition
  absent). A 64-character length precheck rejects non-dates in constant time (no legal HTTP-date
  is longer); this matters because `If-Modified-Since` is parsed for EVERY request, before any
  handler or authentication, on the single process-wide serial queue that also serializes every
  response's `Date` header (linear-time rejection measured 74× baseline, 1.48 ms exclusive CPU at
  the 64 KB header cap).
- **The date form of `If-Range` must keep working**: the recorded Finder session
  `Tests/WebDAV-Finder/059` resumes with `If-Range: <HTTP-date>` and no entity tag — honouring
  only the ETag form turns every Finder resume into a full re-download (this broke the first fix
  attempt, caught by the trace corpus).
- **gzip is never applied to a 206** (its `Content-Range` describes the identity coding).
- **Unsatisfiable ranges answer 416 with `Content-Range: bytes */N`.** Range arithmetic verified
  exact across 1,008 header spellings and ~5,000 generated partitions, 0 B to 128 MiB.
- **`WSKFileResponse` opens once with `O_NOFOLLOW` and derives everything from `fstat` on that
  descriptor** (stat-then-open is two path walks: a file replaced between them was served with
  the previous file's `Content-Length` and ETag). Every chunk is verified against the promised
  size and mtime BEFORE being handed over — end-of-body-only verification detects the change
  after the bytes are on the wire under a satisfied `Content-Length`, so the client still gets a
  complete, well-formed, WRONG response. The end-of-body branch is `} else if (_size > 0)`:
  **a zero-length NSData is the end-of-stream sentinel** both consumers require
  (`writeBodyWithCompletionBlock:` writes the terminal chunk on it; `WSKGZipEncoder` selects
  `Z_FINISH` on it), and returning nil at normal end aborts the chain — the missing `_size > 0`
  once broke gzip at all 8 tested sizes and logged a false truncation ERROR on 8/8 successful
  responses while identity responses hid it completely.

### Header and framing rules

- **One validating pass over the header block**: paired CRLF only, no obs-fold, `1*tchar` field
  names, and a request line of exactly `method SP target SP HTTP-version`. Header failures answer
  431/414/400/505, never 500. This exists because the block was delimited by CRLFCRLF but parsed
  by CFHTTPMessage, which ends at a bare LF-LF — headers between the two silently dropped
  (`X-Pad: p\n\nHost: evil.example` produced a request with NO Host, taking the allow-list's
  no-Host branch), `Content-Length : 5` and folded `Content-Length:\r\n 5` both produced a
  length, and `GET /a HTTP/1.1 junk` dispatched with path `/a HTTP/1.1`. All eight probe cases
  answered 200 before. The eighteenth pass widened the same pass rather than adding a second one:
  C0 controls and DEL in field values are refused (the NUL entry under path resolution), more
  than one `Host` line is 400 (counted on the RAW lines — CFHTTPMessage merges duplicates into
  one comma-joined value, and a comma is LEGAL in a reg-name, so the merged spelling cannot be
  told apart downstream), at least one empty line ahead of the request-line is skipped (RFC 9112
  §2.2 — the skip offset is also where the CF append starts), and the version rules are grammar
  first: not `HTTP/DIGIT.DIGIT` → 400; a major this server does not implement → **505**; a HIGHER
  minor within HTTP/1 is patched to `1.1` in place and served (RFC 9110 §2.5 — the patched line
  is exactly what CF parses, so `_clientIsHTTP10` stays truthful). The validator also reports
  whether the target was ABSOLUTE-FORM, read off the raw line — see Host validation for why the
  parsed URL cannot answer that. An over-cap refusal splits by what overflowed: no line
  terminator inside the whole block budget means the request LINE itself did → **414**; anything
  else → 431.
- **`kHeadersMaxLength` applies to the BLOCK, not the buffer** — enforcing it only while waiting
  for the terminator let an oversized block sent in one burst be parsed and served, and the
  buffer legitimately runs past the cap once body bytes arrive in the same read.
- **Wire integers parse strictly** (digits only, explicit overflow): `-integerValue` accepted
  `"5abc"` and clamped overflow to `NSIntegerMax`; `strtol` accepted `" 5"`, `"+5"`, `"0x5"`,
  and `"-0"` as a terminator on Range and chunk-size lines.
- **The `tchar` predicate is SHARED** between the request parser and the response-side header
  name check (`setValue:forAdditionalHeader:` — CFHTTPMessage sanitizes values but not names). A
  name beginning with a space serializes as an obs-fold continuation, silently appending it to
  the PRECEDING header's value (measured against the real `Date` header) — which is why the
  check must be the full predicate, not just non-empty.
- **`Transfer-Encoding` is parsed properly** (list split, parameters stripped, chunked must be
  the sole coding); anything that cannot be framed or decoded is refused, never treated as an
  empty body — exact-string matching once read RFC-legal `gzip, chunked` as "no body" after the
  destination had already been unlinked. The refusal status splits per RFC 9112 §6.1 (eighteenth
  pass): a coding the server does not IMPLEMENT (`gzip, chunked`, `gzip`) answers **501**; a
  malformed APPLICATION of an implemented one (`chunked, chunked`, `Content-Length` alongside
  chunked, an unparseable Content-Length) stays 400. The split is decided by
  `WSKTransferEncodingIsUnsupported`, which shares its tokenizer with the framing decision in
  `WSKRequest` — by the time the connection writes the refusal, both cases are just a nil
  request, so the connection has to re-ask. Chunked framing and interim `100 Continue` are never
  sent to HTTP/1.0 clients, which read them as body.
- **`Content-Encoding`: `gzip` and `x-gzip` decode** (RFC 9110 §8.4.1 defines `x-gzip` as a
  synonym; refusing it trades silent corruption for an interop bug); every other coding is 415,
  because storing still-encoded bytes as the entity is worse than refusing. A truncated gzip
  body is refused; a member with trailing bytes is refused **regardless of TCP segmentation**
  (the verdict once depended on how the client split its writes — the split-invariance property
  is the invariant to preserve); a valid body that exactly fills the read is accepted (commit
  `d7a290a` fixed over-refusal there — the fifth-pass description of gzip semantics is
  superseded twice, so derive current details from code). The decoder's `close:` closes the
  downstream writer even when refusing, so a refused transaction leaves no descriptor or staging
  file behind.
- **Refusals are evaluated on headers, before the body is read** — the Host allow-list and
  `-preflightRequest:` both run via a single `-_responseForRejectedRequest` as soon as headers
  are available.
- **Multipart**: `,` delimits only BEFORE a parameter name (RFC 2046 allows a comma in a
  boundary — `boundary=ab,cd` must not truncate). The parser budget (`WSKMIMEStreamBudget`) is
  shared with every sub-parser because nested `multipart/mixed` appends into the same arrays;
  part-header blocks are capped (`kMultiPartMaxHeadersLength` — an 8 MB part *name* was once
  retained and charged to nothing); total parts capped at `kMultiPartMaxParts` (1024, which also
  bounds temp-file/inode use). The initializer establishes `[super init]` and the `_tmpFile = -1`
  sentinel BEFORE any failure return — under ARC a nil-returning initializer still deallocates
  its receiver, and `-dealloc`'s `close(_tmpFile)` on a zeroed object was `close(0)`, tearing
  down a live connection when the descriptor slot was recycled.
- **Digest auth works over full bytes** — `-UTF8String`+`strlen` truncates at an embedded NUL,
  which survives from the wire into `request.headers`, and once made nonce integrity tags
  forgeable. Header-parameter extraction requires a token boundary (`scanUpToString:` finds
  `name=` inside `filename=` and `nonce=` inside `cnonce=`; Digest was a permanent 401 loop for
  any RFC 2617 client sending `cnonce` first). `filename*` is escaped with an escaper that
  covers `;` — the parameter delimiter — because a query-string escaper once let
  `evil.command;ok.txt` be delivered as `evil.command`, defeating `allowedFileExtensions` at the
  point that matters.
- **Host validation lives in the connection layer, AHEAD of `-preflightRequest:`** (a
  subclassing point must not be able to switch it off), so WebDAV and host-app handlers inherit
  it. IP literals are accepted by SHAPE, never by resolving and comparing against local
  interfaces — the attacker controls that DNS, so it resolves to us and the check evaporates;
  the asymmetry (a browser scripting from a domain cannot put a raw IP literal in `Host`) is the
  entire defence. Rejections log the name, path, peer and full accepted set, deliberately loudly.
  A trailing-dot FQDN normalizes. The port comparison is REMOVED (a judgement call, easy to
  reverse): `Host` derives from the request URL, so a browser can only state this server's port;
  a differing port comes from a forwarder or a non-browser client, against which rebinding does
  not apply. The uploader's CSRF check (Origin vs Host) is sound *because* Host is validated
  first. Three eighteenth-pass refinements, none of which moves the rebinding defence:
  **an ABSOLUTE-FORM target's authority is what gets validated and the Host header is ignored**
  (RFC 9112 §3.2.2 — the old order let the more attacker-shaped input win; not browser-reachable,
  browsers send absolute-form only to proxies). The form flag comes from the RAW request line
  (`_requestTargetIsAbsoluteForm`), NEVER from `_request.URL.host` alone —
  `CFHTTPMessageCopyRequestURL` synthesizes an absolute URL FROM the Host header for origin-form
  requests, so by the time a URL exists, "the target carried an authority" and "Host did" are
  indistinguishable, and CF has already sanitized the value ("bad host value" came back as a
  clean host, which silently defeated the syntax rule below — measured, the one green-phase
  failure of the pass). **More than one Host line answers 400** (in the block validator).
  **A refusal splits by syntax**: not even a well-formed authority → 400 (RFC 9112 §3.2), a
  well-formed name this server does not serve → 421 — judged only on the REFUSAL path,
  deliberately, so an operator who allow-listed an odd spelling keeps it (an exact match is
  admitted before syntax is ever asked).
- **A mapped HEAD gets a bodiless response** (it once ran `/events` and registered an SSE channel
  no client ever held). The deliberate exception that is NOT fixed: with
  `WSKOption_AutomaticallyMapHEADToGET` = NO *and* a host-app handler registered for HEAD, a body
  is written (RFC 9110 §9.3.2 violation) — the obvious fix keys on `_request.method`, which is
  whatever the match block stamped, and would suppress a genuine GET's body. Nothing in the tree
  does either half; if it ever becomes reachable, fix it off the WIRE method.
- **The `SO_NOSIGPIPE` result is checked and the socket dropped on failure.** If the peer's RST
  has already reached the kernel, Darwin fails the setsockopt with EINVAL and leaves it OFF, so
  the next write raises SIGPIPE and kills the process — measured dying at reset #13, exit 141,
  roughly once per 15–25 abortive closes. `testAbortiveClientResetsDoNotKillTheProcess` drives
  300 abortive resets (2 rounds × 150) and asserts only that the process survives and the listener
  still serves; the guard firing 72–94 times was an out-of-band log observation, not an assertion.
  Never remove the check.
- **`WSK_DCHECK` is a no-op in Release** — a property enforced only by a DCHECK is unenforced in
  production. **`WSK_DNOT_REACHED()` is `abort()` in Debug** — remote-input paths must
  log-and-fail instead (the converted sites: `GET /%FF`, `?a=%FF`, malformed multipart part
  headers, `Content-Length` alongside chunked, a file vanishing mid-listing).
- **Fourteen reason phrases are supplied** — CF's table stops at HTTP/1.1 as of 1999, and three
  post-1999 statuses are emitted in ordinary operation: 421 (the whole DNS-rebinding defence,
  once serialized as `421 Bad Request`), 424 (PROPPATCH atomicity), 431 (header cap). Only those
  fourteen; everything CF gets right is left to CF, so the corpus's four statuses still
  serialize byte-for-byte.
- **Reflected strings are clamped at the single point they pass through** (a 16 MB PROPFIND once
  produced a 96 MB error page and 540 MB RSS — the HTML escaper expands `"` sixfold through
  UTF-16 passes); PROPFIND/LOCK bodies are capped at `kDAVMaxRequestBodyLength` before the
  libxml2 DOM (16 MB of empty elements once took RSS from 5 MB to 561 MB). `_EscapeHTMLString`
  escapes `& < > " '` with `&` FIRST; directory-listing hrefs are HTML-escaped AFTER being
  percent-encoded, in that order (the URL escaper leaves `&` alone, so `&colon;` reconstituted
  `javascript:` via the browser's entity decoder); `_XMLEscape` drops control characters illegal
  in XML 1.0, which filenames may legally contain.
- **Filesystem-error mapping**: ENOSPC/EDQUOT answer **507 Insufficient Storage** for PUT,
  MKCOL, COPY and MOVE (was 500/500/403/403 — 403 is a claim the client may NEVER do this, so a
  client that would retry after freeing space gives up permanently; RFC 4918 §11.5). Both
  spellings must be read: `NSFileManager` reports `NSFileWriteOutOfSpaceError`, while `EDQUOT`
  only arrives as a POSIX errno under `NSUnderlyingError`.

### File serving and connection reuse

- **Every file-vending surface honours `Range` and `If-Range`.** The uploader's `/download` was
  the last that did not: it built its response with `+responseWithFile:isAttachment:`, which
  passes `NSMakeRange(NSUIntegerMax, 0)`, so every range request was answered 200 with the whole
  file — including an unsatisfiable one that owes 416. An interrupted download of a large build
  therefore could not resume, which Shape A treats as a main path. Going through the `ifRange:`
  variant is also what brings the If-Range protection with it, so a resume against a REPLACED
  file is refused rather than spliced.
- **`/preview` serves inert media inline; `/download` is always an attachment.** Inline content
  runs in the server's OWN origin, and the uploader's one-click buttons delete and move files,
  so an uploaded `.html` served inline is stored XSS against the share. That is why `/download`
  forces `attachment` and why the flag cannot simply be relaxed — `<img src="/download?…">` gets
  a save dialog. `/preview` is a separate endpoint with an allow-list of whole types a browser
  renders but cannot execute, plus `Content-Disposition: inline`, `nosniff`, and a policy
  denying every subresource. **`image/svg+xml` is excluded deliberately** and is the reason this
  is an allow-list rather than "anything beginning `image/`": SVG carries and runs script, so an
  "images are inert" rule admits the one image that is not. PDF is out for the same reason. Both
  remain downloadable — refusing inline removes a file from the inline surface, not the share.
  Both endpoints share one resolution walk, so every refusal `/download` makes `/preview` makes.
- **`fileCacheControlMaxAge` is opt-in and defaults to 0**, which keeps `no-cache`. That does
  not mean "do not store": a browser keeps the body and revalidates with `If-None-Match`, so a
  thumbnail grid already costs 304s rather than transfers. A non-zero age removes the REQUEST,
  which is the win for many small images and the cost of a window in which a browser may serve
  content the share no longer holds.
- **Connection reuse is opt-in via `WSKOption_ConnectionKeepAliveTimeout`, default 0** — one
  request per connection, as it always was, until a deployment sets it. **Reuse is restricted to
  requests carrying NO body framing at all**, and that restriction is the design rather than a
  simplification: request smuggling is a disagreement about where one request's body ends and
  the next begins, so a connection on which no body is ever read cannot be desynchronized. The
  guarantee stays STRUCTURAL rather than becoming "we parse carefully". Everything else answers
  and closes as before — a body of any kind, a refusal, HTTP/1.0, a client asking to close, a
  response whose length cannot be stated, a partial body write, and anything past
  `kMaxRequestsPerConnection`.
  **Eligibility reads the RAW header names, never `-[WSKRequest hasBody]`.** `hasBody` keys on
  `_contentType` and is only equivalent to "has body framing" because `-initWithMethod:`
  maintains the correspondence thirty lines away — and it is NOT equivalent for
  `Transfer-Encoding: identity`, which sets no content type, so `hasBody` answers NO for a
  request that does carry transfer-coding framing. That is exactly the shape a TE.CL desync is
  built from, and gating on `hasBody` would have made it the one eligible shape.
  Measured 0.515 → 0.377 ms/request (26.7%) on loopback, where the handshake is nearly free; on
  a real link it is about one RTT per request.
- **A request served from `_carryOverData` is NOT idle, and the reaper must be told so at the point
  the carry-over is consumed.** "Has the next request started arriving?" was a read-count
  comparison, which a pipelined request can never satisfy — its bytes were counted against the
  request BEFORE it, so no read happens and the count never rises. The connection therefore stayed
  marked idle while its response streamed, and the keep-alive deadline cut the body off mid-transfer
  under a `Content-Length` it then never reached: measured **15,867,384 of 16,777,216 bytes** at the
  default idle timeout, and 3,622,183 of 8,388,608 in the regression test. A complete, well-formed,
  WRONG response — the same shape as the in-place-rewrite splice, and the reason
  `testPipelinedRequestIsNotReclaimedWhileItsResponseIsStillStreaming` carries a SEQUENTIAL control
  that must pass on both trees: without it the test cannot tell this apart from the ordinary
  response-phase idle rule.
- **Bytes past the header block are TRIMMED to `Content-Length`, never refused.** Requiring
  `extraData.length <= contentLength` honoured a guess about segmentation — TCP may deliver a body
  and whatever follows it in one read — and answered 400. It was **reachable in the DEFAULT
  configuration** (no keep-alive needed, one write is enough) and predates connection reuse
  entirely; the split-invariance oracle found it, not reading. The remainder is DROPPED, never
  interpreted: a request carrying body framing is not eligible for reuse, so the connection closes
  after it and nothing is framed by a length the next request could disagree about.
- **`-open` and `-close` are once per CONNECTION**, which is what their headers say and what a host
  app pairing them relies on. Reuse briefly called `-close` per REQUEST, giving one open and N
  closes. The per-request work — the access-log line and the trace recording — lives in
  `-_flushRequestRecordAndLog` instead, called as each response completes, with `-close` flushing
  only the request that has not been flushed yet. That guard is why `_requestLogged` is deliberately
  NOT cleared in `-_resetForNextRequest` (which runs whether or not another request ever comes) but
  where the next header block actually arrives.
- **A persistent connection ending because the client went away is its designed end, not a
  failure** — no `ERROR` log line, and no response. It used to write a 500 into a socket that was
  already gone, putting a fabricated server error in the access log for every well-behaved
  keep-alive client. Genuine read ERRORS still log as errors; only the EOF case changed.

### Limits and budgets

All fixed safety constants, deliberately NOT options (like `kHeadersMaxLength`). They cap only
data held in memory; bodies streamed to disk (uploads, WebDAV PUT) are deliberately unlimited.

- **`kWSKMaxTotalInMemoryLength` (64 MB)** bounds the SUM across all live connections — per-
  request limits do not compose (with the 128-connection cap the old real ceiling was ~2 GB of
  chunked framing buffers or ~8 GB of inflated gzip). Charged sites: data-request bodies,
  inflated gzip output, multipart argument parts, each multipart working buffer, the chunked
  framing buffer. **The reservation is an OBJECT whose bytes are returned in `-dealloc`**, so a
  connection dying mid-body cannot leak budget — the budget is process-wide static state with no
  reset. The gzip decoder charges its LIVE buffer, before growing it (charging cumulative output
  once parked 63 of the 64 MB permanently on 64 KB of traffic). Verified: 24 concurrent chunked
  bodies peaked at exactly the ceiling, never above, and returned to zero.
- **`kWSKMaxInMemoryBodyLength` (16 MB)**, **`kWSKMaxDecompressedBodyLength` (64 MB)**: enforced
  at the data-request body, inside the gzip inflate loop (so a zip bomb cannot balloon the buffer
  first), the multipart working buffer (whose cap also fixed a stall on a boundary token with no
  trailing CRLF), and a single chunked chunk. **Consult `WSKMaxInMemoryBodyLength()` /
  `WSKMaxDecompressedBodyLength()`, never the `kWSK…` constants**, so
  `WSKSetMemoryLimitsForTesting` overrides are honoured — proving a bound against 64 KB instead
  of 16 MB is what fixed the flake that lost the test runner in half of full-suite runs.
- **Budget exhaustion surfaces as 500, not 503** — settled ONLY in the narrow sense that swapping
  this one status is not worth destabilising the body-read path. It does not settle the wider class:
  EVERY body-read failure collapses to 500 for the same reason, which is the top item under Still
  open. Settled: the body-writer protocol reports
  failure as a plain BOOL; threading a status through it was judged not worth destabilising the
  body-read path. Do not "fix" the 500 without accepting that trade.
- **Idle timeout**: hard deadline (`kMaxHeaderPhaseTicks`) while `_request` is nil; while the
  BODY arrives the floor is `kMinReceiveBytesPerSecond` scaled by tick length (a rate, not an
  absolute per-tick count — the absolute version disconnected slow-but-genuine uploads); the
  response phase keeps the lax any-byte-is-progress rule so a slow-but-live SSE reader is never
  cut; time inside a handler NEVER counts.
- **A body read that fails** (disconnect, malformed framing, cap rejection) aborts the request —
  never process a partial body as complete.

### WebDAV semantics

- **Class 1 is complete.** A property that cannot be returned gets its own propstat with 404;
  requested names are echoed in the requester's namespace; `<propname/>` returns names with
  empty values; an unrecognised Depth is still refused.
- **Status conformance (all four found by an outside audit, closed together).**
  `MKCOL` on a URL that already identifies a resource answers **405 with `Allow`** per §9.3.1 —
  it answered 500, because `EEXIST` arrives as `NSFileWriteFileExistsError` and the error
  mapping recognises only the full-volume cases. That matters because "MKCOL each ancestor,
  treat 405 as already-exists" is how every client builds a tree, so a 5xx aborts the copy. An
  existing **file** at the name is also a §9.3.1 case and takes the same branch; the window
  between the preflight and the create is covered by mapping `EEXIST` at the creation site too.
  `PROPFIND` with **no** `Depth` answers 403 with `<DAV:propfind-finite-depth/>`, because §9.1
  makes an absent Depth mean `infinity` — only the explicit spelling reached that branch before.
  `COPY` with `Depth: 0` on a collection now genuinely copies the collection WITHOUT its members
  (§9.8.3); the header was validated and then discarded, so a client asking for a shallow copy
  was answered 201 and handed the whole subtree. A plain file is deliberately unaffected — with
  no internal members, `Depth: 0` and `Depth: infinity` mean the same thing, and `Depth: 0` is
  accepted on COPY and DELETE of one for that reason.
  `Allow` advertises **PROPPATCH** (implemented since the class-1 work, never advertised, so a
  client reading OPTIONS concluded it was unavailable), and **all four** 405 sites route through
  one `_MethodNotAllowed()` helper so a refusal added later cannot omit the header — it was
  missing from two of the four.
- **PROPPATCH**: dead properties live in ONE extended attribute holding a plist keyed in Clark
  notation (`{namespace}localname`) — one blob, so keys never need escaping into xattr names and
  a property set cannot half-apply. Atomic per RFC 4918 §9.2: computed against a copy, written
  only if nothing was refused, so a 424 client can retry the whole document. Live properties are
  refused 403. A filesystem without xattrs (`ENOTSUP` — exFAT among them, measured) becomes a
  per-property 403, not a pretence of storage. PROPFIND and PROPPATCH share ONE convention for a
  no-namespace property (they once disagreed — storable but never readable back; litmus found it
  when 122 passing tests and a live Apple client both missed it).
- **The LOCK stub is deliberately a stub**: `performLOCK` mints a token, returns a well-formed
  `lockdiscovery` document and stores NOTHING — no lock table, no timeout, no `If:` parsing. It
  exists solely because Finder refuses to write to a share not advertising class 2. Not made
  real, deliberately: deployments are single-user, the same lost-update protection exists
  statelessly via `If-Match`/`If-Unmodified-Since` (usable by every client, not only lockers),
  and real class 2 needs the `If:` grammar — a parser, and parsers have been the richest defect
  source here. Sharp edges an auditor will trip on: the whole class-2 façade is **Finder-only**
  (`_IsMacFinder` — `WebDAVFS/`/`WebDAVLib/` user agents; everyone else gets `DAV: 1` and 405
  for LOCK/UNLOCK), and the stub requires `Depth: 0` exactly — a LOCK with no Depth answers 403
  even from Finder's user agent, which is fine because Finder always sends it (the recorded
  traces are the proof). Since the eighteenth pass a new lock also returns the RFC 4918 §9.10
  `Lock-Token` response header (Finder reads the body's `locktoken`; a conforming client is
  entitled to the header — the affected recordings had the one header line added, verified as
  the only byte difference), and **`Allow` tells the same per-client story as `DAV`**: the
  class-1 list for non-Finder clients, so the 405 a non-Finder LOCK receives no longer lists
  LOCK inside its own refusal (RFC 9110 §15.5.6 — Allow is the target's CURRENTLY SUPPORTED
  methods).
- **MOVE/COPY stage unconditionally and swap EXCLUSIVELY** (`renamex_np(RENAME_EXCL)`) when
  nothing was vetted, so an item appearing in the window survives and the request refuses.
  `existing` detection is deliberately unchanged: `-fileExistsAtPath:` follows links, so a
  dangling symlink at the destination reads as absent — under exclusive swap it simply makes the
  swap fail and the link survives (the old cleanup unlinked it while answering 403). The
  rejected alternatives were both measured: stage-and-always-swap destroyed MORE (83/144
  answered 201 vs 25/95 unfixed — the rename fallback is a recursive delete); remove-only-the-
  staging-path strands a partial tree. The replace-swap fallback **carries the `dev`+`ino` the
  caller vetted and refuses to remove anything else** — vetting thirty lines above the swap is a
  TOCTOU window (a collection arriving in it was once destroyed with 204).
- **The exFAT fallback fires ONLY on ENOTSUP/ENOSYS** from `renamex_np` (macOS 15 FSKit exFAT
  returns ENOTSUP; APFS, FAT32 and HFS+ implement it — which is why the APFS-only test suite
  never saw it; measured on a real exFAT image 0/10 before, 10/10 after). It reserves the name
  itself (`mkdir` for a staged directory, `open(O_CREAT|O_EXCL)` otherwise), and if the
  following `rename(2)` fails it reclaims the reservation and preserves the ORIGINAL errno.
  Every other errno — `EEXIST` above all — must keep failing, or the racing newcomer the branch
  protects gets clobbered.
- **`Overwrite` is case-folded** through the shared `_HeaderTokenIs` (comparing
  `-isEqualToString:@"F"` meant that exact byte was the only "do not overwrite" and `f`,
  `False`, `no`, `0` and empty were all taken as permission — fail-OPEN, and lowercase `f` is
  RFC-conformant). Overwrite vetting routes through the shared `WSKFirstUnvettableItemAtPath`
  used by DELETE too — and note again that it returns nil when no allow-list is set, so nothing
  that must run by default may live inside it.
  **MOVE and COPY are deliberately asymmetric and this is not a defect**: MOVE refuses unless
  the value is `T` (fail-closed, against RFC 4918 §10.6's default, recorded under Settled
  decisions), while COPY refuses only on `F`. An outside audit reported the COPY arm as a P0
  fail-open; it is not, because §10.6 makes an ABSENT `Overwrite` mean `T`, so a non-conformant
  value grants a client nothing it could not have by omitting the header. A strict server could
  answer 400 for a third value; that is a conformance nit, not an authorization defect.
- **MKCOL removes the collection if a later step fails** before the error goes out — otherwise
  the client is told the method failed, the collection exists, and the retry gets 405. "A
  refused transaction leaves nothing behind" applies to failure paths.
- **COPY with `Destination` inside the source is refused as a precondition** before any
  filesystem work (`NSFileManager` re-enters the tree it walks and otherwise fails only at
  `PATH_MAX`, ~250 directories down, with cleanup success dependent on the share's path length).
  `Destination` is parsed as a URI (substring-searching the Host value once landed
  `Destination: /moved.txt` at `<share>/t` when `Host: x`).
- **The uploader's `/upload` and `/move` have NO overwrite path** — they route through
  `-_uniquePathForPath:`. Deliberate asymmetry, not a parity gap: only WebDAV implements RFC
  4918 `Overwrite`.

### Long-lived surfaces (SSE, Bonjour, lifecycle)

- **SSE delivery is per-connection FIFO buffering** (`WSKWebUploaderSSEChannel`): the async
  streaming API is a strict ping-pong (one completion block, called once per chunk; between
  calls no reader waits), so a shared-array broadcast collapses bursts to one delivered event.
  **Every stop path must call `-close`** (heartbeat reap, `-stop`, disabling SSE, losing the
  registration race): it completes any parked reader with empty data — the end-of-stream
  sentinel — and makes future `parkReader:` calls complete the same way. Merely dropping the
  channel from `_sseChannels` strands the connection parked forever via the retain cycle
  connection → response → stream block → channel → parked reader → connection, and
  `_activeConnections` never reaches zero.
- **The channel dies with its connection** (halving, not cure: 62 s → 32 s for graceful closes;
  the 15–30 s the server takes to DISCOVER a departed client remains, because nothing tells it
  until a write fails; the heartbeat reaper — two consecutive idle ticks — is the backstop for a
  merely-silent client; `retry: 30000` in the refusal body is the one-constant lever on the
  client-visible half). The "quiet client is never reaped" claim was REFUTED by measurement: 16
  such clients against a 16-channel server, sampled every 15 s for 90 s — a real client still
  obtained a stream at 5 of 7 sample points. Do not re-open it as a denial of service.
- **One stream per browser**: a single tab holds `/events` under a Web Lock and relays over a
  `BroadcastChannel`; the browser itself releases the lock when the holding tab goes away, so
  there is no heartbeat, no timeout, and no way to leave the stream unheld or held twice.
  Reason: a browser allows six HTTP/1.1 connections per origin and an `EventSource` never
  completes, so six tabs deadlocked the whole UI (tabs 1–5 in 2 ms, the sixth timed out, a
  seventh blank for 13.5 minutes — with the server idle: 122 free slots, 10 free channels).
  `kMaxSSEChannels` (16) now bounds browsers rather than tabs. It does NOT follow that 16 browsers
  are servable — that figure is untested, and `index.js` still carries the original finding that 16
  sits above the bound which actually binds. **The rejected alternative is recorded
  because it looks obvious**: closing the stream on `visibilitychange` was MEASURED as worse —
  the server reclaims a browser-closed channel only when a heartbeat write fails 20–33 s later,
  so tab switching left zombies (25/40 reconnects refused, the visible tab stopped updating),
  and it does nothing for six simultaneously visible tabs. Do not swap it in.
- **`/events` defence**: the same Origin-reading `-_rejectIfCrossOrigin:` as the mutating
  endpoints (Sec-Fetch-* headers are absent on every browser predating them — Safari < 16.4,
  Firefox < 90, exactly the browser an attacker would choose — so a Sec-Fetch-only check fails
  open), PLUS `Sec-Fetch-Mode`/`Sec-Fetch-Site`, PLUS `Accept: text/event-stream`. Non-browser
  clients send no Origin and are unaffected; the served page's own EventSource sends a matching
  one; both directions are asserted, because refusing the real UI is the easy mistake.
- **SSE event paths resolve symlinks on BOTH sides.** Neither `-stringByStandardizingPath` nor
  `-stringByResolvingSymlinksInPath` expands `/var` to `/private/var`; only `realpath(3)` does —
  so a prefix comparison mixing the two fails for EVERY share under `NSTemporaryDirectory()`,
  which made every change event name the share root (`path":"//"`) and live updates silently do
  nothing for every subfolder, in the uploader's ordinary deployment. This mismatch has bitten
  in THREE different methods now; treat any new prefix comparison as suspect. Two further rules
  the third one taught:
  **`-presentedItemURL` must hand out the RESOLVED root**, because `NSFileCoordinator` matches a
  presenter against the canonical path of the changed item — registering under a symlinked
  spelling produced not fewer events but ZERO, against 8 on a same-process real-path control, i.e.
  the whole external-change feature absent for a deployment whose share is a link. It deliberately
  reads the ONCE-captured `_resolvedUploadDirectory` and must not re-resolve per call:
  `NSFilePresenter` requires this URL to stay put while registered.
  **`-_relativePathForAbsolutePath:` re-resolves on a miss**, so a share whose realpath changes
  under a live server (a symlinked share repointed — how an atomic publish swaps one) does not
  silently revert every event to naming the root. That result is NOT cached back, for the reason
  directly above. Its prefix test also compares against `root + "/"`; a bare `hasPrefix:` mapped
  the sibling `…/Share2/x.txt` into a share at `…/Share` as `/2/x.txt` (not reachable from the
  network — every caller's path is already resolved inside the share — but wrong in the function).
- **`-bonjourName` reads `_registrationService`** — the service actually registered, which
  carries an auto-rename. `CFNetServiceCreateCopy` taken right after registration is *initiated*
  freezes the configured name (registration is asynchronous; flags 0 means auto-rename is ON),
  so the copy never sees `<name> (2)`. Measured with two servers sharing a name: before, both
  reported the configured name; after, the renamed one reports `WSKRenameProbe (2)`.
- **A failed iOS foreground restart logs the error in the NON-SUSPEND path only.**
  `-_reconnectInForeground:` (registered when `WSKOption_AutomaticallySuspendInBackground` is NO)
  passes a real `NSError **` and logs it. Its sibling `-_willEnterForeground:` — the handler used in
  the DEFAULT configuration — still calls `[self _start:NULL]` under the original "TODO: There's
  probably nothing we can do on failure", so a failed resume there is silent. Still open, and the
  signature shape: closed at one of the two sites the rule applies to.
  `-isRunning`/`-serverURL` correctly report
  stopped (measured 7/7 on both trees — the recorded claim that they lie was FALSE), and
  `-_stop` posts `-webServerDidStop:` exactly ONCE — a second synchronous delivery was added on
  a false justification and removed (it arrived first and inverted ordering against
  `-webServerDidDisconnect:`). Exactly one delivery site remains in the tree. Delegate callbacks
  from lifecycle code are delivered on the main thread and OUTSIDE `_stateQueue` — a delegate
  reading `-serverURL` from inside that block would deadlock.
- **All lifecycle mutation and the `isRunning`/`serverURL` accessors funnel through the serial
  `_stateQueue`.** Deadlock-free by construction: nothing on `_stateQueue` blocks on the main
  queue, the accept handler touches only `_syncQueue`, and the cancel handlers
  `dispatch_group_wait` waits on run on a global queue doing only `close()` + leave. (Prior
  symptoms: concurrent stops double-released a dispatch source; an orphaned source left
  `_sourceGroup` permanently entered so every later `-stop` hung.)
- **Each connection SNAPSHOTS the server's mutable config in `initWithServer:`** (serverName,
  auth realm/accounts, HEAD→GET flag) and serves its whole life from the copies. Intentional
  semantics, not just a race fix: an accepted connection keeps the config it started with. The
  snapshot is race-free ONLY because the accept handler runs solely while the listening socket
  is live — after `-_start` populates config, before `-_stop`'s barrier;
  `-_reconnectInForeground:` re-runs start/stop on EVERY foreground transition in non-suspend
  mode, which is why the race was hot.
- **NAT-PMP callbacks are confined to `_stateQueue`** with two sharp edges: `_DNSServiceCallBack`
  runs INSIDE `DNSServiceProcessResult` and must not re-dispatch, and the delegate is notified
  asynchronously or a delegate reading `publicServerURL` would deadlock.
- **`serverSentEventsEnabled` defaults to YES**; the `NSFilePresenter` registration is installed
  only while enabled (it participates in system-wide file coordination). External changes are
  monitored recursively via `presentedSubitemDidChangeAtURL:` with 100 ms coalescing; presenter
  paths are compared after `URLByResolvingSymlinksInPath` on both sides.
- **`index.js` has NO test harness.** The XCTest suite is structurally blind to it (it stayed
  118/118 through browser fixes in both states); every JS change must be verified by a Chromium
  probe against the unfixed and fixed builds. Current JS invariants: re-entrancy is a boolean
  owned solely by `_reload()` and cleared in its `.always()` (which jQuery always runs), and
  whether a rename editor is open is DERIVED FROM THE DOM — **do not reintroduce a shared
  counter**: `_reloadingDisabled` wedged the page permanently twice (a throw skipping the
  release; `$("#listing").empty()` destroying the editor so jeditable's `onsubmit`/`onreset`
  never fired), and the "obvious repair" (decrement per destroyed editor) goes NEGATIVE because
  jeditable's `onblur: 'cancel'` fires `onreset` too — just as truthy, wedging identically. The
  self-healing property is the point: a missed flush leaves a stale listing until the next
  reload, not a frozen page. The SSE `onopen` re-sync targets the path most recently REQUESTED
  (`_path` is only assigned when a listing returns, so the in-flight window used to bounce deep
  links to the root, 33/40). The rename comparison is against what the box can actually hold —
  `<input type=text>` applies the "strip newlines" algorithm, so a CR-bearing filename made
  `value != name` unconditionally true and Enter renamed with nothing typed.

### API shape

- **The rename box is seeded with the real name from `/list`.** jeditable otherwise pre-fills from
  the element's serialized HTML, so `A & B.txt` becomes `A &amp; B.txt` and then `A &amp;amp; B.txt`
  on the next pass — silently corrupting a common character. The value jeditable returns is put back
  with `.html()`, so it must be escaped on the way out. Same family as the CR-filename fix one layer
  up, except there the mangling is the browser's own and no seeding can cure it.
- **Public `WSKFunctions.h` is 11 declarations covering exactly seven general-purpose areas**: URL escaping, MIME type, primary IP,
  the HTTP date format/parse pair, form parsing, the NUL check, the filesystem-error status
  mapping. The fourteen audit-shaped functions (resolvers, vetting walks, allow-list predicates,
  validators, same-file detection) live in `WSKPrivate.h` — every one changed contract during
  the audit programme, each a silent source break for anyone bound to accidental public API.
  SPM sibling targets see `WSKPrivate.h` via ONE extra `headerSearchPath` — no new header, no
  modulemap change, no pbxproj change. The old recorded reasons this "could not" work were
  measured and neither reproduced (MEMORY.md's visibility rationale is stale; the symlink farm,
  hand-written modulemap and `SWIFT_PACKAGE` bundle accessor remain load-bearing and untouched).
  `Framework/Tests.m` imports `WSKPrivate.h` — `WSKResolvedPathIsWithinDirectory` has eleven
  direct assertions there, which is why it must stay linkable, not `static`.
- **Nullability tells the truth, source-breaking for Swift deliberately**: the three
  `WSKFileResponse` properties (above); `allowedFileExtensions` on both servers and `title`,
  `header`, `prologue`, `epilogue`, `footer` on the uploader are `nullable` because nil is
  MEANINGFUL for every one (no restriction; use the computed default) — substituting a value
  would destroy information; `localAddressData`/`remoteAddressData` are `nullable` (match-block
  window).
- **`+responseWithFile:` honours its `nullable` declaration** for an empty or NUL-bearing path
  instead of raising (`-fileSystemRepresentation` raises `NSInvalidArgumentException` for both —
  guard every new call site; the fifth recurrence of this class was self-inflicted three files
  from the comment explaining the hazard). The NUL check is kept even though `open(2)` would
  truncate: truncating acts on a prefix of what was asked, refused everywhere else here.
- **`+responseWithJSONObject:` asks `+isValidJSONObject:` FIRST** —
  `+[NSJSONSerialization dataWithJSONObject:]` RAISES for an unserialisable object (`NSDate`,
  `NSURL`, `NAN`), so a nil guard after the call is dead code and `resp ?: fallback` does not
  help.
- **The four public date functions initialize via `dispatch_once`, lazily from each** — callable
  before any server exists (previously an immediate crash; the real oracle is out-of-process: a
  binary linking the framework that names `WSKWebServer` nowhere — fixed prints OK, unfixed
  exits 139). Safe off the main thread; the formatters pin `en_US`/GMT (held across 80,384
  round-trips in 6 timezones and 10 non-Gregorian calendars).
- **`addGETHandlerForBasePath:` normalizes leading/trailing-slash spellings** (neither is
  ambiguous) instead of aborting/registering nothing; its documented no-match status is the 404
  it actually returns. `-stop` after a FAILED start is idempotent tidy-up.
  `-startWithOptions:error:` on an already-running server returns NO with `*error` set.
- **Handler registration order is REVERSE match order** (handlers insert at index 0): a
  catch-all must be registered FIRST so it matches LAST — backwards shadows the page and every
  asset while still passing a naive 404 check.
- **The uploader's clickjacking control is serving ONLY the three asset directories the page
  loads** (`css`, `js`, `fonts`) — the raw template and `Localizable.strings` are out of the URL
  space entirely. `/index.html` is a convenience alias and explicitly NOT the control: **an
  exact path is not a containment boundary** (`/./index.html` and `/x/../index.html` both defeat
  it through a normalizing handler).
- **`WSKStreamedResponse` releases its block on `-close`** to break handler retain cycles.
- **`__WEBSERVERKIT_ENABLE_TESTING__` is defined at PROJECT level in Debug only** — so every target
  carries it in Debug — **plus BOTH configurations of the `WebServerKit Example (Mac)` target**,
  which `Run-Tests.sh` builds in Release. It is absent from project-level Release, and that is what
  keeps it off the shipped framework's Release compile line. Do not "tidy" it to project level (that shipped
  client-settable file timestamps and a client-chosen lock token in Release) and do not remove
  it wholesale (that made all eight trace suites unrunnable for three passes). Note:
  `GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS` is excluded only from PCH generation — the
  `-D` still lands on the compile line.

### Verified clean — do not re-test speculatively

Negative results that cost real machine-time to establish. Re-run them only when the layer they
exercise changes, not on suspicion.

- **Site inventories already done by DRIVING each entry point, not grepping**: the NUL guard was
  confirmed present at all 10 client-path entry points that way. Redo it the same way if you redo
  it — a grep for the guard is what missed two multipart sites once.
- **Split-invariance is clean since the gzip fix**: 1,143 same-bytes-different-segmentation pairs
  plus 2,700 randomized splits, zero verdict differences, including the 256 KiB×2^k band where the
  ninth pass's defect lived.
- **HEAD/GET parity** exact across 79 header-by-header comparisons.
- **The staging-swap failure path**, forced with an immutable child: 30 COPY + 30 MOVE left zero
  staging siblings and restored the source 30/30.
- **40 interrupted-and-resumed 128 MiB transfers** reassembled byte-perfectly.
- **Differential against an independent HTTP implementation**: this library was MORE correct on
  Range arithmetic across 1,200 generated headers; upstream GCDWebServer builds on a current
  toolchain and the behavioural differential found only the hardening intended and documented.
- **600 start/stop cycles, 1,900 aborted transactions and an idle-timeout evasion matrix**: no
  hang, no deadlock, no unreclaimed slot.

- **Nothing accumulates.** Five-hour soak: 19,723,889 requests, 15.6 TB, 12 concurrent workers
  (ranges, revalidation, abortive deaths) with the served file rewritten every 750 ms —
  descriptors ended BELOW baseline, `reservedInMemoryByteCount` 0 at every sample and at rest.
  Also: 676,970-request soak, 67 failure scenarios × 250 iterations at exactly baseline
  descriptors, the budget driven to its ceiling and abandoned 150 times with `SO_LINGER {1,0}`
  and still 0 at rest. An RSS creep of ~15 B/request was chased and proved allocator behaviour
  (`leaks(1)` zero; live bytes fell between samples; a legitimate-traffic control showed the
  same slope). PR #72's connection reuse HAS since been soaked with keep-alive ENABLED — 6.01 h,
  85,210,679 requests, 14.4 TB, descriptors at baseline and `reservedInMemoryByteCount` 0 at rest
  (run against a keep-alive-OFF control in the same process, so a divergence would have pointed at
  reuse rather than at load; peak +38 descriptors in flight, budget nonzero in 47 of 392 samples
  and never above 22 bytes).
  But that soak did not PIPELINE (its client read one response per write), so it never touched
  `_carryOverData`. **A pipelining soak has since run against the fixed tree**: 4.01 h, 748,020
  requests, 1.01 TB, **312,820 replies served from carried-over bytes**, descriptors +0 at rest,
  `reservedInMemoryByteCount` 0 with peak 0, zero unexpected statuses, still serving. Its
  short-body tripwire was PROVEN SENSITIVE first — 119 against the pre-fix framework, 0 at tip —
  which took two harness fixes to achieve and is the whole reason the 0 means anything (see
  Lessons). Unexplained and NOT waved away: 32,875 connect failures where the previous soak had
  zero, most likely listen-backlog saturation under 12 workers holding reused connections, partly
  competing suite runs — cause not established. Re-run when the connection or response layer
  changes (PR #48 did; the full re-run has since exercised it).

  **`task_info`'s `resident_size` is the WRONG metric for that judgement and nearly produced a
  false alarm.** It grew 8.6 MB → 3,005 MB over the keep-alive soak and looked like a leak.
  `leaks(1)` against the live process reported **0 leaks, 0 bytes, 17.6 MB of malloc'd nodes**,
  and the **physical footprint was 40.3 MB (peak 54.7)** at the same instant the harness reported
  1,957 MB. The gap is file-backed, reclaimable page cache for the 512 KB file being served tens
  of millions of times. `phys_footprint` is what macOS uses for memory pressure and jetsam;
  measure that, or `leaks`, and never report `resident_size` growth as accumulation.
- **Torn writes do not happen** — 240 concurrent 128 KiB + 90 concurrent 4 MiB PUTs, zero mixed
  files (the body always lands in a temp file first). **Atomic replacement under load is safe**
  — 915 `rename(2)` replacements, 47.7 GB, zero splices, with the oracle provably sensitive
  (1,584 splices the moment the writer switched to `O_TRUNC`).
- **The "refused operation changes nothing" invariant** held across 22,820 operations in 120
  sequences (checker proved sensitive by injection first). The three listings never disagreed
  across 431,151 requests. 316,047 trace-seeded mutated requests: no crash, zero
  "refused but changed" across 176,661 snapshot comparisons. 1,268,184 SSE connection attempts:
  all 16 slots reclaimed within two ticks, no retain cycle, Bonjour deregistering 9 Add / 9 Rmv.
- **Static analysis found nothing reproducible** (nine analyzer configurations, three engines,
  every plausible diagnostic then driven from the network; zero survived). After thirteen passes
  of runtime instrumentation, the remaining defects are not the kind a symbolic explorer finds —
  do not re-run it.
- **ThreadSanitizer's 4 data races in `-_stop` are FALSE POSITIVES** — a 200-trial experiment
  (198 genuinely overlapping) confirmed libdispatch orders a source's cancel handler after its
  in-flight event handler, an edge TSan does not model. Do not "fix" them.
- **Request smuggling is structurally impossible in the DEFAULT configuration** (keep-alive off, so
  one request per connection, `Connection: Close`, leftover bytes dropped) — verified LIVE by
  pipelining. With `WSKOption_ConnectionKeepAliveTimeout` set, that premise is preserved by
  restricting reuse to requests carrying NO body framing, so nothing can be framed by a length the
  next request disagrees about. That mode HAS now been probed: the split-invariance oracle replayed
  ten pipelined byte-streams — bodyless runs, a body between two GETs, a bad chunk, `Connection:
  close` mid-stream, an HTTP/1.0 request mid-stream — at every single-byte split offset and
  byte-at-a-time, 1,355 segmentations, run against BOTH trees with the same oracle: **14 status
  disagreements before, 4 and 6 in two runs after**. Read the BASELINES, not the counts — the
  counts are RST timing and move in both directions between runs (one shape went 1→0, another
  0→4), while the baselines changed exactly where they should: `200,400,close` → `200,200,close`
  and `400,close` → `200,close`, with "GET then bad chunk then GET" correctly still baselining at
  `400`. A genuinely malformed body is still refused; only the spurious refusal went. What remains
  is the RST-lost-response shape (`200,200,close` becoming `200,error`: the reply was produced, the
  client never got to read it), not a difference in what the server DECIDED. That is evidence
  against desync, not proof of its absence. ~7,000 mutated
  requests under ASan+UBSan: zero memory errors. 9,366 injected allocation failures: nothing,
  zero descriptor leaks.
- **The seventeenth pass's own changes were audited adversarially before the branch was handed
  over**, and the technique that found the defect was NOT the one aimed at correctness. A paired
  existence-oracle fuzzer (same request against an absent and a present target outside the share,
  over generated paths × depths × 12 verbs) read **940 disagreements out of 2,880 pairs against
  `main` and 0 at tip** — sensitivity proven, no new finding. What did find something was an
  AMPLIFICATION probe asking what a deep path now COSTS: 2,259 ms, i.e. the correctness fix had
  introduced a denial of service. Ask what a fix costs, not only whether it is right; the
  ~1-new-defect-per-5-fixed rate is real and it lands in exactly what the fix touched.
  `rclone copy dav:/nodir/deeper` was driven against both trees as the closing check —
  `CRITICAL … 403 Forbidden` before, `directory not found` after — and a real `mount_webdav` mount
  did mkdir, a 12 MB write, byte-identical read-back, list, rename, read-after-rename, `mkdir -p`
  on a nested path, copy, recursive delete and a clean unmount.
- **A whole-behaviour differential of the seventeenth pass against `main`** — 480 cells (15 verbs ×
  32 hostile targets: dangling and looping links, a link to the share root, a link to a subdirectory,
  dot-names, `%2e%2e`, `%23`, unicode, spaces, absent paths at three depths), recording for every
  cell BOTH the status and the resulting state of the share and of the directory outside it. 71
  status differences, every one falling into a bucket the branch intended (26 collection allow-list
  refusals, 18+8 escaping-link write refusals, 11 absent-path 403→404, 8 mixed), and — the number
  that matters — **0 cells where the status matched but the filesystem effect differed**. That is
  the shape a status-only differential cannot see and the one this project keeps being bitten by.
  The one cell needing a ruling rather than a fix is the symlink-vetting entry under Still open.
- **Concurrency and accumulation against the reordered write verbs**: 6 workers × 400 requests
  racing a component that flips between a real directory and a symlink out of the share. No 500 or
  dropped response that `main` does not also produce, nothing created outside that `main` does not
  also create, `reservedInMemoryByteCount` 0 at rest and descriptors BELOW baseline. The one
  difference was staging residue, which is the widened TOCTOU recorded under Settled decisions.
  **Three rounds of adversarial audit were run against this branch and the yield fell off exactly
  as the record predicts**: round 1 (paired oracle fuzzer + amplification probe) found a real
  denial of service; round 2 (whole-behaviour differential vs `main`) found one behaviour change
  needing an owner ruling and no defect; round 3 (concurrency + accumulation) found no new class,
  only a quantified widening of a documented one. Repeating a technique finds nothing; each round
  had to change lens to find anything at all.
- **Conformance and real clients**, RE-TAKEN against tip after the #70/#71/#75 status changes and
  unchanged: litmus `basic` 16/16, `http` 4/4, `locks` 3/3, `props`
  29/30 (sole failure still `propfind_invalid2`, settled). The four changed behaviours were also
  checked directly: MKCOL new 201 / existing **405**, PROPFIND with no Depth **403**, `Allow`
  carrying PROPPATCH, and an unknown target **404**. And driven through macOS's own kernel WebDAV
  client via `mount_webdav`: mkdir, 12 MB write, byte-identical read-back, list, rename,
  read-after-rename, copy, delete, `mkdir -p` on a nested path — which walks ancestors and so
  exercises the new 405 — write into it, recursive delete, clean unmount. All passed. (`cp` exits
  non-zero on extended attributes, which WebDAV has no transport for; the bytes compare identical.)
  Historic figures, not re-taken: 2.3 GB through a real `mount_webdav` mount
  byte-perfect across 33,269 mixed operations, 3,290 mount-vs-disk listing comparisons agreeing,
  34 hostile filenames including the NFC/NFD pair round-tripping; rclone `sync`/`check` agreeing
  both directions; the macOS client tolerates the dateless-PROPFIND window by falling back to
  `creationdate`. ENOSPC/EROFS across 14 verbs on a genuinely full volume: no staging residue,
  no half-files. A case-SENSITIVE volume did not weaken containment, hiddenness or the
  allow-list (26 probes). A volume force-ejected mid-transfer: no crash.
- **Host-app contract**: all 11 delegate methods on the main thread, no null-contract
  violations; all 21 wrong-typed option values refused with a named diagnostic; 21 lifecycle
  sequences including 8 threads × 60 concurrent start/stop with no hang or deadlock.
- **A dangling symlink no longer reaches the `_RealPath` fallback at all** — an entry that exists
  and cannot be resolved now fails closed, so it answers 403. The historical measurement (that even
  when such a link DID resolve inside the share, a PUT through it was refused with nothing landing
  outside) is kept as the record of a sound hypothesis that measured negative — but it is now a
  statement about removed code, not a current property.

## Settled decisions

Each is deliberate and carries its reason, because without the reason someone re-fixes it — which
has happened.

- **A MOVE with no `Overwrite` header answers 412 — when the destination EXISTS.** RFC 4918
  §9.9.3 says absent means `T`, but conforming would make MOVE destructive by default, against
  "refuse rather than half-succeed". The earlier spelling of this entry omitted the scope: a MOVE
  to a FRESH destination has nothing to overwrite and answers 201 with no `Overwrite` header at
  all (measured in the eighteenth pass — the code was always scoped this way; the record's
  sentence over-claimed).
- **The `//` status disagreement** (501 from the base-path handler, 404 from WebDAV) stays. Both
  refuse; only the status differs. Cosmetic.
- **The directory-rename TOCTOU** (a real directory renamed between resolution and use) is not
  closed, and the seventeenth pass MEASURABLY WIDENED it — recorded because the trade was made
  deliberately and someone will otherwise re-find it as a regression. Driving 6 workers against a
  path whose middle component flips between a real directory and a symlink out of the share, a PUT
  lands its body outside on BOTH trees (this is the class, unchanged), but the STAGING residue left
  outside went from 7–13 per run on `main` to 77–84 at tip, three runs each, isolated to PUT.
  Cause: closing the write-verb existence oracle required moving the containment test AHEAD of the
  parent-exists check, which puts one more syscall inside the resolve→write window. The two
  properties are in direct conflict and the trade is deliberate: the oracle is an information leak
  reachable by ANY client with no race at all, while this needs an attacker who can already rename
  directories inside the share, and the residue is race-induced only — the 480-cell differential
  shows no staging residue anywhere without the race. If the balance ever changes, the fix is the
  one already adjudicated below, not re-ordering the checks back.
  Closing it properly still means an `openat(2)` component walk or `O_NOFOLLOW_ANY`, which would
  also refuse the benign
  intermediate symlinks that work today and are pinned by `testHiddenItemsAreRefusedThroughSymlinksToo`
  (`testBasePathHandlerRefusesSymlinkEscape` pins the ESCAPE; its positive assertion is a plain file,
  so it does not cover the benign-symlink case).
- **litmus `propfind_invalid2`** (invalid namespace declaration answering 207 not 400) is a
  recorded failure: libxml2 runs with `XML_PARSE_RECOVER` by choice; tightening risks rejecting
  bodies real clients send.
- **`If-Match` on a missing resource answers 404, not 412** — RFC-required (§13.2.1); "fixing" it
  would break conformance. Pinned in both directions.
- **Listing a symlink-to-root answers 200 from the base-path handler and 403 from the other two**
  — adjudicated, measured rather than argued: `GET /selfroot/` is byte-identical to `GET /`, so
  the permissive answer discloses nothing, and every composite through it is refused exactly as
  its direct spelling; the refusal elsewhere is the resolver-level guard protecting destructive
  verbs, which the base-path handler does not have. (Measured on a pre-alias-semantics tree; the
  decision is believed to stand.)
- **Case-variant PUT on a case-insensitive volume is not a defect** — `rclone serve webdav` over
  the same directory behaves byte-identically; it is inherent to vending a case-insensitive
  namespace through a protocol whose clients assume otherwise. Do not re-flag.
- **A case-only rename via MOVE is refused 403** rather than performed — an unconditional
  remove-before-move once deleted the only copy of the file.
- **The lock stub stays a stub** (see WebDAV semantics for the three reasons).
- **Budget exhaustion answers 500, not 503** (see Limits for the trade).
- **The HEAD-body RFC violation** (option NO + registered HEAD handler) is recorded, not fixed —
  the obvious fix suppresses a genuine GET's body; fix off the WIRE method if it ever becomes
  reachable.
- **Host validation**: IP literals by shape, never resolved; no-Host allowed; port comparison
  removed (recorded as a judgement call, easy to reverse — one inverted assertion in
  `testHostValidationRefusesRebindingButAllowsRealNames` marks it).
- **The two-second seal window for unclassifiable filesystems** is the fail-closed trade: wrong
  in the permissive direction splices builds; wrong conservatively costs a date-only client one
  second of caching. The blunt alternative (2 s everywhere) is a one-line flip if caching ever
  matters more than the SMB case.
- **`x-gzip` decodes; every other unsupported coding is 415** — refusing the synonym trades
  silent corruption for an interop bug; storing encoded bytes as the entity is worse than
  refusing.
- **Symlinks are aliases**, and under those semantics the old "it relaxes the allow-list"
  objection DISSOLVES rather than being overridden: removing an alias named `x.txt` that points
  at `id_rsa` does not touch `id_rsa`, so refusing it was the wrong answer. Do not re-raise it.
- **The allow-list both-names ruling** and its accepted cost (see path resolution).
- **A MOVE whose swap fails already unwinds**, restoring the source; only a double failure
  leaves residue, and nothing better exists when the filesystem itself is refusing.
- **`kWSK…` limits are constants, not options.** The example apps do not disable
  `allowHiddenItems` (reverted once; do not reintroduce).
- **Reason phrases: only the fourteen CF gets wrong** — rewriting phrases the corpus records
  would turn a fix into a corpus change (the trace runner fails on any difference, including any
  header present in a response but absent from a recording; targeted re-recording validates the
  reconstruction against the OLD byte count first).
- **The trace corpus is never re-recorded wholesale** — that would bless current behaviour in
  bulk; it proves recorded replay only and cannot prove live-client tolerance, so WebDAV changes
  are also driven against a real `mount_webdav` client.
- **`bootstrap.css` requests `.woff`/`.woff2` glyphicons not in the bundle** — a 404 per page
  load; browsers fall back to the shipped `.ttf`. Cosmetic, untouched.
- **Genuine host-app API-misuse assertions stay abort-in-Debug**, except the specific ones batch
  A converted (slash normalization, `-stop` after failed start, the date functions' main-thread
  assertion — removed because `NSDateFormatter` is thread-safe to build and `dispatch_once`
  replaces the race it stood in for).
- **The out-of-process date oracle lives in the scratch harness, not the suite** — it needs its
  own link line (must not name `WSKWebServer` anywhere).

## Still open

Genuinely open at tip. Re-measure before fixing any of these — aged findings here evaporate on
contact roughly one time in three.

From the sixteenth pass (all pre-existing; it counted thirteen confirmed findings left and
enumerated nine of them — three have since been closed and are struck from this list: MKCOL's 500,
and the two `Allow` gaps, which the draft had merged into one bullet):
- ~~403 where a 404 belongs when a parent collection is absent~~ — **fixed**; see the restated
  entry further down for the measured matrix and the two corrections to the record.
- `WSKDataRequest.text`/`.jsonObject` abort for exactly the case their header documents as
  returning nil.
- `addHandlerForMethod:path:` aborts in Debug and registers nothing in Release for a missing
  leading slash — the identical shape batch A fixed one method away.
  (The three SSE/file-presenter items this list also carried — the missing separator boundary,
  `_resolvedUploadDirectory` being captured once, and a symlinked share receiving no
  `NSFilePresenter` events — are now closed; see the restated entries further down.)

From the outside audit (an independent agent, 23 findings, 5 solid after adversarial review — see
the appendix). **All five are now CLOSED** — by #74 (typed body-failure statuses) and #75 (the
audit tail). They are struck here rather than deleted because this list asserted them as open for
six days after the code stopped agreeing, which is this file's own signature failure and worth
leaving visible:
- ~~Request-body failures all collapse into 500~~ — `_StatusForBodyError` maps a typed
  `WSKRequestBodyErrorCode` to 400/413/503/500 (#74). Verified at tip.
- ~~`-_willEnterForeground:` calls `[self _start:NULL]`~~ — it passes `&error` and logs (#75).
- ~~`indexFilename` escapes the served root~~ — it goes through `WSKResolveWithinDirectory` and is
  refused with a warning when it lands outside (#75).
- ~~`acceptsGzipContentEncoding` parsed by case-sensitive substring~~ — `_AcceptEncodingAllowsGzip`
  now parses tokens and q-values (#75).
- ~~An unmatched request always answers 501~~ — it consults `_registeredMethods` and answers 404
  when some handler implements the method (#75). **405 with `Allow` remains deliberately
  unattempted**: a handler is an opaque match block, so the server cannot ask which methods a path
  accepts without changing the registration model.
- ~~Ten of the audit's findings were never adversarially verified~~ — **done**. Four had already
  been closed by #75; of the six that remained, **five were refuted** and one was real:
  `Transfer-Encoding: identity` (the desync it implied is closed by construction, since reuse is
  restricted to requests with no body framing); the completion-once BOOL races (host-app-only, and
  two of three stated consequences false); `additionalHeaders` overriding framing headers (the
  documented contract, with a `@warning` on the method itself); the SSE cached share root (both
  halves attributed to the wrong method — file-presenter events never call it); and the unchecked
  `dispatch_source_create` (its arguments are statically pinned, so NULL cannot occur). The
  survivor was the weak-delegate swap, now fixed.

From the narrow audit of #72's 1,024 new lines (two lenses and the split-invariance oracle
converged on the same area; four defects fixed, one left open):
- **No lingering close, so a client can lose the last response to a RST.** When the server closes
  with unread bytes still in its receive buffer — which is exactly what pipelining past a
  non-reusable request produces — Darwin sends RST rather than FIN, and the client's unread receive
  buffer is discarded with it. Measured as `200,error` where `200,200,error` was owed, in a minority
  of segmentations. RFC 9112 §9.6's remedy is `shutdown(SHUT_WR)` then drain-before-close. NOT taken
  in that batch: it holds a connection slot open longer on a server with a 128-slot cap, so it needs
  its own bounded design rather than being tacked onto a fix for something else. **Pre-existing and
  unchanged by the fixes** — 48 differing segmentations before, 47 after, on the same shape.
- **The split-invariance oracle needed refining before its verdict meant anything.** It compared
  the connection's manner of ending as if it were a status, so it reported 228 disagreements of
  which every single one was FIN-vs-RST, at the same rate on both trees. It now compares statuses
  and counts endings separately. Its `HEAD then GET -> desync` baseline is likewise the oracle's own
  bug — its client consumes `Content-Length` bytes after a HEAD response, which has none. A RED
  signal from an unvalidated oracle is worth exactly as much as a green one.

Carried from earlier passes. **All nine were re-measured at tip by driving the code (not reading
it), and all nine reproduced — nine skeptics, none refuted.** That is far above this project's
usual ~1-in-3 survival rate, and the reason is worth noting: these are the project's OWN recorded
items, not an outside reader's guesses. Aged findings still need re-measuring, but the base rate
for a self-recorded backlog is much better than for an external audit. Three came back MORE precise
than the record and are restated below; three are now fixed.

- ~~`addHandlerForMethod:path:` aborts for a missing leading slash~~ — **fixed**: normalized like
  its sibling, empty path refused loudly, and the regex variant now reports the `NSError` it was
  discarding. Measured unfixed: SIGABRT/exit 134 in Debug at 5/5 entry points, and a silent 404 in
  Release.
- ~~`WSKDataRequest.text`/`.jsonObject` abort~~ — **fixed**: they return nil, as their `nullable`
  headers always promised. Worth recording WHY this was more than an API-honesty bug: the
  Content-Type that selects the branch is CLIENT input, so it was remotely triggerable, not host-app
  misuse — which is the line the "genuine API-misuse assertions stay abort-in-Debug" decision draws.
- ~~MOVE has no Depth check at all~~ — **fixed**: MOVE and COPY share `performCOPY:isMove:` and the
  validation sat inside `if (!isMove)`, so every spelling — `banana`, `2`, `0,` — answered 201 and
  performed a full recursive relocation while COPY, DELETE and PROPFIND all answered 400.
  Deliberately NOT made stricter than COPY: RFC 4918 §9.9.2 forbids a non-infinity Depth on a MOVE
  of a collection, but COPY and DELETE both accept `0` on a plain file because it means the same
  thing there, and an asymmetry only MOVE enforces would refuse what real clients send.
- **PROPFIND publishes no `getetag`** — confirmed at tip on EVERY path (allprop, no-body, Depth:1,
  propname), and an explicit `<D:getetag/>` is answered in a **404 propstat**, so PROPFIND and GET
  actively contradict each other about the same resource. A just-written file has zero validators
  12/12, because the mtime seal correctly withholds `getlastmodified` and `getetag` does not exist
  at all. The obvious fix was measured as failing CI; needs care.
- ~~MOVE/COPY of a collection relocates/duplicates members the allow-list refuses individually~~ —
  **fixed, at all three sites**. Measured before: with `allowedFileExtensions = @["txt"]`, every
  DIRECT operation on `Coll/sub/secret.pem` was 403, a recursive DELETE was 403, an overwrite was
  403 — and MOVE and COPY of the collection to a NEW destination both answered 201 and carried the
  file with them. Both extension checks were gated behind `!srcIsDirectory`, so a collection source
  skipped every allow-list rule. The uploader's `/move` had the identical `!isDirectory &&` gate and
  was fixed with it, because closing this in one server and not the other is precisely how this
  class keeps recurring. COPY is vetted too even though it destroys nothing: duplicating a file the
  client may not read is still acting on it.
  **Accepted cost, pinned by the test:** a collection holding anything outside the allow-list is now
  unmovable, not merely undeletable — the same cost already accepted for DELETE, and the
  inconsistency was the defect. The test asserts the permitted half in both directions, so no later
  fix can degrade to "refuse every collection operation".
- ~~403 where a 404 belongs when a parent collection is absent~~ — **fixed inside `_RealPath`**,
  which walks up until an ancestor resolves instead of trying the parent once (see the invariant
  above for the measured matrix). The record's guidance held up on every point that mattered: the
  write verbs' 409 is RFC-mandated and unchanged, the `-fileExistsAtPath:` precheck really would
  have reopened the oracle, and the regression test really does need a TWO-or-more-missing
  component path — the one-level spelling already answered 404 and would have passed on unfixed
  code. Two corrections to it: **LOCK and UNLOCK are not in this class** (405 at tip), and the
  cheap textual predicate `WSKResolvedPathIsWithinDirectory` changes answer for a deep
  not-yet-existing path inside the share, from NO to YES, which is correct — it reports
  containment, not existence.
  **A second oracle was found while measuring this one, and is also closed** — see the
  resolve-before-you-ask rule under Path resolution.
- ~~A symlinked share receives no `NSFilePresenter` events at all~~ — **fixed**, and the record's
  own advice was what stood in the way: it said the mismatch is not in
  `-presentedSubitemDidChangeAtURL:`, which is true and correct, but that ruled out the one method
  it names without naming the one at fault. It was `-presentedItemURL` handing `NSFileCoordinator`
  the *standardized* path, so the presenter registered for a spelling no change is ever reported
  against. Re-measured before the fix at 0 events against 8 on a same-process real-path control;
  after, 8 and 8. Note the asymmetry that hid it for three passes: the two methods that already
  had the rule are handed a realpath'd argument and resolve their own root to match it, whereas
  this one is the method that hands a root OUT, so nothing downstream could compensate.
- ~~The SSE prefix test has no separator boundary~~ — **fixed** in
  `-_relativePathForAbsolutePath:`; `-presentedSubitemDidChangeAtURL:` already had it and was left
  alone, as the record instructed. Measured: a share at `…/Share` answered `/2/x.txt` for
  `…/Share2/x.txt`, slicing a directory name in half. **Honest limit, recorded because the fix
  reads more important than it is:** every current caller hands over a path already resolved
  INSIDE the share, so this was NOT reachable from the network. It is the function being wrong,
  not the server.
- ~~`_resolvedUploadDirectory` is captured once~~ — **fixed** by re-resolving on a miss, last and
  only when both cached roots fail, so the common path pays nothing. Deliberately NOT written back
  to the ivar: those callers run on concurrent connection queues, and `-presentedItemURL` needs
  that value to stay put for as long as the presenter is registered. Re-measured before the fix:
  after a repoint, `/Sub` became `/`.
- **The allow-list vetting walk judges a symlink's TARGET, not the alias — needs an owner ruling,
  not a fix.** With `allowedFileExtensions` set and `link -> Vault` where `Vault/sub/secret.pem` is
  not allow-listed, all three destructive verbs answer 403 for `/link`, although acting on the link
  touches nothing inside `Vault`. Measured on both trees, which is what makes the shape clear:

  | request | main | tip |
  |---|---|---|
  | `DELETE /link` | 403 | 403 |
  | `MOVE /link` | 201, link moved | 403 |
  | `COPY /link` | 201, link copied | 403 |
  | `MOVE /Vault` | 201, **`secret.pem` moved with it** | 403 |

  DELETE was ALREADY 403 on main, so the seventeenth pass did not invent this — it made MOVE/COPY
  consistent with DELETE while closing the real defect in the last row. But consistent with what is
  the question: **"symlinks are aliases" is a recorded OWNER decision** ("a destructive verb acts on
  the entry the client NAMED"), and vetting the target contradicts it. It is fail-CLOSED
  (over-refusal, no exposure) and invisible in the DEFAULT configuration, because
  `WSKFirstUnvettableItemAtPath` returns nil when no allow-list is set.
  **Do not "just fix" it by deriving directory-ness from `lstat`**: that reclassifies a
  symlink-to-directory as a file, which then puts it through `_checkFileExtension:` — and a link
  named `latest` with no extension fails that, so it answers 403 again for a different reason. Any
  fix has to settle the allow-list-vs-alias interaction first.
- A header-time refusal can lose its error-page body to a TCP reset (the status is never lost).
- Phase 2's low-value structural tail: the URI-to-path derivation, and the limits/constants.

Known verification gap, stated rather than papered over: the duplicate-`webServerDidStop:` fix is
`#if TARGET_OS_IPHONE`, the Mac suite is structurally blind to it, and the failure regime cannot
be synthesized by fd exhaustion (`-_stop` releases the listening descriptors before `-_start:`
runs, so that probe always lands in the success regime — two attempts did, and were discarded).
The after-state is NOT measured; only the single delivery site is established.

NOT open — do not resurrect from old lists: the SSE quiet-client reaping "gap" (refuted by
measurement), the browser reload wedge (redesigned), `WSKFileResponse` non-null lie (deleted),
the batch A/B backlog (closed or adjudicated), the 11th/12th/13th-pass still-open items that the
symlinks-are-aliases, WebDAV class 1, and batch A entries closed, and the pre-server date-function
crash (dispatch_once). "The known-open backlog is now empty" was written once and falsified
within one pass; never write it again without a fresh full re-run.

## Lessons

Process knowledge that cost real time. The generic form of each is worthless; these are stated so
they can be acted on.

### The record itself is the most dangerous artefact

**This file has asserted properties the code did not have at least six times** — the counts in
old entries themselves disagree, which is part of the lesson: the sixth pass's If-Range claim
("fixed" — it was not, 5/5 reproducible); the seventh pass's "every date a client can present was
sealed" (false two ways: PROPFIND published unsealed dates, and FAT's bucket is two seconds); the
hidden-item rule recorded as fixed while covering two servers of three; the recursive-delete
claim asserted while only the uploader had it; the gzip trailing-data case recorded closed while
half open; "performPUT refuses an existing collection with 405" (true at check time, false at
swap time); batch C's "isRunning/serverURL lie after a failed restart" (measured false 7/7 — and
it justified adding a call that was itself a regression); "the known-open backlog is now empty"
(falsified next pass). Every one was a sentence describing a property the code held only partly.
**When a pass closes a class, check every site the class can occur at before writing that it is
closed** — and a correction is more valuable than the claim it corrects; never quietly delete the
history of being wrong.

**Proposed fixes are hypotheses, and the fix has been the dangerous part at least seven times**:
a no-op inside a method that returns nil in the default configuration (behind a green suite); a
"stage always and swap" that destroyed MORE (83/144 answered 201 vs 25/95 unfixed); a containment
comparison that would have broken every upload under `/var`; end-of-body-only chunk verification
that reports the splice after the bytes are sent; the exFAT fallback that omitted reclaiming its
reservation; the W_OK removability walk and the entity-tag-keyed `If-Match: *` (both regressions
from in-project fixes); `visibilitychange` SSE closing (measured worse than the deadlock).
**Apply the fix and re-run the ORIGINAL probe, never just the suite** — a green suite is not
evidence for a fix the suite was never sensitive to (one dangerous fix passed all 112 tests and
the full trace corpus).

**Re-measure before acting on any recorded finding.** Eight of ten aged violations evaporated in
one pass (five already fixed by an unrelated change); across the sixteenth pass and batches B/C,
nine findings were refuted against sixteen real, and one refuted "fix" would have broken RFC
conformance. Findings age against a moving tree.

**Each batch of fixes has introduced roughly one new defect per five it closed**, clustered in
exactly what the fix touched — every one from adding a guard or a call without asking what it now
REFUSES, DUPLICATES, or COSTS. A guard justified by one failure mode must be checked against
everything it then refuses (the existence-oracle fix measured six operations that must survive
alongside the two that must change — the first change made deliberately under this rule).

### Verification

- **Read the executed count, never the failure count.** A crashed test runner reports
  success-shaped output: `Executed 0 tests, with 0 failures` (three separate recorded instances,
  including regression tests that SEGV'd the runner against the unfixed tree, and a SIGPIPE'd
  process reported as "Executed 23 tests, with 0 failures").
- **Run every new regression test against the UNFIXED source first** and confirm it fails on the
  intended assertion — this twice caught a test passing for the wrong reason in one pass alone.
- **For NEW capability there is no unfixed tree, so use the inverse: delete the specific line the
  test is about and confirm the test fails.** A compile error against absent API proves nothing
  about behaviour. This caught a keep-alive reclaim test that passed with its ENTIRE idle branch
  removed — it had been measuring a pre-existing slowloris deadline the whole time, and the
  replacement was redesigned to discriminate (it configures a keep-alive longer than that
  deadline). Two security-critical assertions were confirmed the same way: deleting an SVG
  exclusion produced `200 OK` with `alert(1)` in the body; deleting the bodyless restriction made
  `Transfer-Encoding: identity` reusable. **A test whose subject can be deleted while it stays
  green is measuring something adjacent to its subject.**
- **A dictionary literal inside `XCTAssertTrue()` splits on its commas** and produces a wall of
  nonsense syntax errors pointing at one line. Four occurrences. Hoist it to a local.
- **A green oracle you have not proved sensitive proves nothing** — prove it by injecting the
  defect (the leak test, the splice oracle, the full-volume probe, the SPM consumer were each
  proven this way; the SPM consumer's first sensitivity attempt measured a cached 0.15 s build).
  **An oracle can also be un-sensitive because its CONFIGURATION closes the window**, which looks
  identical to a pass: the pipelining soak's short-body tripwire read 0 against the PRE-FIX
  framework, because at a realistic 10 s keep-alive and 30 s tick a loopback response finishes long
  before the reaper can fire. Only pacing the reads — bytes moving every tick, transfer spanning
  several — opened the window, and then it read 119. Ask what configuration the defect NEEDS, not
  just whether the check is present. The same harness first counted 190 "truncations" at tip that
  were the server CORRECTLY refusing a torn read of a file its own writer thread replaces every
  750 ms: an oracle that cannot tell correct behaviour from the defect is as useless as one that
  cannot fire.
- **A RED signal from an unvalidated oracle is worth exactly as much as a green one.** The
  split-invariance fuzzer reported 228 disagreements and VERDICT: SPLIT-DEPENDENT, of which every
  one was FIN-vs-RST at the same rate on both trees, and its `HEAD then GET -> desync` baseline was
  its own client consuming `Content-Length` bytes after a HEAD response, which has none. Validate
  an oracle before acting on its alarm, not only before trusting its silence.
- **A workflow that infers "clean" from an empty results array cannot tell "nothing found" from
  "nothing checked"** — the twelfth pass reported CLEAN with every verifier dead (fourteen
  findings pending). Report coverage counters explicitly ("8 lenses, 22 skeptics, none dead").
- **Green-signal traps, all one shape** (the signal was about something other than the question):
  a stacked PR that merged into a dead base branch while GitHub reported MERGED (verify a landing
  by grepping main for the code and `git merge-base --is-ancestor`; do not stack PRs here); a CI
  run reporting success for a pre-rebase SHA; `Run-Tests.sh` builds into `./build` while ad-hoc
  probes load from DerivedData, so a probe after a swap-build-restore reports the PREVIOUS build.
  Always rebuild explicitly before believing a probe. **And a STALE LOG FILE reads exactly like a
  passing run**: a `pgrep` that matched nothing broke an `&&` chain at the failed `kill`, so
  `Run-Tests.sh` never executed — and the `grep` that followed read a log of the same name from
  four days earlier and reported "149 tests, TEST SUCCEEDED, 8 corpus suites". The tell was the
  COUNT: 149 where 165 was expected. Write to a fresh filename or `rm` it first, check the file's
  timestamp, and treat a test total that does not match what you expect as a stop signal rather
  than a curiosity. `Run-Tests.sh` also stops at the first test failure, so a run that fails a test
  never reaches the trace corpus at all — "the suite ran" is not "the corpus ran".
- **`Run-Tests.sh` and a running soak must not overlap.** The soak's 12 workers reproduce the
  documented flake (`testConnectionClosesSlowlorisHeaderDribble` failed in-suite, then passed 3/3
  in isolation WITH the soak still running). Pause the soak with `SIGSTOP`/`SIGCONT` rather than
  killing it — the whole process, server included, freezes together.
- **Check warnings against a clean `-derivedDataPath` or the count means nothing** — an
  incremental build recompiles nothing and reports zero (five warnings accumulated this way; the
  GNU `?:` class recurred and was caught only by the clean build).
- **Verify batches together, not per-fix** — per-fix greens let two regressions ride `main`
  through three CI runs. **Periodically run every technique family together against tip**: each
  had last run against an older commit, and only the combined run asks "do the repairs hold
  together" (three times the answer was no, including two regressions the full harness could not
  see).
- **A test of the helper is not a test of the wiring** — the 507 mapping's unit test passed while
  the status LINE said `421 Bad Request`; only the end-to-end probe against a real full volume
  showed it.
- **Fixture placement decides sensitivity**: any regression test for the recursive-vetting class
  must put the victim ONE LEVEL DOWN — the top level of the addressed collection is immune to
  the `-skipDescendants` bug, which is why three existing tests passed against unfixed code.
  Hidden-item tests must assert on a file inside a dot-DIRECTORY, not a leaf dotfile. Timing
  tests must verify the WHOLE sequence lands inside one second, not only the write (pass-locally
  fail-on-CI otherwise).
- **Substring assertions**: `retry: 30000` has `retry: 3000` as a PREFIX — the fourth such
  misfire in two passes. Match the longer marker first or include its terminator.
- **`-stop` is NOT a barrier for connection teardown** — it waits on `_sourceGroup`, which covers
  the LISTENING sources' cancel handlers, and never on `_activeConnections`. A test that asserts on
  anything a connection does as it unwinds (`-close`, the access-log line, a recording being moved)
  must WAIT for the event, not read state straight after `-stop`. This was learned by writing a
  test whose comment claimed `-stop` was "a full barrier over every connection queue": it passed
  6/6 in isolation locally and 3/3 under saturating CPU load, and failed on CI with `closes=0`.
  Local load does not reproduce it — the race is won or lost on machine, not on load — so the only
  safe form is a bounded poll for the event. When adding one, check it still discriminates: the
  defect here made `-close` run once per REQUEST, so the wrong value is already present before
  `-stop` and a poll returns immediately with it (verified by restoring the old call and watching
  the test fail 2 != 1).
- **Two timing tests flake under load** (`testConnectionIdleTimeoutSparesSlowHandler`,
  `testConnectionClosesSlowlorisHeaderDribble` — observed failing at load average 169, 3/3 in
  isolation). Never read a `Run-Tests.sh` verdict while a fleet is building; re-run a failure
  alone before believing it.
- **An in-suite XCTest cannot regression-guard a lazy-initialization fix** — the suite runs one
  process alphabetically, so an earlier test has already initialized the class. The oracle is
  out-of-process.
- **Filesystem-dependent code passing all tests proves only APFS behaviour** — measure on real
  images (exFAT, FAT32, full volumes, case-sensitive). **A fix inside `#if TARGET_OS_IPHONE` is
  structurally invisible to the Mac suite** — state the verification limit rather than papering
  over it.
- **The per-change verification bar**: full suite on a CLEAN build with no new warnings, trace
  corpus green, iOS and tvOS Debug clean; plus `swift build` AND the external SwiftPM consumer
  (depends on the package by path, imports all three modules) for any header/layout move —
  in-package builds cannot detect external unbuildability.
- **Cheap reusable oracles**: split-invariance (same bytes, different TCP segmentation, compare
  verdicts — found the gzip defect automatically); an independent implementation over the same
  data (`rclone serve webdav` — refuted a "defect" as inherent); property-based generation (the
  NUL crash triggered on 188 of 2,356 generated paths after imagination had missed it for
  passes); driving each entry point rather than grepping for the guard.
- **Measure and kill hypotheses instead of filing them** ("does a PUT through a dangling link
  escape?" — measured no, recorded as a negative result).
- **A load harness needs its own oracle debugged before its numbers mean anything.** Building the
  keep-alive soak produced four harness bugs and only the fourth was subtle: no `SO_NOSIGPIPE`, so
  it killed itself at three minutes (the trap this file already records the suite hitting); a
  strong global written from twelve threads, SIGSEGV; a desync theory that was simply wrong (fixed
  it, the numbers did not move — that is what told me it was wrong); and finally, an
  `-abortRequest:` reply is a bare status line with **no `Content-Length`**, so a reader that
  returns without consuming those bytes makes every later request in a keep-alive burst re-parse
  the same stale header. That last one reported **32% of 750,000 requests as unexpected statuses**
  — entirely the harness. After it: zero. **Do not start a long unattended run until the oracle
  reads zero on the paths you already understand.**
- **A second-opinion agent is differently blind, not more reliable.** An independent audit of tip
  produced 23 findings and never ran the code (its sandbox blocked `xcodebuild`, which it said
  plainly). After verification and adversarial review: 5 solid, 3 already-documented deliberate
  choices, 5 dead, 10 never checked — and all four of its P0s gone. That is this project's own
  ~1-in-3 rate. Its real value was independently re-finding recorded known-opens, because
  agreement between two unrelated readers beats either alone. A purely static pass gets the
  MECHANISM wrong far more often than the symptom, so check the cause it names even when the
  symptom is real — two of its findings named a cause that had been fixed passes earlier, and one
  of those was relayed onward before a skeptic caught it. **Re-verify before relaying, not only
  before fixing.**

### Orchestration

- **`git stash` is repo-wide, not per-worktree** — one agent popped another's stash mid-fleet; a
  skeptic nearly measured a fix against itself. Never stash while a fleet is live; copy files
  aside.
- **Stage by naming paths, never `git add -A`, while background work is live** — unreviewed agent
  edits once reached `main` under an unrelated commit message (they were correct; that is luck,
  not process).
- Agents that might write need worktree isolation (one edited despite instructions and broke the
  build); concurrent builds need their own `-derivedDataPath` (shared DerivedData produced two
  phantom failures); passing `args` as a JSON string arrived as `undefined` and degraded the
  prompts.
- **Recovering a crashed run beats re-running it**: per-agent transcripts survive on disk when
  the journal shows nothing; tell the relaunch what is already known so agents hunt siblings.
  Three agents independently converging on one defect is the strongest realness signal any pass
  produced. **Changing audit technique finds what repeating a sweep cannot.**
- **An inventory ages like any other finding** (a "dead" helper had gained its first caller one
  commit later). When unifying duplicated rules, audit which copy is CORRECT first — unifying
  cements whichever spelling was read first (of 72 duplicated rules inventoried, 23 already
  disagreed; 4 reproduced from the network). Delete the dead second implementation of a security
  rule once callers are converted; sequence moves so public docs never name a private symbol —
  and remember public docs can actively teach the vulnerable pattern (one `@warning` recommended
  the two-observation pattern measured escaping in 24% of requests).
- litmus 0.13 builds with `CFLAGS=-Wno-implicit-function-declaration` on modern clang (or it
  dies claiming it cannot find `socket`); `mount_webdav` needs no privileges when an ordinary
  user owns the mount point — both were once wrongly written off as needing hardware.

### Recurring defect shapes (check new code against these)

1. **The same rule spelled two ways in two places** — the signature shape; it appeared even in
   brand-new PROPPATCH code. Give every rule one home.
2. **A class closed at one of the sites it applies to** — NUL (five recurrences), hidden items,
   recursive vetting (four recurrences), If-Range, preconditions, `/var` prefix comparisons
   (two methods). Sweep every site before recording closure.
3. **nil/NUL reaching Foundation APIs that raise or return nil** — a nil in a dictionary literal
   is the named recurring crash; nothing in `Sources/` catches NSExceptions.
   `-fileSystemRepresentation` raises; `-stringByAppendingPathComponent:` returns nil on a
   NUL-bearing receiver; `NSJSONSerialization` raises.
4. **Honouring a truncated prefix of what was asked** (NUL, then `#` — same class, different
   delimiter, and the header-value spelling survived the request-line fix).
5. **Fail-open vs fail-closed mix-ups**: judge every case-comparison and parse-failure by which
   way it fails (`Overwrite: f` failed open — data loss; `Depth` failed closed — interop bug;
   an unparseable date must fail OPEN by RFC).
6. **Two observations of the filesystem that need not agree** — resolve once; restate every rule
   about the unresolved path against the resolved one; put root-guards in the resolver so a new
   call site cannot forget them.
7. **Vet-then-act windows**: carry the vetted `dev`+`ino` into the destructive step.
8. **A derived predicate standing in for the real one.** `-[WSKRequest hasBody]` keys on
   `_contentType` and only tracks "has body framing" because `-initWithMethod:` maintains the
   correspondence thirty lines away — it answers NO for `Transfer-Encoding: identity`, which DOES
   carry framing. Any framing, containment or authorization decision must read the primary source
   (here, the raw header names), never a convenience property derived from it elsewhere.
9. **A check and the action it guards must observe the SAME object.** Every delegate callback
   tested `-respondsToSelector:` and then hopped to the main queue and re-read the WEAK, MUTABLE
   delegate — so a host app swapping one live delegate for another implementing a different subset
   of these @optional methods raised unrecognized-selector, and nothing in `Sources/` catches an
   NSException. Fourteen sites. Note which oracles are worthless here: setting the delegate to nil
   and letting it deallocate are BOTH already safe (the weak read yields nil, the message is a
   no-op), so a test using either passes against the unfixed tree. Re-read into a strong local and
   re-check inside the block; do not capture strongly at check time, which would deliver into an
   object the host app has released.
10. **Messaging nil returns a ZEROED struct, so a struct-returning check on an absent value is
   silently wrong.** `[headers[@"Connection"] rangeOfString:@"close"].location != NSNotFound` was
   TRUE whenever the header was absent, because `{0, 0}.location` is 0. It failed safe, which is
   worse in one specific way: the feature it guarded never turned on, and every functional test
   passed while it did nothing. Guard the nil explicitly before any `NSRange`, `NSRect` or
   `NSSize` returned from a possibly-nil receiver.
11. **A status that differs by what the filesystem holds is an answer about the filesystem.** Any
   predicate consulted BEFORE containment leaks across the share boundary if it follows symlinks,
   and `-fileExistsAtPath:` does. The tell is two refusals with different statuses on the same
   path shape: 409-vs-403 and 404-vs-403 were both this. Ask the question after resolution, on the
   RESOLVED path. Note the trap that kept it alive: the ordering was correct when written, and its
   comment said so — a rule can be right and become wrong because a function underneath it got
   better. Re-read the justification of an ordering whenever you change what it depends on.

## Appendix: audit history

Newest first. One entry per pass/change-set; the durable rules extracted from each live in the
body above.

- **Eighteenth pass: HTTP-conformance audit + fixes, 2026-08-17.** ~115 raw-socket probes across
  request-line, framing, Range, conditional, Expect and WebDAV matrices, then a fix branch for
  everything not covered by a settled decision. The bulk measured clean (framing strictness,
  Range/416 arithmetic, 304 validator set, 100-continue both directions, chunk extensions and
  trailers, the DAV status matrix). Fixed, each with a regression test proven red first: NUL and
  other C0 controls in header VALUES answered 200 (the nil/NUL class's sixth site); If-Match /
  If-Unmodified-Since were never evaluated on reads (safe direction; gated to GET/HEAD to avoid
  re-judging the write verbs' tag-less successes); an absolute-form target's authority lost to
  the Host header; multiple/invalid Host answered 421 where 400 is owed (syntax judged only on
  the refusal path); unsupported transfer codings answered 400 for 501; HTTP/2.0 answered 400
  for 505 and HTTP/1.2 was refused instead of served as 1.1; a leading CRLF was refused; an
  oversized request-target answered 431 for 414; the non-Finder 405 for LOCK listed LOCK in its
  own Allow; a new lock omitted the Lock-Token header. Two probe-design artifacts in the audit
  itself (a MOVE matrix that forgot the destination must exist; a LOCK probe missing `Depth: 0`)
  re-confirmed the project's outside-findings base rate. One record over-claim corrected (the
  MOVE/Overwrite settled entry). One green-phase surprise recorded: CFHTTPMessageCopyRequestURL
  synthesizes the URL's authority from Host for origin-form, so absolute-form must be detected
  on the raw request line. Deliberate deviations left standing: no-Host-still-served,
  the 501/404 unmatched-request model, and the Finder-only class-2 façade.

- **Outside audit + three PRs (#70–#72), 2026-08-01.** An independent agent (Codex) reported 23
  findings without running the code. Verification plus adversarial review left 5 solid, 3
  documented deliberate choices, 5 dead, 10 unchecked; all four of its P0s gone — this project's
  own ~1-in-3 rate, from a different reader. Two findings named a cause fixed passes earlier
  (`Overwrite` case-folding; a "regression" that `git log -L` shows as untouched upstream code),
  and one of those was relayed onward before a skeptic corrected it. Closed: four WebDAV status
  defects (#70), `/download` ignoring `Range` plus the `/preview` inline-media endpoint and
  opt-in file caching (#71), and opt-in connection reuse restricted to bodyless requests (#72).
  Three defects of my own were introduced and caught during #72, two of them only by tests
  redesigned to discriminate. 154 tests.
- **Structural cleanup phase 3 (groups A–C)**: public surface 27 → 7; the "SPM siblings cannot
  see WSKPrivate.h" constraint measured stale (one `headerSearchPath`); group B held back
  `WSKResolveWithinDirectory` so docs never named a private symbol. Structural cleanup complete
  but for the low-value tail. 142 tests.
- **Existence oracle closed** at its real cause (`_RealPath`'s dangling-link branch), fail-closed
  403 both spellings, six must-survive operations pinned.
- **Structural cleanup phase 2**: four resolver copies → one (198 lines removed); vetting walk →
  `WSKFirstUnvettableItemAtPath` (94 lines); allow-list both-names ruling; resolve-before-stat in
  uploader reads. Phase 1 inventory: 72 duplicated rules, 23 disagreeing, 4 network-reproducible.
- **Sixteenth pass**: 17 confirmed / 5 refuted, 8 lenses, 22 skeptics, none dead. Four findings
  were regressions from the three batches (self-inflicted NUL raise, ICU year-0094 fail-closed
  validator, linear date rejection, duplicate `webServerDidStop:` on a false justification).
  Verdict: ~1 new defect per 5 fixed → stop auditing, do the structural cleanup. 138 tests.
- **Known-open lows, batch C** (long-lived surfaces): SSE event paths were broken BY DEFAULT
  (`/var` vs `/private/var` — every `NSTemporaryDirectory()` share); `-bonjourName` never saw an
  auto-rename; failed foreground restart now says so; the quiet-client reaping gap REFUTED.
  Closed with "backlog is now empty" — falsified next pass.
- **Known-open lows, batch B**: ENOSPC/EDQUOT → 507; fourteen reason phrases (421 was
  serialized `Bad Request`); MKCOL failure removes the created collection; `*error` set on
  double-start; six properties honestly nullable. Three recorded items refuted (If-Match 404 is
  RFC-required; empty header name already refused request-side; MOVE swap failure already
  unwinds).
- **Known-open lows, batch A**: six host-app process-kills (nullable `+responseWithFile:`,
  match-block address SEGV, date functions crashing pre-server → `dispatch_once`, RFC 850/asctime
  parsing added, slash normalization, `-stop`-after-failed-start). Four of six crashed the test
  runner against the unfixed tree — "Executed 0 tests".
- **Reload guard redesign**: shared counter → boolean + DOM-derived editor state; the naive
  repair goes negative and wedges identically.
- **The non-null lie in `WSKFileResponse`**: three redeclarations deleted (breaking); five
  warnings surfaced only by a clean build.
- **WebDAV class 1, parts one and two**: propstat 404s, `propname`, Depth rules, `Allow`;
  PROPPATCH with single-xattr storage, atomic; litmus found the no-namespace disagreement
  (28/30 → 29/30); the fifth Finder recording had preserved a dishonest 200-over-nothing since
  2014; the lock stub documented as such.
- **Symlinks are aliases**: destructive verbs act on the named entry (source AND destination,
  both servers); symlinks listed, classified by target; root-destruction impossible by
  construction; the re-pointed test.
- **Full confirmation re-run** (fifteenth): all technique families together against tip; two
  regressions from PR #48 the full harness could not see (`} else if (_size > 0)`; exFAT
  ENOTSUP fallback), plus the `-skipDescendants` dot-FILE bug (fourth recurrence of the
  recursive-vetting class, default macOS folders affected).
- **Fourteenth pass** (browser first in scope): six-tab SSE deadlock → one stream per browser;
  deep-link bounce to root; CR-filename rename; Host port comparison removed; static analysis
  clean; case-variant PUT refuted via rclone.
- **Thirteenth pass** (litmus, real mount, trace-seeded fuzzing, long-lived churn): raw `#`
  truncation honoured against the prefix (both request line and `Destination`); two regressions
  from the twelfth pass (W_OK walk, `If-Match: *`); cross-request splice recorded as
  client-side-only.
- **Twelfth pass** (fault injection, clock/locale, platform-conditional, contract conformance):
  reported CLEAN with all verifiers dead — artefact; real answer five confirmed. Half-succeeded
  recursive removal (`WSKFirstUnremovableItemAtPath`); `If-Unmodified-Since` not read anywhere;
  PROPFIND publishing the unsealed validator; FAT two-second buckets; the proposed removability
  fix was a no-op in the default configuration.
- **Eleventh pass** (stateful sequences, concurrency, metamorphic, host-app API): COPY-racing-
  MKCOL destruction (pre-existing since the fourth pass); swap-time destruction of a vetted-
  absent collection; in-place rewrite splicing (per-chunk verification); JSON raise;
  the "worse than the bug" proposed fix measured.
- **Tenth pass** (meant to end the programme; found five): MOVE/COPY overwrite bypassing the
  allow-list both ways; `Overwrite: f` fail-open; `filename="/"` escape (and the proposed fix
  that would have broken `/var` uploads); undecoded codings stored; preconditions evaluated
  after the write. Recovered from a machine reboot via surviving transcripts.
- **Ninth pass** (fuzzing, differential, allocation-failure): the eighth pass's own resolve-once
  fix let one request empty the share (root guard restated on the resolved path, in the
  resolver); `close(0)` from a nil-returning initializer; NUL in multipart filename; gzip
  verdict depending on TCP segmentation; size added to the ETag; the 15.6 TB soak.
- **Eighth pass** (property-based): NUL crash and prefix-honouring deletes; the retargeted-
  symlink escape closed by resolve-once (`WSKResolveWithinDirectory`); WebDAV recursive DELETE
  bypassing the allow-list; the merged-PR-that-never-landed; eight of ten report findings
  evaporating on re-measurement.
- **Seventh pass** (aimed at the sixth's changes): the If-Range fix that did not work — moved to
  issue-time sealing (with the tenth-pass correction that issue-time is the WHOLE protection);
  501-for-unmatched-paths regression; unmatched-request SEGV in `abortRequest:`; symlink-defeats-
  hidden closed via resolved-relative test; SSE channel dying with its connection (a halving);
  the 896 GB soak; the `aa1969a` unattributed-edit incident.
- **Sixth pass** (post-rename sweep): SO_NOSIGPIPE process kill; base-path hidden-item gap;
  href entity escaping; the two failed If-Range attempts (Finder trace catching the first);
  If-Modified-Since exact equality; HEAD-pinned SSE channels; the framing-proof clickjacking
  control; `/events` failing open without Sec-Fetch.
- **Fifth pass** (eight lenses, two refuters each): truncated gzip accepted (DCHECK no-op);
  refusals after 288 MB of body spooling; inverted gzip budget accounting; 6×/27× error-page
  amplification; CRLF/LF-LF framing ambiguity; header cap on the block; COPY-into-source
  recursion; four honesty fixes on served files (`If-Range` added, `filename*` `;`, no gzip on
  206); trace corpus builds restored.
- **Fourth pass** (sanitizers, fuzzing, hostile frames): base-path containment added; WebDAV
  component-walk hidden fix; stage-and-swap for PUT; multipart part-header cap and boundary
  comma regression (both third-pass corrections); Digest full-byte hashing; open-once
  `WSKFileResponse`; TSan false positives established.
- **Third pass** (remote DoS, lifecycle, parsing): multipart budgets, slow-body timeout, SSE
  channel cap, `__WEBSERVERKIT_ENABLE_TESTING__` out of Release, component-wise hidden checks,
  token-boundary parameters, `_stateQueue` lifecycle, async gzip encoder.
- **Earlier feature/safety work**: aggregate in-memory budget; Host validation; MOVE/COPY
  self-move safety; error-page escaping; per-connection config snapshot; in-memory body caps;
  SSE for the uploader; connection idle timeout.
