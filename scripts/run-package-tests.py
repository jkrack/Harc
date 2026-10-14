#!/usr/bin/env python3
"""Bound package execution and preserve task-owned macOS hang diagnostics."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading


def descendants(root):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command='], text=True)
    processes = {}
    for line in rows.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            processes[int(parts[0])] = (int(parts[1]), parts[2])
    owned = {root}
    while True:
        next_owned = owned | {pid for pid, (parent, _) in processes.items() if parent in owned}
        if next_owned == owned:
            return {pid: processes[pid][1] for pid in owned if pid in processes}
        owned = next_owned


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout-seconds', type=float, default=180)
    parser.add_argument('--diagnostics-dir', type=Path, default=Path('.build/test-diagnostics'))
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command or ['swift', 'test', '--skip-build', '--jobs', '2']
    if command[0] == '--':
        command = command[1:]
    args.diagnostics_dir.mkdir(parents=True, exist_ok=True)
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, bufsize=1, start_new_session=True)
    with (args.diagnostics_dir / 'test-output.log').open('w') as output:
        def relay():
            for line in child.stdout:
                output.write(line)
                output.flush()
                sys.stdout.write(line)
                sys.stdout.flush()
        reader = threading.Thread(target=relay, daemon=True)
        reader.start()
        try:
            status = child.wait(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            print(f'Package tests exceeded {args.timeout_seconds:g}s; capturing owned test stacks.', flush=True)
            owned = descendants(child.pid)
            (args.diagnostics_dir / 'owned-processes.txt').write_text(
                '\n'.join(f'{pid} {command}' for pid, command in owned.items()))
            if sys.platform == 'darwin':
                for pid, invocation in owned.items():
                    executable = Path(invocation.split()[0]).name
                    if executable in ('swiftpm-testing', 'swiftpm-testing-helper', 'HarcPackageTests'):
                        try:
                            subprocess.run(['sample', str(pid), '3', '-file',
                                            str(args.diagnostics_dir / f'sample-{pid}.txt')],
                                           timeout=90, check=False)
                        except (subprocess.TimeoutExpired, OSError) as error:
                            print(f'Could not finish sampling {pid}: {error}', flush=True)
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    for pid in sorted(owned, reverse=True):
                        try:
                            os.kill(pid, signal.SIGTERM)
                        except (ProcessLookupError, PermissionError):
                            pass
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    for pid in sorted(descendants(child.pid), reverse=True):
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except (ProcessLookupError, PermissionError):
                            pass
            status = 124
        reader.join(timeout=5)
    return status if status >= 0 else 128 - status


if __name__ == '__main__':
    sys.exit(main())
