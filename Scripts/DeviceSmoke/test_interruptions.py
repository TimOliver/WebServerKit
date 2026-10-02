#!/usr/bin/env python3
"""Negative controls for physical interruption evidence; no device or network."""
import copy
import time
import unittest
import uuid

from interruptions import (BUNDLE, MIB, check_clean_resources, check_owned_process,
                           check_prefixes, check_relaunch, wifi_absent_while_serving)


class InterruptionOracleTests(unittest.TestCase):
    def sample(self):
        return {"run_id": "owned-run", "bundle_id": BUNDLE, "pid": 123,
                "launch_id": str(uuid.uuid4()), "sample_timestamp": time.time(),
                "status": "ready", "app_state": "active", "wifi_ipv4": None,
                "uploader_running": True, "dav_running": True}

    def test_outage_requires_fresh_foreground_app_and_both_running_servers(self):
        value = self.sample()
        self.assertTrue(wifi_absent_while_serving(value, value["sample_timestamp"] - 1))
        for key, bad in [("wifi_ipv4", "192.168.1.2"), ("app_state", "background"),
                         ("uploader_running", False), ("dav_running", False),
                         ("sample_timestamp", time.time() - 60), ("status", "failed")]:
            with self.subTest(key=key):
                self.assertFalse(wifi_absent_while_serving({**value, key: bad}, 0))
        self.assertFalse(wifi_absent_while_serving(value, value["sample_timestamp"]))

    def test_relaunch_requires_actual_new_pid_generation_and_persisted_run(self):
        before = self.sample()
        after = {**before, "pid": 124, "launch_id": str(uuid.uuid4()), "resumed_existing_run": True}
        check_relaunch(after, before, 124, time.time() - 1)
        for key, bad in [("pid", 123), ("run_id", "other-run"), ("bundle_id", "other.app"),
                         ("launch_id", before["launch_id"]), ("resumed_existing_run", False),
                         ("sample_timestamp", time.time() - 60)]:
            with self.subTest(key=key), self.assertRaises(AssertionError):
                check_relaunch({**after, key: bad}, before, 124, time.time() - 1)
        with self.assertRaises(AssertionError):
            check_relaunch(after, before, 123, time.time() - 1)

    def test_kill_requires_current_pid_and_exact_installed_app_executable(self):
        root = "file:///private/var/containers/Bundle/Application/owned/WebServerKitExample.app/"
        installation = {"result": {"installedApplications": [{"bundleID": BUNDLE, "installationURL": root}]}}
        process = {"processIdentifier": 123, "executable": root + "WebServerKitExample"}
        self.assertEqual(check_owned_process([process], 123, installation), process)
        for rows in [[], [{**process, "processIdentifier": 124}],
                     [{**process, "executable": "file:///other/app"}], [process, process]]:
            with self.subTest(rows=rows), self.assertRaises(AssertionError):
                check_owned_process(rows, 123, installation)
        bad = copy.deepcopy(installation)
        bad["result"]["installedApplications"][0]["bundleID"] = "another.app"
        with self.assertRaises(AssertionError):
            check_owned_process([process], 123, bad)

    def test_saved_prefix_must_keep_each_original_key_and_size(self):
        item = {"key": "original"}
        sample = {"resumable_inventory": {"errors": [], "entries": [
            {"path": "original/payload", "type": "file", "size": MIB}]}}
        check_prefixes(sample, [item])
        for key, bad in [("path", "replacement/payload"), ("size", 0), ("size", MIB + 65536), ("type", "symlink")]:
            changed = copy.deepcopy(sample)
            changed["resumable_inventory"]["entries"][0][key] = bad
            with self.subTest(key=key, bad=bad), self.assertRaises(AssertionError):
                check_prefixes(changed, [item])

    def test_cleanup_never_adopts_crash_spools_or_receipts_as_baseline(self):
        sample = {"connections": 0, "reserved_bytes": 0, "accepted": 8, "closed": 8, "descriptors": 7,
                  "share_inventory": {"entries": [{"path": "asset.bin", "type": "file", "size": 10}], "errors": []},
                  "temp_inventory": {"entries": [], "errors": []},
                  "resumable_inventory": {"entries": [{"path": ".lock", "type": "file", "size": 0}], "errors": []}}
        check_clean_resources(sample, {"descriptors": 7}, {"asset.bin": 10}, set())
        for field in ["temp_inventory", "resumable_inventory"]:
            changed = copy.deepcopy(sample)
            changed[field]["entries"].append({"path": "orphan", "type": "file", "size": 65536})
            with self.subTest(field=field), self.assertRaises(AssertionError):
                check_clean_resources(changed, {"descriptors": 7}, {"asset.bin": 10}, set())
        for key, bad in [("connections", 1), ("reserved_bytes", 1), ("closed", 7), ("descriptors", 8)]:
            with self.subTest(key=key), self.assertRaises(AssertionError):
                check_clean_resources({**sample, key: bad}, {"descriptors": 7}, {"asset.bin": 10}, set())


if __name__ == "__main__":
    unittest.main()
