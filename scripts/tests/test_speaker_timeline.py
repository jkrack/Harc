import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('scorer', Path(__file__).parents[1] / 'quality/score-speaker-timeline.py')
scorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorer)

class TimelineTests(unittest.TestCase):
    def test_unknown_wrongly_named_is_not_correct_cluster_count(self):
        result = scorer.score([dict(identity='unknown', startMs=0, endMs=100)],
                              [dict(speaker=0, startMs=0, endMs=100)], {0: 'Alice'})
        self.assertEqual(result['unknownNamedKnownMs'], 100)
        self.assertEqual(result['exactIdentitySetMs'], 0)

    def test_overlap_requires_both_identities(self):
        result = scorer.score([dict(identity=n, startMs=0, endMs=100) for n in ['Alice', 'Bob']],
                              [dict(speaker=0, startMs=0, endMs=100)], {0: 'Alice'})
        self.assertEqual(result['missingIdentityMs'], 100)
        self.assertEqual(result['exactIdentitySetMs'], 0)

    def test_disjoint_publication_is_scored_once(self):
        result = scorer.score([dict(identity='Alice', startMs=0, endMs=100)],
                              [dict(speaker=0, startMs=a, endMs=b) for a,b in [(0,50),(50,100)]], {0:'Alice'})
        self.assertEqual(result['referenceMs'], 100)
        self.assertEqual(result['exactIdentitySetMs'], 100)

    def test_missing_match_row_is_invalid(self):
        with self.assertRaises(ValueError):
            scorer.score([dict(identity='Alice', startMs=0, endMs=100)],
                         [dict(speaker=0, startMs=0, endMs=100)], {})
