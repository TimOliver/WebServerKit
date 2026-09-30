#!/usr/bin/env python3
"""Bounded serial DAV listing/idle cycles on an owned loopback process."""
import argparse
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
import traceback

from audit import SharedAudit, operation_summary
from run import (MIB, PACKAGE, REPOSITORY, TIMEOUT, Host, check_resources,
                 closing_reported, digest, require)


def bounded(low, high):
    def parse(value):
        number = int(value)
        if not low <= number <= high:
            raise argparse.ArgumentTypeError(f"must be between {low} and {high}")
        return number
    return parse


def cpu_delta(before, after):
    result = {}
    for key in ("cpu_user_seconds", "cpu_system_seconds"):
        difference = after[key] - before[key]
        require(difference >= 0, "Host CPU counter went backwards")
        result[key] = difference
    result["cpu_total_seconds"] = sum(result.values())
    return result


class ListingProfile:
    def __init__(self, runner, report, stream):
        self.runner, self.report, self.stream = runner, report, stream
        self.started = time.monotonic()

    def snapshot(self, label):
        value = self.runner.host.command("profile-stats")["resources"]
        for key in ("cpu_user_seconds", "cpu_system_seconds", "allocator_live_bytes",
                    "allocator_live_blocks", "allocator_reserved_bytes"):
            require(isinstance(value[key], (int, float)) and value[key] >= 0,
                    f"Invalid profile counter: {key}")
        self.report["last_resources"] = value
        self.stream.write(json.dumps({"label": label, "elapsed": time.monotonic() - self.started, **value}) + "\n")
        self.stream.flush()
        return value

    def idle(self, label, seconds):
        # Inventory and stable ownership checks remain identical to the audit.
        self.snapshot(label + "-before-settle")
        self.runner.quiescent(self.runner.baseline)
        end, observations = time.monotonic() + seconds, []
        while True:
            value = self.snapshot(label)
            check_resources(value, self.runner.baseline, 64 * MIB)
            observations.append(value)
            remaining = end - time.monotonic()
            if remaining <= 0:
                return observations
            time.sleep(min(.25, remaining))

    def batch(self, label, count, idle_seconds):
        runner = self.runner
        runner.metrics = {}
        row = {"name": label, "requested_listings": count, "completed_listings": 0,
               "load_average_start": os.getloadavg(), "before": self.snapshot(label + "-before")}
        self.report["cycles"].append(row)  # Keep incomplete work visible on failure.
        started = time.monotonic()
        row["requests_start_elapsed"] = started - self.started
        try:
            for _ in range(count):
                runner.listing("dav")
                row["completed_listings"] += 1
        finally:
            finished = time.monotonic()
            row["requests_end_elapsed"] = finished - self.started
            row["elapsed_seconds"] = finished - started
            row["operations"] = operation_summary(runner.metrics)
        row["after"] = self.snapshot(label + "-after")
        row.update(cpu_delta(row["before"], row["after"]))
        row["cpu_seconds_per_listing"] = row["cpu_total_seconds"] / count
        row["idle"] = self.idle(label + "-idle", idle_seconds)
        last = row["idle"][-1]
        print(f"{label}: {count} listings, {row['cpu_seconds_per_listing']:.3f} CPU s/listing, "
              f"idle live/reserved/footprint {last['allocator_live_bytes']/MIB:.1f}/"
              f"{last['allocator_reserved_bytes']/MIB:.1f}/{last['footprint_bytes']/MIB:.1f} MiB", flush=True)
        return row


class OwnedSampler:
    def __init__(self, host, path, interval, clock_origin):
        self.host, self.path = host, path
        self.interval, self.clock_origin = interval, clock_origin
        self.process = None
        self.output = None

    def start(self):
        require(self.host.process.poll() is None, "Cannot sample an exited host")
        self.output = self.path.with_suffix(".tool.log").open("wb")
        # Only this run's child PID, never a process-name match or caller target.
        self.interval["launch_elapsed"] = time.monotonic() - self.clock_origin
        self.process = subprocess.Popen(["/usr/bin/sample", str(self.host.process.pid), "5", "10",
                                         "-file", str(self.path)], stdout=self.output, stderr=subprocess.STDOUT)

    def finish(self):
        result = self.process.wait(timeout=30)
        self.interval["completion_observed_elapsed"] = time.monotonic() - self.clock_origin
        self.interval["exit_code"] = result
        require(result == 0, "Host stack sampling failed")
        require(self.path.is_file() and self.path.stat().st_size > 0, "Missing host stack sample")

    def close(self):
        try:
            if self.process is not None and self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
        finally:
            if self.output is not None:
                self.output.close()


