"""Exercise either native receipt handling or simulated system delivery on a disposable iPhone.

Prepare Flutter's iOS Debug simulator build for scripts/fixtures/quiet_simulator_host.dart
and boot the same UDID. The system scenario requests registration without recording device tokens.
Both scenarios generate their messages locally.
"""
import argparse
from collections import deque
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import tempfile
import threading
import time
from uuid import UUID, uuid4
from xml.parsers.expat import ExpatError


CASES = ("quiet", "scope", "expired", "allowed")
BUNDLE = "com.learningplanet.learningPlanet"


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
    for case in CASES:
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


def command_output(*args):
    return subprocess.check_output(args, stderr=subprocess.DEVNULL, timeout=8)


def push_entitlement(data):
    if not data:
        return {"status": "noPlist"}
    try:
        values = plistlib.loads(data if data.startswith(b"bplist") else data.rstrip(b"\0"))
    except (ValueError, plistlib.InvalidFileException, OverflowError, ExpatError):
        return {"status": "invalidPlist"}
    if not isinstance(values, dict):
        return {"status": "invalidPlist"}
    value = values.get("aps-environment")
    environment = value if value in ("development", "production") else "unexpected"
    return {"status": "read", "aps-environment": environment if "aps-environment" in values else "absent",
            "plistSha256": hashlib.sha256(data).hexdigest()}


def embedded_entitlement(binary):
    layout = command_output("xcrun", "otool", "-l", str(binary)).decode()
    for section in re.split(r"(?m)^Section\s*$", layout)[1:]:
        if (not re.search(r"(?m)^\s*sectname __entitlements\s*$", section)
                or not re.search(r"(?m)^\s*segname __TEXT\s*$", section.split("Load command", 1)[0])):
            continue
        size = re.search(r"(?m)^\s*size (0x[0-9a-fA-F]+)\s*$", section)
        offset = re.search(r"(?m)^\s*offset (\d+)\s*$", section)
        if not size or not offset or not 0 < int(size[1], 16) <= 65536:
            return {"status": "invalidSection"}
        with binary.open("rb") as stream:
            stream.seek(int(offset[1]))
            data = stream.read(int(size[1], 16))
        if len(data) != int(size[1], 16):
            return {"status": "invalidSection"}
        return push_entitlement(data)
    return {"status": "sectionAbsent"}


def installed_entitlements(device):
    app = Path(command_output("xcrun", "simctl", "get_app_container", device, BUNDLE, "app").decode().strip())
    info = plistlib.loads((app / "Info.plist").read_bytes())
    executable = info["CFBundleExecutable"]
    if (app.suffix != ".app" or info["CFBundleIdentifier"] != BUNDLE
            or Path(executable).name != executable or not (app / executable).is_file()):
        raise ValueError("Unexpected installed test host")
    binary = app / executable
    result = {"bundle": BUNDLE, "remoteNotificationMode": "remote-notification" in info.get("UIBackgroundModes", []),
              "codeSignature": {"status": "unavailable"}, "machOTextSections": {}}
    try:
        result["codeSignature"] = push_entitlement(command_output("codesign", "-d", "--entitlements", "-", "--xml", str(app)))
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        archs = command_output("xcrun", "lipo", "-archs", str(binary)).decode().split()
        if not archs or len(archs) > 2 or not set(archs) <= {"x86_64", "arm64"}:
            raise ValueError("Unexpected simulator architectures")
        with tempfile.TemporaryDirectory() as temp:
            for arch in archs:
                item = binary
                if len(archs) > 1:
                    item = Path(temp) / arch
                    command_output("xcrun", "lipo", str(binary), "-thin", arch, "-output", str(item))
                result["machOTextSections"][arch] = embedded_entitlement(item)
    except (OSError, ValueError, subprocess.SubprocessError):
        result["machOInspectionIncomplete"] = True
    return result


LOG_PROCESSES = ("apsd", "dasd", "SpringBoard", "runningboardd", "usernotificationsd", "SpringBoardServices",
                 "bulletindistributord", "usernotificationslistener")
