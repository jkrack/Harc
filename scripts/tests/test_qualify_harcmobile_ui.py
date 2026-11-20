import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "qualify-harcmobile-ui.sh"
BASH = os.environ.get("HARC_QUALIFICATION_TEST_BASH", "bash")


class QualifyHarcMobileUITests(unittest.TestCase):
    def run_mock_qualification(self, root, summary, platform="physical", derived_data=None):
        """Exercise the real wrapper without Xcode, devices, or app storage."""
        repo = root / "repo"
        scripts = repo / "scripts"
        scripts.mkdir(parents=True)
        for name in (SCRIPT.name, "build-concurrency.sh"):
            shutil.copyfile(SCRIPT.parent / name, scripts / name)
        for args in (("init", "--quiet"), ("add", "."),
                     ("-c", "user.name=Qualification Test", "-c",
                      "user.email=qualification@example.invalid", "-c",
                      "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                      "commit", "--quiet", "-m", "fixture")):
            subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)
        tools = root / "tools"
        tools.mkdir()
        stubs = {
            "df": "printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 99999999 0 99999999 0%% /\\n'\n",
            "xcodebuild": 'printf "%s\\0" "$@" > "$FIXTURE_ARGUMENTS"\nwhile [[ $# -gt 0 ]]; do\n  if [[ "$1" == -resultBundlePath ]]; then mkdir -p "$2"; shift; fi\n  shift\ndone\n',
            "xcrun": 'if [[ "$1" == xcresulttool ]]; then cat "$FIXTURE_SUMMARY"; fi\n',
            "ditto": 'touch "${@: -1}"\n',
        }
        for name, body in stubs.items():
            path = tools / name
            path.write_text("#!/usr/bin/env bash\nset -eu\n" + body)
            path.chmod(0o755)
        summary_path = root / "summary.json"
        summary_path.write_text(json.dumps(summary) if summary is not None else "not JSON")
        output = root / "evidence"
        arguments = [BASH, str(scripts / SCRIPT.name), "--destination-id", "fixture-device",
                     "--platform", platform, "--output-dir", str(output), "--attempts", "1"]
        if platform == "physical":
            arguments += ["--development-team", "ABCDEFGHIJ"]
        if derived_data is not None:
            arguments += ["--derived-data-path", str(derived_data)]
        result = subprocess.run(
            arguments,
            env=dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                     FIXTURE_SUMMARY=str(summary_path), FIXTURE_ARGUMENTS=str(root / "arguments")),
            capture_output=True, text=True)
        return result, output

    def test_zero_xcode_status_cannot_accept_incomplete_or_failed_results(self):
        for summary in (None, {},
                        {"totalTestCount": 0, "passedTests": 0, "failedTests": 0},
                        {"totalTestCount": 1, "passedTests": 0, "failedTests": 0, "skippedTests": 1},
                        {"totalTestCount": 2, "passedTests": 1, "failedTests": 1}):
            with self.subTest(summary=summary), tempfile.TemporaryDirectory() as scratch:
                result, output = self.run_mock_qualification(Path(scratch), summary)
                self.assertTrue((output / "attempt-1.txt").exists(), result.stderr)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                receipt = (output / "qualification.txt").read_text()
                self.assertIn("selected_attempt=0\n", receipt)
                self.assertIn("xcode_status=0\n", receipt)
                self.assertIn("qualification_status=1\n", receipt)
                self.assertFalse((output / "HarcMobileUITests.xcresult.zip").exists())

    def test_executed_passing_attempt_is_retained(self):
        # macOS Bash 3.2 + nounset rejects unguarded empty-array expansions.
        # Exercise both optional arrays empty and populated, preserving argv.
        for platform in ("physical", "simulator"):
            for explicit_derived_data in (False, True):
                with self.subTest(platform=platform, derived_data=explicit_derived_data), \
                        tempfile.TemporaryDirectory() as scratch:
                    root = Path(scratch)
                    derived_data = root / "Derived Data" if explicit_derived_data else None
                    result, output = self.run_mock_qualification(root, {
                        "totalTestCount": 1, "passedTests": 1, "failedTests": 0},
                        platform=platform, derived_data=derived_data)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    receipt = (output / "qualification.txt").read_text()
                    self.assertIn("selected_attempt=1\n", receipt)
                    self.assertIn("qualification_status=0\n", receipt)
                    self.assertTrue((output / "HarcMobileUITests.xcresult.zip.sha256").exists())
                    arguments = (root / "arguments").read_bytes().decode().split("\0")[:-1]
                    self.assertNotIn("", arguments)
                    self.assertEqual("DEVELOPMENT_TEAM=ABCDEFGHIJ" in arguments, platform == "physical")
                    self.assertEqual("-derivedDataPath" in arguments, explicit_derived_data)
                    if explicit_derived_data:
                        self.assertEqual(arguments[arguments.index("-derivedDataPath") + 1], str(derived_data))

    def run_script(self, *arguments):
        return subprocess.run(
            [BASH, str(SCRIPT), *arguments],
            capture_output=True,
            text=True,
        )

    def test_derived_data_path_requires_value(self):
        result = self.run_script(
            "--destination-id",
            "fixture-device",
            "--platform",
            "simulator",
            "--output-dir",
            "/tmp/fixture-output",
            "--derived-data-path",
        )

        self.assertEqual(result.returncode, 64)
        self.assertIn("--derived-data-path requires a value", result.stderr)

    def test_existing_derived_data_path_is_rejected_before_build(self):
        with tempfile.TemporaryDirectory(prefix="harc-ui-qualification-test-") as scratch:
            root = Path(scratch)
            output = root / "evidence"
            derived_data = root / "DerivedData"
            derived_data.mkdir()

            result = self.run_script(
                "--destination-id",
                "fixture-device",
                "--platform",
                "simulator",
                "--output-dir",
                str(output),
                "--derived-data-path",
                str(derived_data),
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn("derived data path already exists", result.stderr)

    def test_relative_derived_data_path_is_rejected_before_build(self):
        with tempfile.TemporaryDirectory(prefix="harc-ui-qualification-test-") as scratch:
            output = Path(scratch) / "evidence"
            result = self.run_script(
                "--destination-id",
                "fixture-device",
                "--platform",
                "simulator",
                "--output-dir",
                str(output),
                "--derived-data-path",
                "relative-derived-data",
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn("derived data path must be absolute", result.stderr)


if __name__ == "__main__":
    unittest.main()
