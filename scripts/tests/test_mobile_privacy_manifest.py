import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/preflight-harcmobile-app-store.sh"


class MobilePrivacyManifestTests(unittest.TestCase):
    def run_gate(self, manifest, scope="source"):
        source = SCRIPT.read_text()
        helpers = source[source.index("require_equal() {"):source.index("require_nonempty() {")]
        manifest_path = {"source": "$REPO_ROOT/HarcMobileApp/PrivacyInfo.xcprivacy",
                         "archive": "$APP/PrivacyInfo.xcprivacy",
                         "distribution": "$DISTRIBUTION_APP/PrivacyInfo.xcprivacy"}[scope]
        tracking = source.index('plutil -extract NSPrivacyTracking raw', source.index(manifest_path) if scope == "source" else source.index('if [[ -f "' + manifest_path))
        start = source.rfind("require_equal", 0, tracking)
        helper = "require_mobile_privacy_manifest" if "require_mobile_privacy_manifest" in source else "require_mobile_required_reason_apis"
        call = source.index(helper, tracking)
        end = source.index('\n', source.index('\n', source.index('\n', call) + 1) + 1)
        gate = source[start:end]
        with tempfile.TemporaryDirectory(prefix="harc-privacy-fixture-") as scratch:
            root = Path(scratch)
            (root / "HarcMobileApp").mkdir()
            (root / "HarcMobileApp/PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(manifest))
            # Run the real production gate, without unrelated release/device checks.
            harness = ("set -u\nFAILURES=0\npass() { :; }\n"
                       'fail() { echo "$*" >&2; FAILURES=$((FAILURES + 1)); }\n'
                       + helpers + gate + '\nexit "$FAILURES"\n')
            return subprocess.run(["bash", "-c", harness], env=dict(os.environ, REPO_ROOT=str(root), APP=str(root / "HarcMobileApp"),
                                                  DISTRIBUTION_APP=str(root / "HarcMobileApp")),
                                  capture_output=True, text=True, timeout=15)

    def valid_manifest(self):
        return plistlib.loads((ROOT / "HarcMobileApp/PrivacyInfo.xcprivacy").read_bytes())

    def test_valid_manifest_and_optional_empty_domains_pass(self):
        manifest = self.valid_manifest()
        for with_domains in (False, True):
            if with_domains:
                manifest["NSPrivacyTrackingDomains"] = []
            for scope in ("source", "archive", "distribution"):
                with self.subTest(scope=scope, with_domains=with_domains):
                    result = self.run_gate(manifest, scope)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_privacy_declaration_types_cannot_impersonate_safe_values(self):
        for key, value in [("NSPrivacyTracking", "false"), ("NSPrivacyCollectedDataTypes", "0"),
                           ("NSPrivacyTrackingDomains", "0")]:
            with self.subTest(key=key):
                manifest = self.valid_manifest()
                manifest[key] = value
                for scope in ("source", "archive", "distribution"):
                    result = self.run_gate(manifest, scope)
                    self.assertNotEqual(result.returncode, 0, f"malformed {scope} declaration passed: {key}")


    def test_missing_unsafe_and_malformed_values_are_rejected(self):
        mutations = [
            lambda m: m.pop("NSPrivacyTracking"),
            lambda m: m.update(NSPrivacyTracking=True),
            lambda m: m.update(NSPrivacyTracking=0),
            lambda m: m.pop("NSPrivacyCollectedDataTypes"),
            lambda m: m.update(NSPrivacyCollectedDataTypes=[{}]),
            lambda m: m.update(NSPrivacyTrackingDomains=["tracker.invalid"]),
            lambda m: m.update(NSPrivacyTrackingDomains={}),
            lambda m: m.update(NSPrivacyAccessedAPITypes="2"),
            lambda m: m["NSPrivacyAccessedAPITypes"][0].update(NSPrivacyAccessedAPITypeReasons="1"),
            lambda m: m["NSPrivacyAccessedAPITypes"][0].update(NSPrivacyAccessedAPITypeReasons=["wrong"]),
            lambda m: m["NSPrivacyAccessedAPITypes"].append(m["NSPrivacyAccessedAPITypes"][0]),
        ]
        for index, mutate in enumerate(mutations):
            for scope in ("source", "archive", "distribution"):
                with self.subTest(mutation=index, scope=scope):
                    manifest = self.valid_manifest()
                    mutate(manifest)
                    result = self.run_gate(manifest, scope)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
