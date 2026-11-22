"""Wait for CoreSimulator to confirm shutdown of the selected CI device."""
import json
import os
import subprocess
import time
import uuid


def shutdown(device, timeout=210):
    # Reject simctl aliases such as 'all' and 'booted'.
    if str(uuid.UUID(device)) != device.lower():
        raise ValueError('Expected a simulator UDID')
    deadline = time.monotonic() + timeout
    next_request = 0
    attempts = 0
    last_state = 'unobserved'
    while (remaining := deadline - time.monotonic()) > 0:
        try:
            inventory = subprocess.run(['xcrun', 'simctl', 'list', 'devices', '--json'], check=True,
                                       capture_output=True, text=True, timeout=min(20, remaining))
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
            print('Simulator state query unavailable, retrying', flush=True)
        else:
            matches = [item['state'] for devices in json.loads(inventory.stdout)['devices'].values()
                       for item in devices if item['udid'].lower() == device.lower()]
            if len(matches) != 1:
                raise RuntimeError(f'Could not identify selected simulator {device}')
            state = matches[0]
            if state != last_state:
                print(f'{device}: {state}', flush=True)
                last_state = state
            if state == 'Shutdown':
                return
            now = time.monotonic()
            # A timed-out client can leave shutdown running in CoreSimulator.
            # Only repeat a request for a booted device, allowing time to verify it.
            if state in ('Booted', 'Booting') and attempts < 2 and now >= next_request and deadline - now > 20:
                attempts += 1
                try:
                    result = subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True,
                                            timeout=min(45, deadline - now - 15))
                    print(f'Shutdown request {attempts} returned {result.returncode}, checking state', flush=True)
                except subprocess.TimeoutExpired:
                    print(f'Shutdown request {attempts} timed out, checking state', flush=True)
                next_request = time.monotonic() + 30
        time.sleep(min(3, max(0, deadline - time.monotonic())))
    raise RuntimeError(f'Shutdown unconfirmed for {device} after {timeout}s, last observed state: {last_state}')


if __name__ == '__main__':
    shutdown(os.environ['SIMULATOR_ID'])
