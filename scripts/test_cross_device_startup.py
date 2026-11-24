"""Exercise AC-01 startup ordering and safe failures without an Apple host."""
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import run_cross_device_sync as runner


class StartupTests(unittest.TestCase):
    def exercise_stages(self, occupied=None, android_result="passed"):
        udid = "10000000-0000-0000-0000-000000000001"
        events = []
        state = {"phase":None, "avd":False, "iphone":False}
        base = {"test":"AC-01", "task_id":"task", "child_id":"child", "family_id":"family",
                "ready_with_zero_wallet":True}
        paid = {"completed":True, "coins":7, "xp":5}

        def report(name, data):
            runner.RESULTS.mkdir(parents=True, exist_ok=True)
            (runner.RESULTS / f"cross_device_sync_{name}.json").write_text(json.dumps(data), encoding="utf-8")

        def launch(command, **kwargs):
            args = [str(arg) for arg in command]
            if args[0] == "node":
                events.append("backend")
                state["phase"] = "initial"
                return Mock(poll=lambda: 0 if state["phase"] == "reader-confirmed" else None, wait=lambda timeout: 0)
            if "bootstatus" in args:
                self.assertIn(udid, args)
                self.assertFalse(state["avd"])
                state["iphone"] = True
                events.append("boot iPhone")
            elif "-avd" in args:
                self.assertEqual(state["phase"], "reader-ready")
                self.assertFalse(state["iphone"])
                self.assertEqual(args[args.index("-cores") + 1], "2")
                self.assertEqual(args[args.index("-memory") + 1], "1536")
                self.assertEqual(args[args.index("-gpu") + 1], "software")
                state["avd"] = True
                events.append("boot Android")
                return Mock(poll=lambda: None if state["avd"] else 0, wait=lambda timeout: 0)
            elif "scripts/run_ios_simulator_flow.py" in args:
                self.assertFalse(state["avd"])
                self.assertTrue(state["iphone"])
                if state["phase"] == "initial":
                    self.assertNotIn("--reuse-installed", args)
                    report("ios_initial", {**base, "device":"ios", "reader_pass":"initial"})
                    state["phase"] = "reader-ready"
                    events.append("initial reader")
                else:
                    self.assertEqual(state["phase"], "writer-complete")
                    self.assertIn("--reuse-installed", args)
                    self.assertIn("Android released", events)
                    report("ios", {**base, **paid, "device":"ios", "reader_pass":"restore",
                                  "offline_state_after_android_completion":True})
                    proof = {"passed":True, "separateLogins":True, "readerSessionRetained":True,
                             "initial":{"status":"ready","coin_balance":0,"frozen_balance":0,"xp":0},
                             "final":{"status":"completed","coin_balance":7,"frozen_balance":0,"xp":5},
                             "childId":"child", "taskId":"task", "blockedAfterWriter":1, "blockedReaderRequests":1,
                             "firstSnapshotAfterReconnectMs":8,
                             "ledger":[{"id":"a","asset_type":"coin","amount":7},{"id":"b","asset_type":"xp","amount":5}],
                             "receipts":[{"kind":"start","outcome":"applied"},{"kind":"complete","outcome":"applied"}]}
                    runner.SERVER_RESULT.write_text(json.dumps(proof), encoding="utf-8")
                    state["phase"] = "reader-confirmed"
                    events.append("restored reader")
            elif "logcat" in args:
                self.assertTrue(state["avd"])
                self.assertIn("both routes", events)
                self.assertEqual(args[args.index("-e") + 1], runner.STARTUP_MARK)
                self.assertEqual(args[-3:], ["LP_STARTUP:I", "flutter:I", "*:S"])
                self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
                events.append("capture startup marks")
                return Mock(poll=lambda:None)
            elif "scripts/run_android_simulator_flow.py" in args:
                self.assertFalse(state["iphone"])
                self.assertTrue(state["avd"])
                self.assertEqual(args[args.index("--serial") + 1], runner.SERIAL)
                self.assertNotIn("--driver", args)
                self.assertIn("screen awake", events)
                self.assertIn("capture startup marks", events)
                self.assertIn("both routes",events)
                state["phase"] = "writer-complete"
                events.append("writer")
            else:
                self.fail("Unexpected launch")
            return Mock(poll=lambda: 0, returncode=0)

        def command(args, timeout, discard=False):
            self.assertGreater(timeout, 0)
            if "start-server" in args:
                self.assertEqual(state["phase"], "initial")
                self.assertFalse(state["avd"] or state["iphone"])
                self.assertTrue(discard)
                events.append("ADB server")
            elif str(args[0]).endswith("adb") and args[-1] == "devices":
                if state["phase"] == "writer-complete":
                    self.assertFalse(state["avd"])
                    events.append("Android released")
                return 0, "List of devices attached\n" + (runner.SERIAL+" offline\n" if occupied == "serial" else "")
            elif "list" in args:
                return 0, json.dumps({"devices":{"iOS":[{"udid":udid,"state":"Shutdown"}]}})
            elif "-accel-check" in args:
                return 0, "accel:\n0\nOK\naccel\n"
            elif "getprop" in args:
                return 0, "1"
            elif "get-state" in args:
                return 0, "device"
            elif args[-4:] == ["svc", "power", "stayon", "true"]:
                events.append("stay awake")
            elif "KEYCODE_WAKEUP" in args:
                self.assertIn("stay awake", events)
                events.append("wakeup requested")
            elif "dumpsys" in args:
                self.assertIn("wakeup requested", events)
                events.append("screen awake")
                return 0, "Power Manager State:\n  mWakefulness=Awake\n"
            elif "--list" in args:
                events.append("both routes")
                return 0, "android tcp:54324 tcp:54324\nandroid tcp:54326 tcp:54326\n"
            elif "kill" in args:
                events.append("stop Android")
                state["avd"] = False
            return 0, ""

        def shutdown(device):
            self.assertEqual(device, udid)
            state["iphone"] = False
            events.append("stop iPhone")

        queries = 0
        def android_status(device):
            nonlocal queries
            self.assertEqual(device, "android")
            queries += 1
            if queries == 1:
                return state["phase"], "confirm_task_and_wallet"
            if android_result == "stalled login":
                return state["phase"], "otp_verify_tapped"
            if android_result == "failed":
                return state["phase"], "failed"
            if android_result == "passed":
                report("android", {**base, **paid, "device":"android"})
                events.append("verified Android report")
            return state["phase"], "confirmed"

        with tempfile.TemporaryDirectory() as temp, contextlib.ExitStack() as stack:
            old_cwd = Path.cwd()
            os.chdir(temp)
            stack.callback(os.chdir, old_cwd)
            runner.APK.parent.mkdir(parents=True)
            runner.APK.touch()
            app = Path("build/ios/iphonesimulator/Runner.app")
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"test.local"}))
            stack.enter_context(patch.dict(os.environ, {"ANDROID_HOME":temp, "FLUTTER_ROOT":temp, "SIMULATOR_ID":udid}))
            stack.enter_context(patch.object(runner.sys, "platform", "darwin"))
            stack.enter_context(patch.object(runner, "control_phase", side_effect=lambda:state["phase"]))
            stack.enter_context(patch.object(runner, "control_status", side_effect=android_status))
            stack.enter_context(patch.object(runner, "control_data", return_value={}))
            stack.enter_context(patch.object(runner, "stop_group"))
            stack.enter_context(patch.object(runner, "shutdown_iphone", side_effect=shutdown))
            stack.enter_context(patch.object(runner, "ports_free", side_effect=lambda:occupied != "port"))
            stack.enter_context(patch.object(runner, "one_probe", side_effect=command))
            stack.enter_context(patch.object(runner.subprocess, "Popen", side_effect=launch))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            if occupied:
                with self.assertRaisesRegex(RuntimeError,"ports already in use"):
                    runner.run()
            elif android_result == "failed":
                with self.assertRaisesRegex(RuntimeError, "assertions failed after confirm_task_and_wallet"):
                    runner.run()
            elif android_result in ("missing", "stalled login"):
                now = [0]
                def advance(_):
                    now[0] += 30
                with patch.object(runner.time, "monotonic", side_effect=lambda:now[0]), patch.object(runner.time, "sleep", side_effect=advance):
                    reason = "Android login timed out after otp_verify_tapped" if android_result == "stalled login" else "Verified Android report timed out"
                    with self.assertRaisesRegex(RuntimeError, reason):
                        runner.run()
                    if android_result == "stalled login":
                        self.assertLess(now[0], 21 * 60)
            else:
                runner.run()
        return events

    def test_staged_boot_and_same_install(self):
        self.assertEqual(self.exercise_stages(), ["backend", "ADB server", "boot iPhone", "initial reader", "stop iPhone",
                         "boot Android", "stay awake", "wakeup requested", "screen awake", "both routes", "capture startup marks", "writer", "verified Android report", "stop Android", "Android released", "boot iPhone",
                         "restored reader", "stop iPhone"])

    def test_failed_or_missing_report_never_starts_the_restored_reader(self):
        for outcome in ("failed", "missing", "stalled login"):
            with self.subTest(outcome=outcome):
                self.assertNotIn("restored reader", self.exercise_stages(android_result=outcome))

    def test_failure_snapshot_only_contains_allowlisted_state_and_counts(self):
        data = {"androidCheckpoint":"otp_received", "private":"private_marker",
                "androidHttp":{"otp":1, "otpOk":1, "verify":True, "verifyOk":-1, "snapshot":"private_marker"}}
        with patch.object(runner, "control_data", return_value=data), \
                patch.object(runner, "one_probe", return_value=(0, "private_marker\n  mWakefulness=Asleep\n")):
            self.assertEqual(str(runner.android_failure("failed", ["adb"])),
                             "failed; checkpoint=otp_received adb=responded power=Asleep HTTP otp=1 otpOk=1 verify=unknown "
                             "verifyOk=unknown snapshot=unknown snapshotOk=unknown")
        with patch.object(runner, "control_data", return_value={}), \
                patch.object(runner, "one_probe", side_effect=subprocess.TimeoutExpired("private_marker", 15)):
            self.assertIn("adb=timed_out power=unknown", str(runner.android_failure("failed", ["adb"])))
        with tempfile.TemporaryDirectory() as temp:
            logfile = Path(temp) / "emulator"
            logfile.write_text("Android emulator version 37.2.13.0\nprivate_marker\n"
                               "vulkan_mode_selected:private_marker gles_mode_selected:swiftshader", encoding="utf8")
            self.assertEqual(runner.renderer_summary(logfile), "Android emulator=37.2.13.0 GLES=swiftshader Vulkan=unknown")
            logfile.write_text("source=android stage=activity_create elapsed_us=80 outcome=ok\n"
                               "LP_STARTUP source=dart stage=first_frame elapsed_us=4 outcome=ok\n"
                               "LP_STARTUP source=dart stage=credentials elapsed_us=7 outcome=error\n"
                               "LP_STARTUP source=dart stage=credentials elapsed_us=7 outcome=ok private_marker\n"
                               "source=android stage=private_marker elapsed_us=1 outcome=ok\n", encoding="utf8")
            self.assertEqual(runner.startup_summary(logfile), "android.activity_create=ok,dart.first_frame=ok,dart.credentials=error")

    def test_occupied_serial_or_port_stops_before_boot(self):
        for occupied in ("port", "serial"):
            with self.subTest(occupied=occupied):
                self.assertEqual(self.exercise_stages(occupied), ["backend", "ADB server"])
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as already_listening:
            already_listening.bind(("127.0.0.1", 0))
            already_listening.listen(1)
            port = already_listening.getsockname()[1]
            self.assertFalse(runner.ports_free(port))
            self.assertFalse(runner.ports_free(port - 1))

    def test_probes_use_regular_files_and_bounded_backoff(self):
        def invoke(command, **kwargs):
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            self.assertNotIn(subprocess.PIPE, [kwargs["stdout"], kwargs["stderr"]])
            if kwargs["stdout"] != subprocess.DEVNULL:
                kwargs["stdout"].write(b"fixture response")
            return subprocess.CompletedProcess(command, 0)
        with patch.object(runner.subprocess, "run", side_effect=invoke):
            self.assertEqual(runner.one_probe(["adb", "start-server"], 5, True), (0, ""))
            self.assertEqual(runner.one_probe(["adb", "devices"], 5), (0, "fixture response"))
        now = [0]
        def sleep(seconds):
            now[0] += seconds
        with patch.object(runner.time, "monotonic", side_effect=lambda:now[0]), patch.object(runner.time, "sleep", side_effect=sleep):
            with patch.object(runner, "one_probe", side_effect=[subprocess.TimeoutExpired("hidden", 1),
                        (1,"private detail"),(0,"List of devices attached\n")]) as run, contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertTrue(runner.probe("inventory", ["adb"], total=10, per_attempt=4, accept=runner.device_list))
                self.assertEqual(run.call_count,3)
                self.assertNotIn("private detail",out.getvalue())
            with patch.object(runner, "one_probe", return_value=(3, "sensitive")), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, r"exceeded 5s after 3 attempts \(exited with code 3\)"):
                    runner.probe("keyguard", ["adb"], total=5)
        self.assertTrue(runner.valid_accel_result(0, "accel:\n0\nusable"))
        self.assertTrue(runner.valid_accel_result(8, "accel:\n8\nunavailable"))
        self.assertFalse(runner.valid_accel_result(8, "unclassified"))
        self.assertFalse(runner.valid_accel_result(1, "accel:\n0\nusable"))

    def test_real_spawn_failure_diagnostics(self):
        root = Path(__file__).resolve().parent.parent
        module = (root / "scripts/fixtures/auth_backend.mjs").as_uri()
        node = shutil.which("node")
        self.assertIsNotNone(node)
        code = ("import {withAuthBackend} from " + json.dumps(module) +
                "; try { await withAuthBackend(() => {}); } catch (e) { console.error(e.message); process.exitCode=1; }")
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / "supabase/templates").mkdir(parents=True)
            for name in ["supabase/config.toml", "supabase/templates/email_otp.html"]:
                shutil.copyfile(root / name, folder / name)
            # Node itself acts as a real version executable: 'node version'
            # runs this file. No shell quoting or platform-specific shim.
            for binary, body, expected in [
                (str(folder/"missing"), "", "errno=ENOENT exit=none"),
                (node, "console.error('private-marker'); process.exitCode=7", "exit=7 signal=none"),
                (node, "setTimeout(() => {}, 8000)", "errno=ETIMEDOUT exit=none"),
            ]:
                with self.subTest(expected=expected):
                    (folder/"version").write_text(body, encoding="utf-8")
                    result = subprocess.run([node,"--input-type=module","-e",code], cwd=folder, capture_output=True,
                                            text=True, timeout=15, env={**os.environ,"GOTRUE_BIN":binary,
                                            "AUTH_VERSION_TIMEOUT_MS":"1000","CROSS_DEVICE_STARTUP_STAGES":"1"})
                    self.assertEqual(result.returncode,1)
                    self.assertIn(expected,result.stderr)
                    self.assertNotIn("private-marker",result.stderr)
                    self.assertNotIn(str(folder),result.stderr)
                    log = folder/"server"
                    # An unhandled Node exception adds this prefix in the real coordinator.
                    log.write_text(result.stdout+"Error: "+result.stderr, encoding="utf-8")
                    diagnostic = runner.startup_error(log,"server","exited with code 1")
                    self.assertIn("auth-version",diagnostic)
                    self.assertIn("timeout_ms=1000",diagnostic)
                    self.assertNotIn("private-marker",diagnostic)


if __name__ == "__main__":
    unittest.main()
