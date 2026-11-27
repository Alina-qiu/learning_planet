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


ANNOUNCEMENT = re.compile(
    r"^(?P<time>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{1,9})\s+\w+\s+"
    r"Runner\[(?P<pid>[1-9]\d*):[0-9a-fA-F]+\]\s+.*?The Dart VM service is listening on "
    r"(?P<url>http://127\.0\.0\.1:(?P<port>[1-9]\d{0,4})/[A-Za-z0-9_=-]{1,512}/)(?=\s|$)"
)
LOG_BYTE_LIMIT = 8 * 1024 * 1024


def read_announcements(path, offset):
    """Read complete compact-format lines once, in bounded blocks, including late appends."""
    matches = []
    with path.open("rb") as log:
        log.seek(max(0, offset - 1))
        line_start = offset == 0 or log.read(1) == b"\n"
        end = min(LOG_BYTE_LIMIT, offset + 262144)
        while log.tell() < end:
            start = log.tell()
            line = log.readline(min(8192, end - start))
            if not line:
                break
            if not line.endswith(b"\n") and len(line) < 8192:
                # A writer may finish this entry later. If this is a block
                # boundary the next read starts here with a fresh allowance.
                log.seek(start)
                break
            match = ANNOUNCEMENT.match(line.decode("utf8", "replace")) if line_start else None
            line_start = line.endswith(b"\n")
            if match and int(match["port"]) <= 65535:
                matches.append(match)
        return log.tell(), matches


def runner_log_command(device, kind, last="5m"):
    command = ["xcrun", "simctl", "spawn", device, "log", kind]
    if kind == "show":
        command += ["--last", last]
    predicate = 'process == "Runner"'
    if kind == "stream":
        predicate += ' AND eventMessage CONTAINS "The Dart VM service is listening on"'
    return command + ["--style", "compact", "--predicate", predicate]


def launch_pid(output, bundle):
    matches = re.findall(rf"^{re.escape(bundle)}: ([1-9][0-9]*)$", output, re.MULTILINE)
    if len(matches) != 1:
        raise RuntimeError("simctl launch did not return a unique app PID")
    return int(matches[0])


