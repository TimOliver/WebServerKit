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

### Seventh audit pass: the sixth pass's own diff, and the first real concurrency soak

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
`testIfRangeRefusesADateMintedInsideItsOwnSecond`, which asserts both that no such date is
issued and that one presented anyway is refused; it fails 2/2 against the sixth pass's code.

Not a regression — the pre-fix commit was built and measured and behaves identically. The
defect was in the claim, not the code, which is the more dangerous kind in a file whose purpose
is to be trusted.

**The uploader's asset restructure turned unmatched paths from 404 into 501.** Removing the
catch-all base-path handler left nothing matching `/favicon.ico`, which every browser requests,
so the server answered `501 Not Implemented` — "I do not implement this method", about a method
it implements fine. Inside the scoped asset directories a miss is still correctly 404. This one
*is* a regression from the sixth pass.

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
