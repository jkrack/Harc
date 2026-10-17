import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('gate', Path(__file__).parents[1]/'quality/check-speaker-identification.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

class IdentificationGateTests(unittest.TestCase):
    def run_case(self, expected='unknown', matched=None, speakers=None, segments=None):
        return gate.evaluate({'cases':[dict(id='query', expectedIdentity=expected)]},
            [dict(id='query', speakers=speakers if speakers is not None else [dict(speakerIndex=0, vector=[1.0,0.0])],
                  segments=segments if segments is not None else [dict(speaker=0,startMs=0,endMs=100)])],
            [dict(id='query', speakerIndex=0, matched=matched)])

    def test_unknown_requires_detected_speech(self):
        self.assertTrue(self.run_case()['passed'])
        self.assertFalse(self.run_case(speakers=[],segments=[])['passed'])

    def test_known_voice_must_match(self):
        self.assertTrue(self.run_case('Alice','Alice')['passed'])
        self.assertFalse(self.run_case('Alice','Bob')['passed'])
        self.assertFalse(self.run_case('Alice')['passed'])

    def test_missing_result_fails(self):
        self.assertFalse(gate.evaluate({'cases':[dict(id='query', expectedIdentity='Alice')]},[],[])['passed'])

    def test_duplicate_result_invalid(self):
        with self.assertRaises(ValueError):
            gate.evaluate({'cases':[dict(id='q', expectedIdentity='Alice')]},[dict(id='q'),dict(id='q')],[])

    def test_enrollment_only_is_not_accuracy(self):
        with self.assertRaises(ValueError):
            gate.evaluate({'cases':[dict(id='e', kind='enroll',expectedIdentity='Alice')]},[],[])

    def test_fragmented_speaker_fails(self):
        self.assertFalse(self.run_case(speakers=[dict(speakerIndex=0),dict(speakerIndex=1)])['passed'])

    def test_mixed_reference_unsupported(self):
        with self.assertRaises(ValueError):
            gate.evaluate({'cases':[dict(id='q',expectedIdentity='Alice',sourceWindows=[])]},[],[])

    def test_empty_or_nonfinite_embedding_is_not_speech_evidence(self):
        for vector in [[], [0.0,0.0], [float('nan'),1.0]]:
            self.assertFalse(self.run_case(speakers=[dict(speakerIndex=0,vector=vector)])['passed'])

    def test_invalid_interval_does_not_count_as_detection(self):
        for start,end in [(0,0),(-1,10),(10,5),(0,float('inf'))]:
            self.assertFalse(self.run_case(segments=[dict(speaker=0,startMs=start,endMs=end)])['passed'])
