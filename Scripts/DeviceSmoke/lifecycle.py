#!/usr/bin/env python3
"""Check normal background/resume serving on the identified physical iPhone app."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import errno
import ipaddress
import json
import math
from pathlib import Path
import platform
import socket
import subprocess
import sys
import tempfile
import time
import traceback
import uuid

import transfers
from transfers import BUNDLE, FRESH_SECONDS, INITIAL, KINDS, MIB, Phone, Transfers
from transfers import closing_reported, digest, inventory, require


class LifecyclePhone(Phone):
    def __init__(self, *args):
        super().__init__(*args)
        self.counters = None

    def validate_counters(self, sample):
        values = tuple(sample[key] for key in ("accepted", "closed"))
        require(all(type(value) is int and value >= 0 for value in values), "Invalid cumulative connection counters")
        require(values[1] <= values[0], "Closed connections exceed accepted connections")
        require(self.counters is None or all(now >= before for now, before in zip(values, self.counters)),
                "Cumulative connection counters regressed")
        self.counters = values

    def sample(self, label):
        sample = super().sample(label)
        self.validate_counters(sample)
        return sample

    def raw_sample(self, label):
        # Phone.sample deliberately requires active servers. Lifecycle callbacks
        # need the same container/PID identity checks without that assertion.
        destination = self.directory / "lifecycle-probe.json"
        destination.unlink(missing_ok=True)
        command = ["xcrun", "devicectl", "device", "copy", "from", "--device", self.args.device,
                   "--source", "Documents/probe.json", "--destination", str(destination),
                   "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                   "--timeout", "20", "--quiet"]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
        require(result.returncode == 0, f"Device report copy failed: {result.stderr.decode(errors='replace')[-2000:]}")
        require(destination.stat().st_size <= MIB, "Device report exceeds one MiB")
        sample = json.loads(destination.read_bytes())
        self.samples.write(json.dumps({"label": label, "received_at": time.time(), "phone": sample}) + "\n")
        self.samples.flush()
        self.report["last_phone_sample"] = sample
        require(sample["run_id"] == self.args.run_id and sample["bundle_id"] == BUNDLE,
                "Lifecycle report identity differs")
        require(type(sample["pid"]) is int and sample["pid"] == self.pid, "Smoke app process changed across lifecycle")
        stamp = sample["sample_timestamp"]
        require(isinstance(stamp, (int, float)) and math.isfinite(stamp) and time.time() - stamp >= -3,
                "Invalid lifecycle timestamp or phone clock differs from the Mac")
        require(sample["status"] != "failed", f"Smoke app failed: {sample.get('error')}")
        self.validate_counters(sample)
        return sample

    def resume(self, after):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            sample = self.raw_sample("resume-wait")
            if (sample["sample_timestamp"] > after and sample["status"] == "ready"
                    and sample["app_state"] == "active" and sample["uploader_running"] and sample["dav_running"]):
                require(time.time() - sample["sample_timestamp"] <= FRESH_SECONDS, "Resumed report is stale")
                address = ipaddress.IPv4Address(sample["wifi_ipv4"])
                require(not (address.is_unspecified or address.is_multicast or address.is_loopback), "Invalid resumed Wi-Fi address")
                ports = tuple(sample[kind + "_port"] for kind in KINDS)
                require(all(type(port) is int and 0 < port <= 65535 for port in ports), "Invalid resumed server port")
                # Only a fresh same-process report from our own app container may
                # supply replacement endpoints. There is no target URL option.
                self.endpoint = str(address), ports
                return self.sample("resumed-confirmed")
            time.sleep(.2)
        raise AssertionError("Same smoke-app process did not resume active serving")


class Lifecycle(Transfers):
    def __init__(self, *args):
        super().__init__(*args)
        self.background_requested = False
        self.background_stamp = None

    def launch(self, bundle, label):
        require(bundle in (BUNDLE, "com.apple.Preferences"), "Only the smoke app and Settings may be activated")
        row = {"action": label, "bundle_id": bundle, "started_at": time.time(), "completed": False}
        self.report.setdefault("activation_attempts", []).append(row)
        self.save()
        command = ["xcrun", "devicectl", "device", "process", "launch", "--device", self.phone.args.device,
                   "--activate", "--timeout", "20", "--quiet", bundle]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
        row.update(returncode=result.returncode, completed=result.returncode == 0, finished_at=time.time(),
                   output=(result.stdout + result.stderr).decode(errors="replace")[-4000:])
        require(result.returncode == 0, f"{label} failed: {row['output']}")
        self.save()

    def port_attempt(self, endpoint, kind):
        address, ports = endpoint
        started = time.monotonic()
        row = {"server": kind, "address": address, "port": ports[KINDS.index(kind)], "reachable": False}
        try:
            with socket.create_connection((address, row["port"]), timeout=2):
                row["reachable"] = True
        except OSError as error:
            expected = {errno.ECONNREFUSED, errno.ETIMEDOUT, errno.EHOSTUNREACH, errno.ENETUNREACH,
                        errno.EHOSTDOWN, errno.ENETDOWN, errno.ECONNRESET}
            require(isinstance(error, TimeoutError) or error.errno in expected,
                    f"Unexpected background connect failure: {error}")
            row.update(error=f"{type(error).__name__}: {error}", errno=error.errno)
        row["elapsed_seconds"] = time.monotonic() - started
        return row

    def stopped(self, endpoint):
        deadline = time.monotonic() + 10
        rows = self.report.setdefault("background_connection_attempts", [])
        while time.monotonic() < deadline:
            with ThreadPoolExecutor(max_workers=2) as pool:
                attempts = list(pool.map(lambda kind: self.port_attempt(endpoint, kind), KINDS))
            rows.append({"sampled_at": time.time(), "ports": attempts})
            self.save()
            if all(not row["reachable"] for row in attempts):
                self.report["previous_ports_unavailable"] = True
                return
            time.sleep(.2)
        raise AssertionError("A previously verified phone listener remained reachable in the background")

    def run(self):
        initial = self.sample("initial")
        require(set(inventory(initial, "share_inventory")) == INITIAL,
                "Expected only the smoke app's two initial fixtures")
        self.temp_baseline = set(inventory(initial, "temp_inventory"))
        self.identity()  # First HTTP requests identify both app-owned listeners.
        self.advertised_identity()
        for kind in KINDS:
            self.sample("warm-" + kind)
            self.download_pair(kind)
        self.baseline = self.idle(None)
        self.report["baseline"] = self.baseline
        previous_endpoint = self.phone.endpoint
        self.report["previous_endpoint"] = {"address": previous_endpoint[0],
                                            **dict(zip(KINDS, previous_endpoint[1]))}
        self.background_stamp = self.baseline["sample_timestamp"]
        self.background_requested = True  # A timed-out launch may still activate Settings.
        self.launch("com.apple.Preferences", "background-via-settings")
        time.sleep(2.5)  # Exceed the library's lifecycle notification coalescing.
        background = self.phone.raw_sample("background")
        require(background["sample_timestamp"] > self.background_stamp and background["app_state"] == "background",
                "No new background callback snapshot")
        require(time.time() - background["sample_timestamp"] <= FRESH_SECONDS, "Background callback snapshot is stale")
        events = background.get("lifecycle_events", [])
        require(any(event.get("event") == "did_enter_background"
                    and isinstance(event.get("timestamp"), (int, float))
                    and event["timestamp"] > self.background_stamp for event in events),
                "No new did_enter_background lifecycle event")
        self.background_stamp = background["sample_timestamp"]
        self.report["background"] = background
        self.report_path.with_suffix(".background-probe.json").write_text(json.dumps(background, indent=2) + "\n")
        # The callback snapshot can precede automatic server stop. The old ports
        # are tested separately; running flags in that snapshot are not an oracle.
        self.stopped(previous_endpoint)
        self.launch(BUNDLE, "resume-smoke-app")
        resumed = self.phone.resume(self.background_stamp)
        self.report["resumed"] = resumed
        require(any(event.get("event") == "did_become_active"
                    and isinstance(event.get("timestamp"), (int, float))
                    and event["timestamp"] > self.background_stamp for event in resumed.get("lifecycle_events", [])),
                "No did_become_active event after the background snapshot")
        self.identity()
        self.advertised_identity()
        for kind in KINDS:
            self.sample("resumed-download-" + kind)
            self.download_pair(kind)
        self.report["final"] = self.idle(self.baseline)
        self.save()

    def restore(self):
        if self.background_requested:
            # Always attempt this even if an earlier lifecycle or network check
            # failed. Never terminate or relaunch with a new run identifier.
            self.launch(BUNDLE, "cleanup-foreground-smoke-app")
            self.report["cleanup_foreground"] = self.phone.resume(self.background_stamp)
            self.report["cleanup_idle"] = self.idle(self.baseline)
            self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Physical iPhone UDID")
    parser.add_argument("--run-id", required=True, help="UUID supplied when launching the smoke app")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    uuid.UUID(args.run_id)
    report_path = args.report.resolve()
    sample_path = report_path.with_suffix(".samples.jsonl")
    background_path = report_path.with_suffix(".background-probe.json")
    require(not any(path.exists() for path in (report_path, sample_path, background_path)),
            "Choose unused report paths so earlier evidence is preserved")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "device": args.device, "run_id": args.run_id, "bundle_id": BUNDLE,
              "mac_platform": platform.platform(), "sample_log": str(sample_path),
              "background_probe": str(background_path),
              "scope": "physical iPhone Wi-Fi background/resume with idle listeners; no active-upload or Windows claim",
              "driver_sha256": digest(Path(__file__).read_bytes()),
              "transfers_sha256": digest(Path(transfers.__file__).read_bytes())}
    started = time.monotonic()
    try:
        with closing_reported(tempfile.TemporaryDirectory(prefix="wsk-device-lifecycle-"), report, "local_probe_copy", "cleanup") as temporary, \
                closing_reported(sample_path.open("x"), report, "samples_log") as samples:
            phone = LifecyclePhone(args, Path(temporary.name), report, samples)
            driver = Lifecycle(phone, report, report_path)
            with closing_reported(driver, report, "restore_foreground_app", "restore"):
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
