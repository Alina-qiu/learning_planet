"""Run the native task fixture without racing Apple's unified log stream.

The simulator and prebuilt integration app must already exist. Read retained
system logs for the PID returned by launch, including an early VM announcement.
This changes test transport only, not the app, renderer or test assertions.
"""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
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
    while time.monotonic() < deadline:
        # Flutter emits the announcement via os_log on iOS; --console-pty does
        # not capture it. Query persisted entries instead of subscribing late.
        result = subprocess.run(
            ["xcrun", "simctl", "spawn", device, "log", "show", "--last", "5m",
             "--style", "compact", "--predicate",
             'process == "Runner" AND eventMessage CONTAINS "The Dart VM service is listening on"'],
            capture_output=True, text=True, timeout=20, check=True,
        )
        (report / "vm-service.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        url = vm_service_url(result.stdout, pid)
        if url:
            return url
        time.sleep(2)
    raise TimeoutError("Dart VM service was not announced within 120 seconds")


def main():
    if sys.platform != "darwin":
        raise RuntimeError("This runner requires macOS and an iOS simulator")
    device = os.environ["SIMULATOR_ID"]
    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", device):
        raise ValueError("Expected a simulator UDID")
    app = Path("build/ios/iphonesimulator/Runner.app")
    with (app / "Info.plist").open("rb") as source:
        bundle = plistlib.load(source)["CFBundleIdentifier"]
    report = Path("build/ios-simulator")
    report.mkdir(parents=True, exist_ok=True)
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
        print("Dart VM ready; running the unchanged native task assertions", flush=True)
        with (report / "task-flow.log").open("wb") as log:
            result = subprocess.run(
                ["flutter", "drive", "--no-pub", "--debug", "--verbose",
                 f"--use-existing-app={url}",
                 "--driver=test_driver/task_flow_driver.dart",
                 "--target=integration_test/task_flow_test.dart", "-d", device],
                stdout=log, stderr=subprocess.STDOUT, timeout=480,
            )
        return result.returncode
    finally:
        # Keep the app alive until workflow cleanup, preserving its failed UI.
        try:
            with (report / "app-screenshot.log").open("wb") as log:
                subprocess.run(
                    ["xcrun", "simctl", "io", device, "screenshot",
                     str(report / "app-final.png")],
                    stdout=log, stderr=subprocess.STDOUT, timeout=30,
                )
        finally:
            for name in ("app-launch.log", "vm-service.log", "task-flow.log"):
                path = report / name
                if path.exists():
                    print(f"\n{name}:\n{path.read_text(encoding='utf-8', errors='replace')}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
