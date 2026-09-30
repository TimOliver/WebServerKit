#!/usr/bin/env python3
"""Bounded shared-folder integration and listing measurements on an owned local host."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from urllib.parse import quote, urlencode
import xml.etree.ElementTree as ET

from run import (CHUNK, MIB, PACKAGE, REPOSITORY, TIMEOUT, Host, Runner,
                 check_entries, check_resources, closing_reported, digest, positive, require)

KINDS = ("uploader", "dav")
LIST_BODY = b'<D:propfind xmlns:D="DAV:"><D:prop><D:displayname/><D:getcontentlength/></D:prop></D:propfind>'


def distribution(values):
    """Nearest-rank descriptive quantiles; do not imply a tail from a tiny sample."""
    ordered = sorted(values)
    def rank(fraction):
        return round(ordered[math.ceil(len(ordered) * fraction) - 1], 3)
    return {"count": len(ordered), "p50_ms": rank(.5) if ordered else None,
            "p95_ms": rank(.95) if len(ordered) >= 20 else None,
            "p99_ms": rank(.99) if len(ordered) >= 1000 else None,
            "max_ms": round(max(ordered), 3) if ordered else None}


def bodies_in_flight(intervals, start, end):
    """Count client bodies unfinished throughout an observation interval."""
    return sum(body["start"] <= start and end < body["end"] for body in intervals)


def operation_summary(metrics):
    return {label: {"latency": distribution([e["total_ms"] for e in events]),
                   "headers": distribution([e["headers_ms"] for e in events]),
                   "response_bytes": sum(e["response_bytes"] for e in events),
                   "uploaded_file_bytes": sum(e["upload"]["file_bytes"] for e in events if e["upload"])}
            for label, events in sorted(metrics.items())}


def check_listing(kind, body, files):
    """Exact immutable directory contents; status-only success is insufficient."""
    expected = {"/catalog/" + name: size for name, size in files.items()}
    if kind == "uploader":
        rows = json.loads(body)
        require(isinstance(rows, list), "Listing is not an array")
        actual = {}
        for row in rows:
            path = row["path"]
            require(path not in actual, "Duplicate listing path")
            require(row["name"] == path.rsplit("/", 1)[-1], "Listing name differs")
            actual[path] = row["size"]
        require(actual == expected, "Uploader listing contents differ")
    else:
        root = ET.fromstring(body)
        require(root.tag == "{DAV:}multistatus", "Not a DAV multistatus")
        actual = {}
        for resource in root.findall("{DAV:}response"):
            hrefs = resource.findall("{DAV:}href")
            require(len(hrefs) == 1, "Missing or duplicate DAV href")
            href = hrefs[0].text
            require(href not in actual, "Duplicate DAV resource")
            properties = {}
            for propstat in resource.findall("{DAV:}propstat"):
                status = propstat.findtext("{DAV:}status")
                require(status in ("HTTP/1.1 200 OK", "HTTP/1.1 404 Not Found"), "DAV property failed")
                for prop in propstat.find("{DAV:}prop"):
                    require(prop.tag not in properties, "Duplicate DAV property")
                    properties[prop.tag] = (status, prop.text or "")
            actual[href] = properties
        expected_hrefs = {quote(path, safe="/"): size for path, size in expected.items()}
        require(set(actual) == set(expected_hrefs) | {"/catalog/"}, "DAV listing contents differ")
        for href, properties in actual.items():
            require(set(properties) == {"{DAV:}displayname", "{DAV:}getcontentlength"}, "DAV property set differs")
            size_status, size = properties["{DAV:}getcontentlength"]
            if href == "/catalog/":
                require((size_status, size) == ("HTTP/1.1 404 Not Found", ""), "Collection size must be unavailable")
                name = "catalog"
            else:
                require(size_status == "HTTP/1.1 200 OK" and int(size) == expected_hrefs[href], "DAV file size differs")
                name = href.rsplit("/", 1)[-1]  # Fixtures deliberately use ASCII leaf names.
            require(properties["{DAV:}displayname"] == ("HTTP/1.1 200 OK", name), "DAV displayname differs")


class SharedAudit(Runner):
    def __init__(self, host, args, report, samples):
        super().__init__(host, args, report)
        require(len(set(host.shares.values())) == 1, "Audit requires one shared directory")
        self.share = host.shares["dav"]
        self.catalog = self.share / "catalog"
        self.catalog.mkdir()
        self.probe = b"shared-folder probe\n" * 128
        (self.share / "probe.txt").write_bytes(self.probe)
        self.samples = samples
        self.metrics = {}
        self.files = {}
        self.serial = 0

    def record(self, label, started, headers_at, finished, size, upload=None):
        with self.lock:
            self.metrics.setdefault(label, []).append({"start": started, "end": finished,
                "headers_ms": (headers_at - started) * 1000,
                "total_ms": (finished - started) * 1000, "response_bytes": size,
                "upload": upload})

    def request(self, kind, method, path, expected=200, body=None, headers=None, label=None):
        started = time.monotonic()
        with closing_reported(self.connection(kind), self.report, "request_connection") as connection:
            connection.request(method, path, body, {"Connection": "close", **(headers or {})})
            with closing_reported(connection.getresponse(), self.report, "response") as response:
                headers_at = time.monotonic()
                require(response.status == expected, f"{kind} {method}: expected {expected}, got {response.status}")
                fields = dict(response.getheaders())
                chunks, size = [], 0
                while True:
                    data = response.read1(CHUNK)
                    if not data:
                        break
                    size += len(data)
                    require(size <= 16 * MIB, "Audit response exceeds bounded fixture limit")
                    chunks.append(data)
                finished = time.monotonic()
                length = response.getheader("Content-Length")
                require(length is None or size == int(length), "Response was truncated")
        if label:
            self.record(label, started, headers_at, finished, size)
        self.count(requests=1)
        return b"".join(chunks), fields

    def form(self, endpoint, fields):
        body, _ = self.request("uploader", "POST", endpoint, body=urlencode(fields),
                               headers={"Content-Type": "application/x-www-form-urlencoded"})
        require(json.loads(body) == {}, "Uploader mutation response differs")

    def fetch(self, kind, name, expected, label=None, ranged=False):
        headers = {"Accept-Encoding": "identity"}
        if ranged:
            headers["Range"] = f"bytes=65536-{65536 + len(expected) - 1}"
        body, fields = self.request(kind, "GET", self.path(kind, name), 206 if ranged else 200,
                                    headers=headers, label=label)
        require(digest(body) == digest(expected), "Cross-server file hash differs")
        if ranged:
            fields = {key.lower(): value for key, value in fields.items()}
            require(fields.get("content-range") == f"bytes 65536-{65536 + len(expected) - 1}/{len(self.asset)}",
                    "Range metadata differs")
        self.count(verified_bytes=len(body))

    def listing(self, kind, label=True):
        if kind == "uploader":
            body, _ = self.request(kind, "GET", "/list?path=%2Fcatalog%2F", label="list.uploader" if label else None)
        else:
            body, _ = self.request(kind, "PROPFIND", "/catalog/", 207, body=LIST_BODY,
                headers={"Depth": "1", "Content-Type": "application/xml"}, label="list.dav" if label else None)
        # Client XML/JSON parsing is outside the recorded response interval.
        check_listing(kind, body, self.files)

    def populate(self, count):
        check_entries(self.catalog, self.files)
        for entry in self.catalog.iterdir():
            entry.unlink()
        self.files = {f"item-{i:05d}.txt": 32 + i % 17 for i in range(count)}
        for name, size in self.files.items():
            (self.catalog / name).write_bytes(b"x" * size)

    def quiescent(self, baseline):
        deadline, stable = time.monotonic() + TIMEOUT, 0
        last_error = None
        while time.monotonic() < deadline:
            sample = self.host.stats()
            try:
                check_resources(sample, baseline, self.args.max_footprint_growth_mib * MIB)
                check_entries(self.host.tmp, set())
                check_entries(self.share, {"asset.bin", "probe.txt", "catalog"})
                check_entries(self.catalog, self.files)
                stable += 1
                if stable == 3:
                    return sample
            except AssertionError as error:
                last_error, stable = error, 0
            time.sleep(.1)
        raise AssertionError(f"Shared resources did not settle: {last_error}")

    def workflow(self, kind, worker):
        with self.lock:
            self.serial += 1
            name = f"transfer-{worker}-{self.serial}.bin"
        payload = hashlib.shake_256(name.encode()).digest(self.args.upload_mib * MIB)
        started = time.monotonic()
        connection, remainder = self.begin_upload(kind, name, payload)
        with closing_reported(connection, self.report, "upload_connection"):
            body_started = time.monotonic()
            # Healthy paced sends keep bodies progressing while other clients work.
            for offset in range(0, len(remainder), CHUNK):
                time.sleep(.008)
                connection.send(remainder[offset:offset + CHUNK])
            body_sent = time.monotonic()
            with closing_reported(connection.getresponse(), self.report, "upload_response") as response:
                headers_at = time.monotonic()
                require(response.status == (200 if kind == "uploader" else 201), "Shared upload failed")
                result = response.read(1024)
                require(response.read(1) == b"", "Unexpected upload response")
                if kind == "uploader":
                    require(json.loads(result) == {}, "Upload response differs")
                else:
                    require(result == b"", "PUT response differs")
                finished = time.monotonic()
        self.record("upload." + kind, started, headers_at, finished, len(result),
                    upload={"start": body_started, "end": body_sent, "file_bytes": len(payload)})
        self.count(completed_uploads=1, requests=1)
        peer = "dav" if kind == "uploader" else "uploader"
        self.fetch(peer, name, payload)
        moved, copied, final = name + ".moved", name + ".copy", name + ".final"
        if peer == "uploader":
            self.form("/move", {"oldPath": "/" + name, "newPath": "/" + moved})
        else:
            self.request("dav", "MOVE", "/" + name, 201, headers={"Destination": "/" + moved, "Overwrite": "F"})
        self.request("dav", "COPY", "/" + moved, 201, headers={"Destination": "/" + copied, "Overwrite": "F"})
        self.fetch("uploader", copied, payload)
        self.form("/delete", {"path": "/" + copied})
        self.form("/move", {"oldPath": "/" + moved, "newPath": "/" + final})
        self.fetch("dav", final, payload)
        self.request("dav", "DELETE", "/" + final, 204)
        require(not any((self.share / path).exists() for path in (name, moved, copied, final)), "Mutation left a source or copy")

    def phase(self, name, seconds, listings, warmup=False):
        self.metrics = {}
        state = {"name": name, "entries": len(self.files), "stage": "workload",
                 "load_average_start": os.getloadavg(), "sample_count": 0,
                 "last_resource_sample": None}
        started = time.monotonic()
        try:
            return self._phase(name, seconds, listings, warmup, state, started)
        except BaseException as error:
            self.report["failed_phase"] = {**state, "elapsed_seconds": time.monotonic() - started,
                "load_average_end": os.getloadavg(), "operations": operation_summary(self.metrics),
                "error": f"{type(error).__name__}: {error}"}
            raise

    def _phase(self, name, seconds, listings, warmup, state, started):
        observations, sample_errors = [], []
        finished = threading.Event()
        stop_workers = threading.Event()
        ready = threading.Barrier(8 if listings else 6)
        load_start = state["load_average_start"]
        deadline = started + seconds

        def sample():
            try:
                while not finished.is_set():
                    before = time.monotonic()
                    value = self.host.stats()
                    after = time.monotonic()
                    value.update(elapsed=after - started, sample_start_seconds=before - started,
                                 control_ms=(after - before) * 1000,
                                 temporary_files=len(list(self.host.tmp.iterdir())))
                    observations.append(value)
                    state.update(last_resource_sample=value, sample_count=len(observations))
                    self.samples.write(json.dumps({"phase": name, **value}) + "\n")
                    finished.wait(.025)
            except Exception as error:
                sample_errors.append(error)
        sampler = threading.Thread(target=sample, daemon=True)
        sampler.start()

        def repeat(action, pause=0):
            ready.wait(timeout=TIMEOUT)
            # Always perform one operation, including short warmup phases.
            while True:
                try:
                    action()
                except BaseException:
                    stop_workers.set()
                    raise
                if stop_workers.is_set() or time.monotonic() >= deadline:
                    return
                if pause:
                    time.sleep(pause)

        def reader(kind):
            self.fetch(kind, "probe.txt", self.probe, "get." + kind)
            self.fetch(kind, "asset.bin", self.asset[65536:196608], "range." + kind, ranged=True)

        primary = None
        try:
            with ThreadPoolExecutor(max_workers=8) as pool:
                try:
                    jobs = [pool.submit(repeat, lambda k=kind, i=index: self.workflow(k, i))
                            for index, kind in enumerate(("uploader", "dav", "uploader", "dav"))]
                    jobs += [pool.submit(repeat, lambda k=kind: reader(k), .01) for kind in KINDS]
                    if listings:
                        jobs += [pool.submit(repeat, lambda k=kind: self.listing(k), .05) for kind in KINDS]
                    for job in jobs:
                        job.result(timeout=seconds + 3 * TIMEOUT)
                finally:
                    # Signal before executor shutdown joins; Ctrl-C must not keep
                    # starting work until a potentially hours-away phase deadline.
                    stop_workers.set()
        except BaseException as error:
            primary = error
            raise
        finally:
            if primary is None:
                state["stage"] = "sampler_cleanup"
            finished.set()
            try:
                sampler.join(timeout=TIMEOUT)
                require(not sampler.is_alive(), "Resource sampler did not stop")
                self.samples.flush()
            except Exception as error:
                self.report.setdefault("cleanup_errors", []).append({"resource": "sampler",
                    "error": f"{type(error).__name__}: {error}"})
                if primary is None:
                    raise
        state["stage"] = "sampler_checks"
        require(not sample_errors, f"Resource sampler failed: {sample_errors}")
        require(observations, "No resource samples")
        state["stage"] = "concurrency_checks"
        upload_intervals = [e["upload"] for kind in KINDS for e in self.metrics["upload." + kind]]
        # Flags alone include all POSTs. Also require unfinished file bodies on disk,
        # and all four clients still sending throughout the resource measurement.
        overlap = sum(s["uploads"] >= 4 and s["temporary_files"] >= 4 and s["reserved_bytes"] > 0
            and bodies_in_flight(upload_intervals, started + s["sample_start_seconds"], started + s["elapsed"]) >= 4
            for s in observations)
        require(overlap > 0, "Four unfinished uploads were never observed together")
        completions = {}
        for kind in KINDS:
            for operation in (("get", "range", "list") if listings else ("get", "range")):
                label = operation + "." + kind
                completions[label] = sum(bodies_in_flight(upload_intervals, event["end"], event["end"]) > 0
                                         for event in self.metrics.get(label, []))
                require(completions[label] > 0, f"No {label} completed while an upload body was in flight")
        result = {"name": name, "entries": len(self.files), "listings": listings, "warmup": warmup,
            "elapsed_seconds": round(time.monotonic() - started, 3), "sample_count": len(observations),
            "load_average_start": load_start, "load_average_end": os.getloadavg(),
            "max_sample_gap_ms": round(max((b["elapsed"] - a["elapsed"] for a, b in zip(observations, observations[1:])), default=0) * 1000, 3),
            "sampled_peak_footprint_bytes": max(s["footprint_bytes"] for s in observations),
            "sampled_peak_descriptors": max(s["descriptors"] for s in observations),
            "four_upload_samples": overlap,
            "completions_during_upload": completions,
            "operations": operation_summary(self.metrics)}
        state["stage"] = "settle"
        result["settled"] = self.quiescent(self.baseline)
        print(f"{name}: {len(self.files)} entries, peak {result['sampled_peak_footprint_bytes'] / MIB:.1f} MiB, "
              f"{sum(len(v) for v in self.metrics.values())} timed operations", flush=True)
        return result


def entry_counts(value):
    counts = [int(item) for item in value.split(",")]
    if not counts or any(count < 1 or count > 5000 for count in counts):
        raise argparse.ArgumentTypeError("entry counts must each be between 1 and 5000")
    return sorted(set(counts))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entries", type=entry_counts, default=[100, 1000, 5000])
    parser.add_argument("--seconds", type=positive, default=5, help="minimum workload seconds per measured phase")
    parser.add_argument("--repeats", type=positive, default=2, help="alternate baseline/listing order each repeat")
    parser.add_argument("--report", type=Path, default=REPOSITORY / "build" / "shared-folder-audit.json")
    args = parser.parse_args()
    args.upload_mib, args.asset_mib, args.max_footprint_growth_mib = 1, 8, 64
    report_path = args.report.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "phases": [], "configuration": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
              "platform": platform.platform(), "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPOSITORY, text=True).strip(),
              "harness_sha256": {name: digest((PACKAGE / name).read_bytes()) for name in ("audit.py", "run.py")},
              "memory_measurement": "sampled phys_footprint; transient peaks between samples can be missed",
              "scope": "ordinary distinct-resource workflows in one shared folder; no overlapping-path atomicity or storage-failure claim"}
    started = time.monotonic()
    try:
        subprocess.run(["swift", "build", "--package-path", str(PACKAGE), "-c", "release"], check=True)
        binary = Path(subprocess.check_output(["swift", "build", "--package-path", str(PACKAGE), "-c", "release", "--show-bin-path"], text=True).strip())
        library = binary / "EnduranceTemporaryDirectory.dylib"
        subprocess.run(["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-framework", "Foundation", str(PACKAGE / "TemporaryDirectory.m"), "-o", str(library)], check=True)
        with closing_reported(tempfile.TemporaryDirectory(prefix="wsk-shared-audit-"), report, "temporary_directory", "cleanup") as temporary, \
                closing_reported(report_path.with_suffix(".host.log").open("wb"), report, "host_log") as log, \
                closing_reported(report_path.with_suffix(".samples.jsonl").open("w"), report, "samples_log") as samples:
            host = Host(binary / "EnduranceHost", library, Path(temporary.name), log, shared_directory=True, report=report)
            with closing_reported(host, report, "host"):
                runner = SharedAudit(host, args, report, samples)
                report["host_pid"] = host.process.pid
                # Warm the largest fixture before fixing a baseline that will never be rebased.
                runner.populate(max(args.entries))
                report["initial"] = runner.quiescent(None)
                # A cold large listing can outlast a one-second transfer window.
                # Warm with the measured duration (at least five seconds) so the
                # same concurrency evidence is required here as in measured phases.
                report["phases"].append(runner.phase("warmup", max(5, args.seconds), True, warmup=True))
                runner.baseline = runner.quiescent(None)
                report["baseline"] = runner.baseline
                for count in args.entries:
                    runner.populate(count)
                    for kind in KINDS:
                        runner.listing(kind, label=False)
                    for repeat in range(args.repeats):
                        for listings in ((False, True) if repeat % 2 == 0 else (True, False)):
                            name = f"{count}-{repeat}-{'listing' if listings else 'baseline'}"
                            report["phases"].append(runner.phase(name, args.seconds, listings))
                            report_path.write_text(json.dumps(report, indent=2) + "\n")
                for kind in KINDS:
                    runner.cancel_upload(kind)
                    runner.quiescent(runner.baseline)
                report["final"] = runner.quiescent(runner.baseline)
                require(not host.command("shutdown")["running"], "Host did not stop")
                require(host.process.wait(timeout=TIMEOUT) == 0, "Host shutdown failed")
        report["passed"] = True
    except (Exception, KeyboardInterrupt) as error:
        report["passed"] = False
        report["error"] = f"{type(error).__name__}: {error}"
        traceback.print_exc()
    finally:
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{'PASS' if report['passed'] else 'FAIL'}: {report_path}", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
