"""Stop each real qualification entry point at its first compiler invocation."""
import contextlib
import io
import os
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
DRIVERS = ('qualify-publication-faults.py', 'qualify-publication-storage.py',
           'qualify-tls-identity.py')

class CompilerObserved(Exception):
    pass

class QualificationConcurrencyTests(unittest.TestCase):
    def run_driver(self, driver, overrides):
        env = {k: v for k, v in os.environ.items() if k not in ('CI', 'HARC_BUILD_JOBS')}
        env.update(overrides)
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / 'evidence'
            args = [str(SCRIPTS / driver)]
            if driver != 'qualify-tls-identity.py':
                args += ['--evidence-dir', str(evidence)]
            stderr = io.StringIO()
            with mock.patch.dict(os.environ, env, clear=True), \
                 mock.patch.object(sys, 'argv', args), \
                 mock.patch.object(sys, 'path', [str(SCRIPTS), *sys.path]), \
                 mock.patch('os.statvfs', return_value=SimpleNamespace(f_bavail=8 * 1024**3, f_frsize=1)), \
                 mock.patch('shutil.disk_usage', return_value=SimpleNamespace(free=8 * 1024**3)), \
                 mock.patch('subprocess.check_output', return_value='fixture\n'), \
                 mock.patch('subprocess.run', side_effect=CompilerObserved) as compiler, \
                 contextlib.redirect_stderr(stderr):
                try:
                    runpy.run_path(str(SCRIPTS / driver), run_name='__main__')
                except CompilerObserved:
                    self.assertEqual(compiler.call_count, 1)
                    return compiler.call_args.args[0], None, stderr.getvalue()
                except SystemExit as error:
                    self.assertFalse(compiler.called)
                    self.assertFalse(evidence.exists(), 'invalid override must fail before setup')
                    return None, error.code, stderr.getvalue()
            self.fail('Driver neither validated nor invoked its compiler')

    def test_local_defaults_leave_all_three_compilers_uncapped(self):
        for driver in DRIVERS:
            with self.subTest(driver=driver):
                command, code, _ = self.run_driver(driver, {})
                self.assertIsNone(code)
                self.assertIn(command[0], ('swiftc', 'swift'))
                self.assertNotIn('-j', command)
                self.assertNotIn('--jobs', command)

    def test_override_and_ci_defaults_reach_actual_compiler_command(self):
        for driver in DRIVERS:
            for env, expected in (({'HARC_BUILD_JOBS': '4'}, '4'),
                                  ({'CI': 'true'}, '2'),
                                  ({'CI': '1'}, '2'),
                                  ({'CI': 'true', 'HARC_BUILD_JOBS': '3'}, '3')):
                with self.subTest(driver=driver, env=env):
                    command, code, _ = self.run_driver(driver, env)
                    self.assertIsNone(code)
                    flag = '--jobs' if command[0] == 'swift' else '-j'
                    self.assertEqual(command[command.index(flag) + 1], expected)

    def test_invalid_overrides_fail_before_qualification_side_effects(self):
        for driver in DRIVERS:
            for value in ('0', '-1', '1.5', 'many', '01', ' ', '４'):
                with self.subTest(driver=driver, value=value):
                    command, code, error = self.run_driver(driver, {'HARC_BUILD_JOBS': value})
                    self.assertIsNone(command)
                    self.assertEqual(code, 2)
                    self.assertIn('positive integer', error)
