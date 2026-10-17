#!/usr/bin/env python3
"""Fail-closed single-speaker identity diagnostic; not a mixed-speaker/DER gate.

Corpus cases require id and expectedIdentity (literal 'unknown' for unenrolled
voices). kind='enroll' validates enrollment structure but is excluded from query
accuracy. Every case needs exactly one detected speaker and a matching decision
row; absence of speech is not successful unknown rejection.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def indexed(rows, label):
    result = {}
    for row in rows:
        if row['id'] in result:
            raise ValueError(f'Duplicate {label} id: {row["id"]}')
        result[row['id']] = row
    return result


def evaluate(corpus, results, matches):
    cases = indexed(corpus['cases'], 'corpus')
    if not cases:
        raise ValueError('Empty corpus')
    outputs = indexed(results, 'result')
    decisions = {}
    for row in matches:
        key = (row['id'], row['speakerIndex'])
        if key in decisions:
            raise ValueError(f'Duplicate decision: {key}')
        decisions[key] = row
    if set(outputs) - set(cases) or {r['id'] for r in matches} - set(cases):
        raise ValueError('Unexpected case output')
    scored = []
    for key, case in cases.items():
        if 'sourceWindows' in case or not isinstance(case.get('expectedIdentity'), str):
            raise ValueError('This checker requires single-speaker expectedIdentity cases')
        reasons = []
        output = outputs.get(key)
        if output is None:
            reasons.append('missing_result')
        elif output.get('error'):
            reasons.append('inference_error')
        elif len(output.get('speakers', [])) != 1 or not output.get('segments'):
            reasons.append('expected_one_detected_speaker')
        else:
            vector = output['speakers'][0].get('vector', [])
            valid_vector = bool(vector) and all(
                isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
                for v in vector
            ) and any(v != 0 for v in vector)
            if not valid_vector:
                reasons.append('invalid_speaker_embedding')
            for segment in output['segments']:
                start, end = segment.get('startMs'), segment.get('endMs')
                if not (isinstance(start, (int, float)) and isinstance(end, (int, float))
                        and math.isfinite(start) and math.isfinite(end) and 0 <= start < end):
                    reasons.append('invalid_speech_interval')
                    break
            speaker = output['speakers'][0]['speakerIndex']
            case_decisions = {index for case_id, index in decisions if case_id == key}
            if case_decisions != {speaker}:
                reasons.append('missing_or_extra_identity_decision')
            elif any(segment['speaker'] != speaker for segment in output['segments']):
                reasons.append('segment_speaker_mismatch')
            else:
                actual = decisions[(key, speaker)].get('matched') or 'unknown'
                if actual != case['expectedIdentity']:
                    reasons.append('wrong_identity' if actual != 'unknown' else 'unrecognized_known_voice')
        scored.append(dict(id=key, enrollment=case.get('kind') == 'enroll',
                           passed=not reasons, reasons=reasons))
    queries = [r for r in scored if not r['enrollment']]
    if not queries:
        raise ValueError('No query cases; enrollment replay is not an accuracy test')
    return dict(scope='Single-speaker diagnostic only; not meeting qualification',
                passed=all(r['passed'] for r in scored), queryCount=len(queries),
                passedQueries=sum(r['passed'] for r in queries),
                failedQueries=sum(not r['passed'] for r in queries),
                enrollmentCount=len(scored)-len(queries), cases=scored)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['corpus', 'results', 'matches', 'output']:
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    report = evaluate(*(json.loads(getattr(args, name).read_text())
                        for name in ['corpus', 'results', 'matches']))
    report['inputs'] = {name: dict(path=str(getattr(args, name)),
                                 sha256=hashlib.sha256(getattr(args, name).read_bytes()).hexdigest())
                        for name in ['corpus', 'results', 'matches']}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'{report["passedQueries"]}/{report["queryCount"]} query cases passed; '
          f'{report["enrollmentCount"]} enrollment cases excluded from accuracy')
    raise SystemExit(0 if report['passed'] else 1)


if __name__ == '__main__':
    main()
