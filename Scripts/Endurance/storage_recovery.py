#!/usr/bin/env python3
"""Bounded upload storage failures in a disposable, loopback-only child host."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from types import SimpleNamespace

from run import (CHUNK, MIB, PACKAGE, REPOSITORY, TIMEOUT, Host, Runner,
                 closing_reported, digest, read_small_response, require)


MODES = {"write-enospc": 507, "write-eio": 500, "close-eio": 500}
ATTRIBUTE = "com.webserverkit.storage-recovery"


def check_fault(fault, mode, payload_length):
    require(fault["mode"] == mode and fault["released"], "Wrong or unreleased storage fixture")
    require(fault["hits"] == 1, f"Storage fault did not fire exactly once: {fault}")
    require(fault["bytes_written"] >= CHUNK, "Failure occurred before a real disk prefix")
    require(fault["target_closed"] and fault["real_closed"] and fault["target_fd"] == -1,
            f"Target descriptor was not closed: {fault}")
    if mode == "close-eio":
        require(fault["bytes_written"] == payload_length, "Close fault did not follow the complete file body")
        require(fault["real_close_result"] == 0 and fault["close_result"] == -1,
                "Close error was not injected after a successful real close")
    else:
        require(fault["bytes_written"] < payload_length, "Write fault occurred after the complete file body")


class Downloads:
    """Hash-checked readers keep running before, during and after the upload error."""
    def __init__(self, runner, row):
        self.runner, self.row = runner, row
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.observations = {kind: [] for kind in runner.host.shares}
        row["downloads"] = self.observations
        self.pool = ThreadPoolExecutor(max_workers=2)
        self.futures = [self.pool.submit(self.work, kind) for kind in self.observations]

    def work(self, kind):
        while not self.stop.is_set():
            started = time.monotonic()
            self.runner.download(kind)
            with self.lock:
                self.observations[kind].append({"start": started, "end": time.monotonic()})
            self.stop.wait(.02)

    def wait_after(self, moment):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            for future in self.futures:
                if future.done():
                    future.result()
            with self.lock:
                if all(any(item["start"] >= moment for item in values) for values in self.observations.values()):
                    return
            time.sleep(.01)
        raise AssertionError("Unrelated downloads stopped making progress")

    def close(self):
        self.stop.set()
        try:
            for future in self.futures:
                future.result(timeout=TIMEOUT + 1)
        finally:
            self.pool.shutdown(wait=True)


class StorageRecovery(Runner):
    def __init__(self, host, args, report, samples):
        super().__init__(host, args, report)
        self.samples = samples
        self.started = time.monotonic()
        self.payload = hashlib.shake_256(b"storage recovery upload").digest(MIB)

    def snapshot(self, label):
        sample = {"label": label, "elapsed": time.monotonic() - self.started,
                  "resources": self.host.stats(), "fault": self.host.command("fault-stats")}
        self.report["last_sample"] = sample
        self.samples.write(json.dumps(sample) + "\n")
        self.samples.flush()
        return sample

    def wait_prefix(self):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            sample = self.snapshot("prefix")
            fault = sample["fault"]
            if fault["bytes_written"] >= CHUNK:
                require(fault["hits"] == 0 and not fault["released"] and not fault["target_closed"],
                        "Fixture fired before release")
                require(sample["resources"]["uploads"] == 1, "Upload did not remain active")
                candidates = [path.stat() for path in self.host.tmp.iterdir()]
                matches = [item for item in candidates if (item.st_dev, item.st_ino) ==
                           (fault["target_device"], fault["target_inode"])]
                require(len(matches) == 1 and matches[0].st_size >= CHUNK,
                        "Fixture's disk-write evidence does not match the owned temporary file")
                return sample
            time.sleep(.02)
        raise AssertionError("Upload never wrote the required disk prefix")

    def finish_upload(self, connection, remainder, row):
        try:
            for offset in range(0, len(remainder), CHUNK):
                connection.send(remainder[offset:offset + CHUNK])
        except (BrokenPipeError, ConnectionResetError) as error:
            # Still require a complete HTTP response; a reset alone cannot pass.
            row["send_error"] = f"{type(error).__name__}: {error}"
        response = connection.getresponse()
        row["status"] = response.status
        row["connection_header"] = response.getheader("Connection")
        read_small_response(response)
        self.count(requests=1)
        return row["status"]

    def retry(self, kind, name, existed):
        row = {}
        connection, remainder = self.begin_upload(kind, name, self.payload)
        with closing_reported(connection, self.report, "retry_connection"):
            expected_status = 200 if kind == "uploader" else (204 if existed else 201)
            require(self.finish_upload(connection, remainder, row) == expected_status,
                    f"Upload did not recover: {row}")
        actual = "target (1).bin" if kind == "uploader" and existed else name
        self.expected[kind].add(actual)
        require((self.host.shares[kind] / actual).read_bytes() == self.payload, "Retry stored incorrect bytes")
        self.download(kind, actual, self.payload)
        self.count(completed_uploads=1)
        return row, actual

    def case(self, kind, mode, existed):
        row = {"server": kind, "mode": mode, "existing_destination": existed, "passed": False}
        self.report["cases"].append(row)
        path = self.host.shares[kind] / "target.bin"
        original = b"original destination must survive"
        if existed:
            path.write_bytes(original)
            os.setxattr(path, ATTRIBUTE, b"original metadata")
            identity = path.stat().st_dev, path.stat().st_ino
            self.expected[kind].add(path.name)
        self.quiescent(self.baseline)
        self.host.command("fault-arm", mode=mode)
        try:
            connection, remainder = self.begin_upload(kind, path.name, self.payload)
            with closing_reported(connection, self.report, "failed_upload_connection"):
                # Multipart keeps a small delimiter margin. Send 128 KiB so at
                # least 64 KiB can be proven to have reached the file itself.
                connection.send(remainder[:CHUNK])
                remainder = remainder[CHUNK:]
                row["prefix"] = self.wait_prefix()
                if kind == "uploader":
                    require(row["prefix"]["resources"]["reserved_bytes"] > 0,
                            "Multipart argument did not reserve memory")
                with closing_reported(Downloads(self, row), self.report, "downloads") as readers:
                    readers.wait_after(0)
                    row["before_release"] = self.snapshot("before-release")
                    require(row["before_release"]["resources"]["uploads"] == 1,
                            "Upload ended before concurrent downloads completed")
                    row["release_started"] = time.monotonic()
                    self.host.command("fault-release")
                    status = self.finish_upload(connection, remainder, row)
                    row["response_received"] = time.monotonic()
                    require(status == MODES[mode], f"Expected HTTP {MODES[mode]}, got {status}")
                    require((row["connection_header"] or "").lower() == "close", "Upload did not honor the requested connection close")
                    readers.wait_after(row["response_received"])
            row["idle_after_failure"] = self.quiescent(self.baseline)
            row["after_failure"] = self.snapshot("after-failure")
            check_fault(row["after_failure"]["fault"], mode, len(self.payload))
            if existed:
                require(path.read_bytes() == original and os.getxattr(path, ATTRIBUTE) == b"original metadata"
                        and (path.stat().st_dev, path.stat().st_ino) == identity,
                        "Failed upload changed the original destination")
            else:
                require(not path.exists(), "Failed upload published a destination")
            self.host.command("fault-clear")
            row["retry"], actual = self.retry(kind, path.name, existed)
            row["idle_after_retry"] = self.quiescent(self.baseline)
            require(not self.host.command("fault-stats")["armed"], "Retry unexpectedly rearmed the fixture")
            for name in {path.name, actual}:
                (self.host.shares[kind] / name).unlink(missing_ok=True)
                self.expected[kind].discard(name)
            row["final"] = self.quiescent(self.baseline)
            row["passed"] = True
            print(f"PASS {kind} {mode} {'existing' if existed else 'new'} destination", flush=True)
        finally:
            # Retain applied-fault evidence even when a status or cleanup check fails.
            try:
                row["last_sample"] = self.snapshot("case-end")
            except Exception as error:
                self.report.setdefault("diagnostic_errors", []).append(str(error))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=REPOSITORY / "build" / "storage-recovery.json")
    args = parser.parse_args()
    report_path = args.report.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "cases": [], "platform": platform.platform(),
              "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPOSITORY, text=True).strip(),
              "harness_sha256": {name: digest((PACKAGE / name).read_bytes()) for name in
                                  ("storage_recovery.py", "StorageFaults.m", "run.py", "Sources/EnduranceHost/main.m")},
              "multipart_source_sha256": digest((REPOSITORY / "Sources/WebServerKit/Requests/WSKMultiPartFormRequest.m").read_bytes()),
              "scope": "injected temporary-upload write/close failures; not real volume exhaustion, crash durability or publication failures"}
    started = time.monotonic()
    try:
        subprocess.run(["swift", "build", "--package-path", str(PACKAGE), "-c", "release"], check=True)
        binary = Path(subprocess.check_output(["swift", "build", "--package-path", str(PACKAGE), "-c", "release", "--show-bin-path"], text=True).strip())
        libraries = []
        for source in ("TemporaryDirectory", "StorageFaults"):
            output = binary / ("Endurance" + source + ".dylib")
            subprocess.run(["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-framework", "Foundation",
                            str(PACKAGE / (source + ".m")), "-o", str(output)], check=True)
            libraries.append(output)
        with closing_reported(tempfile.TemporaryDirectory(prefix="wsk-storage-recovery-"), report, "temporary_directory", "cleanup") as temporary, \
                closing_reported(report_path.with_suffix(".host.log").open("wb"), report, "host_log") as log, \
                closing_reported(report_path.with_suffix(".samples.jsonl").open("w"), report, "samples_log") as samples:
            host = Host(binary / "EnduranceHost", libraries[0], Path(temporary.name), log, report=report, storage_fault_library=libraries[1])
            with closing_reported(host, report, "host"):
                report["host_pid"] = host.process.pid
                runner = StorageRecovery(host, SimpleNamespace(asset_mib=2, max_footprint_growth_mib=64), report, samples)
                host.command("fault-stats")  # Refuse a run without the fixture.
                for kind in host.shares:
                    runner.download(kind)
                    _, name = runner.retry(kind, "target.bin", False)
                    (host.shares[kind] / name).unlink()
                    runner.expected[kind].remove(name)
                runner.baseline = runner.quiescent(None)
                report["baseline"] = runner.baseline
                for kind in host.shares:
                    for mode in MODES:
                        for existed in (False, True):
                            runner.case(kind, mode, existed)
                            report_path.write_text(json.dumps(report, indent=2) + "\n")
                report["final"] = runner.quiescent(runner.baseline)
                require(not host.command("shutdown")["running"], "Host did not stop")
                require(host.process.wait(timeout=TIMEOUT) == 0, "Host shutdown failed")
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
