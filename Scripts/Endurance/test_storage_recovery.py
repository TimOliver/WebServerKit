"""An unapplied fault or cleanup failure must never count as recovery evidence."""
import unittest

from storage_recovery import check_fault
from run import CHUNK, MIB


class StorageFaultOracleTests(unittest.TestCase):
    def test_write_failure_requires_actual_prefix_one_hit_and_descriptor_cleanup(self):
        fixture = dict(mode="write-enospc", released=True, hits=1, bytes_written=2 * CHUNK,
                       target_closed=True, real_closed=True, target_fd=-1)
        check_fault(fixture, "write-enospc", MIB)
        for key, value in [("mode", "close-eio"), ("released", False), ("hits", 0), ("hits", 2),
                           ("bytes_written", 0), ("bytes_written", MIB), ("target_closed", False),
                           ("real_closed", False), ("target_fd", 9)]:
            with self.subTest(key=key, value=value), self.assertRaises(AssertionError):
                check_fault({**fixture, key: value}, "write-enospc", MIB)

    def test_close_failure_requires_complete_body_and_successful_real_close(self):
        fixture = dict(mode="close-eio", released=True, hits=1, bytes_written=MIB,
                       target_closed=True, real_closed=True, target_fd=-1,
                       real_close_result=0, close_result=-1)
        check_fault(fixture, "close-eio", MIB)
        for key, value in [("bytes_written", 2 * CHUNK), ("real_close_result", -1), ("close_result", 0)]:
            with self.subTest(key=key, value=value), self.assertRaises(AssertionError):
                check_fault({**fixture, key: value}, "close-eio", MIB)


if __name__ == "__main__":
    unittest.main()
