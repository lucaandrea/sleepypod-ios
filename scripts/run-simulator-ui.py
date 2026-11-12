#!/usr/bin/env python3
"""Run the unchanged UI suite; recover once from a proven pre-test AX startup failure."""
import json
from pathlib import Path
import re
import subprocess
import sys

AX_FAILURE = ('The test runner failed to initialize for UI testing. '
              '(Underlying Error: Timed out waiting for AX loaded notification)')
AX_LOADING_FAILURE = ('The test runner failed to initialize for UI testing. '
                      '(Underlying Error: Timed out while loading Accessibility.)')
AX_STARTUP_FAILURES = (AX_FAILURE, AX_LOADING_FAILURE)
RUNNER_FAILURE = re.compile(r'^SleepypodUITests-Runner \([0-9]+\) encountered an error$')


def bootstrap_only(summary, tree):
    """Require both result views to prove no application test began."""
    if not isinstance(summary, dict) or not isinstance(tree, dict):
        return False
    if summary.get('result') != 'Failed' or any(summary.get(key) != value for key, value in {
        'passedTests': 0, 'skippedTests': 0, 'expectedFailures': 0,
        'failedTests': 1, 'totalTestCount': 1,
    }.items()):
        return False
    failures = summary.get('testFailures')
    if not isinstance(failures, list) or len(failures) != 1:
        return False
    failure = failures[0]
    if (not isinstance(failure, dict) or failure.get('failureText') not in AX_STARTUP_FAILURES
            or not RUNNER_FAILURE.fullmatch(failure.get('testIdentifierString', ''))):
        return False
    cases = []

    def visit(nodes, system_failure=False):
        if not isinstance(nodes, list):
            raise ValueError('Invalid test tree')
        for node in nodes:
            if not isinstance(node, dict):
                raise ValueError('Invalid test node')
            inside_system = system_failure or (node.get('nodeType') == 'Test Suite'
                                               and node.get('name') == 'System Failures')
            if node.get('nodeType') == 'Test Case':
                cases.append((node, inside_system))
            visit(node.get('children', []), inside_system)

    try:
        visit(tree.get('testNodes'))
    except ValueError:
        return False
    return (len(cases) == 1 and cases[0][1]
            and cases[0][0].get('result') == 'Failed'
            and RUNNER_FAILURE.fullmatch(cases[0][0].get('nodeIdentifier', '')) is not None)


def option(arguments, name):
    if arguments.count(name) != 1:
        raise ValueError(f'Expected exactly one {name}')
    index = arguments.index(name) + 1
    if index >= len(arguments):
        raise ValueError(f'Missing {name} value')
    return arguments[index]


def result_json(bundle, view):
    process = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', view,
                              '--path', str(bundle), '--format', 'json'],
                             text=True, capture_output=True, timeout=60, check=True)
    return json.loads(process.stdout)


def run(arguments):
    if not arguments or arguments[0] != 'test-without-building':
        raise ValueError('Only an already-built UI test run is supported')
    destination = option(arguments, '-destination')
    match = re.fullmatch(r'platform=iOS Simulator,id=([A-Fa-f0-9-]{36})', destination)
    if not match:
        raise ValueError('Expected one explicit iOS simulator identifier')
    bundle = Path(option(arguments, '-resultBundlePath'))
    if bundle.suffix != '.xcresult' or bundle.exists():
        raise ValueError('Expected a new result bundle')
    retry_bundle = bundle.with_name(bundle.stem + '-bootstrap-retry.xcresult')
    receipt = bundle.with_name(bundle.stem + '-bootstrap-recovery.json')
    if retry_bundle.exists() or receipt.exists():
        raise ValueError('Recovery evidence already exists')
    status = subprocess.run(['xcodebuild', *arguments]).returncode
    if status == 0:
        return 0
    try:
        summary, tree = result_json(bundle, 'summary'), result_json(bundle, 'tests')
        if not bootstrap_only(summary, tree):
            return status
    except (subprocess.SubprocessError, OSError, ValueError, TypeError):
        return status

    evidence = {'reason': summary['testFailures'][0]['failureText'], 'originalExit': status, 'originalResult': str(bundle),
                'retryResult': str(retry_bundle), 'retryAttempted': False}
    receipt.write_text(json.dumps(evidence, indent=2) + '\n')
    print('Simulator AX failed before any app test. Preserving the result and rebooting this simulator once.', flush=True)
    try:
        subprocess.run(['xcrun', 'simctl', 'shutdown', match.group(1)], check=True, timeout=120)
        subprocess.run(['xcrun', 'simctl', 'bootstatus', match.group(1), '-b'], check=True, timeout=240)
    except (subprocess.SubprocessError, OSError):
        return status
    retry_arguments = list(arguments)
    retry_arguments[retry_arguments.index('-resultBundlePath') + 1] = str(retry_bundle)
    evidence['retryAttempted'] = True
    receipt.write_text(json.dumps(evidence, indent=2) + '\n')
    retry_status = subprocess.run(['xcodebuild', *retry_arguments]).returncode
    # A nominally successful process must still contain executed, passing tests.
    if retry_status == 0:
        try:
            retry_summary = result_json(retry_bundle, 'summary')
            if (retry_summary.get('result') != 'Passed' or retry_summary.get('failedTests') != 0
                    or not isinstance(retry_summary.get('passedTests'), int)
                    or retry_summary['passedTests'] < 1):
                retry_status = status
        except (subprocess.SubprocessError, OSError, ValueError, TypeError):
            retry_status = status
    evidence['retryExit'] = retry_status
    receipt.write_text(json.dumps(evidence, indent=2) + '\n')
    return retry_status


if __name__ == '__main__':
    try:
        sys.exit(run(sys.argv[1:]))
    except ValueError as error:
        print(error, file=sys.stderr)
        sys.exit(2)
