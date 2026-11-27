import copy
import io
import itertools
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
from uuid import uuid4

from run_ios_quiet_receipt import (BUNDLE, embedded_entitlement, installed_entitlements, log_records, payload,
                                   push_entitlement, run, simulator_log, stage_observations, verify, wait_for_ready)


class QuietReceiptDiagnosticTests(unittest.TestCase):
    def test_actual_installed_executable_embedded_entitlements_survive_missing_code_signature_plist(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / "Runner.app"
            app.mkdir()
            info = {"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "Runner", "UIBackgroundModes": ["remote-notification"]}
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            section = plistlib.dumps({"aps-environment": "development", "private-field": "secret value"}) + b"\0"
            (app / "Runner").write_bytes(b"P" * 32 + section)
            layout = ("Section\n  sectname __other\n  segname __TEXT\n  size 0x2\n  offset 0\n"
                      f"Section\n  sectname __entitlements\n  segname __TEXT\n  size {len(section):#x}\n  offset 32\n")
            commands = [str(app).encode(), b"", b"arm64\n", layout.encode()]
            with patch("run_ios_quiet_receipt.command_output", side_effect=commands) as invoke:
                result = installed_entitlements("target")
                self.assertEqual(invoke.call_args_list[0].args, ("xcrun", "simctl", "get_app_container", "target", BUNDLE, "app"))
                self.assertEqual(invoke.call_args_list[-1].args[-1], str(app / "Runner"))
            self.assertTrue(result["remoteNotificationMode"])
            self.assertEqual(result["codeSignature"]["status"], "noPlist")
            self.assertEqual(result["machOTextSections"]["arm64"]["aps-environment"], "development")
            self.assertNotIn("secret", json.dumps(result))
            (app / "Runner").write_bytes(b"truncated")
            with patch("run_ios_quiet_receipt.command_output", return_value=layout.encode()):
                self.assertEqual(embedded_entitlement(app / "Runner")["status"], "invalidSection")

    def test_signed_plist_remains_available_when_macho_tools_fail(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / "Runner.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "Runner"}))
            (app / "Runner").write_bytes(b"fixture")
            signed = plistlib.dumps({"aps-environment": "production"})
            with patch("run_ios_quiet_receipt.command_output", side_effect=[str(app).encode(), signed, OSError()]):
                result = installed_entitlements("target")
            self.assertEqual(result["codeSignature"]["aps-environment"], "production")
            self.assertTrue(result["machOInspectionIncomplete"])

    def test_inspection_reports_absent_unreadable_or_unexpected_entitlements_distinctly(self):
        self.assertEqual(push_entitlement(plistlib.dumps({}))["aps-environment"], "absent")
        self.assertEqual(push_entitlement(plistlib.dumps({"aps-environment": "secret"}))["aps-environment"], "unexpected")
        self.assertEqual(push_entitlement(b"<?xml bad")["status"], "invalidPlist")
        with patch("run_ios_quiet_receipt.command_output", return_value=b"Section\n sectname __data\n segname __DATA\n"):
            self.assertEqual(embedded_entitlement(Path("unused"))["status"], "sectionAbsent")

    def test_log_projection_is_bundle_scoped_bounded_and_does_not_copy_tokens(self):
        row = {"processImagePath": "/usr/libexec/dasd", "timestamp": "2026-11-27 08:07:06.23+0000",
               "eventMessage": f"Denied background push for {BUNDLE} token=private-long-token"}
        lines = ([b"noise", json.dumps({**row, "eventMessage": "Denied push for another app"}).encode(),
                  json.dumps({**row, "processImagePath": "/tmp/Other"}).encode()]
                 + [json.dumps(row).encode()] * 85)
        result = log_records(b"\n".join(lines))
        self.assertEqual((result["matchedRecordsRead"], len(result["records"])), (85, 80))
        self.assertEqual(result["records"][0], {"process": "dasd", "timestamp": row["timestamp"],
                                                "terms": ["denied", "background", "push"]})
        self.assertNotIn("private", json.dumps(result))

    def test_log_capture_queries_selected_device_with_limit_and_deadline(self):
        proc = Mock(stdout=io.BytesIO(b"X" * (600 * 1024)), pid=452, wait=Mock(return_value=-9))
        proc_context = Mock()
        proc_context.__enter__ = Mock(return_value=proc)
        proc_context.__exit__ = Mock(return_value=False)
        with patch("run_ios_quiet_receipt.subprocess.Popen", return_value=proc_context) as start, \
                patch("run_ios_quiet_receipt.os.name", "nt"), patch("run_ios_quiet_receipt.time.monotonic", return_value=500):
            item = simulator_log("dedicated-udid", 0)
        args = start.call_args.args[0]
        self.assertEqual(args[:4], ["xcrun", "simctl", "spawn", "dedicated-udid"])
        self.assertIn(BUNDLE, args[-1])
        self.assertIn("240s", args)
        self.assertTrue(item["byteLimitReached"])
        self.assertEqual(proc.stdout.tell(), item["byteLimit"] + 1)
        proc.kill.assert_called_once()

    def test_unassociated_fetch_stale_or_mismatched_payload_cannot_identify_a_message(self):
        current = {"run": str(uuid4()), "source": "system"}
        ids = {case: str(uuid4()) for case in ("quiet", "allowed")}
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            events = {"host-fetch": {"state": -1, "count": 1, "secret": "never copy"},
                      "registration": {"callback": "registered", "registered": True, "token": "never copy"},
                      "app-quiet": {"message": ids["allowed"], "state": 2},
                      "entered-quiet": {"message": ids["quiet"], "state": 2, "run": str(uuid4())},
                      "claimed-quiet": {"message": ids["quiet"], "state": 2, "source": "native"},
                      "app-unmatched": {"state": 2, "count": 1, "payload": "never copy"},
                      "app-allowed": {"message": ids["allowed"], "state": 2}}
            for name, data in events.items():
                (directory / (name + ".json")).write_text(json.dumps({**current, **data}), encoding="utf8")
            ready = {**current, "ids": ids}
            result = stage_observations(directory, ready, "system", {"quiet": {}})
            self.assertEqual(result["observedStagesBySentCase"], {"quiet": []})
            self.assertEqual(set(result["events"]), {"registration", "host-fetch", "app-unmatched"})
            self.assertNotIn("never copy", json.dumps(result))
            self.assertEqual(stage_observations(directory, ready, "native", {})["status"], "noMatchingReady")


class QuietReceiptHostTests(unittest.TestCase):
    def run_fixture(self, case_result):
        with tempfile.TemporaryDirectory() as temp:
            prior = os.getcwd()
            os.chdir(temp)
            try:
                return self.exercise_host(Path(temp), case_result)
            finally:
                os.chdir(prior)

    def exercise_host(self, root, case_result):
        (root / "ios/Runner.xcworkspace").mkdir(parents=True)
        installed = root / "build/ios/iphonesimulator/Runner.app"
        installed.mkdir(parents=True)
        (installed / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": BUNDLE}))
        directory = root / "Documents/ac09-receipt"
        directory.mkdir(parents=True)
        report = root / "report"
        ids = {case: str(uuid4()) for case in ("quiet", "scope", "expired", "allowed")}
        device = str(uuid4())
        ready = {"run": str(uuid4()), "scope": str(uuid4()), "source": "system", "state": 0, "pid": 111,
                 "ids": ids, "anchor": 1773057600000, "scheduled": 1773057510000, "registrationRequested": True}
        def emit(name, **fields):
            row = {"run": ready["run"], "source": "system", **fields}
            (directory / (name + ".json")).write_text(json.dumps(row), encoding="utf8")
        emit("background", state=2)
        emit("registration", callback="registered", registered=True)
        emit("host-fetch", count=1, state=2)
        emit("complete", delivered=[ids["allowed"]], seen=[ids["allowed"]],
             quietSuppressed=True, scopeRejected=True, expiredRejected=True)
        def simulator(cmd, **kwargs):
            if "push" in cmd:
                data = json.loads(kwargs["input"])
                case = next(k for k in ids if ids[k] == data["message_id"])
                entry = {"state": 2, "message": ids[case]}
                emit("app-" + case, **entry)
                if case_result == "timeout":
                    return subprocess.CompletedProcess(cmd, 0)
                emit("entered-" + case, **entry)
                emit("claimed-" + case, **entry, handled=True)
                emit(case, **entry, result=0 if case == "allowed" else 1, aps=data["aps"],
                     payload={k: v for k, v in data.items() if k != "aps"})
                if case_result == "invoked":
                    emit("invoked-" + case, **entry)
            return subprocess.CompletedProcess(cmd, 0)
        devices = {"devices": {"test-runtime": [{"state": "Booted", "udid": device, "name": "iPhone 18"}]}}
        process = Mock(poll=Mock(return_value=None), wait=Mock(return_value=0))
        with patch("run_ios_quiet_receipt.wait_for_ready", return_value=(directory, ready)), \
                patch("run_ios_quiet_receipt.subprocess.Popen", return_value=process), \
                patch("run_ios_quiet_receipt.subprocess.check_output", side_effect=[json.dumps(devices), "Runner: 111"]), \
                patch("run_ios_quiet_receipt.subprocess.run", side_effect=simulator), \
                patch("run_ios_quiet_receipt.installed_entitlements", return_value={"inspected": True}) as signature, \
                patch("run_ios_quiet_receipt.simulator_log", return_value={"records": []}) as logs, \
                patch("run_ios_quiet_receipt.time.monotonic", side_effect=itertools.count()), \
                patch("run_ios_quiet_receipt.time.sleep"):
            if case_result == "timeout":
                with self.assertRaisesRegex(TimeoutError, "UIKit callback for quiet"):
                    run(device, report, "system")
            elif case_result == "invoked":
                with self.assertRaisesRegex(ValueError, "Test-invoked"):
                    run(device, report, "system")
            else:
                run(device, report, "system")
            signature.assert_called_once_with(device)
            self.assertEqual(logs.call_args.args[0], device)
        return {p.stem: json.loads(p.read_bytes()) for p in report.glob("*.json")}

    def test_system_timeout_keeps_app_and_system_stages_without_creating_a_pass(self):
        result = self.run_fixture("timeout")
        self.assertNotIn("result", result)
        self.assertEqual(result["app-observations"]["observedStagesBySentCase"], {"quiet": ["appPayload"]})
        self.assertTrue(result["installed-entitlements"]["inspected"])
        self.assertIn("records", result["simulator-push-log"])
        self.assertTrue(result["registration"]["registered"])

    def test_passing_system_report_keeps_all_four_correlated_stages(self):
        result = self.run_fixture("success")
        stages = result["app-observations"]["observedStagesBySentCase"]
        self.assertTrue(result["result"]["passed"])
        self.assertEqual(set(stages), {"quiet", "scope", "expired", "allowed"})
        for observed in stages.values():
            self.assertEqual(observed, ["appPayload", "pluginEntry", "pluginClaim", "pluginCompletion"])
        self.assertIn("simulator-push-log", result)

    def test_test_invocation_on_disk_cannot_be_used_for_system_delivery(self):
        self.assertNotIn("result", self.run_fixture("invoked"))


class QuietReceiptEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.ready = {"run": str(uuid4()), "scope": str(uuid4()), "state": 0, "source": "system", "registrationRequested": True,
                      "anchor": 1773057600000, "scheduled": 1773057510000,
                      "ids": {k: str(uuid4()) for k in ("quiet", "scope", "expired", "allowed")}}
        self.sent = {k: payload(self.ready, k, 1000) for k in self.ready["ids"]}
        self.callbacks = {k: {"run": self.ready["run"], "source": "system", "message": p["message_id"],
                          "payload": {f: v for f, v in p.items() if f != "aps"},
                          "aps": p["aps"], "state": 2, "result": 0 if k == "allowed" else 1}
                          for k, p in self.sent.items()}
        allowed = [self.ready["ids"]["allowed"]]
        self.complete = {"run": self.ready["run"], "source": "system", "delivered": allowed, "seen": allowed,
                         "quietSuppressed": True, "scopeRejected": True, "expiredRejected": True}
        self.entries = {case: {k: r[k] for k in ("state", "source", "message", "run")} for case, r in self.callbacks.items()}
        self.claims = {case: {**row, "handled": True} for case, row in self.entries.items()}
        self.invocations = {}

    def validate(self, source="system"):
        verify(self.ready, self.sent, self.callbacks, self.complete, source=source,
               entries=self.entries, claims=self.claims, invocations=self.invocations)

    def test_native_result_requires_its_own_delegate_completion(self):
        self.ready["registrationRequested"] = False
        for row in (self.ready, self.complete, *self.entries.values(), *self.callbacks.values(), *self.claims.values()):
            row["source"] = "native"
        self.invocations = {k: {**entry, "result": self.callbacks[k]["result"]} for k, entry in self.entries.items()}
        self.validate("native")
        with self.assertRaises(ValueError):
            self.validate("system")
        del self.invocations["quiet"]
        with self.assertRaises(ValueError):
            self.validate("native")

    def test_system_result_rejects_test_invocation_and_missing_entry(self):
        self.invocations["allowed"] = self.callbacks["allowed"]
        with self.assertRaises(ValueError):
            self.validate()
        self.invocations.clear()
        del self.entries["quiet"]
        with self.assertRaises(KeyError):
            self.validate()

    def test_visiting_parent_listener_is_insufficient_without_task_claim(self):
        self.claims["quiet"]["handled"] = False
        with self.assertRaises(ValueError):
            self.validate()

    def test_valid_background_contrast(self):
        self.validate()
        self.assertEqual(self.sent["quiet"]["scope_nonce"], self.ready["scope"])
        self.assertNotEqual(self.sent["scope"]["scope_nonce"], self.ready["scope"])
        self.assertEqual(self.sent["quiet"]["quiet_start"], "11:58:00")
        self.assertEqual(self.sent["allowed"]["quiet_start"], self.sent["allowed"]["quiet_end"])
        self.assertEqual(self.sent["allowed"]["aps"], {"content-available": 1})

    def test_expired_control_has_matching_scope_and_elapsed_deadline(self):
        expired = self.sent["expired"]
        self.assertEqual(expired["scope_nonce"], self.ready["scope"])
        self.assertLess(int(expired["expires_ms"]), self.ready["anchor"])
        self.assertGreaterEqual(int(expired["issued_ms"]), self.ready["scheduled"])
        self.assertEqual(expired["quiet_start"], expired["quiet_end"])

    def test_empty_list_and_no_callback_cannot_prove_suppression(self):
        self.complete["delivered"] = []
        del self.callbacks["quiet"]
        with self.assertRaises((ValueError, KeyError)):
            self.validate()

    def test_foreground_receipt_does_not_count_as_background(self):
        self.callbacks["quiet"]["state"] = 0
        with self.assertRaises(ValueError):
            self.validate()

    def test_old_receipts_do_not_count(self):
        self.callbacks["quiet"]["run"] = str(uuid4())
        with self.assertRaises(ValueError):
            self.validate()

    def test_real_selector_must_receive_identical_payload(self):
        self.callbacks["quiet"]["aps"] = {}
        with self.assertRaises(ValueError):
            self.validate()

    def test_wrong_completion_does_not_count(self):
        self.callbacks["quiet"]["result"] = 0
        with self.assertRaises(ValueError):
            self.validate()

    def test_missing_accepted_notification_does_not_count(self):
        self.complete = copy.deepcopy(self.complete)
        self.complete["delivered"] = []
        with self.assertRaises(ValueError):
            self.validate()


class QuietReceiptReadinessTests(unittest.TestCase):
    def test_busy_then_uninstalled_then_ready(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / 'Documents' / 'ac09-receipt'
            directory.mkdir(parents=True)
            (directory / 'ready.json').write_text(json.dumps({'run': 'fixture'}), encoding='utf8')
            responses = [subprocess.TimeoutExpired('simctl', 10),
                         subprocess.CompletedProcess([], 2, stdout=''),
                         subprocess.CompletedProcess([], 0, stdout=root + '\n')]
            with patch('run_ios_quiet_receipt.subprocess.run', side_effect=responses) as query, \
                    patch('run_ios_quiet_receipt.time.sleep'):
                self.assertEqual(wait_for_ready(Mock(poll=lambda: None), 'sim', 'app', 0),
                                 (directory, {'run': 'fixture'}))
                self.assertEqual(query.call_count, 3)

    def test_repeated_timeouts_share_one_deadline(self):
        clock = [0]
        def busy(*args, timeout, **kwargs):
            clock[0] += timeout
            raise subprocess.TimeoutExpired('simctl', timeout)
        def sleep(seconds):
            clock[0] += seconds
        with patch('run_ios_quiet_receipt.subprocess.run', side_effect=busy) as query, \
                patch('run_ios_quiet_receipt.time.monotonic', side_effect=lambda: clock[0]), \
                patch('run_ios_quiet_receipt.time.sleep', side_effect=sleep):
            with self.assertRaisesRegex(TimeoutError, 'native settings/clock/plan'):
                wait_for_ready(Mock(poll=lambda: None), 'sim', 'app', 0, timeout=15)
            self.assertEqual([c.kwargs['timeout'] for c in query.call_args_list], [10, 3])
            self.assertEqual(clock[0], 15)

    def test_xctest_exit_during_busy_probe_surfaces_its_status(self):
        process = Mock()
        process.poll.side_effect = [None, 65]
        with patch('run_ios_quiet_receipt.subprocess.run', side_effect=subprocess.TimeoutExpired('simctl', 10)) as query, \
                patch('run_ios_quiet_receipt.time.sleep'):
            with self.assertRaisesRegex(RuntimeError, 'XCTest exited with 65'):
                wait_for_ready(process, 'sim', 'app', 0)
            query.assert_called_once()


if __name__ == "__main__":
    unittest.main()
