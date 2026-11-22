"""Attach the integration driver to a freshly launched, prebuilt Android app."""
import argparse
from contextlib import ExitStack
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from run_cross_device_sync import ui_timeout


def command(args, timeout, *, env=None):
    # VM announcements and failed UI assertions can contain credentials.
    # Capture output in memory and report only fixed failure descriptions.
    try:
        return subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              encoding='utf-8', errors='replace', timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        raise RuntimeError('command timed out') from None
    except OSError:
        raise RuntimeError('command could not start') from None


def checked(args, timeout):
    result = command(args, timeout)
    if result.returncode:
        raise RuntimeError(f'command exited {result.returncode}')
    return result.stdout.strip()


def apk_target(badging):
    identifier = r'([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)'
    package = re.search(r"^package: name='" + identifier + "'", badging, re.MULTILINE)
    activity = re.search(r"^launchable-activity: name='" + identifier + "'", badging, re.MULTILINE)
    if not package or not activity:
        raise RuntimeError('no launchable app in APK')
    return package[1], activity[1]


def microseconds(timestamp):
    seconds, fraction = timestamp.split('.')
    return int(seconds) * 1_000_000 + int(fraction[:6].ljust(6, '0'))


def vm_endpoint(log, current_pid, launch_time):
    # logcat epoch/usec fields are seconds.microseconds, PID, TID, priority and tag.
    for line in reversed(log.splitlines()):
        match = re.fullmatch(r'\s*(\d+\.\d+)\s+(\d+)\s+\d+\s+I\s+flutter\s*:\s*'
                             r'The Dart VM service is listening on http://127\.0\.0\.1:(\d{1,5})/([A-Za-z0-9_=-]+)/\s*', line)
        if (match and match[2] == current_pid and microseconds(match[1]) >= launch_time
                and 0 < int(match[3]) <= 65535):
            return match[3], match[4]
    return None


def stage(name):
    print('Android driver stage: ' + name, flush=True)


def run(serial, apk, driver):
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
    suffix = '.exe' if os.name == 'nt' else ''
    adb = [sdk / 'platform-tools' / ('adb' + suffix), '-s', serial]
    aapt = sdk / 'build-tools/36.0.0' / ('aapt' + suffix)
    dart = Path(os.environ['FLUTTER_ROOT']) / 'bin/cache/dart-sdk/bin' / ('dart' + suffix)

    stage('APK metadata')
    package, activity = apk_target(checked([aapt, 'dump', 'badging', apk], 45))
    stage('installation')
    if 'Success' not in checked(adb + ['install', '-r', '-t', apk], 180).splitlines():
        raise RuntimeError('APK installation not confirmed')

    cleanup_failed = False
    def cleanup(*args):
        nonlocal cleanup_failed
        try:
            checked(adb + list(args), 15)
        except RuntimeError:
            cleanup_failed = True

    with ExitStack() as stack:
        stage('activity launch')
        checked(adb + ['shell', 'am', 'force-stop', package], 20)
        timestamp = checked(adb + ['shell', 'date', '+%s.%N'], 15)
        if not re.fullmatch(r'\d+\.\d+', timestamp):
            raise RuntimeError('could not read device clock')
        launch_time = microseconds(timestamp)
        # -W waits for a first frame; start-paused intentionally withholds that frame.
        stack.callback(cleanup, 'shell', 'am', 'force-stop', package)
        started = checked(adb + ['shell', 'am', 'start', '-a', 'android.intent.action.MAIN', '-c',
                                 'android.intent.category.LAUNCHER', '-n', f'{package}/{activity}',
                                 '--ez', 'start-paused', 'true', '--ez', 'enable-checked-mode', 'true',
                                 '--ez', 'verify-entry-points', 'true'], 30)
        if 'Starting: Intent' not in started or 'Error' in started:
            raise RuntimeError('activity launch failed')

        stage('app PID')
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            existing = command(adb + ['shell', 'pidof', package], 8)
            pid = existing.stdout.strip()
            if existing.returncode == 0 and re.fullmatch(r'[1-9][0-9]*', pid):
                break
            time.sleep(1)
        else:
            raise RuntimeError('app PID not found')

        stage('VM discovery')
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline:
            logs = checked(adb + ['logcat', '-d', '--pid=' + pid, '-v', 'epoch', '-v', 'usec', '-s', 'flutter:I'], 15)
            endpoint = vm_endpoint(logs, pid, launch_time)
            if endpoint:
                break
            time.sleep(1)
        else:
            raise RuntimeError('VM discovery timed out')
        if checked(adb + ['shell', 'pidof', package], 8) != pid:
            raise RuntimeError('app process changed')

        stage('VM forwarding')
        port, auth_path = endpoint
        local_port = checked(adb + ['forward', 'tcp:0', 'tcp:' + port], 20)
        if not re.fullmatch(r'[0-9]{1,5}', local_port) or not 0 < int(local_port) <= 65535:
            raise RuntimeError('no host port allocated')
        stack.callback(cleanup, 'forward', '--remove', 'tcp:' + local_port)

        stage('Dart driver')
        service = f'http://127.0.0.1:{local_port}/{auth_path}/'
        result = command([dart, driver], 1200, env={**os.environ, 'VM_SERVICE_URL': service})
        if result.returncode:
            label = ui_timeout(result.stdout)
            if label:
                print('Timed out waiting for ' + label, flush=True)
            raise RuntimeError(f'command exited {result.returncode}')
    if cleanup_failed:
        stage('cleanup')
        raise RuntimeError('could not release app or forward')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--serial', required=True)
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--driver', required=True, type=Path)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        run(args.serial, args.apk, args.driver)
    except RuntimeError as error:
        sys.exit('Android driver failure: ' + str(error))
