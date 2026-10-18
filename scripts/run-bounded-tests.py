#!/usr/bin/env python3
"""Bound a CI test command and retain diagnostics before terminating its group."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


class Terminated(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupted(signum, _frame):
    raise Terminated(signum)


def group_processes(group):
    result = subprocess.run(['ps', '-axo', 'pid=,pgid=,comm='], capture_output=True,
                            text=True, timeout=5, check=True)
    processes = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and int(fields[1]) == group:
            processes.append({'pid': int(fields[0]), 'command': fields[2]})
    return processes


def diagnose(group, directory):
    # Only capture this command's process group; do not collect unrelated argv.
    try:
        processes = group_processes(group)
        (directory / 'processes.json').write_text(json.dumps(processes, indent=2) + '\n')
        if sys.platform == 'darwin':
            candidates = sorted(processes, key=lambda p: 'test' not in p['command'].lower())[:3]
            for process in candidates:
                with (directory / f"sample-{process['pid']}.log").open('w') as output:
                    try:
                        subprocess.run(['/usr/bin/sample', str(process['pid']), '2', '10'],
                                       stdout=output, stderr=subprocess.STDOUT, timeout=6)
                    except (OSError, subprocess.TimeoutExpired) as error:
                        output.write(str(error) + '\n')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        (directory / 'diagnostic-error.txt').write_text(str(error) + '\n')


def signal_group(group, sig):
    try:
        os.killpg(group, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        # On macOS the group leader can exit between wait/poll and killpg,
        # leaving a transient stale group identifier that reports EPERM rather
        # than ESRCH. Ignore that race only after confirming that the group is
        # empty; a surviving descendant must still make cleanup fail closed.
        if group_processes(group):
            raise


def run(command, timeout, grace, directory):
    directory.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    process = subprocess.Popen(command, start_new_session=True)
    timed_out = False
    interrupted_by = None
    handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        try:
            result = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            print(f'Test command exceeded {timeout:g} seconds; retaining diagnostics.', flush=True)
            diagnose(process.pid, directory)
            result = 124
    except Terminated as error:
        interrupted_by = error.signum
        result = 128 + error.signum
    finally:
        # A second cancellation must not interrupt descendant cleanup.
        for sig in handlers:
            signal.signal(sig, signal.SIG_IGN)
        # Include surviving descendants even when their parent has already exited.
        signal_group(process.pid, signal.SIGTERM)
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            process.poll()
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        signal_group(process.pid, signal.SIGKILL)
        process.wait()
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
    exit_code = result if result >= 0 else 128 - result
    (directory / 'result.json').write_text(json.dumps({
        'timedOut': timed_out, 'exitCode': exit_code, 'interruptedBySignal': interrupted_by,
        'elapsedSeconds': round(time.monotonic() - started, 3),
        'timeoutSeconds': timeout,
    }, indent=2) + '\n')
    return exit_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout-seconds', type=float, required=True)
    parser.add_argument('--grace-seconds', type=float, default=5)
    parser.add_argument('--diagnostics', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    import math
    if not command or not math.isfinite(args.timeout_seconds) or args.timeout_seconds <= 0:
        parser.error('a command and positive finite timeout are required')
    if not math.isfinite(args.grace_seconds) or args.grace_seconds < 0:
        parser.error('grace must be finite and nonnegative')
    return run(command, args.timeout_seconds, args.grace_seconds, args.diagnostics)


if __name__ == '__main__':
    sys.exit(main())
