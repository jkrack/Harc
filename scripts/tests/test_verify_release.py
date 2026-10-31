"""Offline verifier command doubles; these do not validate macOS artifacts."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TEAM = '63TNU5M7P4'


class VerifyReleaseTests(unittest.TestCase):
    def run_verifier(self, target='', field='', value='', fail_display=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = (ROOT / 'scripts/verify-release.sh').read_text()
            # Only the disposable script changes platform command locations.
            for command in ('hdiutil', 'lipo'):
                script = script.replace('/usr/bin/' + command, command)
            script = script.replace('/private/tmp/harc-release-verify.', str(root / 'mount.'))
            (root / 'verify.sh').write_text(script)
            double = root / 'double'
            double.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'codesign' and '-d' in args:
    target = pathlib.Path(args[-1]).name
    if target == os.environ['TARGET'] and os.environ['FAIL_DISPLAY'] == '1':
        sys.exit(1)
    fields = {'TeamIdentifier': '63TNU5M7P4', 'Identifier': {'Harc.app': 'com.harc.Harc', 'harc-mcp': 'com.harc.Harc.mcp'}.get(target, target)}
    if target == os.environ['TARGET']:
        fields[os.environ['FIELD']] = os.environ['VALUE']
    for key, value in fields.items():
        if value != '<missing>':
            print(key + '=' + value, file=sys.stderr)
elif name == 'hdiutil' and 'attach' in args:
    mount = pathlib.Path(args[args.index('-mountpoint') + 1])
    (mount / 'Harc.app/Contents/MacOS').mkdir(parents=True)
elif name == 'plutil':
    print({'CFBundleShortVersionString':'1.2.3', 'CFBundleVersion':'42', 'CFBundleIdentifier':'com.harc.Harc', 'HarcRemoteRelayOrigin':'https://relay.adaptcontext.com', 'HarcBuildSHA':'a'*40}[args[1]])
elif name == 'lipo':
    print('arm64')
elif name == 'stat':
    print('7')
''')
            double.chmod(0o755)
            for command in ('codesign', 'hdiutil', 'xcrun', 'spctl', 'plutil', 'lipo', 'stat'):
                (root / command).symlink_to(double)
            dmg = root / 'candidate.dmg'
            dmg.write_bytes(b'fixture')
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       HARC_EXPECTED_BUILD_SHA='a'*40, TARGET=target, FIELD=field,
                       VALUE=value, FAIL_DISPLAY=str(int(fail_display)))
            return subprocess.run(['bash', str(root / 'verify.sh'), '1.2.3', '42', str(dmg)],
                                  env=env, capture_output=True, text=True, timeout=10)

    def test_expected_release_passes(self):
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Release candidate verified:', result.stdout)

    def test_wrong_or_missing_team_rejected_for_each_signed_target(self):
        for target in ('candidate.dmg', 'Harc.app', 'harc-stt', 'harc-mcp'):
            for value in ('WRONGTEAM0', '<missing>', '', 'not set', TEAM + '\nTeamIdentifier=WRONGTEAM0'):
                with self.subTest(target=target, value=value):
                    result = self.run_verifier(target, 'TeamIdentifier', value)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn('expected TeamIdentifier ' + TEAM, result.stderr)
                    self.assertNotIn('Release candidate verified:', result.stdout)

    def test_wrong_or_missing_signing_identifier_rejected(self):
        for target, expected in (('Harc.app', 'com.harc.Harc'), ('harc-mcp', 'com.harc.Harc.mcp')):
            for value in ('wrong.identifier', '<missing>', '', expected + '.suffix', expected + '\nIdentifier=' + expected):
                with self.subTest(target=target, value=value):
                    result = self.run_verifier(target, 'Identifier', value)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn('expected signing Identifier ' + expected, result.stderr)

    def test_display_failure_rejected(self):
        for target in ('candidate.dmg', 'Harc.app', 'harc-stt', 'harc-mcp'):
            with self.subTest(target=target):
                result = self.run_verifier(target, fail_display=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('cannot read signing identity', result.stderr)
