"""Install the AC-01 test APK and start its on-device widget test."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


def checked(args, timeout):
    try:
        result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                encoding='utf-8', errors='replace', timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError('command timed out') from None
    except OSError:
        raise RuntimeError('command could not start') from None
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


def run(serial, apk):
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
    suffix = '.exe' if os.name == 'nt' else ''
    adb = [sdk / 'platform-tools' / ('adb' + suffix), '-s', serial]
    aapt = sdk / 'build-tools/36.0.0' / ('aapt' + suffix)
    print('Android driver stage: APK metadata', flush=True)
    package, activity = apk_target(checked([aapt, 'dump', 'badging', apk], 45))
    print('Android driver stage: installation', flush=True)
    if 'Success' not in checked(adb + ['install', '-r', '-t', apk], 180).splitlines():
        raise RuntimeError('APK installation not confirmed')
    print('Android driver stage: activity launch', flush=True)
    checked(adb + ['shell', 'am', 'force-stop', package], 20)
    started = checked(adb + ['shell', 'am', 'start', '-a', 'android.intent.action.MAIN', '-c',
                             'android.intent.category.LAUNCHER', '-n', f'{package}/{activity}'], 30)
    if 'Starting: Intent' not in started or 'Error' in started:
        raise RuntimeError('activity launch failed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--serial', required=True)
    parser.add_argument('--apk', required=True, type=Path)
    args = parser.parse_args()
    try:
        run(args.serial, args.apk)
    except RuntimeError as error:
        sys.exit('Android driver failure: ' + str(error))
