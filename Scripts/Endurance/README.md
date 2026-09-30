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

## Shared-folder and listing audit

```sh
python3 Scripts/Endurance/audit.py --seconds 10 --report build/shared-folder-audit.json
```

This separate audit points the uploader and WebDAV server at **the same disposable
directory**. Four workers (two multipart, two PUT) upload distinct 1 MiB files, read
them through the other server, move and copy them, verify their hashes, and delete
them. Two additional clients continuously fetch a small file and a 128 KiB range
from an 8 MiB asset. A cancelled upload through each server must also leave no residue.
It exercises ordinary independent-resource operations; it does not establish atomicity
when clients modify the same path or validate recovery from storage failures.

The default directory sizes are 100, 1,000 and 5,000 entries (`--entries` accepts
comma-separated counts from 1 to 5,000). At each size, two repeats alternate baseline/listing order.
Baseline phases run the transfer workload; listing phases add one JSON listing client
and one Depth:1 PROPFIND client requesting `displayname` and `getcontentlength`.
Every listing must contain exactly the expected resources, names, sizes, namespaces
and property statuses. Fixture files in the listed directory remain immutable while
transfers and mutations use its parent directory. This does not test a changing listing
snapshot, recursive listings, dead-property-heavy responses, or maximum request capacity.

Uploads send continuously in paced 64 KiB chunks. The audit requires samples with four
unfinished bodies, four temporary files and reserved multipart memory, corroborated by
client send intervals. Both GET and Range clients, and both listing clients when enabled,
must complete responses while a body is still being sent. Upload durations include
deliberate pacing and are not throughput benchmarks.

The host is warmed using the largest directory before fixing its resource baseline.
Each phase requires three clean idle samples: no connections, transfers, reservations,
temporary or staging files, and no descriptor growth. The footprint allowance remains
64 MiB. Approximate 25 ms sampling records **observed** peak `phys_footprint`, descriptor
counts and actual sample gaps; shorter peaks can be missed. Reports include per-operation
latency and time to headers for uploads, probe GETs, ranges and listings, plus counts,
received response bytes, uploaded file bytes and completions during uploads. Mutations
are verified but not timed separately. Percentiles use nearest rank; p95 is omitted below 20 samples
and p99 below 1,000. These are client-observed loopback timings, including client scheduling;
XML/JSON validation occurs after the measured response interval.

`--seconds` defaults to five seconds per phase; ten gives larger listings more observations.
A phase finishes its current operations before settling. The report includes warmup
separately and records the library revision, harness hashes and phase load averages. Summary JSON, resource
samples and the host log use the supplied report stem. Run this audit alone for useful
timings. The unit tests for its oracles run in the regular validation gate; the live audit
is explicit, alongside the existing endurance smoke.

Failed requests retain the server, method/path, last stage (`send`, `headers`, `body`
or `validation`), status, advertised length, elapsed time, bytes returned by successful
reads and last observed body progress. This distinguishes a timeout before headers
from a partially consumed response; it does not attribute server CPU or filesystem time.
Failed phases preserve completed-operation metrics and the last sampled resources,
including when sampler, concurrency or settling checks fail. Cleanup errors are recorded
separately and cannot mask an earlier error. Both runners mark PASS only after the host,
logs and temporary directory have been cleaned up successfully. Harness removal of a
failed run's disposable files is separate from the library's idle-resource checks; it
does not count as evidence that the library cleaned up correctly.

Measured on 2026-09-30 against `a3799a9` (Release, arm64 macOS loopback), using the command
above: 63,535 completed requests, 2,817 uploads, two cancellations and 10.56 GiB verified
by hash, including warmup. All 63,537 accepted connections closed; descriptors returned
to eight, reservations to zero, and no temporary or staging files remained. Observed
peak footprint was 59.1 MiB including warmup; final idle footprint was 8.6 MiB.

| Entries | Uploader listing median, two phases | DAV listing median, two phases |
| --- | --- | --- |
| 100 | 6.0–6.1 ms | 8.3–8.4 ms |
| 1,000 | 49.7–53.7 ms | 161–230 ms |
| 5,000 | 251–262 ms | 850–914 ms |

