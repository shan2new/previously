"""Runner guard regressions. All native commands/processes are mocked; no simulator needed."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).with_name('run-native-qa.py')
spec = importlib.util.spec_from_file_location('native_qa_runner', SOURCE)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def receipt(cases, *, passed=None, failed=0, skipped=0):
    return json.dumps({'didError': False, 'data': {
        'summary': {'status': 'SUCCEEDED', 'counts': {
            'passed': len(cases) if passed is None else passed, 'failed': failed, 'skipped': skipped,
        }},
        'testCases': [{'suite': suite, 'test': name, 'status': status} for suite, name, status in cases],
    }})


class FakeProcess:
    def __init__(self, waits=()):
        self.pid = 123456789
        self.returncode = None
        self.waits = list(waits)

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        value = self.waits.pop(0) if self.waits else 0
        if isinstance(value, BaseException):
            raise value
        if callable(value):
            value()
        self.returncode = value or 0
        return self.returncode


class RunnerGuards(unittest.TestCase):
    def test_native_write_log_requires_stable_operation_and_unique_sequence(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'fixture.log'
            stamp = {'operationID': '11111111-1111-4111-8111-111111111111',
                     'writerID': '22222222-2222-4222-8222-222222222222', 'sequence': 1}
            item = {'method': 'PUT', 'path': '/me/watch-sessions/:id', 'account': 'fixture-a', 'mutation': stamp}
            log.write_text('\n'.join(json.dumps(value) for value in [item, item]))
            self.assertEqual(runner.mutation_log_audit(log), {'passed': True, 'protectedWrites': 2, 'uniqueOperations': 1, 'failures': []})
            repeated_request = dict(item, requestID=1)
            log.write_text('\n'.join(json.dumps(value) for value in [repeated_request, repeated_request]))
            self.assertEqual(runner.mutation_log_audit(log)['protectedWrites'], 1)
            changed = dict(item, mutation=dict(stamp, sequence=2))
            log.write_text('\n'.join(json.dumps(value) for value in [item, changed]))
            self.assertFalse(runner.mutation_log_audit(log)['passed'])
            changed = dict(item, mutation=dict(stamp, operationID='33333333-3333-4333-8333-333333333333'))
            log.write_text('\n'.join(json.dumps(value) for value in [item, changed]))
            self.assertFalse(runner.mutation_log_audit(log)['passed'])
            del item['mutation']
            log.write_text(json.dumps(item))
            self.assertFalse(runner.mutation_log_audit(log)['passed'])

    def test_coverage_log_records_only_valid_summary_fields(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'build.log'
            summary = {'version': 1, 'caseName': 'monkey', 'seed': 7, 'durationSeconds': 12.5,
                       'completedActions': 9, 'unavailableActions': 2, 'assertions': 5, 'states': ['library']}
            log.write_text('private unrelated log\nQA_SUMMARY broken\nQA_SUMMARY ' + json.dumps(dict(summary, secret='do not copy')) + '\n')
            body = json.dumps({'data': {'artifacts': {'buildLogPath': str(log)}}})
            self.assertEqual(runner.coverage_summaries(body), [summary])
            self.assertEqual(runner.coverage_summaries('{}'), [])

    def test_source_fingerprint_detects_an_app_change(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / 'ios/Sources/App.swift'
            fixture = root / 'ios/Tools/qa/fixture-server.mjs'
            app.parent.mkdir(parents=True)
            fixture.parent.mkdir(parents=True)
            app.write_text('initial source')
            fixture.write_text('fixture')
            (root / 'ios/project.yml').write_text('scheme')
            before = runner.source_fingerprint(root)
            app.write_text('changed source')
            self.assertNotEqual(runner.source_fingerprint(root), before)

    def test_directed_qualification_includes_account_privacy_suites(self):
        suites = {selector.split('/')[-1] for selector in runner.DIRECTED_SUITES}
        self.assertEqual(suites, {'QAHarnessTests', 'AccountLocalStoreTests', 'RewatchStoreTests', 'PreviouslyDirectedTests',
                                 'PreviouslyDeletionTests', 'PreviouslyAccountIsolationTests', 'MutationJournalTests', 'PreviouslyDurabilityTests', 'AccountDeletionRequestTests', 'ImportModelTests'})
        expected = runner.selected_test_cases(runner.DIRECTED_SUITES)
        for suite in suites:
            self.assertTrue(any(case[0] == suite for case in expected), suite)
        output = receipt([(suite, method, 'passed') for suite, method in expected])
        self.assertTrue(runner.classify_result(output, 0, expected)['passed'])
        missing_privacy = [(suite, method, 'passed') for suite, method in expected if suite != 'PreviouslyDeletionTests']
        self.assertFalse(runner.classify_result(receipt(missing_privacy), 0, expected)['passed'])

    def test_harness_only_success_cannot_claim_directed_coverage(self):
        expected = {('QAHarnessTests', 'testConfig'), ('PreviouslyDirectedTests', 'testProgress')}
        output = receipt([('QAHarnessTests', 'testConfig', 'passed')])
        result = runner.classify_result(output, 0, expected)
        self.assertFalse(result['passed'])
        self.assertEqual(result['missingTests'], ['PreviouslyDirectedTests/testProgress'])

    def test_all_named_tests_and_counts_are_required(self):
        expected = {('PreviouslyDirectedTests', 'testProgress'), ('PreviouslyDirectedTests', 'testUndo')}
        cases = [('PreviouslyUITests.PreviouslyDirectedTests', 'testProgress()', 'passed'),
                 ('PreviouslyDirectedTests', 'testUndo', 'passed')]
        self.assertTrue(runner.classify_result(receipt(cases), 0, expected)['passed'])
        self.assertFalse(runner.classify_result(receipt(cases, passed=1), 0, expected)['passed'])
        self.assertFalse(runner.classify_result(receipt(cases), 1, expected)['passed'])
        self.assertFalse(runner.classify_result(receipt(cases), 0, set())['passed'])
        self.assertFalse(runner.classify_result('{"didError":false}', 0, expected)['passed'])

    def test_skip_or_failure_cannot_pass_despite_green_summary(self):
        expected = {('PreviouslyMonkeyTests', 'testSeededMonkey')}
        for status in ['skipped', 'failed']:
            result = runner.classify_result(receipt([('PreviouslyMonkeyTests', 'testSeededMonkey', status)], passed=1), 0, expected)
            self.assertFalse(result['passed'])

    def test_new_selected_source_method_becomes_required(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'ios/UITests/PreviouslyDirectedTests.swift'
            source.parent.mkdir(parents=True)
            source.write_text('class PreviouslyDirectedTests {\n func testFirst() {}\n func testNewFault() async throws {}\n}\n')
            expected = runner.selected_test_cases(['PreviouslyUITests/PreviouslyDirectedTests'], root=root)
            self.assertEqual(expected, {('PreviouslyDirectedTests', 'testFirst'), ('PreviouslyDirectedTests', 'testNewFault')})
            result = runner.classify_result(receipt([('PreviouslyDirectedTests', 'testFirst', 'passed')]), 0, expected)
            self.assertFalse(result['passed'])

    def test_cleanup_handles_process_exit_race_and_escalates_own_group(self):
        with patch.object(runner.os, 'killpg', side_effect=ProcessLookupError) as kill:
            process = FakeProcess()
            runner.stop_owned(process)
            kill.assert_called_once_with(process.pid, signal.SIGTERM)
        with patch.object(runner.os, 'killpg') as kill:
            process = FakeProcess([subprocess.TimeoutExpired(['private-argv'], 10), 0])
            runner.stop_owned(process)
            self.assertEqual([call.args for call in kill.call_args_list], [(process.pid, signal.SIGTERM), (process.pid, signal.SIGKILL)])

    def test_native_timeout_returns_failure_without_rendering_secret_argv(self):
        token = 'ephemeral-token-must-not-be-printed'
        process = FakeProcess([subprocess.TimeoutExpired(['npx', token], 1800), 0])
        captured = io.StringIO()
        with patch.object(runner.subprocess, 'Popen', return_value=process), patch.object(runner.os, 'killpg'):
            with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
                code = runner.run_native_command(['npx', token], io.StringIO())
        self.assertEqual(code, 124)
        self.assertNotIn(token, captured.getvalue())

    def test_timeout_evidence_and_ledger_redact_ephemeral_control_token(self):
        token = 'ephemeral-test-control-token-must-not-escape'
        fixture = FakeProcess()
        native = FakeProcess([subprocess.TimeoutExpired(['npx', token], 1800), 0])
        output = json.loads(receipt([('PreviouslyMonkeyTests', 'testSeededMonkey', 'passed')]))
        output['requestToken'] = token
        def fake_popen(command, **options):
            if command[0] == 'node':
                return fixture
            options['stdout'].write(json.dumps(output))
            return native
        captured = io.StringIO()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with patch.object(runner, 'ROOT', root), patch.object(sys, 'argv', ['runner', '--simulator-id', 'synthetic-simulator']):
                with patch.object(runner.secrets, 'token_urlsafe', return_value=token), patch.object(runner.os, 'killpg'):
                    with patch.object(runner.subprocess, 'Popen', side_effect=fake_popen), patch.object(runner, 'source_fingerprint', return_value={'sha256': 'test', 'fileCount': 1}):
                        with patch.object(runner.subprocess, 'run'), patch.object(runner.subprocess, 'check_output', side_effect=['revision', '']):
                            with patch.object(runner.urllib.request, 'urlopen', return_value=io.StringIO('{"fixtureVersion":"1"}')):
                                with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
                                    self.assertEqual(runner.main(), 1)
            ledger_file = next(root.glob('ios/Tools/qa/.runs/*/ledger.json'))
            ledger = json.loads(ledger_file.read_text())
            self.assertEqual(ledger['status'], 'failed')
            self.assertTrue(ledger['fixtureStopped'])
            self.assertEqual(ledger['runs'][0]['exitCode'], 124)
            self.assertNotIn(token, captured.getvalue())
            for evidence in root.rglob('*.json'):
                self.assertNotIn(token, evidence.read_text())

    def test_sigterm_unwinds_and_stops_owned_fixture_and_native_child(self):
        token = 'ephemeral-test-control-token'
        fixture = FakeProcess()
        native = FakeProcess([lambda: runner.terminate_runner(signal.SIGTERM, None), 0])
        processes = iter([fixture, native])
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with patch.object(runner, 'ROOT', root), patch.object(sys, 'argv', ['runner', '--simulator-id', 'synthetic-simulator']):
                with patch.object(runner.secrets, 'token_urlsafe', return_value=token), patch.object(runner.os, 'killpg') as kill:
                    with patch.object(runner.subprocess, 'Popen', side_effect=lambda *args, **kwargs: next(processes)), patch.object(runner, 'source_fingerprint', return_value={'sha256': 'test', 'fileCount': 1}):
                        with patch.object(runner.subprocess, 'run'), patch.object(runner.subprocess, 'check_output', side_effect=['revision', '']):
                            with patch.object(runner.urllib.request, 'urlopen', return_value=io.StringIO('{"fixtureVersion":"1"}')):
                                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as raised:
                                    runner.main()
            self.assertEqual(raised.exception.code, 128 + signal.SIGTERM)
            self.assertEqual(kill.call_count, 2)
            ledger_file = next(root.glob('ios/Tools/qa/.runs/*/ledger.json'))
            ledger = json.loads(ledger_file.read_text())
            self.assertTrue(ledger['fixtureStopped'])
            self.assertEqual(ledger['status'], 'interrupted')
            self.assertNotIn(token, ledger_file.read_text())


if __name__ == '__main__':
    unittest.main()
