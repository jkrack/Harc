import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).parents[1] / "quality" / "sweep-speaker-confidence.py"
spec = importlib.util.spec_from_file_location("confidence_sweep", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ConfidenceSweepTests(unittest.TestCase):
    def fixture(self):
        return (
            {"cases": [{"id": "query", "durationMs": 1000, "sourceWindows": [
                {"identity": "B", "startMs": 0, "endMs": 500},
                {"identity": "C", "startMs": 500, "endMs": 1000}]}]},
            [{"id": "query", "segments": [{"speaker": 0, "startMs": 0, "endMs": 1000}],
              "overlapRanges": [{"startMs": 500, "endMs": 750}]}],
            [{"id": "query", "speakerIndex": 0, "matched": "B", "score": .83}])

    def test_high_confidence_mixed_cluster_exposes_cost_of_abstaining(self):
        report = module.sweep(*self.fixture(), [.65, .85], ["B"])
        baseline, strict = [r["totals"]["B"] for r in report["thresholds"]]
        self.assertEqual(baseline["correctNamedMs"], 500)
        self.assertEqual(baseline["wrongNamedOverSpeechMs"], 500)
        self.assertEqual(baseline["wrongNamedOutsideOverlapWarningMs"], 250)
        self.assertEqual(strict["wrongNamedOverSpeechMs"], 0)
        self.assertEqual(strict["missedKnownMs"], 500)
        self.assertFalse(report["qualified"])

    def test_missing_or_duplicate_decisions_are_errors(self):
        refs, results, matches = self.fixture()
        for invalid in ([], matches + matches):
            with self.assertRaises(ValueError):
                module.sweep(refs, results, invalid, [.65], ["B"])

    def test_invalid_scores_intervals_and_lower_threshold_rejected(self):
        refs, results, matches = self.fixture()
        with self.assertRaises(ValueError):
            module.sweep(refs, results, matches, [.6], ["B"])
        matches[0]["score"] = float("nan")
        with self.assertRaises(ValueError):
            module.sweep(refs, results, matches, [.65], ["B"])
        matches[0]["score"] = .8
        results[0]["segments"][0]["endMs"] = 1001
        with self.assertRaises(ValueError):
            module.sweep(refs, results, matches, [.65], ["B"])
