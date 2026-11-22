"""Run the prebuilt AC-01 clients on one Intel Mac and one loopback backend."""
import contextlib
import errno
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


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
             "completed task", "confirmed wallet"}


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


def verify_evidence(ios, android, server):
    require(server["passed"] is True and server["separateLogins"] is True, "Server proof incomplete")
    require(server["initial"]["status"] in ("ready", "scheduled"), "Invalid initial task")
    require(all(server["initial"][key] == 0 for key in ("coin_balance", "frozen_balance", "xp")), "Invalid initial wallet")
    final = server["final"]
    require(final["status"] == "completed" and final["frozen_balance"] == 0, "Invalid final task or wallet")
    for name, device in [("ios", ios), ("android", android)]:
        require(device["device"] == name and device["test"] == "AC-01", f"Invalid {name} device report")
        require(device["ready_with_zero_wallet"] is True and device["completed"] is True, f"Incomplete {name} UI flow")
        require(device["task_id"] == server["taskId"] and device["child_id"] == server["childId"], f"Different {name} task or child")
        require(device["coins"] == final["coin_balance"] > 0 and device["xp"] == final["xp"] > 0, f"{name} wallet mismatch")
    require(ios["family_id"] == android["family_id"], "Different families")
    require(ios["offline_state_after_android_completion"] is True and server["blockedReaderRequests"] > 0, "Missing offline observation")
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


