"""Prepare an exact iOS universal runtime for x86_64 simulator checks.

Only used on disposable Apple Silicon CI hosts. No app dependencies, signing
configuration, or installed runtime are removed or substituted.
"""
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys


def compatible_runtime(inventory, version):
    identifier = "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-")
    return next((runtime for runtime in inventory["runtimes"]
                 if runtime.get("identifier") == identifier
                 and runtime.get("isAvailable") is True
                 and "x86_64" in runtime.get("supportedArchitectures", [])), None)


def main():
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise RuntimeError("This setup requires an Apple Silicon macOS host")
    version = os.environ["IOS_VERSION"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+", version):
        raise ValueError("Expected a specific major.minor iOS runtime")
    report = Path("build/ios-simulator")
    report.mkdir(parents=True, exist_ok=True)

    def inventory(name):
        raw = subprocess.check_output(
            ["xcrun", "simctl", "list", "runtimes", "--json"], text=True, timeout=60,
        )
        (report / name).write_text(raw, encoding="utf-8")
        return json.loads(raw)

    # Verify an existing Rosetta installation; this does not run its installer
    # or accept a new software license on behalf of the user.
    with (report / "rosetta-check.log").open("wb") as output:
        subprocess.run(["/usr/bin/arch", "-x86_64", "/usr/bin/true"],
                       stdout=output, stderr=subprocess.STDOUT, check=True, timeout=30)
    before = inventory("runtimes-before.json")
    if compatible_runtime(before, version) is None:
        path = report / "universal-runtime.log"
        try:
            with path.open("wb") as output:
                subprocess.run(
                    ["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", version,
                     "-architectureVariant", "universal"],
                    stdout=output, stderr=subprocess.STDOUT, check=True, timeout=900,
                )
        finally:
            if path.exists():
                print(path.read_text(encoding="utf-8", errors="replace"), flush=True)
    after = inventory("runtimes-after.json")
    runtime = compatible_runtime(after, version)
    if runtime is None:
        raise RuntimeError(f"iOS {version} has no available x86_64 runtime after preparation")
    (report / "universal-runtime.json").write_text(json.dumps({
        "runtime": runtime["identifier"], "version": version,
        "supported_architectures": runtime["supportedArchitectures"],
        "host_architecture": platform.machine(), "rosetta_available": True,
        "scope": "Runtime preparation only; app build and native assertions must still pass",
    }, indent=2) + "\n", encoding="utf-8")
    print(f"Required iOS {version} x86_64 runtime is available", flush=True)


if __name__ == "__main__":
    main()
