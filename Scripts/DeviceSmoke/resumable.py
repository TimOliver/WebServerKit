#!/usr/bin/env python3
"""Python-client checks of active resumable uploads across physical iPhone backgrounding."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import errno
import hashlib
import json
from pathlib import Path
import platform
import socket
import sys
import tempfile
import time
import traceback
import uuid

import lifecycle
import transfers
from lifecycle import Lifecycle, LifecyclePhone
from transfers import BUNDLE, FRESH_SECONDS, INITIAL, KINDS, MIB
from transfers import closing_reported, digest, inventory, require

TUS = {"Tus-Resumable": "1.0.0"}
BACKGROUND_SECONDS = 90
HELD_TIMEOUT = 180
PREFIX = 64 * 1024


class Resumable(Lifecycle):
    def __init__(self, *args):
        super().__init__(*args)
        self.sessions = {}
        self.held_sockets = []

    def sample(self, label):
        value = super().sample(label)
        inventory(value, "resumable_inventory")
        return value

    def make_item(self, suffix, size, seed):
        data = hashlib.shake_256(seed.encode()).digest(size)
        name, key = self.name(suffix), str(uuid.uuid4())
        metadata = {"filename": name, "path": "/", "sha256": digest(data)}
        encoded = ",".join(field + " " + base64.b64encode(value.encode()).decode()
                           for field, value in metadata.items())
        item = {"name": name, "key": key, "path": "/uploads/" + key,
                "data": data, "sha256": metadata["sha256"], "metadata": encoded}
        # Register before POST, including an outcome lost to a transport failure.
        self.sessions[key] = item
        return item

    def create(self, item, offset=0):
        _, headers, _ = self.request("uploader", "POST", "/uploads", 201, b"", {
            **TUS, "Upload-Key": item["key"], "Upload-Length": str(len(item["data"])),
            "Upload-Metadata": item["metadata"]})
        require(headers.get("location") == item["path"], "Creation changed the upload key")
        self.check_offset(item, headers, offset)

    def check_offset(self, item, headers, expected):
        require(headers.get("tus-resumable") == "1.0.0", "Missing tus version")
        require(headers.get("upload-offset") == str(expected),
                f"Unexpected offset for {item['name']}: {headers.get('upload-offset')}, expected {expected}")
        if "upload-length" in headers:
            require(headers["upload-length"] == str(len(item["data"])), "Upload length changed")

    def head(self, item, expected):
        _, headers, _ = self.request("uploader", "HEAD", item["path"], 200, headers=TUS)
        self.check_offset(item, headers, expected)
        require(headers.get("upload-length") == str(len(item["data"])), "HEAD omitted upload length")
        self.report.setdefault("confirmed_offsets", []).append({"key": item["key"], "offset": expected,
                                                                "observed_at": time.time()})

    def patch(self, item, offset):
        body = item["data"][offset:offset + MIB]
        _, headers, _ = self.request("uploader", "PATCH", item["path"], 204, body, {
            **TUS, "Upload-Offset": str(offset), "Content-Type": "application/offset+octet-stream"})
        self.check_offset(item, headers, offset + len(body))
        return offset + len(body)

    def delete_receipt(self, item):
        self.request("uploader", "DELETE", item["path"], (204, 404, 410), headers=TUS)
        self.sessions.pop(item["key"], None)

    def hold_patch(self, item):
        require(time.time() - self.phone.latest["sample_timestamp"] <= FRESH_SECONDS,
                "Need a fresh verified phone endpoint before opening held PATCH")
        address, ports = self.phone.endpoint
        connection = socket.create_connection((address, ports[0]), timeout=10)
        # A plain socket has no DeadlineConnection's 60-second shutdown timer.
        connection.settimeout(HELD_TIMEOUT)
        row = {"key": item["key"], "opened_at": time.time(), "client_timeout_seconds": HELD_TIMEOUT,
               "bytes_sent": PREFIX, "closed_by_client_at": None}
        held = {"socket": connection, "item": item, "row": row, "last_send": time.monotonic()}
        self.held_sockets.append(held)
        self.report.setdefault("held_requests", []).append(row)
        headers = (f"PATCH {item['path']} HTTP/1.1\r\nHost: {address}:{ports[0]}\r\n"
                   "Connection: close\r\nTus-Resumable: 1.0.0\r\n"
                   "Content-Type: application/offset+octet-stream\r\n"
                   f"Upload-Offset: {MIB}\r\nContent-Length: {MIB}\r\n\r\n").encode("ascii")
        connection.sendall(headers + item["data"][MIB:MIB + PREFIX])
        held["last_send"] = time.monotonic()

    def refresh_held(self):
        # Real next bytes of each incomplete chunk; never enough to finish it.
        for held in self.held_sockets:
            row = held["row"]
            position = row["bytes_sent"]
            require(position + 1024 < MIB, "Held body unexpectedly reached its full length")
            held["socket"].sendall(held["item"]["data"][MIB + position:MIB + position + 1024])
            row["bytes_sent"] += 1024
            held["last_send"] = time.monotonic()
            row["last_progress_at"] = time.time()

    def close_held(self):
        while self.held_sockets:
            held = self.held_sockets.pop()
            try:
                held["socket"].close()
            finally:
                held["row"]["closed_by_client_at"] = time.time()

    def four_held(self, sample, items):
        temporary = set(inventory(sample, "temp_inventory"))
        sessions = inventory(sample, "resumable_inventory")
        return (sample["connections"] >= 4 and self.temp_baseline <= temporary
                and len(temporary - self.temp_baseline) == 4
                and all(sessions.get(item["key"] + "/payload", {}).get("size") == MIB for item in items))

    def wait_four_held(self, items):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            sample = self.sample("four-resumable-bodies-held")
            if self.four_held(sample, items):
                return sample
            time.sleep(.2)
        raise AssertionError("Phone did not report four held PATCH bodies and four saved 1 MiB payloads")

    def idle(self, baseline):
        deadline, stable, last_stamp = time.monotonic() + 60, [], None
        error = "No fresh idle samples"
        while time.monotonic() < deadline:
            sample = self.sample("resumable-idle")
            if last_stamp is not None and sample["sample_timestamp"] <= last_stamp:
                time.sleep(.2)
                continue
            last_stamp = sample["sample_timestamp"]
            try:
                require(sample["connections"] == sample["reserved_bytes"] == 0, "Connections or reservations remain")
                require(sample["accepted"] == sample["closed"], "Connection accounting differs")
                share = inventory(sample, "share_inventory")
                require(set(share) == set(self.expected), f"Unexpected share entries: {sorted(share)}")
                require(all(share[name]["type"] == "file" and share[name]["size"] == size
                            for name, size in self.expected.items()), "Shared file type or size differs")
                require(set(inventory(sample, "temp_inventory")) == self.temp_baseline, "Temporary files remain")
                sessions = inventory(sample, "resumable_inventory")
                require(set(sessions) <= {".lock"}, "Session files or receipts remain")
                require(".lock" not in sessions or sessions[".lock"]["type"] == "file", "Invalid coordination file")
                require(baseline is None or sample["descriptors"] <= baseline["descriptors"], "Descriptors grew")
                stable.append(sample)
                if len(stable) == 3:
                    result = dict(stable[-1])
                    result["descriptors"] = max(value["descriptors"] for value in stable)
                    return result
            except AssertionError as failure:
                error, stable = str(failure), []
            time.sleep(.2)
        raise AssertionError(f"Phone did not settle: {error}")

    def observe_stopped(self, endpoint, started):
        rows = self.report.setdefault("background_connection_attempts", [])
        while time.monotonic() - started < BACKGROUND_SECONDS:
            require(len(self.held_sockets) == 4 and all(value["socket"].fileno() >= 0 for value in self.held_sockets),
                    "Client closed a held upload before observing listener stop")
            with ThreadPoolExecutor(max_workers=2) as pool:
                attempts = list(pool.map(lambda kind: self.port_attempt(endpoint, kind), KINDS))
            elapsed = time.monotonic() - started
            idle_age = max(time.monotonic() - value["last_send"] for value in self.held_sockets)
            rows.append({"observed_at": time.time(), "since_background_request_seconds": elapsed,
                         "maximum_held_idle_seconds": idle_age, "client_owned_sockets": 4, "ports": attempts})
            self.save()
            # Timeouts/Wi-Fi unreachability are recorded, but do not establish that
            # UIKit-driven server suspension closed these previously verified listeners.
            if all(not row["reachable"] and row.get("errno") == errno.ECONNREFUSED for row in attempts):
                require(idle_age < 120, "Server idle timeout could explain the observed stop")
                require(elapsed <= BACKGROUND_SECONDS + 3, "Background observation exceeded its bound")
                self.report["listener_stop"] = {"both_refused": True, "observed_at": time.time(),
                    "since_background_request_seconds": elapsed, "maximum_held_idle_seconds": idle_age,
                    "client_owned_sockets": 4, "client_closed_any_held_socket": False,
                    "accepted_socket_eof_required": False}
                return
            time.sleep(.5)
        raise AssertionError("Both verified listeners did not refuse connections within the 90-second background window")

    def run(self):
        initial = self.sample("initial")
        require(set(inventory(initial, "share_inventory")) == INITIAL, "Expected only the two initial fixtures")
        require(set(inventory(initial, "resumable_inventory")) <= {".lock"}, "Prior upload sessions remain")
        self.temp_baseline = set(inventory(initial, "temp_inventory"))
        self.identity()
        self.advertised_identity()
        for kind in KINDS:
            self.sample("warm-download-" + kind)
            self.download_pair(kind)
        warm = self.make_item("resumable-warmup", PREFIX, "resumable-warmup")
        self.sample("warm-resumable")
        self.create(warm)
        self.patch(warm, 0)
        self.expected[warm["name"]] = len(warm["data"])
        self.fetch("dav", warm["name"], warm["data"])
        self.delete_receipt(warm)
        self.delete(warm["name"])
        self.baseline = self.idle(None)
        self.report["baseline"] = self.baseline

        items = [self.make_item(f"resumable-{index}", 3 * MIB + 17 + index,
                                self.phone.args.run_id + f":{index}") for index in range(4)]
        self.report["files"] = [{"name": item["name"], "key": item["key"],
                                  "size": len(item["data"]), "sha256": item["sha256"]} for item in items]
        for item in items:
            self.sample("create-and-first-chunk-" + item["key"])
            self.create(item)
            self.patch(item, 0)
            self.head(item, MIB)
        for item in items:
            self.sample("begin-held-chunk-" + item["key"])
            self.hold_patch(item)
        self.report["held_before_reads"] = self.wait_four_held(items)
        with ThreadPoolExecutor(max_workers=2) as pool:
            readers = [pool.submit(self.download_pair, kind) for kind in KINDS]
            self.listing()
            for reader in readers:
                reader.result(timeout=60)
        self.report["held_after_reads"] = self.wait_four_held(items)
        for item in items:
            self.head(item, MIB)
        self.refresh_held()
        # This reset occurs immediately before the transition, leaving the entire
        # bounded observation shorter than the host's 120-second inactivity limit.
        previous_endpoint = self.phone.endpoint
        self.report["previous_endpoint"] = {"address": previous_endpoint[0],
                                             **dict(zip(KINDS, previous_endpoint[1]))}
        self.background_stamp = self.phone.latest["sample_timestamp"]
        self.background_requested = True
        started = time.monotonic()
        self.report["background_requested_at"] = time.time()
        self.launch("com.apple.Preferences", "background-via-settings-with-four-uploads")
        time.sleep(2.5)
        background = self.phone.raw_sample("active-upload-background")
        require(background["sample_timestamp"] > self.background_stamp and background["app_state"] == "background",
                "No new UIKit background callback snapshot")
        require(time.time() - background["sample_timestamp"] <= FRESH_SECONDS, "Background callback snapshot is stale")
        require(background["connections"] >= 4, "No four active connections at the UIKit background transition")
        require(any(event.get("event") == "did_enter_background" and event.get("timestamp", 0) > self.background_stamp
                    for event in background.get("lifecycle_events", [])), "Missing fresh did_enter_background event")
        self.background_stamp = background["sample_timestamp"]
        self.report["background"] = background
        self.report_path.with_suffix(".background-probe.json").write_text(json.dumps(background, indent=2) + "\n")
        self.observe_stopped(previous_endpoint, started)
        self.close_held()
        self.launch(BUNDLE, "resume-smoke-app")
        resumed = self.phone.resume(self.background_stamp)
        self.report["resumed"] = resumed
        require(any(event.get("event") == "did_become_active" and event.get("timestamp", 0) > self.background_stamp
                    for event in resumed.get("lifecycle_events", [])), "Missing foreground event after interruption")
        self.identity()
        self.advertised_identity()
        for item in items:
            self.sample("resume-offset-" + item["key"])
            self.head(item, MIB)

        def finish(item):
            offset = MIB
            while offset < len(item["data"]):
                offset = self.patch(item, offset)
            self.count(completed_uploads=1)

        self.sample("resume-four-uploads")
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(finish, item) for item in items]
            for future in futures:
                future.result(timeout=60)
        self.expected.update({item["name"]: len(item["data"]) for item in items})
        for item in items:
            self.sample("verify-completed-" + item["key"])
            self.head(item, len(item["data"]))
            # A completion receipt must answer an identical POST without creating
            # another file, even though this protocol client already saw success.
            self.create(item, len(item["data"]))
            for kind in KINDS:
                self.fetch(kind, item["name"], item["data"])
        self.listing()
        published = self.sample("published-exactly-once")
        require(set(inventory(published, "share_inventory")) == set(self.expected),
                "Completed uploads produced duplicate or unexpected names")
        self.report["published"] = published
        self.report["same_upload_keys_resumed"] = True
        self.report["four_files_verified_through_both_servers"] = True
        self.report["completion_replay_created_no_duplicates"] = True
        for item in items:
            self.sample("remove-owned-upload-" + item["key"])
            self.delete_receipt(item)
            self.delete(item["name"])
        self.report["final"] = self.idle(self.baseline)
        self.save()

    def restore(self):
        self.close_held()
        if self.background_requested:
            self.launch(BUNDLE, "cleanup-foreground-smoke-app")
            self.report["cleanup_foreground"] = self.phone.resume(self.background_stamp)
        # Revalidate both independently identified listeners before any deletion.
        self.sample("cleanup-start")
        self.identity()
        for item in list(self.sessions.values()):
            self.sample("cleanup-session-" + item["key"])
            self.delete_receipt(item)
        # The inherited cleanup deletes only pre-registered names, then our
        # stronger idle override checks both app temporary and private sessions.
        self.cleanup()
        self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Physical iPhone UDID")
    parser.add_argument("--run-id", required=True, help="UUID used when launching the dedicated smoke app")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    uuid.UUID(args.run_id)
    report_path = args.report.resolve()
    sample_path = report_path.with_suffix(".samples.jsonl")
    require(not any(path.exists() for path in (report_path, sample_path, report_path.with_suffix(".background-probe.json"))),
            "Choose unused report paths to preserve previous evidence")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "device": args.device, "run_id": args.run_id, "bundle_id": BUNDLE,
              "client": "Python standard-library HTTP and raw sockets; no browser in this run",
              "scope": "Physical iPhone Wi-Fi; four active resumable uploads across UIKit background/listener stop and same-process foreground; no Windows, process-restart, or overnight claim",
              "mac_platform": platform.platform(), "sample_log": str(sample_path),
              "background_window_seconds": BACKGROUND_SECONDS, "held_socket_timeout_seconds": HELD_TIMEOUT,
              "driver_sha256": digest(Path(__file__).read_bytes()),
              "lifecycle_sha256": digest(Path(lifecycle.__file__).read_bytes()),
              "transfers_sha256": digest(Path(transfers.__file__).read_bytes())}
    started = time.monotonic()
    try:
        with closing_reported(tempfile.TemporaryDirectory(prefix="wsk-device-resumable-"), report, "local_probe_copy", "cleanup") as temporary, \
                closing_reported(sample_path.open("x"), report, "samples_log") as samples:
            phone = LifecyclePhone(args, Path(temporary.name), report, samples)
            driver = Resumable(phone, report, report_path)
            with closing_reported(driver, report, "owned_uploads_and_foreground", "restore"):
                driver.run()
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
