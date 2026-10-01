"""Offline checks keep weak endurance evidence from passing the audit."""
import unittest

from endurance import check_idle, check_idle_inventory, check_maintenance_only, check_read_progress, summarize_memory


class EnduranceOracleTests(unittest.TestCase):
    def setUp(self):
        self.idle = dict(connections=0, accepted=10, closed=10, uploads=0,
                         downloads=0, reserved_bytes=0, descriptors=8,
                         footprint_bytes=1000, allocator_live_bytes=100,
                         allocator_live_blocks=10, allocator_reserved_bytes=800)

    def test_idle_requires_exact_resource_ownership(self):
        check_idle(self.idle, self.idle, 500, 20)
        for key, value in (("connections", 1), ("accepted", 11), ("uploads", 1),
                           ("downloads", 1), ("reserved_bytes", 1),
                           ("descriptors", 9), ("footprint_bytes", 1501),
                           ("allocator_live_bytes", 121)):
            with self.subTest(key=key), self.assertRaises(AssertionError):
                check_idle({**self.idle, key: value}, self.idle, 500, 20)

    def test_idle_rejects_deleted_receipts_even_below_the_retention_limit(self):
        empty = {"active": [], "complete": [], "payloads": [], "stages": [], "unknown": []}
        check_idle_inventory(empty)
        for count in (1, 128):
            with self.subTest(count=count), self.assertRaises(AssertionError):
                check_idle_inventory({**empty, "complete": [str(index) for index in range(count)]})
        # Allowing a deliberate partial upload never permits a deleted receipt.
        with self.assertRaises(AssertionError):
            check_idle_inventory({**empty, "complete": ["retained"]}, allow_active=True)

    def test_idle_inventory_rejects_other_session_residue(self):
        empty = {"active": [], "complete": [], "payloads": [], "stages": [], "unknown": []}
        for key in ("active", "payloads", "stages", "unknown"):
            with self.subTest(key=key), self.assertRaises(AssertionError):
                check_idle_inventory({**empty, key: ["residue"]})
        check_idle_inventory({**empty, "active": ["partial"], "payloads": ["partial/payload"]}, allow_active=True)

    def test_allocator_reserve_is_not_misreported_as_live_growth(self):
        high_reserve = {**self.idle, "allocator_reserved_bytes": 100000}
        check_idle(high_reserve, self.idle, 500, 20)
        result = summarize_memory([{"resources": self.idle}, {"resources": high_reserve}])
        self.assertEqual(result["allocator_live_bytes"]["delta"], 0)
        self.assertEqual(result["allocator_reserved_bytes"]["delta"], 99200)
        self.assertFalse(result["allocator_live_bytes"]["strictly_increasing"])

    def test_progress_requires_complete_reads_inside_the_active_window(self):
        good = [{"kind": "uploader", "start": 2, "end": 3},
                {"kind": "dav", "start": 2.1, "end": 4}]
        check_read_progress(good, 2, 4)
        for altered in (good[:1], [{**good[0], "start": 1}, good[1]],
                        [good[0], {**good[1], "end": 5}]):
            with self.subTest(altered=altered), self.assertRaises(AssertionError):
                check_read_progress(altered, 2, 4)

    def test_memory_summary_retains_direction_and_peak(self):
        samples = [{"resources": {**self.idle, "allocator_live_bytes": value}}
                   for value in (100, 120, 105)]
        result = summarize_memory(samples)["allocator_live_bytes"]
        self.assertEqual(result["delta"], 5)
        self.assertEqual(result["maximum"], 120)
        self.assertFalse(result["nondecreasing"])
        with self.assertRaises(AssertionError):
            summarize_memory([])

    def test_expiry_cannot_be_credited_to_periodic_maintenance_after_a_head(self):
        before = {"POST": 4, "PATCH": 4}
        check_maintenance_only(before, before, 10, 4)
        for after, downloads, removed in (({**before, "HEAD": 1}, 10, 4),
                                           (before, 0, 4), (before, 10, 3)):
            with self.subTest(after=after, downloads=downloads, removed=removed), self.assertRaises(AssertionError):
                check_maintenance_only(before, after, downloads, removed)


if __name__ == "__main__":
    unittest.main()
