# WebServerKit

A fork of GCDWebServer with additional features for iOS/macOS web serving.

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
  bytes mid-body; the eleventh pass measured a 48 MB response of which 49.5 MB of body bytes came
  from the replacement, under one 200 OK with a matching `Content-Length`. Each chunk is now
  verified against the size and mtime the response promised. **Publish atomically anyway** — the
  check refuses the transfer, it cannot make a torn read whole.
- **Shape B depends on start/stop correctness**, because it happens constantly. Lifecycle
  races a daemon meets once in its life, this meets every time it wakes.
- **Both depend on refusing clearly rather than half-succeeding.** A request the server cannot
  honour exactly should fail with a status that says so, leaving prior state untouched.
  Silently accepting something and doing an approximation of it is the worst outcome. This is
  why an unsupported `Transfer-Encoding` is a 400 rather than an empty body, why a destructive
  operation stages and swaps rather than removing first, why a truncated gzip body is refused
  rather than written, and why a recursive delete refuses when it would destroy a file a
  direct delete would have refused.
- **Both depend on a transaction leaving nothing behind.** No staging files, no temp files, no
  held descriptors, no connection slots — on the failure paths as much as the success paths.
- The one deliberate exception to "short-lived" is the SSE `/events` stream, which is
  long-lived by design and is bounded separately (`kMaxSSEChannels`, heartbeats, reaping).

**Threat model.** Shape A is reachable only from the tailnet (Tailscale *Serve*, not Funnel)
and binds to localhost, so the audit's assumption of a small trusted network still holds. If
that ever becomes Funnel — i.e. public internet — this needs re-auditing with an
internet-facing lens: there is no rate limiting, no auth backoff, and the 128-connection cap
is trivially saturated. Plaintext transport remains a settled choice because TLS is
terminated upstream; do not re-flag it.

**Tailscale deployments must set `WSKOption_AllowedHostNames`** to the node's
MagicDNS name (`<node>.<tailnet>.ts.net`). The Host allow-list admits localhost, IP literals
and the Bonjour/`.local` name only, so without it every request is refused with 421.

## Recent Changes

### Eleventh audit pass: four techniques never used here, and a proposed fix that was worse than the bug

The tenth pass exhausted the technique list, so this one used four lenses the project had never
applied: **stateful model-based sequence testing**, **concurrent mutating operations**,
**metamorphic relations on the served bytes**, and **the host-app API surface**. Every one of them
found something the request-at-a-time lenses could not, which is the argument for changing
technique rather than repeating a sweep.

**A refused COPY destroyed what another client had just created.** `performCOPY:isMove:` derived a
staging path *only when the destination already existed*; when it looked absent, `writePath` WAS
the destination, so the cleanup written for "a failed tree copy leaves a partial tree behind"
recursively removed whatever occupied that name by the time the copy failed. A `COPY` racing a
`MKCOL` destroyed **209 of 483** collections the other client had just been told it created (201),
while the destroying client got 403. Default configuration, no allow-list, no external actor. It
also defeated the tenth pass's own overwrite vetting, which is gated behind `if (existing)` and so
never ran on this path. Pre-existing since the fourth pass; measured identically on the parent
commit.

**⚠️ The proposed fix made it worse, and the suite stayed green through it — fourth time a proposed
fix has been the dangerous part.** "Stage unconditionally and always swap" moves the destruction
from the copy-failure cleanup into `-_replaceItemAtPath:`'s `rename` fallback, which is a recursive
delete — measured at **83/144 destroyed, answered 201 Created** against 25/95 unfixed, i.e. more
destruction reported as success. The one-line variant (only remove the staging path) closes the
destruction but strands a partial tree, trading a rare race for a routine residue class. What
shipped does both: stage unconditionally *and* make the swap **exclusive** (`renamex_np` with
`RENAME_EXCL`) when nothing was vetted, so an item that appears in the window survives and the
request refuses. `existing` is unchanged, so a dangling symlink at the destination — which
`-fileExistsAtPath:` reports as absent because it follows links, and which the old cleanup
unlinked while answering 403 — now simply makes the swap fail and the link survives.

**The swap removed whatever was at the path, not what had been vetted.** `-_replaceItemAtPath:`
falls back to `removeItemAtPath:` when `rename(2)` refuses, and `rename(2)` refuses here only when
the destination has become a directory. `performPUT:` clears the destination at line 561 (405 if it
is a collection) and then, thirty lines later, destroyed a collection that arrived in between —
answering **204 No Content**. The swap now carries the `dev`+`ino` the caller vetted and refuses to
remove anything else. Note the tenth-pass sentence this falsifies: *"Every other destructive site
was then checked rather than assumed: `performPUT` refuses an existing collection with 405."* True
at check time, false at swap time — **the seventh time this file has claimed a property the code
held only partly**, and the sweep that was meant to close the class stopped at the check.

**A build rewritten in place spliced two representations into one 200 OK.** See the corrected
design-priorities note above. The fix verifies size and mtime **on every chunk, before that chunk
is handed over** — verifying only at end-of-body, which is what was proposed, detects the change
*after* the bytes are on the wire under a satisfied `Content-Length`, so the client still receives
a complete, well-formed, wrong response. That distinction was caught by the regression test failing
against the first attempt at the fix.

**`+responseWithJSONObject:` killed the process.** It is declared `nullable` and even had a
`data == nil` guard — but `+[NSJSONSerialization dataWithJSONObject:]` *raises* for an
unserialisable object rather than returning nil, so the guard was dead code. A host-app handler
returning `[WSKDataResponse responseWithJSONObject:dict]` with an `NSDate`, `NSURL` or `NAN` in the
dictionary terminated the process, Debug and Release alike, and `resp ?: fallback` did not help
because the raise happens first. It asks `+isValidJSONObject:` first now, exactly as
`-initWithText:` does for a string it cannot encode.

**Still open — one finding, deliberately not taken, and it needs a decision.** `DELETE /latest`
where `latest -> build-2026-07-30` answers **204** and removes the whole *target directory*, leaving
the link behind as a dangling entry; `rm latest` behaves the opposite way. MOVE does the same. It
follows from the eighth pass's resolve-once design handing every verb a `realpath`'d path. It was
**not** fixed because the obvious fix is dangerous in three separate ways, all measured: it relaxes
the extension allow-list (a link whose own name is allow-listed but whose target's is not goes from
403 to 204); it resolves *twice*, which re-opens exactly the two-observations class the eighth pass
closed and this file names as the general form that will recur; and it is incomplete, because the
destination side (`MOVE /new.txt` with `Destination: /latest`) is untouched and still replaces the
whole build directory with a 3-byte file. A green suite is not evidence here — the dangerous
version passed all 112 tests and the full trace corpus. Source and destination semantics have to be
decided together, and that is a judgement call about what the library should mean, not a defect fix.

**Verified clean, and worth not re-testing.** The "a refused operation changes nothing" invariant
held across **22,820 operations in 120 sequences**, firing only on the COPY case above, with the
checker proved sensitive by injection first. The three listings (DAV `PROPFIND`, uploader `/list`,
base-path index) never disagreed across 431,151 requests. Range arithmetic is exact across 1,008
header spellings and ~5,000 generated partitions on files from 0 B to 128 MiB; 40 interrupted-and-
resumed 128 MiB transfers reassembled byte-perfectly. **Torn writes do not happen** — 240 concurrent
128 KiB PUTs and 90 concurrent 4 MiB PUTs produced zero mixed files, because the body always lands
in a temp file first. Atomic replacement under load is genuinely safe (915 `rename(2)` replacements,
47.7 GB, zero splices — and the oracle is provably sensitive, since the same harness reported 1,584
splices the moment the writer switched to `O_TRUNC`). All 11 delegate methods arrive on the main
thread with no null-contract violations, all 21 wrong-typed option values are refused with a named
diagnostic, and 21 lifecycle sequences (including 8 threads × 60 concurrent start/stop) produced no
hang or deadlock.

**Known and still open, from the host-app sweep, all low:** creating a server off the main thread
aborts a Debug build inside `WSKInitializeFunctions` (and `+initialize` is inherited, so warming up
`WSKWebServer` first does not protect a subclass); `-stop` after a *failed* start aborts a Debug
build, with no public way to tell that state from a stoppable one; and
`-startWithOptions:error:` returns NO without setting `*error` when the server is already running.
Also carried forward and re-confirmed 10/10: `WSKFormatRFC822` before any server exists still
crashes.

### Tenth audit pass: the scan that was meant to end the programme, and did not

This pass existed to *stop* the audit: the rule agreed beforehand was that if a scan aimed at the
recurring classes found nothing new, the programme ends. **It found five things, and the run had
to be done twice** — the first attempt was killed mid-sweep by a machine reboot.

**Recovering the dead run was worth more than re-running it.** The journal recorded four agents
`started` and no results, which reads as a total loss; `resumeFromRunId` is same-session only, so
it was not available either. But the per-agent transcripts survive on disk, and one of them
contained `**S6c is a hit.**` with the probe table under it. That lead became the first finding
below. The relaunch was then told what was already known so the agents hunted *siblings* rather
than re-deriving it — and three of them independently landed on the same defect from different
directions anyway, which is the strongest evidence any pass here has produced that a finding is
real.

**A collection was again a spelling that skipped the allow-list — this time through MOVE and
COPY.** The eighth pass closed the recursive `DELETE` and the design priorities at the top of this
file then claimed the general property. `MOVE` and `COPY` destroy exactly as much through
`Overwrite`, and nothing vetted what they were about to destroy. Both of `performCOPY:isMove:`'s
extension checks are gated behind `!srcIsDirectory`, which opens *two* doors:

