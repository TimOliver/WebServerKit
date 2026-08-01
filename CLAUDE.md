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

### Cleanup phase 3, group C: the public surface goes 27 → 7, and both reasons it could not were stale

The last structural item. Fourteen audit-shaped functions — the resolvers, the vetting walks, the
allow-list predicates, the validators, same-file detection — leave the public `WSKFunctions.h` for
`WSKPrivate.h`. **The public function surface is now 7 declarations, down from 27**, and what remains
is exactly the general-purpose utilities: URL escaping, MIME type, primary IP, the HTTP date
format/parse pair, form parsing, the NUL check, and the filesystem-error status mapping.

These were public for one stated reason: the SPM sibling targets could not see `WSKPrivate.h`. The
manifest gave two justifications for why that could not change. **Both were measured and neither
reproduced.**

| manifest claim | measured |
|---|---|
| `WSKPrivate.h` in the symlink farm makes the module unbuildable by a Swift consumer — "the umbrella would drag in the private header, which imports a dozen others it cannot find" | builds clean, 4.7 s forced rebuild |
| a sibling reaching `Core/` by a second search path hits clang's "duplicate interface definition" | builds clean, 5.2 s, with a sibling importing `WSKPrivate.h` |

Both may well have been true when written — `#if __has_include` arms and toolchains have moved. The
point is that neither constrains the layout now, and the change collapsed from "restructure the
package" to **one extra `headerSearchPath`**. No new header, no modulemap change, no pbxproj change.
The symlink farm, hand-written modulemap and `SWIFT_PACKAGE` bundle accessor are all untouched.

**⚠️ The oracle had to be built first, and proving it sensitive took two attempts.** `swift build`
inside this package cannot catch a module that is unbuildable from *outside* it, because every header
is reachable there — so the check is an **external SwiftPM consumer** that depends on the package by
path and imports all three modules from Swift. The first sensitivity attempt was worthless twice
over: a `cd` moved the cleanup out of the repo (leaving a stray symlink behind, caught by
`git status`), and the build it measured completed in 0.15 s because it was cached. The real check —
removing a symlink the consumer genuinely needs — produces
`fatal error: 'WSKWebServer.h' file not found`, which is what makes the green results above worth
anything.

**Why this matters beyond tidiness.** Every one of the fourteen changed contract during the audit
programme: `WSKServableFileTypeAtPath` gained two parameters, the resolvers were merged from four
copies, the allow-list predicate learned a second name. Each of those was a silent source break for
anyone who had bound to them, published as public API by accident of the build graph.

**Verified together.** 142 tests and 0 failures on a clean build with no warnings, the external SPM
consumer building and linking against all three modules, `swift build`, the trace corpus, and iOS and
tvOS Debug all clean.

**The structural cleanup is complete.** What remains is phase 2's low-value tail (the URI-to-path
derivation, the limits and constants) and consolidating this file, which is past 2,000 lines.

### Cleanup phase 3, group B: the header-field and host-name rules go private

Three more off the public surface — `WSKIsHeaderTokenCharacter`, `WSKIsHeaderTokenString` and
`WSKHostNameWithoutRootLabel`. None has a caller outside the core target and none has a plausible
host-app use: they exist because the request parser and the response serializer BOTH have to spell
the same rule, which is why they were shared at all. Being shared between two files inside one
target never required being public.

The public `WSKFunctions.h` is now **21 declarations, down from 27**.

**⚠️ One of the four approved for this batch was deliberately held back.** `WSKResolveWithinDirectory`
was in the plan, and moving it would have left **three public doc comments naming a private symbol** —
including the `@warning` on `WSKPathIsInsideDirectory` that the previous change had just rewritten to
point at it as the resolve-once alternative. `WSKPathIsInsideDirectory` is used by both sibling
targets, so it stays public until group C. Moving the resolver first would either strand those
references or strip the only useful pointer out of a public warning, so it moves **with the rest of
the resolver cluster** instead. Recorded because "do the approved thing" and "leave the docs
coherent" genuinely conflicted here, and the smaller batch is the one that keeps both true.

**Verified together.** 142 tests and 0 failures on a clean build with no new warnings, `swift build`
clean, the trace corpus green, iOS and tvOS Debug clean.

**Group C remains** — eleven functions the sibling targets genuinely use, which need the SPM target
restructure so those targets can see `WSKPrivate.h`. That is the breaking change, and the last
structural item.

### Cleanup phase 3, group A: three security-shaped functions leave the public header

The public `WSKFunctions.h` had grown to **27 declarations**, and the memory note carried the reason
as "ten are public solely because the SPM sibling targets cannot see `WSKPrivate.h`". Measuring the
actual usage split it three ways instead, which makes the work tractable in pieces rather than as
one breaking change:

- **eleven the siblings genuinely use** — the resolvers, the vetting walk, the allow-list predicates,
  same-file detection. These are the ones that need the target-visibility change, and they are still
  public.
- **seven core-only utilities** — MIME type, URL escaping, primary IP, the header-token predicates,
  the root-label helper. No build-graph work needed; some are plausibly legitimate public API, so
  they are a judgement call rather than an obvious removal.
- **three used nowhere outside `WSKFunctions.m`** — `WSKResolvedPathIsWithinDirectory`,
  `WSKResolvedPathRelativeToDirectory`, `WSKResolvedPathHasHiddenComponent`. **This change.**

**⚠️ A claim of mine was wrong and it would have changed the fix.** I first reported these three as
having "zero callers anywhere", from a grep that excluded `WSKFunctions.m` — where all of them are in
fact called. The honest statement is "no caller *outside* that file", which makes them internal
helpers exposed publicly, not dead code. Delete was never the right answer; relocating is.

**And `static` was not the right answer either**, for a reason only a full-repo grep surfaces:
`WSKResolvedPathIsWithinDirectory` has **eleven assertions in `Framework/Tests.m`**, which test the
containment predicate directly and are worth keeping. So all three move to `WSKPrivate.h`, which
`Tests.m` already imports — off the public surface, still linkable by the suite.

**Two documentation defects went with them.** The doc block describing
`WSKResolvedPathRelativeToDirectory` was stranded above a *different* declaration (its own had none),
which the inventory flagged as "a future editor fixes the wrong function to match the wrong comment".
And `WSKPathIsInsideDirectory`'s `@warning` told callers to "pair it with
WSKResolvedPathIsWithinDirectory() before acting on a path that came from a client" — the library's
own documentation recommending the **two-observation pattern** that `WSKResolveWithinDirectory()`
exists to replace, and that was measured serving content from outside the root in 24% of requests. It
now points at the resolve-once function.

**Verified together.** 142 tests and 0 failures on a clean build with no new warnings — including the
eleven assertions that `static` would have broken — plus `swift build` clean (the sibling targets
resolve headers through the symlink farm, so SPM is the check that matters for a header move), the
trace corpus green, and iOS and tvOS Debug clean.

**Groups B and C remain**, and C is the one carrying the target-visibility decision.

### The existence oracle closed at its real cause, and the fallback it lives in proved intact

The oracle the fifteenth-pass inventory blamed on stat-before-resolve, and which reordering those
endpoints did NOT close. The real cause is `_RealPath`: when `realpath(3)` fails it resolves the
PARENT and appends the raw leaf — the branch that lets a `PUT` or `MKCOL` to a not-yet-existing name
resolve at all. **A dangling symlink also fails `realpath`**, so it took the same branch and resolved
to a location *inside* the share, which made the answer depend on whether the link's target existed:

    GET escaping link, target EXISTS : 403
    GET escaping link, target ABSENT : 404

An entry that exists and cannot be resolved now fails closed. Both spellings answer 403.

**⚠️ The important half of this change is what it does NOT break.** The fallback is load-bearing —
without it every `PUT` and `MKCOL` of a new name fails — so the probe measured six operations that
must survive alongside the two that must change, and the regression test asserts all of them. A
guard justified by one failure mode has to be checked against everything it then refuses; that rule
was written here after two self-inflicted over-refusals, and this is the first change made under it
deliberately.

| | before | after |
|---|---|---|
| escaping link, target exists | 403 | 403 |
| escaping link, target absent | **404** | **403** |
| PUT to a brand-new path | 201 | 201 |
| PUT to a new path in a subfolder | 201 | 201 |
| MKCOL a brand-new collection | 201 | 201 |
| PUT over an existing file | 204 | 204 |
| GET an ordinary file | 200 | 200 |
| MOVE to a brand-new name | 201 | 201 |
| dangling link inside the share | 404 | 403 |
| symlink loop | 404 | 403 |

The last two are the only other behaviour change, and neither was ever served — a `PUT` through a
dangling link already answered 500, so no working operation is lost and only the status moves, in
the honest direction.

**Verified together.** 142 tests and 0 failures on a clean build with no new warnings, the trace
corpus green, iOS and tvOS Debug clean.

### Cleanup phase 2, continued: the four-times-recurring walk gets one home