Probe GET and Range p95 stayed below 1.6 ms in every measured phase, including with
listings. There were only 11 DAV listings in each 5,000-entry phase, so no p95 is claimed
for that case. Background simulator/installer and security-scanner work was present;
these timings are descriptive, not an isolated performance comparison. An earlier
warmup hit an unclassified timeout. The instrumented full rerun passed, but does not
explain that failure. Its report now includes phase load averages, partial metrics and
a traceback on workload failure to support investigation if it recurs. No shipping
library or browser code changed for this audit.

A follow-up at 5,000 entries with the additional diagnostics passed 23,884 completed
requests, 1,073 uploads, two cancellations and 4.02 GiB hash-verified. All 23,886
connections closed, descriptors returned to eight and reservations/residual files to
zero. The timeout did not recur. Performance still varied: measured DAV medians were
1.16 s and 4.46 s (eight and three samples), with a 6.69 s maximum. Probe GET/Range p95
stayed below 2 ms. Observed peak footprint was 72.7 MiB and final idle footprint 72.2 MiB,
60.7 MiB above the fixed post-warmup baseline and within the 64 MiB allowance. This
short run cannot distinguish allocator retention from a slower accumulation trend.
The earlier timeout, listing latency variability and memory retention remain unclassified;
neither a passing run nor load averages establish their cause. Eighteen deterministic
runner tests now also cover request diagnostics and cleanup-error reporting, including
both runners' exit codes when cleanup fails.

## Serial DAV listing profile

```sh
python3 Scripts/Endurance/profile_listings.py --report build/listing-profile-timing.json
python3 Scripts/Endurance/profile_listings.py --diagnostic --cycles 2 --report build/listing-profile-diagnostic.json
```

Run these separately and without other test workloads. Both create an owned loopback
host and an immutable 5,000-file catalog, using the shared-folder audit's exact two-property
DAV listing and cleanup checks. The timing run warms five requests, fixes its baseline,
then measures eight cycles of five serial listings with two seconds idle between cycles
and ten seconds idle at the end. Counts and durations have bounded CLI overrides. This
isolates listings; it does not measure mixed-client concurrency or allocation churn.

Stdio snapshots record process user/system CPU, bytes and blocks currently live across
all malloc zones, allocator-reserved capacity and `phys_footprint`. These quantities are
different: allocator capacity is not the size of live objects or the physical footprint.
Snapshots bracket each request batch and continue during idle; they do not capture peak
in-request allocations. Request latency excludes client validation, while batch elapsed
time includes it. CPU deltas include host control/background work. The fixed 64 MiB
footprint allowance remains enforced; exceeding it produces a partial failed report,
not a complete retention diagnosis.

The diagnostic run enables `MallocStackLogging` only in its child host, samples that PID
for five seconds at 10 ms intervals during the first measured cycle, and runs `leaks`
after the final idle window. It records request-batch intervals and the sampler's launch
through observed completion, which may include idle. Read active request stacks rather
than interpreting all-thread idle counts as request cost. Instrumented timing and memory
are not comparable to the timing run; zero reported leaks does not exclude reachable
retention. Inherited `Malloc*` instrumentation is rejected except `MallocNanoZone`, whose
value is recorded and preserved in both modes.

Only after all measured cycles, final idle and any leak inspection does the harness ask
the allocator for pressure relief and record a further idle window. That endpoint control
never rebases or rescues a failed memory check. It may release zero bytes. JSON, resource
JSONL and host logs share the report stem; diagnostics add `.stacks.txt`, `.stacks.tool.log`
and `.leaks.txt`. Incomplete batches and tool failures remain visible, and PASS requires
successful process/log/directory cleanup. The metrics and allocator control exist only
in the test executable, over stdin.

Measured on 2026-09-30 against production tip `a3799a9` (Release, arm64 macOS 27.0.1,
`MallocNanoZone=0`), the timing run completed 45 validated 5,000-entry listings. The
eight measured batches had medians of 695–707 ms and a maximum request of 785 ms,
using 0.380–0.391 host CPU seconds per listing. Warmup included a 6.712-second request,
almost entirely before headers. Its cause remains unclassified; the later warm stacks
do not explain that outlier or the earlier mixed-workload timeout.

