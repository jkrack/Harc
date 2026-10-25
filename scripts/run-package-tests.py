#!/usr/bin/env python3
"""Bound package execution and preserve task-owned macOS hang diagnostics."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


def process_table():
    rows = subprocess.check_output(
        ['ps', '-axo', 'pid=,ppid=,pgid=,stat=,lstart=,command='], text=True)
    processes = {}
    for line in rows.splitlines():
        parts = line.strip().split(None, 9)
        if len(parts) != 10:
            continue
        try:
            pid, parent, group = map(int, parts[:3])
        except ValueError:
            continue
        processes[pid] = dict(parent=parent, group=group, state=parts[3],
                              started=tuple(parts[4:9]), command=parts[9])
    return processes


def descendants(root, previous=None):
    processes = process_table()
    # start_new_session makes root the owner of a fresh process group. Include
    # its orphaned members even after the immediate subprocess has exited.
    owned = {pid for pid, item in processes.items() if item['group'] == root}
    for pid, old in (previous or {}).items():
        current = processes.get(pid)
        if current and (current['group'], current['started']) == (old['group'], old['started']):
            owned.add(pid)
    while True:
        next_owned = owned | {pid for pid, item in processes.items() if item['parent'] in owned}
        if next_owned == owned:
            return {pid: processes[pid] for pid in owned
                    if pid in processes and not processes[pid]['state'].startswith('Z')}
        owned = next_owned


def capture_stacks(owned, diagnostics_dir):
    if sys.platform != 'darwin':
        return
    for pid, process in owned.items():
        # Recheck identity immediately before sampling: an exited owned process
        # must not turn into permission to inspect a reused unrelated PID.
        live = process_table().get(pid)
        if not live or (live['group'], live['started']) != (process['group'], process['started']):
            continue
        executable = Path(process['command'].split()[0]).name
        if executable in ('swiftpm-testing', 'swiftpm-testing-helper', 'HarcPackageTests',
                          'xcodebuild', 'xctest'):
            try:
                subprocess.run(['sample', str(pid), '3', '-file',
                                str(diagnostics_dir / f'sample-{pid}.txt')],
                               timeout=90, check=False)
            except (subprocess.TimeoutExpired, OSError) as error:
                print(f'Could not finish sampling {pid}: {error}', flush=True)


def signal_owned(root, owned, sig):
    group_signalled = False
    if any(item['group'] == root for item in owned.values()):
        try:
            os.killpg(root, sig)
            group_signalled = True
        except (ProcessLookupError, PermissionError):
            pass
    # A captured descendant can start another group. Never signal a different
    # whole group: only its individually tracked, still-matching process IDs.
    current = process_table()
    for pid, item in owned.items():
        if group_signalled and item['group'] == root:
            continue
        live = current.get(pid)
        if not live or (live['group'], live['started']) != (item['group'], item['started']):
            continue
        try:
            os.kill(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass


def terminate_owned(child, previous=None):
    owned = descendants(child.pid, previous)
    if not owned:
        return
    signal_owned(child.pid, owned, signal.SIGTERM)
    deadline = time.monotonic() + 5
    while owned and time.monotonic() < deadline:
        child.poll()
        time.sleep(.05)
        owned = descendants(child.pid, owned)
    if owned:
        signal_owned(child.pid, owned, signal.SIGKILL)
        deadline = time.monotonic() + 1
        while owned and time.monotonic() < deadline:
            child.poll()
            time.sleep(.01)
            owned = descendants(child.pid, owned)
        if owned:
            print(f'Owned processes remain after SIGKILL: {sorted(owned)}', flush=True)
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        print(f'Could not reap subprocess {child.pid}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout-seconds', type=float, default=180)
    parser.add_argument('--diagnostics-dir', type=Path, default=Path('.build/test-diagnostics'))
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if not command:
        jobs = os.environ.get('HARC_BUILD_JOBS', '')
        if not jobs and os.environ.get('CI') in ('true', '1'):
            jobs = '2'
        if jobs and (not jobs.isascii() or not jobs.isdecimal() or jobs.startswith('0')):
            parser.error('HARC_BUILD_JOBS must be a positive integer')
        command = ['swift', 'test', '--skip-build']
        if jobs:
            command += ['--jobs', jobs]
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
        owned = None
        try:
            status = child.wait(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            print(f'Package tests exceeded {args.timeout_seconds:g}s; capturing owned test stacks.', flush=True)
            owned = descendants(child.pid)
            (args.diagnostics_dir / 'owned-processes.txt').write_text(
                '\n'.join(f"{pid} {item['command']}" for pid, item in owned.items()))
            capture_stacks(owned, args.diagnostics_dir)
            status = 124
        finally:
            # Joining the parent is not proof its children stopped. Cleanup
            # and escalation follow the owned group independently of poll().
            terminate_owned(child, owned)
        reader.join(timeout=5)
        if not reader.is_alive():
            child.stdout.close()
    return status if status >= 0 else 128 - status


if __name__ == '__main__':
    sys.exit(main())
