"""Run a native integration fixture on a prepared Apple simulator.

Follow live unified logs and query retained entries from the last five minutes.
Connect the Flutter driver to the VM announcement from the newly launched PID.
"""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time


def vm_service_url(output, pid):
    # Compact log entries include Runner[PID:thread]. Ignore any earlier launch
    # even if it announced an otherwise valid loopback service URL.
    output = "\n".join(line for line in output.splitlines() if f"Runner[{pid}:" in line)
    match = re.search(
        r"The Dart VM service is listening on (http://127\.0\.0\.1:\d+/[A-Za-z0-9_=-]+/)",
        output,
    )
    return match.group(1) if match else None


def launch_pid(output, bundle):
    match = re.search(rf"^{re.escape(bundle)}: ([1-9][0-9]*)$", output, re.MULTILINE)
    if not match:
        raise RuntimeError("simctl launch did not return the app PID")
    return int(match.group(1))


def wait_for_service(device, pid, report, timeout=120):
    deadline = time.monotonic() + timeout
    # Flutter sends this announcement through os_log. Follow new entries and
    # also query the preceding five minutes in case it was emitted at launch.
    prefix = ["xcrun", "simctl", "spawn", device, "log"]
    flags = ["--style", "compact", "--predicate",
             'process == "Runner" AND eventMessage CONTAINS "The Dart VM service is listening on"']
    processes = {}
    last_lookup = float("-inf")

    def stop(process):
        if process.poll() is not None:
            return True
        process.kill()
        try:
            process.wait(timeout=min(1, max(0, deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            # Keep ownership of a slow-to-exit probe. Never wait past discovery's budget.
            return False
        return True

    url = None
    with tempfile.TemporaryDirectory() as directory:
        paths = {name:Path(directory) / name for name in ("stream", "show")}
        try:
            while True:
                for path in paths.values():
                    if path.exists():
                        with path.open("rb") as log:
                            log.seek(max(0, path.stat().st_size - 65536))
                            url = vm_service_url(log.read().decode("utf-8", "replace"), pid)
                        if url:
                            return url
                now = time.monotonic()
                if now >= deadline:
                    raise TimeoutError(f"Dart VM service was not announced within {timeout} seconds")
                for name, path in paths.items():
                    process = processes.get(name)
                    if name == "stream" and process is not None:
                        continue
                    if process is not None and process.poll() is None:
                        if now - last_lookup < 30:
                            continue
                        if not stop(process):
                            continue
                    if name == "show" and now - last_lookup < 2:
                        continue
                    args = [name, "--last", "5m"] if name == "show" else [name]
                    # Each producer appends. A late writer after simctl exits
                    # must not lose its bytes to truncation on the next probe.
                    with path.open("ab") as log:
                        processes[name] = subprocess.Popen(prefix + args + flags, stdout=log,
                                                           stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
                    if name == "show":
                        last_lookup = now
                time.sleep(min(0.5, max(0, deadline - time.monotonic())))
        finally:
            pending = sum(1 for process in processes.values() if not stop(process))
            status = "ready" if url else "unavailable"
            counts = {name:path.stat().st_size if path.exists() else 0 for name,path in paths.items()}
            (report / "vm-service.log").write_text(
                f"Runner PID {pid}: VM discovery {status}; stream bytes={counts['stream']}, "
                f"retained bytes={counts['show']}, pending cleanup={pending}\n", encoding="utf-8")


DEFAULT_DRIVER = "test_driver/task_flow_driver.dart"
CROSS_DEVICE_DRIVER = "test_driver/cross_device_sync_driver.dart"
OCR_DRIVER = "test_driver/ocr_native_driver.dart"


def main(driver=DEFAULT_DRIVER, private_report=None, reuse_installed=False):
    if sys.platform != "darwin":
        raise RuntimeError("This runner requires macOS and an iOS simulator")
    if driver == CROSS_DEVICE_DRIVER and private_report is None:
        with tempfile.TemporaryDirectory(prefix="cross-device-ios-") as directory:
            return main(driver, Path(directory), reuse_installed)
    device = os.environ["SIMULATOR_ID"]
    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", device):
        raise ValueError("Expected a simulator UDID")
    app = Path("build/ios/iphonesimulator/Runner.app")
    with (app / "Info.plist").open("rb") as source:
        bundle = plistlib.load(source)["CFBundleIdentifier"]
    report = private_report or Path("build/ios-simulator")
    report.mkdir(parents=True, exist_ok=True)
    if reuse_installed:
        print("Launching the previously installed integration app", flush=True)
    else:
        print("Installing the prebuilt integration app", flush=True)
        subprocess.run(["xcrun", "simctl", "install", device, str(app)], check=True, timeout=180)
    launch = subprocess.run(
        ["xcrun", "simctl", "launch", device, bundle,
         "--enable-dart-profiling", "--disable-vm-service-publication",
         "--start-paused", "--enable-checked-mode", "--verify-entry-points"],
        capture_output=True, text=True, timeout=60, check=True,
    )
    (report / "app-launch.log").write_text(launch.stdout + launch.stderr, encoding="utf-8")
    pid = launch_pid(launch.stdout, bundle)
    try:
        url = wait_for_service(device, pid, report)
        print(f"Dart VM ready; running {driver}", flush=True)
        with (report / "task-flow.log").open("wb") as log:
            # This is the same Dart driver invocation used by Flutter's
            # FlutterDriverService.startTest. Avoid a second device discovery
            # and an unscoped system-log subscription for an existing app.
            dart = Path(os.environ["FLUTTER_ROOT"]) / "bin/cache/dart-sdk/bin/dart"
            result = subprocess.run(
                [str(dart), driver],
                env={**os.environ, "VM_SERVICE_URL": url},
                stdout=log, stderr=subprocess.STDOUT, timeout=1200 if private_report else 480,
            )
        if private_report and result.returncode:
            # Share the failed assertion stage with the coordinator. Raw device
            # logs can include a VM token, and a login screenshot can show an OTP.
            output = (report / "task-flow.log").read_text(encoding="utf-8", errors="replace")
            match = re.search(r"Timed out waiting for ([a-zA-Z /-]{1,60})(?:\r?\n|$)", output)
            if match:
                print("Timed out waiting for " + match.group(1), flush=True)
        return result.returncode
    finally:
        if not private_report:
            collect_diagnostics(device, report)


def collect_diagnostics(device, report):
    # Keep the app alive until workflow cleanup, preserving its failed UI.
    try:
        with (report / "app-screenshot.log").open("wb") as log:
            subprocess.run(
                ["xcrun", "simctl", "io", device, "screenshot",
                 str(report / "app-final.png")],
                stdout=log, stderr=subprocess.STDOUT, timeout=30,
            )
    except (subprocess.TimeoutExpired, OSError) as error:
        # This optional post-test image must not replace the driver's exit
        # code (or its exception). Required in-test screenshots still fail
        # through the Dart driver when they cannot be captured.
        print(f"Optional final screenshot unavailable: {type(error).__name__}", flush=True)
    finally:
        for name in ("app-launch.log", "vm-service.log", "task-flow.log"):
            path = report / name
            if path.exists():
                print(f"\n{name}:\n{path.read_text(encoding='utf-8', errors='replace')}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--driver", choices=[DEFAULT_DRIVER, CROSS_DEVICE_DRIVER, OCR_DRIVER], default=DEFAULT_DRIVER)
    parser.add_argument("--reuse-installed", action="store_true")
    args = parser.parse_args()
    sys.exit(main(args.driver, reuse_installed=args.reuse_installed))
