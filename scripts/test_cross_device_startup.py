"""Exercise AC-01 startup ordering and safe failures without an Apple host."""
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import run_cross_device_sync as runner


class StartupTests(unittest.TestCase):
    def test_serial_boot_and_reader_before_writer(self):
        udid = "10000000-0000-0000-0000-000000000001"
        events = []
        class WriterStarted(Exception):
            pass

        def launch(command, **kwargs):
            args = [str(arg) for arg in command]
            if args[0] == "node":
                events.append("start backend")
                self.assertEqual(kwargs["env"]["CROSS_DEVICE_STARTUP_STAGES"], "1")
            elif "bootstatus" in args:
                self.assertEqual(events[-1], "control initial")
                events.append("boot iPhone")
                return Mock(poll=Mock(side_effect=[None, 0]), returncode=0)
            elif "-avd" in args:
                self.assertEqual(events[-1], "boot iPhone")
                self.assertEqual(args[args.index("-cores")+1], "2")
                self.assertEqual(args[args.index("-memory")+1], "1536")
                events.append("boot Android")
            elif "scripts/run_ios_simulator_flow.py" in args:
                self.assertEqual(events[-1], "Android ready")
                events.append("start iPhone reader")
            elif "drive" in args:
                self.assertEqual(events[-1], "reader ready")
                events.append("start Android writer")
                raise WriterStarted
            else:
                self.fail("Unexpected startup command")
            return Mock(poll=Mock(return_value=None))

        def invoke(command, **_kwargs):
            output = ""
            if "list" in command:
                output = json.dumps({"devices":{"iOS":[{"udid":udid,"state":"Shutdown"}]}})
            elif "getprop" in command:
                events.append("Android ready")
                output = "1"
            return subprocess.CompletedProcess(command, 0, output, "")

        phases = iter([None, None, "initial", "initial", "reader-ready"])
        def phase():
            value = next(phases)
            if value == "initial" and events == ["start backend"]:
                events.append("control initial")
            if value == "reader-ready":
                self.assertEqual(events[-1], "start iPhone reader")
                events.append("reader ready")
            return value

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
            stack.enter_context(patch.object(runner, "control_phase", side_effect=phase))
            stack.enter_context(patch.object(runner, "stop_group"))
            stack.enter_context(patch.object(runner.time, "sleep"))
            stack.enter_context(patch.object(runner.subprocess, "Popen", side_effect=launch))
            stack.enter_context(patch.object(runner.subprocess, "check_output", return_value=""))
            stack.enter_context(patch.object(runner.subprocess, "run", side_effect=invoke))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            with self.assertRaises(WriterStarted):
                runner.run()
        self.assertEqual(events, ["start backend", "control initial", "boot iPhone", "boot Android",
                                  "Android ready", "start iPhone reader", "reader ready", "start Android writer"])

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
