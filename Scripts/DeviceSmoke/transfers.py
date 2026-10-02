#!/usr/bin/env python3
"""Normal foreground Wi-Fi transfers against the identified, installed smoke app."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import hashlib
import ipaddress
import json
import math
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from urllib.parse import quote, urlparse
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts" / "Endurance"))
import run as endurance
from run import CHUNK, MIB, DeadlineConnection, Runner, closing_reported, digest, read_small_response, require

endurance.TIMEOUT = TIMEOUT = 60
BUNDLE = "com.timoliver.WebServerKitDeviceSmoke"
KINDS = ("uploader", "dav")
INITIAL = {"asset.bin", "probe-identity.json"}
FRESH_SECONDS = 15
LIST_BODY = b'<D:propfind xmlns:D="DAV:"><D:prop><D:displayname/><D:getcontentlength/></D:prop></D:propfind>'


def inventory(sample, field):
    value = sample[field]
    require(not value["errors"], f"Phone inventory failed: {field}: {value['errors']}")
    result = {}
    for item in value["entries"]:
        name = item["path"]
        require(isinstance(name, str) and name not in result, f"Duplicate or invalid {field} entry")
        result[name] = item
    return result


class Phone:
    def __init__(self, args, directory, report, samples):
        self.args, self.directory, self.report, self.samples = args, directory, report, samples
        self.pid, self.endpoint, self.latest = None, None, None

    def sample(self, label):
        destination = self.directory / "probe.json"
        destination.unlink(missing_ok=True)
        command = ["xcrun", "devicectl", "device", "copy", "from", "--device", self.args.device,
                   "--source", "Documents/probe.json", "--destination", str(destination),
                   "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                   "--timeout", "20", "--quiet"]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
        require(result.returncode == 0, f"Device report copy failed: {result.stderr.decode(errors='replace')[-2000:]}")
        require(destination.stat().st_size <= MIB, "Device report exceeds one MiB")
        sample = json.loads(destination.read_bytes())
        self.samples.write(json.dumps({"label": label, "received_at": time.time(), "phone": sample}) + "\n")
        self.samples.flush()
        self.report["last_phone_sample"] = sample
        require(sample["run_id"] == self.args.run_id and sample["bundle_id"] == BUNDLE, "Device report identity differs")
        require(type(sample["pid"]) is int and sample["pid"] > 0, "Invalid phone PID")
        stamp = sample["sample_timestamp"]
        require(isinstance(stamp, (int, float)) and math.isfinite(stamp) and -3 <= time.time() - stamp <= FRESH_SECONDS,
                "Phone report is stale or its clock differs from the Mac")
        require(sample["status"] == "ready" and sample["app_state"] == "active", "Smoke app must remain ready and foreground active")
        require(sample["uploader_running"] and sample["dav_running"], "Both phone servers must be running")
        address = ipaddress.IPv4Address(sample["wifi_ipv4"])
        require(not (address.is_unspecified or address.is_multicast or address.is_loopback), "Invalid phone Wi-Fi address")
        ports = tuple(sample[kind + "_port"] for kind in KINDS)
        require(all(type(port) is int and 0 < port <= 65535 for port in ports), "Invalid phone server port")
        endpoint = str(address), ports
        if self.pid is None:
            self.pid, self.endpoint = sample["pid"], endpoint
            self.report.update(phone_pid=self.pid, phone_os=sample["os_version"], wifi_ipv4=str(address),
                               uploader_port=ports[0], dav_port=ports[1])
        require(self.pid == sample["pid"] and self.endpoint == endpoint, "Phone process or server endpoint changed")
        for key in ("connections", "accepted", "closed", "reserved_bytes", "descriptors"):
            require(type(sample[key]) is int and sample[key] >= 0, f"Unavailable or invalid phone metric: {key}")
        inventory(sample, "share_inventory")
        inventory(sample, "temp_inventory")
        self.latest = sample
        return sample


class Transfers(Runner):
    # Reuse only the bounded HTTP helpers; the local endurance Host is never created.
    def __init__(self, phone, report, report_path):
        self.phone, self.report, self.report_path = phone, report, report_path
        self.lock = threading.Lock()
        self.asset = b"\x5a" * (8 * MIB)
        self.asset_hash = digest(self.asset)
        self.prefix = "smoke-" + str(uuid.UUID(phone.args.run_id)) + "-"
        self.owned = set()
        self.expected = {"asset.bin": len(self.asset)}
        self.temp_baseline = None
        self.baseline = None

    def save(self):
        with self.lock:
            self.report_path.write_text(json.dumps(self.report, indent=2) + "\n")

    def sample(self, label):
        sample = self.phone.sample(label)
        self.save()
        return sample

    def connection(self, kind):
        require(self.phone.latest is not None and time.time() - self.phone.latest["sample_timestamp"] <= FRESH_SECONDS,
                "A fresh phone report is required before opening a connection")
        return DeadlineConnection(self.phone.endpoint[0], self.phone.endpoint[1][KINDS.index(kind)], timeout=TIMEOUT)

    def request(self, kind, method, path, expected=200, body=None, headers=None):
        with closing_reported(self.connection(kind), self.report, "http_connection") as connection:
            connection.request(method, path, body, {"Connection": "close", **(headers or {})})
            response = connection.getresponse()
            status = response.status
            fields = {key.lower(): value for key, value in response.getheaders()}
            data = read_small_response(response)
            self.count(requests=1)
            require(status in expected if isinstance(expected, tuple) else status == expected,
                    f"{kind} {method} {path}: expected {expected}, got {status}")
            return data, fields, status

    def identity(self):
        contents = []
        for kind in KINDS:
            body, _, _ = self.request(kind, "GET", self.path(kind, "probe-identity.json"))
            value = json.loads(body)
            require(value.get("run_id") == self.phone.args.run_id and value.get("bundle_id") == BUNDLE,
                    f"{kind} HTTP server identity differs from the selected phone run")
            contents.append(body)
        require(contents[0] == contents[1], "Servers do not expose the same identity file")
        self.expected["probe-identity.json"] = len(contents[0])

    def fetch(self, kind, name, data, etag=None):
        headers = {"Accept-Encoding": "identity", "Connection": "close"}
        if etag is not None:
            start, end = CHUNK, 3 * CHUNK - 1
            headers.update(Range=f"bytes={start}-{end}", **{"If-Range": etag})
            expected_data, status = data[start:end + 1], 206
        else:
            expected_data, status = data, 200
        with closing_reported(self.connection(kind), self.report, "download_connection") as connection:
            connection.request("GET", self.path(kind, name), headers=headers)
            response = connection.getresponse()
            fields = {key.lower(): value for key, value in response.getheaders()}
            self.verify_response(response, digest(expected_data), len(expected_data), status)
        if etag is not None:
            require(fields.get("content-range") == f"bytes {start}-{end}/{len(data)}", "Range metadata differs")
        else:
            require(fields.get("etag") and not fields["etag"].startswith("W/"), "Expected a strong file ETag")
        return fields["etag"]

    def advertised_identity(self):
        # Keep the connection on the identity-verified Wi-Fi endpoint. Exercise
        # the advertised Host spelling without depending on the Mac's resolver.
        deadline = time.monotonic() + 30
        while True:
            sample = self.sample("bonjour-hostnames")
            if all(sample.get(kind + "_bonjour_url") for kind in KINDS):
                break
            require(time.monotonic() < deadline, "Phone Bonjour names did not become available")
            time.sleep(.2)
        rows = []
        for kind in KINDS:
            url = urlparse(sample[kind + "_bonjour_url"])
            require(url.scheme == "http" and url.port == sample[kind + "_port"]
                    and url.hostname and url.hostname.endswith(".local"), "Unexpected advertised phone URL")
            body, _, status = self.request(kind, "GET", self.path(kind, "probe-identity.json"),
                                           headers={"Host": url.netloc})
            value = json.loads(body)
            require(value.get("run_id") == self.phone.args.run_id and value.get("bundle_id") == BUNDLE,
                    "Advertised hostname returned a different identity")
            rows.append({"server": kind, "host": url.netloc, "status": status})
        self.report.setdefault("bonjour_host_checks", []).append(rows)
        self.save()

    def name(self, suffix):
        name = self.prefix + suffix + ".bin"
        self.owned.add(name)  # Register before any request can publish the file.
        return name

    def start_upload(self, kind, name, data):
        connection, remainder = self.begin_upload(kind, name, data)
        try:
            connection.send(remainder[:CHUNK])
            return connection, remainder[CHUNK:]
        except BaseException:
            with closing_reported(connection, self.report, "upload_prefix"):
                raise

    def finish_upload(self, kind, connection, remainder):
        for offset in range(0, len(remainder), CHUNK):
            connection.send(remainder[offset:offset + CHUNK])
        response = connection.getresponse()
        status = response.status
        read_small_response(response)
        self.count(requests=1)
        require(status == (200 if kind == "uploader" else 201), f"{kind} upload returned HTTP {status}")
        self.count(completed_uploads=1)

    def held(self, kind, count, sample):
        temporary = set(inventory(sample, "temp_inventory"))
        return (sample["connections"] >= count and self.temp_baseline <= temporary
                and len(temporary - self.temp_baseline) == count
                and (kind != "uploader" or sample["reserved_bytes"] > 0))

    def wait_held(self, kind, count):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            sample = self.sample(f"{kind}-{count}-held")
            if self.held(kind, count, sample):
                return sample
            time.sleep(.2)
        raise AssertionError(f"Phone never reported {count} held {kind} uploads with matching temporary files")

    def idle(self, baseline):
        deadline, stable, last_stamp = time.monotonic() + TIMEOUT, [], None
        error = "No fresh idle samples"
        while time.monotonic() < deadline:
            sample = self.sample("idle")
            if last_stamp is not None and sample["sample_timestamp"] <= last_stamp:
                time.sleep(.2)
                continue
            last_stamp = sample["sample_timestamp"]
            try:
                require(sample["connections"] == sample["reserved_bytes"] == 0, "Phone connections or reservations remain")
                require(sample["accepted"] == sample["closed"], "Phone connection accounting differs")
                share = inventory(sample, "share_inventory")
                require(set(share) == set(self.expected), f"Phone share inventory differs: {sorted(share)}")
                require(all(share[name]["type"] == "file" and share[name]["size"] == size for name, size in self.expected.items()),
                        "Phone share type or size differs")
                require(set(inventory(sample, "temp_inventory")) == self.temp_baseline, "Temporary files remain or baseline contents changed")
                require(baseline is None or sample["descriptors"] <= baseline["descriptors"], "Phone descriptors grew")
                stable.append(sample)
                if len(stable) == 3:
                    # Keep the conservative peak and its actual inventory/time
                    # together, rather than combining two different snapshots.
                    return dict(max(stable, key=lambda item: item["descriptors"]))
            except AssertionError as failure:
                error, stable = str(failure), []
            time.sleep(.2)
        raise AssertionError(f"Phone did not settle: {error}")

    def delete(self, name, missing_ok=False):
        require(name in self.owned and name.startswith(self.prefix), "Refusing to delete a name not owned by this run")
        self.request("dav", "DELETE", "/" + quote(name), (204, 404) if missing_ok else 204)
        self.expected.pop(name, None)

    def warm(self):
        for kind in KINDS:
            self.sample("warm-" + kind)
            tag = self.fetch(kind, "asset.bin", self.asset)
            self.fetch(kind, "asset.bin", self.asset, tag)
            data = hashlib.shake_256(kind.encode()).digest(MIB)
            name = self.name("warm-" + kind)
            connection, remainder = self.start_upload(kind, name, data)
            with closing_reported(connection, self.report, "warm_upload"):
                self.finish_upload(kind, connection, remainder)
            self.expected[name] = len(data)
            self.sample("warm-uploaded-" + kind)
            self.fetch("dav" if kind == "uploader" else "uploader", name, data)
            self.delete(name)
        self.baseline = self.idle(None)
        self.report["baseline"] = self.baseline

    def concurrent(self, kind):
        self.sample("begin-" + kind)
        row = {"server": kind, "passed": False}
        self.report.setdefault("concurrent_uploads", []).append(row)
        data = [hashlib.shake_256(f"{kind}-{index}".encode()).digest(MIB) for index in range(4)]
        names = [self.name(f"{kind}-{index}") for index in range(4)]
        with ExitStack() as stack:
            uploads = []
            for name, body in zip(names, data):
                connection, remainder = self.start_upload(kind, name, body)
                stack.enter_context(closing_reported(connection, self.report, "concurrent_upload"))
                uploads.append((connection, remainder))
            row["held_before_downloads"] = self.wait_held(kind, 4)
            row["downloads_started"] = time.time()
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(self.download_pair, peer) for peer in KINDS]
                for future in futures:
                    future.result(timeout=TIMEOUT)
            row["downloads_finished"] = time.time()
            row["held_after_downloads"] = self.sample("held-after-downloads-" + kind)
            require(self.held(kind, 4, row["held_after_downloads"]), "Four uploads did not stay open through downloads")
            row["bodies_released"] = time.time()
            with ThreadPoolExecutor(max_workers=4) as pool:
                futures = [pool.submit(self.finish_upload, kind, connection, remainder) for connection, remainder in uploads]
                for future in futures:
                    future.result(timeout=TIMEOUT)
        self.expected.update({name: len(body) for name, body in zip(names, data)})
        self.sample("uploaded-" + kind)
        for name, body in zip(names, data):
            self.fetch("dav" if kind == "uploader" else "uploader", name, body)
        row["idle"] = self.idle(self.baseline)
        row["passed"] = True
        self.save()
        return names, data

    def download_pair(self, kind):
        tag = self.fetch(kind, "asset.bin", self.asset)
        self.fetch(kind, "asset.bin", self.asset, tag)

    def cancel(self, kind):
        self.sample("cancel-begin-" + kind)
        name = self.name("cancel-" + kind)
        connection, _ = self.start_upload(kind, name, b"c" * MIB)
        with closing_reported(connection, self.report, "cancel_upload"):
            held = self.wait_held(kind, 1)
        settled = self.idle(self.baseline)
        self.report.setdefault("cancellations", []).append({"server": kind, "held": held, "idle": settled, "passed": True})

    def listing(self):
        self.sample("propfind")
        body, _, _ = self.request("dav", "PROPFIND", "/", 207, LIST_BODY,
                                   {"Depth": "1", "Content-Type": "application/xml"})
        root, actual = ET.fromstring(body), {}
        require(root.tag == "{DAV:}multistatus", "Expected DAV multistatus")
        for resource in root.findall("{DAV:}response"):
            hrefs = resource.findall("{DAV:}href")
            require(len(hrefs) == 1 and hrefs[0].text not in actual, "Missing or duplicate DAV href")
            properties = {}
            for group in resource.findall("{DAV:}propstat"):
                status = group.findtext("{DAV:}status")
                for prop in group.find("{DAV:}prop"):
                    require(prop.tag not in properties, "Duplicate DAV property")
                    properties[prop.tag] = status, prop.text or ""
            actual[hrefs[0].text] = properties
        expected = {"/" + quote(name): (name, size) for name, size in self.expected.items()}
        require(set(actual) == set(expected) | {"/"}, "DAV listing inventory differs")
        for href, props in actual.items():
            require(set(props) == {"{DAV:}displayname", "{DAV:}getcontentlength"}, "DAV property set differs")
            name, size = expected.get(href, ("", None))
            require(props["{DAV:}displayname"] == ("HTTP/1.1 200 OK", name), "DAV displayname differs")
            want = ("HTTP/1.1 404 Not Found", "") if size is None else ("HTTP/1.1 200 OK", str(size))
            require(props["{DAV:}getcontentlength"] == want, "DAV size or property status differs")
        self.count(verified_listings=1)

    def mutations(self, source, data):
        copied, moved = self.name("copied"), self.name("moved")
        for method, old, new in (("COPY", source, copied), ("MOVE", copied, moved)):
            self.sample(method.lower())
            destination = f"http://{self.phone.endpoint[0]}:{self.phone.endpoint[1][1]}/{quote(new)}"
            self.request("dav", method, "/" + quote(old), 201,
                         headers={"Destination": destination, "Overwrite": "F"})
            self.expected[new] = len(data)
            if method == "MOVE":
                self.expected.pop(old)
            self.fetch("uploader", new, data)
            self.listing()
        self.delete(moved)
        self.listing()
        self.report["dav_copy_move_delete"] = True

    def cleanup(self):
        # Revalidate device and HTTP identity before touching any retained test file.
        actions = self.report.setdefault("cleanup_attempts", [])
        deadline = time.monotonic() + 120
        self.sample("cleanup-start")
        self.identity()
        present = set(inventory(self.phone.latest, "share_inventory")) & self.owned
        for name in sorted(present):
            require(time.monotonic() < deadline, "Owned-file cleanup deadline exceeded")
            self.sample("cleanup-" + name)
            action = {"name": name, "deleted": False}
            actions.append(action)
            try:
                self.delete(name, missing_ok=True)
                action["deleted"] = True
            except Exception as error:
                action["error"] = f"{type(error).__name__}: {error}"
                raise
        # Interrupted requests may have published before their client saw success.
        self.expected = {name: size for name, size in self.expected.items() if name in INITIAL}
        self.report["final"] = self.idle(self.baseline)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Physical iPhone UDID")
    parser.add_argument("--run-id", required=True, help="UUID supplied when launching the smoke app")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    uuid.UUID(args.run_id)
    report_path = args.report.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "device": args.device, "run_id": args.run_id, "bundle_id": BUNDLE,
              "mac_platform": platform.platform(), "scope": "physical iPhone foreground Wi-Fi; normal HTTP/WebDAV traffic; no Windows or background claim",
              "sample_log": str(report_path.with_suffix(".samples.jsonl")),
              "driver_sha256": digest(Path(__file__).read_bytes())}
    started = time.monotonic()
    try:
        with closing_reported(tempfile.TemporaryDirectory(prefix="wsk-device-smoke-"), report, "local_probe_copy", "cleanup") as temporary, \
                closing_reported(report_path.with_suffix(".samples.jsonl").open("w"), report, "samples_log") as samples:
            phone = Phone(args, Path(temporary.name), report, samples)
            driver = Transfers(phone, report, report_path)
            initial = driver.sample("initial")
            require(set(inventory(initial, "share_inventory")) == INITIAL, "Expected a fresh smoke-app share containing only its two fixtures")
            driver.temp_baseline = set(inventory(initial, "temp_inventory"))
            driver.identity()  # These are the first HTTP requests to either port.
            with closing_reported(driver, report, "owned_device_files", "cleanup"):
                driver.warm()
                driver.advertised_identity()
                for kind in KINDS:
                    names, data = driver.concurrent(kind)
                    driver.cancel(kind)
                driver.listing()
                driver.mutations(names[0], data[0])
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
