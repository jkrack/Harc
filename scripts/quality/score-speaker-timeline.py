#!/usr/bin/env python3
"""Score synthetic source-clip windows, not human-annotated speech or DER.

Reference JSON: {cases: [{id, sourceWindows: [{identity, startMs, endMs}]}]}.
Result JSON contains id/segments (speaker,startMs,endMs); match JSON contains
id/speakerIndex and optional matched. Missing matched means unknown, while a
missing match row is an invalid run. All intervals are half-open.
"""
import argparse
import hashlib
import json
from pathlib import Path


def score(windows, segments, identities):
    if any(s['speaker'] not in identities for s in segments):
        raise ValueError('Segment has no identity decision')
    for item in windows + segments:
        if not 0 <= item['startMs'] < item['endMs']:
            raise ValueError('Invalid interval')
    boundaries = sorted({v for x in windows + segments for v in (x['startMs'], x['endMs'])})
    totals = dict(referenceMs=0, exactIdentitySetMs=0, missingIdentityMs=0,
                  extraIdentityMs=0, unknownNamedKnownMs=0)
    for start, end in zip(boundaries, boundaries[1:]):
        expected = {w['identity'] for w in windows if w['startMs'] <= start < w['endMs']}
        if not expected:
            continue  # No scoring outside reference clip windows.
        actual = {identities[s['speaker']] for s in segments if s['startMs'] <= start < s['endMs']}
        duration = end - start
        totals['referenceMs'] += duration
        totals['exactIdentitySetMs'] += duration * (expected == actual)
        totals['missingIdentityMs'] += duration * bool(expected - actual)
        totals['extraIdentityMs'] += duration * bool(actual - expected)
        totals['unknownNamedKnownMs'] += duration * ('unknown' in expected and bool(actual - expected - {'unknown'}))
    return {k: round(v, 3) for k, v in totals.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('reference', 'results', 'matches', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    refs = json.loads(args.reference.read_text())['cases']
    results = json.loads(args.results.read_text())
    if len({r['id'] for r in results}) != len(results):
        raise ValueError('Duplicate result id')
    results = {r['id']: r for r in results}
    decisions = {}
    for row in json.loads(args.matches.read_text()):
        per_case = decisions.setdefault(row['id'], {})
        if row['speakerIndex'] in per_case:
            raise ValueError('Duplicate identity decision')
        per_case[row['speakerIndex']] = row.get('matched', 'unknown')
    output = {'scope': 'Synthetic source-clip timing; includes natural pauses. Not DER or human identity qualification.',
              'inputs': {name: {'path': str(getattr(args, name)), 'sha256': hashlib.sha256(getattr(args, name).read_bytes()).hexdigest()}
                         for name in ('reference', 'results', 'matches')}, 'cases': []}
    for ref in refs:
        result = results[ref['id']]
        output['cases'].append({'id': ref['id'], **score(ref['sourceWindows'], result['segments'], decisions.get(ref['id'], {}))})
    args.output.write_text(json.dumps(output, indent=2) + '\n')


if __name__ == '__main__':
    main()
