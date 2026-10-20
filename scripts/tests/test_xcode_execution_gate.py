import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('execution_gate', Path(__file__).parents[1] / 'check-xcode-test-results.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ExecutionGateTests(unittest.TestCase):
    def setUp(self):
        self.summary = dict(result='Passed', failedTests=0, skippedTests=0,
                            expectedFailures=0, passedTests=1, totalTestCount=1, testFailures=[])
        self.case = dict(nodeType='Test Case', nodeIdentifier='Suite/required()', result='Passed')
        self.tree = dict(testNodes=[dict(nodeType='UI test bundle', name='UI', result='Passed', children=[self.case])])

    def check(self):
        return gate.check(self.summary, self.tree, ['UI'], ['UI/Suite/required'])

    def test_complete_run_passes(self):
        self.assertTrue(self.check()['passed'])

    def test_skipped_expected_or_failed_counts_rejected(self):
        for key in ('skippedTests', 'expectedFailures', 'failedTests'):
            with self.subTest(key=key):
                changed = copy.deepcopy(self.summary)
                changed[key] = 1
                self.assertFalse(gate.check(changed, self.tree, ['UI'], [])['passed'])

    def test_absent_summary_fields_fail_closed(self):
        for key in self.summary:
            with self.subTest(key=key):
                changed = copy.deepcopy(self.summary)
                del changed[key]
                self.assertFalse(gate.check(changed, self.tree, ['UI'], [])['passed'])

    def test_empty_run_rejected(self):
        self.summary.update(passedTests=0, totalTestCount=0)
        self.tree['testNodes'] = []
        self.assertFalse(self.check()['passed'])

    def test_missing_required_bundle_or_case_rejected(self):
        self.assertFalse(gate.check(self.summary, self.tree, ['App'], [])['passed'])
        self.assertFalse(gate.check(self.summary, self.tree, ['UI'], ['UI/Suite/other'])['passed'])

    def test_tree_skip_cannot_hide_behind_passing_summary(self):
        self.case['result'] = 'Skipped'
        self.assertFalse(self.check()['passed'])

    def test_parameter_failure_is_rejected(self):
        self.case['children'] = [dict(nodeType='Arguments', result='Failed', name='case 2')]
        self.assertFalse(self.check()['passed'])

    def test_passing_parameters_are_not_double_counted(self):
        self.case['children'] = [dict(nodeType='Arguments', result='Passed', name='case 1'),
                                 dict(nodeType='Arguments', result='Passed', name='case 2')]
        self.assertTrue(self.check()['passed'])

    def test_summary_tree_disagreement_rejected(self):
        self.summary.update(passedTests=2, totalTestCount=2)
        self.assertFalse(self.check()['passed'])

    def test_duplicate_case_rejected(self):
        self.tree['testNodes'][0]['children'].append(copy.deepcopy(self.case))
        self.assertFalse(self.check()['passed'])

    def test_missing_case_result_rejected(self):
        del self.case['result']
        self.assertFalse(self.check()['passed'])


if __name__ == '__main__':
    unittest.main()