**The recursive-destroy vetting walk was two implementations, comments and all.** DAV's
`-_firstUnvettableItemAtPath:isDirectory:` and an inline walk in the uploader's `deleteItem:` — and
the DAV comment openly said it "mirrors `-[WSKWebUploader deleteItem:]`", a self-documented second
copy of a security rule. Four separate audit lenses reported it independently, which is itself worth
noting: nothing else in the inventory drew that much agreement.

This is **the class that has recurred four times** (eighth, tenth, thirteenth and fifteenth passes):
a recursive DELETE or an overwrite destroying files that a direct request refuses, most recently
measured at 60/60. It is now `WSKFirstUnvettableItemAtPath`, called by both. **Both copies were
wrong simultaneously the last time** — the `-skipDescendants` handling — which is the sharpest
possible argument for one home: the fifteenth pass had to find and fix the identical bug twice.

Both judgement calls move with it and are documented at the shared site: dot-names and their
descendants are skipped whatever `allowHiddenItems` says (a `.DS_Store` sits in every macOS folder
and its empty `pathExtension` is in no allow-list, so vetting them would make ordinary directories
permanently undeletable), and an extensionless file IS vetted, because a direct DELETE of it is
already refused.

**Same-file detection is shared too** — `WSKPathsNameTheSameFile`, verified byte-identical in both
servers first. It is the whole of the protection against a self-move deleting the only copy of a
file, including the case-variant pair that is one file on a case-insensitive volume.

