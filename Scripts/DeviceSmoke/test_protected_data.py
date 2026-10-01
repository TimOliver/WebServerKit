#!/usr/bin/env python3
"""Offline lifecycle-oracle checks; no phone, sockets, or file mutations."""
import errno
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from protected_data import ProtectedData
from transfers import MIB


class ProtectedDataOracleTests(unittest.TestCase):
    def driver(self, samples):
        driver = ProtectedData.__new__(ProtectedData)
        driver.phone = SimpleNamespace(args=SimpleNamespace(wait_seconds=30), raw_sample=Mock(side_effect=samples))
        driver.report = {}
        driver.save = Mock()
        driver.held_sockets = [{"last_send": 0}]
        # A closed socket is expected after suspension, but must still surface
        # when the original pre-background request unexpectedly fails.
        driver.refresh_held = Mock(side_effect=BrokenPipeError(errno.EPIPE, "closed held body"))
        return driver

    def sample(self, state="active", rows=(), events=()):
        return {"app_state": state, "sample_timestamp": 150, "protected_data_available": state == "active",
                "protected_data_results": list(rows), "lifecycle_events": list(events)}

    def completed(self):
        locked = {"phase": "locked", "key": "test-session", "observed_at": 120,
                  "protected_data_available": False, "complete_protection": True,
                  "read_errno": errno.EPERM, "http_status": 500, "manifest_retained": True,
                  "payload_retained": True, "payload_size": MIB}
        unlocked = {"phase": "unlocked", "key": "test-session", "observed_at": 140,
                    "protected_data_available": True, "offset": MIB}
        events = [{"event": "protected_data_will_become_unavailable", "timestamp": 110},
                  {"event": "protected_data_did_become_available", "timestamp": 140}]
        return self.sample(rows=[locked, unlocked], events=events)

    def run_cycle(self, driver):
        with patch("protected_data.time.monotonic", return_value=500), \
                patch("protected_data.time.time", return_value=150), \
                patch("protected_data.time.sleep"), patch("builtins.print"):
            driver.await_lock_cycle({"key": "test-session"},
                                    {"sample_timestamp": 100, "protected_session": {"armed_at": 90}})

    def test_resumed_snapshot_processes_proof_before_touching_closed_body(self):
        driver = self.driver([self.completed()])
        self.run_cycle(driver)
        driver.refresh_held.assert_not_called()
        self.assertEqual(driver.report["unlocked_probe"]["offset"], MIB)

    def test_observed_background_stays_terminal_for_original_body(self):
        background = self.sample("background", events=[{"event": "did_enter_background", "timestamp": 110}])
        # Even an intermediate active sample without the final proof cannot
        # restart writes to a request from before the observed suspension.
        driver = self.driver([background, self.sample(), self.completed()])
        self.run_cycle(driver)
        driver.refresh_held.assert_not_called()
        self.assertEqual(driver.report["unlocked_probe"]["offset"], MIB)

    def test_unavailable_notification_prevents_refresh_before_background_snapshot(self):
        will_lock = self.sample(events=[{"event": "protected_data_will_become_unavailable", "timestamp": 110}])
        driver = self.driver([will_lock, self.sample(), self.completed()])
        self.run_cycle(driver)
        driver.refresh_held.assert_not_called()

    def test_pre_background_broken_body_is_still_a_failure(self):
        stale_event = {"event": "did_enter_background", "timestamp": 50}
        driver = self.driver([self.sample(events=[stale_event])])
        with self.assertRaises(BrokenPipeError):
            self.run_cycle(driver)
        driver.refresh_held.assert_called_once()
        self.assertNotIn("locked_probe", driver.report)


if __name__ == "__main__":
    unittest.main()
