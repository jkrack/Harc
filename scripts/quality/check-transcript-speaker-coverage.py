#!/usr/bin/env python3
"""Flag detected speaker segments with no overlapping lexical ASR token.

Input is the retained daemon harness [{id,response:{type,payload}}] format.
This is a diagnostic for missing text, not WER, speaker accuracy, or proof of
complete speech coverage. Diarization and token timing can themselves be wrong.
Enrollment rows must be excluded by the caller. Exit 1 means evidence needs review;
exit 2 means invalid input. Punctuation alone is not evidence of transcribed speech.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def interval(item):
    start, end = item['startMs'], item['endMs']
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or
           not math.isfinite(v) for v in (start, end)) or not 0 <= start < end:
        raise ValueError('Invalid timing interval')
    return start, end


def assess(rows):
    seen = set()
    cases = []
    for row in rows:
        case_id = row['id']
        if not isinstance(case_id, str) or not case_id or case_id in seen:
            raise ValueError('Missing or duplicate case ID')
        seen.add(case_id)
        response = row['response']
        if response['type'] != 'result':
            cases.append(dict(id=case_id, issue='transcription_error', segments=[]))
            continue
        payload = response['payload']
        lexical = []
        for word in payload['words']:
            bounds = interval(word)
            if not isinstance(word['text'], str):
                raise ValueError('Invalid token text')
            if any(c.isalnum() for c in word['text']):
                lexical.append(bounds)
        segments = []
        for segment in payload['speakers']:
            start, end = interval(segment)
            speaker = segment['speaker']
            if isinstance(speaker, bool) or not isinstance(speaker, int) or speaker < 0:
                raise ValueError('Invalid speaker index')
            count = sum(a < end and b > start for a, b in lexical)
            segments.append(dict(speaker=speaker, startMs=start, endMs=end,
                                 overlappingLexicalTokens=count))
        issue = ('speaker_evidence_unavailable' if not segments else
                 'speech_without_timed_text' if any(s['overlappingLexicalTokens'] == 0
                                                   for s in segments) else None)
        cases.append(dict(id=case_id, issue=issue, segments=segments))
    if not cases:
        raise ValueError('Empty evaluation')
    return dict(scope='Diagnostic only: token overlap cannot prove transcription or identity accuracy.',
                caseCount=len(cases), casesNeedingReview=sum(c['issue'] is not None for c in cases),
                cases=cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    raw = args.input.read_bytes()
    try:
        report = assess(json.loads(raw))
    except (KeyError, TypeError, ValueError) as error:
        parser.exit(2, f'Invalid evaluation: {error}\n')
    report['inputSHA256'] = hashlib.sha256(raw).hexdigest()
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    return 1 if report['casesNeedingReview'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
