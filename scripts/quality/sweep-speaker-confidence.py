#!/usr/bin/env python3
"""Replay stricter thresholds over retained matcher decisions, without remapping identities.

Diagnostic activity timing, not word ownership, DER, or model holdout accuracy.
Only already accepted decisions may survive; rejected decisions never become
accepted. Scores are retained matcher scores, not probabilities. Silence outside
annotated lexical activity is reported separately, not classified as wrong speech.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def sweep(reference, results, matches, thresholds, known):
    if not known or len(set(known)) != len(known):
        raise ValueError("Require unique enrolled identities")
    if not thresholds or any(not math.isfinite(t) or not .65 <= t <= 1.000001 for t in thresholds):
        raise ValueError("Only stricter thresholds at or above the .65 baseline are supported")
    cases = reference["cases"]
    ids = [c["id"] for c in cases]
    if not cases or len(set(ids)) != len(ids):
        raise ValueError("Require unique nonempty cases")
    if len({r["id"] for r in results}) != len(results) or set(ids) != {r["id"] for r in results}:
        raise ValueError("Result inventory mismatch")
    outputs = {r["id"]: r for r in results}
    decisions = {}
    for row in matches:
        key = (row["id"], row["speakerIndex"])
        if key in decisions:
            raise ValueError("Duplicate identity decision")
        if row.get("matched") is not None:
            if row["matched"] not in known or not isinstance(row.get("score"), (int, float)) or not math.isfinite(row["score"]):
                raise ValueError("Invalid accepted matcher decision")
        decisions[key] = row
    prepared = []
    for case in cases:
        result = outputs[case["id"]]
        segments, windows = result["segments"], case["sourceWindows"]
        overlap = result["overlapRanges"]
        for row in segments + windows + overlap:
            if not 0 <= row["startMs"] < row["endMs"] <= case["durationMs"]:
                raise ValueError("Interval outside evaluated audio")
        if any((case["id"], s["speaker"]) not in decisions for s in segments):
            raise ValueError("Missing identity decision")
        bounds = sorted({0, case["durationMs"]} | {
            v for row in segments + windows + overlap for v in (row["startMs"], row["endMs"])})
        spans = []
        for start, end in zip(bounds, bounds[1:]):
            refs = {w["identity"] for w in windows if w["startMs"] <= start < w["endMs"]}
            active = [decisions[(case["id"], s["speaker"])] for s in segments if s["startMs"] <= start < s["endMs"]]
            warning = any(w["startMs"] <= start < w["endMs"] for w in overlap)
            spans.append((end-start, refs, active, warning))
        prepared.append((case["id"], spans))
    rows = []
    for threshold in thresholds:
        scored = []
        for case_id, spans in prepared:
            counts = {who: dict(referenceMs=0, correctNamedMs=0, missedKnownMs=0,
                wrongNamedOverSpeechMs=0, wrongNamedOutsideOverlapWarningMs=0,
                namedWithoutLexicalSupportMs=0) for who in known}
            for length, refs, active, warning in spans:
                names = {r["matched"] for r in active if r.get("matched") is not None and r["score"] >= threshold}
                for who, c in counts.items():
                    c["referenceMs"] += length * (who in refs)
                    c["correctNamedMs"] += length * (who in refs and who in names)
                    c["missedKnownMs"] += length * (who in refs and who not in names)
                    wrong = bool(refs) and who not in refs and who in names
                    c["wrongNamedOverSpeechMs"] += length * wrong
                    c["wrongNamedOutsideOverlapWarningMs"] += length * (wrong and not warning)
                    c["namedWithoutLexicalSupportMs"] += length * (not refs and who in names)
            scored.append(dict(id=case_id, identities=counts))
        totals = {who: {key: sum(c["identities"][who][key] for c in scored)
            for key in scored[0]["identities"][who]} for who in known}
        rows.append(dict(threshold=threshold, cases=scored, totals=totals))
    return dict(scope=__doc__, qualified=False, enrolledIdentities=known,
        excludedMatchCaseIDs=sorted({r["id"] for r in matches} - set(ids)), thresholds=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("reference", "results", "matches", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--known", nargs="+", required=True)
    parser.add_argument("--thresholds", nargs="+", type=float,
                        default=[.65, .70, .75, .80, .825, .85, .875, .90])
    args = parser.parse_args()
    paths = [args.reference, args.results, args.matches]
    payload = sweep(*(json.loads(p.read_text()) for p in paths), args.thresholds, args.known)
    payload["inputs"] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    payload["scriptSHA256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    args.output.write_text(json.dumps(payload, indent=2) + "\n")


if __name__ == "__main__":
    main()
