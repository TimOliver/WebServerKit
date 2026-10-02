# Resumable browser uploads

The uploader page sends up to four files concurrently, one 1 MiB request per file
at a time. Before starting, it hashes each selected file incrementally with SHA-256;
this also identifies the exact file when the user selects it again after a reload.
The implementation works on ordinary HTTP LAN pages without Web Crypto or persistent
filesystem-access permissions. Hashing and upload reads use bounded slices.

A disconnected browser waits and queries the server's confirmed offset before
sending more data. It never treats bytes handed to the network as saved bytes.
Repeated failures back off to 30 seconds and eventually show Retry. Authentication,
permission, and capacity errors pause for user action. Closing the page leaves a
saved session; select the same file in the same folder and browser origin to resume.
Private browsing or denied local storage limits recovery to the current page.

Server sessions survive listener stop/start and recreation of the uploader with the
same share and session directory. The default directory is under the app's cache,
outside the share and keyed by its current resolved path. Cache eviction can remove
unfinished sessions. Hosts can set `resumableUploadDirectory` before starting to
choose another private directory outside the share. Browser records are origin-specific:
use the original device URL to resume a saved session after reopening the page.
Retargeting a shared symlink selects a different default store.

The default lifetime is 24 hours since successful progress. Set
`resumableUploadTimeout` before starting to change it. HEAD does not extend it.
Expired files in the current store are cleaned on session access and every 30 seconds
while the uploader is running. Startup also checks an existing store, including a downloads-only run.
No cleanup can execute while the host app is suspended or terminated; it runs when
the app is executing again. Cancellation deletes the partial session; failed
cancellation leaves a bounded cleanup record for the next page visit.

## Publication and bounds

Only complete, hash-verified files reach the share. Publication copies into private
staging outside the share, then uses an exclusive atomic rename. When the session
and destination are on the same volume, staging is a `.stage-<UUID>` file inside
the existing private session directory. Recovery and periodic maintenance remove
unjournaled regular files in that reserved namespace; they do not follow symlinks
or walk staging directories. A session on another volume uses Foundation's
replacement directory on the destination volume instead.

Existing names use the uploader's normal unique-name behavior, and its extension,
hidden-file and `shouldUploadFileAtPath` policy applies again at completion. The
existing multipart `/upload` endpoint remains available. WebDAV PUT semantics are
unchanged; this feature is for the browser upload interface.

Resumable publication requires a destination volume that supports exclusive atomic
renaming. A volume reporting that this capability is unavailable is refused with
HTTP 501 before a session receives file bytes. Unknown capability is checked by the
final rename; an unsupported result also returns 501, and the browser pauses with
a filesystem message. Some macOS FSKit exFAT volumes do not support this operation.
The existing multipart `/upload` API remains unchanged. There is no automatic
fallback that exposes an empty or partially written destination file.

Each completed chunk is saved before its offset is acknowledged. Interrupted
request bodies do not advance the session. A publication journal and bounded
completion receipts let a reconnect discover that a final upload already succeeded,
even after a server process restart. This avoids publishing a second copy when the
last response is lost. Delegate/SSE delivery remains an in-process notification;
a process exit or receipt-save error between publication and notification does not
replay the callback. Recovery can confirm the published file even when that
notification was lost.

A temporary manifest read failure, including protected storage being inaccessible
while an iPhone is locked, preserves the saved session and returns HTTP 500 for a
later retry. The server also refuses new admission when it cannot read existing
sessions' reserved lengths. If it cannot inspect the final file's identity during
publication recovery, it retains the publication journal and returns HTTP 500;
inability to inspect a file is not treated as evidence that publication failed.
After storage becomes accessible, HEAD can report the original saved offset or
confirm that publication already completed.

An interrupted empty-file creation also retries publication when the original
session is recovered. POST or HEAD reports offset 0/length 0 only after the empty
file has actually been published. Current destination policy still applies, and
an existing completed receipt does not publish a second copy.

Once the store has opened and checked a fully received PATCH body, it removes the
request temporary filename while keeping its read descriptor. Process exit during
subsequent append or publication therefore cannot strand that request spool. The
same-volume staging name remains recoverable even before its journal is saved.
These protections do not cover every possible process-exit point: termination
during HTTP body reception, before the store opens that body, can still leave an
ordinary request temporary file. For a cross-volume upload, an exit between creating
the Foundation replacement directory/staging file and saving its publication
journal can still leave an untracked Foundation temporary item outside the share.
Recovery cannot safely reclaim an outside item it never recorded. Normal request
cleanup closes files and sockets, and process exit releases held descriptors.
Request-body files created by this version use the reserved
`WebServerKit-body-v1-<pid>-<UUID>` namespace and owner-only permissions. Each
server start reclaims regular, singly linked files owned by the current user only
when the creating PID is confirmed absent. Files belonging to live or reused
PIDs, uncertain process checks, links, directories, unrelated files and legacy
unmarked request files are retained. This uses no age threshold and holds no
extra descriptors during normal serving. A process reusing a dead creator's PID
can therefore conservatively postpone reclamation until a later server start.

