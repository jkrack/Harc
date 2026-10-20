import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class CIJobPartitionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = WORKFLOW.read_text()
        cls.package_job = workflow.split("  build:\n", 1)[1].split("  macos:\n", 1)[0]
        cls.macos_job = workflow.split("  macos:\n", 1)[1].split(
            "  mobile-configuration:\n", 1
        )[0]
        cls.mobile_job = workflow.split("  mobile-configuration:\n", 1)[1]

    def test_package_and_macos_compilation_are_separate_jobs(self):
        self.assertIn("Build package tests", self.package_job)
        self.assertIn("Direct pinned-TLS pairing lifecycle", self.package_job)
        self.assertNotIn("Build Harc.app", self.package_job)

        self.assertIn("Build Harc.app", self.macos_job)
        self.assertIn("macOS app and UI regression", self.macos_job)
        self.assertNotIn("Build package tests", self.macos_job)

    def test_each_heavy_job_keeps_the_hosted_runner_bound(self):
        self.assertIn("timeout-minutes: 60", self.package_job)
        self.assertIn("timeout-minutes: 60", self.macos_job)

    def test_independent_validation_jobs_do_not_wait_for_each_other(self):
        for job in [self.package_job, self.macos_job, self.mobile_job]:
            self.assertNotIn("needs:", job)

    def test_superseded_pr_runs_cancel_without_cancelling_main(self):
        workflow = WORKFLOW.read_text()
        self.assertIn("group: ci-${{ github.event.pull_request.number || github.ref }}", workflow)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", workflow)

    def test_publication_log_parent_exists_before_tee_opens_it(self):
        mkdir = self.package_job.index("mkdir -p build/validation")
        tee = self.package_job.index(
            "tee build/validation/publication-cross-volume.log"
        )
        self.assertLess(mkdir, tee)

    def test_macos_build_and_test_allow_checked_in_package_plugins(self):
        self.assertEqual(self.macos_job.count("-skipMacroValidation"), 2)
        self.assertEqual(self.macos_job.count("-skipPackagePluginValidation"), 2)


if __name__ == "__main__":
    unittest.main()
