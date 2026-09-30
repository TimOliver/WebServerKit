"""Profile reports must retain partial progress and reject invalid CPU deltas."""
import io
import subprocess
import unittest
from unittest.mock import Mock, patch

from profile_listings import ListingProfile, cpu_delta, inspect_leaks


class ProfileTests(unittest.TestCase):
    def test_cpu_delta_uses_both_counters_and_rejects_reset(self):
        before = {"cpu_user_seconds": 2, "cpu_system_seconds": 1}
        after = {"cpu_user_seconds": 2.5, "cpu_system_seconds": 1.25}
        self.assertEqual(cpu_delta(before, after)["cpu_total_seconds"], .75)
        with self.assertRaises(AssertionError):
            cpu_delta(after, before)

    def test_failed_batch_does_not_count_unvalidated_listing(self):
        runner = Mock()
        original = AssertionError("incomplete listing")
        runner.listing.side_effect = [None, original]
        report = {"cycles": []}
        profile = ListingProfile(runner, report, io.StringIO())
        profile.snapshot = Mock(return_value={})
        with self.assertRaises(AssertionError) as caught:
            profile.batch("fixture", 3, 1)
        self.assertIs(caught.exception, original)
        cycle, = report["cycles"]
        self.assertEqual(cycle["requested_listings"], 3)
        self.assertEqual(cycle["completed_listings"], 1)
        self.assertNotIn("idle", cycle)
        self.assertIn("elapsed_seconds", cycle)
        self.assertGreaterEqual(cycle["requests_end_elapsed"], cycle["requests_start_elapsed"])
        self.assertEqual(runner.listing.call_count, 2)

    def test_leak_timeout_survives_log_close_failure(self):
        report, host, path = {}, Mock(), Mock()
        path.open.return_value.close.side_effect = OSError("log close failed")
        original = subprocess.TimeoutExpired("leaks", 45)
        with patch("profile_listings.subprocess.run", side_effect=original):
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                inspect_leaks(host, path, report)
        self.assertIs(caught.exception, original)
        self.assertEqual(report["leaks"], {"path": str(path), "completed": False})
        self.assertIn("log close failed", str(report["cleanup_errors"]))


if __name__ == "__main__":
    unittest.main()
