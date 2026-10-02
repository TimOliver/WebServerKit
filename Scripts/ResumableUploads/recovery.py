#!/usr/bin/env python3
"""Bounded resumable storage-failure and process-exit recovery on owned loopback hosts."""
import argparse
import base64
import errno
import hashlib
import http.client
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
import uuid
from urllib.parse import quote, urlencode

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parent.parent
sys.path.insert(0, str(HERE.parent / "Endurance"))
from run import (Host, DeadlineConnection, MIB, TIMEOUT, check_resources,
                 closing_reported, digest, read_small_response, require)

TUS = {"Tus-Resumable": "1.0.0"}


def build(faults=True):
    package = HERE.parent / "Endurance"
    subprocess.run(["swift", "build", "--package-path", str(package), "-c", "release"], check=True)
    binary_dir = Path(subprocess.check_output(["swift", "build", "--package-path", str(package), "-c", "release", "--show-bin-path"], text=True).strip())
    libraries = []
    sources = [package / "TemporaryDirectory.m"] + ([HERE / "StorageFaults.m"] if faults else [])
    for source in sources:
        output = binary_dir / ("Resumable" + source.stem + ".dylib")
        subprocess.run(["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-framework", "Foundation", str(source), "-o", str(output)], check=True)
        libraries.append(output)
    return binary_dir / "EnduranceHost", libraries


