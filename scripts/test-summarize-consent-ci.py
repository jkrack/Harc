import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('summary', pathlib.Path(__file__).with_name('summarize-consent-ci.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class SummaryTests(unittest.TestCase):
    def test_exact_failure_only_emits_line(self):
        text = '/private/path/HarcAppUITests.swift:63: error: -[HarcAppUITests.HarcAppUITests testProjectConnectionsExplicitSingleSourceConsent] : PRIVATE CONTENT'
        self.assertEqual(module.summarize(text), 'consent-failed-line-63')
    def test_pass(self):
        self.assertEqual(module.summarize("Test Case '-[HarcAppUITests.HarcAppUITests testProjectConnectionsExplicitSingleSourceConsent]' passed (1 second)."), 'consent-passed')
    def test_unrelated_and_injected_content_is_not_emitted(self):
        for text in ['', 'secret\nstatus=bad', 'HarcAppUITests.swift:63: error: -[Other testOther] : secret', 'HarcAppUITests.swift:99999999: error: -[HarcAppUITests.HarcAppUITests testProjectConnectionsExplicitSingleSourceConsent] : secret']:
            self.assertEqual(module.summarize(text), 'consent-result-unavailable')
    def test_failure_takes_precedence(self):
        prefix = "Test Case '-[HarcAppUITests.HarcAppUITests testProjectConnectionsExplicitSingleSourceConsent]' "
        self.assertEqual(module.summarize(prefix+'passed\n'+prefix+'failed'), 'consent-failed-location-unavailable')

if __name__ == '__main__':
    unittest.main()