**An inventory finding that resolved itself.** The survey flagged `WSKResolvedPathHasHiddenComponent`
as a DEAD helper sitting beside eleven live inline spellings of the same rule — exactly the trap this
file names ("an unused second implementation of a security rule sitting beside the live one is a trap
for whoever needs that check next"). It is no longer dead: phase 1's fix to
`WSKServableFileTypeAtPath` gave it its first caller. Recorded because the survey ran one commit
earlier, which is a reminder that an inventory ages like any other finding.

**Verified together.** 141 tests and 0 failures on a clean build with no new warnings, the trace
corpus green, iOS and tvOS Debug clean. 94 lines left the two servers.

### Cleanup phase 2: the four resolver copies are one, and an oracle whose cause was not what the survey said

**The largest duplication in the library is gone.** `-_namedEntryPathForRelativePath:hidden:` and
`-_resolvedPathForRelativePath:hidden:` existed once per server — four near-verbatim methods, ~100
lines each side — and these are the methods every path-taking verb passes through. **Five of this
project's historical defects lived in exactly these copies**: the NUL guard, the hidden-item rule,
recursive-delete vetting, `If-Range` and the overwrite vetting were each closed in one server and
left open in another.

**They were verified line-for-line identical before being merged**, with comments and blank lines
stripped and the two servers diffed — the last difference, the uploader's missing NUL guard, was
closed in phase 1. So this move *cannot* change behaviour; what it removes is the possibility of the
next divergence. 198 lines left the two servers; each keeps a three-line wrapper so every call site
still binds the result to the variable it already used, which makes "I missed one" structurally
impossible.

**The uploader's two read endpoints now resolve before they stat.** `/list` and `/download` answered
404-vs-403 from a path that had not been vetted, while DAV has enforced and documented the opposite
ordering since the eighth pass — and `-deleteItem:` in the *same file* already got it right, so the
rule disagreed with itself inside one server.

**⚠️ That did NOT close the existence oracle, and the survey's stated cause was wrong.** Measured
after the reorder: `/list` improved from 400 to 403 and now agrees with `/download`, but the
exists-vs-absent difference survives — 403 when an escaping symlink's target exists, 404 when it does
not. The real cause is `_RealPath`: when `realpath(3)` fails it falls back to resolving the PARENT
and appending the raw leaf, which is required so a `PUT` to a not-yet-existing path resolves at all.
A **dangling** link also fails `realpath`, so it takes that same branch and resolves to a path
*inside* the share. Recorded as still open rather than patched, because the fix changes the most
security-critical function in the library and needs its own measured pass.

**One hypothesis raised and killed rather than written up.** If a dangling link resolves to a path
inside the share, does a `PUT` through it escape? Measured: no — refused, the link survives, nothing
lands outside; the stage-and-swap machinery holds. Worth recording as a negative result, because the
reasoning that produced it was sound and the answer was still no.

**Verified together.** 141 tests and 0 failures on a clean build with no new warnings, the trace
corpus green, iOS and tvOS Debug clean, and the probe re-run in full — A, B and D all "not
reproduced", C improved but honestly still confirmed.

**Phase 2 continues** with the remaining ~45 inventoried rules.

### Cleanup phase 2, first rule: the extension allow-list now judges BOTH names a symlink presents

**A decided semantics question, not a defect fix**, and the first of the 48 duplicated-but-agreeing
rules the phase 1 survey inventoried — except this pair did not agree. A symlink presents two names:
the one the client used and the one the bytes live under. Listings vetted the alias; access vetted
the resolved target. Measured with `allowedFileExtensions = ["txt"]`:

    alias.txt -> real.bin    listed YES,  GET 403
    alias.bin -> real.txt    listed no,   GET 200

**The ruling is that both must pass**, which is the fail-closed reading. The alternatives were put
side by side and rejected on their measured consequences: judging the **alias alone** is the most
faithful reading of the "symlinks are aliases" semantics, but a *read* through an alias hands over
the target's bytes, so `alias.txt -> id_rsa` becomes servable and the allow-list stops being a
control for reads at all. Judging the **target alone** is safe for reads but contradicts the
destructive-verb semantics already chosen, where a verb acts on the entry the client named.

The accepted cost, recorded because it will be noticed: a link named `.txt` pointing at a file whose
own extension is not allow-listed stops being servable. Both refusals and the case that must keep
working are pinned by one test that asserts, for five entries, that **the listing and the handler
never disagree** — which is the property, rather than any particular verdict.

**The rule has one home**, `WSKEntryPassesExtensionAllowList`, and both servers' `-_checkFileExtension:`
now delegate to `WSKNamePassesExtensionAllowList` rather than each spelling `containsObject:` over a
lowercased `pathExtension`.

**⚠️ The resolved name is derived from the resolution the listing ALREADY performed.** A caller that
resolved a second time to learn the target's name would be making two observations of a filesystem
that need not agree — the class the eighth pass closed and this file names as the general form that
will recur. `WSKServableFileTypeAtPath` therefore hands the resolved leaf back through an out-param
instead, and the base-path index (which has no allow-list) passes NULL.

**Verified together.** 141 tests and 0 failures on a clean build with no new warnings, the trace
corpus green, iOS and tvOS Debug clean, and the probe sensitive in both directions.

**Phase 2 continues** with the remaining 47 rules, which unlike this one already agree — so a
mistake there surfaces as a test failure rather than a behaviour change. The uploader's read
endpoints stat before resolving (an existence oracle for paths outside the share) is carried into it
as part of the resolver unification.

### Structural cleanup, phase 1: the survey found live bugs before it moved a line of code

The cleanup deferred since the fourteenth pass began, deliberately, with a **read-only inventory**:
seven lenses over every rule implemented in more than one place. That ordering was the whole point —
a mechanical sweep is exactly when a check quietly stops being enforced, and unifying two copies
before knowing which one is *correct* cements whichever spelling was read first.

**72 rules inventoried; 23 of them already disagree.** Those are not cleanup, they are latent
defects, and four were measured from the network before anything was touched. All four reproduced.

**A root-dotted `WSKOption_AllowedHostNames` entry admitted NOTHING — not even its own spelling.**
The two sides of the allow-list had drifted: the check side strips the DNS root label from the
incoming `Host`, the config side only lowercased the entry. So `puck.tailnet.ts.net.` — how DNS
canonically writes a fully-qualified name — matched neither `puck.tailnet.ts.net.` (stripped on
arrival) nor `puck.tailnet.ts.net`, and **every request answered 421**. That is the one option a
Tailscale deployment is *required* to set, so it presents as "the server just doesn't work" in
Shape A's only deployment. Measured 421/421 before, 200/200 after. The rule now has one home,
`WSKHostNameWithoutRootLabel`, used by both sides.

**All three listings advertised entries every handler refuses.** `WSKServableFileTypeAtPath` tested
containment and never hiddenness, so a link whose own name carries no dot but which resolves inside
a dot-directory was listed and then answered 403. Measured: listed YES, `GET` 403. This is the
"advertise iff served" rule the sixth, eighth and fifteenth passes each restored in one direction or
another, back in a third.

**The uploader's follow-resolver had no NUL guard**, where DAV's has one *inside* the resolver under
a comment saying it lives there "so a verb added later cannot forget it". Six per-endpoint
pre-checks compensated, so behaviour matched only because every current caller remembered. Moved
inside. No behaviour change today; what it removes is the requirement that the next endpoint
remembers, which is how `POST /delete path=/Keep%00/x` once destroyed `/Keep`.

**Two confirmed and deliberately NOT fixed here.** The uploader's read endpoints stat before
resolving, so `404`-vs-`403` is an existence oracle for paths outside the share (measured: 403 when
the out-of-share target exists, 404 when it does not; `/list` leaks the same way with 400/404) — a
small reordering, but it belongs with the resolver unification rather than as a spot fix. And the
extension allow-list judges the **alias** name in listings and the **resolved target's** name on
access (measured: `alias.txt -> real.bin` listed then 403; `alias.bin -> real.txt` unlisted then
served 200). That one is a **semantics decision, not a defect fix** — the "symlinks are aliases"
ruling says a destructive verb acts on the named entry, but a *read* through an alias discloses the
target, so judging the alias name alone would be a disclosure. The fail-closed answer is to require
both names to pass, and that is the owner's call, exactly as the source/destination semantics were.

**Verified together.** 140 tests and 0 failures on a clean build with no new warnings, the trace
corpus green, and the probe sensitive in both directions on both fixes.

**Phase 2 is the 48 rules that agree but are duplicated** — the safe half, where a mistake surfaces
as a test failure rather than a behaviour change. Phase 3 is the API-shape debt (including the
target visibility that would let several symbols leave the public `WSKFunctions.h`) and consolidating
this file.

### Sixteenth pass: it was not green, and four of the findings were mine

A full top-down re-run at the owner's request, to see whether the tree finally came back clean after
the three known-open-low batches. It did not: **17 confirmed findings, 5 refuted, across 8 lenses
with 22 skeptics and none dead** — the coverage counters are reported explicitly this time, because
the twelfth pass returned `CLEAN` when every one of its verifiers had died.

**Four of the seventeen were regressions from the three batches that had just landed.** This entry
fixes those four; the rest are recorded for the cleanup.

**⚠️ The uploader initializer was made to kill the process — by the very session that fixed that
class.** Batch C added `realpath([_uploadDirectory fileSystemRepresentation], ...)` with no guard,
and `-fileSystemRepresentation` raises for an empty or NUL-bearing receiver. That is the **fifth
recurrence** of this codebase's most repeated defect, the first that was self-inflicted, and it
landed three files from the comment in `WSKFileResponse.m` explaining the exact hazard. Nothing
about knowing a rule prevents breaking it somewhere else.

**A validator that failed OPEN was replaced by one that fails CLOSED.** Batch A's new RFC 850 and
asctime patterns are parsed by ICU, which accepts 1–3 digits for a `yyyy` field and 1 for `yy`, so
`Sun Nov  6 08:49:37 94` parsed to the year **0094** rather than failing. Such a date precedes every
real mtime, so an `If-Unmodified-Since` carrying it produced a **permanent 412 that no retry could
ever satisfy**, where RFC 9110 §13.1.4 requires an unparseable date to be ignored. Measured 412/412/412
against 204/204/204 at the pre-batch commit. The fix anchors the calendar year rather than tightening
three ICU patterns, and applies to **all three** spellings rather than the two where it was noticed —
"closed at one of the sites the rule applies to" being the shape that keeps recurring here.

**Rejecting a non-date became linear in its length.** Two extra formatter passes plus a whole-string
double-space collapse, all inside the single process-wide serial queue that also serializes the
`Date` header of *every* response — 74× baseline, 1.48 ms of exclusive CPU at the 64 KB header cap,
and `If-Modified-Since` is parsed for every request before any handler or authentication runs. A
length precheck restores constant-time rejection; no legal HTTP-date exceeds 33 characters. Pinned by
a test with a deliberately loose bound (2000 rejections under 2 s, against 3.78 s unfixed) so it
catches the class without flaking under load.

**`webServerDidStop:` was delivered twice for one stop.** `-_stop` already posts it; batch C added a
second, synchronous, so the duplicate arrived *first* and inverted the ordering against
`-webServerDidDisconnect:`. The added call is now gone. **⚠️ And the claim that justified it was
false:** that entry asserted `-isRunning` and `-serverURL` "still answer as though it were serving",
which the skeptic measured on both trees, 7/7, as reporting stopped. **Sixth time this file has
asserted a property the code did not have.**

**A guard that quoted the whole rule and enforced one spelling of it.** Batch B's empty-header-name
check cited RFC 9112 §5 `field-name = 1*tchar` and then rejected only the empty string. A name
beginning with a space serializes as an obs-fold continuation and is therefore appended to the
**preceding header's value** — measured against the real `Date` header — and interior spaces, tabs
and non-ASCII went out verbatim. The request parser's own `tchar` predicate is now **shared** rather
than restated, in `WSKFunctions`, so the two sites cannot drift.

**⚠️ Verification limit, stated rather than papered over.** The duplicate-`webServerDidStop:` fix is
`#if TARGET_OS_IPHONE`, so the Mac suite is structurally blind to it, and the failure regime could
not be re-synthesized on demand: `-_stop` releases the listening descriptors before `-_start:` runs,
so exhausting file descriptors beforehand always lands in the SUCCESS regime, where both trees report
one stop and the measurement discriminates nothing. Two probe attempts did exactly that and were
discarded. What IS established: the skeptic pinned the duplicate to that line by measuring the
synchronous phase (tip `stops=1` before the run loop drained, baseline `stops=0`), and exactly one
delivery site now remains in the tree. The after-state is *not* measured, and this entry does not
claim it is.

**Five findings were refuted** by the skeptics, including one that would have broken conformance had
it been "fixed". Combined with batches B and C that is **nine refuted against sixteen real** — a
recorded finding in this project is roughly a 2-in-3 shot, so reproduce before fixing.

**Verified together.** 138 tests and 0 failures on a clean build with no new warnings — including one
nullable-to-nonnull warning this change introduced and removed before shipping — the trace corpus
green, and iOS and tvOS Debug both clean.

**Still open, and now the argument for the cleanup rather than another pass.** Thirteen confirmed
findings are left, all pre-existing and mostly low: MKCOL answering 500 rather than RFC 4918 §9.3.1's
405 on an existing collection (**medium — rclone cannot copy into any existing folder**, and the
error body leaks the server-side path); a 403 where a 404 belongs when a parent collection is absent
(same rclone breakage); `WSKDataRequest.text` and `.jsonObject` aborting for exactly the case their
header documents as returning nil; `addHandlerForMethod:path:` aborting in Debug and registering
nothing in Release for a missing leading slash — the identical shape batch A fixed one method away;
`OPTIONS` omitting PROPPATCH from `Allow`; LOCK/UNLOCK 405s carrying no `Allow`; the SSE prefix test
having no separator boundary; `_resolvedUploadDirectory` being captured once so the batch C fix
reverts if the share's realpath changes; and a symlinked share receiving no `NSFilePresenter` events
at all.

**The rate is not falling, and the reason is now measured.** Each batch of fixes has introduced
roughly one new defect per five it closed, clustered in exactly what the fix touched. Auditing harder
does not converge while that holds. Every one of the four regressions above came from adding a guard
or a call without asking what it now refuses, duplicates, or costs — so the next work is the deferred
structural cleanup, starting from the rules that have more than one implementation.

### Known-open lows, batch C: the long-lived surfaces, and live updates that were broken by default

**⚠️ The headline finding is far broader than the entry that predicted it.** It was carried as "SSE
event paths collapse to `/` when the share is reached through a symlinked ancestor" — which reads
like an exotic configuration. It is the **default**. `-_relativePathForAbsolutePath:` derives an
event's path by chopping the share off the front of an absolute path; every caller hands it a
`realpath(3)` result while `_uploadDirectory` has only been `-stringByStandardizingPath`'d. Those
disagree for **every share under `NSTemporaryDirectory()`**, because `/var` is a symlink to
`/private/var` that neither `-stringByStandardizingPath` nor `-stringByResolvingSymlinksInPath`
expands — the same `/var` vs `/private/var` mismatch the tenth pass recorded in a different method.

The prefix test therefore failed and the fallback fired, so every change event named the share
root. Measured against a plain `mktemp -d "$TMPDIR/..."` share, creating a folder inside a
subfolder:

    before:  data: {"type":"create","path":"//"}
    after:   data: {"type":"create","path":"/Sub (1)/"}

`//` rather than `/` because the create path appends its own separator to the fallback. The browser
only reloads when the changed directory matches the folder it is viewing, so **live updates
silently did nothing for every subfolder** — the uploader's headline feature, in its ordinary
deployment, with no error anywhere. `-presentedSubitemDidChangeAtURL:` had resolved both sides
since the SSE work landed; this is the same rule at the one site that never got it, which is this
codebase's signature defect shape yet again.

**`-bonjourName` never saw an auto-rename.** `_resolutionService` is a `CFNetServiceCreateCopy` of
the registration service taken immediately after `CFNetServiceRegisterWithOptions` is *initiated* —
registration is asynchronous, so the copy freezes the name as configured. Registering with flags 0
means auto-rename is on, so a second instance on the network becomes `<name> (2)` and the property
reported the original for the rest of the run. Measured with two servers sharing a name:

| | server 1 | server 2 |
|---|---|---|
| before | `WSKRenameProbe` | `WSKRenameProbe` |
| after | `WSKRenameProbe (2)` | `WSKRenameProbe` |

Reading `_registrationService` first is the whole fix; it is the service that was actually
registered, and it has the same `-_start`/`-_stop` lifecycle, so the `_stateQueue` confinement the
old comment existed to justify is unchanged.

**A failed foreground restart said nothing, and the code admitted it.** `-_reconnectInForeground:`
called `[self _start:NULL]` under a comment reading *"TODO: There's probably nothing we can do on
failure"*. Something can: say so. The listening sockets are gone, the server is dead for the rest
of the foreground session, and `-isRunning` and `-serverURL` still answer as though it were
serving. It now logs the error and delivers `-webServerDidStop:`, on the main thread and outside
`_stateQueue` — a delegate reading `-serverURL` from inside that block would deadlock on it.

**⚠️ The SSE quiet-client reaping gap was REFUTED by measurement.** It was carried as "an SSE client
that stops reading but holds its socket open is never reaped". Sixteen such clients against a
16-channel server, sampled every 15 s for 90 s: a real client still obtained a stream at **5 of 7**
sample points. The reaper does reclaim them; what remains is the expected window while slots are
held, not a denial. That makes **four** recorded lows across batches B and C that evaporated on
contact, against twelve that were real — the ratio is the argument for re-measuring rather than
working from the list.

**Verified together.** 134 tests and 0 failures on a clean build with no new warnings, the trace
corpus green, iOS and tvOS Debug both clean, and both the SSE-path and Bonjour probes sensitive in
each direction. One warning I introduced — the GNU `?:` extension, a class this project has fixed
before — was caught by the clean build and removed before the suite ran.

**The known-open backlog is now empty.** What remains are settled decisions rather than defects: the
`//` status disagreement, `MOVE`-without-`Overwrite` defaulting to refuse, the directory-rename
TOCTOU, and litmus's `propfind_invalid2`. The next piece of work is the structural cleanup that has
been deferred since the programme began.

### Known-open lows, batch B: honest status codes, and three entries that were not defects

**Three of the recorded items were refuted by re-measuring them, and one of the three would have
been an actively harmful "fix".** That is the fourth time this programme has found an aged finding
evaporate on contact, and it is why the rule is to re-measure rather than work from the list:

- **`If-Match` on a missing resource answering 404 is REQUIRED, not a bug.** RFC 9110 §13.2.1 says
  a server MUST ignore all preconditions when the unconditional response would be anything other
  than 2xx or 412 — so a conditional `DELETE` of something that does not exist must answer 404, and
  "fixing" it to 412 would have broken conformance. `PUT` is the opposite case, because it would
  create (201), so the condition IS evaluated and `If-Match: *` on a missing path correctly fails
  412. Both directions are now pinned by a test, precisely so a later pass does not re-find the 404
  and "correct" it.
- **An empty header name was already refused** on the request side (`colon == 0`). The gap was on
  the *response* side, which had no such check — fixed there instead.
- **A MOVE whose swap fails already unwinds**, restoring the source rather than stranding it under
  the staging dot-name. Only a double failure can leave residue, and nothing better is available
  when the filesystem itself is refusing.

**A full volume answered "you are not allowed".** ENOSPC and EDQUOT were mapped onto 500 for PUT
and MKCOL, and — the sharp one — onto **403 Forbidden** for COPY and MOVE. 403 is a claim that the
client may never do this, so a client that would have retried after freeing space gives up
permanently instead. RFC 4918 §11.5 defines 507 for exactly this. Measured on a genuinely full
2 MB volume, before and after:

| verb | before | after |
|---|---|---|
| PUT | 500 Internal Server Error | 507 Insufficient Storage |
| MKCOL | 500 Internal Server Error | 507 Insufficient Storage |
| COPY | **403 Forbidden** | 507 Insufficient Storage |

Both spellings have to be read or the mapping closes half the class: `NSFileManager` reports a full
volume as `NSFileWriteOutOfSpaceError`, while `EDQUOT` only ever arrives as a POSIX errno nested
under `NSUnderlyingError`.

**⚠️ Fourteen status codes went out under the wrong reason phrase, and the unit test could not have
found it.** `CFHTTPMessageCreateResponse`'s own table stops at HTTP/1.1 as it stood in 1999, so
every status registered since gets its class default. Three of them this library emits in ordinary
operation: **`421 Misdirected Request` — the Host allow-list refusal, i.e. the whole DNS-rebinding
defence — was serialized as `421 Bad Request`**, as were `424 Failed Dependency` (PROPPATCH's
atomicity refusal, added earlier in this programme) and `431 Request Header Fields Too Large` (the
fifth pass's header cap). Measured across all 56 codes in `WSKHTTPStatusCodes.h`.

The lesson is the one this file keeps re-learning from a different angle: the 507 work was covered
by a unit test over the mapping function, which passed and proved only that the *function* was
right. The end-to-end probe against a real full volume is what showed the status line itself, and
that is where the phrase was visibly wrong. **A test of the helper is not a test of the wiring.**

Only those fourteen are supplied; everything CF already gets right is left to CF, so all four
statuses the recorded-trace corpus contains (200, 201, 207, 404) still serialize byte for byte. The
corpus fails on any difference, so rewriting phrases it records would have turned a fix into a
corpus change.

**MKCOL answered 500 with the collection already created.** The creation-date step runs after the
directory exists, so a failure there told the client the method failed while leaving the collection
behind — and the retry then gets 405 because it is there. The collection is removed before the error
goes out. "A refused transaction leaves nothing behind" applies to the failure paths too.

**`-startWithOptions:error:` on an already-running server was a fourth process kill.** It is
documented to return NO, and the way a host app finds out is `*error` — which was never set. In
Debug it did not return at all: `WSK_DNOT_REACHED()` aborted. Same shape as all six of batch A, found
because the test for the *documented* behaviour crashed the runner rather than failing.

**Six non-null properties that are genuinely nil are `nullable` now** — `allowedFileExtensions` on
both servers, and `title`, `header`, `prologue`, `epilogue` and `footer` on the uploader. nil is
*meaningful* for every one of them (no extension restriction; use the computed default), so
substituting a value in the getter would have destroyed information rather than told the truth. One
of them, `epilogue`, was documented as "the default value is nil" directly beneath a non-null
declaration. Source-breaking for Swift, deliberately, as in batch A. The `Server` header default was
also documented as the class name when it is `"WebServerKit"`.

**Verified together.** 133 tests and 0 failures on a clean build with no new warnings, the trace
corpus green, iOS and tvOS Debug both clean, and the full-volume probe sensitive in both directions.

**Still open:** batch C, the long-lived surfaces — the SSE quiet-client reaping gap, SSE paths
collapsing to `/` through a symlinked ancestor, `-bonjourName` after an auto-rename, and the silent
iOS foreground-restart failure. The `//` status disagreement, `MOVE`-without-`Overwrite`, the
directory-rename TOCTOU and litmus's `propfind_invalid2` remain settled decisions rather than
defects.

### Known-open lows, batch A: six ways a host app could kill the process

The ~20 items the audit programme deferred were all filed as "low". For these six that label was
measuring the wrong axis: they are low in **reachability** — each needs a host app to use a
documented API in a documented way — not in consequence. **Four of the six kill the process**, and
the proof is how the regression tests behaved against the unfixed tree: they did not fail, they
crashed the test runner four separate times and the suite reported `Executed 0 tests, with 0
failures`. That is the third time this file has recorded that exact trap. Read the executed count.

**`+responseWithFile:` is declared `nullable` and raised instead.** `-fileSystemRepresentation`
raises `NSInvalidArgumentException` for an empty or NUL-bearing receiver rather than returning
NULL, and the raise escapes through the host app's handler into the connection. Any handler that
builds a path from request input can reach both spellings. This is the same shape the eleventh pass
fixed in `+responseWithJSONObject:` — **the fourth time a fix for the nil/NUL class has failed to
reach every site the value can arrive by**, which is now this codebase's single most repeated
defect. The NUL check is kept even though `open(2)` would truncate there anyway: truncating makes
the server act on a prefix of what was asked for, which is refused everywhere else here.

**A `WSKMatchBlock` inspecting the request it just built SEGV'd.** The connection populates a
request's addresses *after* the match block returns, so inside the block they are nil — and
`WSKStringFromSockAddr` reads `addr->sa_len` before `getnameinfo` can fail, so there is nothing to
fail closed on. Inspecting the request is the match block's entire job. It now returns the same
`@""` it already returned for a `getnameinfo` failure, so no caller needs a new case, and
`localAddressData`/`remoteAddressData` are **`nullable`** now because they genuinely are in that
window. Source-breaking for Swift, deliberately — the same call as the `WSKFileResponse` validators.

**The public date functions crashed unless a server had been created first.** `WSKFormatRFC822`,
`WSKParseRFC822`, `WSKFormatISO8601` and `WSKParseISO8601` `dispatch_sync` on a queue only built by
`WSKInitializeFunctions`, which ran only from `+[WSKWebServer initialize]` — so calling any of the
four before touching the server class was an immediate crash. Carried in this file as known-open
since the sixth pass. Now `dispatch_once`, called lazily from each of the four. The main-thread
assertion is gone with it: `NSDateFormatter` has been safe to build off the main thread for many
releases, and `dispatch_once` removes the race the assertion stood in for.

**⚠️ The in-suite test for that one cannot regress-guard it, and it would have been easy to claim
otherwise.** XCTest runs one process in alphabetical order, so in a full-suite run some earlier
test has already messaged `WSKWebServer` and the formatters exist by the time it runs — it only
exercised the lazy path because it happened to run in *isolation*. The real oracle is
out-of-process: a binary that links the framework and names `WSKWebServer` nowhere. Fixed library
prints OK; unfixed exits **139 (SIGSEGV)**. Kept in the scratch harness, not the suite, because it
needs its own link line.

**Date preconditions failed OPEN for two of the three formats RFC 9110 requires.** Only IMF-fixdate
parsed, so an `If-Modified-Since`, `If-Unmodified-Since` or `If-Range` carrying an RFC 850 or
`asctime()` date parsed to nil and the precondition was treated as *absent* — a validator failing in
the permissive direction. Both are parsed now (never formatted; senders must still emit
IMF-fixdate). Two details that are easy to get wrong: RFC 9110 §5.6.7's two-digit-year rule is
exactly a window opening 50 years ago, which is what `twoDigitStartDate` is set to; and `asctime()`
pads a single-digit day to width two ("Sun Nov  6"), which `d` does not absorb, so runs of spaces are
collapsed rather than the pattern being loosened.

**Two `WSK_DNOT_REACHED()` sites punished the careful host app.** `addGETHandlerForBasePath:`
enforced an *undocumented* leading/trailing-slash precondition by aborting in Debug with no
diagnostic and, in Release, registering nothing and returning — so every request 404'd with no clue
why. Neither spelling is ambiguous, so both are normalized now. And `-stop` on a server whose start
**failed** aborted a Debug build, which is precisely what an error path does right after
`-startWithOptions:error:` returns NO; it is idempotent tidy-up now. While in the header, the
base-path handler's documented no-match status was corrected from 401 to the 404 it actually
returns.

**Verified together, not per-fix.** 127 tests and 0 failures on a clean build with no new warnings,
the trace corpus green, iOS and tvOS Debug both building with 0 warnings, and the date oracle
sensitive in both directions. The full-suite run is the load-bearing one: per-fix greens are what
let two regressions ride `main` through three CI runs earlier in this programme.

**Still open:** the remaining lows, which split into batch B (status-code and documentation honesty
— `If-Match` on a missing resource answering 404 not 412, ENOSPC/EROFS answering 500/403 not 507,
MKCOL's 500-after-create, empty header names, the six non-null-but-nil properties on the uploader
and DAV server, `-startWithOptions:error:` not setting `*error`) and batch C (the long-lived
surfaces — the SSE quiet-client reaping gap, SSE paths collapsing to `/` through a symlinked
ancestor, `-bonjourName` after an auto-rename, the silent iOS foreground-restart failure). The `//`
status disagreement, `MOVE`-without-`Overwrite` and the directory-rename TOCTOU remain settled
decisions rather than defects.

### The reload guard was a counter two parties shared, and it has now wedged twice

A listing arriving while the rename box is open froze the page permanently: it stopped tracking the
share, and no later change — SSE, Refresh, navigation — ever moved it again.

`_reloadingDisabled` was a COUNTER that two independent parties incremented and decremented:
`_reload()` around its own request, and the rename box between `onedit` and `onsubmit`/`onreset`. A
counter like that is only ever as correct as its least reliable decrement, and this one has now
failed twice for two unrelated reasons. The first, already recorded in this file, was a throw
skipping the release. The second: with a reload IN FLIGHT the box is opened (count 2), the listing
lands and `$("#listing").empty()` destroys the box, so jeditable's `onsubmit` and `onreset` never
fire and that increment is never matched — the request's own release takes it to 1, where it stays
forever.

**⚠️ The obvious repair makes it worse, which is why this was left for a designed fix.** Decrementing
by the number of destroyed editors trips over jeditable's default `onblur: 'cancel'`, which fires
`onreset` as well — so the same teardown can decrement twice and the counter goes NEGATIVE, which is
just as truthy in `if (_reloadingDisabled)` and wedges identically.

**So the counter is gone.** Re-entrancy is now a boolean owned solely by `_reload()` and cleared in
its `.always()`, which jQuery always runs; and whether an editor is open is **derived from the DOM**
rather than remembered, so there is no pairing to get wrong and nothing to leak. If a box is
destroyed, the next question simply answers "no".

That is the property that matters, and it is what the old design could not have: **self-healing**. A
missed flush now leaves a stale listing until the next reload rather than a permanently frozen page.

Verified in Chromium with the reload deliberately held in flight (a delayed route) so the box can be
opened underneath it — the ordering the wedge actually needs, which an earlier attempt at the probe
got wrong and so measured correct queueing instead of the bug. Unfixed: WEDGED. Fixed: healthy. The
three UI fixes from the previous browser pass were re-checked in the same run and all still hold.


### The non-null lie in WSKFileResponse, and five warnings an incremental build was hiding

**⚠️ BREAKING CHANGE.** `WSKFileResponse` redeclared `contentType`, `lastModifiedDate` and `eTag` as
non-null, over `WSKResponse`'s own `nullable` declarations. The code cannot keep that promise, so the
redeclarations are gone — the base class's honest ones now apply, and **Swift callers will need
`if let` or `?`**.

Two cases make the promise false, both reachable with no host-app opt-in. `lastModifiedDate` is
deliberately nil while mtime is inside its filesystem's timestamp bucket, which is the whole of the
protection stopping two representations going out under one date. And an unsatisfiable byte range
answers 416 with **none of the three set**, so one remote `Range: bytes=999999999-` handed a host app
three nils from properties its own header said could not be nil — in Objective-C a nil heading for
whatever the caller did next (this codebase's named recurring crash is a nil reaching a dictionary
literal, and nothing in `Sources/` catches an NSException); in Swift, `lastModifiedDate` imported as
a non-optional `Date` and **trapped**.

Deleting three lines was the whole fix, which is worth noting: the properties were only ever
*declared* wrongly. A header that lies to the type system is worse than one that changes.

**⚠️ An incremental build hides warnings, and that is how five of them accumulated.** Removing the
redeclarations forced a full rebuild, which surfaced five: two nullable-to-nonnull conversions, two
uses of the GNU `?:` extension, and two messages to an unqualified `id` (one of them in the symlink
listing that landed two PRs ago). Running `xcodebuild` twice in a row proves it — the first
invocation reported four, the second reported zero, having recompiled nothing. **Check warnings
against a clean `-derivedDataPath`, or the count means nothing.** It is the same shape as the
`-Wbad-function-cast` warning found the same way a few PRs earlier. All five are fixed and a
from-scratch build is at zero.


### WebDAV class 1, part two: PROPPATCH, and an independent suite finding my own bug

`PROPPATCH` was 501 while `OPTIONS` advertised `DAV: 1`, which is the last of the class-1 MUSTs this
server did not meet. Dead properties are stored in **one extended attribute** holding a plist keyed
in Clark notation (`{namespace}localname`) — one blob rather than an xattr per property, so a key
never has to be escaped into an xattr name and a set of properties is written in a single call and
cannot half-apply. A filesystem that cannot store extended attributes at all reports `ENOTSUP` —
**exFAT among them, measured rather than assumed** — and that becomes a per-property 403 rather than
a pretence that the property was stored.

**The method is atomic**, as §9.2 requires: the update is computed against a copy and only written if
nothing was refused, so a client told 424 Failed Dependency can retry the whole document without
working out what half-landed. Live properties are derived from the filesystem and are refused with
403. `PROPFIND` reports stored properties by name, in `allprop`, and by name in `propname`.

**⚠️ litmus found a bug of mine that the suite could not.** The two parsers disagreed: `PROPPATCH`
keyed a property in NO namespace by its bare name, while `PROPFIND` defaulted the same case to
`DAV:` — so such a property could be stored and then never read back. That is this codebase's
signature defect shape (the same rule spelled two ways in two places) appearing in brand-new code,
and 122 passing tests plus a live Apple client both missed it. litmus `props` went 28/30 → **29/30**
once the convention was unified.

The remaining failure is `propfind_invalid2`: an invalid namespace declaration in the body answers
207 rather than 400, because libxml2 runs with `XML_PARSE_RECOVER` by deliberate choice. Tightening
it risks rejecting bodies real clients send, so it is recorded rather than chased. `basic` is 16/16.

**The lock stub is now documented for what it is.** `performLOCK` mints a token, returns a
well-formed `lockdiscovery` document and stores **nothing** — no lock table, no timeout, no reaping,
and the `If:` header is not parsed anywhere. It exists solely because Finder refuses to write to a
share that does not advertise class 2. Deliberately not made real: locking prevents concurrent
writers losing each other's updates, these deployments are single-user, and the same protection is
now available statelessly through `If-Match` and `If-Unmodified-Since` — which every client can use,
not only ones that lock. Real class 2 needs the `If:` grammar, i.e. a parser, and parsers have been
by far the richest source of defects here.


### WebDAV class 1, part one: PROPFIND completeness and method semantics

WebDAV was only partially promised in the original README, so this is **new capability rather than
repair** — the gaps below are undocumented scope, not regressions. Split from `PROPPATCH`, which
needs a dead-property storage design of its own, so each half stays reviewable.

**A property that cannot be returned now gets its own propstat with 404.** The old model was a
bitmask of the four live properties and an unrecognised name was logged and dropped, so a client
asking for three properties and receiving one was told `HTTP/1.1 200 OK` over a `<prop>` that
silently omitted the rest — unable to tell "this property does not exist here" from "it exists and is
empty", which is the distinction the propstat structure exists to draw. Requested names are now
remembered, with their namespace, so a client asking in its own namespace sees that name back rather
than a `DAV:`-qualified guess.

**`<propname/>` is supported** — it returns the names with empty values, and used to be refused with
400, telling a client its perfectly legal request was malformed.

**`Depth: infinity` on PROPFIND answers 403 with `<DAV:propfind-finite-depth/>`**, the
machine-readable precondition RFC 4918 §9.1 defines for exactly this refusal, instead of a bare 400.

**`Depth: 0` is accepted on COPY and DELETE.** For a resource with no internal members it cannot mean
anything else, and refusing it meant a client that sets Depth uniformly could not delete or copy a
single FILE at all. An unrecognised Depth is still refused.

**`Allow` is sent on OPTIONS and on the 405**, the latter required by RFC 9110 §15.5.6.

**⚠️ The trace corpus needed re-recording, exactly as predicted, and one recording was a lie worth
keeping.** Four OPTIONS recordings gained the `Allow` header. The fifth is the interesting one:
Finder asks for four quota properties, and the recorded response was `207` carrying
`<D:propstat><D:prop></D:prop><D:status>HTTP/1.1 200 OK</D:status>` — "OK" over nothing. That is the
dishonesty this change fixes, preserved in the corpus since 2014. Re-recorded by reconstructing the
body and **validating the method against the OLD byte count first** (208 reconstructed = 208
recorded) before trusting the new one (364 = 364 emitted).

**A live Apple WebDAV client was driven against the change**, because CLAUDE.md records that the
corpus proves recorded replay and "cannot prove live-client tolerance" — the class that broke Finder
when the sixth pass first tightened `If-Range`. Mounted with `mount_webdav`, then list, read, write,
read-back, mkdir, rename, delete and rmdir all succeeded, and it unmounted clean.


### Symlinks are aliases: decided semantics, not a defect fix

Two owner decisions, implemented together because the eleventh pass's skeptic established that source
and destination semantics have to be decided as one or the next pass finds the half that was missed.

**A destructive verb now acts on the entry the client NAMED, not on what it points at.** `DELETE
/latest` where `latest -> build/` used to remove the multi-hundred-megabyte build directory and leave
the dangling link behind, answering 204; no shell tool behaves that way, and the residue was then
invisible to every listing and removable by nothing. `rm` removes the alias, `mv a latest` replaces
it, and reads still FOLLOW it — `GET /latest/app.ipa` is unchanged. Applied to DELETE, and to
MOVE/COPY on **both** source and destination, in both servers.

**The three dangers the skeptic measured are each addressed rather than accepted.** It resolves
ONCE — `WSKResolveNamedEntryWithinDirectory()` resolves the PARENT and appends the raw leaf, deriving
containment and hiddenness from that single observation, so the two-observations shape the eighth
pass closed is not reopened. The destination side is covered, which the proposed fix left untouched.
And the "it relaxes the extension allow-list" objection dissolves under these semantics rather than
being overridden: removing an alias named `x.txt` that points at `id_rsa` does not touch `id_rsa`, so
refusing it was the wrong answer.

**Containment is exactly as strong**, and that is what the new test asserts hardest: the parent is
still resolved, so `PUT /escape/x` through a link out of the share is still 403 with nothing landing
outside, and reads and deletes through it are still refused.

**⚠️ `testSymlinkResolvingToTheShareRootCannotDestroyIt` was deliberately re-pointed.** It asserted
that `DELETE /self` (where `self -> .`) is REFUSED, because when the resolver substituted the
resolved path the only safe answer was refusal. Acting on the named entry means the share root is
never the thing operated on, so the catastrophe it guards — the ninth pass's five-entry share emptied
to zero by one request — is now impossible **by construction**. The test now asserts that the
contents survive rather than that the request was refused, which is the property that actually
matters.

**Symlinks now appear in listings**, classified by what they point at. They were served but omitted
from all three enumerations, which through a real mounted client is data loss rather than cosmetics:
`mv` returns 0 having copied only what the listing reported, then deletes the source. A link is only
advertised when its target resolves INSIDE the share and is a regular file or directory — otherwise
it would be advertised and then refused on access, which is the same disagreement with the sign
flipped. Shared through `WSKServableFileTypeAtPath()` so the three enumerators cannot drift.


### Full confirmation re-run: every technique at once, and it caught what the individual passes could not

Not a new technique — **all ten technique families re-run simultaneously against tip**, at the owner's
request, as a sanity check. It was worth far more than expected, and the reason is worth keeping:
every technique had last run against an OLDER commit, and five PRs had landed since. The individual
passes each asked "is this correct?"; only running them together against the accumulated result asks
**"do the repairs hold together?"** — and three times the answer was no.

**Two of the findings were regressions from my own PR #48, and the full harness could not see
either.** 118 tests, eight recorded trace suites and Release builds on three platforms passed on that
PR and on every one since.

**Every successful file response logged a false truncation, and gzip on a file response was entirely
broken.** PR #48's per-chunk verification treated normal end-of-body as a premature EOF: once `_size`
reaches 0 the read length is 0, so `read(2)` returns 0 for the ordinary reason. A **zero-length
NSData is the end-of-stream sentinel** both consumers require — `-[WSKConnection
writeBodyWithCompletionBlock:]` writes the terminal chunk on it and `-[WSKGZipEncoder readData:]`
selects `Z_FINISH` on it — so returning nil aborted the chain. Measured: gzip broken at all 8 sizes
from 0 B to 200 KB, chunked stream never terminated, and 8/8 successful responses logging an ERROR
falsely claiming truncation — destroying the exact signal that change existed to create. Identity
responses hid it completely, because `Content-Length` had already framed the body. One token:
`} else {` → `} else if (_size > 0) {`.

**On exFAT, WebDAV MOVE and COPY to any new name answered 403 — rename and duplicate simply did not
work.** PR #48 swaps with `renamex_np(RENAME_EXCL)` when nothing was vetted, and macOS 15's FSKit
exFAT returns `ENOTSUP` for it. APFS, FAT32 and HFS+ all implement it, which is exactly why every
test passed: they run on APFS. Measured on a real exFAT image, 0/10 before and 10/10 after, with zero
staging residue. The fallback reserves the name itself — `mkdir` for a staged directory,
`open(O_CREAT|O_EXCL)` otherwise — which gets the same exclusivity, and **fires only on
ENOTSUP/ENOSYS**: every other errno, `EEXIST` above all, must keep failing or the racing newcomer
that branch exists to protect gets clobbered. **The proposed fix omitted reclaiming the reservation
when the following `rename(2)` fails**, which would have left a zero-byte file or empty directory at
a name the request then refuses — a brand-new residue class, and the seventh instance of a fix
planting the next defect. What shipped unlinks or rmdirs it and preserves the original errno.

**A dot-file one level down switched off the extension allow-list for the rest of that directory.**
`-skipDescendants` is defined for the most recently returned SUBDIRECTORY; both subtree walks called
it for every dot-name including regular FILES, which pops the enclosing level — so every entry after
the first dot-name in that directory's readdir order was never vetted. A `.DS_Store` sits in every
Finder-touched folder and sorts early, so this was the ordinary case: `DELETE /Vault` answered 204 and
destroyed `sub/id_rsa` 60/60, as did the uploader's `/delete` and a MOVE/COPY overwrite, while the
same file addressed directly is refused 403 by the same server in the same configuration. **The top
level of the addressed collection is immune, which is why three existing tests looking straight at
this all pass against the unfixed code** — their fixtures put the victim at the top. Any regression
test for this class must put it one level down, and the new one does.

This is the **fourth recurrence** of the class the eighth and tenth passes each declared closed, and
it falsifies the design-priorities sentence "a recursive delete refuses when it would destroy a file
a direct delete would have refused" for essentially every macOS folder. Pre-existing — established by
building `e53c43d` and measuring, not by reading the diff. Only a dot-named DIRECTORY is skipped
wholesale now; that judgement call is deliberate and still holds.

**Still open from this run, deliberately.** The browser reload wedge — a listing arriving while the
rename box is open leaves `_reloadingDisabled` above zero and the page stops tracking the share — is
confirmed, but **the proposed fix re-introduces the identical permanent wedge with a negative
counter**, so it needs a different approach. `WSKFileResponse.lastModifiedDate` being declared
non-null while nil inside the timestamp bucket is real but its fix is a **source-breaking public API
change**. Also low and open: an empty header name is accepted; MKCOL answers 500 after creating the
collection in Debug builds; a header-time refusal can lose its error page body to a TCP reset (the
status is never lost); `If-Match` on a resource that does not exist answers 404 rather than 412; and
a MOVE whose swap fails can strand its staged item under an unreachable dot-name.

**The lesson worth carrying: run everything together, periodically.** A per-pass green harness proved
nothing about the accumulated tree, and the two regressions above sat on `main` through three
subsequent PRs and their CI runs.

### Fourteenth audit pass: the browser was never in scope, and that is where the defects were

Four oracles, weighted deliberately toward things outside this project's own reasoning: **static
analysis**, **a second and third independent client**, **the uploader's page in a real browser**, and
**a two-binary differential against upstream GCDWebServer**. Three of the four findings live in
`index.js`, which thirteen passes had never touched.

**Static analysis found nothing reproducible, and that is the most informative clean result yet.**
Nine analyzer configurations across three engines, every plausible diagnostic then driven from the
network before being believed. Zero survived. After thirteen passes of runtime instrumentation this
says the defects that remain are not the kind a symbolic explorer finds — do not re-run it.

**Six open browser tabs deadlocked the uploader UI completely.** A browser allows six HTTP/1.1
connections per origin and an `EventSource` never completes, so six tabs consumed all six. Measured:
tabs 1–5 answered in 2 ms, the sixth timed out, a seventh rendered nothing for 13.5 minutes. The
server was idle throughout — curl through the same relay answered 200 with 122 free connection slots
and 10 free SSE channels. **`kMaxSSEChannels` (16) sits above the bound that actually binds**: one
browser deadlocks itself at 6 and can never reach 16. Default configuration, no hostility, and it is
Shape B's entire deployment.

**⚠️ The obvious fix is worse than the defect, and was measured rather than reasoned about.** Closing
the stream on `visibilitychange` trades the deadlock for a live-update blackout: the server only
reclaims a browser-closed channel when a heartbeat write fails 20–33 s later, so ordinary tab
switching left zombies — 25 of 40 reconnects refused, and the tab actually being looked at stopped
updating. It also does nothing for six *simultaneously visible* tabs. What shipped instead is **one
stream per browser**: a single tab holds `/events` under a Web Lock and relays over a
`BroadcastChannel`. The lock is released by the browser itself when the holding tab goes away, so
there is no heartbeat, no timeout, and no way to leave the stream unheld or held twice; where either
API is missing the old behaviour stands. Verified in Chromium: seven tabs all answering in 1–2 ms
against tab 6 dead for 20 s before.

**A deep link, or simply pressing Reload inside a subfolder, bounced to the root.** `_path` is only
assigned when a listing *returns*, so between `_reload(hashPath)` and its response it still read
`"/"` — and the SSE `onopen` re-sync firing in that window re-requested the root. 33 of 40 attempts.
The re-sync now targets the path most recently *requested*.

**Opening the rename box on a CR-bearing filename and pressing Enter renamed it, with nothing
typed.** `<input>` in the Text state applies the "strip newlines" sanitization algorithm, so the box
can never hold a CR — making `value != name` unconditionally true. This is the same shape as the
fourth pass's `&` fix one layer further down: there the mangling was jeditable's and seeding cured
it; here it is the browser's own and no seeding can. The comparison is now against what the box can
actually hold.

**The Host allow-list refused any Host whose port differed from the listening port** — contradicting
`WSKOption_AllowedHostNames`' own documentation ("may include a port ...; **without one, any port
matches**"), and refusing every deployment behind a port-translating hop. **This one is a judgement
call and is easy to reverse:** the port comparison is gone, and an existing assertion in
`testHostValidationRefusesRebindingButAllowsRealNames` was deliberately inverted. The reasoning is
that `Host` is derived from the request URL, not from the page's origin, so a browser fetching this
server can only ever state *this* server's port; a differing one comes from a forwarder, or from a
non-browser client that could state any `Host` it liked and against which rebinding — which requires
a browser — does not apply. The name carries the entire defence, and every rebinding assertion still
passes unchanged. An entry that pins a port is still honoured verbatim.

**Refuted, and worth recording as the method rather than the result.** A case-variant `PUT` on a
case-insensitive volume looked like a real defect until the skeptic ran `rclone serve webdav` over
the same directory and got byte-identical behaviour. Not a WebServerKit deviation — inherent to
vending a case-insensitive namespace through a protocol whose clients assume otherwise.

**Verified clean:** litmus `basic` 16/16, `http` 4/4, `locks` 3/3; 2.3 GB through a real
`mount_webdav` client byte-perfect across 33,269 mixed operations; rclone `sync`/`check` agreeing in
both directions; upstream GCDWebServer builds on a current toolchain and the behavioural differential
found the hardening intended and documented.

**The JS has no test harness**, so all three `index.js` fixes are verified by a Chromium probe run
against the unfixed and fixed builds, not by the XCTest suite — which is blind to them and stayed at
118/118 throughout, in both states.

### Thirteenth audit pass: an outside conformance suite, a real mounted client, and two regressions of my own

Four more never-used techniques, and two of them were ones an earlier pass had written off as needing
hardware: **litmus 0.13**, the standard WebDAV conformance suite, built from source (its 2005-era
autoconf needs `CFLAGS=-Wno-implicit-function-declaration` on a modern clang, or it dies claiming it
cannot find `socket`); **a real `mount_webdav` mount** driven by macOS's own kernel WebDAV client,
which needs no privileges when an ordinary user owns the mount point; **mutational fuzzing seeded
from the eight recorded real-client sessions** rather than from synthetic requests; and **the
long-lived resources** — the SSE channel state machine, Bonjour, the heartbeat reaper — under churn.

**A raw `#` in the request-target was discarded and every verb honoured against the prefix.**
`CFURLCopyPath()` treats it as a fragment delimiter. `#` is a legal filename character and
`MyApp#42.ipa` is an ordinary CI convention, so this needs no malice:

    PUT /ci/MyApp#41.ipa -> 201     PUT /ci/MyApp#42.ipa -> 204    PUT /ci/MyApp#43.ipa -> 204
    files on disk in /ci: ['MyApp'] = BUILD-43-BYTES
    GET /ci/MyApp#42.ipa -> 200 OK    body = BUILD-43-BYTES
    DELETE /D1/#nope     -> 204       /D1 destroyed

Three builds collapse into one, two are destroyed, every answer says success, and a GET naming build
42 hands over build 43. Same class as the NUL truncation the eighth pass refused rather than
honoured, at a delimiter that fix never covered. litmus finds it independently (`delete_fragment`).
Not an allow-list bypass — the allow-list judges the truncated path and still refuses.

**⚠️ Guarding the request-target alone leaves the whole defect reachable.** HTTP stacks sanitize a
URL they put in the request line but never a header value, so curl strips `#` from the target and
passes it through in `Destination` untouched — measured with the target-only guard in place, `COPY`
with `Destination: http://h/Builds#x` still answered 204 and still replaced a three-build collection
with a 4-byte file. Both sites are guarded. The request-line check is on the raw wire bytes in
`_ValidateRequestLine`, ahead of any CF parsing, so a `-rewriteRequestURL:` subclass cannot route
around it. What it costs, measured: `GET /q.txt?a=1#b=2` and a bare trailing `#` become 400, and a
`Destination` of `/Builds#nope.txt` no longer creates a file with that literal name. `%23` still
addresses a `#`-bearing file correctly, and the test asserts that, because it is what a naive fix
breaks.

**⚠️ Two of this pass's findings were regressions from the TWELFTH pass — mine.** Both in the
default configuration:

- The removability walk required `W_OK` on every directory in the subtree, but `unlink(2)` and
  `rmdir(2)` need write permission on the **parent**, not on the item — so an **empty** directory is
  removable whatever its own mode says. `chmod 555` on one made its whole ancestry permanently
  undeletable, and both `unzip` and `ditto -x -k` preserve 0555, so it arrives through ordinary
  archive extraction. A directory is now only required to be writable if it actually has entries; one
  that cannot be listed at all is still refused, and a read-only NON-empty directory is still refused,
  which the test pins in both directions.
- `If-Match: *` was keyed on the entity tag, which is only minted for a regular file, so it always
  failed for a collection: a conditional `DELETE`, `MOVE` or `COPY` of a folder could never succeed.
  `*` asks whether a representation exists at all (RFC 9110 §13.1.1), and now does.

That is the fifth and sixth time a fix in this project planted the next defect, and the first time the
fix was written here rather than proposed by an agent. The lesson generalises: **a guard justified by
one failure mode has to be checked against the operations it now refuses**, not only against the one
it was written to catch.

**Still open from this pass, and worth deciding on.** Directory enumeration omits every symlink the
same server serves with 200, so through a real mount `mv` returns 0, copies only what was listed, and
then deletes the source — silent loss via the OS's own client. `MOVE`/`COPY` of a *collection*
relocates and duplicates members the allow-list refuses individually, which is the class the eighth
and twelfth passes closed for `DELETE` and the overwrite, at the two verbs they did not reach.
PROPFIND publishes no `getetag` at all, so since the twelfth pass a just-written file has *zero*
validators for a PROPFIND-driven client where it previously had one (an unsealed, useless one) — the
skeptic measured the obvious fix as failing CI. MKCOL on an existing URL answers 500 rather than the
RFC-required 405, breaking the universal "MKCOL each ancestor, treat 405 as already-exists" idiom;
its fix is safe, but the "nearly free" second half — adding `Allow` to OPTIONS — **breaks the trace
runner**, which fails on any header present in the response but absent from the recording. Also:
`PROPPATCH` is 501 while `OPTIONS` advertises `DAV: 1` and the header promises class 1 compliance;
`propname` is refused with 400; unavailable properties get no 404 propstat; `Depth: 0` is refused on
COPY/DELETE of a plain file and MOVE has no Depth check at all; an SSE client that stops reading but
holds its socket open is never reaped; SSE event paths collapse to `/` when the share is reached
through a symlinked ancestor; and `-bonjourName` reports the configured name rather than the
auto-renamed one.

**A record correction that no server-side fix closes.** macOS's WebDAV client fetches a large file as
~99 independent 1 MiB `Range` requests on separate connections. A build republished mid-download
therefore produced a local file that was 20 MiB of build A and 80 MiB of build B — with the server
answering every request truthfully and handing out two distinct ETags. Shape A's in-flight
consistency guarantee holds *within* a response and cannot hold *across* independent requests. The
client, not the server, is the only place that could bind them.

**Verified clean, quantitatively.** litmus `basic` 16/16, `http` 4/4, `locks` 3/3, and 409/204
overwrite semantics exactly right. Through a real mount: 2.3 GB of large writes and 33,269 mixed
operations with zero wrong bytes and 3,290 mount-vs-disk listing comparisons agreeing; 34 hostile
filenames including the NFC/NFD pair round-tripping both ways; **the twelfth pass's dateless-PROPFIND
window is well tolerated by the OS client**, which falls back to `creationdate` — the specific
question that pass could not answer. 316,047 trace-seeded mutated requests produced no crash and zero
"refused but changed" across 176,661 snapshot comparisons. 1,268,184 SSE connection attempts with all
16 slots reclaimed within two ticks, no retain cycle, and Bonjour deregistering 9 Add / 9 Rmv 1:1.

### Twelfth audit pass: the harness reported CLEAN when its verifiers had died

Four more never-used techniques: **filesystem fault injection on real disk images** (ENOSPC,
read-only, case-sensitive, FAT32/FAT16/exFAT, force-eject), **clock and locale manipulation**
(80,384 format/parse round-trips across 6 timezones and 10 non-Gregorian calendars, without ever
touching the system clock), **platform-conditional iOS/tvOS code** — never compiled by any previous
pass — and **declared-contract conformance**, sweeping every nullability annotation and prose
promise in the public headers.

**⚠️ The run first answered `CLEAN — nothing new found`, and that was an artefact.** All five
skeptics died on transient API errors, so the verdict array was empty and `confirmed.length === 0`
evaluated to "clean". The sweeps had found fourteen things. **A workflow that infers "clean" from an
empty array cannot tell *nothing found* from *nothing checked*** — the same shape as the CI run that
reported success for a pre-rebase SHA, and the probe that reported the previous build. Resuming the
run (sweeps replayed from cache, only the skeptics re-ran) produced the real answer: five confirmed.

**A recursive removal that half-succeeded was reported as a total failure.**
`-[NSFileManager removeItemAtPath:]` deletes as it walks and stops at the first member it cannot
unlink, keeping everything it already destroyed. One `chflags uchg` file — what Finder's "Locked"
checkbox sets — or one unwritable subdirectory turned `DELETE /Folder` into **21 files in, 9 left,
status 500**. Through an overwrite it was worse: `403`, destination gutted from 7 files to 1, *and*
the source left in place, so the client has a failed move and a wrecked destination. Default
configuration, both servers. `WSKFirstUnremovableItemAtPath()` now asks before anything is touched.

**⚠️ The proposed fix for it was a no-op — fifth time a proposed fix has been the dangerous part.**
It said to add the check inside `-_firstUnvettableItemAtPath:isDirectory:`, whose first line returns
`nil` when `allowedFileExtensions` is unset — the default, and where every single reproduction lives.
It would have shipped a change that did nothing behind a green suite that proved nothing. The
removability walk has to be unconditional, and is.

**`If-Unmodified-Since` was not read anywhere in the tree.** `grep -rn Unmodified Sources/` returned
zero. So a client that said "only if it has not changed since <date>" against a file newer than that
date had it destroyed and was told the method succeeded — the date-form twin of the `If-Match` gap
the tenth pass closed, at the spelling a date-only client uses. Now evaluated for PUT, DELETE, MOVE
and COPY in RFC 9110 §13.2.2 order. **Note the cap this leaves:** `WSKParseRFC822` reads only the
RFC 1123 form, so the RFC 850 and asctime spellings §5.6.7 also requires a server to accept parse to
nil and the method proceeds. Shared with `If-Modified-Since` and `If-Range` rather than introduced
here — so this closes the common spelling, **not the class**.

**PROPFIND published the validator the GET path refuses to issue**, and FAT's timestamp bucket is
two seconds, not one. See the corrected seventh-pass note above.

**The FAT threshold is a deliberate trade-off, and it is the fail-closed one.**
`WSKLastModifiedDateIsSealed` asks `fstatfs` and allows one second only for `apfs`, `hfs` and
`exfat` (measured at ns, 1s and 10ms); **everything else, including `smbfs`, `nfs` and an
`fstatfs` failure, is assumed two-second**. A FAT volume reached over SMB reports `smbfs` and cannot
be probed from here, and being wrong in that direction splices two builds while being wrong the
other way costs a date-only client one second of caching. The blunt alternative — two seconds
everywhere — closes the same class and costs that second on every volume; flipping to it is a
one-line change if the caching matters more than the SMB case.

**Still open from this pass, deliberately.** `Range: bytes=999999999-` kills a host app that reads
the three properties `WSKFileResponse.h` redeclares non-null: the 416 path returns before setting
them. Not fixed because the skeptic measured the proposed fix as unsafe and it is not reachable in a
default configuration — it needs a handler written the way the header documents. Also open and low:
`+responseWithFile:` is `nullable` but raises for an empty or NUL-bearing path (the same shape the
eleventh pass fixed in `+responseWithJSONObject:`, at a site that fix did not reach);
`WSKRequest`'s non-null address properties are nil on the request a `WSKMatchBlock` builds, so
reading `remoteAddressString` there SEGVs; `addGETHandlerForBasePath:` enforces its undocumented
trailing-slash precondition by aborting with no diagnostic in Debug and registering nothing in
Release; ENOSPC and EROFS answer 500/403 rather than 507; six non-null properties on the uploader
and DAV server return nil, three of them documented as defaulting to nil; the `Server` header
default and the base-path no-match status are both documented wrongly; and a foreground restart
failure on iOS/tvOS is silent.

**Verified clean, quantitatively.** ENOSPC and EROFS across 14 verbs on a genuinely full volume left
no staging residue and no half-files. A case-**sensitive** volume did not weaken containment,
hiddenness or the allow-list across 26 probes. 80,384 date round-trips held across every timezone
and calendar tried, including Buddhist, Islamic, Japanese, Persian and Hebrew — the formatters' pinned
`en_US`/GMT is doing its job. A volume force-ejected mid-transfer produced no crash. iOS and tvOS
Debug and Release all build.

**An orchestration hazard worth remembering: `git stash` is repo-wide, not per-worktree.** One
skeptic stashed its fix to build a comparison and a *different* agent's worktree popped it; a second
skeptic found the fix it was meant to evaluate already applied when it started, and had to revert and
rebuild or it would have measured the fix against itself. Never stash while a fleet is live — copy
the files aside instead.

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
Also carried forward and re-confirmed 10/10 (**closed in batch A of the known-open lows, above**):
`WSKFormatRFC822` before any server exists still
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
handed out and does identify one representation. **⚠️ Correction (twelfth pass): "every date a
client can present" was false for two reasons.** WebDAV `PROPFIND` emitted `<D:getlastmodified>`
with no seal test at all, and since it emits no `getetag` that unsealed date was the *only*
validator a PROPFIND-driven client could obtain — 12/12 splices. And the one-second threshold is
wrong on FAT, which stores mtime in **two-second** buckets and truncates downward, so a timestamp
one second old there can still take another write; 12/12 splices and 12/12 stale 304s on a real
FAT32 image. Both surfaces now share `WSKLastModifiedDateIsSealed`, which asks the descriptor's
filesystem for its granularity. The ETag carries `tv_nsec` and was never
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
browsers fall back to the `.ttf` that ships), and — **closed in batch A of the known-open lows,
above** — `WSKFormatRFC822`/`WSKParseRFC822` are public
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
**closed in batch A of the known-open lows, above** —
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
