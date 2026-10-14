import contextlib
import importlib.util
import io
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

RUNNER = Path(__file__).resolve().parents[1] / 'run-package-tests.py'
spec = importlib.util.spec_from_file_location('package_runner', RUNNER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

CHILD = '''import json, os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid': os.getpid(), 'group': os.getpgrp()}))
while True: time.sleep(1)
'''
PARENT = '''import pathlib, signal, subprocess, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]])
if sys.argv[3] == 'diagnostics':
    while not pathlib.Path(sys.argv[4]).exists(): time.sleep(.01)
    pathlib.Path(sys.argv[5]).write_text('exited during diagnostics')
    sys.exit(0)
while True: time.sleep(1)
'''


def running(identity):
    try:
        if os.getpgid(identity['pid']) != identity['group']:
            return False
    except ProcessLookupError:
        return False
    state = subprocess.run(['ps', '-p', str(identity['pid']), '-o', 'stat='],
                           capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith('Z')


class RunnerCleanupTests(unittest.TestCase):
    def fixture(self, root, mode):
        marker = root / 'child.json'
        barrier = root / 'diagnostics-started'
        exited = root / 'parent-exited'
        command = [sys.executable, '-c', PARENT, CHILD, str(marker), mode,
                   str(barrier), str(exited)]
        return marker, barrier, exited, command

    def assert_cleaned(self, marker):
        self.assertTrue(marker.exists(), 'fixture child did not start')
        identity = json.loads(marker.read_text())
        self.assertFalse(running(identity), 'TERM-resistant descendant survived runner exit')

    def cleanup_fixture(self, marker):
        if marker.exists():
            identity = json.loads(marker.read_text())
            if running(identity):
                # This group belongs to our start_new_session fixture, never
                # the test process or any unrelated user's process group.
                self.assertNotEqual(identity['group'], os.getpgrp())
                os.killpg(identity['group'], signal.SIGKILL)

    def test_term_exiting_parent_does_not_leave_resistant_child(self):
        with tempfile.TemporaryDirectory(prefix='harc-runner-test-') as scratch:
            root = Path(scratch)
            marker, _, _, command = self.fixture(root, 'term')
            sentinel = subprocess.Popen(
                [sys.executable, '-c', 'import time; time.sleep(60)'],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)
            try:
                result = subprocess.run(
                    [sys.executable, str(RUNNER), '--timeout-seconds', '1',
                     '--diagnostics-dir', str(root / 'diagnostics'), '--', *command],
                    capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
                self.assert_cleaned(marker)
                self.assertIsNone(sentinel.poll(), 'independent process was signalled')
            finally:
                self.cleanup_fixture(marker)
                sentinel.terminate()
                sentinel.wait(timeout=5)

    def test_parent_exit_during_diagnostics_does_not_skip_cleanup(self):
        with tempfile.TemporaryDirectory(prefix='harc-runner-test-') as scratch:
            root = Path(scratch)
            marker, barrier, exited, command = self.fixture(root, 'diagnostics')
            def capture(*_):
                barrier.write_text('diagnostics entered')
                time.sleep(.3)
            try:
                argv = [str(RUNNER), '--timeout-seconds', '1',
                        '--diagnostics-dir', str(root / 'diagnostics'), '--', *command]
                with mock.patch.object(sys, 'argv', argv), \
                     mock.patch.object(runner, 'capture_stacks', side_effect=capture), \
                     contextlib.redirect_stdout(io.StringIO()):
                    status = runner.main()
                self.assertEqual(status, 124)
                self.assertTrue(exited.exists(), 'parent did not exit during diagnostics')
                self.assert_cleaned(marker)
            finally:
                self.cleanup_fixture(marker)

    def test_exit_status_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix='harc-runner-status-') as scratch:
            for status in (0, 7):
                with self.subTest(status=status):
                    result = subprocess.run(
                        [sys.executable, str(RUNNER), '--diagnostics-dir', scratch,
                         '--', sys.executable, '-c', f'raise SystemExit({status})'],
                        capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, status)


if __name__ == '__main__':
    unittest.main()