# Store only fixed diagnostic vocabulary. System messages can include APNs tokens and unrelated content.
LOG_TERMS = re.compile(r"\b(pushlaunch|push|remote[ -]?notification|notification|background|fetch|scheduled?|"
                       r"receiv(?:ed|ing)|deliver(?:y|ed|ing)?|dispatch(?:ed)?|launch(?:ed)?|waking|wake|"
                       r"drop(?:ped)?|deny|denied|reject(?:ed)?|defer(?:red)?|throttl(?:ed|ing)|budget|"
                       r"eligib(?:le|ility)|ineligible|allow(?:ed)?|disabled|enabled|entitlement|priority|"
                       r"suspend(?:ed)?|expired|registration|assertion|failed|error|no|not)\b", re.IGNORECASE)


def log_records(raw, start, end):
    first = []
    last = deque(maxlen=40)
    count = 0
    for line in raw.splitlines():
        try:
            row = json.loads(line)
        except (ValueError, UnicodeError):
            continue
        if not isinstance(row, dict):
            continue
        process = str(row.get("processImagePath") or row.get("process", "")).rsplit("/", 1)[-1]
        message = row.get("eventMessage")
        if process not in LOG_PROCESSES or not isinstance(message, str) or BUNDLE.lower() not in message.lower():
            continue
        # log show accepts whole seconds. Exclude records before the actual
        # submission, even when the app became ready in the very same second.
        try:
            stamp = datetime.fromisoformat(row["timestamp"])
            if stamp.tzinfo is None or not start <= stamp.timestamp() <= end:
                continue
        except (KeyError, TypeError, ValueError, OverflowError, OSError):
            continue
        count += 1
        terms = [m[0].lower().replace(" ", "") for m in LOG_TERMS.finditer(message)][:18]
        record = {"timestamp": stamp.astimezone(timezone.utc).isoformat(), "process": process, "terms": terms}
        if len(first) < 40:
            first.append(record)
        else:
            last.append(record)
    return {"matchedRecordsRead": count, "recordLimit": 80, "records": first + list(last)}


def simulator_log(device, observed_since, phase):
    limit = 512 * 1024
    end = time.time()
    start = min(end, max(end - 240, observed_since))
    start_utc = datetime.fromtimestamp(start, timezone.utc)
    end_utc = datetime.fromtimestamp(math.ceil(end), timezone.utc)
    # SpringBoard and RunningBoard also log routine view and scene changes for the same bundle.
    relevant = ' OR '.join(f'eventMessage CONTAINS[c] "{term}"' for term in
                           ("push", "notification", "background", "fetch", "wake", "deliver", "denied", "throttl"))
    predicate = ('process IN {' + ', '.join(f'"{name}"' for name in LOG_PROCESSES)
                 + f'}} AND eventMessage CONTAINS[c] "{BUNDLE}"'
                 + ' AND (process IN {"apsd", "dasd", "usernotificationsd"} OR ' + relevant + ')')
    cmd = ["xcrun", "simctl", "spawn", device, "log", "show",
           "--start", start_utc.strftime("%Y-%m-%d %H:%M:%S%z"), "--end", end_utc.strftime("%Y-%m-%d %H:%M:%S%z"), "--style", "ndjson",
           "--info", "--debug", "--predicate", predicate]
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=(os.name == "posix")) as proc:
        def stop():
            try:
                if os.name == "posix":
                    os.killpg(proc.pid, signal.SIGKILL)
                else:
                    proc.kill()
            except ProcessLookupError:
                pass
        with_timeout = threading.Event()
        def expire():
            with_timeout.set()
            stop()
        timer = threading.Timer(15, expire)
        timer.start()
        try:
            raw = proc.stdout.read(limit + 1)
            if len(raw) > limit:
                stop()
            code = proc.wait(timeout=5)
        finally:
            timer.cancel()
            timer.join()
    return {"device": device, "phase": phase, "startUtc": start_utc.isoformat(),
            "windowSeconds": math.ceil(end - start), "byteLimit": limit, "byteLimitReached": len(raw) > limit,
            "timedOut": with_timeout.is_set(), "exitCode": code, **log_records(raw[:limit], start, end)}


