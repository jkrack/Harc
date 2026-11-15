#!/usr/bin/env python3
"""Temporary, bounded simulator-only trace collection; never a test/release gate."""
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

SUBSYSTEM = 'com.harc.recording-navigation-diagnostic'
EVENT = re.compile(
    r'event=(?:rootAppeared|rootDisappeared|renderedRequestChanged|recentTapped|'
    r'recentRequestAssigned|coverAppeared|coverDisappeared|coverDismissed|doneRequested)'
    r' requested=(?:true|false) setup=(?:true|false) library=(?:true|false)'
)


def bounded_events(text):
    """Do not retain OSLog paths, arbitrary messages or other process metadata."""
    events = []
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict) or row.get('subsystem') != SUBSYSTEM:
            continue
        message = row.get('eventMessage')
        if not isinstance(message, str) or not EVENT.fullmatch(message):
            continue
        if not isinstance(row.get('timestamp'), str) or type(row.get('processID')) is not int:
            continue
        events.append({key: row[key] for key in ('timestamp', 'processID', 'eventMessage')})
    return events


def collect(destination_file):
    report = {'scope': 'Diagnostic only; does not establish a fix or release readiness.', 'events': []}
    try:
        destination = json.loads(Path(destination_file).read_text())
        raw_udid = destination['udid']
        if not isinstance(raw_udid, str):
            return {**report, 'status': 'destination_unavailable'}
        udid = str(uuid.UUID(raw_udid))
    except (OSError, ValueError, KeyError, TypeError):
        return {**report, 'status': 'destination_unavailable'}
    try:
        # Xcode shuts the selected simulator down after tests. Its persisted log
        # survives a boot. Only boot this explicit CI simulator, never a phone.
        boot = subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'],
                              capture_output=True, text=True, timeout=45)
        if boot.returncode:
            return {**report, 'status': 'simulator_unavailable'}
        result = subprocess.run(
            ['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--style', 'ndjson',
             '--last', '40m', '--predicate', f'subsystem == "{SUBSYSTEM}"'],
            capture_output=True, text=True, timeout=30)
        if result.returncode:
            return {**report, 'status': 'log_unavailable'}
    except subprocess.TimeoutExpired:
        return {**report, 'status': 'collection_timed_out'}
    except OSError:
        return {**report, 'status': 'collector_unavailable'}
    report['events'] = bounded_events(result.stdout)
    report['status'] = 'collected' if report['events'] else 'no_matching_events'
    return report


if __name__ == '__main__':
    output = Path(sys.argv[2])
    output.parent.mkdir(parents=True, exist_ok=True)
    report = collect(sys.argv[1])
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(f"Recording navigation diagnostic: {report['status']}; {len(report['events'])} fixed events")
