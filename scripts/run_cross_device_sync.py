"""Run the prebuilt AC-01 clients on one Intel Mac and one loopback backend."""
import contextlib
import errno
import io
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from shutdown_ios_simulator import shutdown as shutdown_iphone


PORT = 5568
SERIAL = f"emulator-{PORT}"
DRIVER = "test_driver/cross_device_sync_driver.dart"
RESULTS = Path("build/integration_results")
SERVER_RESULT = Path("build/cross-device/server.json")
APK = Path("build/cross-device/android-fixture.apk")
PHASES = ("initial", "reader-ready", "writer-complete", "reader-reconnect", "reader-confirmed")
UI_STAGES = {*PHASES, "/scenario", "/otp", "email sign-in screen", "enabled OTP form", "home after OTP verification",
             "home with the fixture child", "child menu", "selected child", "initial wallet", "ready task", "offline cached ready task",
             "offline cached wallet", "enabled start action", "in-progress task", "enabled completion action",
             "completed task", "confirmed wallet", "home from the offline iPhone session",
             "child nickname", "child wallet", "child ready task", "child notebook",
             "child question", "offline notebook", "home after notebook"}
LOGIN_STAGES = {"email_login", "login_form_visible", "otp_send_tapped", "otp_received", "otp_form_ready", "otp_verify_tapped"}
REPORT_STAGES = {"fixture", *LOGIN_STAGES, "online_child_views", "offline_child_views", "restore_offline_session", "load_family_task_and_wallet",
                 "cached_before_shutdown", "reconnect", "complete_task", "confirm_task_and_wallet", "confirmed"}
ANDROID_DRIVER_STAGES = {"APK metadata", "installation", "activity launch"}
ANDROID_APP_STAGES = {"fixture", *LOGIN_STAGES, "load_family_task_and_wallet", "complete_task",
                      "confirm_task_and_wallet", "confirmed", "failed"}
# Android 10 logcat and the host both use this expression. Its captures allow
# only the startup marks emitted by MainActivity and the debug Dart entry point.
STARTUP_MARK = (r"^(LP_STARTUP )?source=(android|dart) stage=(activity_create|activity_first_frame|plugins|channels|"
                r"binding|notifications|timezone|notificationPlugin|taskAlarmClear|notificationClear|database|"
                r"credentials|supabase|push|initialization|first_frame) elapsed_us=[0-9]{1,18} outcome=(ok|error)$")
FAILURE_MARK = (r"^AC01_UI_FAILURE kind=(assertion|state|type|framework|other) line=([1-9][0-9]{0,3}|unknown)"
                r"(?: wait=(start_button|in_progress|complete_button))?$")
PROGRESS_MARK = r"^AC01_PROGRESS_UNACKNOWLEDGED reason=(timeout|transport)$"
ANDROID_LOG_FILTER = "|".join((STARTUP_MARK, FAILURE_MARK, PROGRESS_MARK))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def control_data(device):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:54324/phase?device={device}", timeout=2) as response:
            data = json.load(response)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def control_status(device):
    data = control_data(device)
    phase, stage = data.get("phase"), data.get("androidStage")
    return phase if phase in PHASES else None, stage if isinstance(stage, str) and stage in ANDROID_APP_STAGES else None


def wakefulness(output):
    match = re.search(r"^\s*mWakefulness=(Awake|Asleep|Dreaming|Dozing)\s*$", output, re.MULTILINE)
    return match.group(1) if match else "unknown"


def renderer_summary(path):
    with path.open("rb") as stream:
        log = stream.read(512 * 1024).decode("utf8", "replace")
    version = re.search(r"Android emulator version (\d{1,3}(?:\.\d{1,3}){1,3})\b", log)
    gles = re.search(r"\bgles_mode_selected:(swiftshader|swangle|angle|mesa|host|guest|none)\b", log)
    vulkan = re.search(r"\bvulkan_mode_selected:(lavapipe|swiftshader|host|none)\b", log)
    fields = (match[1] if match else "unknown" for match in (version, gles, vulkan))
    return "Android emulator={} GLES={} Vulkan={}".format(*fields)


