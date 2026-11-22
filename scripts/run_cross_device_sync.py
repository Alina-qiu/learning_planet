"""Run the prebuilt AC-01 clients on one Intel Mac and one loopback backend."""
import contextlib
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


def startup_error(logfile, item):
    # Emit only fixed descriptions. Raw logs stay in a private temporary folder.
    log = logfile.read_text(encoding="utf-8", errors="replace").lower()
    for text, diagnosis in (
        ("no space left", "no free disk space"),
        ("not enough disk space", "insufficient disk for AVD"),
        ("requires hardware acceleration", "hypervisor unavailable"),
        ("address already in use", "port occupied"),
        ("unknown avd", "fixture AVD missing"),
        ("expected pinned", "backend binary version mismatch"),
        ("set gotrue_bin", "Auth executable unavailable"),
    ):
        if text in log:
            return f"{item} failed during setup ({diagnosis})"
    return f"{item} exited during setup"


def run():
    require(sys.platform == "darwin", "A macOS host is required")
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ["ANDROID_SDK_ROOT"])
    adb = sdk / "platform-tools/adb"
    emulator = sdk / "emulator/emulator"
    flutter = Path(os.environ["FLUTTER_ROOT"]) / "bin/flutter"
    plist = Path("build/ios/iphonesimulator/Runner.app/Info.plist")
    require(APK.is_file() and plist.is_file(), "Prebuilt app missing")
    bundle = plistlib.loads(plist.read_bytes())["CFBundleIdentifier"]
    def stop_ios_app():
        # The caller owns the simulator; terminate only this test app.
        with contextlib.suppress(subprocess.TimeoutExpired, OSError):
            subprocess.run(["xcrun", "simctl", "terminate", os.environ["SIMULATOR_ID"], bundle],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)

    adb_devices = subprocess.check_output([adb, "devices"], text=True, timeout=20)
    require(SERIAL not in adb_devices, f"{SERIAL} already in use")
    require(control_phase() is None, "The control port is already in use")
    accel = subprocess.run([emulator, "-accel-check"], capture_output=True, text=True, timeout=15)
    accelerated = bool(re.search(r"^accel:\s*0\s*$", accel.stdout + accel.stderr, re.MULTILINE))
    print("Starting Android AVD with " + ("hardware acceleration" if accelerated else "software CPU emulation"), flush=True)
    for name in ("ios", "android"):
        (RESULTS / f"cross_device_sync_{name}.json").unlink(missing_ok=True)
    SERVER_RESULT.unlink(missing_ok=True)
    adb_device = [adb, "-s", SERIAL]
    with tempfile.TemporaryDirectory(prefix="cross-device-") as tmp, contextlib.ExitStack() as stack:
        # No raw child output enters the public CI logs or artifacts.
        def start(name, command):
            stream = stack.enter_context((Path(tmp) / name).open("wb"))
            process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            stack.callback(stop_group, process)
            return process

        def adb_run(*args, check=True, timeout=15):
            return subprocess.run(adb_device + list(args), capture_output=True, text=True,
                                  timeout=timeout, check=check)

        avd = start("emulator", [emulator, "-avd", "cross-device-android", "-port", str(PORT),
                                 "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot",
                                 "-gpu", "software", "-accel", "on" if accelerated else "off"])
        server = start("server", ["node", "scripts/test_cross_device_sync.mjs"])
        deadline = time.monotonic() + (600 if accelerated else 900)
        while True:
            for name, process in [("emulator", avd), ("server", server)]:
                if process.poll() is not None:
                    raise RuntimeError(startup_error(Path(tmp) / name, name))
            try:
                boot = adb_run("shell", "getprop", "sys.boot_completed", check=False, timeout=5)
            except subprocess.TimeoutExpired:
                boot = None
            if boot and boot.stdout.strip() == "1" and control_phase() == "initial":
                break
            require(time.monotonic() < deadline, "Timed out waiting for Android and the local backend")
            time.sleep(2)
        adb_run("shell", "wm", "dismiss-keyguard")
        def shutdown_avd():
            with contextlib.suppress(subprocess.TimeoutExpired, OSError):
                adb_run("emu", "kill", check=False, timeout=8)
        stack.callback(shutdown_avd)
        for port in ("54324", "54326"):
            adb_run("reverse", f"tcp:{port}", f"tcp:{port}")
        print("Both simulators and local backend ready; launching OTP clients", flush=True)
        stack.callback(stop_ios_app)
        ios = start("ios", [sys.executable, "scripts/run_ios_simulator_flow.py", "--driver", DRIVER])
        android = start("android", [flutter, "drive", "--no-dds", "--debug", "--no-pub", "-d", SERIAL,
                                    f"--use-application-binary={APK}", f"--driver={DRIVER}",
                                    "--target=integration_test/cross_device_sync_test.dart"])
        last_phase = None
        deadline = time.monotonic() + 21 * 60
        while True:
            phase = control_phase()
            if phase and phase != last_phase:
                last_phase = phase
                print(f"AC-01 phase {phase}", flush=True)
            for name, process in [("ios", ios), ("android", android), ("server", server)]:
                code = process.poll()
                if code not in (None, 0):
                    # Device transcripts may contain OTPs or VM addresses. Only
                    # extract a bounded stage from our own test assertion.
                    log = (Path(tmp) / name).read_text(encoding="utf-8", errors="replace")
                    match = re.search(r"Timed out waiting for ([a-zA-Z /-]{1,60})(?:\r?\n|$)", log)
                    detail = f", timeout at {match.group(1)}" if match else ""
                    raise RuntimeError(f"{name} exited with {code} in {last_phase}{detail}")
            if all(p.poll() == 0 for p in (ios, android, server)):
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