`interrupted_bodies.py --report <unused-path>` verifies process-death cleanup for
four partial resumable PATCH bodies, WebDAV PUT and multipart upload, while a
second process uses the same temporary directory. Recovery must preserve that
live peer's body, allow it to finish with exact bytes, preserve the four saved
offsets and complete their files concurrently without temporary/session residue.

The protocol does not promise durability across power loss or storage failure.

Limits are 8 GiB per file, 32 unfinished sessions and 32 GiB of their declared
lengths per store. The store retains 128 completion receipts, with a bounded
transient allowance for concurrent completions awaiting exclusive cleanup. The
oldest completed receipts can be evicted. Final publication also needs space for its staging copy.
Session storage retains no descriptors or locks between operations. Existing
server timeout and keep-alive rules govern sockets. A missing/expired receipt
asks the user to select the file again rather than silently publishing a duplicate.

## HTTP profile

This is a tus 1.0 based application profile, not resumable WebDAV PUT. It supports
creation, expiration and termination, with required destination metadata and an
idempotency key. Clients must limit each PATCH to 1 MiB.

| Request | Contract |
| --- | --- |
| `OPTIONS /uploads` | Capabilities, no session mutation. |
| `POST /uploads` | No body. `Tus-Resumable: 1.0.0`, `Upload-Key` UUID, decimal `Upload-Length`, and `Upload-Metadata`. Returns 201 and relative `Location`. |
| `HEAD /uploads/<key>` | Returns 200, `Upload-Offset`, `Upload-Length`, `Upload-Expires`, and `Cache-Control: no-store`. |
| `PATCH /uploads/<key>` | `Content-Type: application/offset+octet-stream`, decimal `Upload-Offset`, and up to 1 MiB of bytes. Returns 204 and the new offset. |
| `DELETE /uploads/<key>` | Deletes the session/receipt, never the published file; returns 204. |

All session requests carry `Tus-Resumable: 1.0.0`. Metadata fields are `filename`,
`path` (share-relative folder), and `sha256` (64 lowercase hexadecimal characters).
Each metadata value is base64-encoded UTF-8, following tus metadata syntax. Repeating
a POST with the same key and identical metadata returns the same session. A reused
key with different metadata or a mismatched PATCH offset returns 409. Missing or
expired sessions return 404 or 410; unsupported protocol versions return 412; limits
return 413; a final content-checksum mismatch returns 422; unsupported atomic
publication returns 501.

The reported offset equals the length only after successful final publication.
The browser deletes a completion receipt after observing success. Host validation,
authentication, and same-origin checks apply to session operations as to the rest
of the uploader. No cross-origin upload API is enabled.

## Validation

`node Scripts/test_resumable_upload.js` compares the incremental hash with Node's
crypto implementation and exercises the client state machine with controlled
transport outcomes. It is included in `Run-Tests.sh`, together with the native
session/publication tests.

The browser integration driver uses a newly launched headless Chrome, a local
reverse proxy, and its own synthetic-data EnduranceHost. The proxy preserves a
stable browser origin while the owned host process is restarted. Run it with the
built host and test-only temporary-directory library; see `browser-probe.mjs --help`.
It requires the `playwright` Node module and macOS Google Chrome. Set
`WSK_PLAYWRIGHT_MODULE` to use a separately installed module, or
`WSK_CHROME_EXECUTABLE` to select another Chromium executable.
This establishes browser/network recovery on macOS. Physical iPhone background
suspension and locked protected-data access are separate device checks; see
[DeviceSmoke](../DeviceSmoke/README.md). Loopback results do not establish device
suspension behavior.

### Storage failures and process exits

The recovery driver builds and owns a disposable macOS loopback host, private
session/share directories, and a test-only syscall interposer. Its 26 cases cover
payload append and staging-copy write failures, fsync/close errors, manifest
write/fsync/close/rename failures, publication rename errors, and deterministic
process exits at payload, staging, journal, rename and completion-receipt boundaries.

Each case starts with an acknowledged 1 MiB prefix and an existing destination.
The report requires proof that the selected fault fired exactly once against the
owned file. It checks the authoritative offset and payload bytes, then retries and
verifies complete SHA-256 hashes through both HTTP and WebDAV. The original file
must retain its inode and bytes, only one new filename may appear, and final idle
checks require baseline descriptors, zero connections/reservations, and no request,
staging or session residue beyond the store's closed `.lock` file. Exit cases
restart the owned process; error cases keep it running. These are injected syscall
failures, not physical volume exhaustion or power-loss tests.

