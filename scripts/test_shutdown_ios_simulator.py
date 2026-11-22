"""Exercise delayed CoreSimulator status changes without an Apple host."""
import contextlib
import io
import json
import subprocess
import unittest
from unittest.mock import patch

import shutdown_ios_simulator as simulator


DEVICE = '10000000-0000-0000-0000-000000000001'
OTHER = '10000000-0000-0000-0000-000000000002'


class ShutdownTests(unittest.TestCase):
    def setUp(self):
        self.clock = 0
        self.requests = 0
        self.queries = 0

    def sleep(self, duration):
        self.clock += duration

    def exercise(self, state, request_result=0, *, timeout=210):
        def run(command, **kwargs):
            if command == ['xcrun', 'simctl', 'list', 'devices', '--json']:
                self.queries += 1
                current = state()
                entries = [{'udid': OTHER, 'state': 'Shutdown'}]
                if current is not None:
                    entries.append({'udid': DEVICE, 'state': current})
                output = json.dumps({'devices': {'iOS': entries}})
                return subprocess.CompletedProcess(command, 0, output)
            self.assertEqual(command, ['xcrun', 'simctl', 'shutdown', DEVICE])
            self.requests += 1
            if request_result == 'timeout':
                self.sleep(kwargs['timeout'])
                raise subprocess.TimeoutExpired(command, kwargs['timeout'])
            return subprocess.CompletedProcess(command, request_result)

        with (patch.object(simulator.subprocess, 'run', side_effect=run),
              patch.object(simulator.time, 'monotonic', side_effect=lambda: self.clock),
              patch.object(simulator.time, 'sleep', side_effect=self.sleep),
              contextlib.redirect_stdout(io.StringIO())):
            simulator.shutdown(DEVICE, timeout=timeout)

    def test_already_shutdown_needs_no_command(self):
        self.exercise(lambda: 'Shutdown')
        self.assertEqual(self.requests, 0)

    def test_request_times_out_but_shutdown_completes_after_two_minutes(self):
        def state():
            if self.clock >= 129:
                return 'Shutdown'
            return 'Shutting Down' if self.requests else 'Booted'
        self.exercise(state, 'timeout')
        self.assertEqual(self.requests, 1)
        self.assertGreater(self.clock, 120)

    def test_command_error_while_device_finishes_shutdown(self):
        self.exercise(lambda: 'Shutdown' if self.requests else 'Booted', request_result=1)
        self.assertEqual(self.queries, 2)

    def test_retries_a_still_booted_device(self):
        self.exercise(lambda: 'Shutdown' if self.requests == 2 else 'Booted')
        self.assertEqual(self.requests, 2)
        self.assertGreaterEqual(self.clock, 30)

    def test_unconfirmed_state_fails_even_when_commands_succeed(self):
        with self.assertRaisesRegex(RuntimeError, 'last observed state: Booted'):
            self.exercise(lambda: 'Booted', timeout=70)
        self.assertEqual(self.requests, 2)
        self.assertEqual(self.clock, 70)

    def test_another_device_cannot_satisfy_shutdown(self):
        with self.assertRaisesRegex(RuntimeError, 'Could not identify selected simulator'):
            self.exercise(lambda: None)
        self.assertEqual(self.requests, 0)


if __name__ == '__main__':
    unittest.main()
