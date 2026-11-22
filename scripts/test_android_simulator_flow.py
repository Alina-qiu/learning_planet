import contextlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import run_android_simulator_flow as android
import run_cross_device_sync as coordinator


def vm_line(timestamp='99.234567', pid='987', host='127.0.0.1', port=43111):
    return (f'{timestamp} {pid} 321 I flutter : The Dart VM service is listening on '
            f'http://{host}:{port}/private_marker=/')


class DirectAndroidTests(unittest.TestCase):
    def test_vm_belongs_to_current_launch_and_pid(self):
        launch = android.microseconds('99.234567000')
        logs = [vm_line('98.234567'), vm_line('99.234566'), vm_line(pid='986'),
                vm_line(host='10.0.2.2'), vm_line(port=65536)]
        self.assertIsNone(android.vm_endpoint('\n'.join(logs), '987', launch))
        self.assertEqual(android.vm_endpoint('\n'.join([vm_line(), *logs]), '987', launch),
                         ('43111', 'private_marker='))

    def test_original_driver_failure_releases_forward_and_hides_private_output(self):
        commands = []
        def invoke(args, timeout, *, env=None):
            args = list(map(str, args))
            commands.append(args)
            status, output = 0, ''
            if 'badging' in args:
                output = "package: name='com.example.fixture'\nlaunchable-activity: name='other.package.MyActivity'"
            elif 'install' in args:
                output = 'Success\n'
            elif 'date' in args:
                output = '99.234567000'
            elif 'start' in args:
                self.assertIn('com.example.fixture/other.package.MyActivity', args)
                self.assertNotIn('-W', args)
                output = 'Starting: Intent { ... }'
            elif 'pidof' in args:
                output = '987'
            elif 'logcat' in args:
                output = vm_line()
            elif 'tcp:0' in args:
                output = '44000'
            elif env:
                self.assertEqual(env['VM_SERVICE_URL'], 'http://127.0.0.1:44000/private_marker=/')
                status, output = 1, 'not-for-output\nTimed out waiting for confirmed wallet\n'
            return subprocess.CompletedProcess(args, status, output)

        with patch.dict(os.environ, ANDROID_HOME='sdk', FLUTTER_ROOT='flutter'), \
                patch.object(android, 'command', side_effect=invoke), contextlib.redirect_stdout(io.StringIO()) as log:
            with self.assertRaisesRegex(RuntimeError, 'exited 1'):
                android.run('emulator-5554', Path('fixture.apk'), Path('driver.dart'))
        self.assertEqual(commands[-2][-3:], ['forward', '--remove', 'tcp:44000'])
        self.assertEqual(commands[-1][-3:], ['am', 'force-stop', 'com.example.fixture'])
        self.assertNotIn('private_marker', log.getvalue())
        self.assertNotIn('not-for-output', log.getvalue())
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / 'driver.log'
            report.write_text(log.getvalue(), encoding='utf8')
            reason = coordinator.driver_failure(report, 'Android writer', 'exited with code 1', 'reader-ready')
        self.assertIn('Android driver stage Dart driver, timeout at confirmed wallet', reason)
        self.assertIsNone(coordinator.ui_timeout('Timed out waiting for not-for-output\n'))

    def test_subprocess_timeout_never_exposes_command_or_output(self):
        error = subprocess.TimeoutExpired(['private_marker'], 15, output=b'sensitive output')
        with patch.object(android.subprocess, 'run', side_effect=error):
            with self.assertRaisesRegex(RuntimeError, '^command timed out$'):
                android.command(['private_marker'], 15)


if __name__ == '__main__':
    unittest.main()
