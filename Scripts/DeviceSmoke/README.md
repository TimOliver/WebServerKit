# Native iPhone smoke test

This workflow installs a disposable app named **WSK Device Test**, with bundle ID
`com.timoliver.WebServerKitDeviceSmoke`. It serves HTTP uploads and WebDAV from one
new `Documents/Share-<UUID>` directory containing only synthetic fixtures: an
8 MiB `asset.bin` filled with `0x5a`, and `probe-identity.json`. The app refuses to
reuse an existing run directory unless explicitly launched with `--resume-probe-run`
for the interruption tests below. It does not serve the rest of Documents.

The servers use unauthenticated HTTP on OS-assigned ports, advertising `_http._tcp`
and `_webdav._tcp`. Use the intended test Wi-Fi network and keep personal files out
of this dedicated app. The host writes `Documents/probe.json` outside the share;
there is no HTTP metrics or remote-control endpoint.

## Prepare, build, and launch

Run from the repository root on a Mac with Xcode and Python 3.9 or later. Connect
and trust the physical iPhone, enable Developer Mode, and use a signing team that
can provision it. The phone and Mac must share a reachable Wi-Fi network. Allow
the app's local-network permission when prompted.

Replace the three placeholders below. Generate a **new UUID** with `uuidgen` for
each fresh app launch; keep its spelling unchanged in all commands for that run.

```sh
PROBE_DEVICE='<PHYSICAL-IPHONE-UDID>'
PROBE_TEAM='<APPLE-DEVELOPMENT-TEAM-ID>'
PROBE_RUN_ID='<NEW-UUID>'
PROBE_RESULTS="build/device-smoke-$PROBE_RUN_ID"
mkdir -p "$PROBE_RESULTS"

python3 Scripts/DeviceSmoke/prepare.py

xcodebuild \
  -project build/device-smoke-project/WebServerKit.xcodeproj \
  -scheme 'WebServerKit Example (iOS)' \
  -configuration Release \
  -destination "id=$PROBE_DEVICE" \
  -derivedDataPath build/DeviceSmokeDerivedData \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$PROBE_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' \
  PROVISIONING_PROFILE_SPECIFIER= \
  build > "$PROBE_RESULTS/build.log" 2>&1

xcrun devicectl device install app --device "$PROBE_DEVICE" \
  build/DeviceSmokeDerivedData/Build/Products/Release-iphoneos/WebServerKitExample.app \
  --json-output "$PROBE_RESULTS/install.json"

xcrun devicectl device process launch --device "$PROBE_DEVICE" \
  --terminate-existing --json-output "$PROBE_RESULTS/launch.json" \
  com.timoliver.WebServerKitDeviceSmoke --probe-run-id "$PROBE_RUN_ID"
```

Check each command's exit status before continuing. `--terminate-existing` applies
only to this dedicated bundle and is for a fresh run, not a foreground-resume test.
Installing an update does not clear its container; old run directories are left
alone. The app disables auto-lock while active and restores the normal idle timer
when it resigns active or enters the background. Keep the app visible during the
foreground test, without a debugger attached.

Preparation creates a project under `build/device-smoke-project`, reuses the
repository's framework sources, and substitutes the probe controller. It inherits
the shipping iOS example's scene manifest and scene delegate, including support
for the iOS 27 scene requirement. Preparation does not edit the shipping library
or example app.

## Copy the report and run transfers

Wait until the status label shows a Wi-Fi address and both ports. Copy the report
through CoreDevice's app-container service:

```sh
xcrun devicectl device copy from --device "$PROBE_DEVICE" \
  --domain-type appDataContainer \
  --domain-identifier com.timoliver.WebServerKitDeviceSmoke \
  --source Documents/probe.json \
  --destination "$PROBE_RESULTS/probe.json" \
  --timeout 20 --json-output "$PROBE_RESULTS/copy.json"

python3 -m json.tool "$PROBE_RESULTS/probe.json"

python3 Scripts/DeviceSmoke/transfers.py \
  --device "$PROBE_DEVICE" --run-id "$PROBE_RUN_ID" \
  --report "$PROBE_RESULTS/transfers.json"
```

