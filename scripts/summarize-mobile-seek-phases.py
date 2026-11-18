#!/usr/bin/env python3
"""Read only fixed tokens emitted by the owned synthetic paused-seek UI test."""
PHASES = frozenset((
    "launch-start", "launch-complete", "recent-start", "recent-complete",
    "detail-confirmed", "reveal-play-start", "reveal-play-complete",
))
PREFIX = "HARC_SEEK_PHASE:"

def summarize(text):
    # Exact whole-line matching rejects payloads and arbitrary diagnostic text.
    # At most seven tokens; duplicates do not grow the report.
    found = []
    for line in text.splitlines():
        if line.startswith(PREFIX):
            phase = line[len(PREFIX):]
            if phase in PHASES and phase not in found:
                found.append(phase)
    return found
