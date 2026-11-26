"""Exercise either native receipt handling or simulated system delivery on a disposable iPhone.

Prepare Flutter's iOS Debug simulator build for scripts/fixtures/quiet_simulator_host.dart
and boot the same UDID. The system scenario requests registration without recording device tokens.
Both scenarios generate their messages locally.
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


def verify(ready, sent, callbacks, complete, *, source, entries, claims, invocations):
    ids = ready["ids"]
    if (source not in ("native", "system") or ready["source"] != source or complete["source"] != source
            or ready["registrationRequested"] != (source == "system")):
        raise ValueError("Wrong receipt source or registration setup")
    if len(set(ids.values())) != 4 or set(ids) != {"quiet", "scope", "expired", "allowed"}:
        raise ValueError("Expected four distinct task message IDs")
    if ready["state"] != 0:
        raise ValueError("Fixture was not initially active")
    for case in ("quiet", "scope", "expired", "allowed"):
        original, receipt = sent[case], callbacks[case]
        expected_entry = {"message": ids[case], "run": ready["run"], "source": source, "state": 2}
        if entries[case] != expected_entry or receipt["source"] != source:
            raise ValueError("Wrong native callback entry for " + case)
        if claims[case] != {**expected_entry, "handled": True}:
            raise ValueError("The task delegate did not claim " + case)
        native = {**receipt["payload"], "aps": receipt["aps"]}
        if (original != native or receipt["message"] != ids[case] or receipt["run"] != ready["run"]
                or receipt["state"] != 2 or receipt["result"] != (0 if case == "allowed" else 1)):
            raise ValueError("Wrong payload, lifecycle state or fetch result for " + case)
        if source == "native" and invocations.get(case) != {**expected_entry, "result": receipt["result"]}:
            raise ValueError("Original UIApplicationDelegate completion was not observed for " + case)
    if source == "system" and invocations:
        raise ValueError("Test-invoked delegate evidence cannot represent a system push")
    if (complete["run"] != ready["run"] or complete["seen"] != [ids["allowed"]]
            or complete["delivered"] != [ids["allowed"]] or not complete["quietSuppressed"]
            or not complete["scopeRejected"] or not complete["expiredRejected"]):
        raise ValueError("Persisted receipt and Notification Center evidence disagree")


def wait_for_ready(process, device, bundle, started, timeout=1200):
    deadline = time.monotonic() + timeout
    command = ["xcrun", "simctl", "get_app_container", device, bundle, "data"]
    while (remaining := deadline - time.monotonic()) > 0:
        status = process.poll()
        if status is not None:
            raise RuntimeError(f"XCTest exited with {status} before native settings/clock/plan; see xctest.log")
        # The container may be absent, or CoreSimulator busy, while Xcode installs the test host.
        try:
            found = subprocess.run(command, capture_output=True, text=True, timeout=min(10, remaining))
        except subprocess.TimeoutExpired:
            found = None
        if found is not None and found.returncode == 0 and found.stdout.strip():
            directory = Path(found.stdout.strip()) / "Documents" / "ac09-receipt"
            path = directory / "ready.json"
            if path.is_file() and path.stat().st_mtime >= started and path.stat().st_size:
                return directory, json.loads(path.read_text(encoding="utf8"))
        time.sleep(max(0, min(2, deadline - time.monotonic())))
    raise TimeoutError("Timed out waiting for native settings/clock/plan; see xctest.log")


def run(device, report, source):
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
    transport = "XCTest calls UIApplicationDelegate" if source == "native" else "local simctl push"
    coverage = "native receipt policy and Notification Center" if source == "native" else "simulated system delivery to background app"
    write("scenario", {"source": source, "transport": transport, "coverage": coverage, "externalAPNs": False})
    method = "testNativeDelegateReceipt" if source == "native" else "testBackgroundQuietReceipt"
    with tempfile.TemporaryDirectory(prefix="ac09-xcode-") as derived, log.open("wb") as output:
        proc = subprocess.Popen([
            "xcodebuild", "test", "-workspace", "ios/Runner.xcworkspace", "-scheme", "Runner",
            "-configuration", "Debug", "-destination", "platform=iOS Simulator,id=" + device,
            "-parallel-testing-enabled", "NO",
            "-only-testing:RunnerTests/RunnerTests/" + method,
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
        try:
            directory, ready = wait_for_ready(proc, device, bundle, started)
            write("ready", ready)
            if ready["source"] != source:
                raise ValueError("XCTest started a different receipt scenario")
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
            # Wait for the actual delegate completion before submitting the next case.
            sent, callbacks, entries, claims, invocations = {}, {}, {}, {}, {}
            for case in ("quiet", "scope", "expired", "allowed"):
                data = payload(ready, case, round((time.monotonic() - zero) * 1000))
                if source == "system":
                    command = subprocess.run(simulator + ["push", device, bundle, "-"],
                                             input=json.dumps(data), text=True, capture_output=True, timeout=30)
                    command.check_returncode()
                else:
                    path = directory / ("invoke-" + checked_id(ready["run"]) + "-" + case + ".json")
                    temporary = path.with_suffix(".tmp")
                    temporary.write_text(json.dumps(data), encoding="utf8")
                    temporary.replace(path)
                sent[case] = data
                write("sent-" + case, data)
                try:
                    callbacks[case] = await_result(lambda: event(case), 35, "UIKit callback for " + case)
                finally:
                    entry = event("entered-" + case)
                    if entry is not None:
                        entries[case] = entry
                        write("entered-" + case, entry)
                    claim = event("claimed-" + case)
                    if claim is not None:
                        claims[case] = claim
                        write("claimed-" + case, claim)
                    registration = event("registration")
                    if registration is not None:
                        write("registration", registration)
                write("receipt-" + case, callbacks[case])
                if source == "native":
                    invocations[case] = await_result(lambda: event("invoked-" + case), 10, "test delegate completion for " + case)
                    write("invoked-" + case, invocations[case])
            (directory / ("resume-" + checked_id(ready["run"]))).touch(exist_ok=False)
            resumed = subprocess.check_output(simulator + ["launch", device, bundle], text=True, timeout=30)
            if resumed.strip().split(":")[-1].strip() != str(ready["pid"]):
                raise RuntimeError("Returning to Runner started another process")
            complete = await_result(lambda: event("complete"), 28, "delivered notification query")
            write("complete", complete)
            verify(ready, sent, callbacks, complete, source=source, entries=entries, claims=claims, invocations=invocations)
            if proc.wait(timeout=80) != 0:
                raise RuntimeError("XCTest failed; see xctest.log")
            write("result", {"passed": True, "runtime": matches[0][0], "device": matches[0][1]["name"],
                 "source": source, "transport": transport, "coverage": coverage, "externalAPNs": False, "receiveState": "background",
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
    parser.add_argument("--source", choices=("system", "native"), default="system")
    args = parser.parse_args()
    run(args.device, args.report, args.source)