Before starting, the report should identify this UUID and bundle, have `status`
`ready`, `app_state` `active`, and report both servers running. Its
`sample_timestamp` is Unix time in seconds; phone and Mac clocks must agree. The
driver requires samples no more than 15 seconds old and rejects unavailable metrics
or inventory errors. A descriptor value of `-1` means measurement was unavailable,
not zero descriptors.

HTTP traffic uses the phone's **`en0` IPv4 Wi-Fi address** from this report. The
CoreDevice tunnel is used only for installation, launch, and report copies; do not
substitute its address for Wi-Fi. Before any mutation, the driver fetches and
checks `probe-identity.json` through both reported HTTP ports. It rejects a changed
process, run identity, or endpoint during the foreground test.

The bounded workload checks:

- Four incomplete multipart uploads coexist while full and ranged downloads
  complete through both servers; then all four uploads finish. A separate phase
  does the same with four DAV PUTs. Uploads are 1 MiB each and downloads are checked
  against the seeded 8 MiB asset, with SHA-256, length, and range metadata checks.
- Uploads can be read back through the other server. One cancellation per server
  occurs after the report shows its temporary file and open connection.
- Both servers accept the Host name in their advertised Bonjour URL, checked
  over the verified Wi-Fi endpoints. The lifecycle driver repeats this after
  resume. This checks HTTP hostname admission, not client-side DNS discovery.
- DAV named Depth:1 PROPFIND results match the expected inventory and property
  statuses; COPY, MOVE, and DELETE preserve the expected file bytes and names.
- Three successive fresh idle samples show zero connections and reservations,
  matching cumulative accepted/closed counts, no descriptor growth against the
  warmed baseline, the expected share, and the original app-temp inventory.

The server idle timeout is 120 seconds to accommodate report-copy delays while
uploads are held; client transaction deadlines are 60 seconds. Keep-alive is two
seconds. Summary JSON and append-only `.samples.jsonl` files retain the evidence.
The driver attempts cleanup of only its registered `smoke-<UUID>-...` files after
rechecking device and HTTP identity. It leaves the two initial fixtures intact.

This script tests foreground normal traffic on this phone and network. It does not
establish overnight endurance, Windows compatibility, background transfer duration,
Bonjour client discovery, or recovery from injected storage failures.

## Separate lifecycle observation

Do this after the foreground driver has finished, with no debugger attached and
all HTTP clients closed. Allow the framework's one-second disconnect coalescing
interval to settle before backgrounding. Opening Settings provides an ordinary
background transition; reactivate the existing probe without terminating it:

```sh
python3 Scripts/DeviceSmoke/lifecycle.py \
  --device "$PROBE_DEVICE" --run-id "$PROBE_RUN_ID" \
  --report "$PROBE_RESULTS/lifecycle.json"
```

The driver activates Settings, observes both verified listeners becoming
unreachable, then activates the probe again. It verifies the same process and run,
downloads and ranges through both servers, and three idle resource samples. It
attempts to restore the probe to the foreground even if an earlier check fails.

Automatic background suspension is enabled. An idle server closes its listeners;
active transfers may receive a system-granted background interval. The probe timer
stops in the background, so an unchanged report is expected and is not fresh
background telemetry. A transition snapshot can precede the framework's own stop
handler. Do not run the foreground driver while the app is backgrounded.

After reactivation, copy a new report and verify a newer active sample, the same
PID and run ID, and both servers running. The library tries to reuse the previous
ephemeral ports but may fall back if one is unavailable; inspect the new report
and verify both identity fixtures before further traffic. A changed PID is a new
process, not proof of suspension/resume. Record lifecycle observations separately
from the foreground driver's result.

## Active resumable uploads across backgrounding

With the current probe host foregrounded, run this separate **Python client** check:

```sh
python3 Scripts/DeviceSmoke/resumable.py \
  --device "$PROBE_DEVICE" --run-id "$PROBE_RUN_ID" \
  --report "$PROBE_RESULTS/resumable.json"
```

The host gives each run a private session directory outside its share and reports
`resumable_inventory`. The driver acknowledges the first 1 MiB of four synthetic
files, holds their second PATCH bodies after 64 KiB, and checks that downloads and
a DAV listing still finish. It activates Settings with those four connections
open and requires a new UIKit background event and both listeners to refuse new
connections within a bounded 90-second observation. Held sockets use a 180-second
timeout, without the ordinary helper's 60-second shutdown timer. Their partial
bodies receive a small amount of genuine progress immediately before backgrounding
so the observation is shorter than the server's 120-second inactivity timeout.
Network timeouts alone do not satisfy the listener-stop check.

