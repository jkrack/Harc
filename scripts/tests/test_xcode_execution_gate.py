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


class MobilePolishSelectionTests(unittest.TestCase):
    case = ('HarcMobileUITests/HarcMobileReleaseReadinessUITests/'
            'testRecordEmptyTodayRemainsNavigableAtLargestText')

    def test_polish_regression_is_selected_and_required(self):
        root = Path(__file__).resolve().parents[2]
        runner = (root / 'scripts/test-mobile-configuration.sh').read_text()
        self.assertIn('-only-testing:' + self.case + ' ', runner)
        self.assertIn('--require-test ' + self.case + ' ', runner)
        source = (root / 'HarcMobileUITests/HarcMobileReleaseReadinessUITests.swift').read_text()
        self.assertIn('func ' + self.case.rsplit('/', 1)[1] + '()', source)

    def test_polish_case_cannot_be_missing_or_skipped_in_an_otherwise_passing_run(self):
        summary = dict(result='Passed', failedTests=0, skippedTests=0,
                       expectedFailures=0, passedTests=1, totalTestCount=1, testFailures=[])
        other = dict(nodeType='Test Case', nodeIdentifier='Other/testExisting()', result='Passed')
        bundle = dict(nodeType='UI test bundle', name='HarcMobileUITests',
                      result='Passed', children=[other])
        tree = dict(testNodes=[bundle])
        self.assertFalse(gate.check(summary, tree, ['HarcMobileUITests'], [self.case])['passed'])
        polish = dict(nodeType='Test Case', nodeIdentifier=self.case.split('/', 1)[1] + '()',
                      result='Passed')
        bundle['children'].append(polish)
        summary.update(passedTests=2, totalTestCount=2)
        self.assertTrue(gate.check(summary, tree, ['HarcMobileUITests'], [self.case])['passed'])
        polish['result'] = 'Skipped'
        self.assertFalse(gate.check(summary, tree, ['HarcMobileUITests'], [self.case])['passed'])


class MobileLibrarySummarySelectionTests(MobilePolishSelectionTests):
    case = ('HarcMobileUITests/HarcMobileReleaseReadinessUITests/'
            'testLibraryDaySummaryRemainsReadableAtLargestText')


class MobileLibraryContrastSelectionTests(MobilePolishSelectionTests):
    case = ('HarcMobileUITests/HarcMobileReleaseReadinessUITests/'
            'testLibraryTextActionsHaveAccessibleContrast')


class MobileLongHostNameSelectionTests(MobilePolishSelectionTests):
    case = ('HarcMobileUITests/HarcMobileReleaseReadinessUITests/'
            'testLongHostNameKeepsRecordAndToolbarsUsable')


class MobileRecordingDetailSelectionTests(unittest.TestCase):
    suite = 'HarcMobileUITests/HarcMobileRecordingDetailUITests'
    names = (
        'testLocalDetailPlaybackSectionsAndReopening',
        'testLocalDetailRemainsUsableAtLargestDynamicType',
        'testStorageWarningSurvivesDoneRecentAndLibrary',
    )

    def test_detail_suite_and_each_required_case_are_selected_once(self):
        root = Path(__file__).resolve().parents[2]
        runner = (root / 'scripts/test-mobile-configuration.sh').read_text()
        self.assertEqual(runner.count('-only-testing:' + self.suite + ' '), 1)
        source = (root / 'HarcMobileUITests/HarcMobileRecordingDetailUITests.swift').read_text()
        for name in self.names:
            self.assertEqual(runner.count('--require-test ' + self.suite + '/' + name + ' '), 1)
            self.assertEqual(source.count('func ' + name + '()'), 1)

    def test_each_detail_case_must_execute_and_pass(self):
        required = [self.suite + '/' + name for name in self.names]
        cases = [dict(nodeType='Test Case', nodeIdentifier=key.split('/', 1)[1] + '()',
                      result='Passed') for key in required]
        summary = dict(result='Passed', failedTests=0, skippedTests=0,
                       expectedFailures=0, passedTests=3, totalTestCount=3, testFailures=[])
        tree = dict(testNodes=[dict(nodeType='UI test bundle', name='HarcMobileUITests',
                                   result='Passed', children=cases)])
        self.assertTrue(gate.check(summary, tree, ['HarcMobileUITests'], required)['passed'])
        for index, name in enumerate(self.names):
            with self.subTest(case=name):
                missing = copy.deepcopy(tree)
                del missing['testNodes'][0]['children'][index]
                smaller = dict(summary, passedTests=2, totalTestCount=2)
                self.assertFalse(gate.check(smaller, missing, ['HarcMobileUITests'], required)['passed'])
                skipped = copy.deepcopy(tree)
                skipped['testNodes'][0]['children'][index]['result'] = 'Skipped'
                self.assertFalse(gate.check(summary, skipped, ['HarcMobileUITests'], required)['passed'])


class MacSpeakerPlayheadSelectionTests(unittest.TestCase):
    suite = 'HarcAppUITests/HarcAppUITests'
    names = ('testPlaybackControlsSeekAndPause', 'testPlaybackControlsSeekAndPauseLight')

    def test_both_appearances_are_present_and_required_by_hosted_gate(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/ci.yml').read_text()
        source = (root / 'HarcAppUITests/HarcAppUITests.swift').read_text()
        for name in self.names:
            self.assertEqual(workflow.count('--require-test ' + self.suite + '/' + name + ' '), 1)
            self.assertEqual(source.count('func ' + name + '()'), 1)

    def test_missing_or_skipped_appearance_cannot_pass(self):
        required = [self.suite + '/' + name for name in self.names]
        cases = [dict(nodeType='Test Case', nodeIdentifier=key.split('/', 1)[1] + '()',
                      result='Passed') for key in required]
        summary = dict(result='Passed', failedTests=0, skippedTests=0,
                       expectedFailures=0, passedTests=2, totalTestCount=2, testFailures=[])
        tree = dict(testNodes=[dict(nodeType='UI test bundle', name='HarcAppUITests',
                                   result='Passed', children=cases)])
        self.assertTrue(gate.check(summary, tree, ['HarcAppUITests'], required)['passed'])
        for index, name in enumerate(self.names):
            with self.subTest(case=name):
                missing = copy.deepcopy(tree)
                del missing['testNodes'][0]['children'][index]
                self.assertFalse(gate.check(dict(summary, passedTests=1, totalTestCount=1),
                                            missing, ['HarcAppUITests'], required)['passed'])
                skipped = copy.deepcopy(tree)
                skipped['testNodes'][0]['children'][index]['result'] = 'Skipped'
                self.assertFalse(gate.check(summary, skipped, ['HarcAppUITests'], required)['passed'])


if __name__ == '__main__':
    unittest.main()
