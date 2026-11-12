"""Run the native task fixture without racing Apple's unified log stream.

The simulator and prebuilt integration app must already exist. simctl's console
is attached before launch, so even an early Dart VM announcement is retained.
This changes test transport only, not the app, renderer or test assertions.
"""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time


def vm_service_url(output):
    match = re.search(
        r"The Dart VM service is listening on (http://127\.0\.0\.1:\d+/[A-Za-z0-9_=-]+/)",
        output,
    )
    return match.group(1) if match else None


def wait_for_service(process, console, timeout=120):
    deadline = time.monotonic() + timeout
    while True:
        url = vm_service_url(console.read_text(encoding="utf-8", errors="replace"))
        if url:
            return url
        if process.poll() is not None:
            raise RuntimeError("simctl console closed before the Dart VM was ready")
        if time.monotonic() >= deadline:
            raise TimeoutError("Dart VM service was not announced within 120 seconds")
        time.sleep(0.25)


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
    console = report / "app-console.log"
    print("Installing the prebuilt integration app", flush=True)
    subprocess.run(["xcrun", "simctl", "install", device, str(app)], check=True, timeout=180)
    with console.open("wb") as output:
        launcher = subprocess.Popen(
            ["xcrun", "simctl", "launch", "--console-pty", device, bundle,
             "--enable-dart-profiling", "--disable-vm-service-publication",
             "--start-paused", "--enable-checked-mode", "--verify-entry-points"],
            stdout=output, stderr=subprocess.STDOUT,
        )
        try:
            url = wait_for_service(launcher, console)
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
            # Capture the still-running app, including a failed/blank test UI.
            # flutter drive's default uninstall used to erase this evidence.
            try:
                with (report / "app-screenshot.log").open("wb") as log:
                    subprocess.run(
                        ["xcrun", "simctl", "io", device, "screenshot",
                         str(report / "app-final.png")],
                        stdout=log, stderr=subprocess.STDOUT, timeout=30,
                    )
            finally:
                if launcher.poll() is None:
                    launcher.terminate()
                    try:
                        launcher.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        launcher.kill()
                        launcher.wait(timeout=10)
                for name in ("app-console.log", "task-flow.log"):
                    path = report / name
                    if path.exists():
                        print(f"\n{name}:\n{path.read_text(encoding='utf-8', errors='replace')}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