def stage_observations(directory, ready, source, sent):
    if directory is None or ready is None or ready.get("source") != source:
        return {"status": "noMatchingReady"}
    run_id = checked_id(ready["run"])
    events = {}
    names = ["registration", "host-remote", "host-fetch", "app-unmatched"]
    for case in CASES:
        names += ["app-" + case, "entered-" + case, "claimed-" + case, case]
    for name in names:
        path = directory / (name + ".json")
        if not path.is_file() or path.stat().st_size > 16384:
            continue
        try:
            row = json.loads(path.read_bytes())
        except (ValueError, OSError):
            continue
        if not isinstance(row, dict) or row.get("run") != run_id or row.get("source") != source:
            continue
        if name == "registration":
            if row.get("callback") in ("registered", "failed") and type(row.get("registered")) is bool:
                events[name] = {"callback": row["callback"], "registered": row["registered"]}
            continue
        state = row.get("state")
        valid_states = (-1, 0, 1, 2) if name in ("host-remote", "host-fetch") else (0, 1, 2)
        if type(state) is not int or state not in valid_states:
            continue
        if name in ("host-remote", "host-fetch", "app-unmatched"):
            if type(row.get("count")) is int and row["count"] > 0:
                events[name] = {"state": state, "count": row["count"]}
            continue
        case = name.split("-")[-1]
        if case not in sent or row.get("message") != ready["ids"][case]:
            continue
        if name.startswith("claimed-") and row.get("handled") is not True:
            continue
        if name == case and (type(row.get("result")) is not int or row["result"] not in (0, 1, 2)):
            continue
        events[name] = {"message": ready["ids"][case], "state": state}
        if name == case:
            events[name]["result"] = row["result"]
    stages = {}
    for case in sent:
        stages[case] = [stage for name, stage in (("app-" + case, "appPayload"), ("entered-" + case, "pluginEntry"),
                        ("claimed-" + case, "pluginClaim"), (case, "pluginCompletion")) if name in events]
    return {"status": "inspected", "source": source, "run": run_id, "events": events, "observedStagesBySentCase": stages}


def run(device, report, source):
    device = checked_id(device)
    if not Path("ios/Runner.xcworkspace").is_dir():
        raise ValueError("Run from the Flutter project root")
    report.mkdir(parents=True, exist_ok=False)
    bundle = BUNDLE
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
        directory, ready = None, None
        sent = {}
        observed_since = time.time()
        log_phase = "setup"
        try:
            directory, ready = wait_for_ready(proc, device, bundle, started)
            write("ready", ready)
            if ready["source"] != source:
                raise ValueError("XCTest started a different receipt scenario")
            zero = time.monotonic()
            observed_since = time.time()
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
            callbacks, entries, claims, invocations = {}, {}, {}, {}
            for case in CASES:
                data = payload(ready, case, round((time.monotonic() - zero) * 1000))
                if not sent:
                    observed_since = time.time()
                    log_phase = "firstDeliveryAttempt"
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
            if source == "system":
                invocations = {case: row for case in CASES if (row := event("invoked-" + case)) is not None}
            verify(ready, sent, callbacks, complete, source=source, entries=entries, claims=claims, invocations=invocations)
            if proc.wait(timeout=80) != 0:
                raise RuntimeError("XCTest failed; see xctest.log")
            write("result", {"passed": True, "runtime": matches[0][0], "device": matches[0][1]["name"],
                 "source": source, "transport": transport, "coverage": coverage, "externalAPNs": False, "receiveState": "background",
                 "observationAfterResume": "Notification Center delivered task IDs",
                 "callbackCases": list(CASES), "run": ready["run"],
                 "xctestLogSha256": hashlib.sha256(log.read_bytes()).hexdigest()})
        finally:
            # Keep diagnostics out of the measured callback window and independent of its verdict.
            for name, collect in (
                    ("app-observations", lambda: stage_observations(directory, ready, source, sent)),
                    ("installed-entitlements", lambda: installed_entitlements(device)),
                    ("simulator-push-log", lambda: simulator_log(device, observed_since, log_phase))):
                try:
                    item = collect()
                except Exception as error:
                    item = {"status": "unavailable", "errorType": type(error).__name__}
                write(name, item)
                if name == "app-observations" and "registration" in item.get("events", {}):
                    write("registration", {"source": source, "run": item["run"], **item["events"]["registration"]})
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
