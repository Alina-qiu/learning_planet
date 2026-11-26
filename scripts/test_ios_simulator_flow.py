"""Verify same-PID VM discovery and preservation of simulator driver outcomes."""
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


class VmDiscoveryTests(unittest.TestCase):
    def simulate(self, scenario, timeout):
        # A simctl child may still append a retained entry after its host
        # query timed out. Keep the first descriptor open across supersession.
        now = [0.0]
        outputs = []
        processes = []
        announced = False
        url = "http://127.0.0.1:1234/fixture=/"

        class FakeProcess:
            def __init__(self, name):
                self.name = name
                self.code = None

            def poll(self):
                return self.code

            def kill(self):
                self.code = -9
                if not (scenario == "late retained" and self is processes[1] and not announced):
                    outputs[processes.index(self)].close()

            def wait(self, timeout):
                if timeout < 0 or timeout > 1:
                    raise AssertionError("unbounded probe cleanup")
                if scenario == "stalled cleanup":
                    raise subprocess.TimeoutExpired("fixture",timeout)
                if self.code is None:
                    raise AssertionError("unbounded process wait")

        def start(args, stdout, **_):
            self.assertIn(args[5], ("show", "stream"))
            self.assertIn("--style", args)
            self.assertEqual(args[6:8], ["--last", "5m"] if args[5] == "show" else ["--style","compact"])
            child = FakeProcess(args[5])
            outputs.append(os.fdopen(os.dup(stdout.fileno()), "ab", buffering=0))
            processes.append(child)
            outputs[-1].write(f"Runner[999:aaa] The Dart VM service is listening on {url}\n".encode())
            return child

        def advance(seconds):
            nonlocal announced
            self.assertGreater(seconds, 0)
            now[0] += seconds
            live, retained = outputs[:2]
            if not announced and scenario == "stream" and now[0] >= 1:
                live.write(f"Runner[123:aaa] The Dart VM service is listening on {url}\n".encode())
                announced = True
            if not announced and scenario == "late retained" and len(processes) == 3:
                self.assertEqual(processes[1].poll(), -9)
                retained.write(f"Runner[123:aaa] The Dart VM service is listening on {url}\n".encode())
                retained.close()
                announced = True

        with tempfile.TemporaryDirectory() as folder, \
                patch.object(runner.time, "monotonic", side_effect=lambda:now[0]), \
                patch.object(runner.time, "sleep", side_effect=advance), \
                patch.object(runner.subprocess, "Popen", side_effect=start):
            try:
                if scenario in ("wrong process", "stalled cleanup"):
                    with self.assertRaises(TimeoutError):
                        runner.wait_for_service("device",123,Path(folder),timeout)
                    self.assertEqual(now[0], timeout)
                else:
                    self.assertEqual(runner.wait_for_service("device",123,Path(folder),timeout),url)
                    self.assertLess(now[0], timeout)
                self.assertTrue(all(p.poll() is not None for p in processes))
                log = (Path(folder) / "vm-service.log").read_text(encoding="utf8")
                self.assertNotIn(url, log)
                if scenario == "stalled cleanup":
                    self.assertIn("pending cleanup=2", log)
            finally:
                for handle in outputs:
                    handle.close()

    def test_live_announcement_before_retained_query_exits(self):
        self.simulate("stream",5)

    def test_late_retained_entry_survives_replacement_query(self):
        self.simulate("late retained",35)

    def test_slow_probe_cleanup_cannot_extend_discovery_deadline(self):
        self.simulate("stalled cleanup",5)

    def test_other_pid_reaches_original_deadline(self):
        self.simulate("wrong process",5)


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