- a **collection source** skips both checks outright, so `MOVE /Src` over a folder holding `id_rsa`
  answered 204 and destroyed it;
- a **file source** does run the destination check — and a collection named `Puck.app` or
  `Backup.txt` *passes* it, because the check only ever judges a name. `COPY /Puck-1.2.ipa` with
  `Destination: /Puck.app` needs no `Overwrite` header at all and took out `id_rsa`,
  `embedded.mobileprovision` and `Frameworks/secret`.

Both measured 5/5, in Debug and Release. The vetting is now one method,
`-_firstUnvettableItemAtPath:isDirectory:`, used by `performDELETE` *and* by the overwrite — a
second implementation of a rule beside the live one is the trap this file already names. Every
other destructive site was then checked rather than assumed: `performPUT` refuses an existing
collection with 405, and the uploader's `/upload` and `/move` route through `-_uniquePathForPath:`
and so have no overwrite path at all. That asymmetry is deliberate and not a parity gap — only
WebDAV implements RFC 4918 `Overwrite`.

**`Overwrite: f` destroyed the destination.** The header was compared with `-isEqualToString:@"F"`,
so that exact byte was the only spelling that meant "do not overwrite" and **every other one was
taken as permission**: `f`, `False`, `no`, `0` and an empty value all answered 204 and clobbered,
while `F` answered 412. RFC 4918 §1.4 adopts RFC 2616 ABNF, in which quoted literals are
case-insensitive, so `f` is *conformant* — a client that explicitly said "do not overwrite" lost
its data and was told it succeeded. This one fails **open**, which is what separates it from the
identical shape in the `Depth: infinity` comparison, which fails closed and was merely an interop
bug; both are case-folded now through one `_HeaderTokenIs` helper.

**Deliberately not changed:** a `MOVE` with no `Overwrite` header at all still answers 412. RFC
4918 §9.9.3 says an absent header means `T`, but conforming would make MOVE destructive by default,
against this file's own "refuse rather than half-succeed" priority. Recorded rather than fixed.

**An upload escaped the share through its filename.** `POST /upload` with `filename="/"` — no
`path` field needed, no allow-list set, i.e. the **default configuration** — answered 200 and wrote
the body *beside* the served directory. `[@"/" lastPathComponent]` is `@"/"`, the one input for
which that does not yield a leaf; it then passes every guard, and
`-stringByAppendingPathComponent:@"/"` collapses straight back to the upload directory, so
`-_uniquePathForPath:` finds it already exists and renames **its own leaf in the parent** —
`Share (1)`, repeatable and unbounded. Same class the eighth pass called the sharpest finding of
any pass, arriving through the filename rather than a symlink.

**⚠️ The fix the agent proposed for it would have broken every upload under `/var` or `/tmp`,** and
its own skeptic caught that. The suggestion was `WSKPathIsInsideDirectory(desiredPath,
_uploadDirectory)`, but `_uploadDirectory` is stored `-stringByStandardizingPath`'d (a share under
`NSTemporaryDirectory()` stays `/var/…`) while `desiredPath` is composed onto a `realpath(3)`
result (`/private/var/…`), so the comparison is false for every legitimate upload there — and
`MakeTempDirectory()` uses exactly that base, so the suite would have gone red. What shipped
rejects a separator in the reduced leaf *and* judges the composed path against **`resolvedDirectory`**.
This is the second time a proposed fix, not the finding, was the dangerous part.

**A content coding the server could not decode was stored as the entity.** `-prepareForWriting`
installed the gzip decoder for the exact token `gzip` and had **no else branch**, so every other
coding left the raw sink in place: `PUT` with `Content-Encoding: deflate` wrote the *compressed*
octets to disk and answered 201. `x-gzip` — which RFC 9110 §8.4.1 defines as a synonym for `gzip`
— was silently stored undecoded too. The rule this violates was already written down one screen
away, in `_ParseTransferEncoding`: *storing the still-encoded bytes as if they were the body is
worse than refusing.* Unsupported codings are now 415; `x-gzip` decodes, because refusing it would
trade silent corruption for an interop bug.

**Preconditions were evaluated after the write.** `If-Match` was not parsed anywhere in the tree,
and `-overrideResponse:forRequest:` — the only place any precondition was evaluated — runs *after*
the handler has produced its response, comparing against a `response.eTag` that a 201/204 does not
carry. So no 412 could ever be produced and the lost-update protection a WebDAV client believes it
has did not exist: two clients editing one file each silently overwrote the other. Now enforced
before any destructive step for **PUT, DELETE, MOVE and COPY** rather than only for PUT where it
was found, since "closed at one of the sites the rule applies to" is this codebase's most reliable
defect shape. The tag is `WSKEntityTagForFileInfo`, extracted so `WSKFileResponse` and this check
cannot drift — a second formatter would make every precondition fail rather than protect anything.

**Class C came back genuinely clean, and the instruments were proved before the zeros were
believed.** 67 failure scenarios × 250 iterations ended at exactly baseline descriptors (12 → 12);
a 676,970-request soak ended 33 descriptors *below* baseline; `reservedInMemoryByteCount` was 0 at
rest in every run, including after being driven to its ceiling and abandoned there 150 times with
`SO_LINGER {1,0}`. The staging-swap failure path was forced with an immutable child: 30 COPY + 30
MOVE left zero staging siblings and restored the source 30/30. An RSS creep of ~15 B/request was
chased rather than waved away and proved to be allocator behaviour — `leaks(1)` reported zero, live
bytes went *down* between samples, and a legitimate-traffic-only control showed the same slope.
**Do not re-run this speculatively.**

Also clean and worth not re-testing: 1,143 same-bytes-different-segmentation pairs plus 2,700
randomized splits produced zero verdict differences, including the 256 KiB×2^k band where the ninth
pass's gzip defect lived — the split-invariance oracle found nothing this time. HEAD/GET parity was
exact across 79 header-by-header comparisons. The NUL guard was confirmed present at all 10
client-path entry points by *driving* each one, not by grepping.

**The one disagreement that was adjudicated rather than fixed:** listing a symlink-to-root answers
200 from the base-path handler and 403 from the uploader and WebDAV. Not a defect, and measured
rather than argued — the body of `GET /selfroot/` is byte-identical to `GET /`, so the permissive
answer discloses nothing, and every composite through it is still refused exactly as its direct
spelling is. The refusal in the other two is the resolver-level guard protecting their destructive
verbs; the base-path handler has none to protect.

**Still open:** the `MOVE`-without-`Overwrite` default above, deliberately. The `//` status
disagreement from the eighth pass remains deliberately unfixed.

**A note on running this again.** Two timing tests — `testConnectionIdleTimeoutSparesSlowHandler`
and `testConnectionClosesSlowlorisHeaderDribble` — fail when parallel agents saturate the machine
(observed at load average 169; both passed 3/3 in isolation immediately after). Do not read a
`Run-Tests.sh` verdict while a fleet is building, and re-run a failure alone before believing it.

### Ninth audit pass: fuzzing, differential testing, and a fix of mine that destroyed the share

Run overnight, unattended, with three techniques this project had never applied: mutational and
grammar-aware fuzzing straight at the body parsers, differential testing against an independent
HTTP implementation, and allocation-failure injection. Plus randomized lifecycle churn. Agents
ran in their own git worktrees with instructions to change nothing, and every finding was
reproduced independently before being acted on.

**⚠️ The eighth pass's own resolve-once fix turned a symlink into "destroy the whole share".**
The `"not the root directory"` guards are correct, but they are evaluated on the path the client
*typed*; the resolve-once work then substituted the resolved path — which is the root — with no
re-check. One unauthenticated request emptied a five-entry share to zero through DAV `DELETE`,
DAV `MOVE` and the uploader's `/delete` alike, answering 204, 409 and 200.

The general form will recur and is the thing to remember: **resolving once and acting on the
resolved path is right, but every rule stated about the unresolved path has to be restated about
the resolved one.** It is refused in the resolver rather than at each destructive call site, so a
site added later cannot forget it; naming the root *directly* is still allowed, because listing it
and uploading into it are ordinary operations.

**A malformed multipart boundary closed descriptor 0.** `-[WSKMIMEStreamParser
initWithBoundary:...]` returned nil before `[super init]` and before `_tmpFile = -1`. Under ARC a
nil-returning initializer still deallocates its receiver, so `-dealloc` ran on a zeroed object and
its `close(_tmpFile)` became `close(0)` — a descriptor it never owned. Once freed, that slot goes
to the next `accept()`, so a later malformed request tears down a live connection mid-serve;
measured as a process crash under concurrent load. The sentinel's own comment showed the hazard
was understood — it was established too late. Establish `[super init]` and any fd sentinel before
the first failure return.

**A NUL in the multipart filename killed the process** — it reached
`-stringByAppendingPathComponent:`, which returns nil for a NUL-bearing receiver, and the nil
reached `-[NSFileManager moveItemAtPath:toPath:error:]` as its destination. Fourth appearance of
this codebase's recurring shape, and the second time a fix for it did not reach every site the
value can arrive by: the eighth pass guarded the query and form fields and missed the two that
arrive through the multipart parser.

**A gzip body's verdict depended on TCP segmentation.** A concatenated second member sent in one
write was silently dropped and answered 200 — handing the handler less data than the client
sent — while the identical bytes split at the member boundary answered 500. The client chose
which. The fifth pass fixed the later-read half and this file recorded the case as closed; the
same-read half was still open, because `Z_STREAM_END` was accepted without checking whether
`avail_in` still held bytes. **A split-invariance oracle found this automatically** — same
request, different segmentation, different answer — a cheap property worth reusing.