def inspect_leaks(host, path, report):
    # Identify the artifact before invoking the tool, including on timeout.
    diagnostic = {"path": str(path), "completed": False}
    report["leaks"] = diagnostic
    with closing_reported(path.open("wb"), report, "leaks_log") as output:
        result = subprocess.run(["/usr/bin/leaks", "-quiet", "-noContent", str(host.process.pid)],
                                stdout=output, stderr=subprocess.STDOUT, timeout=45)
        diagnostic.update(completed=True, exit_code=result.returncode)
        require(result.returncode == 0, "Leak inspection reported leaks or could not complete; see diagnostic log")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entries", type=bounded(1, 5000), default=5000)
    parser.add_argument("--cycles", type=bounded(1, 12), default=8)
    parser.add_argument("--listings", type=bounded(1, 10), default=5, help="validated requests per cycle, including warmup")
    parser.add_argument("--idle-seconds", type=bounded(1, 10), default=2)
    parser.add_argument("--final-idle-seconds", type=bounded(5, 30), default=10)
    parser.add_argument("--diagnostic", action="store_true", help="separate stack-logging, sample and leaks run; timings are instrumented")
    parser.add_argument("--report", type=Path, default=REPOSITORY / "build" / "listing-profile.json")
    args = parser.parse_args()
    args.upload_mib, args.asset_mib, args.max_footprint_growth_mib = 1, 1, 64
    report_path = args.report.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "cycles": [], "configuration": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
              "platform": platform.platform(), "mode": "instrumented-diagnostic" if args.diagnostic else "timing",
              "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True, cwd=REPOSITORY).strip(),
              "harness_sha256": {name: digest((PACKAGE / name).read_bytes()) for name in
                                  ("profile_listings.py", "audit.py", "run.py", "Sources/EnduranceHost/main.m")},
              "allocator_scope": "all malloc zones: live blocks and reserved capacity, not cumulative allocations",
              "allocator_environment": {key: value for key, value in os.environ.items() if key == "MallocNanoZone"},
              "scope": "serial immutable named-property Depth:1 listings; no claim about mixed-client throughput or unreachable vs reachable retention"}
    started = time.monotonic()
    try:
        # An inherited stack logger would invalidate the timing/diagnostic separation.
        require(not any(key.startswith("Malloc") and key != "MallocNanoZone" for key in os.environ),
                "Run from a shell without Malloc instrumentation variables")
        subprocess.run(["swift", "build", "--package-path", str(PACKAGE), "-c", "release"], check=True)
        binary = Path(subprocess.check_output(["swift", "build", "--package-path", str(PACKAGE), "-c", "release", "--show-bin-path"], text=True).strip())
        library = binary / "EnduranceTemporaryDirectory.dylib"
        subprocess.run(["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-framework", "Foundation", str(PACKAGE / "TemporaryDirectory.m"), "-o", str(library)], check=True)
        with closing_reported(tempfile.TemporaryDirectory(prefix="wsk-listing-profile-"), report, "temporary_directory", "cleanup") as temporary, \
                closing_reported(report_path.with_suffix(".host.log").open("wb"), report, "host_log") as log, \
                closing_reported(report_path.with_suffix(".samples.jsonl").open("w"), report, "samples_log") as samples:
            host = Host(binary / "EnduranceHost", library, Path(temporary.name), log,
                        shared_directory=True, report=report, allocation_stacks=args.diagnostic)
            with closing_reported(host, report, "host"):
                report["host_pid"] = host.process.pid
                runner = SharedAudit(host, args, report, io.StringIO())
                profile = ListingProfile(runner, report, samples)
                runner.populate(args.entries)
                report["initial_idle"] = profile.idle("initial", args.idle_seconds)
                profile.batch("warmup", args.listings, args.idle_seconds)
                runner.baseline = profile.snapshot("fixed-baseline")
                report["baseline"] = runner.baseline
                for cycle in range(args.cycles):
                    if args.diagnostic and cycle == 0:
                        sample_path = report_path.with_suffix(".stacks.txt")
                        interval = {"duration_seconds": 5, "interval_milliseconds": 10,
                                    "scope": "tool launch to observed completion; may include idle and delayed observation"}
                        report["stack_sample"] = {"path": str(sample_path), "interval": interval}
                        with closing_reported(OwnedSampler(host, sample_path, interval, profile.started), report, "stack_sampler") as sampler:
                            sampler.start()
                            profile.batch(str(cycle), args.listings, args.idle_seconds)
                            sampler.finish()
                    else:
                        profile.batch(str(cycle), args.listings, args.idle_seconds)
                    report_path.write_text(json.dumps(report, indent=2) + "\n")
                report["final_idle"] = profile.idle("final", args.final_idle_seconds)
                if args.diagnostic:
                    inspect_leaks(host, report_path.with_suffix(".leaks.txt"), report)
                # This is an explicitly labelled endpoint control, never a rebase
                # or a way to hide growth during the measured cycles.
                report["before_relief"] = profile.snapshot("before-relief")
                report["allocator_relief"] = host.command("relieve-allocator")
                report["after_relief_idle"] = profile.idle("after-relief", args.idle_seconds)
                report["final"] = runner.quiescent(runner.baseline)
                require(not host.command("shutdown")["running"], "Host did not stop")
                require(host.process.wait(timeout=TIMEOUT) == 0, "Host shutdown failed")
        report["passed"] = True
    except (Exception, KeyboardInterrupt) as error:
        report["passed"] = False
        report["error"] = f"{type(error).__name__}: {error}"
        traceback.print_exc()
    finally:
        report["elapsed_seconds"] = time.monotonic() - started
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{'PASS' if report['passed'] else 'FAIL'}: {report_path}", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
