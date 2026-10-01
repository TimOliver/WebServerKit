#!/usr/bin/env python3
"""Owned-loopback resumable uploads, concurrent reads, churn and idle accounting.

The continuous phase has a bounded duration. Its report records the actual elapsed
time; a short smoke does not establish overnight stability. Resource ownership
counters are exact, while allocator/footprint samples are reported separately.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import hashlib
import json
import math
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid

ENDURANCE = Path(__file__).resolve().parents[1] / "Endurance"
sys.path.insert(0, str(ENDURANCE))
from run import (CHUNK, MIB, REPOSITORY, TIMEOUT, DeadlineConnection,
                 check_resources, closing_reported, read_small_response, require)
from recovery import Protocol, ResumableHost, TUS, build


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def check_idle(sample, baseline, max_footprint_growth, max_live_growth):
    """Exact FD/reservation/connection accounting plus explicit memory allowances."""
    check_resources(sample, baseline, max_footprint_growth)
    for name in ("allocator_live_bytes", "allocator_live_blocks", "allocator_reserved_bytes"):
        require(name in sample and sample[name] >= 0, f"Missing allocator metric: {name}")
    if baseline is not None:
        require(sample["allocator_live_bytes"] <= baseline["allocator_live_bytes"] + max_live_growth,
                f"Live allocator bytes exceeded allowance: {baseline} -> {sample}")


def check_idle_inventory(inventory, allow_active=False):
    """All workload receipts are deleted before idle; the 128 bound is for churn."""
    require(not inventory["stages"] and not inventory["unknown"],
            f"Staging or unrecognized session files remain: {inventory}")
    if not allow_active:
        require(not inventory["active"] and not inventory["payloads"],
                f"Partial sessions remain: {inventory}")
    require(not inventory["complete"], f"Deleted completion receipts remain: {inventory}")


def summarize_memory(samples):
    """Describe measured change without labeling retained allocator capacity a leak."""
    require(samples, "No idle resource samples were collected")
    result = {}
    for name in ("footprint_bytes", "allocator_live_bytes", "allocator_live_blocks", "allocator_reserved_bytes"):
        values = [sample["resources"][name] for sample in samples]
        result[name] = {"first": values[0], "last": values[-1], "minimum": min(values),
                        "maximum": max(values), "delta": values[-1] - values[0],
                        "nondecreasing": all(right >= left for left, right in zip(values, values[1:])),
                        "strictly_increasing": len(values) > 1 and all(right > left for left, right in zip(values, values[1:]))}
    result["interpretation"] = ("Samples distinguish live allocations from reserved allocator capacity and physical footprint. "
                                "Passing bounded allowances and fixed ownership counters is not proof of the absence of a slow leak.")
    return result


def check_read_progress(intervals, start, end, required=("uploader", "dav")):
    """Require whole verified reads to finish while uploads are known to be active."""
    for kind in required:
        require(any(row["kind"] == kind and row["start"] >= start and row["end"] <= end for row in intervals),
                f"No complete {kind} download overlapped the held upload bodies")


def check_maintenance_only(before, after, downloads, removed):
    require(before == after, "An upload, HEAD or session request contaminated the maintenance-only phase")
    require(downloads > 0 and removed == 4, "Maintenance evidence needs verified reads and all four expired sessions")


class ReaderGroup:
    def __init__(self, runner):
        self.runner = runner
        self.stop = threading.Event()
        self.pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="wsk-resume-read")
        self.futures = [self.pool.submit(self._work, kind) for kind in ("uploader", "dav")]

    def _work(self, kind):
        count = 0
        while not self.stop.is_set():
            self.runner.download(kind, ranged=bool(count % 2))
            count += 1
            self.stop.wait(self.runner.args.read_pause)

    def check(self):
        for future in self.futures:
            if future.done():
                future.result()

    def close(self):
        self.stop.set()
        try:
            for future in self.futures:
                future.result(timeout=TIMEOUT + 2)
        finally:
            self.pool.shutdown(wait=True)


class CountedProtocol(Protocol):
    def __init__(self, host, report):
        super().__init__(host)
        self.report = report
        self.lock = threading.Lock()

    def record(self, method):
        with self.lock:
            counts = self.report.setdefault("protocol_requests", {})
            counts[method] = counts.get(method, 0) + 1

    def request(self, kind, method, path, body=b"", headers=None, expected=(200,)):
        self.record(method)
        return super().request(kind, method, path, body, headers, expected)

    def request_counts(self):
        with self.lock:
            return dict(self.report.get("protocol_requests", {}))


class Workload:
    def __init__(self, host, protocol, args, report, samples):
        self.host, self.protocol, self.args = host, protocol, args
        self.report, self.samples = report, samples
        self.lock = threading.Lock()
        self.started = time.monotonic()
        self.read_intervals = []
        self.idle_samples = []
        self.baseline = None
        self.asset = hashlib.shake_256(b"WebServerKit resumable endurance asset").digest(args.asset_mib * MIB)
        self.asset_hash = sha256(self.asset)
        self.sequence = 0
        self.last_checkpoint = 0
        (host.shared / "asset.bin").write_bytes(self.asset)

    def checkpoint(self, force=False):
        if not force and time.monotonic() - self.last_checkpoint < 10:
            return
        self.report["elapsed_seconds"] = time.monotonic() - self.started
        self.report["idle_samples"] = self.idle_samples
        path = self.args.report.resolve()
        temporary = path.with_suffix(".progress.tmp")
        temporary.write_text(json.dumps(self.report, indent=2) + "\n")
        temporary.replace(path)
        self.last_checkpoint = time.monotonic()

    def phase(self, name):
        self.report["phase"] = name
        self.checkpoint(force=True)
        print(f"resumable endurance: {name}", flush=True)

    def count(self, **counts):
        with self.lock:
            for name, value in counts.items():
                self.report[name] = self.report.get(name, 0) + value

    def sample(self, label):
        result = self.host.command("profile-stats")["resources"]
        row = {"label": label, "elapsed": time.monotonic() - self.started,
               "pid": self.host.process.pid, "resources": result}
        with self.lock:
            self.samples.write(json.dumps(row) + "\n")
            self.samples.flush()
            self.report["last_sample"] = row
        return row

    def connection(self, kind):
        return DeadlineConnection("127.0.0.1", self.host.ports[kind], timeout=TIMEOUT)

    def download(self, kind, ranged=False, item=None):
        start = time.monotonic()
        name = item["name"] if item else "asset.bin"
        source = item["data"] if item else self.asset
        path = "/download?path=%2F" + name if kind == "uploader" else "/" + name
        headers = {"Connection": "close", "Accept-Encoding": "identity"}
        first = len(source) // 4
        last = first + min(MIB // 2, len(source) - first) - 1
        expected = source[first:last + 1] if ranged else source
        if ranged:
            headers["Range"] = f"bytes={first}-{last}"
        with closing(self.connection(kind)) as connection:
            connection.request("GET", path, headers=headers)
            response = connection.getresponse()
            try:
                require(response.status == (206 if ranged else 200),
                        f"{kind} download failed: {response.status}")
                if ranged:
                    require(response.getheader("Content-Range") == f"bytes {first}-{last}/{len(source)}",
                            "Range response does not describe its actual bytes")
                checksum = hashlib.sha256()
                received = 0
                while True:
                    chunk = response.read1(CHUNK)
                    if not chunk:
                        break
                    received += len(chunk)
                    require(received <= len(expected), "Download exceeded the expected byte count")
                    checksum.update(chunk)
                require(received == len(expected) and checksum.hexdigest() == sha256(expected),
                        "Download length or SHA-256 mismatch")
            finally:
                response.close()
        end = time.monotonic()
        with self.lock:
            self.read_intervals.append({"kind": kind, "range": ranged, "start": start, "end": end})
            # Only a recent window is needed for overlap evidence. Long runs keep
            # aggregate counters instead of retaining every download in memory.
            if len(self.read_intervals) > 4096:
                del self.read_intervals[:2048]
        self.count(download_requests=1, ranged_downloads=int(ranged), verified_download_bytes=received)

    def wait_read_progress(self, readers, since):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            readers.check()
            with self.lock:
                complete = all(any(row["kind"] == kind and row["start"] >= since
                                   for row in self.read_intervals) for kind in ("uploader", "dav"))
            if complete:
                return
            time.sleep(.01)
        raise AssertionError("Both verified readers did not make progress")

    def inventory(self):
        root = self.host.sessions
        result = {"active": [], "complete": [], "payloads": [], "stages": [], "unknown": []}
        if not root.exists():
            return result
        for entry in root.iterdir():
            if entry.name == ".lock" and entry.is_file():
                continue
            if entry.name.startswith(".stage-"):
                result["stages"].append(entry.name)
                continue
            if not entry.is_dir() or entry.is_symlink():
                result["unknown"].append(entry.name)
                continue
            manifest = entry / "manifest.json"
            require(manifest.is_file(), f"Session has no manifest: {entry.name}")
            state = json.loads(manifest.read_text())["state"]
            result["complete" if state == "complete" else "active"].append(entry.name)
            for child in entry.iterdir():
                name = str(child.relative_to(root))
                if child.name == "payload":
                    result["payloads"].append(name)
                elif child.name.startswith(".stage-"):
                    result["stages"].append(name)
                elif child.name not in ("manifest.json", ".lock"):
                    result["unknown"].append(name)
        return result

    def idle(self, label, baseline=None, allow_active=False):
        deadline, stable, last_error = time.monotonic() + TIMEOUT, 0, None
        while time.monotonic() < deadline:
            row = self.sample(label)
            try:
                check_idle(row["resources"], baseline, self.args.max_footprint_growth_mib * MIB,
                           self.args.max_live_growth_mib * MIB)
                require(not list(self.host.tmp.iterdir()), "Request temporary files remain at idle")
                inventory = self.inventory()
                check_idle_inventory(inventory, allow_active)
                stable += 1
                if stable >= 3:
                    row["sessions"] = inventory
                    self.idle_samples.append(row)
                    self.checkpoint()
                    return row
            except AssertionError as error:
                stable, last_error = 0, error
            time.sleep(.1)
        raise AssertionError(f"Idle resources did not settle: {last_error}")

    def new_item(self, label, size):
        self.sequence += 1
        name = f"{label}-{self.sequence}.bin"
        data = hashlib.shake_256(name.encode()).digest(size)
        return self.protocol.create(name, data)

    def remove_completed(self, item, receipt=True):
        if receipt:
            self.protocol.delete(item)
            require(not (self.host.sessions / item["key"]).exists(), "Deleted completion receipt remains")
        self.protocol.request("dav", "DELETE", "/" + item["name"], expected=(204,))
        require(not (self.host.shared / item["name"]).exists(), "Published test file was not deleted")

    def begin_held_patch(self, item):
        offset = item["offset"]
        chunk = item["data"][offset:offset + self.args.chunk_kib * 1024]
        require(len(chunk) > CHUNK, "Held PATCH must contain a real prefix and unsent suffix")
        connection = self.connection("uploader")
        try:
            connection.putrequest("PATCH", item["url"])
            for name, value in {**TUS, "Content-Type": "application/offset+octet-stream",
                                "Upload-Offset": str(offset), "Content-Length": str(len(chunk)),
                                "Connection": "close"}.items():
                connection.putheader(name, value)
            connection.endheaders()
            connection.send(chunk[:CHUNK])
            self.protocol.record("PATCH")
            return connection, chunk[CHUNK:], offset + len(chunk)
        except BaseException:
            connection.close()
            raise

    def finish_held_patch(self, item, held):
        connection, remaining, offset = held
        with closing(connection):
            connection.send(remaining)
            response = connection.getresponse()
            headers = {key.lower(): value for key, value in response.getheaders()}
            require(response.status == 204, f"Held PATCH failed: {response.status}")
            read_small_response(response)
            self.protocol.offset(headers, offset)
            item["offset"] = offset

    def finish_item(self, item, deadline):
        while item["offset"] < len(item["data"]):
            require(time.monotonic() < deadline, "Upload phase exceeded its total deadline")
            offset = item["offset"]
            self.protocol.patch(item, offset, item["data"][offset:offset + self.args.chunk_kib * 1024])
            time.sleep(self.args.send_pause)
        require(self.protocol.head(item) == len(item["data"]), "Final receipt did not confirm publication")

    def wait_active(self, count):
        deadline = time.monotonic() + min(TIMEOUT, 4)
        while time.monotonic() < deadline:
            resources = self.host.stats()
            if resources["uploads"] >= count:
                return resources
            time.sleep(.01)
        raise AssertionError(f"Expected {count} simultaneous active upload bodies")

    def four_uploads(self, readers, size_mib, label):
        items = [self.new_item(label, size_mib * MIB) for _ in range(4)]
        held = []
        try:
            for item in items:
                held.append(self.begin_held_patch(item))
            active = self.wait_active(4)
            start = time.monotonic()
            self.wait_read_progress(readers, start)
            end = time.monotonic()
            require(self.host.stats()["uploads"] >= 4, "Upload bodies ended before reads completed")
            with self.lock:
                intervals = list(self.read_intervals)
            check_read_progress(intervals, start, end)
            self.report.setdefault("overlap_windows", []).append({"label": label,
                "start": start - self.started, "end": end - self.started, "resources": active,
                "completed_reads": sum(row["start"] >= start and row["end"] <= end for row in intervals)})
            with ThreadPoolExecutor(max_workers=4) as pool:
                futures = [pool.submit(self.finish_held_patch, item, body) for item, body in zip(items, held)]
                for future in futures:
                    future.result(timeout=TIMEOUT + 2)
            deadline = time.monotonic() + max(60, size_mib * 3)
            with ThreadPoolExecutor(max_workers=4) as pool:
                futures = [pool.submit(self.finish_item, item, deadline) for item in items]
                for future in futures:
                    future.result(timeout=max(60, size_mib * 3) + TIMEOUT)
            for item in items:
                for kind in ("uploader", "dav"):
                    self.download(kind, item=item)
                self.remove_completed(item)
            self.count(completed_uploads=4, uploaded_bytes=4 * size_mib * MIB)
        finally:
            for connection, _, _ in held:
                connection.close()

    def cancel_partial(self):
        item = self.new_item("cancel", 2 * self.args.chunk_kib * 1024)
        self.protocol.patch(item, 0, item["data"][:self.args.chunk_kib * 1024])
        confirmed = item["offset"]
        held = self.begin_held_patch(item)
        self.wait_active(1)
        held[0].close()
        require(self.protocol.head(item) == confirmed, "Interrupted body advanced its confirmed offset")
        self.protocol.delete(item)
        require(not (self.host.sessions / item["key"]).exists(), "Cancelled session remains")
        require(not (self.host.shared / item["name"]).exists(), "Cancelled upload was published")
        self.count(cancelled_uploads=1)

    def listener_restart(self):
        items = [self.new_item("restart", 2 * self.args.chunk_kib * 1024) for _ in range(4)]
        for item in items:
            self.protocol.patch(item, 0, item["data"][:self.args.chunk_kib * 1024])
        pid = self.host.process.pid
        require(not self.host.command("stop")["running"], "Listeners did not stop")
        restarted = self.host.command("start")
        require(restarted["running"] and self.host.process.pid == pid, "Listener restart changed process identity")
        self.host.ports = {kind: restarted[kind + "_port"] for kind in ("uploader", "dav")}
        for item in items:
            require(self.protocol.head(item) == self.args.chunk_kib * 1024, "Restart lost a committed offset")
        reader_start = time.monotonic()
        with closing_reported(ReaderGroup(self), self.report, "restart_readers") as readers:
            with ThreadPoolExecutor(max_workers=4) as pool:
                deadline = time.monotonic() + 60
                futures = [pool.submit(self.finish_item, item, deadline) for item in items]
                for future in futures:
                    future.result(timeout=60 + TIMEOUT)
            self.wait_read_progress(readers, reader_start)
            for item in items:
                for kind in ("uploader", "dav"):
                    self.download(kind, item=item)
                self.remove_completed(item)
        self.count(listener_restarts=1, resumed_uploads=4, completed_uploads=4,
                   uploaded_bytes=sum(len(item["data"]) for item in items))

    def receipt_churn(self):
        items = []
        for _ in range(self.args.receipts):
            item = self.new_item("receipt", 4096)
            self.protocol.patch(item, 0, item["data"])
            for kind in ("uploader", "dav"):
                self.download(kind, item=item)
            self.remove_completed(item, receipt=False)
            items.append(item)
        inventory = self.inventory()
        require(len(inventory["complete"]) <= 128 and not inventory["active"],
                f"Completion receipt churn was not bounded: {inventory}")
        self.protocol.request("uploader", "HEAD", items[0]["url"], headers=TUS, expected=(404, 410))
        require(self.protocol.head(items[-1]) == len(items[-1]["data"]), "Newest completion receipt was evicted")
        self.report["receipt_churn"] = {"created": len(items), "retained": len(inventory["complete"]),
                                         "oldest_evicted": True, "newest_retained": True}
        for key in inventory["complete"]:
            self.protocol.request("uploader", "DELETE", "/uploads/" + key, headers=TUS, expected=(204,))
        self.count(completed_uploads=len(items), uploaded_bytes=sum(len(item["data"]) for item in items))

    def admission_recovery(self):
        items = [self.new_item("admission", 1) for _ in range(32)]
        key = str(uuid.uuid4())
        self.protocol.request("uploader", "POST", "/uploads", headers={**TUS,
            "Upload-Key": key, "Upload-Length": "1", "Upload-Metadata": items[0]["metadata"]}, expected=(413,))
        require(not (self.host.sessions / key).exists(), "Refused session consumed admission state")
        self.protocol.delete(items.pop())
        replacement = self.new_item("admission-recovered", 1)
        self.protocol.patch(replacement, 0, replacement["data"])
        for kind in ("uploader", "dav"):
            self.download(kind, item=replacement)
        self.remove_completed(replacement)
        for item in items:
            self.protocol.delete(item)
        require(not self.inventory()["active"], "Admission capacity was not released")
        self.count(admission_recoveries=1, completed_uploads=1, uploaded_bytes=1)

    def configure_timeout(self, seconds):
        pid = self.host.process.pid
        require(not self.host.command("stop")["running"], "Listeners did not stop for timeout configuration")
        result = self.host.command("set-resumable-timeout", seconds=seconds)
        require(result["resumable_timeout"] == seconds, "Test lifetime was not applied")
        result = self.host.command("start")
        require(result["running"] and self.host.process.pid == pid, "Configuration restart changed process identity")
        self.host.ports = {kind: result[kind + "_port"] for kind in ("uploader", "dav")}
        self.count(listener_restarts=1)

    def expiry_while_downloading(self):
        self.configure_timeout(self.args.expiry_ttl)
        items = [self.new_item("abandoned", 2 * self.args.chunk_kib * 1024) for _ in range(4)]
        for item in items:
            self.protocol.patch(item, 0, item["data"][:self.args.chunk_kib * 1024])
        require(all((self.host.sessions / item["key"]).exists() for item in items),
                "Abandoned sessions disappeared before the maintenance phase began")
        initial_requests = self.protocol.request_counts()
        start = time.monotonic()
        initial_downloads = self.report.get("download_requests", 0)
        with closing_reported(ReaderGroup(self), self.report, "expiry_readers") as readers:
            deadline = start + self.args.maintenance_wait
            while any((self.host.sessions / item["key"]).exists() for item in items):
                require(time.monotonic() < deadline, "Periodic cleanup did not remove expired sessions during downloads only")
                readers.check()
                # Filesystem observation and stdio metrics never execute uploader
                # session endpoints, so only the real maintenance timer can reap.
                self.sample("downloads-only-expiry")
                time.sleep(.2)
            self.wait_read_progress(readers, start)
        check_maintenance_only(initial_requests, self.protocol.request_counts(),
                               self.report.get("download_requests", 0) - initial_downloads, len(items))
        require(all(not (self.host.shared / item["name"]).exists() for item in items),
                "Expired partial upload was published")
        self.report.setdefault("expiry_windows", []).append({"duration_seconds": time.monotonic() - start,
            "configured_ttl_seconds": self.args.expiry_ttl, "expired_sessions": len(items),
            "verified_downloads": self.report.get("download_requests", 0) - initial_downloads,
            "protocol_requests_during_wait": 0, "pid": self.host.process.pid})
        self.count(expired_uploads=len(items))
        self.configure_timeout(self.args.session_ttl)

    def warm(self):
        with closing_reported(ReaderGroup(self), self.report, "warm_readers") as readers:
            self.four_uploads(readers, 1, "warm")
            self.cancel_partial()
        self.baseline = self.idle("fixed-warm-baseline")["resources"]
        self.report["fixed_idle_baseline"] = self.baseline

    def run(self):
        self.phase("warmup")
        self.warm()
        self.phase("receipt churn and admission recovery")
        self.receipt_churn()
        self.admission_recovery()
        self.idle("after-receipts-and-admission", self.baseline)
        if self.args.large_file_mib:
            self.phase("four large files")
            start = time.monotonic()
            with closing_reported(ReaderGroup(self), self.report, "large_readers") as readers:
                self.four_uploads(readers, self.args.large_file_mib, "large")
            self.report["large_file_phase"] = {"files": 4, "bytes_per_file": self.args.large_file_mib * MIB,
                "elapsed_seconds": time.monotonic() - start, "both_servers_verified": True}
            self.idle("after-large-files", self.baseline)
        start = time.monotonic()
        self.phase("mixed concurrent workload")
        last_expiry, rounds = start, 0
        while time.monotonic() - start < self.args.duration:
            with closing_reported(ReaderGroup(self), self.report, "mixed_readers") as readers:
                self.four_uploads(readers, self.args.upload_mib, "mixed")
                self.cancel_partial()
            rounds += 1
            if rounds % self.args.restart_every == 0:
                self.listener_restart()
            self.idle(f"mixed-round-{rounds}", self.baseline)
            if self.args.expiry_every and time.monotonic() - last_expiry >= self.args.expiry_every:
                self.phase("periodic expiry with downloads only")
                self.expiry_while_downloading()
                self.idle("after-periodic-expiry", self.baseline)
                last_expiry = time.monotonic()
                self.phase("mixed concurrent workload")
            time.sleep(self.args.round_pause)
        self.report["continuous_phase"] = {"requested_seconds": self.args.duration,
            "elapsed_seconds": time.monotonic() - start, "rounds": rounds,
            "same_process_pid": self.host.process.pid}
        # Every smoke includes a real downloads-only expiry window even when its
        # continuous phase is shorter than the configured recurring interval.
        self.phase("final expiry with downloads only")
        self.expiry_while_downloading()
        self.idle("final-idle", self.baseline)
        require({entry.name for entry in self.host.shared.iterdir()} == {"asset.bin"},
                "Published files or duplicates remain after workload cleanup")
        self.report["idle_samples"] = self.idle_samples
        self.report["memory_observations"] = summarize_memory(self.idle_samples)
        self.report["final_inventory"] = self.inventory()
        self.phase("complete")


def bounded_number(minimum, maximum, integer=False):
    def parse(value):
        number = int(value) if integer else float(value)
        if not math.isfinite(number) or not minimum <= number <= maximum:
            raise argparse.ArgumentTypeError(f"must be between {minimum} and {maximum}")
        return number
    return parse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, help="Use an existing owned EnduranceHost build")
    parser.add_argument("--temporary-library", type=Path, help="Its test-only temporary-directory library")
    parser.add_argument("--report", type=Path,
                        default=Path("/private/tmp/wsk-recovery-hardening-evidence/resumable-endurance.json"))
    parser.add_argument("--duration", type=bounded_number(1, 86400), default=30,
                        help="Seconds in the mixed workload; setup and maintenance checks are additional")
    parser.add_argument("--upload-mib", type=bounded_number(1, 64, True), default=2)
    parser.add_argument("--large-file-mib", type=bounded_number(0, 128, True), default=0,
                        help="Separate four-file phase, verified through both servers")
    parser.add_argument("--asset-mib", type=bounded_number(1, 32, True), default=2)
    parser.add_argument("--chunk-kib", type=bounded_number(128, 1024, True), default=256)
    parser.add_argument("--receipts", type=bounded_number(129, 512, True), default=136)
    parser.add_argument("--restart-every", type=bounded_number(1, 1000, True), default=3)
    parser.add_argument("--expiry-every", type=bounded_number(0, 86400), default=120,
                        help="Seconds between downloads-only expiry phases; 0 leaves only the final phase")
    parser.add_argument("--expiry-ttl", type=bounded_number(.5, 10), default=3)
    parser.add_argument("--session-ttl", type=bounded_number(60, 172800), default=86400)
    parser.add_argument("--maintenance-wait", type=bounded_number(32, 120), default=45)
    parser.add_argument("--read-pause", type=bounded_number(.001, 2), default=.05)
    parser.add_argument("--send-pause", type=bounded_number(0, .5), default=.005)
    parser.add_argument("--round-pause", type=bounded_number(0, 5), default=.05)
    parser.add_argument("--max-footprint-growth-mib", type=bounded_number(1, 1024, True), default=64)
    parser.add_argument("--max-live-growth-mib", type=bounded_number(1, 128, True), default=8)
    args = parser.parse_args()
    if bool(args.host) != bool(args.temporary_library):
        parser.error("--host and --temporary-library must be supplied together")
    report_path = args.report.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "platform": platform.platform(),
              "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPOSITORY, text=True).strip(),
              "configuration": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
              "scope": "Owned same-process loopback host with synthetic files; bounded elapsed time, not native iOS suspension or overnight proof.",
              "source_sha256": {str(path.relative_to(REPOSITORY)): sha256(path.read_bytes()) for path in
                  (Path(__file__), Path(__file__).with_name("recovery.py"), ENDURANCE / "Sources/EnduranceHost/main.m",
                   REPOSITORY / "Sources/WebServerKitUploader/WSKResumableUploadStore.m")}}
    started = time.monotonic()
    try:
        binary, libraries = (args.host.resolve(), [args.temporary_library.resolve()]) if args.host else build(faults=False)
        require(binary.is_file() and all(library.is_file() for library in libraries), "Host or temporary fixture is missing")
        report["binary_sha256"] = sha256(binary.read_bytes())
        report["fixture_sha256"] = {str(library): sha256(library.read_bytes()) for library in libraries}
        with closing_reported(tempfile.TemporaryDirectory(prefix="wsk-resumable-endurance-"), report,
                              "owned_directory", "cleanup") as temporary, \
                closing_reported(report_path.with_suffix(".host.log").open("wb"), report, "host_log") as log, \
                closing_reported(report_path.with_suffix(".samples.jsonl").open("w"), report, "sample_log") as samples:
            host = ResumableHost(binary, libraries, Path(temporary.name), log, report=report, ttl=args.session_ttl)
            with closing_reported(host, report, "host"):
                report["host_pid"] = host.process.pid
                report["owned_root"] = str(Path(temporary.name).resolve())
                protocol = CountedProtocol(host, report)
                workload = Workload(host, protocol, args, report, samples)
                workload.run()
                require(host.process.pid == report["host_pid"], "Endurance changed the host process")
                require(not host.command("shutdown")["running"], "Host did not stop")
                require(host.process.wait(timeout=TIMEOUT) == 0, "Host shutdown failed")
                report["owned_host_stopped"] = True
        report["passed"] = True
    except (Exception, KeyboardInterrupt) as error:
        report["error"] = f"{type(error).__name__}: {error}"
        traceback.print_exc()
    finally:
        report["elapsed_seconds"] = time.monotonic() - started
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{'PASS' if report['passed'] else 'FAIL'}: {report_path}", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
