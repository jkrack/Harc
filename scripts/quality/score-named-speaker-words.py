#!/usr/bin/env python3
"""Diagnostic word error by explicit identity; never optimize the identity mapping.

Input: {"cases": [{"id": str, "reference": {identity: text},
                  "hypothesis": {identity: text}}]}.
Only explicitly selected identities are assessed. Prepare hypothesis text from
actual named output, excluding UI notices. Unknown/overlap words are not credited
to a known identity: missing reference words remain deletions. This measures the
combined transcription and naming result, not pure voice-matching accuracy.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path


def tokens(text):
    if not isinstance(text, str):
        raise ValueError('Speaker text must be a string')
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text.lower())


def edit_counts(reference, hypothesis):
    if len(reference) * len(hypothesis) > 4_000_000:
        raise ValueError('Split long evaluations into fixed excerpts before scoring')
    # Cells contain distance, substitutions, deletions, insertions, correct words.
    # Equal-cost paths prefer diagonal, then deletion, then insertion; the total
    # edit distance is invariant, but the individual breakdown can be ambiguous.
    previous = [(j, 0, 0, j, 0) for j in range(len(hypothesis) + 1)]
    for i, ref in enumerate(reference, 1):
        current = [(i, 0, i, 0, 0)]
        for j, hyp in enumerate(hypothesis, 1):
            d, s, missing, extra, correct = previous[j-1]
            different = int(ref != hyp)
            diagonal = (d+different, s+different, missing, extra, correct+1-different)
            d, s, missing, extra, correct = previous[j]
            deletion = (d+1, s, missing+1, extra, correct)
            d, s, missing, extra, correct = current[j-1]
            insertion = (d+1, s, missing, extra+1, correct)
            current.append(min((diagonal, deletion, insertion), key=lambda cell: cell[0]))
        previous = current
    distance, substitutions, deletions, insertions, correct = previous[-1]
    return dict(referenceWords=len(reference), hypothesisWords=len(hypothesis),
                wordEdits=distance, substitutions=substitutions, deletions=deletions,
                insertions=insertions, correctWords=correct,
                wordErrorRate=distance/len(reference) if reference else None)


def score(payload):
    cases = payload['cases']
    if not cases or len({c['id'] for c in cases}) != len(cases):
        raise ValueError('Require nonempty cases with unique IDs')
    results = []
    for case in cases:
        reference, hypothesis = case['reference'], case['hypothesis']
        if not isinstance(reference, dict) or not isinstance(hypothesis, dict):
            raise ValueError('Require identity-to-text mappings')
        identities = sorted(set(reference) | set(hypothesis))
        if not identities or any(not isinstance(name, str) or not name.strip() for name in identities):
            raise ValueError('Require explicit nonempty identities')
        results.append(dict(id=case['id'], identities={name: edit_counts(
            tokens(reference.get(name, '')), tokens(hypothesis.get(name, '')))
            for name in identities}))
    totals = {key: sum(row[key] for case in results for row in case['identities'].values())
              for key in ['referenceWords', 'hypothesisWords', 'wordEdits', 'substitutions',
                          'deletions', 'insertions', 'correctWords']}
    totals['wordErrorRate'] = totals['wordEdits']/totals['referenceWords'] if totals['referenceWords'] else None
    return dict(scope=__doc__.strip(), evaluationScope=payload.get('scope'),
                normalization='Lowercase ASCII alphanumeric words with internal apostrophes; no filler removal.',
                cases=results, totals=totals)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    raw = args.input.read_bytes()
    result = score(json.loads(raw))
    result['inputSHA256'] = hashlib.sha256(raw).hexdigest()
    args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
