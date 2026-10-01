#!/usr/bin/env python3
"""Offline checks that the recovery oracle refuses missing or mis-scoped proof."""
import copy
import errno
from pathlib import Path
import unittest
from recovery import MIB, authoritative_offset, verify_fault


class FaultProofTests(unittest.TestCase):
    key = "11111111-2222-4333-8444-555555555555"
    sessions, shared = Path("/private/tmp/owned/sessions"), Path("/private/tmp/owned/shared")

    def proof(self):
        return {"armed": True, "mode": "payload-write-enospc", "hits": 1, "bytes_written": 65536,
                "event": {"path": str(self.sessions / self.key / "payload"), "operation": "write",
                          "exists": True, "device": 1, "inode": 2, "size": MIB + 65536, "errno": errno.ENOSPC}}

    def validate(self, proof):
        verify_fault(proof, "payload-write-enospc", self.sessions, self.shared, self.key)

    def test_proven_owned_failure_is_accepted(self):
        self.validate(self.proof())

    def test_missing_or_repeated_fault_is_rejected(self):
        for count in (0, 2):
            proof = self.proof()
            proof["hits"] = count
            with self.assertRaises(AssertionError):
                self.validate(proof)

    def test_another_session_or_scope_is_rejected(self):
        for path in (self.sessions / "other" / "payload", self.shared / "payload", Path("/private/tmp/unrelated/payload")):
            proof = self.proof()
            proof["event"]["path"] = str(path)
            with self.assertRaises(AssertionError):
                self.validate(proof)

    def test_wrong_errno_and_identity_are_rejected(self):
        for field, value in (("errno", errno.EIO), ("inode", 0), ("exists", False)):
            proof = self.proof()
            proof["event"][field] = value
            with self.assertRaises(AssertionError):
                self.validate(proof)

    def test_failed_first_write_is_not_a_disk_prefix(self):
        proof = self.proof()
        proof["bytes_written"] = 0
        with self.assertRaises(AssertionError):
            self.validate(proof)

    def test_prejournal_exit_needs_created_empty_stage(self):
        proof = self.proof()
        proof.update(mode="exit-stage-open", bytes_written=0)
        proof["event"].update(path=str(self.sessions / self.key / (".stage-" + self.key)), operation="open-after", size=0, errno=0)
        verify_fault(proof, "exit-stage-open", self.sessions, self.shared, self.key)
        proof["event"]["size"] = 65536
        with self.assertRaises(AssertionError):
            verify_fault(proof, "exit-stage-open", self.sessions, self.shared, self.key)

    def test_acknowledged_manifest_and_publication_are_authoritative(self):
        self.assertEqual(authoritative_offset("exit-payload-fsync", 3 * MIB), MIB)
        self.assertEqual(authoritative_offset("exit-active-save", 3 * MIB), 2 * MIB)
        for mode in ("manifest-complete-close-eio", "exit-publication-after", "exit-complete-save"):
            self.assertEqual(authoritative_offset(mode, 3 * MIB), 3 * MIB)


if __name__ == "__main__":
    unittest.main()
