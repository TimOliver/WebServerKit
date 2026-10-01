#!/usr/bin/env python3
"""Verify an opt-in synthetic upload survives real iPhone file-protection denial."""
import argparse
import errno
import json
from pathlib import Path
import platform
import sys
import tempfile
import time
import traceback
import uuid

import lifecycle
import resumable
import transfers
from lifecycle import LifecyclePhone
from resumable import Resumable
from transfers import BUNDLE, FRESH_SECONDS, INITIAL, KINDS, MIB, closing_reported, digest, inventory, require


class ProtectedData(Resumable):
    def wait_armed(self, item):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            sample = self.sample("wait-complete-protection")
            session = sample.get("protected_session", {})
            if session.get("key") == item["key"]:
                require(session["offset"] == MIB, "Host protected the wrong offset")
                require(session["protection"] == "NSFileProtectionComplete", "Host did not apply complete protection")
                return sample
            require(not any(row.get("error") for row in sample.get("protected_data_results", [])),
                    "Host failed to arm complete protection")
            time.sleep(.25)
        raise AssertionError("Phone did not protect the acknowledged upload session")

    def await_lock_cycle(self, item, armed):
        self.background_requested = True
        self.background_stamp = armed["sample_timestamp"]
        self.report["phase"] = "waiting_for_phone_lock"
        self.report["phone_action"] = "With WSK Device Test still visible, press the side button directly to lock (do not go Home first). Keep it locked for 30 seconds, then unlock it."
        self.save()
        print(self.report["phone_action"], flush=True)
        deadline = time.monotonic() + self.phone.args.wait_seconds
        locked = None
        background_observed = False
        while time.monotonic() < deadline:
            try:
                sample = self.phone.raw_sample("protected-data-cycle")
            except (AssertionError, OSError) as error:
                # CoreDevice may deny container access during the very lock
                # transition being tested. Only the later same-PID app evidence
                # can establish success; transport errors never substitute for it.
                self.report["last_report_copy_error"] = str(error)
                self.save()
                time.sleep(1)
                continue
            rows = sample.get("protected_data_results", [])
            require(not any(row.get("error") for row in rows), f"In-app protection probe failed: {rows}")
            events = sample.get("lifecycle_events", [])
            if (any(event.get("event") in ("did_enter_background", "protected_data_will_become_unavailable")
                    and event.get("timestamp", 0) > self.background_stamp for event in events)
                    or (sample["sample_timestamp"] > self.background_stamp
                        and (sample["app_state"] == "background" or sample.get("protected_data_available") is False))):
                background_observed = True
            for row in rows:
                if row.get("phase") == "locked" and row.get("key") == item["key"]:
                    require(row.get("observed_at", 0) > armed["protected_session"]["armed_at"], "Stale locked probe")
                    require(row.get("protected_data_available") is False and row.get("complete_protection") is True,
                            "No actual unavailable protected-data state")
                    require(row.get("read_errno") in (errno.EACCES, errno.EPERM),
                            f"Protected manifest remained readable: {row}")
                    require(row.get("http_status") == 500, f"Locked HEAD must retain session and return retryable 500: {row}")
                    require(row.get("manifest_retained") is True and row.get("payload_retained") is True
                            and row.get("payload_size") == MIB, "Denied request discarded or changed saved data")
                    locked = row
                    background_observed = True
            if locked:
                if self.report["phase"] != "waiting_for_phone_unlock":
                    self.report["locked_probe"] = locked
                    self.report["phase"] = "waiting_for_phone_unlock"
                    self.report["phone_action"] = "Protected-file denial was verified. Unlock the phone now."
                    print(self.report["phone_action"], flush=True)
                unlocked = next((row for row in rows if row.get("phase") == "unlocked"
                                 and row.get("key") == item["key"]
                                 and row.get("observed_at", 0) > locked["observed_at"]), None)
                if unlocked:
                    require(unlocked.get("protected_data_available") is True and unlocked.get("offset") == MIB,
                            "Unlock did not recover the identical acknowledged offset")
                    require(any(event["event"] == "protected_data_will_become_unavailable"
                                and event["timestamp"] > self.background_stamp for event in events),
                            "Missing fresh protected-data unavailable notification")
                    require(any(event["event"] == "protected_data_did_become_available"
                                and event["timestamp"] > locked["observed_at"] for event in events),
                            "Missing fresh protected-data available notification")
                    self.report["unlocked_probe"] = unlocked
                    self.report["lock_cycle_snapshot"] = sample
                    self.save()
                    return
            # Only keep the original body alive while waiting for the first
            # lock. Suspension can legitimately close it; after that transition
            # a fresh active sample means resume, not permission to reuse it.
            # Process the stored lock/unlock evidence before considering writes.
            if (not background_observed and sample["app_state"] == "active"
                    and sample.get("protected_data_available") is True
                    and time.time() - sample["sample_timestamp"] <= FRESH_SECONDS
                    and any(time.monotonic() - held["last_send"] >= 20 for held in self.held_sockets)):
                self.refresh_held()
            self.save()
            time.sleep(.5)
        raise AssertionError("Phone did not complete a proven locked-data-denial and unlock cycle before deadline")

    def run(self):
        initial = self.sample("initial")
        require(initial.get("protected_data_probe_enabled") is True,
                "Launch the fresh dedicated host with --probe-protected-data")
        require(initial.get("protected_data_available") is True, "Unlock the phone before starting")
        require(set(inventory(initial, "share_inventory")) == INITIAL, "Expected only fresh synthetic fixtures")
        require(set(inventory(initial, "resumable_inventory")) <= {".lock"}, "Prior sessions remain")
        self.temp_baseline = set(inventory(initial, "temp_inventory"))
        self.identity()
        for kind in KINDS:
            self.sample("warm-download-" + kind)
            self.download_pair(kind)
        self.baseline = self.idle(None)
        self.report["baseline"] = self.baseline
        item = self.make_item("protected-resume.bin", 2 * MIB + 31, self.phone.args.run_id + ":protected")
        self.report["file"] = {key: item[key] for key in ("key", "name", "sha256")}
        self.report["file"]["size"] = len(item["data"])
        self.sample("create-protected-session")
        self.create(item)
        self.patch(item, 0)
        self.head(item, MIB)
        armed = self.wait_armed(item)
        self.report["armed"] = armed
        self.hold_patch(item)
        deadline = time.monotonic() + 30
        while True:
            held = self.sample("protected-patch-held-before-lock")
            temporary = set(inventory(held, "temp_inventory"))
            payload = inventory(held, "resumable_inventory").get(item["key"] + "/payload", {})
            if (held["connections"] >= 1 and self.temp_baseline <= temporary
                    and len(temporary - self.temp_baseline) == 1 and payload.get("size") == MIB):
                self.report["held_before_lock"] = held
                break
            require(time.monotonic() < deadline, "Phone did not report the held PATCH and saved 1 MiB payload")
            time.sleep(.25)
        self.await_lock_cycle(item, armed)
        self.close_held()
        self.launch(BUNDLE, "activate-after-unlock")
        self.report["resumed"] = self.phone.resume(self.background_stamp)
        self.background_requested = False
        self.identity()
        self.head(item, MIB)
        offset = MIB
        while offset < len(item["data"]):
            self.sample("finish-protected-upload")
            offset = self.patch(item, offset)
        self.expected[item["name"]] = len(item["data"])
        self.head(item, len(item["data"]))
        self.create(item, len(item["data"]))
        for kind in KINDS:
            self.sample("verify-protected-result-" + kind)
            self.fetch(kind, item["name"], item["data"])
        published = self.sample("published-once")
        require(set(inventory(published, "share_inventory")) == set(self.expected), "Duplicate or unexpected publication")
        self.report["published"] = published
        self.report["same_key_resumed"] = self.report["both_protocol_checksums_verified"] = True
        self.delete_receipt(item)
        self.delete(item["name"])
        self.report["final"] = self.idle(self.baseline)
        self.report["phase"] = "complete"
        self.report.pop("phone_action", None)
        self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--wait-seconds", type=int, default=300, help="Bound for the human lock/unlock sequence (30–600)")
    args = parser.parse_args()
    uuid.UUID(args.run_id)
    require(30 <= args.wait_seconds <= 600, "Lock/unlock wait must be bounded to 30–600 seconds")
    report_path = args.report.resolve()
    samples_path = report_path.with_suffix(".samples.jsonl")
    require(not report_path.exists() and not samples_path.exists(), "Choose unused evidence paths")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "run_id": args.run_id, "device": args.device, "bundle_id": BUNDLE,
              "client": "Python standard-library HTTP plus native loopback HEAD during real protected-data denial",
              "scope": "Physical iPhone; complete-protection synthetic manifest/payload, same-process lock/unlock and same-key completion; no general change to application file protection",
              "mac_platform": platform.platform(), "sample_log": str(samples_path),
              "driver_sha256": digest(Path(__file__).read_bytes()),
              "resumable_sha256": digest(Path(resumable.__file__).read_bytes()),
              "lifecycle_sha256": digest(Path(lifecycle.__file__).read_bytes()),
              "transfers_sha256": digest(Path(transfers.__file__).read_bytes())}
    started = time.monotonic()
    try:
        with closing_reported(tempfile.TemporaryDirectory(prefix="wsk-protected-data-"), report, "local_probe_copy", "cleanup") as temporary, \
                closing_reported(samples_path.open("x"), report, "samples_log") as samples:
            phone = LifecyclePhone(args, Path(temporary.name), report, samples)
            driver = ProtectedData(phone, report, report_path)
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
