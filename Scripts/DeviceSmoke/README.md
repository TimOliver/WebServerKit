# Native iPhone smoke test

This workflow installs a disposable app named **WSK Device Test**, with bundle ID
`com.timoliver.WebServerKitDeviceSmoke`. It serves HTTP uploads and WebDAV from one
new `Documents/Share-<UUID>` directory containing only synthetic fixtures: an
8 MiB `asset.bin` filled with `0x5a`, and `probe-identity.json`. The app refuses to
reuse an existing run directory. It does not serve the rest of Documents.

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
repository's framework sources, and substitutes the probe controller. Its scene
manifest and minimal scene delegate support current iOS SDKs, including the iOS 27
scene requirement. These adaptations affect only the generated host; preparation
does not edit the shipping library or example app.

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
The generated probe adopts scenes; the shipping iOS example still needs that
migration. See [Apple's scene migration guidance](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle).

Raw summaries and samples are local ignored artifacts at
`build/native-device-transfers.json` and `build/native-device-lifecycle.json`.
Preserve them before running `Run-Tests.sh`, which clears `build`. Windows clients,
active transfers across background suspension, permission denial/recovery, Wi-Fi
loss/rejoin, and overnight device endurance remain outside this run's coverage.
