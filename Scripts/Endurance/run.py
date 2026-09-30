#!/usr/bin/env python3
"""Bounded, loopback-only endurance checks against a host this runner creates."""
import argparse
from contextlib import closing, contextmanager
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlencode

PACKAGE = Path(__file__).resolve().parent
REPOSITORY = PACKAGE.parent.parent
MIB = 1024 * 1024
CHUNK = 64 * 1024
TIMEOUT = 15


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


@contextmanager
def closing_reported(resource, report, label, method="close"):
    """Record cleanup failures without replacing an exception already in flight."""
    failed = False
    try:
        yield resource
    except BaseException:
        failed = True
        raise
    finally:
        try:
            getattr(resource, method)()
        except Exception as error:
            report.setdefault("cleanup_errors", []).append({"resource": label,
                "error": f"{type(error).__name__}: {error}"})
            if not failed:
                raise


class DeadlineConnection(http.client.HTTPConnection):
    """A transaction deadline as well as a socket inactivity timeout."""
    def connect(self):
        super().connect()
        owned_socket = self.sock

        def expire():
            try:
                owned_socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        self.deadline = threading.Timer(TIMEOUT, expire)
        self.deadline.daemon = True
        self.deadline.start()

    def getresponse(self):
        # HTTPConnection implicitly closes itself at headers for Connection: close,
        # while HTTPResponse still owns a readable socket file. Keep that socket's
        # deadline until our caller explicitly finishes the transaction.
        self.reading_headers = True
        try:
            return super().getresponse()
        finally:
            self.reading_headers = False

    def close(self):
        if hasattr(self, "deadline") and not getattr(self, "reading_headers", False):
            self.deadline.cancel()
        super().close()


def read_small_response(response):
    data, deadline = bytearray(), time.monotonic() + TIMEOUT
    try:
        while True:
            require(time.monotonic() < deadline, "Control response timed out")
            chunk = response.read1(CHUNK)
            if not chunk:
                length = response.getheader("Content-Length")
                require(length is None or len(data) == int(length), "Control response was truncated")
                return bytes(data)
            data += chunk
            require(len(data) <= MIB, "Control response exceeded one MiB")
    finally:
        response.close()


def check_resources(sample, baseline, max_growth):
    """Exact ownership counters; footprint has a separate allocator allowance."""
    require(sample["connections"] == 0, f"Connections remain: {sample}")
    require(sample["accepted"] == sample["closed"], f"Connection accounting differs: {sample}")
    require(sample["reserved_bytes"] == 0, f"Memory reservations remain: {sample}")
    require(sample["uploads"] == sample["downloads"] == 0, f"Active transfers remain: {sample}")
    if baseline is not None:
        require(sample["descriptors"] <= baseline["descriptors"], f"Descriptors grew: {baseline} -> {sample}")
        require(sample["footprint_bytes"] <= baseline["footprint_bytes"] + max_growth,
                f"Memory footprint exceeded allowance: {baseline} -> {sample}")


def check_entries(directory, expected):
    actual = {entry.name for entry in directory.iterdir()}
    require(actual == set(expected), f"Unexpected contents of {directory.name}: {sorted(actual)}; expected {sorted(expected)}")


