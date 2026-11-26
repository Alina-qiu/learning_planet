import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
from uuid import uuid4

from run_ios_quiet_receipt import payload, verify, wait_for_ready


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