**The entity tag did not identify the bytes.** It was inode + mtime only, so a rewrite in place
that restores the timestamp — `utimes(2)`, and what `rsync -a`, `cp -p` and `tar -x` all do —
produced a byte-identical tag for different content. A 900-byte build replaced by a 916-byte one
answered **304** to a revalidation (the client keeps the stale copy indefinitely) and **206** to a
resume (the new build's bytes spliced onto the old one's prefix). That is precisely the failure
the `If-Range` work exists to prevent, arriving through the *strong* validator rather than the
weak one — and this file's own note that a preserved-mtime replacement is "undetectable by any
date-based scheme" quietly implied the ETag handled it. Size is now part of the tag, as Apache
does. Equal-length-and-equal-mtime remains undetectable, and nothing derived from `stat(2)` can
close it.

**Nothing accumulates over hours, and this is now measured rather than extrapolated.** A five-hour
soak — 12 concurrent workers doing ranges, revalidation and abortive mid-transfer deaths while a
writer rewrote the served file every 750 ms — ran **19,723,889 requests and 15.6 TB**. Descriptors
ended *below* baseline; `+[WSKWebServer reservedInMemoryByteCount]` was **0 at every one-minute
sample and at rest**. The previous evidence for Shape A's central assumption was 450 sequential
requests. **Do not re-run this speculatively**; re-run it when the connection or response layer
changes.

Also genuinely clean, and worth not re-testing: allocation-failure injection found nothing across
9,366 injected failures with zero descriptor leaks; randomized lifecycle churn found no hang,
leak or unreclaimed port; and the differential comparison found this library *more* correct than
the reference on Range arithmetic across 1,200 generated headers.

**The record has now overstated the code four times**, and the pattern is worth naming: the sixth
pass's `If-Range` claim, the hidden-item rule that covered two servers of three, the recursive
delete that only the uploader vetted, and the gzip trailing-data case above. Every one was a
sentence in this file describing a property the code held only partly. When a pass closes a class,
check every site the class can occur at before writing that it is closed.

**Still open:** nothing from this pass. The `//` status disagreement from the eighth pass remains
deliberately unfixed.

### Eighth audit pass: property-testing the path rules, and a merged PR that never landed

Narrow by design — aimed only at the path containment and hidden-item rules the seventh pass had
just rewritten, on the reasoning that the reading-based lenses are mined out and the newest
security-load-bearing code is where the risk is. The technique was new: **property-based testing**
rather than hand-picked cases. Four generators composing percent-encodings, Unicode normalization
and homoglyphs, case variance, symlink topologies and boundary lengths, asserting four invariants
(containment, hiddenness, no over-refusal, cross-server agreement) over thousands of generated
paths.

It earned its place immediately, and the reason is worth keeping: every finding below came from
*generating* inputs rather than from someone imagining the case. The NUL crash alone triggered on
188 of 2,356 generated enumeration paths. **The invariants did not hold** — the hoped-for clean
result did not materialise.

**One unauthenticated GET killed the process.** `WSKNormalizePath` truncates at an embedded NUL,
deliberately and correctly, because the filesystem's C-string APIs do and the mismatch is
otherwise exploitable (`secret.dat\0.png` passes an extension allow-list and opens
`secret.dat`). But truncating does not make the request mean what the client wrote, and the
server went on to honour the prefix. `GET /list?path=%00` passed every guard — normalized to the
upload root, which exists, is contained and is not hidden — and the per-entry JSON was then built
from the **raw** value, where `-stringByAppendingPathComponent:` returns nil for a NUL-bearing
receiver. Nil into a dictionary literal, `NSInvalidArgumentException`, nothing catches it,
process gone. 5/5 in Debug and 5/5 in Release.

This is the crash shape this file already names as recurring here — *a nil value reaching a
dictionary literal* — resurfacing at a site the earlier fix for it did not cover. The note
predicted the class; nobody had swept for it.

**The worse half of the same defect: a destructive request honoured against the prefix.**
`POST /delete path=/Keep%00/nonexistent` named nothing that exists and deleted `/Keep`. That is
exactly what the design priorities above call the worst outcome — silently doing an approximation
instead of refusing. So all six uploader endpoints taking a client path now refuse a NUL-bearing
one with 400 (`WSKPathContainsNULByte`); normalization keeps truncating as a second line, so the
extension-allow-list bypass stays closed.

**A retargeted symlink escaped the share, in all three servers.** Every path-taking endpoint
checked containment with one `realpath(3)`, hiddenness with a *second, independent* one, and then
operated on a **third** path — the one the client sent, symlinks intact. Three observations of a
filesystem that need not agree. Measured, with a helper thread retargeting a link via `rename(2)`
so it is never absent:

| surface | before | after |
|---|---|---|
| base-path handler `GET` | 977/4000 served content from outside the root (24.4%) | 0/4000 |
| uploader `/download` | 551/3000 (18.4%) | 0/3000 |
| WebDAV `GET` | 772/3000 (25.7%) | 0/3000 |
| WebDAV `PUT` | **228/600 files written OUTSIDE the share** | 0/600 |
| control, link held fixed | 0/1000 | 0/1000 |

The write is the sharpest finding of any pass: a remote client causing files to land outside the
shared directory, 38% of attempts. It needs no concurrency on the client side — the window is
between the server's own steps inside one request — and for a build server rewriting a
`latest ->` link while serving, the precondition is ordinary operation rather than an attack.

`WSKResolveWithinDirectory()` resolves once and reports both the absolute location and its path
relative to the resolved root, so both rules judge the same observation; each server's
`-_resolvedPathForRelativePath:hidden:` wraps it, and callers **bind the result to the variable
the rest of the method already used** — chosen over rewriting each downstream use because it
makes "I missed one" structurally impossible, which is the failure mode that would matter most
here. `-_isHiddenPath:` was deleted from both servers once every caller was converted: an unused
second implementation of a security rule sitting beside the live one is a trap for whoever needs
that check next.

**Not closed, deliberately:** a real *directory* renamed between resolution and use. Closing it
needs an `openat(2)` component walk or `O_NOFOLLOW_ANY`, which would also refuse the benign
intermediate symlinks that work today and are covered by
`testBasePathHandlerRefusesSymlinkEscape`.

**⚠️ A merged PR is not a landed change.** The uploader/WebDAV fix was stacked on the base-path
one. The base PR merged into `main` first; the stacked PR then merged into *its base branch*,
which by then was detached from main's history. GitHub reported it MERGED. It was — into a dead
branch, and the WebDAV write escape stayed live on `main`. It was caught by grepping `main` for
the code rather than by reading the PR list, and confirmed with
`git merge-base --is-ancestor`. **Do not stack PRs here**, or if you must, verify the landing by
looking for the code. The same shape bit twice more in one session: a CI run reported success for
a *pre-rebase* SHA, and `Run-Tests.sh` builds into `./build` while ad-hoc probes load from
DerivedData, so a probe after a swap-build-restore reports the previous build. In all three a
green signal was about something other than the thing being asked about.

**The ten unverified violations were then re-measured rather than fixed from the report, and
eight of them evaporated.** This is the most transferable thing the pass produced, so it is
recorded in full:

- **Five were already fixed** — by the resolve-once change, as a side effect nobody predicted. A
  benign symlink as the final path component had been unservable, answering 500 with an empty
  body from two servers and three different statuses across the three. All of that came from
  vetting one path and *serving another*; once the resolved path is what gets opened, a
  final-component symlink resolves to the real file and all three now answer consistently
  (200/200/207). The security fix cured an over-refusal class as well.
- **One** was the containment race that same change closed.
- **One is cosmetic and deliberately left**: a target beginning `//` gives 501 from the base-path
  handler and 404 from WebDAV. Both refuse; only the status differs.
- **Two were real**, below.

Acting on the report as written would have meant "fixing" five non-problems in the most
security-critical code in the library. **Re-measure before acting on an audit report** — findings
age against a moving tree, and this one had moved three PRs since the run.