def startup_summary(path):
    with path.open("rb") as stream:
        lines = stream.read(64 * 1024).decode("utf8", "replace").splitlines()
    marks = []
    failure = ""
    unacknowledged = set()
    for line in lines:
        match = re.fullmatch(STARTUP_MARK, line)
        if match:
            mark = f"{match[2]}.{match[3]}={match[4]}"
            if mark not in marks:
                marks.append(mark)
        elif not failure and (match := re.fullmatch(FAILURE_MARK, line)):
            failure = f" failure_kind={match[1]} fixture_line={match[2]}"
            if match[3]:
                failure += f" wait={match[3]}"
        elif match := re.fullmatch(PROGRESS_MARK, line):
            unacknowledged.add(match[1])
    progress = " progress_unacknowledged=" + ",".join(sorted(unacknowledged)) if unacknowledged else ""
    return (",".join(marks) or "none") + failure + progress


def android_failure(message, adb_device):
    # These fixed fields suffice to distinguish a dark screen, a missing tap,
    # an Auth error and a failed UI transition. Never include device or HTTP payloads.
    power = "unknown"
    try:
        code, output = one_probe(adb_device + ["shell", "dumpsys", "power"], 15)
        adb_status = "responded" if code == 0 else "command_failed"
        if code == 0:
            power = wakefulness(output)
    except subprocess.TimeoutExpired:
        adb_status = "timed_out"
    except OSError:
        adb_status = "unavailable"
    data = control_data("android")
    stage = data.get("androidCheckpoint")
    stage = stage if isinstance(stage, str) and stage in ANDROID_APP_STAGES else "unknown"
    counts = data.get("androidHttp")
    details = []
    for key in ("otp", "otpOk", "verify", "verifyOk", "snapshot", "snapshotOk"):
        value = counts.get(key) if isinstance(counts, dict) else None
        details.append(f"{key}={value if type(value) is int and 0 <= value <= 1000000 else 'unknown'}")
    return RuntimeError(f"{message}; checkpoint={stage} adb={adb_status} power={power} HTTP {' '.join(details)}")


def control_phase():
    return control_status("ios")[0]


def verify_child_views(initial, server):
    primary, sibling = server["childProfiles"]
    require(primary["child_id"] == server["childId"] and primary["task_id"] == server["taskId"],
            "Primary child does not match the shared task")
    marker_keys = ("child_id", "nickname", "task_id", "title", "question", "coin_balance", "xp")
    require(set(primary) == set(sibling) == set(marker_keys) and
            all(primary[key] != sibling[key] for key in marker_keys), "Child markers are not distinct")
    expected = [dict(profile, task_action="start") for profile in (primary, sibling, primary)]
    for stage in ("online_child_views", "offline_child_views"):
        require(initial.get(stage) == expected, f"Incomplete iPhone child switch in {stage}")
    before = server["siblingInitial"]
    require(before == server["siblingFinal"] and all(before[key] == sibling[key] for key in marker_keys),
            "Sibling data changed during the paired run")
    require(before["status"] in ("ready", "scheduled") and before["frozen_balance"] == 0
            and before["command_count"] == 0, "Sibling task or wallet changed")
    require(len({r["id"] for r in before["ledger"]}) == 2 and
            [(r["asset_type"], r["amount"], r["source_type"]) for r in before["ledger"]] ==
            [("coin", sibling["coin_balance"], "parent_adjustment"), ("xp", sibling["xp"], "parent_adjustment")],
            "Sibling reward ledger mismatch")


