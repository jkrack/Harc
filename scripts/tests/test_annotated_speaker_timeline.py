import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('annotated_speaker_timeline', Path(__file__).parents[1] / 'quality/score-annotated-speaker-timeline.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class AnnotatedTimelineTests(unittest.TestCase):
    def setUp(self):
        self.reference = [dict(identity='A', startMs=0, endMs=100), dict(identity='B', startMs=50, endMs=100)]
        self.hypothesis = [dict(speaker=9, startMs=0, endMs=100), dict(speaker=3, startMs=50, endMs=100)]

    def test_arbitrary_clusters_map_without_identity_claim(self):
        result = module.score(self.reference, self.hypothesis, [dict(startMs=50, endMs=100)], 100)
        self.assertEqual(result['segmentBasedErrorRate'], 0)
        self.assertEqual(result['overlapRecall'], 1)
        self.assertEqual(result['overlapPrecision'], 1)

    def test_missing_overlapping_speaker_counts_speaker_time(self):
        result = module.score(self.reference, self.hypothesis[:1], [], 100)
        self.assertEqual(result['referenceSpeakerMs'], 150)
        self.assertEqual(result['missedSpeakerMs'], 50)
        self.assertEqual(result['segmentBasedErrorRate'], 1/3)

    def test_silence_false_alarm_has_no_invented_denominator(self):
        result = module.score([], self.hypothesis[:1], [], 100)
        self.assertEqual(result['falseAlarmSpeakerMs'], 100)
        self.assertIsNone(result['segmentBasedErrorRate'])

    def test_fragmented_clusters_cannot_both_claim_same_reference(self):
        result = module.score([dict(identity='A', startMs=0, endMs=100)],
            [dict(speaker=1,startMs=0,endMs=50),dict(speaker=2,startMs=50,endMs=100)], [], 100)
        self.assertEqual(result['confusedSpeakerMs'], 50)

    def test_out_of_bounds_fails(self):
        with self.assertRaises(ValueError): module.score(self.reference, self.hypothesis, [], 99)
