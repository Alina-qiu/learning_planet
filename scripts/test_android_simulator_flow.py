"""The Android widget test must run from its own unpaused launcher activity."""
import contextlib
import io
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

import run_android_simulator_flow as android


class NativeAndroidTests(unittest.TestCase):
    def test_launches_apk_without_a_debugger(self):
        commands = []
        def invoke(args, timeout):
            commands.append(list(map(str, args)))
            if 'badging' in args:
                return "package: name='com.example.fixture'\nlaunchable-activity: name='another.package.MyActivity'"
            return 'Success' if 'install' in args else 'Starting: Intent { ... }'

        with patch.dict(os.environ, ANDROID_HOME='sdk'), patch.object(android, 'checked', side_effect=invoke), \
                contextlib.redirect_stdout(io.StringIO()):
            android.run('emulator-5554', Path('fixture.apk'))
        self.assertEqual(len(commands), 4)
        self.assertEqual(commands[-1][3:], ['shell', 'am', 'start', '-a', 'android.intent.action.MAIN', '-c',
                                          'android.intent.category.LAUNCHER', '--ez', 'enable-software-rendering', 'true',
                                          '--ez', 'enable-impeller', 'false', '-n', 'com.example.fixture/another.package.MyActivity'])
        self.assertNotIn('forward', [arg for command in commands for arg in command])

    def test_timeout_stays_private(self):
        error = subprocess.TimeoutExpired(['private_marker'], 15, output=b'sensitive output')
        with patch.object(android.subprocess, 'run', side_effect=error):
            with self.assertRaisesRegex(RuntimeError, '^command timed out$'):
                android.checked(['private_marker'], 15)


if __name__ == '__main__':
    unittest.main()
