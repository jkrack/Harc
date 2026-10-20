#!/usr/bin/env python3
"""Score anonymous clusters against annotated turns, with exact boundaries and no collar.

No enrolled identity claim: cluster assignment is optimized over the evaluated
excerpt. Annotation turns can include within-turn pauses. This is a segment-based
diagnostic, not a standardized AMI benchmark or open-set voice identification.
"""
import argparse
import hashlib
import json
from pathlib import Path


def score(reference, hypothesis, overlap, duration):
    for row in reference + hypothesis + overlap:
        if not 0 <= row['startMs'] < row['endMs'] <= duration:
            raise ValueError('Interval outside evaluated audio')
    labels = sorted({x['identity'] for x in reference})
    clusters = sorted({x['speaker'] for x in hypothesis})
    boundaries = sorted({0, duration} | {v for row in reference+hypothesis+overlap for v in (row['startMs'], row['endMs'])})
    spans = []
    weights = {c: [0]*len(labels) for c in clusters}
    for start, end in zip(boundaries, boundaries[1:]):
        refs = {r['identity'] for r in reference if r['startMs'] <= start < r['endMs']}
        hyps = {r['speaker'] for r in hypothesis if r['startMs'] <= start < r['endMs']}
        detected = any(r['startMs'] <= start < r['endMs'] for r in overlap)
        spans.append((end-start, refs, hyps, detected))
        for c in hyps:
            for i, label in enumerate(labels):
                weights[c][i] += (end-start)*(label in refs)
    # One-to-one maximum-duration mapping; extra clusters stay unmatched.
    states = {0: (0, {})}
    for cluster in clusters:
        next_states = dict(states)
        for mask, (weight, mapping) in states.items():
            for i, label in enumerate(labels):
                if mask & (1 << i): continue
                key = mask | (1 << i); candidate = weight + weights[cluster][i]
                if key not in next_states or candidate > next_states[key][0]:
                    next_states[key] = (candidate, dict(mapping, **{str(cluster): label}))
        states = next_states
    mapping = max(states.values(), key=lambda x: x[0])[1]
    totals = dict(referenceSpeakerMs=0, missedSpeakerMs=0, falseAlarmSpeakerMs=0,
                  confusedSpeakerMs=0, referenceOverlapMs=0, detectedOverlapMs=0, trueOverlapMs=0)
    for length, refs, hyps, detected in spans:
        correct = sum(mapping.get(str(c)) in refs for c in hyps)
        totals['referenceSpeakerMs'] += length*len(refs)
        totals['missedSpeakerMs'] += length*max(len(refs)-len(hyps),0)
        totals['falseAlarmSpeakerMs'] += length*max(len(hyps)-len(refs),0)
        totals['confusedSpeakerMs'] += length*(min(len(refs),len(hyps))-correct)
        totals['referenceOverlapMs'] += length*(len(refs)>1)
        totals['detectedOverlapMs'] += length*detected
        totals['trueOverlapMs'] += length*(len(refs)>1 and detected)
    def ratio(n,d): return n/d if d else None
    return dict(totals, bestAnonymousClusterMapping=mapping,
        segmentBasedErrorRate=ratio(sum(totals[k] for k in ('missedSpeakerMs','falseAlarmSpeakerMs','confusedSpeakerMs')),totals['referenceSpeakerMs']),
        overlapPrecision=ratio(totals['trueOverlapMs'],totals['detectedOverlapMs']),
        overlapRecall=ratio(totals['trueOverlapMs'],totals['referenceOverlapMs']))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('reference','results','output'): parser.add_argument(name,type=Path)
    args=parser.parse_args(); refs=json.loads(args.reference.read_text())['cases']; rows=json.loads(args.results.read_text())
    if len({r['id'] for r in rows}) != len(rows) or {r['id'] for r in refs} != {r['id'] for r in rows}: raise ValueError('Result inventory mismatch')
    results={r['id']:r for r in rows}; output={'scope':__doc__,'inputs':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in (args.reference,args.results)},'cases':[]}
    for case in refs:
        result=results[case['id']]
        if result.get('overlapRanges') is None: raise ValueError('Missing overlap assessment')
        output['cases'].append(dict(id=case['id'],**score(case['sourceWindows'],result['segments'],result['overlapRanges'],case['durationMs'])))
    args.output.write_text(json.dumps(output,indent=2)+'\n')


if __name__ == '__main__': main()
