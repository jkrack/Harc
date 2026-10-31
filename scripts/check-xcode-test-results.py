#!/usr/bin/env python3
"""Fail closed on incomplete Xcode test execution, using xcresulttool JSON."""
import argparse
import json
from pathlib import Path


def check(summary, tree, required_bundles, required_tests):
    errors = []
    if summary.get('result') != 'Passed':
        errors.append('summary result is not Passed')
    for key in ('failedTests', 'skippedTests', 'expectedFailures'):
        if type(summary.get(key)) is not int or summary[key] != 0:
            errors.append(f'{key} must be explicitly zero')
    total = summary.get('totalTestCount')
    if type(total) is not int or total <= 0:
        errors.append('totalTestCount must be positive')
    if type(summary.get('passedTests')) is not int or summary['passedTests'] != total:
        errors.append('passedTests must equal totalTestCount')
    if summary.get('testFailures') != []:
        errors.append('testFailures must be explicitly empty')

    tests = {}
    bundles = set()

    def walk(node, bundle=None):
        kind = node.get('nodeType', '')
        if 'bundle' in kind.lower():
            bundle = node.get('name')
            if not isinstance(bundle, str) or not bundle:
                errors.append('test bundle has no name')
            else:
                bundles.add(bundle)
        if node.get('result') not in (None, 'Passed'):
            errors.append(f"nonpassing node: {node.get('name')} ({node.get('result')})")
        if kind == 'Arguments' and node.get('result') != 'Passed':
            errors.append('parameterized argument result is not explicitly Passed')
        if kind == 'Test Case':
            identifier = node.get('nodeIdentifier')
            if not bundle or not isinstance(identifier, str) or not identifier:
                errors.append('test case has no bundle or identifier')
            else:
                key = f'{bundle}/{identifier.removesuffix("()")}'
                if key in tests:
                    errors.append(f'duplicate test case: {key}')
                tests[key] = node.get('result')
                if node.get('result') != 'Passed':
                    errors.append(f'test did not pass: {key}')
        for child in node.get('children', []):
            walk(child, bundle)

    for node in tree.get('testNodes', []):
        walk(node)
    if not tests or len(tests) != total:
        errors.append(f'test tree count {len(tests)} differs from summary {total}')
    for bundle in required_bundles:
        if bundle not in bundles or not any(key.startswith(bundle + '/') for key in tests):
            errors.append(f'required bundle missing or empty: {bundle}')
    for key in required_tests:
        key = key.removesuffix('()')
        if tests.get(key) != 'Passed':
            errors.append(f'required test missing or not passed: {key}')
    return {'passed': not errors, 'errors': errors, 'testCount': len(tests),
            'bundles': sorted(bundles), 'tests': tests}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--summary', type=Path, required=True)
    parser.add_argument('--tests', type=Path, required=True)
    parser.add_argument('--require-bundle', action='append', required=True)
    parser.add_argument('--require-test', action='append', default=[])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        report = check(json.loads(args.summary.read_text()), json.loads(args.tests.read_text()),
                       args.require_bundle, args.require_test)
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
        report = {'passed': False, 'errors': [f'invalid result input: {error}']}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'tests'}))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