**WebDAV's recursive DELETE bypassed the extension allow-list.** A collection was a spelling that
skipped the check entirely: with `allowedFileExtensions = ["txt"]`, `DELETE /Folder` answered 204
and destroyed both `id_rsa` and `.env` — each of which the same server refuses with 403 when
addressed directly. The uploader had vetted its subtree since the fifth pass, and **the design
priorities at the top of this file already claimed the property** ("a recursive delete refuses
when it would destroy a file a direct delete would have refused") while only one of the two
servers had it. That is the third time in two passes that this file asserted behaviour the code
did not have; the others were the sixth pass's `If-Range` claim and the hidden-item rule that
covered the uploader and WebDAV but not the base-path handler.

The vetting mirrors `-[WSKWebUploader deleteItem:]` including both of its judgement calls, which
are what separate a working rule from an unusable one: dot-names and their descendants are
skipped whatever `allowHiddenItems` says, because a `.DS_Store` sits in every macOS folder with
an empty `pathExtension` that is in no allow-list; and an extensionless file *is* vetted, because
a direct DELETE of it is already refused.

**The directory index disagreed with the handler.** `allowHiddenItems:YES` served a dot-file
while the listing still omitted it, so the browsable index described a smaller tree than the one
being vended — the same disagreement the sixth pass fixed in the opposite direction, arriving
with the opt-out this pass's symlink work added. `testDirectoryIndexAgreesWithWhatIsServed` pins
both directions, and `testDAVRecursiveDeleteRespectsExtensionAllowList` pins the delete; both
fail against the code before them, and both also assert what must keep working — a folder whose
only extra entry is a `.DS_Store` stays deletable, and the default configuration still hides
*and* refuses hidden items.

**Still open:** the `//` status disagreement above, deliberately. Everything else from this pass
is closed.

### Seventh audit pass: a fix that did not fix, a crash, and the first real concurrency soak

Aimed deliberately at what the sixth pass changed (~154 lines of production code) rather than
at the tree, on the observation that **every pass has planted defects the next one found** —
pass four found two regressions from pass three, pass six found two in pass five's
conditional-request work. Seven agents investigating, each finding then put to a skeptic
required to reproduce it independently and to build the *pre-change* commit before calling
anything a regression.

**The sixth pass's `If-Range` fix did not work, and this file said it did.** Three lenses found
it independently and it reproduces 5/5. The deduction that a timestamp is strong once it is a
second old was evaluated in the *resume* path — where it is worthless, because a resume always
arrives after the second has shut, so it reports "strong" for exactly the representation that
is not. Two builds written inside one wall-clock second still spliced under a 206.

It belongs where the validator is **minted**: a `Last-Modified` is now simply not issued while
mtime is inside the current second, so every date a client can present was sealed before it was
handed out and does identify one representation. The ETag carries `tv_nsec` and was never
affected — which is why the ETag control restarted correctly 4/4 while the date form spliced,
the observation that ruled out a harness artefact. Costs a date-only client one second of
caching; a future mtime is unsealed by the same test, which also stops the server advertising a
`Last-Modified` newer than its own `Date`. Pinned by
`testIfRangeRefusesADateMintedInsideItsOwnSecond`, which fails 2/2 against the sixth pass's code.

**⚠️ Correction (tenth pass): the redemption-time check is NOT a second line of defence, and this
entry and the commit both said it was.** Withholding the date at issue time is the whole of the
protection. The check that survives in the resume path is still evaluated when the resume
*arrives*, so a resume landing even one second later sees a sealed timestamp and honours the
date — measured 200 in the same second, 206 one second later, 206 two seconds later. That is the
identical flaw this pass diagnosed in the sixth pass's fix, left in place and then described as a
defence. It cannot be fixed: once the second closes the server *would* issue that date for the
current bytes, so a date a client legitimately holds and one it fabricated are byte-identical,
exactly as for a replacement that preserves mtime. What protects a conformant client is that no
such date is ever issued while the second is open. The test now verifies the whole sequence lands
inside one second rather than only the write — checking only up to the write made it pass locally
and fail on a slower CI runner — and pins the closed-second behaviour so a later pass does not
re-find it and churn.

Not a regression — the pre-fix commit was built and measured and behaves identically. The
defect was in the claim, not the code, which is the more dangerous kind in a file whose purpose
is to be trusted.

**The uploader's asset restructure turned unmatched paths from 404 into 501** — a regression from
the sixth pass. Removing the catch-all base-path handler left nothing matching `/favicon.ico`,
which browsers request unprompted, so the server answered `501 Not Implemented` — a statement
about the *method*, which it implements fine. Inside the scoped asset directories a miss was
still correctly 404. A catch-all GET handler restores it, registered *first* so it matches
*last*: handlers are inserted at index 0, so registration order is reverse match order, and
getting that backwards would shadow the page and every asset while still passing a naive 404
check. The test asserts `/` and `/css/index.css` still return 200.

**Nothing accumulates under sustained concurrent load — the first time that has been measured.**
The existing soak is ~450 *sequential* requests; Shape A is weeks of concurrency. A harness ran
**146,364 requests moving 896 GB** with concurrent range requests, resumes, revalidation,
clients dying mid-transfer, and the served file rewritten underneath: zero descriptor growth,
zero reservation growth, and `+[WSKWebServer reservedInMemoryByteCount]` back to zero at rest —
the process-wide static with no reset that is the sharpest edge in this library. Separately, 600
start/stop cycles, 1,900 aborted transactions and an idle-timeout evasion matrix produced no
hang, no deadlock and no unreclaimed slot. **Record this as a negative result and do not re-run
it speculatively**; re-run it when the connection or response layer changes.

Also verified clean, having been suspected: the `SO_NOSIGPIPE` guard leaks nothing and drops no
connection it could have served; the directory-listing href escaping is correctly ordered and
closes the direct `javascript:` route as well as the entity route; and the `If-Modified-Since`
exact-equality change holds end to end with `If-None-Match` precedence per RFC 9110 §13.1.3.

**Three findings were refuted, all on the same ground** — the behaviour was byte-identical
before the change set, established by building the earlier commit rather than by reading. Worth
noting as the pattern it is: an agent auditing a diff will attribute anything it finds nearby to
that diff unless it is made to check.

**A single unauthenticated request could kill the process.** A request matching no handler is
built in its own branch of `-_readRequestHeaders` and handed to `-abortRequest:withStatusCode:`,
which is a subclassing point a host app reaches through the public `WSKOption_ConnectionClass`.
That branch set *none* of the three fields the matched path sets — so a subclass doing the
obvious thing in that hook, logging who the refused request came from, read `-remoteAddressString`
on a request whose address data was nil. `WSKStringFromSockAddr` evaluates `addr->sa_len` before
calling `getnameinfo`, so there is nothing to fail closed on: SEGV, observed under ASan, from
`GET` or `HEAD` to any path no handler claims. The address half is old; the third field,
`virtualHEAD`, was the sixth pass's own omission — it added the flag to the matched path only.
`testAbortedRequestCarriesItsAddressesAndHEADFlag` covers it, and **against the unfixed source it
does not fail, it SEGVs and takes the whole test process with it** — reported as "0 failures".
Read the executed count.

**A symlink defeated hidden-item protection in all three servers.** Hiddenness and containment
are independent rules, and every hidden-item check tested the path the *client typed*. A symlink
named `pub` pointing at `.git` makes `/pub/config` carry no dot at all, while containment passes
because the target is inside the served root — so both rules were satisfied by a path whose bytes
live inside a dot-directory. Measured: the base-path handler served it, the uploader both
downloaded and *enumerated* through it (discoverable in the UI, not guessed), and WebDAV wrote
through it — `PUT /pub/hooks/x` answered 201 and landed in `.git/hooks/x`, a write the same
server refuses spelled `/.git/hooks/x`. `WSKResolvedPathHasHiddenComponent()` now tests the
resolved path expressed relative to the *resolved root*; relative to the root deliberately,
because the root itself may live under a dot-directory (`NSTemporaryDirectory()` under a
sandboxed app routinely does) and testing the absolute path would refuse every file the server
vends. That case is in the test, because it is the trap the naive version of this springs.

Pre-existing, and it needs a symlink already present in the served content — nothing in this
library creates one, so it arrives with a git checkout, an unpacked archive or an operator's own
link. Because "hidden" now means where the bytes live, a deliberate convenience link such as
`latest -> .builds/2026-07-25` stops resolving, and `addGETHandlerForBasePath:` had no
`allowHiddenItems` concept at all — so it gained an `allowHiddenItems:` variant. The existing
five-argument form delegates with `NO`, so no caller changes behaviour.

**An SSE channel outlived its own connection by 30 seconds.** `WSKConnection` calls
`-performClose` the moment the body write chain ends, including the write that fails because the
client has gone; nothing in the uploader listened, so the reaper's two idle ticks started only
*after* the server already knew. Sixteen abandoned streams — browser tabs navigating away, no
hostility required — denied live updates for about a minute. The channel now dies with the
connection. **This is a halving, not a cure, and the entry should not be read as more:** measured
62s → 32s with graceful closes. It removes the reaper's 30s tail only; the 15–30s the server
takes to *discover* the departure is untouched, because nothing tells it until a write fails.
The reaper remains the backstop for a client that is merely silent. (`retry: 30000` in the
refusal body is a one-constant lever on the client-visible half, if it ever matters.)

**⚠️ Unreviewed agent code reached `main` under an unrelated commit message.** While the triage
agents were running, `git add -A` on the If-Range branch swept an agent's edits to
`WSKFunctions.h/.m` and `WSKWebServer.m` into commit `aa1969a`, whose message describes only the
If-Range change. Those edits implemented the base-path half of the symlink fix above. They were
correct, and they passed CI and the full harness — but that is luck, not process, and the history
now attributes them to a commit that never mentions them. Recorded here because an unattributed
edit on `main` is exactly the kind of thing that becomes invisible in a month. Two things were
changed back afterwards: the cheap textual walk was put in front of the resolved one, so a
`realpath` is only paid when it can change the answer, and the resolved test was moved after
containment, so an escape is still reported as an escape rather than as a hidden item.

**Orchestration lessons, all three the same shape.** Agents were told not to edit the tree and one
did anyway, leaving a half-applied fix that broke the build. Concurrent agent builds clobbered
shared DerivedData twice, producing a phantom link failure and a phantom "the fixes are not on
main". And `args` passed as a JSON string arrived as `undefined`, so the first workflow's prompts
read `SCOPE: the change set undefined..undefined` — the agents recovered because the changed-file
list was spelled out, but the scope instruction was degraded. Any agent that might write needs
worktree isolation; anything building concurrently needs its own `-derivedDataPath`; and staging
should name paths rather than `-A` while background work is live.

**Still open — one finding, deliberately not taken.** With `WSKOption_AutomaticallyMapHEADToGET`
set to `NO` *and* a handler registered for `HEAD`, a response body is written to a HEAD request,
which RFC 9110 §9.3.2 forbids. Nothing in the tree does either half — the option defaults to YES
and no in-tree handler registers HEAD — so it takes a host app opting into both. Recorded rather
than fixed because the obvious one-line fix is wrong: keying on `_request.method` uses whatever
the match block stamped, not what arrived on the wire, so a handler registered through the public
`addHandlerWithMatchBlock:` with `initWithMethod:@"HEAD"` would have a genuine GET's body
suppressed. Fix it off the wire method if it ever becomes reachable.

Carried forward from the sixth pass, both still true and both pre-existing: `bootstrap.css`
requests `.woff`/`.woff2` glyphicons that are not in the bundle (a 404 on every page load;
browsers fall back to the `.ttf` that ships), and `WSKFormatRFC822`/`WSKParseRFC822` are public
but `dispatch_sync` on a queue only created by `+[WSKWebServer initialize]`, so calling either
before any server exists crashes.

### Sixth audit pass: a process-killing socket option, two dishonest validators, and the uploader's channels

Run after the WebServerKit rename, on the premise that a mechanical sweep across 514 files is
exactly when a check quietly stops being enforced. Eight findings, fixed across four branches
(PRs #29–#32). Every regression test here was run against the *unfixed* source first and
confirmed to fail on the intended assertion — twice that caught a test that passed for the
wrong reason. **Two of the fixes below were wrong on the first attempt**; both are recorded as
such, because both mistakes are easy to repeat.

**A client reset could kill the entire process.** The accept handler set `SO_NOSIGPIPE` on the
accepted socket and never checked the result. If the peer's RST has already reached the kernel
by the time that runs, Darwin fails the option with `EINVAL` and leaves it **off** — so the
next write raises SIGPIPE, whose default disposition terminates the process. Measured with a
client doing an abortive close (`SO_LINGER {1,0}`): the server died at reset #13, exit 141 —
roughly one per 15–25 connections. This needs no malice at all, just a cancelled download, and
for a build server meant to run for weeks it is the worst finding of any pass so far. The
socket is now dropped when the option cannot be set; `testAbortiveClientResetsDoNotKillTheProcess`
sees the guard fire 72–94 times per 400 resets.

**`addGETHandlerForBasePath:` was the one file-vending path with no hidden-item check.** The
uploader and WebDAV both walk every path component (third and fourth passes); the base class
never got it, so `GET /.git/config` returned the file — with its embedded token — while the
directory listing dutifully hid it. The fourth pass had already given this handler a
*containment* check, which is what made the omission easy to miss: it looked audited. Covered
by `testBasePathHandlerRefusesHiddenItems`, which asserts on a file inside a dot-*directory*,
not just a leaf dotfile.

**Directory-listing hrefs were percent-encoded but never HTML-escaped.** The two escapers are
not interchangeable: the URL escaper leaves `&` alone, so a filename containing `&colon;`
reached the `href` attribute intact and the browser's entity decoder turned it back into a
`:` — reconstituting `javascript:` inside a link in the server's own origin. Now escaped as
markup after being escaped as a URL, in that order (`testDirectoryListingEscapesHrefEntities`).

**`If-Range` honoured a date that could not tell two builds apart.** `st_mtime` has
one-second resolution, so a file modified within the current second can be modified *again*
inside that same second without the timestamp moving — which is precisely what `If-Range`
requires a strong validator (RFC 9110 §13.1.5) to exclude. A build rewritten inside one
wall-clock second read as "unchanged", so a resumed download spliced the tail of one
representation onto the prefix of another and returned 206 asserting they belonged together.
Silent: `Content-Length` agrees with `Content-Range`, so nothing downstream notices.

**⚠️ The first fix for that refused dates outright and broke macOS Finder.** The recorded
Finder session in `Tests/WebDAV-Finder/059` resumes with `If-Range: <HTTP-date>` and no entity
tag, so honouring only the ETag form turned every Finder resume into a full re-download. The
trace suite caught it — the corpus earning its keep one pass after being revived. The second
attempt applied the deduction RFC 9110 §8.8.2.2 provides for exactly this: the origin may
treat the timestamp as strong once it is **at least one second in the past**, because no
further change can land in that second any more.

**⚠️⚠️ That second attempt did not work either, and this entry claimed it did — see the
seventh pass below, which corrects it.** The deduction was applied when the resume was
*redeemed* rather than when the validator was *issued*, and at redemption the second has
always closed, so the guard reported "strong" for precisely the representation that was not.
The splice described above stayed reproducible 5/5. It was not a regression — the code was no
worse than before the pass — but the claim was wrong, which is worse than the bug in a file
that exists to be trusted. A replacement that *preserves* mtime (`rsync -a`, `cp -p`, `tar -x`)
stays undetectable by any date-based scheme, here or anywhere else.

**`If-Modified-Since` answered 304 for a representation older than the client's.** The
comparison was "not strictly newer", so rolling a build back pinned a date-only client
permanently: told 304, it keeps the stale body and — per RFC 9111 §4.3.4 — adopts the
*current* `ETag` and `Last-Modified` from that 304, so its next revalidation matches on the
ETag too and no request ever dislodges it. A *future* `If-Modified-Since` validated
everything. Now exact equality, which is safe because `_NSDateFromTimeSpec` truncates the
served `Last-Modified` to whole seconds and `WSKParseRFC822` parses at the same precision, so
echoing back the served value still revalidates. This is nginx's default too
(`if_modified_since exact`).

**A `HEAD` request took an SSE channel and gave nothing back.** `HEAD` is mapped to `GET`
*before* handler matching, so `/events` ran and registered a channel — but the connection
layer discards a mapped HEAD's body unsent, so the stream block never ran and no client ever
held the channel. Nothing released it either; only the heartbeat reaper did, two ticks later.
Sixteen HEADs therefore denied live updates to every real client for ~30 seconds, and they are
unusually cheap: each request *completes*, so the sender holds no connection slot and can
repeat the burst indefinitely. The `Sec-Fetch-*` checks are no help — they decide which origin
may ask, and this costs nothing to ask from anywhere on the network. A mapped HEAD now gets a
bodiless response, which is the right answer to HEAD anyway. **Correction to the finding as
first reported:** the denial is ~30s and self-healing, not permanent — the first measurement
waited 20s and missed that the reaper needs *two* consecutive idle heartbeats.

Handlers had no way to see this, so `WSKRequest` gained `-isVirtualHEAD`, set by the connection
where it rewrites the method. It matters to any handler whose response *is* a long-lived
resource rather than just bytes.

**The uploader's own page could be framed by asking for it a different way.** The bundle root
was served by a base-path handler and `index.html` is a file in that bundle, so `/index.html`
returned the template raw — placeholders unsubstituted and, the point, without the
`X-Frame-Options`/`frame-ancestors`/`nosniff` headers the `/` handler sets. Framing that path
instead of `/` defeated the clickjacking defence completely, on a UI whose one-click buttons
delete and move files and whose `#/path` fragment aims it at a chosen folder.

**⚠️ The first fix for that was an exact-path alias for `/index.html`, and it does not hold.**
The base-path handler normalizes, so `/./index.html` and `/x/../index.html` both still reached
the raw file — verified, and the test covers both. **An exact path is not a containment
boundary.** What ships serves only the three asset directories the page actually loads (`css`,
`js`, `fonts`), which takes the template — and `en.lproj/Localizable.strings`, which no browser
needs — out of the URL space altogether, so there is no spelling left to find. `/index.html`
remains as a convenience alias and is explicitly *not* the control. The test asserts the assets
still load, so this cannot silently become "the UI is broken".

**`/events` failed open when `Sec-Fetch-*` was absent**, and those headers are exactly what
stops a cross-origin page pinning every channel. They are absent on every browser predating
them (Safari < 16.4, Firefox < 90) — precisely the browser an attacker would choose. It now
runs the same `-_rejectIfCrossOrigin:` the mutating endpoints use, which reads `Origin`.
Non-browser clients send no `Origin` and are unaffected; the served page's own `EventSource`
sends a matching one. Both are asserted, because refusing the real UI would be the easy
mistake.

**Test-suite traps worth remembering.** `Run-Tests.sh` builds into `./build`, while an ad-hoc
probe linked against the framework loads it from *DerivedData* — so after a
swap-build-restore experiment a probe reports the previous build's behaviour. This produced a
phantom test failure (blamed on the test for half an hour) and later a phantom "the fixes are
not on main". Always rebuild explicitly before believing a probe. Separately, `retry: 30000`
(the SSE refusal) has `retry: 3000` (the acceptance preamble) as a *prefix*, which is the
fourth substring-assertion misfire in two passes; match the longer marker first, or include
its terminator.

**Still open:** nothing from this pass's findings. Noted but deliberately untouched, both
pre-existing: `bootstrap.css` requests `.woff`/`.woff2` glyphicons that are not in the bundle
(a 404 on every page load; browsers fall back to the `.ttf` that ships), and
`WSKFormatRFC822`/`WSKParseRFC822` are public but `dispatch_sync` on a queue only created by
`+[WSKWebServer initialize]`, so calling either before any server exists crashes.

### Fifth audit pass: response-side amplification, refusal ordering, and a regression from the budget branch

Run with eight deliberately disjoint lenses and every finding put through two independent
refuters — one reading the call chain, one required to reproduce it — because the fourth
pass showed that reading alone manufactures confident nonsense. Each fix below was checked
in both directions: the regression test was run against the *unfixed* source and confirmed
to fail. Two findings were defects in code added by the host-validation and
aggregate-budget branches.

**A truncated gzip request body was accepted as a complete one.**
`-[WSKGZipDecoder close:]` asserted `Z_STREAM_END` and then reported success
regardless; `WSK_DCHECK` is a no-op in Release. A `PUT` of a 20-byte gzip prefix over an
existing file answered `204 No Content` and left the file **zero bytes** — stage-and-swap
does not help, because the handler runs. The same request aborted a Debug build. Trailing
bytes *after* `Z_STREAM_END` were a second DCHECK, silently discarding a concatenated
member in Release. Both refuse now, and `close:` still closes the downstream writer so the
refused transaction leaves no descriptor or staging file behind.

**Every refusal was evaluated after the whole body had been spooled to disk.** The
connection matched a handler and read the body immediately; `-_startProcessingRequest` —
which runs the Host allow-list and `-preflightRequest:` — was only reached from that
read's completion. Measured: **288 MB** written to `NSTemporaryDirectory()` before a 401,
the same before a 421, 199 MB before the uploader's 403. The last is reachable from a
plain auto-submitting HTML form, so it needs no DNS rebinding and is not covered by the
rebinding item still deferred below. Both checks now run through a single
`-_responseForRejectedRequest` as soon as the headers are available. **`-preflightRequest:`
is therefore now called before the body exists** and its documentation says so; an
override must decide on headers alone.

**⚠️ The aggregate budget's own gzip accounting was inverted.** The decoder charged
`_totalDecoded` — everything it had ever inflated — rather than the buffer it held, and
the decoded bytes go straight to the downstream writer, which does its own accounting. So
64 KB of traffic parked 63 of the 64 MB budget indefinitely and every other connection
then failed every in-memory path. It charges the live buffer now, *before* growing it.

**Error pages were a 6x wire / 27x memory amplifier.** WebDAV echoes an unparseable
request body verbatim, and the HTML escaper expands `"` sixfold through UTF-16
`NSMutableString` passes: one 16 MB PROPFIND produced a 96 MB response and 540 MB RSS, six
concurrent reached 1.76 GB. The per-request and aggregate caps became the attacker's
budget rather than his limit. Reflected strings are clamped at the single point they pass
through. Relatedly, **PROPFIND/LOCK parsed a body of any size into a libxml2 DOM** — 16 MB
of empty elements took the process from 5 MB to 561 MB and still answered 207 — now capped
at `kDAVMaxRequestBodyLength`.

**Header framing was ambiguous.** The block is delimited by scanning for CRLFCRLF but
parsed by CFHTTPMessage, which ends a message at a bare LF-LF, so headers between the two
were silently dropped while the request still answered 200 — with `X-Pad: p\n\nHost:
evil.example`, `request.headers` came back with no Host at all and the allow-list took its
"no Host" branch. `Content-Length : 5` and a folded `Content-Length:\r\n 5` both produced
a content length, and that field decides how many bytes reach the disk. A single
validating pass now requires paired CRLF, no obs-fold, `1*tchar` field names, and a
request line of exactly `method SP target SP HTTP/1.[01]` (`GET /a HTTP/1.1 junk` was
dispatched with a path of `/a HTTP/1.1`). All eight cases answered 200 before this.
Header failures answer 431/400 instead of a blanket 500.

**Found while writing the test for the above:** `kHeadersMaxLength` was only enforced
while *waiting* for the terminator, so an oversized header block sent in one burst was
found, parsed and served. The cap now applies to the block, not the buffer — which
legitimately runs past it once body bytes arrive in the same read.

**COPY did not reject a Destination inside the source.** Nothing detected it up front:
`-[NSFileManager copyItemAtPath:]` re-entered the tree it was walking and the request was
only refused once a path exceeded `PATH_MAX`, about 250 directories down. Whether the
cleanup could then still remove that tree depends on how long the share's own path is, so
this is now a precondition check, before any filesystem work.

**Correction to the finding as first reported:** the claim that a refused COPY *always*
strands ~250 undeletable directories did not reproduce under `NSTemporaryDirectory()` —
the cleanup succeeds there. The recursion is real (verified directly against
`NSFileManager`); the residue depends on path length.

**Test-suite trap worth remembering:** once the header cap actually refused, the server
began closing the socket mid-request, and `ConnectToLocalhostPort` had no `SO_NOSIGPIPE` —
so the test process was killed by SIGPIPE and xctest reported it as *"Executed 23 tests,
with 0 failures"*. Always read the executed count, never the failure count alone.

**Serving files honestly.** Four separate ways the server asserted something untrue about
the bytes it was sending. `If-Modified-Since` was evaluated first and independently of
`If-None-Match`, so a revalidation carrying a *stale* ETag still got a 304 whenever the
replacement's mtime was not strictly newer — and per RFC 9111 §4.3.4 the client then stores
the old body under the *new* ETag, pinning the stale copy indefinitely. `If-Range` was
ignored entirely, so a resumed download spliced bytes of a changed file onto the prefix the
client already held and returned 206 asserting they belonged together (this added
`-[WSKRequest ifRange]` and an initializer taking it). `filename*` was
percent-encoded with a URL *query* escaper, which leaves `;` — the parameter delimiter — so
`evil.command;ok.txt` was delivered as `evil.command`, defeating `allowedFileExtensions` at
the point that matters. And gzip is no longer applied to a partial response, whose
`Content-Range` describes the identity coding.

**Also closed:** a trailing-dot FQDN Host now normalizes (it was answering 421 for the
server's own mDNS name); `_XMLEscape` drops control characters that are illegal in XML 1.0
at all, which a filename may legally contain and which made `LOCK` emit documents no parser
accepts; `/events` additionally checks `Sec-Fetch-Mode`/`Sec-Fetch-Site`, since
`fetch(mode:'no-cors')` may set `Accept` and could still pin all sixteen channels; the
NAT-PMP callbacks are confined to `_stateQueue` (carefully — `_DNSServiceCallBack` runs
*inside* `DNSServiceProcessResult` and must not re-dispatch, and the delegate is notified
asynchronously, or a delegate reading `publicServerURL` would deadlock); and chunked
framing and interim `100 Continue` are no longer sent to HTTP/1.0 clients, which read them
as body.

**The recorded-trace corpus builds again.** The third pass's `__WEBSERVERKIT_ENABLE_TESTING__`
change also took the definition from the `WSKWebServer (Mac)` command-line target, which
`Run-Tests.sh` builds in Release — so all eight suites had been unrunnable for three passes.
It is restored on that one example target, not at project level (verified: the framework's
Release compile line still does not carry it). Four suites now pass; the other four differ
only in expectations predating deliberate changes — `X-Content-Type-Options: nosniff`, the
`Content-Disposition` attachment header, and reworded 403 text. **Not re-recorded**, because
doing so would bless current behaviour wholesale in a pass that changed a great deal.

**Still open:** nothing from this pass's findings. The DNS-rebinding note under the fourth
pass is now addressed by the Host allow-list; what remains deferred there is unchanged.

### Fourth audit pass: containment, framing, and two regressions from the third pass

Found by changing *technique* rather than re-reading: sanitizers, a mutational fuzzer, and
auditing under deliberately different frames (hostile browser, filesystem semantics, wire
protocol). Two of the findings were defects in the third pass's own patch.

**Corrections to the third pass.** The multipart budget charged part *bodies* only, so a
part header carrying `name="<8 MB>"` was retained and charged to nothing — the OOM the
previous entry claims to close was still open (802 MB RSS, never rejected). Part header
blocks are now capped at `kMultiPartMaxHeadersLength`. Separately, the header-parameter
rewrite made unquoted values terminate at `,`, but RFC 2046 allows a comma in a multipart
boundary, so `boundary=ab,cd` truncated to `ab` and broke every upload from such a client;
`,` now delimits only *before* a parameter name. Both have regression tests covering the
exact case the original tests missed.

**`addGETHandlerForBasePath:` had no containment check** (`WSKWebServer.m`) — the only
file-serving path in the library without one. Textual `..` stripping is not containment:
`lstat` and `O_NOFOLLOW` refuse a symlink solely as the *final* component, so any symlinked
directory under the served root served whatever it pointed at. Verified by removing the new
guard and watching a file outside the root come back. Covered by
`testBasePathHandlerRefusesSymlinkEscape`.

**WebDAV never got the hidden-item fix.** The third pass added `-_isHiddenPath:` to
`WSKWebUploader` and this file recorded the bug class as fixed; WebDAV's nine sites still
tested `lastPathComponent`, so `GET /.git/config` returned contents and `PUT /.git/hooks`
wrote. WebDAV now walks every component too.

**WebDAV `PUT` destroyed the target file on unrecognised framing.** `performPUT:` unlinked
the destination *before* the replacement existed, and `Transfer-Encoding` was matched by
exact string equality — so `gzip, chunked` and `chunked;a=b`, both RFC-legal, were read as
"no body", the move failed, and the file was already gone. Transfer-Encoding is now parsed
properly (list split, parameters stripped, chunked must be the sole coding; anything we
cannot frame or decode is refused rather than silently treated as empty), and PUT/COPY/MOVE
build the replacement under a staging name and swap it in with `rename(2)`.

**Digest nonce integrity tags were forgeable.** `WSKComputeMD5Digest` hashed via
`-UTF8String`+`strlen`, so an embedded NUL — which survives from the wire into
`request.headers` — ended the hashed input before the per-process secret. Not an auth bypass
(the response digest still needs HA1) but it defeated the "we minted this nonce" property.
Both the digest helper and the constant-time credential comparison now work over full bytes.

**`WSKFileResponse` stat'd and opened as two separate path walks**, so a file
replaced between them was served with the previous file's `Content-Length` and ETag — a
truncated body that looks complete and gets cached under a stale validator. It now opens
once with `O_NOFOLLOW` and derives everything from `fstat` on that descriptor.

Also: WebDAV `Destination` was parsed by substring-searching the `Host` *value* (with
`Host: x`, `Destination: /moved.txt` silently landed the file at `<share>/t`) and is now
parsed as a URI; `/delete`'s subtree vetting races `/move` and now holds the file-operation
lock; `/events` requires `Accept: text/event-stream` so a cross-origin `<img>` cannot pin
all 16 SSE channels; the uploader page sets `X-Frame-Options`/`frame-ancestors`/`nosniff`;
the podspec's globs matched **zero files** (CocoaPods users got an empty pod); `_reload(null)`
permanently wedged the web UI; renaming mangled filenames containing `&`; `Range` and
chunk-size lines are parsed strictly (`strtol` accepted `" 5"`, `"+5"`, `"0x5"`, and `"-0"`
as a terminator); and the example apps no longer disable `allowHiddenItems`.

**Two regressions from the third pass, also fixed:** `-startWithOptions:` began touching
`UIApplication` off the main thread once the lifecycle funnel landed (the state is now
sampled on the caller's thread), and the idle-timeout floor was an absolute 1024 bytes/tick
rather than a rate, which disconnected slow-but-genuine uploads at short timeouts — it is
now `kMinReceiveBytesPerSecond` scaled by the tick length.

**Negative results worth keeping.** ThreadSanitizer reports 4 data races in `-_stop` against
the per-connection config snapshot; these are **false positives** — a 200-trial experiment
(198 genuinely overlapping) confirms libdispatch orders a source's cancel handler after its
in-flight event handler, an edge TSan does not model. Do not "fix" them. Separately, ~7,000
mutated requests under ASan+UBSan produced zero memory errors, and request smuggling is
structurally impossible (one request per connection, `Connection: Close`, leftover bytes
never read) — verified live by pipelining.

### Aggregate in-memory budget

Every in-memory limit was per-request, and per-request limits do not compose: with
`kWSKMaxConnections` concurrent requests the real ceiling was their product — about
2 GB of chunked framing buffers, or 8 GB of inflated gzip output — many times what a phone
survives. This was the same bug class fixed twice already (multipart bodies, then multipart
part-headers); rather than wait for a third instance, the general case is now closed.

`kWSKMaxTotalInMemoryLength` (64 MB) bounds the sum across all live connections.
Every place that holds request data in memory takes a `WSKMemoryReservation` and
resizes it as its buffer grows: data-request bodies, inflated gzip output, multipart argument
parts, each multipart parser's working buffer, and the chunked framing buffer. Per-request
limits still apply on top.

The reservation is deliberately an **object**: the bytes are returned in `-dealloc`, so a
connection that dies mid-body — dropped, reset, timed out — cannot leak budget and
permanently shrink what the server can serve afterwards. Reservations that rise and fall
(working buffers) shrink again as the parser drains them; a reservation that only grows
(retained multipart arguments) is charged once against the shared budget object. Verified
under load: 24 concurrent chunked bodies peaked at exactly the ceiling and never above it,
and the reserved total returned to zero once they finished.

`WSKSetMemoryLimitsForTesting` shrinks the limits so a bound can be proven without
moving tens of megabytes. That fixed the long-standing flake in
`testChunkedTransferRejectsUnterminatedSizeLine`, which used to push 16 MB through the server
and lose the test runner in roughly half of full-suite runs; it now proves the same property
against a 64 KB bound. Ten consecutive full-suite runs pass. Consult
`WSKMaxInMemoryBodyLength()` / `WSKMaxDecompressedBodyLength()` rather than
the `kWSK...` constants, so the overrides are honoured.

Known imprecision: exhausting the budget surfaces as a 500, because the body-writer protocol
reports failure as a plain BOOL and the connection maps any body-write failure to 500. A 503
would be more honest; threading a status through that protocol was judged not worth
destabilising the body-read path for.

### Host validation (DNS rebinding)

Every request's `Host` is checked against an allow-list in
`-[WSKConnection _rejectIfHostNotAllowed]`; anything else gets 421. Accepted with
no configuration: any IP address literal, `localhost`, this machine's own host name, and the
Bonjour name being advertised. `WSKOption_AllowedHostNames` adds more, and an entry
may pin its own port.

**Why nothing else would do.** Once a page on `evil.example` repoints its DNS here, the
browser considers itself same-origin: CORS permits the read, an `Origin` comparison passes,
and a CSRF token can simply be fetched from the page and replayed. The only thing that still
differs is the *name* the browser sends in `Host` — and an attacker cannot make a browser put
a raw IP literal there while scripting from a domain. That asymmetry is the entire defence,
which is why IP literals are accepted by *shape* rather than by matching our own addresses.
Do not "improve" this by resolving the Host and comparing against local interfaces: the
attacker controls that DNS, so it resolves to us and the check evaporates.

This also repairs rather than duplicates the uploader's CSRF check. That check compares
`Origin` against `Host`, which was sound logic over an untrusted input; now that `Host` is
validated first, the comparison means something again.

It lives in the connection layer, ahead of `-preflightRequest:` (a subclassing point that
must not be able to switch it off), so WebDAV and host-app handlers inherit it — WebDAV has
no origin check of its own and would otherwise be the most exposed surface.

A request with no `Host` at all is allowed: HTTP/1.0 and many native clients omit it, and
rebinding requires a browser, which never does. Rejections log the offending name, the path,
the peer and the full accepted set, deliberately loudly — this is the check most likely to
surprise a deployment nobody anticipated, and a quiet refusal would present as "the server
just doesn't work". Covered by `testHostValidationRefusesRebindingButAllowsRealNames`,
`testHostValidationCoversWebDAV` and `testHostValidationHonoursConfiguredNames`.

### Third audit pass: remote DoS, lifecycle, and parsing fixes

**Multipart argument accumulation (remote OOM).** `kWSKMaxInMemoryBodyLength`
bounded only the parser's *working buffer*; every completed non-file part was retained
in `_arguments` for the life of the request with no aggregate limit, so a body of many
individually-legal parts grew without bound (200 MB of parts took the process to 626 MB
before rejecting nothing). `WSKMIMEStreamParser` now carries a
`WSKMIMEStreamBudget` — shared with every sub-parser, since nested
`multipart/mixed` appends into the same arrays — capping total retained argument bytes at
`kWSKMaxInMemoryBodyLength` and total parts at `kMultiPartMaxParts` (1024, which
also bounds temp-file/inode use by file parts). Covered by
`testMultiPartRejectsUnboundedArgumentAccumulation`.

**Slow request body held a connection slot forever.** The idle timer's hard deadline
(`kMaxHeaderPhaseTicks`) applied only while `_request` was nil, and the remaining
zero-progress rule counts *any* byte as progress — so a client dribbling one byte per tick
pinned a slot indefinitely, and 128 of them denied service to the whole server (verified:
a connection survived 15 consecutive idle periods on 30 bytes). While the request body is
still arriving the server now requires `kMinReceiveBytesPerTick` (1024) between ticks; the
response phase keeps the laxer rule so a slow-but-live SSE reader is never cut off, and
time inside a handler still never counts. Covered by
`testConnectionIdleTimeoutClosesDribblingBodyClient`, with
`testConnectionIdleTimeoutSparesSlowHandler` guarding the regression.

**Unbounded SSE streams exhausted the connection pool.** `/events` registered unlimited
channels, each pinning a connection that the 15s heartbeats kept alive forever; 128
concurrent `GET /events` permanently denied service. Capped at `kMaxSSEChannels` (16),
over-limit channels are `close`d so the connection ends cleanly and `EventSource` retries.

**`__WEBSERVERKIT_ENABLE_TESTING__` shipped in Release.**
`GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS` was set at project level in *both*
configurations, and that setting is excluded only from PCH generation — the `-D` was on
the Release compile line. That shipped client-settable file timestamps
(`X-WSKWebServer-CreationDate`/`-ModifiedDate` on PUT and MKCOL), a client-chosen
`X-WSKWebServer-LockToken`, and the request/response recording machinery. Now Debug-only.
The LOCK token is also `_XMLEscape`d, which it alone among the LOCK response values was not.

**Hidden items were protected only at the leaf.** Every `allowHiddenItems` check used
`lastPathComponent`, so a hidden *directory* was refused while `/list`, `/download`,
`/delete`, `/upload` and `/move` all reached inside one (`/.git/config`). `-_isHiddenPath:`
now tests every component of the normalized path.

**Malformed input aborted Debug builds.** `WSK_DNOT_REACHED()` is `abort()` under `#if
DEBUG`, and several call sites sat on ordinary remote-input paths: `GET /%FF` (undecodable
percent-escapes → nil path, now 400 rather than 500), `?a=%FF` in a query string, a
multipart part header without a colon or without `name=`, a `Content-Length` alongside a
chunked `Transfer-Encoding`, and a file vanishing mid directory-listing. These now log and
fail the request. Genuine host-app API-misuse assertions were deliberately left alone.

**Header parameters matched on substrings.** `WSKExtractHeaderValueParameter`
used `scanUpToString:`, which finds `name=` inside `filename=` and `nonce=` inside
`cnonce=` — so a client chose which value the server read just by reordering parameters,
and Digest auth was unusable for any RFC 2617 client sending `cnonce` before `nonce`
(permanent 401 loop). It now requires a token boundary. This is not an auth bypass: the
same extracted `uri` feeds both the path-binding check and HA2, so the digest stays
self-consistent. Covered by `testHeaderValueParameterMatchesOnlyAtTokenBoundary`.

**Server lifecycle was unsynchronized.** `_start`/`_stop` mutated the dispatch sources and
Bonjour refs with no confinement while the iOS foreground/background handlers called the
same paths on the main thread; concurrent `stop`s double-released a source, and an
orphaned source left `_sourceGroup` permanently entered so every later `_stop` hung. All
lifecycle mutation and the `isRunning`/`serverURL` accessors now funnel through a serial
`_stateQueue`. Deadlock-free by construction: nothing on `_stateQueue` blocks on the main
queue, the accept handler touches only `_syncQueue`, and the cancel handlers that
`dispatch_group_wait` waits on run on a global queue doing only `close()` + `leave`.

**gzip on an async-only response sent an empty body.** `WSKGZipEncoder` pulled its
source through the synchronous `readData:` only, so any `WSKStreamedResponse` with
`gzipContentEncodingEnabled` produced a valid gzip stream of zero bytes and never ran its
stream block. `WSKBodyEncoder` now implements `asyncReadDataWithCompletion:`.
This path had no test coverage at all; `testGZipEncoded{Data,Streamed}ResponseRoundTrips`
now assert a full round-trip through both reader kinds.

Also: `Content-Length` is parsed strictly (digits only, no overflow) instead of via
`-integerValue`, which accepted `"5abc"` and clamped overflow to `NSIntegerMax`; the
connection no longer `close()`s its socket in both `-initWithServer:` and `-dealloc` (a
double close that could kill a recycled descriptor); `setValue:forAdditionalHeader:`
rejects header *names* containing CR/LF/colon (CFHTTPMessage sanitizes values but not
names); unsatisfiable Ranges return 416 with `Content-Range: bytes */N` instead of 500/404;
and `WSKStreamedResponse` releases its block on `-close` to break handler retain
cycles.

### WebDAV MOVE/COPY safety (self-move data loss)

`performCOPY:isMove:` previously did an unconditional `removeItemAtPath:dst` before
the move. A MOVE whose destination resolved to the source — an exact self-move, or a
case-only rename on a case-insensitive volume (`File.txt`→`file.txt`, same inode) —
with `Overwrite: T` therefore deleted the only copy of the file. COPY onto an existing
destination also always failed (it never removed the existing item). Now it rejects a
self-move/self-copy with 403 (same-file detection via `NSURLFileResourceIdentifierKey`,
so case-variants are caught) before any destructive step, checks the remove error
instead of ignoring it, and removes an overwrite-permitted destination before COPY.
A case-only rename is now rejected (safe) rather than performed. Covered by
`testDAVMoveOntoItselfPreservesFile`, `testDAVCopyOverExistingReplacesContent`,
`testDAVMoveOverExistingReplacesContent`.

### Error-page HTML escaping (reflected XSS fix)

`WSKErrorResponse`'s `_EscapeHTMLString` escaped only `"`, so
request-controlled text reflected into the `text/html` error body (e.g.
`"<path>" does not exist`) passed `<`/`>`/`&` through unescaped — a reflected XSS
in the server's own origin, which via the uploader/DAV can list, move, and delete
files. It now escapes `& < > " '` (with `&` first), matching the directory-listing
escaper in `WSKWebServer.m`. Covered by `testErrorResponseEscapesReflectedMarkup`.

### Per-connection config snapshot (auth/serverName race fix)

Each `WSKConnection` now **snapshots** the server's mutable configuration —
`serverName`, the authentication realm and account dictionaries, and the
HEAD→GET mapping flag — into its own ivars in `initWithServer:`, and reads those
copies for its whole life instead of `_server.*`.

Previously connections read those `nonatomic` ivars directly off the shared server
while `-_stop` niled them (and `-_start` rebuilt them) on the main thread — which
happens on *every* foreground transition in non-suspend mode via
`-_reconnectInForeground:`. A request in flight during that window raced a
nonatomic object-pointer write (use-after-free) and could briefly observe nil auth
accounts, bypassing authentication. The snapshot is race-free because the accept
handler only runs while the listening socket is live — i.e. after `-_start`
populates the config and before `-_stop`'s socket-cancel/`dispatch_group_wait`
barrier tears it down — so the capture always sees a stable, valid config. It also
matches the intended semantics (an already-accepted connection keeps serving with
the config it started with). Regression-tested by `testBasicAuthEnforcedOverConnection`;
the race itself is timing-dependent and verified by construction + build.

### Request hardening: in-memory body caps

Bounds a malicious/broken client's ability to exhaust memory on a transient
device. (Connection slot exhaustion by silent clients is handled separately —
see "Connection Idle Timeout" below.)

**In-memory body caps** (`kWSKMaxInMemoryBodyLength` = 16 MB,
`kWSKMaxDecompressedBodyLength` = 64 MB, in `WSKPrivate.h`).
Fixed safety constants like `kHeadersMaxLength`, not options. They cap only data
held **in memory**; bodies streamed to disk (uploaded files, WebDAV `PUT`) are not
limited, so large uploads keep working. Enforced at four points:
- `WSKDataRequest` body (DAV PROPFIND/LOCK/MKCOL, forms, data requests)
- `WSKGZipDecoder` total inflated output — bails inside the inflate loop, so a zip bomb can't balloon the buffer first
- multipart parser working buffer (`appendBytes:`) — also resolves a stall where content containing the boundary token without a trailing CRLF wedged the parser and grew the buffer without bound
- a single chunked-transfer chunk (`readNextBodyChunk:`)

A body read that fails (client disconnect mid-body, malformed framing, or a cap
rejection) now aborts the request instead of processing a partial body as if
complete (`_readBodyWithLength:` / `_readChunkedBodyWithInitialData:`).

Covered by unit tests in `Framework/Tests.m` (`testDataRequest*`, `testGZip*`,
`testMultiPart*`); the chunk/partial-body paths are verified by build and review
(they need socket-level integration to unit-test).

### Server-Sent Events (SSE) for WSKWebUploader

Added live browser updates when files change on the device.

**Files modified:**
- `Sources/WebServerKitUploader/WSKWebUploader.h` - Added `serverSentEventsEnabled` property
- `Sources/WebServerKitUploader/WSKWebUploader.m` - SSE infrastructure implementation
- `Sources/WebServerKitUploader/WSKWebUploaderSSEChannel.h` - Per-connection SSE buffer (state machine)
- `Sources/WebServerKitUploader/WSKWebUploader.bundle/Contents/Resources/js/index.js` - EventSource client

**Reliability model (per-connection buffering):**
WSKWebServer's async streaming API is a strict ping-pong — it hands the response
one completion block ("reader"), waits for it to be called once with a chunk,
writes it, then asks for the next. Between those calls the connection has no
reader waiting. The original shared-array-of-blocks approach dropped any event
broadcast in that window (bursts collapsed to a single delivered event). Each
connection now owns a `WSKWebUploaderSSEChannel` that buffers events in FIFO
order (bounded, oldest dropped) until a reader parks, so no event is lost.
Dead connections are reaped on the heartbeat tick (no parked reader + buffered
data ⇒ gone). Covered by unit tests in `Framework/Tests.m` (`testSSEChannel*`).

**Channel close semantics:** whenever the uploader stops servicing a channel
(heartbeat reap, `-stop`, disabling SSE, or losing the registration race) it
must call `-[WSKWebUploaderSSEChannel close]`, which completes any parked
reader with empty data — WSKWebServer's end-of-stream sentinel — and makes
future `parkReader:` calls complete immediately the same way. Merely dropping
the channel from `_sseChannels` strands the connection parked forever and leaks
it (retain cycle: connection → response → stream block → channel → parked
reader → connection), which also keeps `_activeConnections` from ever reaching
zero. Covered by `testSSEChannelClose*` and `testStopClosesActiveSSEConnections`.

**`serverSentEventsEnabled`:** defaults to `YES`. The `NSFilePresenter`
registration (which participates in system-wide file coordination) is only
installed while enabled; toggling the property adds/removes it.

**External-change paths** are compared after resolving symlinks on both sides
(`URLByResolvingSymlinksInPath`) so `/private/var` vs `/var` mismatches don't
cause every change to be reported as the root directory.

**Features:**
- `/events` endpoint streaming SSE with content-type `text/event-stream`
- Heartbeat comments every 15 seconds to keep connections alive
- Broadcasts change events for: upload, delete, move, create operations
- File system observation using `NSFilePresenter` for external changes (Files app, etc.)
  - Monitors subdirectories recursively via `presentedSubitemDidChangeAtURL:`
  - Coalesces rapid changes with 100ms timer to avoid flooding
  - Sends specific directory paths so browser only reloads when current folder is affected
- JavaScript EventSource with auto-reconnect on connection errors

**Event format:**
```
event: change
data: {"type":"upload","path":"/file.txt"}

event: change
data: {"type":"delete","path":"/file.txt"}

event: change
data: {"type":"move","oldPath":"/a.txt","newPath":"/b.txt"}

event: change
data: {"type":"create","path":"/NewFolder/"}

event: change
data: {"type":"external","path":"/Documents/"}
```

**Smart reloading:** The browser only reloads when the changed directory matches the currently viewed path.

### Connection Idle Timeout

`WSKOption_ConnectionIdleTimeout` (NSNumber / double, default 30.0
seconds, 0 disables): a connection whose pending socket read/write moves no
bytes in either direction across two consecutive timer ticks is shut down
(`shutdown(2)`, so the pending I/O unwinds through the normal error paths and
the fd is closed in dealloc). The timeout only counts while socket I/O is
actually pending — time spent waiting on a request handler never counts, so
slow handlers are unaffected, and idle SSE streams are kept alive by the 15s
heartbeats. This prevents silent clients from holding connection slots forever
(with the 128-connection cap, 128 idle sockets previously meant a permanent
denial of service). Covered by `testConnectionIdleTimeout*` in
`Framework/Tests.m`.

### Framework Linking

System frameworks are linked via `OTHER_LDFLAGS` in project build settings:
- Foundation, CoreServices (weak), SystemConfiguration, CFNetwork, libxml2, libz
- UIKit is conditionally linked only for iOS/tvOS SDKs

### iOS Files App Integration

`Examples/iOS/Info.plist` includes:
- `UIFileSharingEnabled` - Makes Documents visible in iTunes/Finder
- `LSSupportsOpeningDocumentsInPlace` - Makes app appear in Files app

### Background Mode

`Examples/iOS/ViewController.swift` starts the server with:
- `WSKOption_AutomaticallySuspendInBackground: false`
- This gives ~30 seconds of background execution time before iOS suspends the app
