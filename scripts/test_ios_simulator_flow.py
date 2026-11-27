"""Verify same-PID VM discovery and preservation of simulator driver outcomes."""
import contextlib
import io
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import run_ios_simulator_flow as runner


class VmDiscoveryTests(unittest.TestCase):
    def simulate(self, scenario, timeout):
        # A simctl child may still append a retained entry after its host
        # query timed out. Keep the first descriptor open across supersession.
        now = [0.0]
        outputs = []
        processes = []
        retained_paths = []
        announced = False
        url = "http://127.0.0.1:1234/fixture=/"
        stamp = "2026-11-27 04:37:24.122 Df "
        def entry(pid, address=url):
            return f"{stamp}Runner[{pid}:11c87] (Flutter) flutter: The Dart VM service is listening on {address}\n".encode()

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
            if scenario == "fresh query cannot start" and args[5] == "show" and retained_paths:
                retained_paths.append(Path(stdout.name))
                raise OSError("extra probe unavailable")
            child = FakeProcess(args[5])
            outputs.append(os.fdopen(os.dup(stdout.fileno()), "ab", buffering=0))
            processes.append(child)
            if args[5] == "show":
                self.assertEqual(args[-1], 'process == "Runner"')
                retained_paths.append(Path(stdout.name))
                if scenario in ("second query succeeds", "second query wrong pid"):
                    if len(retained_paths) == 2:
                        self.assertIsNone(processes[1].poll())
                        self.assertNotEqual(retained_paths[0], retained_paths[1])
                        self.assertEqual(retained_paths[0].stat().st_size, 0)
                        self.assertLessEqual(now[0], timeout / 2 + .5)
                        outputs[-1].write(entry(123 if scenario == "second query succeeds" else 999))
                        child.code = 0
                        outputs[-1].close()
                    return child
            else:
                self.assertIn("eventMessage CONTAINS", args[-1])
            outputs[-1].write(entry(999))
            if scenario == "broad early line" and args[5] == "show":
                outputs[-1].write(entry(123))
                outputs[-1].write(b"unrelated lifecycle log\n" * 15000)
            return child

        def advance(seconds):
            nonlocal announced
            self.assertGreater(seconds, 0)
            now[0] += seconds
            live, retained = outputs[:2]
            if not announced and scenario == "stream" and now[0] >= 1:
                live.write(entry(123))
                announced = True
            if scenario == "late retained" and len(processes) == 2:
                processes[1].code = 0
            if not announced and scenario == "late retained" and len(processes) == 3:
                self.assertEqual(processes[1].poll(), 0)
                retained.write(entry(123))
                retained.close()
                announced = True
            if not announced and scenario in ("slow retained", "fresh query cannot start") and now[0] >= 31:
                self.assertEqual(len(retained_paths), 2)
                self.assertIsNone(processes[1].poll())
                retained.write(entry(123))
                announced = True

        with tempfile.TemporaryDirectory() as folder, \
                patch.object(runner.time, "monotonic", side_effect=lambda:now[0]), \
                patch.object(runner.time, "sleep", side_effect=advance), \
                patch.object(runner.subprocess, "Popen", side_effect=start):
            try:
                if scenario in ("wrong process", "second query wrong pid", "stalled cleanup"):
                    with self.assertRaises(TimeoutError):
                        runner.wait_for_service("device",123,Path(folder),timeout)
                    self.assertEqual(now[0], timeout)
                else:
                    self.assertEqual(runner.wait_for_service("device",123,Path(folder),timeout),url)
                    self.assertLess(now[0], timeout)
                self.assertTrue(all(p.poll() is not None for p in processes))
                if scenario in ("second query succeeds", "second query wrong pid"):
                    self.assertEqual(len(retained_paths), 2)
                    self.assertTrue(all(not path.exists() for path in retained_paths))
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

    def test_retained_query_finds_early_announcement_followed_by_more_than_a_log_tail(self):
        self.simulate("broad early line", 5)

    def test_running_retained_query_can_finish_after_thirty_seconds(self):
        self.simulate("slow retained", 35)

    def test_fresh_query_finds_announcement_while_first_query_has_no_output(self):
        self.simulate("second query succeeds", 120)

    def test_fresh_query_ignores_other_pid_and_is_not_restarted(self):
        self.simulate("second query wrong pid", 120)

    def test_slow_first_query_survives_optional_probe_launch_failure(self):
        self.simulate("fresh query cannot start", 35)

    def test_slow_probe_cleanup_cannot_extend_discovery_deadline(self):
        self.simulate("stalled cleanup",5)

    def test_other_pid_reaches_original_deadline(self):
        self.simulate("wrong process",5)

    def test_filtered_records_require_real_process_prefix_loopback_and_valid_port(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "raw"
            valid = "2026-11-27 04:37:24.122 Df Runner[22310:11c87] (Flutter) flutter: The Dart VM service is listening on "
            local = "http://127.0.0.1:1234/fixture=/"
            path.write_text(valid + local + "\n" + valid.replace("Runner[", "Other[") + valid + local + "\n" +
                            valid + "http://example.test:1234/fixture=/\n" + valid + "http://127.0.0.1:99999/fixture=/\n" +
                            valid + local + "another-segment\n", encoding="utf8")
            offset, rows = runner.read_announcements(path, 0)
            self.assertEqual([(m["pid"], m["url"]) for m in rows], [("22310", local)])
            with path.open("ab") as stream:
                stream.write((valid + "http://127.0.0.1:12").encode())
            self.assertEqual(runner.read_announcements(path, offset), (offset, []))
            with path.open("ab") as stream:
                stream.write(b"34/fixture=/\n")
            self.assertEqual(runner.read_announcements(path, offset)[1][0]["url"], local)

    def test_public_runner_diagnostic_keeps_only_the_timestamp_pid_and_announcement(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def start(args, stdout, **kwargs):
                self.assertEqual(args, runner.runner_log_command("target", "show", "15m"))
                stdout.write(b"unrelated message with another-secret\n"
                             b"2026-11-27 04:37:24.122 Df Runner[22310:11c87] (Flutter) flutter: "
                             b"The Dart VM service is listening on http://127.0.0.1:1234/private-token=/\n")
                return Mock(poll=lambda: 0)
            with patch.object(runner.subprocess, "Popen", side_effect=start):
                runner.collect_runner_log("target", root)
            lines = (root / "runner.log").read_text("utf8").splitlines()
            self.assertEqual(lines[1:], ["2026-11-27 04:37:24.122 Runner PID 22310: VM service announced"])
            self.assertNotRegex("\n".join(lines), "127[.]0|private-token|another-secret")


class DriverOutcomeTests(unittest.TestCase):
    def exercise(self, driver_result, screenshot_error, launch_delay=0, launch_output="fixture.app: 123\n"):
        with tempfile.TemporaryDirectory() as folder, contextlib.chdir(folder):
            app = Path("build/ios/iphonesimulator/Runner.app")
            app.mkdir(parents=True)
            with (app / "Info.plist").open("wb") as output:
                plistlib.dump({"CFBundleIdentifier": "fixture.app"}, output)

            now = [0.0]
            launches = []
            def execute(command, **kwargs):
                if "launch" in command:
                    self.assertEqual(kwargs["timeout"], 120)
                    self.assertTrue(kwargs["check"])
                    self.assertFalse(launches)
                    launches.append(command)
                    if isinstance(launch_output, Exception):
                        raise launch_output
                    now[0] += launch_delay
                    return subprocess.CompletedProcess(command, 0, launch_output, "")
                if "screenshot" in command:
                    self.assertEqual(kwargs["timeout"], 30)
                    raise screenshot_error
                if command[-1] == "test_driver/task_flow_driver.dart":
                    self.assertEqual(kwargs["env"]["VM_SERVICE_URL"], "http://127.0.0.1:1234/token=/")
                    kwargs["stdout"].write(b"Dart driver http://127.0.0.1:1234/token=/ token=\n")
                    if isinstance(driver_result, Exception):
                        raise driver_result
                    return subprocess.CompletedProcess(command, driver_result)
                return subprocess.CompletedProcess(command, 0)

            with (
                patch.object(runner.sys, "platform", "darwin"),
                patch.dict(os.environ, {"SIMULATOR_ID": "12345678-1234-1234-1234-123456789abc", "FLUTTER_ROOT": folder}),
                patch.object(runner.time, "monotonic", side_effect=lambda: now[0]),
                patch.object(runner, "wait_for_service", return_value="http://127.0.0.1:1234/token=/") as discover,
                patch.object(runner.subprocess, "run", side_effect=execute),
                contextlib.redirect_stdout(io.StringIO()) as output,
            ):
                result = runner.main()
                self.assertEqual(len(launches), 1)
                self.assertEqual(discover.call_args.kwargs["timeout"], min(120, 180-launch_delay))
                self.assertIn("Optional final screenshot unavailable", output.getvalue())
                self.assertNotIn("token=", output.getvalue())
                self.assertNotIn("127.0.0.1", Path("build/ios-simulator/task-flow.log").read_text("utf8"))
                return result

    def test_success_survives_screenshot_timeout(self):
        self.assertEqual(self.exercise(0, subprocess.TimeoutExpired("screenshot", 30)), 0)

    def test_74_second_launch_uses_the_remaining_106_seconds_for_discovery(self):
        self.assertEqual(self.exercise(0, OSError("screenshot unavailable"), launch_delay=74), 0)

    def test_nonzero_exit_missing_or_ambiguous_launch_pid_does_not_start_a_driver(self):
        for output in ("other.app: 123\n", "fixture.app: 123\nfixture.app: 456\n", "fixture.app: 0\n"):
            with self.subTest(output=output), self.assertRaisesRegex(RuntimeError, "unique app PID"):
                self.exercise(0, OSError(), launch_output=output)
        failure = subprocess.CalledProcessError(4, ["simctl", "launch"])
        with self.assertRaises(subprocess.CalledProcessError) as error:
            self.exercise(0, OSError(), launch_output=failure)
        self.assertIs(error.exception, failure)

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
