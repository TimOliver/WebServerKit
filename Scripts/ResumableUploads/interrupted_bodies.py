#!/usr/bin/env python3
"""Kill owned loopback uploads and recover without disturbing a second live host."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
from pathlib import Path
import tempfile
import time

from recovery import MIB, Protocol, ResumableHost, TUS, build, idle, require


def wait_files(directory, count):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        entries = {p.name: p.stat().st_size for p in directory.iterdir()}
        if len(entries) == count and all(size >= 65536 for size in entries.values()):
            return entries
        time.sleep(.02)
    raise AssertionError(f"Expected {count} partial request bodies, got {entries}")


def hold(host, kind, method, path, body, headers, prefix=65536):
    connection = http.client.HTTPConnection("127.0.0.1", host.ports[kind], timeout=10)
    try:
        connection.putrequest(method, path)
        for key, value in {"Content-Length": str(len(body)), "Connection": "close", **headers}.items():
            connection.putheader(key, value)
        connection.endheaders(body[:prefix])
        return connection, body[prefix:]
    except BaseException:
        connection.close()
        raise


def run(binary, libraries, directory, report, log):
    first = second = None
    sockets = []
    try:
        first = ResumableHost(binary, libraries, directory, log, report)
        protocol = Protocol(first)
        items = []
        for i in range(4):
            data = hashlib.shake_256(f"owned-crash-upload-{i}".encode()).digest(2 * MIB)
            item = protocol.create(f"recovered-{i}.bin", data)
            protocol.patch(item, 0, data[:MIB])
            require(protocol.head(item) == MIB, "Initial offset was not acknowledged")
            items.append(item)
        for item in items:
            connection, _ = hold(first, "uploader", "PATCH", item["url"], item["data"][MIB:],
                                 {**TUS, "Upload-Offset": str(MIB), "Content-Type": "application/offset+octet-stream"})
            sockets.append(connection)
        data = b"p" * (2 * MIB)
        connection, _ = hold(first, "dav", "PUT", "/aborted-put.bin", data, {"Content-Type": "application/octet-stream"})
        sockets.append(connection)
        header = b'--owned-boundary\r\nContent-Disposition: form-data; name="files[]"; filename="aborted-multipart.bin"\r\nContent-Type: application/octet-stream\r\n\r\n'
        body = header + data + b"\r\n--owned-boundary--\r\n"
        connection, _ = hold(first, "uploader", "POST", "/upload", body,
                             {"Content-Type": "multipart/form-data; boundary=owned-boundary"}, len(header) + 65536 + 1024)
        sockets.append(connection)
        interrupted = wait_files(first.tmp, 6)
        require(not list(first.shared.iterdir()), "An incomplete request was published")

        # Same temp, share and session roots, independent processes. Starting this
        # server must not remove the first one's six still-live request bodies.
        second = ResumableHost(binary, libraries, directory, log, report)
        require(wait_files(first.tmp, 6) == interrupted, "Startup removed a live process's request files")
        live_data = b"second-host-must-survive" * 65536
        live, remaining = hold(second, "dav", "PUT", "/live-peer.bin", live_data,
                               {"Content-Type": "application/octet-stream"})
        sockets.append(live)
        all_files = wait_files(first.tmp, 7)
        live_files = set(all_files) - set(interrupted)
        require(len(live_files) == 1, "Could not identify live peer's body")
        old_pid = first.process.pid
        first.process.kill()
        require(first.process.wait(timeout=10) != 0, "The selected process did not terminate abruptly")
        require(wait_files(first.tmp, 7) == all_files, "Crash fixture did not retain its partial bodies")
        first.restart()
        require(first.process.pid != old_pid, "Recovery did not start a new process")
        after = wait_files(first.tmp, 1)
        require(set(after) == live_files and all(after[n] == all_files[n] for n in live_files),
                "Recovery removed a live peer's body or left a dead creator's body")
        report.update(old_pid=old_pid, new_pid=first.process.pid, live_peer_pid=second.process.pid,
                      abandoned_bodies=interrupted, preserved_live_bodies=after)
        for connection in sockets[:-1]:
            connection.close()
        live.send(remaining)
        response = live.getresponse()
        require(response.status == 201, "The live peer could not finish its preserved upload")
        response.read()
        response.close()
        live.close()
        live_item = {"name": "live-peer.bin", "data": live_data, "sha256": hashlib.sha256(live_data).hexdigest()}
        protocol.verify(live_item)
        protocol.request("dav", "DELETE", "/live-peer.bin", expected=(204,))
        for item in items:
            require(protocol.head(item) == MIB, "Restart changed a durable upload offset")
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(protocol.finish, items))
        for item in items:
            protocol.verify(item)
            protocol.delete(item)
            protocol.request("dav", "DELETE", "/" + item["name"], expected=(204,))
        report.update(final=idle(first), peer_final=idle(second),
                      same_offsets_preserved=True, all_hashes_verified=True,
                      live_peer_completed=True, passed=True)
    finally:
        for connection in sockets:
            connection.close()
        for host in (first, second):
            if host is not None:
                host.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    require(not args.report.exists(), "Use an unused evidence path")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "scope": "Owned synthetic loopback children; four PATCH bodies, PUT, multipart and a live peer"}
    started = time.monotonic()
    try:
        binary, libraries = build(faults=False)
        with tempfile.TemporaryDirectory(prefix="wsk-interrupted-bodies-") as directory, \
                args.report.with_suffix(".log").open("w") as log:
            run(binary, libraries, Path(directory), report, log)
    except BaseException as error:
        report.update(passed=False, error=f"{type(error).__name__}: {error}")
        raise
    finally:
        report["elapsed_seconds"] = time.monotonic() - started
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: {args.report}")


if __name__ == "__main__":
    main()
