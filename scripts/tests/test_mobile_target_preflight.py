import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'preflight-harcmobile-app-store.sh'
APP = '''  HarcMobile:
    type: application
    deploymentTarget: "26.0"
    info:
      properties:
        HarcBuildSHA: "$(HARC_BUILD_SHA)"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.harc.HarcMobile
        TARGETED_DEVICE_FAMILY: 1
        SUPPORTS_MACCATALYST: NO
        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO
        HARC_BUILD_SHA: unrecorded
'''
WIDGET = '''  HarcMobileWidgets:
    type: app-extension
    settings:
      base:
        SKIP_INSTALL: YES
'''
TESTS = '''  HarcMobileAppTests:
    type: bundle.unit-test
'''


class MobileTargetPreflightTests(unittest.TestCase):
    def run_gate(self, project):
        # Execute the production source gate without Apple-only plist/image
        # tooling. Do not duplicate its extraction or setting checks here.
        source = SCRIPT.read_text()
        gate = source[source.index('MOBILE_TARGET='):source.index('\nICON_SET=')]
        with tempfile.TemporaryDirectory(prefix='harc-mobile-target-') as scratch:
            root = Path(scratch)
            (root / 'project.yml').write_text(project)
            harness = ('set -eu\nFAILURES=0\npass() { :; }\n'
                       'fail() { echo "$*" >&2; FAILURES=$((FAILURES + 1)); }\n'
                       + gate + '\nexit "$FAILURES"\n')
            return subprocess.run(['bash', '-c', harness],
                                  env=dict(os.environ, REPO_ROOT=str(root)),
                                  capture_output=True, text=True, timeout=10)

    def assert_passes(self, project):
        result = self.run_gate(project)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_rejected(self, project):
        result = self.run_gate(project)
        self.assertNotEqual(result.returncode, 0, 'invalid app settings passed')

    def test_live_project_app_is_installable_despite_widget_skip_install(self):
        self.assert_passes((SCRIPT.parents[1] / 'project.yml').read_text())

    def test_widget_after_app_does_not_make_app_noninstallable(self):
        self.assert_passes('targets:\n' + APP + WIDGET + TESTS)

    def test_widget_before_app_is_independent_of_target_order(self):
        self.assert_passes('targets:\n' + WIDGET + APP + TESTS)

    def test_explicit_app_install_setting_still_passes(self):
        app = APP + '        SKIP_INSTALL: NO\n'
        self.assert_passes('targets:\n' + app + WIDGET + TESTS)

    def test_app_skip_install_yes_remains_a_failure(self):
        for setting in ('        SKIP_INSTALL: YES\n',
                        '      configs:\n        Release:\n          SKIP_INSTALL: YES\n'):
            with self.subTest(setting=setting):
                self.assert_rejected('targets:\n' + APP + setting + WIDGET + TESTS)

    def test_widget_cannot_supply_missing_app_requirements(self):
        requirements = [line for line in APP.splitlines(keepends=True)
                        if any(key in line for key in (
                            'deploymentTarget:', 'HarcBuildSHA:',
                            'PRODUCT_BUNDLE_IDENTIFIER:', 'TARGETED_DEVICE_FAMILY:',
                            'SUPPORTS_MACCATALYST:', 'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD:',
                            'HARC_BUILD_SHA:'))]
        for line in requirements:
            with self.subTest(setting=line.strip()):
                app = APP.replace(line, '')
                # A sibling deliberately has every matching value and does not
                # skip install: only the app may satisfy the app gate.
                sibling = APP.replace('  HarcMobile:', '  HarcMobileWidgets:').replace(
                    'type: application', 'type: app-extension')
                self.assert_rejected('targets:\n' + app + sibling + TESTS)

    def test_arbitrary_peer_target_stops_extraction(self):
        sibling = WIDGET.replace('HarcMobileWidgets:', 'AnotherExtension:')
        self.assert_passes('targets:\n' + APP + sibling + TESTS)

    def test_following_top_level_section_is_not_part_of_last_target(self):
        self.assert_passes('targets:\n' + APP + 'schemes:\n  Other:\n    SKIP_INSTALL: YES\n')

    def test_comments_do_not_end_app_target(self):
        app = APP.replace('    settings:', '  # app settings below\n    settings:')
        self.assert_passes('targets:\n' + app + WIDGET + TESTS)

    def test_missing_app_target_fails_even_with_matching_sibling(self):
        self.assert_rejected('targets:\n' + APP.replace('HarcMobile:', 'HarcMobileWidgets:'))


if __name__ == '__main__':
    unittest.main()
