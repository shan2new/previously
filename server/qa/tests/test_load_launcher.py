"""Pure lifecycle checks; subprocesses, signals and PostgreSQL are all fake."""
import contextlib
import io
import json
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'run-load-test.py'


class LoadLauncherTests(unittest.TestCase):
    def run_launcher(self, evidence):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'run'
            state = {'exists': False, 'drops': 0, 'stops': [], 'signals': {}, 'drain_reads': 0}

            def run(command, **kwargs):
                if command[0] == 'createdb':
                    state['exists'] = True
                elif command[0] == 'dropdb':
                    state['exists'] = False
                    state['drops'] += 1
                elif command[0] == 'psql':
                    query = kwargs['input']
                    if 'server_version' in query:
                        value = '17.0'
                    elif 'pg_stat_activity' in query:
                        state['drain_reads'] += 1
                        value = '1' if state['drain_reads'] == 1 else '0'
                    else:
                        value = str(int(state['exists']))
                    return subprocess.CompletedProcess(command, 0, value + '\n', '')
                return subprocess.CompletedProcess(command, 0, '', '')

            def check_output(command, **_kwargs):
                if '--version' in command:
                    return 'v24.21.0\n'
                return '16384\n4\n' if command[0] == 'sysctl' else ('mock-head\n' if 'rev-parse' in command else '')

            class Child:
                def __init__(self, command, **kwargs):
                    self.server = command[-1].endswith('load-server.ts')
                    self.pid = 900001 if self.server else 900002
                    self.returncode = None if self.server else 0
                    if self.server:
                        env = kwargs['env']
                        db = env['DATABASE_URL'].rsplit('/', 1)[1]
                        (output / 'ready.json').write_text(json.dumps({'dbName': db, 'baseURL': 'http://127.0.0.1:18000'}))
                        if evidence == 'malformed':
                            (output / 'server-resources.json').write_text('{invalid')

                def poll(self):
                    if not self.server and evidence == 'sigterm':
                        evidence_handler = state['signals'][signal.SIGTERM]
                        evidence_handler(signal.SIGTERM, None)
                    return self.returncode

                def wait(self, **_kwargs):
                    self.returncode = 0
                    return 0

            def set_signal(kind, handler):
                prior = state['signals'].get(kind, signal.SIG_DFL)
                state['signals'][kind] = handler
                return prior

            with patch.object(sys, 'argv', [str(SCRIPT), '--output', str(output)]), \
                 patch('subprocess.run', side_effect=run), patch('subprocess.check_output', side_effect=check_output), \
                 patch('subprocess.Popen', Child), patch('os.killpg', side_effect=lambda pid, sig: state['stops'].append((pid, sig))), \
                 patch('signal.signal', side_effect=set_signal), patch('time.sleep'), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as result:
                    runpy.run_path(str(SCRIPT), run_name='__main__')
            self.assertNotEqual(result.exception.code, 0)
            ledger = json.loads((output / 'run-ledger.json').read_text())
            self.assertTrue(ledger['databaseRemoved'])
            self.assertEqual(state['drops'], 1)
            self.assertFalse(state['exists'])
            self.assertGreaterEqual(state['drain_reads'], 2)
            self.assertEqual({pid for pid, _sig in state['stops']}, {900001, 900002})
            self.assertEqual(ledger['nodeOptions'], '--max-old-space-size=256 --max-semi-space-size=8')
            self.assertTrue(ledger['ownedOpsRemoved'])
            return ledger, json.loads((output / 'source-files.json').read_text())

    def test_corrupt_resource_evidence_still_cleans_owned_database(self):
        ledger, _ = self.run_launcher('malformed')
        self.assertIn('JSONDecodeError', ledger['resourceEvidenceError'])
        self.assertFalse(ledger['memoryReviewPassed'])

    def test_full_run_requires_resources_and_ignores_unrelated_qa_sources(self):
        ledger, sources = self.run_launcher('missing')
        self.assertIn('requires server resource evidence', ledger['resourceEvidenceError'])
        self.assertIn('server/package-lock.json', sources)
        qa_files = {name for name in sources if name.startswith('server/qa/')}
        self.assertEqual(qa_files, {'server/qa/load-server.ts', 'server/qa/load-traffic.ts',
                                    'server/qa/load-provider-stubs.ts', 'server/qa/run-load-test.py'})

    def test_sigterm_unwinds_owned_process_and_database_cleanup(self):
        ledger, _ = self.run_launcher('sigterm')
        self.assertIn('SystemExit: 143', ledger['runError'])


if __name__ == '__main__':
    unittest.main()
