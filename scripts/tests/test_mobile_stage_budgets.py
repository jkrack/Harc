"""Run the production mobile shell flow with synthetic tools; never launch Xcode."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/test-mobile-configuration.sh'


class MobileStageBudgetTests(unittest.TestCase):
    def invoke(self, scenario='pass'):
        with tempfile.TemporaryDirectory(prefix='harc-mobile-budget-') as directory:
            root = Path(directory)
            scripts = root / 'scripts'
            scripts.mkdir()
            for name in ('test-mobile-configuration.sh', 'build-concurrency.sh',
                         'check-xcode-test-results.py'):
                shutil.copy2(ROOT / 'scripts' / name, scripts / name)
            # Simulate guard outcomes, not lifecycle internals (covered by
            # test_run_package_tests.py). Log exact command and budget forwarding.
            (scripts / 'run-package-tests.py').write_text('''import json, os, subprocess, sys
from pathlib import Path
a = sys.argv[1:]
with open('calls.jsonl', 'a') as f: f.write(json.dumps(a) + '\\n')
command = a[a.index('--') + 1:]
if os.environ['SCENARIO'] == 'timeout' and command[-1] == 'test-without-building':
    print('** TEST SUCCEEDED **')  # Text must never override timeout status.
    raise SystemExit(124)
raise SystemExit(subprocess.call(command))
''')
            (scripts / 'select-ios-configuration-simulator.py').write_text(
                "import json,sys\nfrom pathlib import Path\n"
                "Path(sys.argv[1]).write_text(json.dumps({'destination': 'platform=iOS Simulator,id=fixture'}))\n")
            required = re.findall(r'--require-test ([^\s\\]+)', SCRIPT.read_text())
            nodes = []
            for bundle in ('HarcMobileAppTests', 'HarcMobileUITests'):
                nodes.append({'nodeType': 'Test Bundle', 'name': bundle, 'children': [
                    {'nodeType': 'Test Case', 'nodeIdentifier': key.split('/', 1)[1],
                     'result': 'Passed'} for key in required if key.startswith(bundle + '/')]})
            (root / 'tree.json').write_text(json.dumps({'testNodes': nodes}))
            (root / 'summary.json').write_text(json.dumps({
                'result': 'Passed', 'totalTestCount': len(required), 'passedTests': len(required),
                'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0, 'testFailures': []}))
            bin_path = root / 'bin'
            bin_path.mkdir()
            tools = {
                'uname': "print('arm64')",
                'df': "print('Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 99999999 0 99999999 0% /')",
                'git': "print('fixture-exact-source')",
                'xcodebuild': '''import json, os, sys
from pathlib import Path
a = sys.argv[1:]
with open('xcode.jsonl', 'a') as f: f.write(json.dumps(a) + '\\n')
scenario = os.environ['SCENARIO']
if a[-1] == 'build-for-testing':
    raise SystemExit(65 if scenario == 'build-failure' else 0)
if scenario == 'test-failure': raise SystemExit(65)
if scenario != 'missing-result':
    p = Path(a[a.index('-resultBundlePath') + 1]); p.mkdir(parents=True)
    (p / 'Info.plist').write_text('synthetic seal')
''',
                'xcrun': '''import os, sys
from pathlib import Path
with open('exports.txt', 'a') as f: f.write(sys.argv[4] + '\\n')
p = Path(sys.argv[sys.argv.index('--path') + 1])
if not (p / 'Info.plist').exists(): raise SystemExit(1)
if os.environ['SCENARIO'] == 'corrupt-result': print('{broken'); raise SystemExit(0)
print(Path('summary.json' if sys.argv[4] == 'summary' else 'tree.json').read_text())
''',
            }
            for name, body in tools.items():
                path = bin_path / name
                path.write_text('#!' + sys.executable + '\n' + body + '\n')
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_path) + os.pathsep + os.environ['PATH'],
                       SCENARIO=scenario, CI='true')
            for key in list(env):
                if key.startswith('HARC_'):
                    env.pop(key)
            result = subprocess.run(['bash', str(scripts / SCRIPT.name)], cwd=root,
                                    env=env, capture_output=True, text=True, timeout=20)
            def lines(name):
                p = root / name
                return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []
            gate_path = root / '.build/mobile-configuration/configuration-execution-gate.json'
            gate = json.loads(gate_path.read_text()) if gate_path.exists() else None
            return result, lines('calls.jsonl'), lines('xcode.jsonl'), gate, (root / 'exports.txt').exists()

    def test_success_uses_separate_bounded_stages_and_same_products(self):
        result, guards, builds, gate, exported = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(gate['passed'])
        self.assertTrue(exported)
        self.assertEqual([a[a.index('--timeout-seconds') + 1] for a in guards], ['1800', '1500'])
        self.assertEqual([a[a.index('--diagnostics-dir') + 1] for a in guards],
                         ['.build/mobile-configuration/build-diagnostics', '.build/mobile-configuration/diagnostics'])
        self.assertEqual([a[-1] for a in builds], ['build-for-testing', 'test-without-building'])
        test_args = builds[1][:-1]
        i = test_args.index('-resultBundlePath')
        self.assertEqual(test_args[i + 1], '.build/mobile-configuration/configuration.xcresult')
        del test_args[i:i + 2]
        self.assertEqual(builds[0][:-1], test_args)
        self.assertIn('HARC_BUILD_SHA=fixture-exact-source', test_args)
        self.assertEqual(test_args[test_args.index('-jobs') + 1], '2')

    def test_build_failure_never_launches_tests_or_exports_results(self):
        result, guards, builds, gate, exported = self.invoke('build-failure')
        self.assertEqual(result.returncode, 65)
        self.assertEqual(len(guards), 1)
        self.assertEqual(len(builds), 1)
        self.assertIsNone(gate)
        self.assertFalse(exported)

    def test_test_failure_or_timeout_cannot_become_a_pass(self):
        for scenario, code in [('test-failure', 65), ('timeout', 124)]:
            with self.subTest(scenario=scenario):
                result, guards, _, gate, exported = self.invoke(scenario)
                self.assertEqual(result.returncode, code)
                self.assertEqual(len(guards), 2)
                self.assertIsNone(gate)
                self.assertFalse(exported)

    def test_missing_or_corrupt_result_fails_closed(self):
        for scenario in ('missing-result', 'corrupt-result'):
            with self.subTest(scenario=scenario):
                result, _, _, gate, exported = self.invoke(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(exported)
                self.assertFalse(gate and gate['passed'])

    def test_timeout_change_preserves_exact_selection_and_gate_requirements(self):
        # Baseline 1dd2ae5; unrelated test-selection edits need separate review.
        source = SCRIPT.read_text()
        for pattern, expected in [
            (r'-only-testing:([^\s\\]+)', '407998521d470d814d8c6a2715fa2f4c88d4cbdcbe7bff82ee12bb582bc5b220'),
            (r'--require-test ([^\s\\]+)', '2cbd496ce3a41e5dd790c52320aee39ebb22ae4b8c9ede201080b71836ffb24c'),
        ]:
            self.assertEqual(hashlib.sha256('\n'.join(re.findall(pattern, source)).encode()).hexdigest(), expected)


if __name__ == '__main__':
    unittest.main()
