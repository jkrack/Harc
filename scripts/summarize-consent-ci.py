#!/usr/bin/env python3
"""Expose only closed consent-test status tokens, never arbitrary log contents."""
import re
import sys
from pathlib import Path

TEST = 'testProjectConnectionsExplicitSingleSourceConsent'

def summarize(text: str) -> str:
    failed = re.findall(r'HarcAppUITests\.swift:([0-9]{1,5}): error: -\[HarcAppUITests\.HarcAppUITests ' + TEST + r'\] :', text)
    if failed:
        return 'consent-failed-line-' + str(int(failed[0]))
    if re.search(r"Test Case '-\[HarcAppUITests\.HarcAppUITests " + TEST + r"\]' failed", text):
        return 'consent-failed-location-unavailable'
    if re.search(r"Test Case '-\[HarcAppUITests\.HarcAppUITests " + TEST + r"\]' passed", text):
        return 'consent-passed'
    return 'consent-result-unavailable'

if __name__ == '__main__':
    try:
        text = Path(sys.argv[1]).read_text(errors='replace')
    except (IndexError, OSError):
        text = ''
    print(summarize(text))
