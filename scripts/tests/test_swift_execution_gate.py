import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('swift_gate', Path(__file__).parents[1] / 'check-swift-test-results.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class SwiftGateTests(unittest.TestCase):
    def setUp(self):
        self.xml = '<testsuites><testsuite tests="1" skipped="1" failures="0" errors="0"><testcase classname="S" name="unit()"/><testcase classname="S" name="model()"><skipped>opt in</skipped></testcase></testsuite></testsuites>'
        self.log = """Test Case '-[X unit]' passed (0.01 seconds).
Test Case '-[X model]' skipped (0.01 seconds).
Test Suite 'All tests' passed at now.
 Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected)
✔ Test run with 2 tests in 1 suites passed after 0.1 seconds.
"""
        self.policy = {'swiftTesting': {'minimumDiscovered': 2, 'allowedSkips': {'S/model()': 'opt in'}},
                       'xctest': {'minimumDiscovered': 2, 'allowedSkips': {'X/model': 'opt in'}}}

    def result(self):
        return gate.check(self.xml, self.log, self.policy)

    def test_explicit_skips_count_separately(self):
        result = self.result()
        self.assertTrue(result['passed'], result)
        for counts in result['counts'].values():
            self.assertEqual(counts['passed'], 1)
            self.assertEqual(counts['skipped'], 1)

    def test_unapproved_skip_rejected_in_either_engine(self):
        for engine in self.policy:
            with self.subTest(engine=engine):
                policy = copy.deepcopy(self.policy)
                policy[engine]['allowedSkips'] = {}
                self.assertFalse(gate.check(self.xml, self.log, policy)['passed'])

    def test_missing_opt_in_test_rejected(self):
        self.policy['swiftTesting']['allowedSkips']['S/missing()'] = 'opt in'
        self.assertFalse(self.result()['passed'])

    def test_incomplete_or_duplicate_completion_rejected(self):
        for log in [self.log.split('✔')[0], self.log + self.log, self.log.replace("Test Suite 'All tests' passed", "Test Suite 'All tests' failed")]:
            self.assertFalse(gate.check(self.xml, log, self.policy)['passed'])

    def test_discovery_floor_rejected(self):
        self.policy['xctest']['minimumDiscovered'] = 3
        self.assertFalse(self.result()['passed'])

    def test_xml_counts_rejected(self):
        self.xml = self.xml.replace('tests="1"', 'tests="2"')
        self.assertFalse(self.result()['passed'])

    def test_case_failure_rejected_despite_green_summary(self):
        self.log = self.log.replace("unit]' passed", "unit]' failed")
        self.assertFalse(self.result()['passed'])

    def test_xctest_count_disagreement_rejected(self):
        self.log = self.log.replace('Executed 2', 'Executed 3')
        self.assertFalse(self.result()['passed'])

    def add_target(self):
        suite = '<testsuite tests="1" skipped="0" failures="0" errors="0"><testcase classname="Other" name="unit()"/></testsuite>'
        self.xml = self.xml.replace('</testsuites>', suite + '</testsuites>')
        self.log += """Test Case '-[OtherX unit]' passed (0.01 seconds).
Test Suite 'All tests' passed at later.
 Executed 1 tests, with 0 failures (0 unexpected)
✔ Test run with 1 test in 1 suite passed after 0.1 seconds.
"""

    def test_per_target_completions_and_singular_wording(self):
        self.add_target()
        self.assertTrue(self.result()['passed'], self.result())

    def test_empty_target_is_explicitly_completed(self):
        self.add_target()
        self.xml = self.xml.replace('</testsuites>', '<testsuite tests="0" skipped="0" failures="0" errors="0"/></testsuites>')
        self.log += "Test Suite 'All tests' passed at end.\n Executed 0 tests, with 0 failures (0 unexpected)\n✔ Test run with 0 tests in 0 suites passed after 0.1 seconds.\n"
        self.assertTrue(self.result()['passed'], self.result())

    def test_missing_target_completion_rejected(self):
        self.add_target()
        self.log = self.log.rsplit('✔', 1)[0]
        self.assertFalse(self.result()['passed'])

    def test_balanced_cross_target_count_errors_rejected(self):
        self.add_target()
        # Global total remains three, but the per-target counts are wrong.
        self.log = self.log.replace('Executed 2 tests, with 1 test', 'Executed 1 tests, with 1 test')
        self.log = self.log.replace('Executed 1 tests, with 0 failures', 'Executed 2 tests, with 0 failures')
        self.assertFalse(self.result()['passed'])

    def test_unfinished_final_xctest_target_rejected(self):
        self.log += "Test Case '-[OtherX unit]' passed (0.01 seconds).\n"
        self.assertFalse(self.result()['passed'])

    def test_duplicate_case_across_targets_rejected(self):
        self.add_target()
        self.xml = self.xml.replace('classname="Other"', 'classname="S"')
        self.assertFalse(self.result()['passed'])

    def test_nested_suites_rejected(self):
        self.xml = self.xml.replace('<testsuites>', '<testsuites><testsuite>').replace('</testsuites>', '</testsuite></testsuites>')
        self.assertFalse(self.result()['passed'])


if __name__ == '__main__':
    unittest.main()