The driver then closes only its own held sockets, activates the same app process,
and requires HEAD to report exactly the acknowledged 1 MiB for every original
upload key. It finishes all four uploads, verifies their full hashes through both
servers, and replays each completed creation request to check that no duplicate
file appears. Cleanup removes its registered files and receipts; three fresh idle
samples must show the original share and temp contents, no remaining sessions
except the root `.lock`, no descriptor growth, and zero connections/reservations.
Cleanup also attempts to restore the app to the foreground after a failed check.

The background report is a lifecycle snapshot, not ongoing suspended-process
telemetry. Listener refusal with held client sockets does not assert that every
accepted socket received EOF. This run covers the native server with a Python
client; the separate real Chrome probe covers browser retry and reselection.
It does not test process termination, device reboot, Windows, or overnight use.

## Protected files across a real lock/unlock cycle

This separate check requires a passcode-enabled physical iPhone and a person to
press its side button and unlock it. Use the preparation, build, and installation
steps above, then launch a **new run** with the additional opt-in flag. Do not run
the other transfer drivers concurrently with this check.

```sh
PROBE_RUN_ID='<NEW-UUID>'
PROBE_RESULTS="build/device-protected-$PROBE_RUN_ID"
mkdir -p "$PROBE_RESULTS"

xcrun devicectl device process launch --device "$PROBE_DEVICE" \
  --terminate-existing --json-output "$PROBE_RESULTS/launch.json" \
  com.timoliver.WebServerKitDeviceSmoke \
  --probe-run-id "$PROBE_RUN_ID" --probe-protected-data

python3 Scripts/DeviceSmoke/protected_data.py \
  --device "$PROBE_DEVICE" --run-id "$PROBE_RUN_ID" \
  --report "$PROBE_RESULTS/protected.json"
```

Keep the app foregrounded and unlocked while the driver prepares the synthetic
upload. Wait for the driver's lock instruction. **With WSK Device Test still
visible, press the side button directly; do not go to the Home screen or another
app first.** Leave the phone locked for **30 seconds**, then unlock it. Enter the
passcode if requested. Do not force-quit or relaunch the app during this cycle;
the driver reactivates the existing process after observing unlock. Its default
wait for this manual sequence is 300 seconds; `--wait-seconds 600` permits a
longer bounded wait. No typed confirmation substitutes for the device evidence.

The driver first verifies both HTTP identities, acknowledges 1 MiB of a
2 MiB + 31 byte upload, and waits for the host to apply `NSFileProtectionComplete`
to that session's manifest and payload. Only those synthetic files are changed;
the library's file-protection policy is unchanged. The session directory's
modification time is deliberately older than the cleanup grace period while the
manifest's real expiry remains in the future. This checks that unreadable live
state is not mistaken for expired or corrupt state.

Before requesting the manual lock, the driver verifies that an incomplete second
PATCH has a live connection and a request temporary file, while its acknowledged
payload remains exactly 1 MiB. It refreshes that body while waiting for the first
lock, then stops writing to the old connection after a fresh background or
protected-data-unavailable event. Suspension may legitimately close that socket.

The opt-in host observes UIKit protected-data notifications and uses a short
background task to record the result. While protected data is unavailable, a
native file open must actually fail with `EPERM` or `EACCES`; a lock notification
alone is insufficient. A bounded loopback HEAD to the host's own uploader must
return retryable HTTP 500, retaining both the manifest and the 1 MiB payload.
The held PATCH keeps the normal server's background interval active for this
probe. This in-app request does not depend on Wi-Fi remaining usable while locked.
Background execution time remains system-controlled. Backgrounding the app before
actually locking the phone can consume the observation window. Lifecycle events
record protected-data availability and the remaining background-time estimate;
an expired observation is **inconclusive**, never evidence that protected files
stayed readable while the process was suspended. A physical pass still requires
the actual denied open and retryable response.
The synthetic report uses protection that permits recording the denial after the
phone's first unlock; no served file or upload payload gets that exception.

