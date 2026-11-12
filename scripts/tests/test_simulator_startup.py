"""Preserve assertion failures while recovering only the observed AX bootstrap failure."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('ui_runner', ROOT / 'scripts/run-simulator-ui.py')
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
IDENTIFIER = 'SleepypodUITests-Runner (30641) encountered an error'
SUMMARY = {'result': 'Failed', 'passedTests': 0, 'skippedTests': 0, 'expectedFailures': 0,
           'failedTests': 1, 'totalTestCount': 1,
           'testFailures': [{'failureText': RUNNER.AX_FAILURE, 'testIdentifierString': IDENTIFIER}]}
TREE = {'testNodes': [{'name': 'System Failures', 'nodeType': 'Test Suite', 'children': [
    {'nodeType': 'Test Case', 'result': 'Failed', 'nodeIdentifier': IDENTIFIER}]}]}


class StartupClassificationTests(unittest.TestCase):
    def test_exact_observed_failure_is_eligible(self):
        self.assertTrue(RUNNER.bootstrap_only(SUMMARY, TREE))

    def test_any_executed_or_skipped_test_prevents_recovery(self):
        for key in ['passedTests', 'skippedTests', 'expectedFailures']:
            summary = copy.deepcopy(SUMMARY)
            summary[key] = 1
            self.assertFalse(RUNNER.bootstrap_only(summary, TREE), key)

    def test_assertion_mentioning_ax_failure_is_never_retried(self):
        summary = copy.deepcopy(SUMMARY)
        summary['testFailures'][0]['testIdentifierString'] = 'ReportWebSharingUITests/testConsent()'
        self.assertFalse(RUNNER.bootstrap_only(summary, TREE))

    def test_hidden_test_in_tree_prevents_recovery(self):
        tree = copy.deepcopy(TREE)
        tree['testNodes'].append({'nodeType': 'Test Case', 'nodeIdentifier': 'ActualTest', 'result': 'Passed'})
        self.assertFalse(RUNNER.bootstrap_only(SUMMARY, tree))

    def test_runner_name_outside_system_failures_is_rejected(self):
        tree = copy.deepcopy(TREE)
        tree['testNodes'][0]['name'] = 'Report tests'
        self.assertFalse(RUNNER.bootstrap_only(SUMMARY, tree))

    def test_other_initialization_errors_are_not_retried(self):
        summary = copy.deepcopy(SUMMARY)
        summary['testFailures'][0]['failureText'] = 'The application crashed'
        self.assertFalse(RUNNER.bootstrap_only(summary, TREE))

    def test_malformed_or_missing_results_fail_closed(self):
        for summary, tree in [(None, TREE), (SUMMARY, {}), ({}, TREE), (SUMMARY, {'testNodes': [None]})]:
            self.assertFalse(RUNNER.bootstrap_only(summary, tree))


class StartupExecutionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.bundle = Path(self.temporary.name) / 'Reports.xcresult'
        self.arguments = ['test-without-building', '-xctestrun', '/unchanged/Reports.xctestrun',
                          '-destination', 'platform=iOS Simulator,id=CAAA601F-5038-46D8-BBF8-CA5E3BE47EC1',
                          '-only-testing:SleepypodUITests/ReportWebSharingUITests',
                          '-resultBundlePath', str(self.bundle), '-parallel-testing-enabled', 'NO']

    def process(self, exit_code):
        return subprocess.CompletedProcess([], exit_code)

    def test_success_runs_once_without_inspecting_or_restarting(self):
        with patch.object(RUNNER.subprocess, 'run', return_value=self.process(0)) as process:
            self.assertEqual(RUNNER.run(self.arguments), 0)
        process.assert_called_once_with(['xcodebuild', *self.arguments])

    def test_real_assertion_failure_is_preserved_without_restart(self):
        summary = copy.deepcopy(SUMMARY)
        summary['testFailures'][0]['failureText'] = 'XCTAssertEqual failed'
        with patch.object(RUNNER.subprocess, 'run', return_value=self.process(65)) as process, \
                patch.object(RUNNER, 'result_json', side_effect=[summary, TREE]):
            self.assertEqual(RUNNER.run(self.arguments), 65)
        self.assertEqual(process.call_count, 1)

    def test_one_recovery_preserves_bundle_and_every_selector(self):
        success = {'result': 'Passed', 'passedTests': 4, 'failedTests': 0}
        with patch.object(RUNNER.subprocess, 'run', side_effect=[self.process(65), self.process(0), self.process(0), self.process(0)]) as process, \
                patch.object(RUNNER, 'result_json', side_effect=[SUMMARY, TREE, success]):
            self.assertEqual(RUNNER.run(self.arguments), 0)
        calls = [entry.args[0] for entry in process.call_args_list]
        self.assertEqual(calls[1][:3], ['xcrun', 'simctl', 'shutdown'])
        self.assertEqual(calls[2][:3], ['xcrun', 'simctl', 'bootstatus'])
        expected = ['xcodebuild', *self.arguments]
        expected[expected.index('-resultBundlePath') + 1] = str(self.bundle.with_name('Reports-bootstrap-retry.xcresult'))
        self.assertEqual(calls[3], expected)
        receipt = json.loads(self.bundle.with_name('Reports-bootstrap-recovery.json').read_text())
        self.assertEqual(receipt['originalExit'], 65)
        self.assertEqual(receipt['retryExit'], 0)

    def test_second_failure_is_final_even_if_it_is_bootstrap_failure(self):
        with patch.object(RUNNER.subprocess, 'run', side_effect=[self.process(65), self.process(0), self.process(0), self.process(65)]) as process, \
                patch.object(RUNNER, 'result_json', side_effect=[SUMMARY, TREE]):
            self.assertEqual(RUNNER.run(self.arguments), 65)
        self.assertEqual(process.call_count, 4)

    def test_empty_successful_retry_cannot_pass(self):
        with patch.object(RUNNER.subprocess, 'run', side_effect=[self.process(65), self.process(0), self.process(0), self.process(0)]), \
                patch.object(RUNNER, 'result_json', side_effect=[SUMMARY, TREE, {'result': 'Passed', 'passedTests': 0, 'failedTests': 0}]):
            self.assertEqual(RUNNER.run(self.arguments), 65)

    def test_failed_reboot_does_not_run_another_test(self):
        with patch.object(RUNNER.subprocess, 'run', side_effect=[self.process(65), subprocess.TimeoutExpired('simctl', 120)]) as process, \
                patch.object(RUNNER, 'result_json', side_effect=[SUMMARY, TREE]):
            self.assertEqual(RUNNER.run(self.arguments), 65)
        self.assertEqual(process.call_count, 2)

    def test_existing_evidence_is_not_overwritten(self):
        self.bundle.mkdir()
        with patch.object(RUNNER.subprocess, 'run') as process, self.assertRaises(ValueError):
            RUNNER.run(self.arguments)
        process.assert_not_called()


if __name__ == '__main__':
    unittest.main()
