import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('named_speaker_words', Path(__file__).parents[1] / 'quality/score-named-speaker-words.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class NamedSpeakerWordTests(unittest.TestCase):
    def score(self, reference, hypothesis):
        return module.score({'cases': [dict(id='one', reference=reference, hypothesis=hypothesis)]})

    def test_perfect_text_under_swapped_names_is_not_perfect(self):
        result = self.score({'A': 'hello', 'B': 'goodbye'}, {'A': 'goodbye', 'B': 'hello'})
        self.assertEqual(result['totals']['wordErrorRate'], 1)
        self.assertEqual(result['totals']['substitutions'], 2)

    def test_unnamed_words_do_not_erase_missing_named_speech(self):
        result = self.score({'A': 'one two'}, {})
        self.assertEqual(result['totals']['deletions'], 2)
        self.assertEqual(result['totals']['wordErrorRate'], 1)

    def test_false_name_without_reference_counts_insertions(self):
        result = self.score({'A': 'one'}, {'A': 'one', 'B': 'two three'})
        self.assertEqual(result['totals']['wordErrorRate'], 2)
        self.assertIsNone(result['cases'][0]['identities']['B']['wordErrorRate'])
        self.assertEqual(result['totals']['insertions'], 2)

    def test_edit_breakdown_and_filler_retention(self):
        result = module.edit_counts(module.tokens("Well, I can't go."), module.tokens("I can't leave now"))
        self.assertEqual(result['wordEdits'], 3)
        self.assertEqual(result['wordEdits'], result['substitutions']+result['insertions']+result['deletions'])
        self.assertEqual(result['referenceWords'], result['correctWords']+result['substitutions']+result['deletions'])

    def test_empty_reference_has_no_invented_rate(self):
        self.assertIsNone(self.score({'A': ''}, {'A': ''})['totals']['wordErrorRate'])

    def test_duplicate_case_rejected(self):
        with self.assertRaises(ValueError):
            module.score({'cases': [dict(id='x', reference={}, hypothesis={})]*2})

if __name__ == '__main__':
    unittest.main()
