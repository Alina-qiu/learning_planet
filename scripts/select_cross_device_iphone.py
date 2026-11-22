"""Select the local iOS 18.5 iPhone on each Intel runner used by AC-01."""
import json
import os
import subprocess


def select_iphone(devices):
    candidates = [device for device in devices.get('com.apple.CoreSimulator.SimRuntime.iOS-18-5', [])
                  if device.get('isAvailable') and device['name'].startswith('iPhone ')]
    if not candidates:
        raise SystemExit('No available iPhone simulator for iOS 18.5')
    return max(candidates, key=lambda device: device['name'])


if __name__ == '__main__':
    inventory = subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'])
    iphone = select_iphone(json.loads(inventory)['devices'])
    with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as destination:
        destination.write(f"SIMULATOR_ID={iphone['udid']}\n")
    print(iphone['name'], 'iOS 18.5')
