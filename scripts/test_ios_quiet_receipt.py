import copy
import unittest
from uuid import uuid4

from run_ios_quiet_receipt import payload, verify


class QuietReceiptEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.ready = {"run": str(uuid4()), "scope": str(uuid4()), "state": 0,
                      "anchor": 1773057600000, "scheduled": 1773057510000,
                      "ids": {k: str(uuid4()) for k in ("quiet", "scope", "expired", "allowed")}}
        self.sent = {k: payload(self.ready, k, 1000) for k in self.ready["ids"]}
        self.callbacks = {k: {"run": self.ready["run"], "message": p["message_id"],
                          "payload": {f: v for f, v in p.items() if f != "aps"},
                          "aps": p["aps"], "state": 2, "result": 0 if k == "allowed" else 1}
                          for k, p in self.sent.items()}
        allowed = [self.ready["ids"]["allowed"]]
        self.complete = {"run": self.ready["run"], "delivered": allowed, "seen": allowed,
                         "quietSuppressed": True, "scopeRejected": True, "expiredRejected": True}

    def validate(self):
        verify(self.ready, self.sent, self.callbacks, self.complete)

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


if __name__ == "__main__":
    unittest.main()
