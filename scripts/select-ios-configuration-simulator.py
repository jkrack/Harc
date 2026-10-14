#!/usr/bin/env python3
"""Choose one installed available iPhone, prefer booted, then newest iOS and stable name/UDID order."""
import json
from pathlib import Path
import re
import subprocess
import sys

def select_simulator(runtimes, devices):
    candidates = []
    for runtime in runtimes.get('runtimes', []):
        if not runtime.get('isAvailable') or not runtime.get('identifier', '').startswith('com.apple.CoreSimulator.SimRuntime.iOS-'):
            continue
        version = tuple(int(x) for x in re.findall(r'\d+', runtime.get('version', '')))
        if not version or version[0] < 18:
            continue
        for device in devices.get('devices', {}).get(runtime['identifier'], []):
            if device.get('isAvailable') and device.get('name', '').startswith('iPhone ') and device.get('udid'):
                candidates.append((version, device['name'], device['udid'], runtime, device.get('state') == 'Booted'))
    if not candidates:
        raise ValueError('No installed available iPhone simulator with iOS 18+; install a compatible runtime.')
    booted = [item for item in candidates if item[4]]
    candidates = booted or candidates
    newest = max(item[0] for item in candidates)
    _, name, udid, runtime, _ = min((item for item in candidates if item[0] == newest), key=lambda item: (item[1], item[2]))
    return {'device_name': name, 'udid': udid, 'runtime_identifier': runtime['identifier'],
            'runtime_version': runtime['version'], 'destination': f'platform=iOS Simulator,id={udid}'}

def main():
    output = Path(sys.argv[1])
    def inventory(kind):
        return json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', kind, '--json'], text=True))
    selected = select_simulator(inventory('runtimes'), inventory('devices'))
    selected['source_sha'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    selected['source_dirty'] = bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip())
    selected['scope'] = 'Simulator configuration checks; not physical-device or release qualification.'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(selected, indent=2) + '\n')
    print(json.dumps(selected))

if __name__ == '__main__':
    main()
