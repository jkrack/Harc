import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "validate-xcode-package-resolution.py"
PROJECT = """packages:
  HarcCore:
    path: .
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.9.4
targets:
  Harc:
    platform: macOS
"""


class XcodePackageResolutionTests(unittest.TestCase):
    def setUp(self):
        self.committed = {
            "version": 3, "originHash": "a" * 64,
            "pins": [{"identity": "grdb.swift", "kind": "remoteSourceControl",
                      "location": "https://github.com/groue/GRDB.swift",
                      "state": {"revision": "b" * 40, "version": "7.0.0"}}],
        }
        self.working = copy.deepcopy(self.committed)
        self.working["originHash"] = "c" * 64
        self.working["pins"].append({
            "identity": "sparkle", "kind": "remoteSourceControl",
            "location": "https://github.com/sparkle-project/Sparkle",
            "state": {"version": "2.10.0", "revision": "eef1a539a373c1f1a320624b1130fc5de7b2e100"},
        })

    def check(self, expected, working=None, committed=None, project=PROJECT):
        with tempfile.TemporaryDirectory(prefix="harc-resolution-gate-") as scratch:
            root = Path(scratch)
            (root / "committed.json").write_text(json.dumps(self.committed if committed is None else committed))
            (root / "working.json").write_text(json.dumps(self.working if working is None else working))
            (root / "project.yml").write_text(project)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(root / "committed.json"),
                 str(root / "working.json"), str(root / "project.yml")],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_current_and_historical_versions_follow_project_range(self):
        for version in ["2.9.4", "2.9.6", "2.10.0"]:
            with self.subTest(version=version):
                self.working["pins"][-1]["state"]["version"] = version
                self.check(0)

    def test_requirement_is_read_from_project_not_a_second_version_allowlist(self):
        project = PROJECT.replace("from: 2.9.4", "from: 2.11.0")
        self.check(1, project=project)
        self.working["pins"][-1]["state"]["version"] = "2.11.0"
        self.check(0, project=project)

    def test_quoted_project_requirement_and_comments_are_supported(self):
        self.check(0, project=PROJECT.replace("from: 2.9.4", 'from: "2.9.4" # minimum'))

    def test_versions_outside_range_and_nonstable_versions_fail(self):
        for version in ["2.9.3", "3.0.0", "2.10.0-beta.1", "2.10", "02.10.0"]:
            with self.subTest(version=version):
                self.working["pins"][-1]["state"]["version"] = version
                self.check(1)

    def test_existing_dependency_version_revision_url_and_removal_drift_fail(self):
        for field, value in [("version", "7.1.0"), ("revision", "d" * 40)]:
            working = copy.deepcopy(self.working)
            working["pins"][0]["state"][field] = value
            self.check(1, working=working)
        working = copy.deepcopy(self.working)
        working["pins"][0]["location"] += "/unexpected"
        self.check(1, working=working)
        self.check(1, working={**self.working, "pins": [self.working["pins"][-1]]})

    def test_unexpected_added_dependency_and_root_metadata_fail(self):
        working = copy.deepcopy(self.working)
        working["pins"].append({"identity": "unexpected"})
        self.check(1, working=working)
        self.check(1, working={**self.working, "version": 4})
        self.check(1, working={**self.working, "unexpected": True})

    def test_wrong_sparkle_url_kind_branch_and_revision_fail(self):
        for field, value in [("location", "https://example.com/Sparkle"), ("kind", "localSourceControl")]:
            working = copy.deepcopy(self.working)
            working["pins"][-1][field] = value
            self.check(1, working=working)
        for state in [{"branch": "main", "revision": "e" * 40},
                      {"version": "2.10.0", "revision": "short"},
                      {"version": "2.10.0", "revision": "e" * 40, "branch": "main"}]:
            working = copy.deepcopy(self.working)
            working["pins"][-1]["state"] = state
            self.check(1, working=working)

    def test_duplicate_missing_or_committed_sparkle_fails(self):
        self.check(1, working={**self.working, "pins": self.working["pins"] * 2})
        self.check(1, working=self.committed)
        self.check(1, committed=self.working)

    def test_unknown_ambiguous_or_nonofficial_project_requirement_fails(self):
        for project in [PROJECT.replace("from:", "exactVersion:"),
                        PROJECT.replace("from: 2.9.4", "from: '2.9.4"),
                        PROJECT.replace("from: 2.9.4", "from: 2.9.4\n    branch: main"),
                        PROJECT.replace("from: 2.9.4", "from: 2.9.4\n    from: 2.10.0"),
                        PROJECT + PROJECT,
                        PROJECT.replace("https://github.com/sparkle-project/Sparkle", "https://example.com/Sparkle")]:
            with self.subTest(project=project):
                self.check(1, project=project)

    def test_origin_hash_may_change_but_must_remain_well_formed(self):
        self.check(0)
        self.check(1, working={**self.working, "originHash": "not-a-hash"})


if __name__ == "__main__":
    unittest.main()