On unlock, the saved manifest and protocol HEAD must both report the original
1 MiB offset and upload key in the same process. The driver finishes the upload,
checks the complete SHA-256 through HTTP and WebDAV, and replays the completed POST
without creating a duplicate file. It deletes its file and receipt, then requires
three fresh idle samples with the original share and temp inventory, no session
state except the closed root `.lock`, zero connections and memory reservations,
matching accepted/closed counts, and no descriptor growth from the warmed baseline.

The report contains `armed`, `held_before_lock`, `locked_probe`, `unlocked_probe`,
`published`, and `final` evidence, with raw snapshots in `.samples.jsonl`. CoreDevice
report copying may be unavailable while locked; such copy failures are recorded
but never count as proof of file-protection denial. Cleanup attempts to foreground
the same app and remove only the registered synthetic upload. If the phone remains
locked or cleanup fails, preserve the failed report before the ordinary disposable
app cleanup described below.

Run the offline lifecycle-oracle checks without a device:

```sh
python3 Scripts/DeviceSmoke/test_protected_data.py
```

These checks cover resumed snapshots with a closed old socket, observed background
and protected-data transitions, and propagation of a connection failure before
backgrounding. They do not establish a physical-device pass. A successful physical
report covers the native server with a Python client and a bounded in-app probe;
it does not establish browser-on-device behavior, process restart or reboot,
protection-policy preservation across arbitrary app edits, Windows compatibility,
Wi-Fi loss/rejoin, overnight endurance, or a guaranteed background execution time.

## Wi-Fi loss and abrupt app restart

`interruptions.py` saves 1 MiB of each of four resumable uploads and retains a
separate completed upload receipt. It also saves the first 64 KiB and strong ETag
of a download through each server. Each mode must recover the same four upload
keys/offsets, resume both downloads with `Range`/`If-Range` and exact full hashes,
finish the uploads concurrently, and replay the completed requests without
creating duplicate files. This uses a Python client; it does not establish that
a browser can find origin-scoped resume records after the address or port changes.

Build/install as above. For every mode, generate a new run UUID, launch the app
normally with `--probe-run-id`, then run:

```sh
python3 Scripts/DeviceSmoke/interruptions.py \
  --device "$PROBE_DEVICE" --run-id "$PROBE_RUN_ID" \
  --mode crash-between-chunks \
  --install-record "$PROBE_RESULTS/install.json" \
  --report "$PROBE_RESULTS/interruption.json"
```

The three modes are:

- `crash-between-chunks`: issue SIGKILL after acknowledged prefixes are saved,
  with the two downloads incomplete. No request body is being received at the
  selected kill point.
- `crash-active-body`: kill with four real incomplete PATCH bodies, each sent
  after the acknowledged prefix. The pre-kill sample must show all four request
  temporary files and saved payloads. This additionally checks the documented
  request-spool cleanup gap; it does not implement its fix.
- `wifi`: hold four PATCH bodies while the user disables Wi-Fi. **Connect USB
  first**, so app-container reports remain accessible without Wi-Fi. When asked,
  turn Wi-Fi off in Settings and return to WSK Device Test with Wi-Fi still off.
  Wait for the restore instruction, then re-enable Wi-Fi, join the same network
  and return to the app. Each manual wait is bounded by `--wait-seconds` (default
  600, maximum 600). Keep the phone unlocked. No Mac network settings are changed.

Wi-Fi loss requires fresh snapshots from the same live app process, foreground
serving with no `en0` IPv4 address, and failed connections to both previously
verified Wi-Fi endpoints. A timeout, a suspended listener, or a verbal confirmation
alone is insufficient. The driver then accepts new endpoints only from the fresh
same-process container report and rechecks both HTTP identities before resuming.
Settings transitions also exercise normal background/foreground behavior, so the
test does not attribute every old-socket closure exclusively to network loss.

Crash modes require the installation JSON from this exact app installation. The
driver matches the current PID/executable to that record before SIGKILL, checks
that the old PID is gone, and launches only the dedicated bundle with the original
run UUID and `--resume-probe-run`. A new PID and launch UUID, a fresh report and
explicit existing-run mode are required. The host validates the existing run's
identity and fixture types/sizes; it preserves the asset inode/bytes and private
session directory instead of recreating them. This simulates abrupt process death;
it is not evidence of a naturally occurring crash, jetsam-specific behavior or a
device reboot. Host production background policy is unchanged.

