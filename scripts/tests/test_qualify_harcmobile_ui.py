import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "qualify-harcmobile-ui.sh"


class QualifyHarcMobileUITests(unittest.TestCase):
    def run_script(self, *arguments):
        return subprocess.run(
            ["bash", str(SCRIPT), *arguments],
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
