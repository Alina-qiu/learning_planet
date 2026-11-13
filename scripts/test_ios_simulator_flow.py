"""Driver outcomes must survive failures in optional simulator diagnostics."""
import contextlib
import io
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import run_ios_simulator_flow as runner


class DriverOutcomeTests(unittest.TestCase):
    def exercise(self, driver_result, screenshot_error):
        with tempfile.TemporaryDirectory() as folder, contextlib.chdir(folder):
            app = Path("build/ios/iphonesimulator/Runner.app")
            app.mkdir(parents=True)
            with (app / "Info.plist").open("wb") as output:
                plistlib.dump({"CFBundleIdentifier": "fixture.app"}, output)

            def execute(command, **kwargs):
                if "launch" in command:
                    return subprocess.CompletedProcess(command, 0, "fixture.app: 123\n", "")
                if "screenshot" in command:
                    self.assertEqual(kwargs["timeout"], 30)
                    raise screenshot_error
                if command[-1] == "test_driver/task_flow_driver.dart":
                    self.assertEqual(kwargs["env"]["VM_SERVICE_URL"], "http://127.0.0.1:1234/token=/")
                    if isinstance(driver_result, Exception):
                        raise driver_result
                    return subprocess.CompletedProcess(command, driver_result)
                return subprocess.CompletedProcess(command, 0)

            with (
                patch.object(runner.sys, "platform", "darwin"),
                patch.dict(os.environ, {"SIMULATOR_ID": "12345678-1234-1234-1234-123456789abc", "FLUTTER_ROOT": folder}),
                patch.object(runner, "wait_for_service", return_value="http://127.0.0.1:1234/token=/"),
                patch.object(runner.subprocess, "run", side_effect=execute),
                contextlib.redirect_stdout(io.StringIO()) as output,
            ):
                result = runner.main()
                self.assertIn("Optional final screenshot unavailable", output.getvalue())
                return result

    def test_success_survives_screenshot_timeout(self):
        self.assertEqual(self.exercise(0, subprocess.TimeoutExpired("screenshot", 30)), 0)

    def test_failed_assertions_stay_failed_after_screenshot_timeout(self):
        self.assertEqual(self.exercise(1, subprocess.TimeoutExpired("screenshot", 30)), 1)

    def test_success_survives_screenshot_os_error(self):
        self.assertEqual(self.exercise(0, OSError("simctl unavailable")), 0)

    def test_failed_assertions_stay_failed_after_screenshot_os_error(self):
        self.assertEqual(self.exercise(1, OSError("simctl unavailable")), 1)

    def test_driver_timeout_is_not_replaced_by_screenshot_timeout(self):
        failure = subprocess.TimeoutExpired("driver", 480)
        with self.assertRaises(subprocess.TimeoutExpired) as caught:
            self.exercise(failure, subprocess.TimeoutExpired("screenshot", 30))
        self.assertIs(caught.exception, failure)


if __name__ == "__main__":
    unittest.main()
