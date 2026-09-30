"""Fault fixtures for the runner's oracles; no library or external service needed."""
import io
import http.client
import json
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from pathlib import Path
import tempfile
import threading
import socket
import time
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import audit
import run
from run import DeadlineConnection, Host, MIB, Runner, check_entries, check_resources, closing_reported, digest


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


class ReportCleanupTests(unittest.TestCase):
    def test_startup_and_initial_upload_errors_survive_failed_close(self):
        report = {}
        primary = TimeoutError("startup failed")
        with tempfile.TemporaryDirectory() as directory, \
                patch("run.subprocess.Popen"), patch.object(Host, "read", side_effect=primary), \
                patch.object(Host, "close", side_effect=OSError("close failed")), \
                self.assertRaises(TimeoutError) as caught:
            Host(Path("/unused"), Path("/unused.dylib"), Path(directory), None, report=report)
        self.assertIs(caught.exception, primary)
        self.assertEqual(report["cleanup_errors"][0]["resource"], "host_startup")

        connection = Mock()
        primary = TimeoutError("send failed")
        connection.send.side_effect = primary
        connection.close.side_effect = OSError("close failed")
        runner = Runner.__new__(Runner)
        runner.connection, runner.report = Mock(return_value=connection), {}
        with self.assertRaises(TimeoutError) as caught:
            runner.begin_upload("dav", "file.bin", b"contents")
        self.assertIs(caught.exception, primary)
        self.assertEqual(runner.report["cleanup_errors"][0]["resource"], "upload_connection")

    def test_handled_outer_exception_does_not_suppress_cleanup_failure(self):
        resource, report = Mock(), {}
        resource.close.side_effect = OSError("cleanup failed")
        try:
            raise ValueError("already handled")
        except ValueError:
            with self.assertRaisesRegex(OSError, "cleanup failed"):
                with closing_reported(resource, report, "fixture"):
                    pass
        self.assertEqual(report["cleanup_errors"][0]["resource"], "fixture")

    def test_both_mains_fail_on_cleanup_and_preserve_workload_error(self):
        # Scripted no-I/O workloads isolate report and cleanup behavior; no build
        # tools, server processes or sockets are used by these cases.
        for module in (run, audit):
            for failure in (None, "host", "temporary_directory", "workload_and_cleanup"):
                with self.subTest(module=module.__name__, failure=failure), tempfile.TemporaryDirectory() as directory:
                    report_path = Path(directory) / "report.json"
                    temporary = SimpleNamespace(name=str(Path(directory) / "scratch"), cleanup=Mock())
                    host = Mock()
                    host.process.pid, host.process.wait.return_value = 123, 0
                    host.command.return_value = {"running": False}
                    if failure in ("host", "workload_and_cleanup"):
                        host.close.side_effect = OSError("host cleanup failed")
                    if failure in ("temporary_directory", "workload_and_cleanup"):
                        temporary.cleanup.side_effect = OSError("temporary cleanup failed")

                    def runner_factory(host, args, report, *unused):
                        runner = Mock(stopped_baseline={})
                        runner.quiescent.return_value = {"accepted": 0, "descriptors": 8}
                        runner.cycle.return_value = {"accepted": 0, "descriptors": 8, "footprint_bytes": 0, "reserved_bytes": 0}
                        runner.phase.return_value = {}
                        report["verified_bytes"] = 0
                        if failure == "workload_and_cleanup":
                            runner.cycle.side_effect = ValueError("workload failed")
                            runner.phase.side_effect = ValueError("workload failed")
                        return runner

                    extra = ["--cycles", "1", "--restart-cycles", "0", "--pause", "0"] if module is run else ["--entries", "1", "--seconds", "1", "--repeats", "1"]
                    with ExitStack() as stack:
                        stack.enter_context(patch.object(module.sys, "argv", [module.__name__, "--report", str(report_path), *extra]))
                        stack.enter_context(patch.object(module.subprocess, "run"))
                        stack.enter_context(patch.object(module.subprocess, "check_output", return_value="/unused"))
                        if module is audit:
                            stack.enter_context(patch.object(module.platform, "platform", return_value="fixture"))
                        stack.enter_context(patch.object(module.tempfile, "TemporaryDirectory", return_value=temporary))
                        stack.enter_context(patch.object(module, "Host", return_value=host))
                        stack.enter_context(patch.object(module, "Runner" if module is run else "SharedAudit", side_effect=runner_factory))
                        stack.enter_context(redirect_stdout(io.StringIO()))
                        stack.enter_context(redirect_stderr(io.StringIO()))
                        status = module.main()
                    report = json.loads(report_path.read_text())
                    self.assertEqual(status, 0 if failure is None else 1, report.get("error"))
                    self.assertEqual(report["passed"], failure is None)
                    host.close.assert_called_once()
                    temporary.cleanup.assert_called_once()
                    if failure == "workload_and_cleanup":
                        self.assertEqual(report["error"], "ValueError: workload failed")
                        self.assertEqual([e["resource"] for e in report["cleanup_errors"]], ["host", "temporary_directory"])


if __name__ == "__main__":
    unittest.main()
