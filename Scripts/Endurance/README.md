# Endurance checks

Run from the repository root on macOS with Xcode's command-line tools and Python 3.9 or later:

```sh
python3 Scripts/Endurance/run.py
```

The runner builds a Release host with SwiftPM, creates private directories, and starts
the uploader and WebDAV server on loopback ports. It accepts no target URL. The host,
its server instances, and its resource counters survive every continuous-serving round.
Temporary files and the child process are cleaned up on success, failure, and Ctrl-C.
JSON summaries, append-only JSONL resource samples, and host logs remain under `build/`.
Use `--report /path/to/report.json` to choose their location.

Each round checks:

- Four multipart uploads and, separately, four WebDAV PUTs. Their incomplete bodies
  must coexist on the server, with temporary files present; multipart arguments must
  also reserve memory. Downloads through both servers must finish before the uploads
  are released. Merely submitting four client jobs is insufficient.
- SHA-256 and length of stored uploads and downloaded content, including reused GET
  connections, interrupted downloads resumed with `Range`/`If-Range`, and an atomic
  file replacement that requires a full response instead of splicing two versions.
- Cancellation after each upload type has actually started writing a temporary file.
  No cancelled destination, hidden staging file, or temporary upload may remain.
- Zero connections and reserved bytes at rest, matching cumulative open/close counts,
  and no descriptor growth against a fixed baseline. Three consecutive clean samples
  are required; settling has a deadline. Process memory uses `phys_footprint`, with a
  configurable 64 MiB allowance for allocator caching rather than requiring exact recovery.

One warmup round and restart exercise all paths before baselines are fixed. Counts and
verified bytes in the report include warmup; `cycles` and `continuous_seconds` cover
only the subsequent continuous-serving phase. After that phase, five lifecycle rounds
stop and restart the same servers on the same ports. Partially consumed downloads must
finish after stop; they may already be buffered in the kernel, so this does not prove
that a server write was pending at the instant of stopping. Stopped and running
descriptor baselines are separate and neither is rebased during the measured run.

For an eight-hour run with no measured restarts:

```sh
python3 Scripts/Endurance/run.py --duration 28800 --restart-cycles 0 --report build/overnight.json
```

The default payloads are 2 MiB per upload and 8 MiB per download. A round transfers
more than 100 MiB, so long runs write substantial data even though temporary disk
usage stays bounded. `--pause` controls the delay between rounds; `--upload-mib` and
`--asset-mib` control payload size. Duration is a minimum: the current round finishes
before shutdown. Socket inactivity and transaction deadlines are 15 seconds, and
resource cleanup gets another bounded settling window. Choose payload sizes that can
finish within those deadlines on the test machine.

`Run-Tests.sh` includes a small smoke run and fault fixtures proving the checksum,
length, status, resource, and residual-file checks reject incorrect results. Longer
runs are explicit; no background task or scheduled job is installed. Do not overlap
the full validation gate with an endurance run, which can distort timing tests.

## Temporary directory isolation

Foundation on macOS does not honor `TMPDIR` for `NSTemporaryDirectory()`. A tiny
test-only dylib redirects that function in this child process to the directory owned
by the runner. The host verifies the redirected location before any transfer. The
shipping library is unchanged, and the runner never inventories or removes files in
another process's temporary directory. Everything else uses the public server APIs.
Control and metrics travel over stdio so measuring resources creates no HTTP connection.

## Real-device validation still required

Loopback endurance cannot establish Windows client compatibility, Wi-Fi behavior,
iOS background execution, or local-network permissions. Before release, use an
actual iPhone and Windows/macOS clients with disposable files and record OS/client
versions and file hashes. Exercise simultaneous uploads/downloads, cancellation,
reconnect and resume, iPhone background/foreground transitions, and local-network
permission denial followed by granting access. Confirm the app remains usable and
its resource counters settle after each case. This checklist does not claim those
device runs have been performed.
