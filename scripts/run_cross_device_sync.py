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
import urllib.error
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
             "child menu", "selected child", "initial wallet", "ready task", "offline cached ready task",
             "offline cached wallet", "enabled start action", "in-progress task", "enabled completion action",
             "completed task", "confirmed wallet", "home from the offline iPhone session"}
REPORT_STAGES = {"fixture", "email_login", "restore_offline_session", "load_family_task_and_wallet",
                 "cached_before_shutdown", "reconnect", "complete_task", "confirm_task_and_wallet", "confirmed"}
ANDROID_DRIVER_STAGES = {"APK metadata", "installation", "activity launch", "app PID", "VM discovery",
                         "VM forwarding", "Dart driver", "cleanup"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def control_phase():
    try:
        with urllib.request.urlopen("http://127.0.0.1:54324/phase?device=ios", timeout=2) as response:
            phase = json.load(response)["phase"]
        return phase if phase in PHASES else None
    except (OSError, ValueError, KeyError, urllib.error.URLError):
        return None


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
    stages = [s for s in re.findall(r"^Android driver stage: ([A-Za-z ]+)\r?$", log, re.MULTILINE)
              if s in ANDROID_DRIVER_STAGES]
    if stages:
        message += ", Android driver stage " + stages[-1]
    label = ui_timeout(log)
    if label:
        return message + ", timeout at " + label
    direct_failure = re.search(r"^Android driver failure: (command (?:timed out|could not start|exited -?\d{1,3})|"
                               r"no launchable app in APK|APK installation not confirmed|could not read device clock|"
                               r"activity launch failed|app PID not found|VM discovery timed out|app process changed|"
                               r"no host port allocated|could not release app or forward)\r?$", log, re.MULTILINE)
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
        def start(name, command, owner, env=None):
            stream = owner.enter_context((Path(tmp) / name).open("wb"))
            try:
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
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

        def drive(label, command, expected, report, health=None):
            # This covers installation, VM connection and execution on both
            # platforms. Flutter's extended integration driver has no request
            # deadline; the separate iOS Dart invocation also has a 1200s cap.
            deadline = time.monotonic() + 21 * 60
            last = None
            exited_at = None
            final = expected == "reader-confirmed"
            with contextlib.ExitStack() as owner:
                process = start(label, command, owner)
                while time.monotonic() < deadline:
                    if health:
                        health()
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
                        # The server exits after the final HTTP acknowledgement;
                        # that short-lived phase may be observable only in its proof.
                        finished = final and SERVER_RESULT.is_file() and read_report(SERVER_RESULT, "server").get("passed") is True
                        if last == expected or finished:
                            return read_report(report, label)
                        exited_at = exited_at or time.monotonic()
                        require(time.monotonic() - exited_at < 10, f"{label} exited before {expected}")
                    time.sleep(2)
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
            probe("Android transport", adb_device + ["get-state"], total=60,
                  accept=lambda code, out: code == 0 and out.strip() == "device", health=android_alive)
            probe("Android keyguard", adb_device + ["shell", "wm", "dismiss-keyguard"], health=android_alive)
            ports = ("54324", "54326")
            for port in ports:
                probe(f"Android reverse {port}", adb_device + ["reverse", f"tcp:{port}", f"tcp:{port}"], health=android_alive)
            def mapped(code, output):
                routes = [line.split()[-2:] for line in output.splitlines()]
                return code == 0 and all([f"tcp:{port}", f"tcp:{port}"] in routes for port in ports)
            probe("Android reverse verification", adb_device + ["reverse", "--list"], accept=mapped, health=android_alive)
            print("Android boot, transport and both reverse mappings confirmed; launching the writer", flush=True)
            android = drive("Android writer", [sys.executable, "scripts/run_android_simulator_flow.py",
                            "--serial", SERIAL, "--apk", str(APK), "--driver", DRIVER],
                            "writer-complete", reports["android"], android_alive)
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