| Idle measurement | Fixed warm baseline | After final ten-second idle |
| --- | --- | --- |
| Live malloc bytes | 511,344 | 528,800 |
| Live malloc blocks | 2,951 | 2,950 |
| Allocator-reserved capacity | 68 MiB | 84 MiB |
| Physical footprint | 17.1 MiB | 16.5 MiB |

During the measured cycles, idle live bytes rose as high as 542,064 before falling in
the final idle window. Reserved capacity reached 84 MiB in the third measured cycle
and stayed there; idle footprint reached 24.4 MiB and then fell. The endpoint relief
control reported zero bytes released. This shows a bounded capacity plateau with a
small net live-byte increase in this run; it does not classify the earlier 72.2 MiB
mixed-workload footprint or exclude slower/reachable accumulation.

The separate diagnostic completed 15 validated listings and `leaks` reported zero
leaked allocations. Active PROPFIND stacks most often showed per-file `open`, followed
by containment/classification through `realpath`; xattr reads, strings and sorting
appeared less often. These are instrumented stack observations, including filesystem
calls that may wait, not percentages of uninstrumented CPU time. The five-second sample
also overlapped idle time. Both runs closed every connection, returned descriptors to
their own baselines (eight without stack logging, nine with it), and left no reservations
or temporary/staging files. Reports are `build/listing-profile-timing.json` and
`build/listing-profile-diagnostic.json`, with their sidecars and exact harness hashes.
Twenty-one deterministic harness tests, the existing transfer/restart endurance smoke
and Objective-C lint passed. These measurements do not establish a production defect;
no library change was made. Future optimization needs stage-specific evidence while
preserving containment and the single-descriptor metadata snapshot.

## Upload storage-failure recovery

```sh
python3 Scripts/Endurance/storage_recovery.py --report build/storage-recovery.json
```

This bounded check owns a loopback host, separate uploader/DAV shares and temporary
upload storage. It injects ENOSPC or EIO into a write after a real 128 KiB body prefix
has been sent, or EIO after actually closing a fully written temporary file. Each mode
runs against a new and an existing destination on both servers, for twelve cases.
At least 64 KiB must be observed on disk before releasing the fault, and exactly one
injection must occur. The dedicated dylib matches only a regular file inside this
child's canonical temp directory and pins its descriptor/device/inode. It exposes its
control only through the test host's stdin; the library and HTTP endpoints have no
fault-injection controls. Calls inside the fixture invoke the real syscalls.

For each failure, the runner requires the expected 507/500 response with connection
close, exact share/temp inventory, preservation of existing inode/body/metadata, and
fixed-baseline recovery of connections, descriptors and memory reservations. Two
hash-checked download clients run while the upload is held, across the error, and
until both complete fresh requests after its response. The recorded intervals show
client progress, not the kernel scheduling order at the failing syscall. An unarmed
retry must then succeed in the same process. DAV retries replace the existing target;
the uploader preserves it and uses its normal numbered filename for the new upload.

Summary JSON retains each incomplete case and its last available resources and fault
counters; append-only samples and host logs share its stem. PASS requires successful
cleanup of the owned host, logs and directory. The separate unit tests prove that an
unapplied fault, insufficient prefix, wrong number of hits or unclosed descriptor
cannot pass. These are temporary-upload error-handling checks: they do not exhaust a
real volume, establish crash durability, or cover publication/rename failure paths.

## Real-device validation still required

Loopback endurance cannot establish Windows client compatibility, Wi-Fi behavior,
iOS background execution, or local-network permissions. Before release, use an
actual iPhone and Windows/macOS clients with disposable files and record OS/client
versions and file hashes. Exercise simultaneous uploads/downloads, cancellation,
reconnect and resume, iPhone background/foreground transitions, and local-network
permission denial followed by granting access. Confirm the app remains usable and
its resource counters settle after each case. This checklist does not claim those
device runs have been performed.