class Host:
    def __init__(self, binary, temporary_library, directory, log, report=None):
        self.directory = directory
        self.tmp = directory / "tmp"
        self.shares = {kind: directory / kind for kind in ("uploader", "dav")}
        for path in [self.tmp, *self.shares.values()]:
            path.mkdir()
        self.process = subprocess.Popen(
            [str(binary), *(str(path) for path in self.shares.values())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
            env={**os.environ, "TMPDIR": str(self.tmp) + "/", "DYLD_INSERT_LIBRARIES": str(temporary_library)}, bufsize=0)
        try:
            ready = self.read()
            require(ready.get("ready"), f"Host did not start: {ready}")
            require(ready["pid"] == self.process.pid, "Unexpected host PID")
            require(Path(ready["temporary_directory"]).resolve() == self.tmp.resolve(),
                    "Host temporary directory is not owned by this run")
            self.ports = {kind: ready[kind + "_port"] for kind in self.shares}
        except BaseException:
            with closing_reported(self, report if report is not None else {}, "host_startup"):
                raise

    def read(self):
        # Unbuffered pipe + explicit deadline: a wedged host must fail the run.
        deadline = time.monotonic() + TIMEOUT
        data = bytearray()
        while not data.endswith(b"\n"):
            remaining = deadline - time.monotonic()
            require(remaining > 0, "Host control response timed out")
            require(select.select([self.process.stdout], [], [], remaining)[0], "Host control response timed out")
            byte = os.read(self.process.stdout.fileno(), 1)
            require(byte, f"Host exited unexpectedly ({self.process.poll()})")
            data += byte
            require(len(data) <= 64 * 1024, "Host control response too large")
        reply = json.loads(data)
        require("error" not in reply, f"Host error: {reply}")
        require("error" not in reply.get("resources", {}), f"Host metrics error: {reply}")
        return reply

    def command(self, command):
        self.process.stdin.write(json.dumps({"command": command}).encode() + b"\n")
        return self.read()

    def stats(self):
        return self.command("stats")["resources"]

    def close(self):
        if self.process.poll() is None:
            # EOF requests clean stop even when a failing run has active clients.
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.stdout.close()


class Runner:
    def __init__(self, host, args, report):
        self.host, self.args, self.report = host, args, report
        self.lock = threading.Lock()
        self.asset = hashlib.shake_256(b"WebServerKit endurance asset").digest(args.asset_mib * MIB)
        self.asset_hash = digest(self.asset)
        self.baseline = None
        self.stopped_baseline = None
        self.expected = {kind: {"asset.bin"} for kind in host.shares}
        for share in host.shares.values():
            (share / "asset.bin").write_bytes(self.asset)

    def count(self, **counts):
        with self.lock:
            for key, value in counts.items():
                self.report[key] = self.report.get(key, 0) + value

    def connection(self, kind):
        # Never accepts a target URL: only ports returned by our own child process.
        return DeadlineConnection("127.0.0.1", self.host.ports[kind], timeout=TIMEOUT)

    def path(self, kind, name):
        return "/download?" + urlencode({"path": "/" + name}) if kind == "uploader" else "/" + name

    def verify_response(self, response, expected_hash, length, status=200, prefix=b""):
        try:
            require(response.status == status, f"Expected HTTP {status}, got {response.status}")
            checksum, size = hashlib.sha256(prefix), len(prefix)
            deadline = time.monotonic() + TIMEOUT
            while True:
                require(time.monotonic() < deadline, "Download exceeded transaction deadline")
                chunk = response.read1(CHUNK)
                if not chunk:
                    break
                checksum.update(chunk)
                size += len(chunk)
                require(size <= length, "Downloaded body exceeded expected length")
            require(size == length, f"Body length differs: {size} != {length}")
            require(checksum.hexdigest() == expected_hash, "Downloaded SHA-256 differs")
            self.count(requests=1, verified_bytes=size)
        finally:
            # Some Python versions leave a known-length read1() response open at
            # length zero. Close its reader explicitly so the connection is reusable.
            response.close()

    def download(self, kind, name="asset.bin", data=None, reuse=False):
        data = self.asset if data is None else data
        with closing(self.connection(kind)) as connection:
            previous = None
            for _ in range(2 if reuse else 1):
                connection.request("GET", self.path(kind, name), headers={"Accept-Encoding": "identity"})
                if previous is not None:
                    require(connection.sock is previous, "GET did not reuse its connection")
                previous = connection.sock
                self.verify_response(connection.getresponse(), digest(data), len(data))
        if reuse:
            self.count(reused_connections=1)

    def begin_upload(self, kind, name, data):
        connection = self.connection(kind)
        try:
            headers = {"Connection": "close"}
            if kind == "uploader":
                boundary = "wsk-endurance-boundary"
                # A completed argument exercises reservation ownership as well as
                # file streaming. Deliberately keep the file part unfinished.
                prefix = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n/\r\n"
                          f"--{boundary}\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\n").encode()
                prefix += b"n" * CHUNK
                prefix += (f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"files[]\"; filename=\"{name}\"\r\n"
                           "Content-Type: application/octet-stream\r\n\r\n").encode()
                suffix = f"\r\n--{boundary}--\r\n".encode()
                headers.update({"Content-Type": f"multipart/form-data; boundary={boundary}", "Accept": "application/json"})
                method, path = "POST", "/upload"
            else:
                prefix, suffix = b"", b""
                headers["Content-Type"] = "application/octet-stream"
                method, path = "PUT", "/" + name
            headers["Content-Length"] = str(len(prefix) + len(data) + len(suffix))
            connection.putrequest(method, path)
            for name, value in headers.items():
                connection.putheader(name, value)
            connection.endheaders()
            connection.send(prefix + data[:CHUNK])
            return connection, data[CHUNK:] + suffix
        except BaseException:
            with closing_reported(connection, self.report, "upload_connection"):
                raise

    def wait_for(self, predicate, message):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            sample = self.host.stats()
            if predicate(sample):
                return sample
            time.sleep(0.05)
        raise AssertionError(f"{message}: {sample}")

    def concurrent_uploads(self, kind, cycle):
        release = threading.Event()
        data = [hashlib.shake_256(f"{kind}:{cycle}:{i}".encode()).digest(self.args.upload_mib * MIB) for i in range(4)]
        names = [f"upload-{i}.bin" for i in range(4)]

        def upload(index):
            connection, remainder = self.begin_upload(kind, names[index], data[index])
            try:
                require(release.wait(TIMEOUT), "Upload overlap gate timed out")
                for offset in range(0, len(remainder), CHUNK):
                    connection.send(remainder[offset:offset + CHUNK])
                response = connection.getresponse()
                require(response.status == (200 if kind == "uploader" else 201), f"Upload failed: HTTP {response.status}")
                read_small_response(response)
                self.count(requests=1, completed_uploads=1)
            finally:
                connection.close()

        with ThreadPoolExecutor(max_workers=6) as pool:
            futures = [pool.submit(upload, i) for i in range(4)]
            try:
                self.wait_for(lambda s: s["uploads"] >= 4 and len(list(self.host.tmp.iterdir())) >= 4
                              and (kind != "uploader" or s["reserved_bytes"] > 0), "Four upload bodies did not overlap")
                # These must finish while all four upload bodies are still held.
                downloads = [pool.submit(self.download, peer, reuse=True) for peer in self.host.shares]
                for future in downloads:
                    future.result(timeout=TIMEOUT)
                require(self.host.stats()["uploads"] >= 4, "Uploads ended before overlapping downloads completed")
                self.count(overlap_groups=1)
            finally:
                release.set()
            for future in futures:
                future.result(timeout=TIMEOUT)
        for name, payload in zip(names, data):
            self.expected[kind].add(name)
            require(digest((self.host.shares[kind] / name).read_bytes()) == digest(payload), "Stored upload SHA-256 differs")
            self.download(kind, name, payload)

    def cancel_upload(self, kind):
        name = "cancelled.bin"
        connection, _ = self.begin_upload(kind, name, self.asset)
        try:
            self.wait_for(lambda s: s["uploads"] >= 1 and bool(list(self.host.tmp.iterdir())), "Cancelled upload never reached disk")
        finally:
            connection.close()
        self.count(cancelled_uploads=1)

    def resume(self, kind, changed=False):
        name = "changing.bin" if changed else "asset.bin"
        if changed:
            (self.host.shares[kind] / name).write_bytes(self.asset)
        try:
            with closing(self.connection(kind)) as connection:
                connection.request("GET", self.path(kind, name), headers={"Accept-Encoding": "identity"})
                response = connection.getresponse()
                require(response.status == 200, f"Initial download failed: {response.status}")
                etag = response.getheader("ETag")
                require(etag and not etag.startswith("W/"), "Resume needs a strong entity tag")
                prefix = response.read(CHUNK)
                require(prefix == self.asset[:CHUNK], "Interrupted download prefix differs")
                response.close()
            self.count(interrupted_downloads=1)
            replacement = None
            if changed:
                replacement = b"changed!" + self.asset[8:]
                staging = self.host.shares[kind] / "replacement.tmp"
                staging.write_bytes(replacement)
                os.replace(staging, self.host.shares[kind] / name)
            with closing(self.connection(kind)) as connection:
                connection.request("GET", self.path(kind, name), headers={
                    "Accept-Encoding": "identity", "Range": f"bytes={len(prefix)}-", "If-Range": etag})
                response = connection.getresponse()
                if changed:
                    self.verify_response(response, digest(replacement), len(replacement))
                    self.count(changed_file_fallbacks=1)
                else:
                    require(response.getheader("Content-Range") == f"bytes {len(prefix)}-{len(self.asset)-1}/{len(self.asset)}",
                            "Resumed Content-Range differs")
                    self.verify_response(response, self.asset_hash, len(self.asset), status=206, prefix=prefix)
                    self.count(resumed_downloads=1)
        finally:
            if changed:
                (self.host.shares[kind] / name).unlink(missing_ok=True)

    def quiescent(self, baseline):
        deadline, stable, last_error = time.monotonic() + TIMEOUT, 0, None
        while time.monotonic() < deadline:
            sample = self.host.stats()
            try:
                check_resources(sample, baseline, self.args.max_footprint_growth_mib * MIB)
                check_entries(self.host.tmp, set())
                for kind, share in self.host.shares.items():
                    check_entries(share, self.expected[kind])
                stable += 1
                if stable == 3:
                    return sample
            except AssertionError as error:
                last_error, stable = error, 0
            time.sleep(0.1)
        raise AssertionError(f"Resources did not settle: {last_error}; last sample: {sample}")

    def delete_uploads(self):
        for kind in self.host.shares:
            for name in sorted(self.expected[kind] - {"asset.bin"}):
                with closing(self.connection(kind)) as connection:
                    if kind == "uploader":
                        connection.request("POST", "/delete", body=urlencode({"path": "/" + name}),
                                           headers={"Content-Type": "application/x-www-form-urlencoded", "Connection": "close"})
                    else:
                        connection.request("DELETE", "/" + name)
                    response = connection.getresponse()
                    require(response.status == (200 if kind == "uploader" else 204), f"Delete failed: {response.status}")
                    read_small_response(response)
                    self.count(requests=1)
                self.expected[kind].remove(name)

    def cycle(self, number):
        for kind in self.host.shares:
            self.concurrent_uploads(kind, number)
            self.quiescent(self.baseline)
            self.cancel_upload(kind)
            self.quiescent(self.baseline)
            self.resume(kind)
            self.resume(kind, changed=True)
        self.delete_uploads()
        return self.quiescent(self.baseline)

    def lifecycle(self):
        # Stop is not a connection-teardown barrier. Finish two partially consumed
        # downloads after stop, then poll for teardown. Some bytes may already be
        # buffered in the kernel; this does not claim to prove a pending write.
        connections = []
        try:
            for kind in self.host.shares:
                connection = self.connection(kind)
                connections.append(connection)
                connection.request("GET", self.path(kind, "asset.bin"))
            responses = [connection.getresponse() for connection in connections]
            require(not self.host.command("stop")["running"], "Servers did not stop listening")
            for response in responses:
                self.verify_response(response, self.asset_hash, len(self.asset))
        finally:
            for connection in connections:
                connection.close()
        stopped = self.quiescent(self.stopped_baseline)
        if self.stopped_baseline is None:
            self.stopped_baseline = stopped
        require(self.host.command("start")["running"], "Servers did not restart")
        for kind in self.host.shares:
            self.download(kind)
        self.count(restarts=1)
        return self.quiescent(self.baseline)


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def nonnegative(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must be nonnegative")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    length = parser.add_mutually_exclusive_group()
    length.add_argument("--cycles", type=positive, help="number of measured rounds (default: 10)")
    length.add_argument("--duration", type=positive, help="minimum seconds of measured continuous serving")
    parser.add_argument("--upload-mib", type=positive, default=2)
    parser.add_argument("--asset-mib", type=positive, default=8)
    parser.add_argument("--restart-cycles", type=nonnegative, default=5, help="lifecycle rounds AFTER continuous serving (default: 5)")
    parser.add_argument("--pause", type=nonnegative, default=1, help="seconds between continuous rounds (default: 1)")
    parser.add_argument("--max-footprint-growth-mib", type=nonnegative, default=64)
    parser.add_argument("--report", type=Path, help="JSON report path; host log is saved beside it")
    args = parser.parse_args()
    args.cycles = args.cycles or (None if args.duration else 10)
    report_path = args.report or REPOSITORY / "build" / (time.strftime("endurance-%Y%m%d-%H%M%S") + ".json")
    report_path = report_path.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "cycles": 0, "configuration": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
              "sample_log": str(report_path.with_suffix(".samples.jsonl")),
              "host_log": str(report_path.with_suffix(".host.log"))}
    started = time.monotonic()
    try:
        subprocess.run(["swift", "build", "--package-path", str(PACKAGE), "-c", "release"], check=True)
        binary_path = subprocess.check_output(["swift", "build", "--package-path", str(PACKAGE), "-c", "release", "--show-bin-path"], text=True).strip()
        temporary_library = Path(binary_path) / "EnduranceTemporaryDirectory.dylib"
        subprocess.run(["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-framework", "Foundation",
                        str(PACKAGE / "TemporaryDirectory.m"), "-o", str(temporary_library)], check=True)
        with closing_reported(tempfile.TemporaryDirectory(prefix="wsk-endurance-"), report, "temporary_directory", "cleanup") as temporary, \
                closing_reported(report_path.with_suffix(".host.log").open("wb"), report, "host_log") as log, \
                closing_reported(report_path.with_suffix(".samples.jsonl").open("w"), report, "samples_log") as samples:
            host = Host(Path(binary_path) / "EnduranceHost", temporary_library, Path(temporary.name), log, report=report)
            with closing_reported(host, report, "host"):
                report["host_pid"] = host.process.pid
                runner = Runner(host, args, report)
                # Warm every path BEFORE fixing baselines. Counters remain cumulative.
                runner.cycle("warmup")
                runner.lifecycle()
                runner.baseline = runner.quiescent(None)
                report["baseline"] = runner.baseline
                report["stopped_baseline"] = runner.stopped_baseline
                measured = time.monotonic()
                checkpoint = measured
                report_path.write_text(json.dumps(report, indent=2) + "\n")
                while (report["cycles"] < args.cycles if args.cycles else time.monotonic() - measured < args.duration):
                    sample = runner.cycle(report["cycles"])
                    report["cycles"] += 1
                    samples.write(json.dumps({"cycle": report["cycles"], "elapsed": round(time.monotonic() - measured, 3), **sample}) + "\n")
                    samples.flush()
                    report["max_quiescent_footprint_bytes"] = max(sample["footprint_bytes"], report.get("max_quiescent_footprint_bytes", 0))
                    if time.monotonic() - checkpoint >= 60:
                        report_path.write_text(json.dumps(report, indent=2) + "\n")
                        checkpoint = time.monotonic()
                    print(f"round {report['cycles']}: {sample['accepted']} connections, {sample['descriptors']} fds, "
                          f"{sample['reserved_bytes']} reserved bytes, {report['verified_bytes'] / MIB:.1f} MiB verified", flush=True)
                    time.sleep(args.pause)
                report["continuous_seconds"] = round(time.monotonic() - measured, 3)
                for _ in range(args.restart_cycles):
                    runner.lifecycle()
                report["final"] = runner.quiescent(runner.baseline)
                host.command("stop")
                report["final_stopped"] = runner.quiescent(runner.stopped_baseline)
                host.command("shutdown")
                require(host.process.wait(timeout=TIMEOUT) == 0, "Host shutdown failed")
        report["passed"] = True
    except (Exception, KeyboardInterrupt) as error:
        report["passed"] = False
        report["error"] = f"{type(error).__name__}: {error}"
        print(report["error"], file=sys.stderr)
    finally:
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{'PASS' if report['passed'] else 'FAIL'}: {report_path}", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
