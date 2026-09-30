"""Sensitivity checks for the shared-folder audit's result oracles."""
import copy
import http.client
import io
import json
import threading
import unittest
from unittest.mock import Mock
import xml.etree.ElementTree as ET

from audit import SharedAudit, bodies_in_flight, check_listing, distribution


FILES = {"item-00000.txt": 32, "item-00001.txt": 33}


def dav_listing():
    root = ET.Element("{DAV:}multistatus")
    for name, size in [("catalog", None), *FILES.items()]:
        response = ET.SubElement(root, "{DAV:}response")
        ET.SubElement(response, "{DAV:}href").text = "/catalog/" + (name if size is not None else "")
        for prop, value, status in [("displayname", name, "200 OK"),
                                    ("getcontentlength", str(size) if size is not None else "",
                                     "200 OK" if size is not None else "404 Not Found")]:
            propstat = ET.SubElement(response, "{DAV:}propstat")
            ET.SubElement(ET.SubElement(propstat, "{DAV:}prop"), "{DAV:}" + prop).text = value
            ET.SubElement(propstat, "{DAV:}status").text = "HTTP/1.1 " + status
    return root


class ListingTests(unittest.TestCase):
    def test_uploader_requires_exact_inventory_sizes_and_names(self):
        rows = [{"name": name, "path": "/catalog/" + name, "size": size} for name, size in FILES.items()]
        check_listing("uploader", json.dumps(rows), FILES)
        variants = [rows[:-1], rows + [rows[0]],
                    [{**rows[0], "size": 999}, rows[1]],
                    [{**rows[0], "name": "another.txt"}, rows[1]],
                    [{**rows[0], "path": "/another/item-00000.txt"}, rows[1]]]
        for variant in variants:
            with self.subTest(variant=variant), self.assertRaises(AssertionError):
                check_listing("uploader", json.dumps(variant), FILES)

    def test_dav_accepts_complete_namespaced_results(self):
        check_listing("dav", ET.tostring(dav_listing()), FILES)

    def test_dav_requires_root_and_every_child_exactly_once(self):
        for change in ("no-root", "no-child", "duplicate", "wrong-href"):
            root = dav_listing()
            if change == "no-root":
                root.remove(root[0])
            elif change == "no-child":
                root.remove(root[-1])
            elif change == "duplicate":
                root.append(copy.deepcopy(root[-1]))
            else:
                root[-1].find("{DAV:}href").text = "/another/item-00001.txt"
            with self.subTest(change=change), self.assertRaises(AssertionError):
                check_listing("dav", ET.tostring(root), FILES)

    def test_dav_requires_property_values_statuses_and_namespaces(self):
        for change in ("size", "name", "status", "namespace", "duplicate", "missing", "collection-size"):
            root = dav_listing()
            resource = root[0] if change == "collection-size" else root[-1]
            propstats = resource.findall("{DAV:}propstat")
            if change == "size":
                propstats[-1].find("{DAV:}prop")[0].text = "999"
            elif change == "name":
                propstats[0].find("{DAV:}prop")[0].text = "wrong.txt"
            elif change in ("status", "collection-size"):
                propstats[-1].find("{DAV:}status").text = "HTTP/1.1 200 OK" if change == "collection-size" else "HTTP/1.1 404 Not Found"
            elif change == "namespace":
                propstats[-1].find("{DAV:}prop")[0].tag = "{urn:other}getcontentlength"
            elif change == "duplicate":
                resource.append(copy.deepcopy(propstats[-1]))
            else:
                resource.remove(propstats[-1])
            with self.subTest(change=change), self.assertRaises(AssertionError):
                check_listing("dav", ET.tostring(root), FILES)


class MeasurementTests(unittest.TestCase):
    def test_progress_and_four_body_evidence_require_temporal_overlap(self):
        bodies = [{"start": 1, "end": 4}] * 3 + [{"start": 2, "end": 5}]
        self.assertEqual(bodies_in_flight(bodies, 2.1, 2.1), 4)  # Response completed during sends.
        self.assertEqual(bodies_in_flight(bodies, 5, 5), 0)  # Completion after sends is insufficient.
        self.assertEqual(bodies_in_flight(bodies, 2.1, 3.9), 4)
        self.assertEqual(bodies_in_flight(bodies, 1.9, 2.1), 3)  # Fourth body started too late.
        self.assertEqual(bodies_in_flight(bodies, 3.9, 4.1), 1)  # Three finished within the sample.

    def test_tail_quantiles_need_enough_observations(self):
        self.assertIsNone(distribution([])["p50_ms"])
        self.assertIsNone(distribution(range(1, 20))["p95_ms"])
        self.assertEqual(distribution(range(1, 21))["p95_ms"], 19)
        self.assertIsNone(distribution(range(1, 1000))["p99_ms"])
        self.assertEqual(distribution(range(1, 1001))["p99_ms"], 990)
        self.assertEqual(distribution([9, 3, 1])["p50_ms"], 3)

    def test_request_rejects_truncation_and_closes_failed_response(self):
        for status, advertised, body in [(200, 3, b"abc"), (200, 4, b"abc"), (500, 3, b"abc")]:
            sock = Mock()
            sock.makefile.return_value = io.BytesIO(
                f"HTTP/1.1 {status} Test\r\nContent-Length: {advertised}\r\n\r\n".encode() + body)
            response = http.client.HTTPResponse(sock)
            response.begin()
            connection = Mock()
            connection.getresponse.return_value = response
            runner = SharedAudit.__new__(SharedAudit)
            runner.connection = Mock(return_value=connection)
            runner.lock, runner.report = threading.Lock(), {}
            with self.subTest(status=status, advertised=advertised):
                if status == 200 and advertised == len(body):
                    self.assertEqual(runner.request("dav", "GET", "/file")[0], body)
                    self.assertEqual(runner.report["requests"], 1)
                else:
                    with self.assertRaises(AssertionError):
                        runner.request("dav", "GET", "/file")
                self.assertTrue(response.isclosed())
                connection.close.assert_called_once()


class DiagnosticTests(unittest.TestCase):
    def runner(self, connection):
        runner = SharedAudit.__new__(SharedAudit)
        runner.lock, runner.report = threading.Lock(), {}
        runner.connection = Mock(return_value=connection)
        return runner

    def test_post_workload_failure_keeps_phase_evidence(self):
        for stage in ("sampler_checks", "concurrency_checks", "settle"):
            runner = self.runner(Mock())
            runner.files = {"file": 1}
            primary = AssertionError("scripted phase failure")

            def fail_phase(name, seconds, listings, warmup, state, started):
                state.update(stage=stage, sample_count=3, last_resource_sample={"connections": 1})
                runner.record("get.dav", 1, 1.001, 1.002, 5)
                raise primary

            runner._phase = Mock(side_effect=fail_phase)
            with self.subTest(stage=stage), self.assertRaises(AssertionError) as caught:
                runner.phase("fixture", 1, True)
            self.assertIs(caught.exception, primary)
            item = runner.report["failed_phase"]
            self.assertEqual((item["name"], item["stage"], item["sample_count"]), ("fixture", stage, 3))
            self.assertEqual(item["last_resource_sample"], {"connections": 1})
            self.assertEqual(item["operations"]["get.dav"]["latency"]["count"], 1)
            self.assertEqual(item["operations"]["get.dav"]["response_bytes"], 5)


if __name__ == "__main__":
    unittest.main()
