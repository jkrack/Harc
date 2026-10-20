import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / 'quality/check-transcript-speaker-coverage.py'
spec = importlib.util.spec_from_file_location('coverage_check', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def case(words, segments=None):
    return dict(id='query', response=dict(type='result', payload=dict(
        words=words, speakers=segments if segments is not None else [
            dict(speaker=0, startMs=0, endMs=1000),
            dict(speaker=1, startMs=2000, endMs=3000)])))


class CoverageTests(unittest.TestCase):
    def test_nonempty_text_does_not_hide_later_missing_turn(self):
        report = module.assess([case([dict(text='hello', startMs=100, endMs=800)])])
        self.assertEqual(report['casesNeedingReview'], 1)
        self.assertEqual([s['overlappingLexicalTokens'] for s in report['cases'][0]['segments']], [1, 0])

    def test_punctuation_is_not_speech_evidence(self):
        report = module.assess([case([dict(text='.', startMs=100, endMs=2200)])])
        self.assertEqual([s['overlappingLexicalTokens'] for s in report['cases'][0]['segments']], [0, 0])

    def test_half_open_boundaries(self):
        report = module.assess([case([dict(text='hello', startMs=1000, endMs=2000)])])
        self.assertEqual([s['overlappingLexicalTokens'] for s in report['cases'][0]['segments']], [0, 0])

    def test_unicode_lexical_tokens(self):
        report = module.assess([case([dict(text='你好', startMs=0, endMs=900),
                                     dict(text='café', startMs=2100, endMs=2500)])])
        self.assertEqual(report['casesNeedingReview'], 0)

    def test_no_speakers_is_unavailable(self):
        report = module.assess([case([], [])])
        self.assertEqual(report['cases'][0]['issue'], 'speaker_evidence_unavailable')

    def test_error_requires_review(self):
        report = module.assess([dict(id='failed', response=dict(type='error'))])
        self.assertEqual(report['casesNeedingReview'], 1)

    def test_empty_duplicate_and_invalid_timing_rejected(self):
        for rows in [[], [case([]), case([])],
                     [case([dict(text='x', startMs=float('nan'), endMs=1)])],
                     [case([dict(text='x', startMs=2, endMs=1)])]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                module.assess(rows)
