#!/usr/bin/env python3
"""Owned physical-iPhone Wi-Fi loss and SIGKILL/relaunch recovery checks."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import http.client
import ipaddress
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
import traceback
import uuid

import lifecycle
import resumable
import transfers
from lifecycle import LifecyclePhone
from resumable import Resumable, TUS, PREFIX
from transfers import BUNDLE, FRESH_SECONDS, INITIAL, KINDS, MIB, closing_reported, digest, inventory, require


def fresh(sample, after=0):
    stamp = sample.get("sample_timestamp", 0)
    return after < stamp and -3 <= time.time() - stamp <= FRESH_SECONDS


def wifi_absent_while_serving(sample, after):
    # Unreachable TCP alone could instead mean listener suspension or a dead app.
    return (fresh(sample, after) and sample.get("status") == "ready"
            and sample.get("app_state") == "active" and sample.get("wifi_ipv4") is None
            and sample.get("uploader_running") is True and sample.get("dav_running") is True)


def check_relaunch(sample, before, expected_pid, requested_at):
    require(sample.get("run_id") == before["run_id"] and sample.get("bundle_id") == BUNDLE,
            "Relaunch selected a different synthetic run")
    require(type(expected_pid) is int and expected_pid > 0 and expected_pid != before["pid"],
            "Relaunch did not identify a new process")
    require(sample.get("pid") == expected_pid, "Report does not belong to the newly launched process")
    uuid.UUID(sample.get("launch_id", ""))
    require(sample["launch_id"] != before["launch_id"] and sample.get("resumed_existing_run") is True,
            "New process did not explicitly reopen the persisted run")
    require(fresh(sample, requested_at), "Relaunch report is stale")


def check_owned_process(processes, pid, installation):
    apps = installation["result"]["installedApplications"]
    owned = [app for app in apps if app.get("bundleID") == BUNDLE]
    require(len(owned) == 1, "Installation record does not identify the dedicated app")
    root = owned[0]["installationURL"]
    require(root.startswith("file:///") and root.endswith("/WebServerKitExample.app/"),
            "Unexpected dedicated app installation URL")
    matching = [row for row in processes if row.get("processIdentifier") == pid]
    require(len(matching) == 1 and matching[0].get("executable") == root + "WebServerKitExample",
            "Refusing to terminate a PID that does not match the installed dedicated app")
    return matching[0]


def check_prefixes(sample, items):
    entries = inventory(sample, "resumable_inventory")
    for item in items:
        payload = entries.get(item["key"] + "/payload", {})
        require(payload.get("type") == "file" and payload.get("size") == MIB,
                "Interruption changed an acknowledged payload prefix")


def check_clean_resources(sample, baseline, expected, temporary):
    require(sample["connections"] == sample["reserved_bytes"] == 0, "Connections/reservations remain")
    require(sample["accepted"] == sample["closed"], "Connection counts differ")
    require(sample["descriptors"] <= baseline["descriptors"], "Descriptors grew")
    share = inventory(sample, "share_inventory")
    require(set(share) == set(expected) and all(share[n]["type"] == "file" and share[n]["size"] == size
                                             for n, size in expected.items()), "Shared files differ")
    sessions = inventory(sample, "resumable_inventory")
    require(set(sessions) <= {".lock"}, "Sessions/receipts remain")
    require(".lock" not in sessions or sessions[".lock"]["type"] == "file", "Invalid coordination file")
    require(set(inventory(sample, "temp_inventory")) == temporary, "Request temporary files remain")


class InterruptionPhone(LifecyclePhone):
    def read_candidate(self, label):
        destination = self.directory / "candidate.json"
        destination.unlink(missing_ok=True)
        result = subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", self.args.device,
            "--source", "Documents/probe.json", "--destination", str(destination), "--domain-type", "appDataContainer",
            "--domain-identifier", BUNDLE, "--timeout", "20", "--quiet"], capture_output=True, timeout=25)
        require(result.returncode == 0, f"Report copy failed: {result.stderr.decode(errors='replace')[-1000:]}")
        require(destination.stat().st_size <= MIB, "Unexpected report size")
        sample = json.loads(destination.read_bytes())
        self.samples.write(json.dumps({"label": label, "received_at": time.time(), "phone": sample}) + "\n")
        self.samples.flush()
        require(sample.get("run_id") == self.args.run_id and sample.get("bundle_id") == BUNDLE,
                "Candidate report has wrong ownership")
        require(sample.get("status") != "failed", f"Probe host failed: {sample.get('error')}")
        return sample

    def adopt_relaunch(self, before, pid, requested_at):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            sample = self.read_candidate("relaunch-candidate")
            if sample.get("pid") == pid and fresh(sample, requested_at) and sample.get("app_state") == "active":
                check_relaunch(sample, before, pid, requested_at)
                address = str(ipaddress.IPv4Address(sample["wifi_ipv4"]))
                ports = tuple(sample[k + "_port"] for k in KINDS)
                require(all(type(p) is int and 0 < p <= 65535 for p in ports), "Invalid new ports")
                self.pid, self.endpoint, self.counters = pid, (address, ports), None
                return self.sample("new-process-confirmed")
            time.sleep(.5)
        raise AssertionError("New process did not reopen the existing run")


class Interruptions(Resumable):
    def __init__(self, *args):
        super().__init__(*args)
        self.downloads = []
        self.cleanup_finished = False
        self.command_index = 0

    def phase(self, name, action=None):
        self.report["phase"] = name
        if action:
            self.report["phone_action"] = action
            print(action, flush=True)
        else:
            self.report.pop("phone_action", None)
        self.save()

    def device_command(self, arguments, label):
        self.command_index += 1
        output = self.report_path.with_name(f"{self.report_path.stem}.{self.command_index}-{label}.json")
        require(not output.exists(), "Device command evidence path already exists")
        command = ["xcrun", "devicectl", "device", *arguments[:2], "--device", self.phone.args.device,
                   "--timeout", "30", "--json-output", str(output), *arguments[2:]]
        result = subprocess.run(command, capture_output=True, timeout=35)
        self.report.setdefault("device_commands", []).append({"action": label, "evidence": str(output),
                                                              "returncode": result.returncode})
        self.save()
        require(result.returncode == 0, f"{label}: {(result.stdout + result.stderr).decode(errors='replace')[-1600:]}")
        return json.loads(output.read_text())["result"]

    def start_downloads(self):
        for kind in KINDS:
            self.sample("begin-partial-download-" + kind)
            address, ports = self.phone.endpoint
            connection = http.client.HTTPConnection(address, ports[KINDS.index(kind)], timeout=10)
            row = {"server": kind, "connection": connection}
            self.downloads.append(row)
            connection.request("GET", self.path(kind, "asset.bin"), headers={"Accept-Encoding": "identity", "Connection": "close"})
            response = connection.getresponse()
            row["response"] = response
            require(response.status == 200, "Initial asset download failed")
            tag = response.getheader("ETag")
            require(tag and not tag.startswith("W/"), "Download needs a strong validator")
            prefix = response.read(PREFIX)
            require(prefix == self.asset[:PREFIX] and response.getheader("Content-Length") == str(len(self.asset)),
                    "Initial download prefix or length differs")
            row.update(prefix=prefix, etag=tag)
            self.report.setdefault("partial_downloads", []).append({"server": kind, "saved_bytes": len(prefix), "etag": tag})
        self.save()

    def close_downloads(self):
        for row in self.downloads:
            if row.get("response"):
                row["response"].close()
            row["connection"].close()

    def resume_downloads(self):
        self.close_downloads()
        for row in self.downloads:
            self.sample("resume-download-" + row["server"])
            offset = len(row["prefix"])
            with closing_reported(self.connection(row["server"]), self.report, "resumed-download") as connection:
                connection.request("GET", self.path(row["server"], "asset.bin"), headers={
                    "Range": f"bytes={offset}-", "If-Range": row["etag"], "Accept-Encoding": "identity", "Connection": "close"})
                response = connection.getresponse()
                require(response.getheader("Content-Range") == f"bytes {offset}-{len(self.asset)-1}/{len(self.asset)}",
                        "Resumed download has wrong range")
                require(response.getheader("ETag") == row["etag"], "Relaunch changed the saved asset validator")
                self.verify_response(response, self.asset_hash, len(self.asset), 206, row["prefix"])
        self.report["both_downloads_resumed_with_matching_hashes"] = True

    def wifi_cycle(self, items):
        before = self.sample("before-wifi-loss")
        require(self.four_held(before, items), "Four upload bodies must still be present before requesting Wi-Fi loss")
        self.background_requested = True
        self.background_stamp = before["sample_timestamp"]
        endpoint = self.phone.endpoint
        self.phase("waiting_for_wifi_off", "Turn iPhone Wi-Fi off in Settings, then return to WSK Device Test with Wi-Fi still off. Leave USB connected. Wait for the restore-Wi-Fi instruction.")
        deadline = time.monotonic() + self.phone.args.wait_seconds
        last_offline = None
        observed_transition = False
        while time.monotonic() < deadline:
            sample = self.phone.raw_sample("wifi-off-observation")
            observed_transition |= sample.get("app_state") != "active" or sample.get("wifi_ipv4") is None
            if wifi_absent_while_serving(sample, before["sample_timestamp"]):
                check_prefixes(sample, items)
                with ThreadPoolExecutor(max_workers=2) as pool:
                    attempts = list(pool.map(lambda kind: self.port_attempt(endpoint, kind), KINDS))
                if all(not row["reachable"] for row in attempts):
                    if last_offline is not None and sample["sample_timestamp"] > last_offline["sample_timestamp"]:
                        self.report["wifi_outage"] = {"first": last_offline, "second": sample, "old_endpoint_attempts": attempts}
                        break
                    last_offline = sample
            # Preserve pre-transition activity while a person gets ready. Never
            # reuse an old socket after the app or network starts transitioning.
            if (not observed_transition and fresh(sample)
                    and any(time.monotonic() - h["last_send"] >= 20 for h in self.held_sockets)):
                self.refresh_held()
            self.save()
            time.sleep(.5)
        else:
            raise AssertionError("No fresh active-app Wi-Fi outage with both old endpoints unreachable")
        self.close_held()
        self.close_downloads()
        self.phase("waiting_for_wifi_on", "Wi-Fi loss is verified. Turn Wi-Fi back on, rejoin the same network, and return to WSK Device Test.")
        deadline = time.monotonic() + self.phone.args.wait_seconds
        while time.monotonic() < deadline:
            sample = self.phone.raw_sample("wifi-return-observation")
            if (fresh(sample, self.report["wifi_outage"]["second"]["sample_timestamp"])
                    and sample.get("wifi_ipv4") and sample.get("app_state") == "active"
                    and sample.get("uploader_running") and sample.get("dav_running")):
                self.report["wifi_rejoined"] = self.phone.resume(self.report["wifi_outage"]["second"]["sample_timestamp"])
                self.identity()
                self.background_requested = False
                return
            time.sleep(.5)
        raise AssertionError("Phone did not rejoin Wi-Fi and return to active serving")

    def crash_cycle(self, items):
        before = self.sample("before-sigkill")
        check_prefixes(before, items)
        if self.phone.args.mode == "crash-active-body":
            require(self.four_held(before, items), "Four upload bodies must still be present at the selected kill point")
        else:
            require(set(inventory(before, "temp_inventory")) == self.temp_baseline,
                    "Between-chunks kill unexpectedly has an unfinished request body")
        processes = self.device_command(["info", "processes"], "verify-pid")["runningProcesses"]
        installation = json.loads(self.phone.args.install_record.read_text())
        owned = check_owned_process(processes, before["pid"], installation)
        self.report["killed_process"] = owned
        self.phase("terminating-owned-app")
        self.device_command(["process", "terminate", "--pid", str(before["pid"]), "--kill"], "sigkill")
        self.close_held()
        self.close_downloads()
        processes = self.device_command(["info", "processes"], "verify-exit")["runningProcesses"]
        require(not any(row.get("processIdentifier") == before["pid"] for row in processes), "Old process remains alive")
        self.report["old_process_exit_verified"] = True
        self.phase("relaunching-persisted-run")
        requested = time.time()
        launched = self.device_command(["process", "launch", "--activate", BUNDLE,
                                        "--probe-run-id", self.phone.args.run_id, "--resume-probe-run"], "relaunch")
        resumed = self.phone.adopt_relaunch(before, launched["process"]["processIdentifier"], requested)
        self.report["relaunch"] = {"before": before, "after": resumed, "requested_at": requested}
        self.identity()

    def settle(self):
        # Give normal request cleanup time to finish. Preserve any actual residue
        # as a failed cleanup result; never silently adopt it as the new baseline.
        deadline, stable, last_stamp = time.monotonic() + 30, [], 0
        while time.monotonic() < deadline:
            sample = self.sample("final-idle")
            if sample["sample_timestamp"] > last_stamp:
                last_stamp = sample["sample_timestamp"]
                self.report["final"] = sample
                try:
                    check_clean_resources(sample, self.baseline, self.expected, self.temp_baseline)
                except AssertionError as error:
                    self.report["cleanup_failure"] = str(error)
                    stable = []
                else:
                    stable.append(sample)
                    if len(stable) == 3:
                        self.report["cleanup_passed"] = True
                        self.report.pop("cleanup_failure", None)
                        return
            time.sleep(.5)
        self.report["cleanup_passed"] = False
        self.report["temporary_residue"] = sorted(set(inventory(sample, "temp_inventory")) - self.temp_baseline)
        raise AssertionError(self.report.get("cleanup_failure", "Cleanup did not settle"))

    def run(self):
        self.phase("preparing")
        initial = self.sample("initial")
        uuid.UUID(initial.get("launch_id", ""))
        require(initial.get("resumed_existing_run") is False, "Begin with a fresh synthetic run")
        require(set(inventory(initial, "share_inventory")) == INITIAL, "Unexpected initial fixtures")
        require(set(inventory(initial, "resumable_inventory")) <= {".lock"}, "Prior session state exists")
        self.temp_baseline = set(inventory(initial, "temp_inventory"))
        self.identity()
        # Warm both file-serving paths and the resumable store before FD comparison.
        for kind in KINDS:
            self.sample("warm-" + kind)
            self.download_pair(kind)
        warm = self.make_item("warm", PREFIX, "interruptions-warm")
        self.sample("warm-upload")
        self.create(warm)
        self.patch(warm, 0)
        self.expected[warm["name"]] = len(warm["data"])
        self.delete_receipt(warm)
        self.delete(warm["name"])
        self.baseline = self.idle(None)
        self.report["baseline"] = self.baseline
        items = [self.make_item(f"recovery-{i}", 3*MIB+17+i, self.phone.args.run_id+str(i)) for i in range(4)]
        self.report["files"] = [{k: item[k] for k in ("name", "key", "sha256")} for item in items]
        for item in items:
            self.sample("save-prefix-" + item["key"])
            self.create(item)
            self.patch(item, 0)
            self.head(item, MIB)
        # Retain an acknowledged completion receipt across the same interruption.
        completed = self.make_item("completed-before-interruption", PREFIX, self.phone.args.run_id+":complete")
        self.sample("save-completion-receipt")
        self.create(completed)
        self.patch(completed, 0)
        self.expected[completed["name"]] = len(completed["data"])
        if self.phone.args.mode != "crash-between-chunks":
            for item in items:
                self.sample("hold-" + item["key"])
                self.hold_patch(item)
            self.report["four_held"] = self.wait_four_held(items)
        self.start_downloads()
        if self.phone.args.mode == "wifi":
            self.wifi_cycle(items)
        else:
            self.crash_cycle(items)
        self.phase("verifying-recovery")
        resumed = self.sample("recovered-prefix-inventory")
        check_prefixes(resumed, items)
        for item in items:
            self.sample("recover-offset-" + item["key"])
            self.head(item, MIB)
        self.sample("recover-completed-receipt")
        self.create(completed, len(completed["data"]))
        self.resume_downloads()
        def finish(item):
            offset = MIB
            while offset < len(item["data"]):
                offset = self.patch(item, offset)
        self.sample("finish-four-uploads")
        with ThreadPoolExecutor(max_workers=4) as pool:
            for future in [pool.submit(finish, item) for item in items]:
                future.result(timeout=60)
        self.expected.update({item["name"]: len(item["data"]) for item in items})
        for item in [*items, completed]:
            self.sample("verify-" + item["key"])
            self.head(item, len(item["data"]))
            self.create(item, len(item["data"]))
            for kind in KINDS:
                self.fetch(kind, item["name"], item["data"])
        published = self.sample("published-once")
        require(set(inventory(published, "share_inventory")) == set(self.expected), "Duplicate or missing publications")
        self.report.update(recovery_passed=True, same_keys_and_offsets_preserved=True,
                           all_upload_hashes_verified=True, completion_replay_created_no_duplicates=True,
                           published=published)
        for item in [*items, completed]:
            self.sample("delete-owned-" + item["key"])
            self.delete_receipt(item)
            self.delete(item["name"])
        self.cleanup_finished = True
        self.phase("checking-cleanup")
        self.settle()
        self.phase("complete")

    def restore(self):
        self.close_held()
        self.close_downloads()
        if not self.cleanup_finished:
            super().restore()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--mode", choices=("wifi", "crash-between-chunks", "crash-active-body"), required=True)
    parser.add_argument("--install-record", type=Path, help="Matching devicectl installation JSON; required before any SIGKILL")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--wait-seconds", type=int, default=600)
    args = parser.parse_args()
    uuid.UUID(args.run_id)
    require(30 <= args.wait_seconds <= 600, "Manual wait must be bounded")
    require(args.mode == "wifi" or (args.install_record and args.install_record.is_file()), "Crash tests require installation proof")
    args.report = args.report.resolve()
    sample_path = args.report.with_suffix(".samples.jsonl")
    require(not args.report.exists() and not sample_path.exists(), "Use unused evidence paths")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "recovery_passed": False, "cleanup_passed": False,
              "mode": args.mode, "device": args.device, "run_id": args.run_id, "bundle_id": BUNDLE,
              "platform": platform.platform(), "sample_log": str(sample_path),
              "scope": "Owned synthetic native app; Python client, actual Wi-Fi loss or SIGKILL; no browser, reboot, jetsam-specific or cleanup-fix claim",
              "source_sha256": {Path(p).name: digest(Path(p).read_bytes()) for p in
                                (__file__, resumable.__file__, lifecycle.__file__, transfers.__file__)}}
    started = time.monotonic()
    try:
        with closing_reported(tempfile.TemporaryDirectory(prefix="wsk-interruptions-"), report, "local-copy", "cleanup") as directory, \
                closing_reported(sample_path.open("x"), report, "samples") as samples:
            phone = InterruptionPhone(args, Path(directory.name), report, samples)
            driver = Interruptions(phone, report, args.report)
            with closing_reported(driver, report, "owned-transfer-cleanup", "restore"):
                driver.run()
        report["passed"] = True
    except (Exception, KeyboardInterrupt) as error:
        report["error"] = f"{type(error).__name__}: {error}"
        traceback.print_exc()
    finally:
        report["elapsed_seconds"] = time.monotonic() - started
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{'PASS' if report['passed'] else 'FAIL'}: {args.report}", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
