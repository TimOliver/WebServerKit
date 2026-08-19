# WebServerKit

A fork of GCDWebServer with additional features for iOS/macOS web serving.

This is the CONDENSED institutional memory (condensed 2026-08-17 from the full 21-pass audit
record). The complete record — every measurement, justification, and the pass-by-pass
appendix — lives in git history: `git show 09416c2:CLAUDE.md`. Consult it before re-auditing
a subsystem or reversing anything under "Settled decisions".

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
  cap — re-audit with an internet-facing lens before ever exposing publicly. Plaintext
  transport is settled (TLS terminates upstream).
- **Publish builds atomically** (`rename`/`mv`/`ditto` — never `cp` or `cat >` in place, which
  reuse the inode and feed the new bytes into in-flight downloads); per-chunk verification
  refuses a torn read but cannot make it whole. Avoid republishing while downloads are
  plausibly in flight — parallel-Range clients can splice client-side; no server fix exists.

## Deployment requirements

- Tailscale: set `WSKOption_AllowedHostNames` to the MagicDNS name; the built-in Host
  allow-list admits only localhost, IP literals, own hostname and `.local` (else 421). An
  entry without a port matches ANY port (needed behind port-translating hops); a request with
  no `Host` header at all is allowed.
- `WSKOption_ConnectionIdleTimeout` default 30 s; 0 disables — without it, 128 idle sockets
  is a permanent denial of service.
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
- iOS Files app: `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`; background
  serving via `WSKOption_AutomaticallySuspendInBackground: false` (~30 s).
- **Finder Network-sidebar presence is a Bonjour type, not a feature**: advertise
  `_webdav._tcp` (+ TXT `path=/`) on a WSKWebDAVServer and NetFS lists the device;
  double-click mounts via mount_webdav. `_http._tcp` only reaches Safari's Bonjour menu.
  Measured live 2026-08-18 (simulator): advert named after the device, Digest 401-challenge /
  wrong-code-401 / right-code-207 matrix all correct with a per-session on-screen pairing code
  (6 chars, unambiguous alphabet — resists LAN-speed guessing without backoff). The example
  change was REVERTED pending a proper example-app refresh; the recipe is the three Bonjour
  options plus Digest accounts on a WSKWebDAVServer.
- A symlinked share is supported for live updates; the one-stream-per-browser SSE relay needs
  Web Locks + BroadcastChannel (falls back to per-tab streams without them).

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
- **Listings advertise iff served**: one classifier, `WSKServableFileTypeAtPath()`, feeds all
  three enumerators (PROPFIND, uploader `/list`, base-path index) so they cannot drift.
- The extension allow-list judges BOTH names a symlink presents — alias AND resolved target
  (`WSKEntryPassesExtensionAllowList`, one home).
- The uploader's mutating endpoints hold `_fileOperationLock` (four sites; any new
  resolve-then-act endpoint must take it too).
- Recursive-destroy vetting has one home, `WSKFirstUnvettableItemAtPath` (dot-names and their
  descendants skipped; `-skipDescendants` only for dot-named DIRECTORIES). It returns nil
  when no allow-list is set, so nothing that must run by default may live inside it. The
  removability walk `WSKFirstUnremovableItemAtPath` is UNCONDITIONAL and asks before anything
  is touched (`removeItemAtPath:` deletes as it walks and keeps what it already destroyed).
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

### Validators and conditional requests

- Entity tag = inode + mtime (`tv_nsec`) + size, minted ONLY by `WSKEntityTagForFileInfo`,
  shared by GET, the precondition check, and PROPFIND's `getetag`. A second formatter would
  make every precondition fail.
- `Last-Modified` is WITHHELD while mtime sits inside its filesystem's timestamp bucket
  (`WSKLastModifiedDateIsSealed`; 1 s only for apfs/hfs/exfat, 2 s otherwise) — the
  issue-time withholding is the WHOLE protection; do not try to "strengthen" the resume-path
  check. PROPFIND's `getlastmodified` shares the seal.
