"""Prove delivery decisions for simulated data-only pushes on a disposable iPhone.

Prepare Flutter's iOS Debug simulator build for scripts/fixtures/quiet_simulator_host.dart
and boot the same UDID. No tokens, APNs credentials or external push service are used.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
from uuid import UUID, uuid4


def checked_id(value):
    if str(UUID(value)) != value.lower():
        raise ValueError("Expected a UUID")
    return value


def payload(ready, case, elapsed_ms):
    issued = ready["anchor"] + elapsed_ms - (70_000 if case == "expired" else 0)
    return {
        "aps": {"content-available": 1}, "version": "task-push-v1",
        "message_id": checked_id(ready["ids"][case]), "kind": "task",
        "scope_nonce": str(uuid4()) if case == "scope" else checked_id(ready["scope"]),
        "scheduled_ms": str(ready["scheduled"]), "issued_ms": str(issued),
        "expires_ms": str(issued + 50000), "timezone": "UTC", "settings_version": "1",
        "quiet_start": "11:58:00" if case == "quiet" else "00:00:00",
        "quiet_end": "12:30:00" if case == "quiet" else "00:00:00",
    }


def verify(ready, sent, callbacks, complete):
    ids = ready["ids"]
    if len(set(ids.values())) != 4 or set(ids) != {"quiet", "scope", "expired", "allowed"}:
        raise ValueError("Expected four distinct task message IDs")
    if ready["state"] != 0:
        raise ValueError("Fixture was not initially active")
    for case in ("quiet", "scope", "expired", "allowed"):
        original, receipt = sent[case], callbacks[case]
        native = {**receipt["payload"], "aps": receipt["aps"]}
        if (original != native or receipt["message"] != ids[case] or receipt["run"] != ready["run"]
                or receipt["state"] != 2 or receipt["result"] != (0 if case == "allowed" else 1)):
            raise ValueError("Wrong payload, lifecycle state or fetch result for " + case)
    if (complete["run"] != ready["run"] or complete["seen"] != [ids["allowed"]]
            or complete["delivered"] != [ids["allowed"]] or not complete["quietSuppressed"]
            or not complete["scopeRejected"] or not complete["expiredRejected"]):
        raise ValueError("Persisted receipt and Notification Center evidence disagree")


def run(device, report):
    device = checked_id(device)
    if not Path("ios/Runner.xcworkspace").is_dir():
        raise ValueError("Run from the Flutter project root")
    report.mkdir(parents=True, exist_ok=False)
    bundle = "com.learningplanet.learningPlanet"
    info = Path("build/ios/iphonesimulator/Runner.app/Info.plist")
    if plistlib.loads(info.read_bytes())["CFBundleIdentifier"] != bundle:
        raise ValueError("Unexpected simulator app")
    simulator = ["xcrun", "simctl"]
    devices = json.loads(subprocess.check_output(simulator + ["list", "devices", "booted", "-j"]))
    matches = [(rt, item) for rt, entries in devices["devices"].items() for item in entries
               if item["udid"].lower() == device.lower() and item["state"] == "Booted"]
    if len(matches) != 1 or not matches[0][1]["name"].startswith("iPhone"):
        raise ValueError("Expected a booted iPhone simulator")
    log = report / "xctest.log"
    started = time.time()
    def write(name, item):
        (report / (name + ".json")).write_text(json.dumps(item, indent=2) + "\n", encoding="utf8")
    with tempfile.TemporaryDirectory(prefix="ac09-xcode-") as derived, log.open("wb") as output:
        proc = subprocess.Popen([
            "xcodebuild", "test", "-workspace", "ios/Runner.xcworkspace", "-scheme", "Runner",
            "-configuration", "Debug", "-destination", "platform=iOS Simulator,id=" + device,
            "-parallel-testing-enabled", "NO",
            "-only-testing:RunnerTests/RunnerTests/testBackgroundQuietReceipt",
            "-derivedDataPath", derived,
            "-resultBundlePath", str(report.absolute() / "native.xcresult"),
            "FLUTTER_TARGET=scripts/fixtures/quiet_simulator_host.dart",
            "OTHER_SWIFT_FLAGS=$(inherited) -D LP_QUIET_SIMULATOR_TEST",
        ], stdout=output, stderr=subprocess.STDOUT)
        def await_result(fn, timeout, description):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                result = fn()
                if result is not None:
                    return result
                if proc.poll() is not None:
                    raise RuntimeError("XCTest ended before " + description + ", see xctest.log")
                time.sleep(.4)
            raise TimeoutError("Timed out waiting for " + description)
        def container():
            found = subprocess.run(simulator + ["get_app_container", device, bundle, "data"],
                                   capture_output=True, text=True, timeout=10)
            if found.returncode == 0:
                return Path(found.stdout.strip()) / "Documents" / "ac09-receipt"
            return None
        def ready_probe():
            directory = container()
            if directory is None:
                return None
            path = directory / "ready.json"
            if path.is_file() and path.stat().st_mtime >= started and path.stat().st_size:
                return directory, json.loads(path.read_text(encoding="utf8"))
            return None
        try:
            directory, ready = await_result(ready_probe, 1200, "native settings/clock/plan")
            write("ready", ready)
            zero = time.monotonic()
            def event(name):
                path = directory / (name + ".json")
                if path.is_file():
                    result = json.loads(path.read_text(encoding="utf8"))
                    if result["run"] == ready["run"]:
                        return result
                return None
            subprocess.run(simulator + ["launch", device, "com.apple.Preferences"], check=True, timeout=35)
            bg = await_result(lambda: event("background"), 20, "didEnterBackground")
            if bg["state"] != 2:
                raise ValueError("Runner did not enter the background")
            write("background", bg)
            # Each push must finish through the real UIApplication selector before
            # the next. An absent notification alone never proves suppression.
            sent, callbacks = {}, {}
            for case in ("quiet", "scope", "expired", "allowed"):
                data = payload(ready, case, round((time.monotonic() - zero) * 1000))
                command = subprocess.run(simulator + ["push", device, bundle, "-"],
                                         input=json.dumps(data), text=True, capture_output=True, timeout=30)
                command.check_returncode()
                sent[case] = data
                write("sent-" + case, data)
                callbacks[case] = await_result(lambda: event(case), 35, "UIKit callback for " + case)
                write("receipt-" + case, callbacks[case])
            (directory / ("resume-" + checked_id(ready["run"]))).touch(exist_ok=False)
            resumed = subprocess.check_output(simulator + ["launch", device, bundle], text=True, timeout=30)
            if resumed.strip().split(":")[-1].strip() != str(ready["pid"]):
                raise RuntimeError("Returning to Runner started another process")
            complete = await_result(lambda: event("complete"), 28, "delivered notification query")
            write("complete", complete)
            verify(ready, sent, callbacks, complete)
            if proc.wait(timeout=80) != 0:
                raise RuntimeError("XCTest failed; see xctest.log")
            write("result", {"passed": True, "runtime": matches[0][0], "device": matches[0][1]["name"],
                 "transport": "local simctl push; no APNs", "receiveState": "background",
                 "observationAfterResume": "Notification Center delivered task IDs",
                 "callbackCases": ["quiet", "scope", "expired", "allowed"], "run": ready["run"],
                 "xctestLogSha256": hashlib.sha256(log.read_bytes()).hexdigest()})
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    run(args.device, args.report)