def verify_evidence(initial, ios, android, server):
    require(server["passed"] is True and server["separateLogins"] is True and server["readerSessionRetained"] is True,
            "Server proof incomplete")
    require(server["initial"]["status"] in ("ready", "scheduled"), "Invalid initial task")
    require(all(server["initial"][key] == 0 for key in ("coin_balance", "frozen_balance", "xp")), "Invalid initial wallet")
    final = server["final"]
    require(final["status"] == "completed" and final["frozen_balance"] == 0, "Invalid final task or wallet")
    for name, device in [("ios", ios), ("android", android)]:
        require(device["device"] == name and device["test"] == "AC-01", f"Invalid {name} device report")
        require(device["ready_with_zero_wallet"] is True and device["completed"] is True, f"Incomplete {name} UI flow")
        require(device["task_id"] == server["taskId"] and device["child_id"] == server["childId"], f"Different {name} task or child")
        require(device["coins"] == final["coin_balance"] > 0 and device["xp"] == final["xp"] > 0, f"{name} wallet mismatch")
    require(initial["device"] == "ios" and initial["test"] == "AC-01" and initial["reader_pass"] == "initial"
            and initial["ready_with_zero_wallet"] is True and ios["reader_pass"] == "restore", "Invalid reader passes")
    require(all(initial[key] == ios[key] == android[key] for key in ("task_id", "child_id", "family_id")),
            "Different task, child or family")
    require(ios["offline_state_after_android_completion"] is True and server["blockedAfterWriter"] > 0
            and server["blockedReaderRequests"] >= server["blockedAfterWriter"], "Missing offline cold-start observation")
    require(server["firstSnapshotAfterReconnectMs"] >= 0, "Missing fresh post-reconnect snapshot")
    rows = server["ledger"]
    require(len({row["id"] for row in rows}) == 2 and
            [(row["asset_type"], row["amount"]) for row in rows] ==
            [("coin", final["coin_balance"]), ("xp", final["xp"])], "Reward ledger mismatch")
    require(server["receipts"] == [{"kind": "start", "outcome": "applied"},
                                   {"kind": "complete", "outcome": "applied"}], "Task receipts mismatch")
    verify_child_views(initial, server)


def stop_group(process):
    # Each child has its own process group. Allow Node to shut down Postgres and
    # GoTrue gracefully, then reap any children left after a timeout or failure.
    if process.poll() is None:
        with contextlib.suppress(ProcessLookupError):
            process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            pass
    try:
        os.killpg(process.pid, signal.SIGTERM)
        time.sleep(0.5)
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=10)


def startup_error(logfile, item, status):
    # Keep process output private. Only permit our version probe's fixed fields,
    # the most recent startup stage and these known failure descriptions.
    log = logfile.read_text(encoding="utf-8", errors="replace").lower()
    stages = re.findall(r"^ac01_backend_stage (auth-version|loopback-services|database|auth-health|postgrest|scenario)$",
                        log, re.MULTILINE)
    stage = f" at {stages[-1]}" if stages and item == "server" else ""
    message = f"{item} {status}{stage}"
    version = re.search(r"^error: gotrue version probe failed: errno=(e[a-z0-9]{1,20}|other|none) "
                        r"exit=(-?[0-9]{1,10}|none) signal=(sig[a-z0-9]{1,12}|other|none) "
                        r"timeout_ms=([0-9]{1,6}) stderr=(none|loader|architecture|resources|permission|unclassified)$",
                        log, re.MULTILINE)
    if version:
        code, exit_code, sig, timeout_ms, stderr = version.groups()
        code = code.upper() if code.upper() in errno.errorcode.values() or code == "none" else "OTHER"
        sig = sig.upper() if sig.upper() in signal.Signals.__members__ or sig == "none" else "OTHER"
        return (f"{message}: Auth version probe errno={code} exit={exit_code} "
                f"signal={sig} timeout_ms={timeout_ms} stderr={stderr}")
    for line in log.splitlines():
        for needle, diagnosis in (
            ("no space left", "no free disk space"), ("not enough disk space", "insufficient disk for AVD"),
            ("requires hardware acceleration", "hypervisor unavailable"), ("address already in use", "port occupied"),
            ("unknown avd", "fixture AVD missing"), ("error: expected pinned", "backend binary version mismatch"),
            ("error: invalid auth_version_timeout_ms", "invalid Auth probe timeout"),
            ("error: set postgrest_bin", "PostgREST version probe failed"),
            ("error: gotrue migrations failed", "Auth migration failed"),
            ("error: gotrue did not become ready", "Auth health probe timed out"),
            ("error: postgrest did not become ready", "PostgREST health probe timed out"),
        ):
            if needle in line:
                return f"{message} ({diagnosis})"
    return message


