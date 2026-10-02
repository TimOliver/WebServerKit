#!/usr/bin/env python3
"""Owned sparse APFS image: publication recovery across actual filesystem volumes."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

from recovery import MIB, Protocol, ResumableHost, build, idle, require


def case(binary, libraries, root, volume, mode, report, log):
    row = {"mode": mode, "passed": False}
    report["cases"].append(row)
    directory = root / mode
    shared = volume / mode / "shared"
    host = ResumableHost(binary, libraries, directory, log, report, shared_directory=shared)
    try:
        require(host.sessions.stat().st_dev != shared.stat().st_dev, "Case did not use different filesystems")
        row.update(session_device=host.sessions.stat().st_dev, destination_device=shared.stat().st_dev)
        protocol = Protocol(host)
        data = hashlib.shake_256(mode.encode()).digest(2 * MIB)
        item = protocol.create("recovered.bin", data)
        protocol.patch(item, 0, data[:MIB])
        require(protocol.head(item) == MIB, "Prefix was not acknowledged")
        row["key"] = item["key"]
        pool = shared.parent / ".WebServerKit-ResumableStaging-v1"
        # Seed independent entries only in this disposable image. The reaper
        # must preserve an unrelated file and a confirmed-live creator's stage.
        pool.mkdir(mode=0o700)
        sentinel = pool / "host-owned-sentinel"
        live = pool / f"WebServerKit-stage-v1-{os.getpid()}-{uuid.uuid4()}"
        sentinel.write_bytes(b"unrelated data")
        live.write_bytes(b"live publisher data")
        old_pid = host.process.pid
        host.command("fault-arm", mode=mode, key=item["key"])
        try:
            protocol.patch(item, MIB, data[MIB:])
        except (OSError, http.client.HTTPException):
            pass
        else:
            raise AssertionError("Expected process exit did not occur")
        require(host.process.wait(timeout=10) == 86, "Child did not exit at the selected boundary")
        event = json.loads((directory / "fault-event.json").read_text())
        row["fault"] = event
        require(event["mode"] == mode and event["hits"] == 1 and event["event"]["exists"], "Missing fault proof")
        selected = Path(event["event"]["path"])
        require(event["event"]["device"] == shared.stat().st_dev, "Stage was not on the destination filesystem")
        if mode == "exit-publication-after":
            require(selected == shared.resolve() / item["name"], "Exit selected another publication")
        else:
            prefix = f"WebServerKit-stage-v1-{old_pid}-"
            require(selected.parent == pool.resolve() and selected.name.startswith(prefix), "Exit selected another stage")
            uuid.UUID(selected.name[len(prefix):])
        if mode == "exit-stage-open":
            require(event["event"]["size"] == 0 and event["event"]["operation"] == "open-after", "Wrong create boundary")
            manifest = json.loads((host.sessions / item["key"] / "manifest.json").read_text())
            require(manifest["state"] == "active" and "journal" not in manifest, "Stage-create exit already had a journal")
        row["at_exit_stages"] = sorted(p.name for p in pool.iterdir())
        host.restart()
        require(host.process.pid != old_pid, "A new process was not launched")
        expected = len(data) if mode == "exit-publication-after" else MIB
        require(protocol.head(item) == expected, "Authoritative offset changed incorrectly")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and set(p.name for p in pool.iterdir()) != {sentinel.name, live.name}:
            time.sleep(.05)
        require(set(p.name for p in pool.iterdir()) == {sentinel.name, live.name}, "Abandoned stage survived recovery")
        require(sentinel.read_bytes() == b"unrelated data" and live.read_bytes() == b"live publisher data", "Cleanup touched another owner")
        protocol.finish(item)
        protocol.verify(item)
        require(set(p.name for p in shared.iterdir()) == {item["name"]}, "Publication duplicated or left a visible stage")
        protocol.delete(item)
        protocol.request("dav", "DELETE", "/" + item["name"], expected=(204,))
        row.update(confirmed_after=expected, final=idle(host), preserved_live_stage=True, hashes_verified=True, passed=True)
        sentinel.unlink()
        live.unlink()
        require(not list(pool.iterdir()), "Final staging files remain")
    finally:
        host.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    require(not args.report.exists(), "Use an unused report path")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "cases": [], "scope": "Disposable APFS sparse image; deterministic owned-child exits, not power loss"}
    started = time.monotonic()
    attached = False
    # Keep a failed fixture if detachment fails; never recursively remove a
    # directory that might still be the mount point of a live volume.
    root = Path(tempfile.mkdtemp(prefix="wsk-cross-volume-")).resolve()
    mount = root / "mounted"
    mount.mkdir()
    image = root / "owned.sparseimage"
    report["fixture_root"] = str(root)
    try:
        binary, libraries = build()
        subprocess.run(["hdiutil", "create", "-size", "512m", "-fs", "APFS", "-type", "SPARSE", "-volname", "WSK Recovery Fixture", str(image)], check=True, timeout=60, capture_output=True)
        result = subprocess.run(["hdiutil", "attach", "-nobrowse", "-owners", "on", "-mountpoint", str(mount), "-plist", str(image)], check=True, timeout=60, capture_output=True)
        attached = True
        attachment = plistlib.loads(result.stdout)
        require(any(e.get("mount-point") == str(mount) for e in attachment["system-entities"]), "Unexpected image mount point")
        report["attachment"] = attachment
        with args.report.with_suffix(".log").open("w") as log:
            for mode in ("exit-stage-open", "exit-stage-write", "exit-publication-after"):
                case(binary, libraries, root, mount, mode, report, log)
        report["passed"] = True
    except BaseException as error:
        report.update(passed=False, error=f"{type(error).__name__}: {error}")
        raise
    finally:
        try:
            if attached:
                subprocess.run(["hdiutil", "detach", str(mount)], check=True, timeout=60, capture_output=True)
                report["detached"] = True
            else:
                report["detached"] = False
        except BaseException as error:
            report.update(passed=False, detach_error=f"{type(error).__name__}: {error}")
            raise
        finally:
            report["elapsed_seconds"] = time.monotonic() - started
            args.report.write_text(json.dumps(report, indent=2) + "\n")
        # The owned sparse image and evidence remain available for inspection.
    print(f"PASS: {args.report}")


if __name__ == "__main__":
    main()