class ResumableHost(Host):
    """No target parameter: every HTTP port comes from our own child over stdin."""
    def __init__(self, binary, libraries, root, log, report=None, ttl=None, shared_directory=None):
        self.binary, self.libraries, self.directory, self.log = Path(binary), libraries, Path(root), log
        self.report, self.ttl = report if report is not None else {}, ttl
        self.control_lock = threading.Lock()
        self.tmp, self.shared, self.sessions = (self.directory / name for name in ("tmp", "shared", "sessions"))
        self.cross_volume_share = Path(shared_directory) if shared_directory is not None else None
        if self.cross_volume_share is not None:
            self.shared = self.cross_volume_share
        self.shares = {kind: self.shared for kind in ("uploader", "dav")}
        for path in (self.tmp, self.shared, self.sessions):
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.launch()

    def launch(self):
        environment = {**os.environ, "TMPDIR": str(self.tmp) + "/",
                       "WSK_ENDURANCE_RESUMABLE_DIRECTORY": str(self.sessions),
                       "DYLD_INSERT_LIBRARIES": ":".join(str(path) for path in self.libraries)}
        if self.ttl is not None:
            environment["WSK_ENDURANCE_RESUMABLE_TIMEOUT"] = str(self.ttl)
        if self.cross_volume_share is not None:
            environment["WSK_RECOVERY_CROSS_VOLUME_SHARE"] = str(self.cross_volume_share)
        self.process = subprocess.Popen([str(self.binary), str(self.shared), str(self.shared)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                        env=environment, bufsize=0)
        try:
            ready = self.read()
            require(ready.get("ready") and ready["pid"] == self.process.pid, "Unexpected child identity")
            require(Path(ready["temporary_directory"]).resolve() == self.tmp.resolve(), "Child temporary directory escaped ownership")
            self.ports = {kind: ready[kind + "_port"] for kind in self.shares}
        except BaseException:
            self.close()
            raise

    def restart(self):
        self.close()
        self.launch()


class Protocol:
    def __init__(self, host):
        self.host = host

    def request(self, kind, method, path, body=b"", headers=None, expected=(200,)):
        connection = DeadlineConnection("127.0.0.1", self.host.ports[kind], timeout=TIMEOUT)
        try:
            connection.request(method, path, body=body, headers={"Connection": "close", **(headers or {})})
            response = connection.getresponse()
            status, result_headers = response.status, {key.lower(): value for key, value in response.getheaders()}
            # Downloads are bounded synthetic assets. Control replies remain capped.
            if method == "GET":
                result = response.read(8 * MIB + 1)
                require(len(result) <= 8 * MIB, "Synthetic download exceeded its bound")
                response.close()
            elif method == "HEAD":
                result = response.read()
                response.close()
            else:
                result = read_small_response(response)
            require(status in expected, f"{method} {path}: HTTP {status}, expected {expected}: {result[:256]!r}")
            return status, result_headers, result
        finally:
            connection.close()

    def create(self, name, data, key=None):
        item = {"key": key or str(uuid.uuid4()), "name": name, "data": data, "sha256": digest(data), "offset": 0}
        item["url"] = "/uploads/" + item["key"]
        metadata = {"filename": name, "path": "/", "sha256": item["sha256"]}
        item["metadata"] = ",".join(key + " " + base64.b64encode(value.encode()).decode() for key, value in metadata.items())
        _, headers, _ = self.request("uploader", "POST", "/uploads", headers={**TUS, "Upload-Key": item["key"], "Upload-Length": str(len(data)), "Upload-Metadata": item["metadata"]}, expected=(201,))
        require(headers.get("location") == item["url"], "Creation changed the idempotency key")
        self.offset(headers, len(data) if not data else 0)
        return item

    @staticmethod
    def offset(headers, expected):
        require(headers.get("tus-resumable") == "1.0.0", "Response omitted protocol version")
        require(int(headers["upload-offset"]) == expected, f"Offset differs: {headers}, expected {expected}")

    def head(self, item):
        _, headers, _ = self.request("uploader", "HEAD", item["url"], headers=TUS)
        require(int(headers["upload-length"]) == len(item["data"]), "Saved length changed")
        item["offset"] = int(headers["upload-offset"])
        return item["offset"]

    def patch(self, item, offset, data, expected=(204,)):
        result = self.request("uploader", "PATCH", item["url"], body=data,
                              headers={**TUS, "Upload-Offset": str(offset), "Content-Type": "application/offset+octet-stream"}, expected=expected)
        if result[0] == 204:
            self.offset(result[1], offset + len(data))
            item["offset"] = offset + len(data)
        return result

    def finish(self, item):
        offset = self.head(item)
        while offset < len(item["data"]):
            data = item["data"][offset:offset + MIB]
            self.patch(item, offset, data)
            offset += len(data)
        require(self.head(item) == len(item["data"]), "Completion did not retain its receipt")

    def verify(self, item, actual_name=None):
        name = actual_name or item["name"]
        for kind in self.host.shares:
            path = "/download?" + urlencode({"path": "/" + name}) if kind == "uploader" else "/" + quote(name)
            _, _, data = self.request(kind, "GET", path)
            require(len(data) == len(item["data"]) and digest(data) == item["sha256"], f"{kind} saved checksum differs")

    def delete(self, item):
        self.request("uploader", "DELETE", item["url"], headers=TUS, expected=(204,))


def inventory(path):
    return sorted(str(item.relative_to(path)) for item in path.rglob("*") if item.is_file() or item.is_symlink())


def idle(host, baseline=None, *, expected_files=(), sessions=True):
    deadline, samples = time.monotonic() + 15, []
    while time.monotonic() < deadline:
        sample = host.stats()
        try:
            check_resources(sample, baseline, 64 * MIB)
            require(set(path.name for path in host.shared.iterdir()) == set(expected_files), "Share has missing/duplicate files")
            require(not list(host.tmp.iterdir()), f"Request temporary files remain: {inventory(host.tmp)}")
            if sessions:
                require(set(path.name for path in host.sessions.iterdir()) <= {".lock"}, f"Session residue remains: {inventory(host.sessions)}")
        except AssertionError:
            samples = []
        else:
            samples.append(sample)
            if len(samples) == 3:
                return samples[-1]
        time.sleep(.05)
    check_resources(sample, baseline, 64 * MIB)
    raise AssertionError(f"Not quiescent: tmp={inventory(host.tmp)}, sessions={inventory(host.sessions)}, share={inventory(host.shared)}")

# Every failure starts after a real acknowledged 1 MiB prefix. Non-final
# manifest cases have a third chunk, so active offset commits are distinguishable
# from publication and completion receipts.
CASES = (
    "payload-write-enospc", "payload-write-eio", "payload-fsync-eio", "payload-close-eio",
    "manifest-active-fsync-eio", "manifest-active-close-eio", "manifest-publishing-fsync-eio", "manifest-complete-close-eio", "stage-close-eio",
    "manifest-active-write-enospc", "manifest-active-rename-eio",
    "manifest-publishing-rename-eio", "stage-write-enospc", "stage-fsync-eio",
    "publication-rename-eio", "manifest-complete-rename-eio",
    "exit-payload-write", "exit-payload-fsync", "exit-active-save",
    "exit-stage-open", "exit-publishing-save", "exit-stage-write", "exit-stage-fsync",
    "exit-publication-before", "exit-publication-after", "exit-complete-save",
)


def authoritative_offset(mode, length):
    if mode.startswith("manifest-complete-") or mode in ("exit-publication-after", "exit-complete-save"):
        return length
    return 2 * MIB if mode == "exit-active-save" else MIB


def verify_fault(fault, mode, sessions, shared, key):
    require(fault.get("mode") == mode and fault.get("hits") == 1 and fault.get("armed"),
            f"Fault was not exercised exactly once: {fault}")
    event = fault.get("event", {})
    path = Path(event.get("path", ""))
    require(event.get("exists") and event.get("device", 0) > 0 and event.get("inode", 0) > 0,
            "Fault proof lacks an existing filesystem identity")
    require(event.get("errno") == (0 if mode.startswith("exit-") else errno.ENOSPC if mode.endswith("enospc") else errno.EIO),
            "Fault proof reports the wrong failure")
    if mode == "exit-publication-after":
        require(path == shared.resolve() / "target (1).bin", "Exit selected an unrelated published file")
    else:
        require(path.parent == sessions.resolve() / key, "Fault selected another session or directory")
        if "payload" in mode:
            require(path.name == "payload", "Fault selected a non-payload file")
        elif "stage" in mode or "publication" in mode:
            require(path.name.startswith(".stage-") and str(uuid.UUID(path.name[7:])) == path.name[7:].lower(),
                    "Fault selected a non-staging file")
        elif mode.startswith("exit-"):
            require(path.name == "manifest.json", "Exit selected an uncommitted manifest")
        else:
            require(path.name.startswith(".manifest-") and str(uuid.UUID(path.name[10:])) == path.name[10:].lower(),
                    "Fault selected a non-manifest file")
    if "write-" in mode and "manifest" not in mode:
        require(fault["bytes_written"] >= 65536, "Write failure lacked a real persisted prefix")
    if mode == "exit-stage-open":
        require(event.get("operation") == "open-after" and event.get("size") == 0,
                "Stage-create exit did not happen after an empty file was created")
    if mode.endswith("close-eio"):
        require(event.get("operation") == "close-after-success", "Close failure was not after a real successful close")


def case(host, mode, report):
    row = {"mode": mode, "existing_destination": True, "passed": False}
    report["cases"].append(row)
    protocol = Protocol(host)
    data = hashlib.shake_256(("resumable failure " + mode).encode()).digest((3 if "active" in mode else 2) * MIB)
    original = b"Existing files retain their exact identity and bytes."
    original_path = host.shared / "target.bin"
    original_path.write_bytes(original)
    original_identity = (original_path.stat().st_dev, original_path.stat().st_ino)
    asset = {"name": "target.bin", "data": original, "sha256": digest(original)}
    protocol.verify(asset)
    row["baseline"] = idle(host, expected_files={"target.bin"})
    item = protocol.create("target.bin", data)
    row["key"] = item["key"]
    protocol.patch(item, 0, data[:MIB])
    require(protocol.head(item) == MIB, "Initial prefix was not acknowledged")
    row["confirmed_before"] = MIB
    host.command("fault-arm", mode=mode, key=item["key"])
    if mode.startswith("exit-"):
        try:
            protocol.patch(item, MIB, data[MIB:2 * MIB])
        except (OSError, http.client.HTTPException) as error:
            row["lost_reply"] = type(error).__name__
        else:
            raise AssertionError("Process-exit case received a successful reply; fault did not fire")
        require(host.process.wait(timeout=TIMEOUT) == 86, "Child did not exit at the selected syscall boundary")
        event_path = host.directory / "fault-event.json"
        require(event_path.exists(), "Exit lacks durable proof that the fault fired")
        row["fault"] = json.loads(event_path.read_text())
        row["at_exit"] = {"tmp": inventory(host.tmp), "sessions": inventory(host.sessions), "share": inventory(host.shared)}
        host.restart()
        row["restarted_pid"] = host.process.pid
    else:
        expected = 507 if mode.endswith("enospc") else 500
        status, _, _ = protocol.patch(item, MIB, data[MIB:2 * MIB], expected=(expected,))
        row["failure_status"] = status
        row["fault"] = host.command("fault-stats")
        host.command("fault-clear")
    verify_fault(row["fault"], mode, host.sessions, host.shared, item["key"])
    expected_offset = authoritative_offset(mode, len(data))
    actual = protocol.head(item)
    row["confirmed_after"] = actual
    require(actual == expected_offset, f"Unacknowledged or committed bytes misreported: {actual} != {expected_offset}")
    # Request bodies are fully spooled at these boundaries; both their temporary
    # storage and publication staging must disappear after recovery.
    row["after_recovery"] = {"tmp": inventory(host.tmp), "sessions": inventory(host.sessions), "share": inventory(host.shared)}
    payload_path = host.sessions / item["key"] / "payload"
    require(not payload_path.exists() if actual == len(data) else payload_path.read_bytes() == data[:actual],
            "Persisted payload disagrees with the authoritative offset")
    require(not [p for p in (host.sessions / item["key"]).iterdir() if p.name.startswith((".stage-", ".manifest-"))],
            "Recovery retained an unjournaled staging or manifest file")
    require(original_path.read_bytes() == original and (original_path.stat().st_dev, original_path.stat().st_ino) == original_identity,
            "Failure changed the original destination")
    if expected_offset < len(data):
        require(set(p.name for p in host.shared.iterdir()) == {"target.bin"}, "Incomplete upload was exposed in the share")
    # Unrelated reads remain usable following every failure, then retry follows
    # only the authoritative offset and reaches one exact final publication.
    protocol.verify(asset)
    protocol.finish(item)
    protocol.verify(item, "target (1).bin")
    require(set(p.name for p in host.shared.iterdir()) == {"target.bin", "target (1).bin"}, "Retry produced duplicate filenames")
    # Repeating the final creation key observes the receipt, never another file.
    _, headers, _ = protocol.request("uploader", "POST", "/uploads", headers={**TUS, "Upload-Key": item["key"], "Upload-Length": str(len(data)), "Upload-Metadata": item["metadata"]}, expected=(201,))
    protocol.offset(headers, len(data))
    protocol.delete(item)
    protocol.request("dav", "DELETE", "/target%20%281%29.bin", expected=(204,))
    require(original_path.read_bytes() == original and (original_path.stat().st_dev, original_path.stat().st_ino) == original_identity,
            "Completion changed the original destination")
    row["final"] = idle(host, row["baseline"], expected_files={"target.bin"})
    original_path.unlink()
    row["passed"] = True
    print(f"PASS {mode}: {MIB} -> {actual} -> {len(data)} bytes", flush=True)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=REPOSITORY / "build" / "resumable-recovery.json")
    parser.add_argument("--case", choices=CASES, action="append", dest="cases")
    parser.add_argument("--host", type=Path)
    parser.add_argument("--temporary-library", type=Path)
    parser.add_argument("--fault-library", type=Path)
    args = parser.parse_args()
    supplied = (args.host, args.temporary_library, args.fault_library)
    if any(supplied) and not all(supplied):
        parser.error("Supply all three built host/library paths or none")
    report_path = args.report.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "cases": [], "platform": platform.platform(),
              "scope": "Owned loopback host; real resumable syscalls with injected errors/process exit, not physical disk exhaustion or power loss",
              "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPOSITORY, text=True).strip(),
              "source_sha256": {str(path.relative_to(REPOSITORY)): digest(path.read_bytes()) for path in
                                  (Path(__file__), HERE / "StorageFaults.m", HERE.parent / "Endurance/run.py", HERE.parent / "Endurance/TemporaryDirectory.m", HERE.parent / "Endurance/Sources/EnduranceHost/main.m", REPOSITORY / "Sources/WebServerKitUploader/WSKResumableUploadStore.m", REPOSITORY / "Sources/WebServerKitUploader/WSKWebUploader.m")}}
    started = time.monotonic()
    try:
        binary, libraries = (args.host.resolve(), [args.temporary_library.resolve(), args.fault_library.resolve()]) if args.host else build()
        with tempfile.TemporaryDirectory(prefix="wsk-resumable-recovery-") as temporary, report_path.with_suffix(".host.log").open("wb") as log:
            # Isolate cases: crash cleanup must be attributed to the case that
            # created it, never a later case or another user's process.
            for index, mode in enumerate(args.cases or CASES):
                root = Path(temporary) / str(index)
                with closing_reported(ResumableHost(binary, libraries, root, log, report), report, "host") as host:
                    case(host, mode, report)
                    require(not host.command("shutdown")["running"], "Host failed to stop")
                    require(host.process.wait(timeout=TIMEOUT) == 0, "Host shutdown failed")
                report_path.write_text(json.dumps(report, indent=2) + "\n")
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