Reports distinguish `recovery_passed`, `cleanup_passed`, and overall `passed`.
All three must be true for a clean pass. Cleanup requires three fresh idle
samples with no connections/reservations, matching accepted/closed counts, no
descriptor growth, no remaining sessions/receipts, and the original temp inventory.
Crash residue is never silently adopted as a new baseline. An active-body kill
can currently recover every file successfully yet fail overall because orphaned
request spools remain. Preserve that failure evidence for the separate cleanup
work; cleanup by removing the disposable app is not a library cleanup pass.

Offline negative controls run without a phone:

```sh
python3 -B -m unittest discover -s Scripts/DeviceSmoke -p 'test_*.py'
```

## Finish and remove the disposable app

Preserve reports before cleanup. The transfer driver does not stop the app. Confirm
the current process still belongs to `com.timoliver.WebServerKitDeviceSmoke` before
terminating its PID; never reuse an old report's PID without checking it against
the current process listing.

```sh
xcrun devicectl device info processes --device "$PROBE_DEVICE" \
  --json-output "$PROBE_RESULTS/processes.json"

xcrun devicectl device process terminate --device "$PROBE_DEVICE" \
  --pid '<CURRENT-VERIFIED-PROBE-PID>'

# Optional: remove only the dedicated test app and all of its synthetic run data.
xcrun devicectl device uninstall app --device "$PROBE_DEVICE" \
  com.timoliver.WebServerKitDeviceSmoke
```

If HTTP cleanup could not complete, stop the identified probe and remove this
dedicated app after saving the evidence. No cleanup step needs access to another
app's container, personal files, or device-wide temporary storage.

## Recorded run: 2026-09-30

A signed Release host on an iPhone Air running iOS 27.0 (24A437), built with the
iOS 27.1 SDK, passed using the Mac Python client over the phone's actual Wi-Fi
IPv4 address. The production changes were `80e64d4` and `714b034`.

- Foreground: 57 completed requests, 10 uploads including two warmups, two
  cancellations, four exact DAV listings, and 63,700,992 hash-verified download
  bytes. Four held multipart uploads and four held DAV PUTs were tested in
  separate phases; both phases allowed simultaneous full and ranged downloads.
- Idle background/resume: 16 completed requests and 34,078,720 verified bytes.
  Both listeners refused new connections in the background; the same process
  resumed on the same ports. Advertised Bonjour Host names returned 200 before
  and after resume.
- Across both phases, all 75 accepted connections closed. Idle descriptors
  stayed at 11, memory reservations returned to zero, and the only remaining
  shared files were the two original fixtures. No app-temp residue remained.
- The complete ASan unit suite passed all 303 tests; Objective-C lint passed.
  Both new hostname regressions failed against their preceding implementations
  in isolated source snapshots. This run did not repeat the entire multi-platform
  `Run-Tests.sh` gate.

The first launch exposed a synchronous `NSProcessInfo.hostName` DNS wait: iOS
terminated the app with a scene-create watchdog after 19.96 seconds. Startup now
uses bounded `gethostname` instead. A compatibility follow-up found that iOS's
advertised Bonjour hostname differed from its kernel hostname; the existing
asynchronous Bonjour success callback now publishes that name through a locked,
immutable snapshot before notifying the delegate. Stale callbacks cannot publish
names for a replacement listener. DNS-derived aliases that are neither the kernel
hostname nor the app's advertised target still need `WSKOption_AllowedHostNames`.

