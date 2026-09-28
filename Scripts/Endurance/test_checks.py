"""Fault fixtures for the runner's oracles; no library or external service needed."""
import io
import http.client
from pathlib import Path
import tempfile
import threading
import socket
import time
import unittest
from unittest.mock import patch

from run import DeadlineConnection, MIB, Runner, check_entries, check_resources, digest


class WireSocket:
    def __init__(self, body, status=200):
        self.wire = (f"HTTP/1.1 {status} Test\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body)

    def makefile(self, *args):
        return io.BytesIO(self.wire)


class OracleTests(unittest.TestCase):
    def setUp(self):
        self.runner = Runner.__new__(Runner)
        self.runner.lock = threading.Lock()
        self.runner.report = {}

    def verify(self, body, expected=b"correct payload", status=200):
        response = http.client.HTTPResponse(WireSocket(body, status))
        response.begin()
        try:
            self.runner.verify_response(response, digest(expected), len(expected))
        finally:
            response.close()

    def test_byte_corruption_cannot_pass_the_length_check(self):
        self.verify(b"correct payload")
        with self.assertRaisesRegex(AssertionError, "SHA-256"):
            self.verify(b"corrupt payload")

    def test_truncation_overlong_body_and_wrong_status_fail(self):
        for body, status in [(b"short", 200), (b"correct payload plus", 200), (b"correct payload", 500)]:
            with self.subTest(body=body, status=status), self.assertRaises(AssertionError):
                self.verify(body, status=status)

    def test_ownership_leaks_cannot_hide_behind_footprint_allowance(self):
        baseline = dict(connections=0, accepted=10, closed=10, reserved_bytes=0,
                        uploads=0, downloads=0, descriptors=8, footprint_bytes=20 * MIB)
        check_resources(baseline, baseline, 64 * MIB)
        for key, value in [("connections", 1), ("closed", 9), ("reserved_bytes", 1),
                           ("uploads", 1), ("downloads", 1), ("descriptors", 9), ("footprint_bytes", 85 * MIB)]:
            with self.subTest(key=key), self.assertRaises(AssertionError):
                check_resources({**baseline, key: value}, baseline, 64 * MIB)

    def test_hidden_staging_file_and_cancelled_destination_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "asset.bin").touch()
            check_entries(path, {"asset.bin"})
            for name in (".stage-orphan", "cancelled.bin"):
                (path / name).touch()
                with self.subTest(name=name), self.assertRaises(AssertionError):
                    check_entries(path, {"asset.bin"})
                (path / name).unlink()

    def test_close_framed_body_keeps_the_transaction_deadline(self):
        # Real sockets, no server: a complete header followed by a body that never
        # arrives. getresponse() calls HTTPConnection.close() internally here.
        client, peer = socket.socketpair()
        client.settimeout(3)
        connection = DeadlineConnection("unused", timeout=3)
        try:
            with patch("run.TIMEOUT", 0.5), patch.object(http.client.HTTPConnection, "connect", lambda c: setattr(c, "sock", client)):
                connection.request("GET", "/")
                peer.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 1\r\n\r\n")
                response = connection.getresponse()
                started = time.monotonic()
                try:
                    self.assertEqual(response.read(1), b"")
                    self.assertLess(time.monotonic() - started, 2)
                finally:
                    response.close()
        finally:
            connection.close()
            peer.close()


if __name__ == "__main__":
    unittest.main()
