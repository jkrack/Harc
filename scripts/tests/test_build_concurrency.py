"""Exercise actual tool argument forwarding without compiling or signing."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class BuildConcurrencyTests(unittest.TestCase):
    def invoke(self, kind, overrides=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for tool in ('swift', 'xcodebuild'):
                script = root / tool
                script.write_text('#!' + sys.executable + '\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n')
                script.chmod(0o755)
            env = {k: v for k, v in os.environ.items()
                   if k not in ('CI', 'HARC_BUILD_JOBS', 'HARC_EMBED_BUILD_JOBS')}
            env.update(overrides or {})
            env['PATH'] = str(root) + os.pathsep + env['PATH']
            if kind == 'runner':
                cmd = [sys.executable, '-B', str(ROOT / 'scripts/run-package-tests.py'),
                       '--diagnostics-dir', str(root / 'diagnostics')]
            else:
                select = ('harc_configure_build_jobs "${HARC_EMBED_BUILD_JOBS:-${HARC_BUILD_JOBS:-}}"'
                          if kind == 'embed' else 'harc_configure_build_jobs')
                invoke = 'harc_xcodebuild -scheme Harc build' if kind == 'xcode' else 'harc_swift build --product harc-stt'
                cmd = ['/bin/bash', '-eu', '-c',
                       'source "$1"; ' + select + '; ' + invoke, 'test',
                       str(ROOT / 'scripts/build-concurrency.sh')]
            return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)

    def test_local_defaults_omit_worker_limits(self):
        for kind in ('swift', 'embed', 'xcode', 'runner'):
            with self.subTest(kind=kind):
                result = self.invoke(kind)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads(result.stdout)
                self.assertNotIn('--jobs', args)
                self.assertNotIn('-jobs', args)
                self.assertFalse(any('MAXIMUM_CONCURRENT' in arg for arg in args))

    def test_explicit_override_and_ci_budget(self):
        for kind in ('swift', 'embed', 'xcode', 'runner'):
            for env, count in (({'CI': 'true'}, '2'), ({'HARC_BUILD_JOBS': '4'}, '4'),
                               ({'CI': 'true', 'HARC_BUILD_JOBS': '3'}, '3')):
                with self.subTest(kind=kind, env=env):
                    result = self.invoke(kind, env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    args = json.loads(result.stdout)
                    flag = '-jobs' if kind == 'xcode' else '--jobs'
                    self.assertEqual(args[args.index(flag) + 1], count)
                    if kind == 'xcode':
                        self.assertIn('SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=' + count, args)

    def test_embed_override_has_precedence(self):
        result = self.invoke('embed', {'HARC_BUILD_JOBS': '4', 'HARC_EMBED_BUILD_JOBS': '3'})
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)
        self.assertEqual(args[args.index('--jobs') + 1], '3')

    def test_invalid_override_fails_before_tool_runs(self):
        for kind in ('swift', 'embed', 'xcode', 'runner'):
            for value in ('0', '-1', '1.5', 'two', '01', ' '):
                with self.subTest(kind=kind, value=value):
                    result = self.invoke(kind, {'HARC_BUILD_JOBS': value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, '')
                    self.assertIn('positive integer', result.stderr)