- `If-Modified-Since` uses EXACT equality; `If-None-Match` takes precedence (RFC 9110).
- `If-Match`/`If-Unmodified-Since` are enforced BEFORE any destructive step (PUT, DELETE,
  MOVE, COPY) and ALSO on reads — gated to GET/HEAD 2xx deliberately (ungating turns every
  successful conditional write into a 412). `If-Match` on a MISSING resource answers 404 —
  RFC-REQUIRED, pinned in both directions; do not "correct" it. Tag comparison has one home:
  `WSKEntityTagMatchesList`.
- All three RFC 9110 date spellings parse (calendar year anchored — ICU once read `…94` as
  year 0094 and made `If-Unmodified-Since` a permanent 412); only IMF-fixdate is formatted;
  a 64-char length precheck rejects non-dates in constant time (parsed per-request on the
  process-wide serial queue).
- The DATE form of `If-Range` must keep working — Finder resumes with it (trace `059`).
- gzip is never applied to a 206. Unsatisfiable ranges: 416 + `Content-Range: bytes */N`.
- `WSKFileResponse` opens once with `O_NOFOLLOW` and derives everything from `fstat` on that
  descriptor; EVERY chunk is verified against the promised size/mtime BEFORE handing over.
  A zero-length NSData is the end-of-stream sentinel — the `} else if (_size > 0)` branch is
  load-bearing (removing it broke gzip at all sizes and logged false truncation errors).
- `WSKFileResponse.contentType`/`lastModifiedDate`/`eTag` are honestly `nullable` (sealed
  dates and the 416 path make nil real; breaking for Swift, deliberate).

### Headers and framing

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
- Digest auth works over full bytes (never `-UTF8String`+`strlen`); header-parameter
  extraction requires a token boundary (`nonce=` matches inside `cnonce=` otherwise);
  `filename*` uses an escaper that covers `;`.
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

### File serving and connection reuse

- EVERY file-vending surface honours `Range`/`If-Range`, including uploader `/download`.
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
- A request served from `_carryOverData` must be marked non-idle at the point the carry-over
  is consumed, or the keep-alive reaper cuts its response off mid-body.