```sh
python3 -m unittest discover -s Scripts/ResumableUploads -p 'test_*.py'
python3 Scripts/ResumableUploads/recovery.py --report build/resumable-recovery.json
```

Use `--case exit-stage-open` to run one boundary, or repeat `--case` for a subset.
The offline tests reject missing/mis-scoped fault proof and invalid endurance
oracles. `Run-Tests.sh` includes these checks, the full recovery matrix and a short
endurance run. It deletes `build` at startup, so copy reports elsewhere before
running the full gate if they need to be retained.

### Concurrent endurance

The endurance driver runs four resumable uploads while both servers complete
hash-checked full and range downloads. It holds four real PATCH bodies open and
requires complete downloads during that overlap window. Repeated rounds include
interrupted-body cancellation, listener stop/start with saved offsets, completion
receipt churn beyond 128 receipts, and admission recovery after filling the 32
active-session limit. Listener restarts preserve the same host process.

Expiry phases abandon four sessions with a short configured lifetime, then issue
only downloads while the real 30-second maintenance timer removes them. Filesystem
observations and stdin metrics do not invoke a session endpoint, so HEAD or another
upload cannot accidentally perform the cleanup being tested. An optional large-file
phase uploads four larger files concurrently and streams their verification through
both servers. Its synthetic source bytes are retained by the Python client; this
measures server behavior, not browser memory usage.

```sh
python3 Scripts/ResumableUploads/endurance.py --duration 30 \
  --report build/resumable-endurance.json
python3 Scripts/ResumableUploads/endurance.py --duration 1200 \
  --large-file-mib 64 --receipts 136 --expiry-every 120 \
  --report /private/tmp/resumable-endurance-long.json
```

`--duration` controls the mixed workload; setup, receipt churn, the optional large
files and the final maintenance window take additional time. Reports include the
actual elapsed time, source/binary hashes, overlap windows, expiry evidence, and
idle resource samples. Descriptors, live connections and reservations are checked
against fixed ownership expectations. Live allocator bytes and physical footprint
have separate stated allowances and are reported separately from retained allocator
capacity. A bounded run cannot establish overnight stability or exclude a slow leak.

Both drivers accept an already-built host: supply `--host` and
`--temporary-library`; recovery additionally requires `--fault-library`. Otherwise
they build their own fixture. They accept no external server URL, modify only their
synthetic directories, and stop their owned child at completion. Use `--help` for
bounded workload and diagnostic options.

### Recorded recovery and endurance: 2026-10-01

The 26-case storage/process-exit matrix passed. The mixed endurance phase ran for
1,200.60 seconds (1,258.89 seconds including setup and final cleanup), with:

- 3,409 completed uploads, 613 cancelled uploads, and 16 expired sessions removed
  during four downloads-only maintenance windows.
- 212 listener restarts and 816 resumed uploads in one process.
- 23,659 verified downloads, including 7,968 ranges and 34,455,224,322 bytes.
  A separate phase completed four concurrent 64 MiB files through both servers.
- 136 receipts created and the newest 128 retained before explicit deletion.
- Final descriptors 7→7, zero connections/reservations, all 63,523 accepted
  connections closed, and no partials, receipts, staging or request-temp residue.

Live allocator bytes increased by 35,344; physical footprint increased by
21,282,816 bytes and reserved allocator capacity by 33,554,432 bytes. Live bytes and
footprint were not monotonic across idle samples. These measurements passed the
stated bounds; they do not prove the absence of a slow leak.

The long run used the nonempty-file recovery implementation in `9b08d3c`, before
the later empty-file-only corrections. Its source and binary hashes are recorded.
The initial harness allowed retained completion receipts at idle; the stricter
final-inventory oracle was subsequently applied to the saved report and passed
with every session inventory empty. The checked-in harness requires this directly.
The final full test gate separately exercises the final source and updated harness.

The full gate passed against frozen production tip `a6892a6`: 330 ASan tests,
all eight trace suites, all three platform Release builds, both Swift consumers,
browser-state checks, existing endurance/storage checks, the 26-case resumable
matrix, 14 resumable and four device-oracle tests, and the updated endurance smoke.
Recorded gate source hashes matched the working source at completion.

Evidence is retained outside the gate's disposable `build` directory under
`/private/tmp/wsk-recovery-hardening-evidence/`: `endurance-20min-final.json`, its
samples/log, and `endurance-final-inventory-check.json`. Physical protected-file
recovery has separate recorded evidence in the DeviceSmoke README.