def exit_status(code):
    if code >= 0:
        return f"exited with code {code}"
    try:
        return f"ended by {signal.Signals(-code).name}"
    except ValueError:
        return f"ended by signal {-code}"


def backend_timeout():
    setting = os.environ.get("CROSS_DEVICE_BACKEND_TIMEOUT_SECONDS", "300")
    require(re.fullmatch(r"[0-9]{1,4}", setting) and 30 <= int(setting) <= 900,
            "CROSS_DEVICE_BACKEND_TIMEOUT_SECONDS must be between 30 and 900")
    return int(setting)


def one_probe(command, timeout, discard=False):
    # A newly spawned ADB daemon can retain its client's descriptors. In
    # particular, communicate()/check_output() can then wait for EOF long
    # after the client exits. No startup or health command here uses a pipe.
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL if discard else output,
                                stderr=subprocess.DEVNULL if discard else subprocess.STDOUT,
                                timeout=timeout, start_new_session=True)
        output.seek(0)
        return result.returncode, output.read(1024 * 1024).decode("utf-8", "replace")


def probe(label, command, *, total=90, per_attempt=15, accept=lambda code, _: code == 0,
          discard=False, health=lambda: None):
    deadline = time.monotonic() + total
    attempts, pause, last = 0, 1, None
    while time.monotonic() < deadline:
        health()
        timeout = min(per_attempt, deadline - time.monotonic())
        if timeout <= 0:
            break
        attempts += 1
        try:
            code, output = one_probe(command, timeout, discard)
        except subprocess.TimeoutExpired:
            reason = "command timed out"
        except OSError as error:
            reason = "errno=" + errno.errorcode.get(error.errno, "UNKNOWN")
            if error.errno in (errno.ENOENT, errno.ENOEXEC, errno.EACCES):
                raise RuntimeError(f"{label} failed: {reason}") from None
        else:
            if accept(code, output):
                return output
            reason = exit_status(code) if code else "expected state not observed"
            for text, detail in (("device offline", "offline"), ("device unauthorized", "unauthorized"),
                                 ("cannot connect to daemon", "ADB daemon unreachable")):
                if text in output.lower():
                    reason += f" ({detail})"
                    break
        if last != reason:
            print(f"{label}: attempt {attempts} {reason}; retrying", flush=True)
        last = reason
        time.sleep(min(pause, max(0, deadline - time.monotonic())))
        pause = min(pause * 2, 8)
    raise RuntimeError(f"{label} exceeded {total}s after {attempts} attempts ({last})")


def device_list(code, output):
    return code == 0 and "List of devices attached" in output.splitlines()


def serial_present(output):
    return any(line.split()[:1] == [SERIAL] for line in output.splitlines())