def run():
    require(sys.platform == "darwin", "A macOS host is required")
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ["ANDROID_SDK_ROOT"])
    adb = sdk / "platform-tools/adb"
    emulator = sdk / "emulator/emulator"
    flutter = Path(os.environ["FLUTTER_ROOT"]) / "bin/flutter"
    plist = Path("build/ios/iphonesimulator/Runner.app/Info.plist")
    require(APK.is_file() and plist.is_file(), "Prebuilt app missing")
    bundle = plistlib.loads(plist.read_bytes())["CFBundleIdentifier"]
    device = os.environ["SIMULATOR_ID"]
    require(re.fullmatch(r"[0-9a-fA-F-]{36}", device), "Expected a simulator UDID")
    server_timeout = backend_timeout()
    require(control_phase() is None, "The control port is already in use")
    for name in ("ios", "android"):
        (RESULTS / f"cross_device_sync_{name}.json").unlink(missing_ok=True)
    SERVER_RESULT.unlink(missing_ok=True)
    adb_device = [adb, "-s", SERIAL]
    with tempfile.TemporaryDirectory(prefix="cross-device-") as tmp, contextlib.ExitStack() as stack:
        # No raw child output enters the public CI logs or artifacts.
        def start(name, command, env=None):
            stream = stack.enter_context((Path(tmp) / name).open("wb"))
            try:
                process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                           start_new_session=True, env=env)
            except OSError as error:
                raise RuntimeError(f"{name} spawn failed: errno={errno.errorcode.get(error.errno, 'UNKNOWN')}") from None
            stack.callback(stop_group, process)
            return process

        def adb_run(*args, check=True, timeout=15):
            return subprocess.run(adb_device + list(args), capture_output=True, text=True,
                                  timeout=timeout, check=check)

        def running(name, process):
            code = process.poll()
            if code is not None:
                raise RuntimeError(startup_error(Path(tmp) / name, name, exit_status(code)))

        print("Starting the isolated backend before booting the simulators", flush=True)
        env = {**os.environ, "CROSS_DEVICE_STARTUP_STAGES": "1"}
        env.setdefault("AUTH_VERSION_TIMEOUT_MS", "60000")
        server = start("server", ["node", "scripts/test_cross_device_sync.mjs"], env)
        deadline = time.monotonic() + server_timeout
        while control_phase() != "initial":
            running("server", server)
            if time.monotonic() >= deadline:
                raise RuntimeError(startup_error(Path(tmp) / "server", "server", f"timed out after {server_timeout}s"))
            time.sleep(2)
        print("Backend control is initial; booting the selected iPhone", flush=True)

        def simctl_cleanup(*arguments):
            with contextlib.suppress(subprocess.TimeoutExpired, OSError):
                subprocess.run(["xcrun", "simctl", *arguments], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=20)

        devices = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                                 capture_output=True, text=True, timeout=30)
        require(devices.returncode == 0, "Could not query selected iPhone state")
        states = [entry["state"] for entries in json.loads(devices.stdout)["devices"].values()
                  for entry in entries if entry["udid"].lower() == device.lower()]
        require(len(states) == 1, "Selected iPhone is unavailable")
        if states[0] == "Shutdown":
            stack.callback(simctl_cleanup, "shutdown", device)
        boot_ios = start("iPhone boot", ["xcrun", "simctl", "bootstatus", device, "-b"])
        deadline = time.monotonic() + 480
        while boot_ios.poll() is None:
            running("server", server)
            require(time.monotonic() < deadline, "Timed out waiting for iPhone boot")
            time.sleep(2)
        if boot_ios.returncode:
            raise RuntimeError(startup_error(Path(tmp) / "iPhone boot", "iPhone boot", exit_status(boot_ios.returncode)))

        adb_devices = subprocess.check_output([adb, "devices"], text=True, timeout=20, stderr=subprocess.DEVNULL)
        require(SERIAL not in adb_devices, f"{SERIAL} already in use")
        accel = subprocess.run([emulator, "-accel-check"], capture_output=True, text=True, timeout=15)
        accelerated = bool(re.search(r"^accel:\s*0\s*$", accel.stdout + accel.stderr, re.MULTILINE))
        print("iPhone booted; starting Android AVD with " +
              ("hardware acceleration" if accelerated else "software CPU emulation"), flush=True)
        avd = start("emulator", [emulator, "-avd", "cross-device-android", "-port", str(PORT),
                                 "-cores", "2", "-memory", "1536", "-no-window", "-no-audio", "-no-boot-anim",
                                 "-no-snapshot", "-gpu", "software", "-accel", "on" if accelerated else "off"])
        def shutdown_avd():
            with contextlib.suppress(subprocess.TimeoutExpired, OSError):
                adb_run("emu", "kill", check=False, timeout=8)
        stack.callback(shutdown_avd)
        deadline = time.monotonic() + (600 if accelerated else 900)
        while True:
            running("server", server)
            running("emulator", avd)
            try:
                boot = adb_run("shell", "getprop", "sys.boot_completed", check=False, timeout=5)
            except subprocess.TimeoutExpired:
                boot = None
            if boot and boot.returncode == 0 and boot.stdout.strip() == "1":
                break
            require(time.monotonic() < deadline, "Timed out waiting for Android boot")
            time.sleep(2)
        adb_run("shell", "wm", "dismiss-keyguard")
        for port in ("54324", "54326"):
            adb_run("reverse", f"tcp:{port}", f"tcp:{port}")
        print("Both simulators are ready; launching the iPhone reader", flush=True)
        stack.callback(simctl_cleanup, "terminate", device, bundle)
        ios = start("ios", [sys.executable, "scripts/run_ios_simulator_flow.py", "--driver", DRIVER])
        android = None
        last_phase = None
        deadline = time.monotonic() + 21 * 60
        while True:
            phase = control_phase()
            if phase and phase != last_phase:
                last_phase = phase
                print(f"AC-01 phase {phase}", flush=True)
            if phase == "reader-ready" and android is None:
                android = start("android", [flutter, "drive", "--no-dds", "--debug", "--no-pub", "-d", SERIAL,
                                           f"--use-application-binary={APK}", f"--driver={DRIVER}",
                                           "--target=integration_test/cross_device_sync_test.dart"])
            for name, process in [("ios", ios), ("android", android), ("server", server)]:
                if process is None:
                    continue
                code = process.poll()
                if code not in (None, 0):
                    # Device transcripts may contain OTPs or VM addresses. Only
                    # extract a bounded stage from our own test assertion.
                    log = (Path(tmp) / name).read_text(encoding="utf-8", errors="replace")
                    match = re.search(r"Timed out waiting for ([a-zA-Z /-]{1,60})(?:\r?\n|$)", log)
                    detail = f", timeout at {match.group(1)}" if match and match.group(1) in UI_STAGES else ""
                    raise RuntimeError(f"{name} exited with {code} in {last_phase}{detail}")
            if android is not None and all(p.poll() == 0 for p in (ios, android, server)):
                break
            require(avd.poll() is None, "Android emulator exited during the test")
            require(time.monotonic() < deadline, f"Cross-device flow timed out in {last_phase}")
            time.sleep(2)
        ios_report, android_report = [json.loads((RESULTS / f"cross_device_sync_{name}.json").read_text())
                                      for name in ("ios", "android")]
        proof = json.loads(SERVER_RESULT.read_text())
        verify_evidence(ios_report, android_report, proof)
        print(f"AC-01 passed: both device reports agree, one coin entry and one XP entry; "
              f"first fresh reader snapshot in {proof['firstSnapshotAfterReconnectMs']} ms.", flush=True)


if __name__ == "__main__":
    # GitHub sends SIGTERM on cancellation. Exit through managed cleanup.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    run()
