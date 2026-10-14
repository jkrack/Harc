import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'preflight-harcmobile-app-store.sh'
ACTIVE = 'docs/evidence/harcmobile-current-candidate-readiness.md'
HISTORICAL = 'docs/evidence/2026-08-09-harcmobile-app-store-readiness.md'
VALID = '**Candidate configuration:** HarcMobile 0.14.13 (68), iOS 18+, iPhone only'
OLD = '**Candidate configuration:** HarcMobile 0.14.10 (65), iOS 18+, iPhone only'


class CurrentCandidateReadinessTests(unittest.TestCase):
    def run_gate(self, active, historical):
        # Execute the actual candidate gate, independent of unrelated icon,
        # metadata and archive fixtures. The constant active path is unchanged.
        source = SCRIPT.read_text()
        gate = source[source.index('READINESS_EVIDENCE='):source.index('\nAVAILABLE_GIB=')]
        with tempfile.TemporaryDirectory(prefix='harc-candidate-gate-') as scratch:
            root = Path(scratch)
            for relative, value in ((ACTIVE, active), (HISTORICAL, historical)):
                if value is not None:
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(value + '\n')
            harness = root / 'gate.sh'
            harness.write_text('FAILURES=0\npass() { :; }\nfail() { FAILURES=$((FAILURES + 1)); }\n'
                               + gate + '\nexit "$FAILURES"\n')
            environment = dict(os.environ, REPO_ROOT=str(root),
                               EXPECTED_VERSION='0.14.13', EXPECTED_BUILD='68')
            return subprocess.run(['bash', str(harness)], env=environment,
                                  capture_output=True, text=True).returncode

    def test_current_record_matches_without_relabeling_history(self):
        self.assertEqual(self.run_gate(VALID, OLD), 0)

    def test_missing_current_record_cannot_use_matching_history(self):
        self.assertNotEqual(self.run_gate(None, VALID), 0)

    def test_stale_current_version_fails_even_when_history_matches(self):
        self.assertNotEqual(self.run_gate(OLD, VALID), 0)

    def test_wrong_current_build_fails(self):
        self.assertNotEqual(self.run_gate(VALID.replace('(68)', '(65)'), VALID), 0)

    def test_multiple_candidate_headers_are_ambiguous_and_fail(self):
        self.assertNotEqual(self.run_gate(VALID + '\n' + OLD, VALID), 0)


if __name__ == '__main__':
    unittest.main()
