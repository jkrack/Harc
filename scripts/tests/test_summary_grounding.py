import importlib.util
from pathlib import Path
import json
import unittest
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("grounding", Path(__file__).parents[1] / "quality/check-summary-grounding.py")
grounding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grounding)


class GroundingTests(unittest.TestCase):
    lines = [{"speaker": "Ada", "text": "I will send the plan if legal approves."},
             {"speaker": "Bo", "text": "The old booking is cancelled."}]

    def payload(self):
        return {"facts": [{"claim": "Ada will send the plan if legal approves.",
                            "evidence": [{"utterance": 1, "quote": self.lines[0]["text"]}]}],
                "actions": [{"owner": "Ada", "task": "send plan if legal approves",
                             "evidence": [{"utterance": 1, "quote": self.lines[0]["text"]}]}]}

    def test_valid_quotes_report_coverage_without_claiming_completeness(self):
        _, covered = grounding.validate(json.dumps(self.payload()), self.lines)
        self.assertEqual(covered, [1])

    def test_source_mutation_or_wrong_citation_rejects_evidence(self):
        for citation in [{"utterance": 2, "quote": self.lines[0]["text"]},
                         {"utterance": 1, "quote": "I sent the plan."},
                         {"utterance": True, "quote": self.lines[0]["text"]},
                         {"utterance": 1, "quote": " "}]:
            with self.subTest(citation=citation), self.assertRaises(ValueError):
                value = self.payload()
                value["facts"][0]["evidence"] = [citation]
                grounding.validate(json.dumps(value), self.lines)

    def test_action_owner_must_have_cited_source(self):
        value = self.payload()
        value["actions"][0]["owner"] = "Bo"
        with self.assertRaises(ValueError):
            grounding.validate(json.dumps(value), self.lines)

    def test_duplicate_json_keys_and_empty_facts_fail(self):
        for raw in ['{"facts":[],"facts":[],"actions":[]}', '{"facts":[],"actions":[]}']:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                grounding.validate(raw, self.lines)

    def test_exact_evidence_does_not_establish_semantic_truth(self):
        value = self.payload()
        value["facts"][0]["claim"] = "Ada already sent the plan."
        # This validator deliberately cannot prove entailment. Keep this
        # limitation explicit so a quotation match is never an accuracy gate.
        grounding.validate(json.dumps(value), self.lines)

    def test_reasoning_requires_one_explicit_boundary(self):
        answer = json.dumps(self.payload())
        self.assertEqual(grounding.qwen_final_answer("scratch\n</think>\n" + answer), answer)
        for raw in [answer, "unfinished scratch", "scratch</think>answer</think>"]:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                grounding.qwen_final_answer(raw)

    def test_cli_rejects_empty_inventory_and_incomplete_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for cases, responses in [([], []),
                ([{"id": "one", "lines": self.lines, "actors": ["Ada"]}],
                 [{"id": "one", "raw": json.dumps(self.payload()), "stopReason": "cancelled"}])]:
                (root / "cases.json").write_text(json.dumps(cases))
                (root / "responses.json").write_text(json.dumps(responses))
                result = subprocess.run([sys.executable, str(spec.origin), str(root / "cases.json"),
                                         str(root / "responses.json"), str(root / "report.json")],
                                        capture_output=True)
                self.assertNotEqual(result.returncode, 0)
            report = json.loads((root / "report.json").read_text())
            self.assertFalse(report["results"][0]["sourceEvidenceValid"])
