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

Only complete, hash-verified files reach the share. Publication uses a temporary
replacement directory outside the share, on the destination volume, followed by an
exclusive atomic rename. Existing names use the uploader's normal unique-name
behavior, and its extension, hidden-file and `shouldUploadFileAtPath` policy applies
again at completion. The existing multipart `/upload` endpoint remains available.
WebDAV PUT semantics are unchanged; this feature is for the browser upload interface.

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
The protocol does not promise durability across power loss or storage failure.
There is also a narrow process-exit window between creating the Foundation
replacement directory/staging file and saving its publication journal. An exit
there can leave an untracked Foundation temporary item outside the share; session
recovery cannot reclaim an item it never recorded. Ordinary request cleanup closes
its files and sockets, and process exit releases all held descriptors.

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
This establishes browser/network recovery on macOS. Actual iPhone suspension and
background-task expiration still require a physical-device run.
