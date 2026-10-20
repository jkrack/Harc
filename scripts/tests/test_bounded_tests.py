import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'run-bounded-tests.py'
SPEC = importlib.util.spec_from_file_location('bounded_test_runner', SCRIPT)
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class BoundedTests(unittest.TestCase):
    def command(self, directory, code, timeout=10):
        return [sys.executable, str(SCRIPT), '--timeout-seconds', str(timeout),
                '--grace-seconds', '0.15', '--diagnostics', str(directory),
                '--', sys.executable, '-c', code]

    def test_preserves_success_and_failure(self):
        for expected in [0, 7]:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as path:
                directory = Path(path)
                result = subprocess.run(self.command(directory, f'raise SystemExit({expected})'), timeout=10)
                self.assertEqual(result.returncode, expected)
                report = json.loads((directory / 'result.json').read_text())
                self.assertFalse(report['timedOut'])
                self.assertEqual(report['exitCode'], expected)

    def test_timeout_kills_resistant_descendant(self):
        with tempfile.TemporaryDirectory() as path:
            directory = Path(path)
            marker = directory / 'escaped'
            child = ('import signal,time,pathlib; signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                     f'time.sleep(4); pathlib.Path({str(marker)!r}).touch()')
            parent = f'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",{child!r}]); time.sleep(30)'
            # Avoid platform sampling extending past the child marker deadline.
            # Import the runner and replace diagnostics only for this cleanup test.
            driver = ('import importlib.util,pathlib; '
                      f's=importlib.util.spec_from_file_location("runner",{str(SCRIPT)!r}); '
                      'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
                      'm.diagnose=lambda *args: None; '
                      f'raise SystemExit(m.run({[sys.executable,"-c",parent]!r},0.5,0.15,pathlib.Path({path!r})))')
            result = subprocess.run([sys.executable, '-c', driver], timeout=10)
            self.assertEqual(result.returncode, 124)
            self.assertTrue(json.loads((directory / 'result.json').read_text())['timedOut'])
            time.sleep(4)
            self.assertFalse(marker.exists(), 'descendant survived timeout cleanup')

    def test_cancellation_retains_nonzero_result(self):
        with tempfile.TemporaryDirectory() as path:
            directory = Path(path)
            ready = directory / 'ready'
            code = f'import pathlib,time; pathlib.Path({str(ready)!r}).touch(); time.sleep(30)'
            process = subprocess.Popen(self.command(directory, code))
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=5), 128 + signal.SIGTERM)
                report = json.loads((directory / 'result.json').read_text())
                self.assertEqual(report['interruptedBySignal'], signal.SIGTERM)
                self.assertFalse(report['timedOut'])
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_rejects_unbounded_timeout(self):
        with tempfile.TemporaryDirectory() as path:
            for timeout in ['nan', 'inf', '0', '-1']:
                result = subprocess.run(self.command(Path(path), 'pass', timeout), capture_output=True)
                self.assertEqual(result.returncode, 2)

    def test_permission_denied_for_empty_group_is_treated_as_disappeared(self):
        with mock.patch.object(RUNNER.os, 'killpg', side_effect=PermissionError), \
                mock.patch.object(RUNNER, 'group_processes', return_value=[]):
            RUNNER.signal_group(82941, signal.SIGKILL)

    def test_permission_denied_for_zombie_group_is_treated_as_disappeared(self):
        zombies = [{'pid': 82942, 'state': 'Z+', 'command': 'exited-test'}]
        with mock.patch.object(RUNNER.os, 'killpg', side_effect=PermissionError), \
                mock.patch.object(RUNNER, 'group_processes', return_value=zombies):
            RUNNER.signal_group(82941, signal.SIGKILL)

    def test_permission_denied_with_surviving_group_fails_closed(self):
        survivors = [{'pid': 82942, 'state': 'S', 'command': 'resistant-test'}]
        with mock.patch.object(RUNNER.os, 'killpg', side_effect=PermissionError), \
                mock.patch.object(RUNNER, 'group_processes', return_value=survivors):
            with self.assertRaises(PermissionError):
                RUNNER.signal_group(82941, signal.SIGKILL)


if __name__ == '__main__':
    unittest.main()