- Bytes past `Content-Length` are TRIMMED, never refused (TCP segmentation isn't the
  client's fault); the remainder is dropped, never interpreted.
- `-open`/`-close` fire once per CONNECTION; per-request work (access log, trace recording)
  lives in `-_flushRequestRecordAndLog`. A keep-alive client leaving is EOF, not an error —
  no fabricated 500 in the log.
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

### Limits (fixed constants, deliberately not options)

- `kWSKMaxTotalInMemoryLength` (64 MB) bounds the SUM across all connections; the reservation
  is an OBJECT whose bytes return in `-dealloc`, so a dying connection can't leak budget.
- 16 MB in-memory body; 64 MB decompressed (enforced inside the inflate loop, anti-zip-bomb).
  Consult `WSKMaxInMemoryBodyLength()`/`WSKMaxDecompressedBodyLength()`, never the `kWSK…`
  constants directly (test overrides depend on it).
- Budget exhaustion = 500, settled. A failed body read (disconnect, bad framing, cap) aborts
  the request — never process a partial body as complete. Bodies streamed to disk are
  deliberately unlimited.
- Idle timeout: hard header-phase deadline; body phase uses a byte-RATE floor; response phase
  is any-byte-is-progress (SSE-safe); handler time never counts.

### WebDAV

- Class 1 is complete; PROPFIND publishes nine properties. `getetag`/`getcontenttype` come
  from the SAME functions GET uses (never a second derivation) and are FILE-only —
  collections have no entity tag. `displayname` prefers a stored (PROPPATCH-set) value,
  skipped by BOTH dead-property loops (allprop and `<propname/>`); the derived fallback comes
  from the resource path the client used, which arrives ALREADY unescaped — do not unescape
  again (`50%.txt` once published EMPTY). The root's displayname is deliberately empty.
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
- One stream per BROWSER via Web Locks + BroadcastChannel; `kMaxSSEChannels` (16) bounds
  browsers, not tabs (six per-tab EventSources once deadlocked the whole UI). Closing on
  `visibilitychange` was MEASURED worse — do not swap it in.
- `/events` defence: the Origin check PLUS `Sec-Fetch-Mode`/`Sec-Fetch-Site` PLUS
  `Accept: text/event-stream` (Sec-Fetch alone fails open on older browsers).
- Event paths resolve symlinks with `realpath(3)` on BOTH sides — the `/var` vs
  `/private/var` mismatch has bitten THREE methods; treat any new prefix comparison as
  suspect. `-presentedItemURL` hands out the once-captured RESOLVED root and must not
  re-resolve per call (NSFilePresenter needs it stable); `-_relativePathForAbsolutePath:`
  re-resolves on a miss WITHOUT caching back, and compares against `root + "/"`.
- `-bonjourName` reads `_registrationService` (the service that actually registered, which
  carries an auto-rename).
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
  concurrent 512 MiB streams: 1,587 MB/s aggregate at 20 MB RSS. litmus and mount_webdav
  re-taken on the tuned tree, unchanged.
- Perspective: Puck's network ceiling (Tailscale over WiFi) is ~30–60 MB/s; the server is not
  the bottleneck. Benchmarks live in the scratch harness (`bench.py` + `wskhost.m`).

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
- The lock stub stays a stub; budget exhaustion stays 500; the HEAD-body RFC violation
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

- **`WSKServableFileTypeAtPath` skips its containment check whenever the final component is
  not itself a symlink** (found by fuzzing 2026-08-18; `abs/passwd` through a link to `/etc`
  classifies `NSFileTypeRegular` while `WSKResolvedPathIsWithinDirectory` refuses it).
  `-attributesOfItemAtPath:` does not follow a FINAL link but does follow INTERMEDIATE ones,
  and the early `return type` for a non-link runs before any containment test. **Latent, not
  reachable today**: all three enumerators (uploader `/list`, base-path index, PROPFIND) pass
  an already-RESOLVED directory and append one raw entry name, so only the final component can
  be a link — measured 0 disagreements across 19 real fixture entries, against 2 when the
  directory portion is unresolved. It is the "advertise iff served" rule holding by caller
  discipline rather than by the one function that owns it; a future caller passing an
  unresolved directory reopens it.
- **The allow-list vetting walk judges a symlink's TARGET, not the alias** — fail-closed
  over-refusal contradicting "symlinks are aliases"; needs an OWNER RULING, not a fix (the
  obvious `lstat` fix re-refuses via `_checkFileExtension:` for extensionless link names).
  Invisible in the default configuration (no allow-list ⇒ walk returns nil).
- **Lingering close** (Core invariants → File serving and connection reuse) fixes the body-loss
  case this line named, and corrects its claim that the status was always safe.
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
- **Read the executed count, never the failure count** — a crashed runner reports
  "Executed 0 tests, with 0 failures". A test total that doesn't match expectation is a STOP
  signal (a four-day-old stale log once read as a passing run — use fresh log filenames).
  `Run-Tests.sh` stops at the first failure, so "the suite ran" ≠ "the corpus ran".
- A green oracle you have not proved sensitive proves nothing — inject the defect first. A
  RED from an unvalidated oracle is worth exactly as much as a green. Ask what configuration
  the defect NEEDS (a real defect read 0 at realistic timeouts until the reads were paced).
- Verify batches together, not per-fix; periodically run every technique family against tip.
- `-stop` is NOT a barrier over connection teardown — poll for the event, never read state
  straight after `-stop`. Two timing tests flake under load; re-run a failure in isolation
  before believing it. Don't overlap `Run-Tests.sh` with a running soak (SIGSTOP it).
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