def ports_free(first=PORT):
    with contextlib.ExitStack() as sockets:
        for port in (first, first + 1):
            sock = sockets.enter_context(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
            try:
                sock.bind(("127.0.0.1", port))
                sock.listen(1)
            except OSError as error:
                if error.errno == errno.EADDRINUSE:
                    return False
                raise
    return True


def accel_status(output):
    return re.search(r"^accel:[ \t]*\r?\n?[ \t]*(\d+)[ \t\r]*$", output, re.MULTILINE)


def valid_accel_result(code, output):
    match = accel_status(output)
    # A documented nonzero acceleration status permits software emulation.
    # An unrecognized failure or missing report must retry the probe.
    if not match:
        return False
    status = int(match.group(1))
    return code == 0 if status == 0 else 0 < status <= 255 and code in (0, 1, status)


def read_report(path, name):
    try:
        result = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise RuntimeError(f"{name} report missing or invalid") from None
    require(isinstance(result, dict), f"Invalid {name} report")
    return result


def ui_timeout(log):
    for match in re.finditer(r"Timed out waiting for ([a-zA-Z /-]{1,60})(?=\r?$|\\[nr])", log, re.MULTILINE):
        if match[1] in UI_STAGES:
            return match[1]
    return None


def driver_failure(path, name, status, phase, report=None):
    log = path.read_text(encoding="utf-8", errors="replace")
    message = f"{name} {status} in {phase}"
    if report and report.is_file():
        try:
            data = read_report(report, name)
        except RuntimeError:
            data = {}
        if data.get("stage") in REPORT_STAGES:
            message += ", app stage " + data["stage"]
        facts = [key for key in ("ready_with_zero_wallet", "offline_state_after_android_completion", "completed")
                 if data.get(key) is True]
        if facts:
            message += ", confirmed " + ", ".join(facts)
    if name in ("initial iPhone reader", "restored iPhone reader"):
        data = control_data("ios").get("iosHttp")
        fields = []
        for key in ("otp", "otpStatus", "verify", "verifyStatus", "snapshot", "snapshotStatus", "mailboxReads", "mailboxStatus", "mailboxInterrupted"):
            value = data.get(key) if isinstance(data, dict) else None
            valid = type(value) is int and (value == 0 or 100 <= value <= 599
                    if key.endswith("Status") else 0 <= value <= 1000000)
            fields.append(f"{key}={value if valid else 'unknown'}")
        message += "; iOS HTTP " + " ".join(fields)
        # A simulator log can contain email addresses, codes or tokens. Only
        # carry the fixture's fixed failure category or numeric status forward.
        match = re.search(r"Fixture mailbox (deadline reached \((?:pending|timeout|transport)\)|returned HTTP [1-5]\d\d)(?![\\w])", log)
        if match:
            message += "; mailbox " + match[1]
    stages = [s for s in re.findall(r"^Android driver stage: ([A-Za-z ]+)\r?$", log, re.MULTILINE)
              if s in ANDROID_DRIVER_STAGES]
    if stages:
        message += ", Android driver stage " + stages[-1]
    label = ui_timeout(log)
    if label:
        return message + ", timeout at " + label
    direct_failure = re.search(r"^Android driver failure: (command (?:timed out|could not start|exited -?\d{1,3})|"
                               r"no launchable app in APK|APK installation not confirmed|"
                               r"activity launch failed)\r?$", log, re.MULTILINE)
    if direct_failure:
        return f"{message} ({direct_failure[1]})"
    for text, detail in (("Dart VM service was not announced", "Dart VM discovery timed out"),
                         ("timed out after 1200 seconds", "Dart driver timed out"),
                         ("failed to install", "app installation failed"),
                         ("Error connecting to the service protocol", "Flutter service connection failed")):
        if text.lower() in log.lower():
            return f"{message} ({detail})"
    return message


def run():
    require(sys.platform == "darwin", "A macOS host is required")
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ["ANDROID_SDK_ROOT"])
    adb = sdk / "platform-tools/adb"
    emulator = sdk / "emulator/emulator"
    plist = Path("build/ios/iphonesimulator/Runner.app/Info.plist")
    require(APK.is_file() and plist.is_file(), "Prebuilt app missing")
    bundle = plistlib.loads(plist.read_bytes())["CFBundleIdentifier"]
    device = os.environ["SIMULATOR_ID"]
    require(re.fullmatch(r"[0-9a-fA-F-]{36}", device), "Expected a simulator UDID")
    server_timeout = backend_timeout()
    require(control_phase() is None, "The control port is already in use")
    reports = {name: RESULTS / f"cross_device_sync_{name}.json" for name in ("ios_initial", "android", "ios")}
    for path in (*reports.values(), SERVER_RESULT):
        path.unlink(missing_ok=True)
    adb_device = [adb, "-s", SERIAL]
    with tempfile.TemporaryDirectory(prefix="cross-device-") as tmp, contextlib.ExitStack() as stack:
        # Only controlled stage and status messages enter the public build log.
        def start(name, command, owner, env=None, stderr=subprocess.STDOUT):
            stream = owner.enter_context((Path(tmp) / name).open("wb"))
            try:
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream, stderr=stderr,
                                           start_new_session=True, env=env)
            except OSError as error:
                raise RuntimeError(f"{name} spawn failed: errno={errno.errorcode.get(error.errno, 'UNKNOWN')}") from None
            owner.callback(stop_group, process)
            return process

        def running(name, process):
            code = process.poll()
            if code is not None:
                raise RuntimeError(startup_error(Path(tmp) / name, name, exit_status(code)))

        print("Starting the isolated backend before booting the simulators", flush=True)
        env = {**os.environ, "CROSS_DEVICE_STARTUP_STAGES": "1"}
        env.setdefault("AUTH_VERSION_TIMEOUT_MS", "60000")
        server = start("server", ["node", "scripts/test_cross_device_sync.mjs"], stack, env)
        def backend_alive():
            running("server", server)
        deadline = time.monotonic() + server_timeout
        while control_phase() != "initial":
            backend_alive()
            if time.monotonic() >= deadline:
                raise RuntimeError(startup_error(Path(tmp) / "server", "server", f"timed out after {server_timeout}s"))
            time.sleep(2)
        print("Backend control is initial; starting the ADB server with both simulators idle", flush=True)
        probe("ADB start-server", [adb, "start-server"], total=120, per_attempt=30, discard=True, health=backend_alive)

        def check_available():
            devices = probe("ADB device inventory", [adb, "devices"], accept=device_list, health=backend_alive)
            require(not serial_present(devices) and ports_free(), "Target Android serial or emulator ports already in use")
        check_available()
        print("ADB device inventory responded and both target emulator ports are available", flush=True)

        inventory = probe("iPhone inventory", ["xcrun", "simctl", "list", "devices", "available", "--json"],
                          total=60, per_attempt=20, health=backend_alive)
        try:
            states = [row["state"] for devices in json.loads(inventory)["devices"].values()
                      for row in devices if row["udid"].lower() == device.lower()]
        except (ValueError, KeyError, TypeError):
            raise RuntimeError("Invalid iPhone inventory response") from None
        require(len(states) == 1, "Selected iPhone is unavailable")
        initially_booted = states[0] in ("Booted", "Booting")
        iphone_in_use = False

        def off_iphone():
            nonlocal iphone_in_use
            # simctl output can include a simulator identifier. Confirm shutdown
            # through the shared state checker and report only the stage.
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    shutdown_iphone(device)
            except (RuntimeError, ValueError, OSError, subprocess.SubprocessError):
                raise RuntimeError("Shutdown of the selected iPhone was not confirmed") from None
            iphone_in_use = False

        def cleanup_iphone():
            if iphone_in_use:
                if initially_booted:
                    with contextlib.suppress(subprocess.SubprocessError, OSError):
                        one_probe(["xcrun", "simctl", "terminate", device, bundle], 15, True)
                else:
                    with contextlib.suppress(RuntimeError):
                        off_iphone()
        stack.callback(cleanup_iphone)

        def boot_iphone(label):
            nonlocal iphone_in_use
            iphone_in_use = True
            with contextlib.ExitStack() as owner:
                process = start(label, ["xcrun", "simctl", "bootstatus", device, "-b"], owner)
                deadline = time.monotonic() + 480
                while process.poll() is None:
                    backend_alive()
                    require(time.monotonic() < deadline, f"{label} exceeded 480s")
                    time.sleep(2)
                if process.returncode:
                    raise RuntimeError(startup_error(Path(tmp) / label, label, exit_status(process.returncode)))

        def drive(label, command, expected, report, health=None, on_device=False):
            # On Android the launcher exits after am start. Only the backend's
            # verified report marks the on-device test as successfully finished.
            deadline = time.monotonic() + 21 * 60
            last = last_app_stage = None
            exited_at = login_deadline = None
            final = expected == "reader-confirmed"
            with contextlib.ExitStack() as owner:
                process = start(label, command, owner)
                while time.monotonic() < deadline:
                    if health:
                        health()
                    if on_device:
                        phase, app_stage = control_status("android")
                        if app_stage == "failed":
                            raise android_failure(f"Android on-device assertions failed after {last_app_stage or 'launch'}", adb_device)
                        if app_stage and app_stage != last_app_stage:
                            last_app_stage = app_stage
                            # A suspended frame can prevent the guest from reaching
                            # its two-minute UI or three-minute mailbox timeout.
                            login_deadline = time.monotonic() + 4 * 60 if app_stage in LOGIN_STAGES else None
                            print(f"Android on-device stage {app_stage}", flush=True)
                        if login_deadline is not None and time.monotonic() >= login_deadline:
                            raise android_failure(f"Android login timed out after {last_app_stage}", adb_device)
                    else:
                        phase = control_phase()
                    if phase and phase != last:
                        last = phase
                        print(f"{label}: AC-01 phase {phase}", flush=True)
                    code = process.poll()
                    if code not in (None, 0):
                        raise RuntimeError(driver_failure(Path(tmp) / label, label, exit_status(code), last, report))
                    server_code = server.poll()
                    if server_code is not None and not (final and server_code == 0):
                        raise RuntimeError(driver_failure(Path(tmp) / "server", "server", exit_status(server_code), last))
                    if code == 0:
                        if on_device:
                            if last == expected and report.is_file():
                                return read_report(report, label)
                            time.sleep(2)
                            continue
                        # The server exits after the final HTTP acknowledgement;
                        # that short-lived phase may be observable only in its proof.
                        finished = final and SERVER_RESULT.is_file() and read_report(SERVER_RESULT, "server").get("passed") is True
                        if last == expected or finished:
                            return read_report(report, label)
                        exited_at = exited_at or time.monotonic()
                        require(time.monotonic() - exited_at < 10, f"{label} exited before {expected}")
                    time.sleep(2)
            if on_device:
                raise android_failure(f"Verified Android report timed out after {last_app_stage or 'launch'}", adb_device)
            raise RuntimeError(driver_failure(Path(tmp) / label, label, "exceeded 21 minutes", last, report))

        ios_command = [sys.executable, "scripts/run_ios_simulator_flow.py", "--driver", DRIVER]
        boot_iphone("initial iPhone boot")
        initial = drive("initial iPhone reader", ios_command, "reader-ready", reports["ios_initial"])
        require(initial.get("reader_pass") == "initial" and initial.get("ready_with_zero_wallet") is True,
                "Initial reader report incomplete")
        print("Initial iPhone reader confirmed the ready task and zero wallet; shutting down that simulator", flush=True)
        off_iphone()
        print("iPhone shutdown confirmed; preparing the Android writer", flush=True)

        # Recheck ownership after the iPhone phase before launching anything on these ports.
        check_available()
        accel = probe("Android acceleration check", [emulator, "-accel-check"], total=60,
                      per_attempt=15, accept=valid_accel_result, health=backend_alive)
        accelerated = int(accel_status(accel).group(1)) == 0
        print("Starting Android AVD with " + ("hardware acceleration" if accelerated else "software CPU emulation"), flush=True)
        with contextlib.ExitStack() as owner:
            avd = start("emulator", [emulator, "-avd", "cross-device-android", "-port", str(PORT),
                        "-cores", "2", "-memory", "1536", "-no-window", "-no-audio", "-no-boot-anim",
                        "-no-snapshot", "-gpu", "software", "-accel", "on" if accelerated else "off"], owner)
            def android_alive():
                backend_alive()
                running("emulator", avd)
            def stop_avd():
                if avd.poll() is None:
                    with contextlib.suppress(subprocess.SubprocessError, OSError):
                        code, _ = one_probe(adb_device + ["emu", "kill"], 8, True)
                        if code == 0:
                            avd.wait(timeout=15)
                # The owner then reaps this exact process group, including after a transport failure.
            owner.callback(stop_avd)
            probe("Android boot completion", adb_device + ["shell", "getprop", "sys.boot_completed"],
                  total=600 if accelerated else 900, per_attempt=8,
                  accept=lambda code, out: code == 0 and out.strip() == "1", health=android_alive)
            print(renderer_summary(Path(tmp) / "emulator"), flush=True)
            probe("Android transport", adb_device + ["get-state"], total=60,
                  accept=lambda code, out: code == 0 and out.strip() == "device", health=android_alive)
            probe("Android stay awake", adb_device + ["shell", "svc", "power", "stayon", "true"], health=android_alive)
            probe("Android wake screen", adb_device + ["shell", "input", "keyevent", "KEYCODE_WAKEUP"], health=android_alive)
            probe("Android keyguard", adb_device + ["shell", "wm", "dismiss-keyguard"], health=android_alive)
            probe("Android display awake", adb_device + ["shell", "dumpsys", "power"], total=30,
                  accept=lambda code, out: code == 0 and wakefulness(out) == "Awake", health=android_alive)
            ports = ("54324", "54326")
            for port in ports:
                probe(f"Android reverse {port}", adb_device + ["reverse", f"tcp:{port}", f"tcp:{port}"], health=android_alive)
            def mapped(code, output):
                routes = [line.split()[-2:] for line in output.splitlines()]
                return code == 0 and all([f"tcp:{port}", f"tcp:{port}"] in routes for port in ports)
            probe("Android reverse verification", adb_device + ["reverse", "--list"], accept=mapped, health=android_alive)
            print("Android boot, transport and both reverse mappings confirmed; launching the writer", flush=True)
            # Keep a filtered stream on the host before the Activity starts.
            # Already received marks survive a later loss of the ADB transport.
            trace = start("Android startup marks", adb_device + ["logcat", "-b", "main", "-T", "1", "-v", "raw",
                          "-e", ANDROID_LOG_FILTER, "LP_STARTUP:I", "flutter:I", "*:S"], owner, stderr=subprocess.DEVNULL)
            try:
                android = drive("Android writer", [sys.executable, "scripts/run_android_simulator_flow.py",
                                "--serial", SERIAL, "--apk", str(APK)],
                                "writer-complete", reports["android"], android_alive, on_device=True)
            finally:
                state = "running" if trace.poll() is None else "exited"
                print(f"Android startup capture={state} marks={startup_summary(Path(tmp) / 'Android startup marks')}", flush=True)
            require(android.get("completed") is True and android.get("task_id") == initial.get("task_id"),
                    "Android writer report incomplete or wrong task")
            print("Android writer confirmed completion; shutting down its emulator", flush=True)
        probe("Android release verification", [adb, "devices"], total=90, per_attempt=12, health=backend_alive,
              accept=lambda code, out: device_list(code, out) and not serial_present(out) and ports_free())
        print("Android process, serial and emulator ports released; restarting the same iPhone", flush=True)
        boot_iphone("restore iPhone boot")
        ios = drive("restored iPhone reader", ios_command + ["--reuse-installed"], "reader-confirmed", reports["ios"])
        try:
            server_code = server.wait(timeout=45)
        except subprocess.TimeoutExpired:
            raise RuntimeError("Backend did not exit after reader confirmation") from None
        require(server_code == 0, f"Backend {exit_status(server_code)} after reader confirmation")
        proof = read_report(SERVER_RESULT, "server")
        verify_evidence(initial, ios, android, proof)
        print(f"AC-01 passed: three native launches agree, one coin entry and one XP entry; "
              f"first fresh reader snapshot in {proof['firstSnapshotAfterReconnectMs']} ms.", flush=True)


if __name__ == "__main__":
    # GitHub sends SIGTERM on cancellation. Exit through managed cleanup.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    run()