def wait_for_service(device, pid, report, timeout=120):
    deadline = time.monotonic() + timeout
    recovery_at = deadline - timeout / 2
    # Flutter sends this announcement through os_log. Follow new entries and
    # also query the preceding five minutes in case it was emitted at launch.
    processes = {}
    last_lookup = float("-inf")
    recovery_attempted = False

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
        paths = {name:Path(directory) / name for name in ("stream", "show", "recovery")}
        offsets = dict.fromkeys(paths, 0)
        try:
            while True:
                backlog = False
                for name, path in paths.items():
                    if not path.exists():
                        continue
                    size = path.stat().st_size
                    previous = offsets[name]
                    offsets[name], rows = read_announcements(path, previous)
                    for row in rows:
                        if int(row["pid"]) == pid:
                            url = row["url"]
                            return url
                    backlog |= previous < offsets[name] < min(size, LOG_BYTE_LIMIT)
                    if size >= LOG_BYTE_LIMIT and processes[name].poll() is None:
                        stop(processes[name])
                now = time.monotonic()
                if now >= deadline:
                    raise TimeoutError(f"Dart VM service was not announced within {timeout} seconds")
                for name, path in paths.items():
                    process = processes.get(name)
                    if offsets[name] >= LOG_BYTE_LIMIT or (path.exists() and path.stat().st_size >= LOG_BYTE_LIMIT):
                        continue
                    # Only the regular retained query repeats after exiting.
                    if process is not None and (name != "show" or process.poll() is None):
                        continue
                    # A retained query can stall without emitting any bytes. Halfway
                    # through discovery, allow one fresh snapshot without stopping it.
                    if name == "recovery" and (recovery_attempted or now < recovery_at):
                        continue
                    if name != "stream" and now - last_lookup < 5:
                        continue
                    # Each producer appends. A late writer after simctl exits
                    # must not lose its bytes to truncation on the next probe.
                    kind = "stream" if name == "stream" else "show"
                    if name == "recovery":
                        recovery_attempted = True
                    try:
                        with path.open("ab") as log:
                            processes[name] = subprocess.Popen(runner_log_command(device, kind), stdout=log,
                                                               stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
                    except OSError:
                        if name != "recovery":
                            raise
                    if name == "show":
                        last_lookup = now
                if not backlog:
                    time.sleep(min(0.5, max(0, deadline - time.monotonic())))
        finally:
            pending = sum(1 for process in processes.values() if not stop(process))
            status = "ready" if url else "unavailable"
            counts = {name:path.stat().st_size if path.exists() else 0 for name,path in paths.items()}
            (report / "vm-service.log").write_text(
                f"Runner PID {pid}: VM discovery {status}; stream bytes={counts['stream']}, "
                f"retained bytes={counts['show']}, pending cleanup={pending}; "
                f"recovery attempted={int(recovery_attempted)}, started={int('recovery' in processes)}, "
                f"recovery bytes={counts['recovery']}\n",
                encoding="utf-8")


def collect_runner_log(device, report):
    """Publish fixed announcement markers only. Keep the wider system query private."""
    deadline = time.monotonic() + 30
    with tempfile.TemporaryDirectory() as temp:
        raw = Path(temp) / "compact.log"
        with raw.open("wb") as stream:
            proc = subprocess.Popen(runner_log_command(device, "show", "15m"), stdout=stream,
                                    stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        while proc.poll() is None and time.monotonic() < deadline and raw.stat().st_size < LOG_BYTE_LIMIT:
            time.sleep(.25)
        if proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
        marks = []
        offset = 0
        while offset < min(raw.stat().st_size, LOG_BYTE_LIMIT) and len(marks) < 64:
            new_offset, rows = read_announcements(raw, offset)
            marks.extend(f'{row["time"]} Runner PID {row["pid"]}: VM service announced' for row in rows[:64-len(marks)])
            if new_offset == offset:
                break
            offset = new_offset
        (report / "runner.log").write_text(
            f"Runner log query exit={proc.poll()}, inspected bytes={offset}\n" +
            "".join(mark + "\n" for mark in marks), encoding="utf8")


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
    # CoreSimulator can take more than a minute to acknowledge this one launch.
    # Keep the former 60 + 120 second setup ceiling shared with VM discovery.
    setup_deadline = time.monotonic() + 180
    launch = subprocess.run(
        ["xcrun", "simctl", "launch", device, bundle,
         "--enable-dart-profiling", "--disable-vm-service-publication",
         "--start-paused", "--enable-checked-mode", "--verify-entry-points"],
        capture_output=True, text=True, timeout=120, check=True,
    )
    pid = launch_pid(launch.stdout, bundle)
    (report / "app-launch.log").write_text(f"{bundle}: {pid}\n", encoding="utf-8")
    try:
        remaining = min(120, setup_deadline - time.monotonic())
        if remaining <= 0:
            raise TimeoutError("Simulator launch exhausted the VM setup deadline")
        url = wait_for_service(device, pid, report, timeout=remaining)
        print(f"Dart VM ready; running {driver}", flush=True)
        with tempfile.TemporaryFile() as log:
            # This is the same Dart driver invocation used by Flutter's
            # FlutterDriverService.startTest. Avoid a second device discovery
            # and an unscoped system-log subscription for an existing app.
            dart = Path(os.environ["FLUTTER_ROOT"]) / "bin/cache/dart-sdk/bin/dart"
            try:
                result = subprocess.run(
                    [str(dart), driver],
                    env={**os.environ, "VM_SERVICE_URL": url},
                    stdout=log, stderr=subprocess.STDOUT, timeout=1200 if private_report else 480,
                )
            finally:
                length = log.tell()
                log.seek(max(0, length - 65536))
                if length > 65536:
                    log.readline(65536)  # A partial first line may contain part of an address.
                diagnostic = re.sub(r"(?:https?|wss?)://[^\s<>\"']+", "[address omitted]",
                                    log.read(65536).decode("utf8", "replace"))
                token = url.rstrip("/").rsplit("/", 1)[-1]
                (report / "task-flow.log").write_text(diagnostic.replace(token, "[omitted]"), encoding="utf8")
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
