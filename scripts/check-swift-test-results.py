#!/usr/bin/env python3
"""Account for both Swift Testing XML and serial XCTest terminal log results."""
import argparse
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path


def check(xml_text, log, policy):
    errors = []
    root = ET.fromstring(xml_text)
    cases = list(root.iter('testcase'))
    swift = {}
    for case in cases:
        key = case.attrib['classname'] + '/' + case.attrib['name']
        if key in swift:
            errors.append('duplicate Swift Testing case: ' + key)
        swift[key] = 'skipped' if case.find('skipped') is not None else 'passed'
        if case.find('failure') is not None or case.find('error') is not None:
            swift[key] = 'failed'
    # Native SwiftPM emits one aggregate; Xcode 27's swiftbuild emits one
    # sibling suite and completion per target, including empty targets.
    suites = list(root.findall('testsuite')) if root.tag == 'testsuites' else []
    if not suites or len(suites) != len(list(root.iter('testsuite'))):
        errors.append('expected flat Swift Testing result suites')
        suites = []
    if sum(len(suite.findall('testcase')) for suite in suites) != len(cases):
        errors.append('Swift Testing cases outside result suites')
    expected_completions = []
    for suite in suites:
        members = list(suite.findall('testcase'))
        skipped = sum(case.find('skipped') is not None for case in members)
        if int(suite.attrib['tests']) != len(members) - skipped or int(suite.attrib['skipped']) != skipped:
            errors.append('Swift Testing XML counts disagree')
        if int(suite.attrib['failures']) != 0 or int(suite.attrib['errors']) != 0:
            errors.append('Swift Testing aggregate has failures/errors')
        expected_completions.append(len(members))
    completion = re.findall(r'Test run with (\d+) tests? in \d+ suites? passed after', log)
    if [int(value) for value in completion] != expected_completions:
        errors.append('missing or inconsistent Swift Testing completion')

    xct = {}
    pending = []
    completions = 0
    case_pattern = r"Test Case '-\[([^ ]+) ([^\]]+)\]' (passed|skipped|failed) \("
    completion_pattern = r"Test Suite 'All tests' passed at [^\n]+\n\s*Executed (\d+) tests, with (?:(\d+) tests? skipped and )?(\d+) failures"
    for match in re.finditer(case_pattern + '|' + completion_pattern, log):
        cls, method, result, total, skips, failures = match.groups()
        if cls is not None:
            key = cls + '/' + method
            if key in xct:
                errors.append('duplicate XCTest case: ' + key)
            xct[key] = result
            pending.append(result)
        else:
            completions += 1
            if int(total) != len(pending) or int(skips or 0) != pending.count('skipped') or int(failures) != 0:
                errors.append('XCTest completion counts disagree')
            pending.clear()
    if not completions or pending or "Test Suite 'All tests' failed" in log:
        errors.append('missing or failed XCTest completion')

    counts = {}
    for name, results in [('swiftTesting', swift), ('xctest', xct)]:
        section = policy[name]
        if len(results) < section['minimumDiscovered']:
            errors.append(f'{name}: discovered too few tests')
        for key, result in results.items():
            if result == 'failed':
                errors.append(f'{name}: failed {key}')
            if result == 'skipped' and key not in section['allowedSkips']:
                errors.append(f'{name}: unexpected skip {key}')
        # Opt-in tests remain part of discovery even when unavailable in CI.
        for key in section['allowedSkips']:
            if key not in results:
                errors.append(f'{name}: missing opt-in test {key}')
        counts[name] = {state: sum(v == state for v in results.values())
                        for state in ('passed', 'skipped', 'failed')}
        counts[name]['skippedTests'] = [key for key, value in results.items() if value == 'skipped']
    return {'passed': not errors, 'errors': errors, 'counts': counts}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for key in ('xml', 'log', 'policy', 'output'):
        p.add_argument('--' + key, type=Path, required=True)
    args = p.parse_args()
    try:
        result = check(args.xml.read_text(), args.log.read_text(), json.loads(args.policy.read_text()))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, ET.ParseError) as error:
        result = {'passed': False, 'errors': [f'invalid evidence: {error}']}
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