The unadapted example-based host also failed iOS 27's scene lifecycle requirement.
The shipping iOS example has since adopted a single-window scene with its existing
Main storyboard. The generated probe now inherits that configuration directly.
See [Apple's scene migration guidance](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle).

Raw summaries and samples are local ignored artifacts at
`build/native-device-transfers.json` and `build/native-device-lifecycle.json`.
Preserve them before running `Run-Tests.sh`, which clears `build`. Windows clients,
active transfers across background suspension, permission denial/recovery, Wi-Fi
loss/rejoin, and overnight device endurance remain outside this run's coverage.

## Recorded active-upload run: 2026-10-01

The signed Release host built from production tip `5d5e032` passed on the same
iPhone Air / iOS 27.0 (24A437), using Xcode 27.1 and the Mac Python client over
Wi-Fi. The host inherited the shipping example's scene configuration, confirming
physical scene launch and same-process foreground recovery.

- Four uploads each saved 1 MiB, then held their second PATCH bodies after 64 KiB.
  Full and ranged downloads through both servers and a DAV listing completed
  while all four partial bodies remained present.
- A fresh UIKit background callback recorded the active connections. Both
  listeners refused connections 27.68 seconds after requesting Settings activation, before
  the 120-second idle timeout and while all four client sockets were still open.
  The client closed those incomplete requests only after observing refusal.
- The same process resumed on the same ports. All four original upload keys
  reported exactly 1 MiB; concurrent completion produced four exact files whose
  hashes matched through both servers. Replaying completed POSTs produced no
  duplicate names. The run completed 83 requests and checked 59,310,228 bytes.
- Three fresh final samples showed zero connections and reservations, idle
  descriptors 11→11, and no app-temp files, sessions, or receipts except the closed
  root `.lock`. Only the two original shared fixtures remained. Final cumulative
  accepted/closed counts were 126/126. The dedicated app was stopped after verification.

No production change was required. The device build, driver syntax/import check,
and independent driver review passed. This harness-only follow-up did not repeat
the full multi-platform test gate already recorded for `5d5e032`.

Evidence is in
`build/device-resume-B607C4B2-CC07-4451-9EEF-4F2E8A269B2D/`, including
`resumable.json`, `resumable.samples.jsonl`, and the background callback snapshot.
Preserve this directory before running `Run-Tests.sh`, which clears `build`.
This run uses a Python client; real Chrome retry/reselection has separate
coverage. It does not establish browser-on-device behavior, server-side EOF on
every accepted socket, process termination, reboot, Windows compatibility,
Wi-Fi loss/rejoin, or overnight endurance.

## Recorded protected-file run: 2026-10-01

Run `ABF06AD3-4946-473D-B89C-0CF7C8472509` passed on the iPhone Air / iOS 27.0
(24A437), using the signed Release host and the Mac Python client. The production
store matched `44f0bed`; the subsequent empty-PATCH validation correction does not
affect this nonempty-file scenario. Source hashes are retained with the build.

- The session saved 1 MiB before its manifest and payload received complete
  protection. While locked, opening the manifest actually failed with `EPERM`.
  Native loopback HEAD returned 500, retaining the manifest and 1 MiB payload.
- Unlock recovered the same key and exact 1 MiB offset in the same process.
  Completion produced the expected 2 MiB + 31 byte file, verified through HTTP and
  WebDAV. Repeating POST produced no duplicate. The client completed 24 requests
  and verified 21,233,726 download bytes.
- Final idle descriptors were 13→11, connections/reservations were zero, and all
  26 accepted connections closed. Only the original fixtures and the closed root
  `.lock` remained; no request-temp files, partial sessions or receipts remained.
  The identified dedicated app was stopped after cleanup.

Earlier attempts are retained as failed evidence: one observed actual denial but
hit a driver write to a socket closed during backgrounding; another exhausted its
background observation interval after leaving the app before locking. Neither was
counted as an end-to-end pass. The final driver checks stored lifecycle proof
before touching the old connection and never refreshes it after backgrounding.
Expired host observations are inconclusive, not evidence that files stayed readable.

Reports, raw samples, build/source hashes and cleanup proof are outside the gate's
disposable `build` directory:
`/private/tmp/wsk-recovery-hardening-evidence/device-ABF06AD3-4946-473D-B89C-0CF7C8472509/`.
The scope limits in the protected-file section above still apply.

## Recorded abrupt-restart runs: 2026-10-02

Both modes ran on iPhone Air / iOS 27.0.1 (24A446), with the signed Release probe
and unchanged production library `1a327bd`. The new host explicitly reopened its
existing synthetic directories. Both old-process exits were verified, both new
PIDs/launch UUIDs were confirmed, and fixture bytes were not recreated.

- **Between chunks: passed.** Run `F56CF7AB-E0D1-49D0-85D6-927CF3A8400A` recovered
  all four original 1 MiB upload prefixes and a previously completed receipt.
  Both interrupted downloads returned 206 with their original ETags and exact
  assembled hashes. All uploads completed and replayed without duplicates.
  The final process had 11 descriptors versus the old warmed baseline's 14,
  zero connections/reservations, accepted/closed counts 51/51, and no residual
  requests, sessions or receipts. This tests abrupt death between chunk requests.
- **During four incomplete bodies: recovery passed, cleanup failed.** Run
  `53C39190-1425-4422-B9A9-35EEB094DF57` completed the same recovery checks, but
  four 64 KiB request spools survived process death. Their names matched the
  pre-kill inventory, and copied bytes exactly matched the four synthetic PATCH
  prefixes. Final descriptors were 11 versus baseline 13, connections/reservations
  zero and accepted/closed 51/51; persistent sessions and receipts were cleaned.
  The driver returned failure rather than treating orphaned spools as a pass.

Each mode completed 75 client requests and verified 59,113,620 download bytes.
The active-body residue is the previously documented incomplete-request crash
window; its production fix is deferred to the separate cleanup work. After all
evidence and the four spool contents were saved on the Mac, only the disposable
test app was removed to clear its synthetic container. This fixture teardown
does not change the failed library cleanup result.

The signed build and all nine offline device-oracle tests passed. Stricter
pre-kill presence/type guards added to the driver after these runs were also
applied to the saved snapshots and passed; no repeat physical run is claimed.
No production or browser code changed, so this work did not repeat the full
library test gate. The subsequent Wi-Fi runs are recorded below.

Evidence: `/private/tmp/wsk-device-interruptions-20261002/`, including both
`report.json` files, raw samples, command evidence, `spool-ownership-proof.json`,
the four retained synthetic spools, and the fixture teardown record.

## Recorded Wi-Fi interruption runs: 2026-10-02

The diagnostic repeat **passed recovery and cleanup** on the same iPhone Air /
iOS 27.0.1, with unchanged production library `1a327bd`. Run
`BE0B845F-30C1-4ABD-89EC-2E6A2F45C84E` held four partial PATCH bodies and two
partial downloads. Two advancing USB snapshots confirmed the same active process
had no Wi-Fi address while both servers remained running; bounded attempts to
both old Wi-Fi ports timed out. After rejoining, the process, IPv4 address and
server ports were unchanged. The Settings transitions also exercised app
background/foreground handling; this is not an isolated radio-only test.

All four uploads retained their original keys and acknowledged 1 MiB offsets,
then completed concurrently with exact hashes over HTTP and WebDAV. Both
downloads resumed using the original ETags, returned 206, and matched their full
hashes. The pre-existing completion receipt survived; retries produced no
duplicates. The run verified 59,113,620 download bytes in 75 client requests.
Three fresh final snapshots showed zero connections/reservations, accepted/closed
counts 81/81, no request temporary files or saved sessions/receipts, and descriptors
13→11. Every final descriptor matched an entry in the warmed baseline: three
standard streams, four listener sockets and four existing Unix-domain sockets.
No transferred asset, request spool or accepted client socket remained open.

An earlier full recovery run, `D0843FCF-B17A-4D6C-9F7B-01B53792AEA0` in `wifi-live2/`,
passed all transfer checks but **failed cleanup** because descriptors rose 11→12.
Connections, reservations and file/session inventories were clean. The extra
descriptor was still present in a later snapshot. That build recorded only a
count, so its ownership remains unexplained; the diagnostic repeat does not
retroactively turn that result into a pass. The test host now records descriptor
paths, file identities and numeric socket endpoints without opening a counting
descriptor. No production fix or baseline exception was introduced.

Earlier attempts are retained too: `wifi/` rejected Python 3.9's distinct
`socket.timeout` exception and tried to parse an absent Wi-Fi address during
failure cleanup. Both driver checks were corrected; all 11 offline oracle tests
passed. `wifi-repeat/` expired its ten-minute manual wait before the switch-off
and also failed its final descriptor-count check. `wifi-live/` rejected a manually
launched session with the wrong run ID before sending transfers. Fresh launches
use `--terminate-existing` and verify the requested run ID before starting the
driver. None of these attempts counts as an outage/recovery pass.

The signed diagnostic build passed. Evidence is under
`/private/tmp/wsk-device-interruptions-20261002/`, including `wifi-diagnostics/`'s
report, original samples, source hashes, independent validation and app teardown.
Only after saving the evidence was the dedicated synthetic test app removed.
These runs do not cover a changed IP address, browser-origin migration, Windows
clients or repeated overnight network cycling. The four request spools surviving
active-body process death remain the separate, deferred production cleanup fix.
