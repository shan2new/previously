"""Fault-test the reviewed activation transaction with mock processes and owned plist files.

Reads the immutable candidate/manifest. Never reads credentials or invokes launchctl/Node/PG.
"""
import contextlib
import datetime
import importlib.util
import io
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent

class ActivationGuardTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('activation_fixture', HERE / 'activate-reviewed.py')
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        self.temp = tempfile.TemporaryDirectory(prefix='previously_activation_fixture_')
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.m.BASE = root / 'evidence'
        self.m.LIVE = root / 'LaunchAgents'
        self.m.OPS = root / 'operations'
        for directory in [self.m.BASE / 'artifact', self.m.BASE / 'load-testing', self.m.LIVE,
                          self.m.OPS / 'backups']:
            directory.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HERE / 'artifact/artifact-manifest.json', self.m.BASE / 'artifact/artifact-manifest.json')
        self.capacity = self.m.BASE / 'load-testing/final-results.json'
        self.capacity.write_text(json.dumps({'qualified':True, 'qualification':'passed',
                                             'artifact':{'sourceSHA256':self.m.EXPECTED}}))
        for label in self.m.LABELS:
            shutil.copyfile(self.m.CANDIDATE / 'rollback' / (label + '.plist'), self.m.LIVE / (label + '.plist'))
        self.original = {p.name:p.read_bytes() for p in self.m.LIVE.iterdir()}
        self.states = {label:{'loaded':True,'state':'running' if index == 0 else 'not running',
                              'lastExitCode':0} for index,label in enumerate(self.m.LABELS)}
        self.commands = []
        self.events = []
        self.node_calls = []
        self.inject_private_failure = False
        self.inject_backup_fault = None
        self.inject_rollback_collector_unhealthy = False
        self.inject_first_bootstrap_failure = False
        self.inject_external_change_after_bootstrap_failure = False
        self.inject_delayed_old_pid = False
        self.pid_probes = 0
        self.fingerprint = 'a' * 64
        self.patches = [patch.object(self.m, 'run', self.fake_run),
                        patch.object(self.m, 'state', lambda label:dict(self.states[label])),
                        patch.object(self.m, 'node', self.fake_node),
                        patch.object(self.m, 'ready', self.fake_ready),
                        patch.object(self.m, 'pid_alive', self.fake_pid_alive),
                        patch.object(self.m, 'wait_until', self.fake_wait)]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def fake_run(self, args, **kwargs):
        self.commands.append(args)
        self.assertEqual(args[0], 'launchctl')
        if args[1] == 'bootout':
            label = args[-1].split('/')[-1]
            self.states[label] = {'loaded':False}
        elif args[1] == 'bootstrap':
            label = Path(args[-1]).stem
            phase = 'rollback' if (self.m.LIVE/(self.m.LABELS[0]+'.plist')).read_bytes() == self.original[self.m.LABELS[0]+'.plist'] else 'candidate'
            if label == self.m.LABELS[0] and phase == 'candidate' and self.inject_first_bootstrap_failure:
                self.inject_first_bootstrap_failure=False
                if self.inject_external_change_after_bootstrap_failure:
                    (self.m.LIVE/(label+'.plist')).write_bytes(b'external concurrent plist change')
                return SimpleNamespace(returncode=5,stderr='Bootstrap failed: 5: Input/output error\n')
            if label == self.m.LABELS[0] and phase == 'candidate' and self.inject_delayed_old_pid:
                self.assertGreaterEqual(self.pid_probes,2,'replacement started before prior wrapper exited')
            self.events.append(('bootstrap',phase,label))
            self.states[label] = {'loaded':True,'state':'running' if label == self.m.LABELS[0] else 'not running',
                                  'lastExitCode':0}
            if label == self.m.LABELS[1]:
                content = b'owned fake backup bytes'
                name = 'previously-20261015T162000000Z-' + ('a'*12 if phase == 'candidate' else 'b'*12) + '.dump'
                path = self.m.OPS/'backups'/name
                path.write_bytes(content)
                path.chmod(0o600)
                data = {'createdAt':self.m.now(),'sourceFingerprint':self.fingerprint,'file':name,
                        'bytes':len(content),'sha256':hashlib.sha256(content).hexdigest()}
                if phase == 'candidate':
                    if self.inject_backup_fault == 'checksum':path.write_bytes(b'X'*len(content))
                    elif self.inject_backup_fault == 'size':data['bytes']+=1
                    elif self.inject_backup_fault == 'mode':path.chmod(0o644)
                    elif self.inject_backup_fault == 'symlink':
                        target=path.with_suffix('.owned-fixture');path.rename(target);path.symlink_to(target)
                (self.m.OPS/'backups'/name.replace('.dump','.manifest.json')).write_text(json.dumps(data))
            if label == self.m.LABELS[2]:
                healthy = not (phase == 'rollback' and self.inject_rollback_collector_unhealthy)
                (self.m.OPS / 'status.json').write_text(json.dumps({'healthy':healthy,'measuredAt':self.m.now()}))
        else:
            self.assertEqual(args[1], 'kickstart')
        return SimpleNamespace(returncode=0,stderr='')

    def fake_pid_alive(self, pid):
        self.pid_probes+=1
        self.assertEqual(pid,123456789)
        return self.pid_probes == 1

    def fake_ready(self, url):
        phase = 'rollback' if (self.m.LIVE/(self.m.LABELS[0]+'.plist')).read_bytes() == self.original[self.m.LABELS[0]+'.plist'] else 'candidate'
        self.events.append(('ready',phase,url))
        return self.states[self.m.LABELS[0]].get('loaded') is True

    def fake_wait(self, predicate, timeout, message):
        # Fixture processes complete synchronously; unsuccessful readiness/health must fail.
        for _ in range(3):
            if predicate():return
        raise RuntimeError(message)

    def fake_node(self, code, **kwargs):
        self.node_calls.append(code)
        if len(self.node_calls) == 1:
            self.assertIn('backupDatabase()', code)
            self.assertIn('restoreCheck(path)', code)
            return {'bytes':123,'sha256':'b'*64,'scratchRemoved':True}
        self.assertIn('staleOpenReports', code)
        self.assertNotIn('alertStaleReports(', code)
        if self.inject_private_failure:
            raise RuntimeError('injected private verification failure')
        return {'sourceFingerprint':self.fingerprint,
                'metrics':{'startedAt':datetime.datetime.now(datetime.timezone.utc).timestamp()*1000}}

    def execute(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.m.activate()

    def assert_old_pointers(self):
        self.assertEqual({p.name:p.read_bytes() for p in self.m.LIVE.iterdir()}, self.original)

    def test_failed_capacity_never_stops_jobs_or_takes_backup(self):
        self.capacity.write_text(json.dumps({'qualified':False,'qualification':'failed'}))
        with self.assertRaises(SystemExit):
            self.execute()
        self.assertEqual(self.commands, [])
        self.assertEqual(self.node_calls, [])
        self.assert_old_pointers()

    def test_external_live_plist_conflict_is_preserved_without_mutation(self):
        changed = self.m.LIVE / (self.m.LABELS[1] + '.plist')
        changed.write_text('external concurrent change')
        self.original[changed.name] = changed.read_bytes()
        with self.assertRaises(SystemExit):
            self.execute()
        self.assertEqual(self.commands, [])
        self.assertEqual(self.node_calls, [])
        self.assert_old_pointers()

    def test_tampered_manifest_cannot_relabel_another_artifact_as_reviewed(self):
        path = self.m.BASE / 'artifact/artifact-manifest.json'
        data = json.loads(path.read_text())
        data['files']['dist/index.js'] = '0' * 64
        path.write_text(json.dumps(data))
        with self.assertRaises(SystemExit):
            self.execute()
        self.assertEqual(self.commands, [])
        self.assertEqual(self.node_calls, [])
        self.assert_old_pointers()

    def test_post_activation_fault_restores_all_three_old_pointers(self):
        self.inject_private_failure = True
        with self.assertRaises(SystemExit):
            self.execute()
        self.assertEqual(len(self.node_calls), 2)
        self.assert_old_pointers()
        receipt = json.loads((self.m.BASE / 'activation-receipt.json').read_text())
        self.assertTrue(receipt['rollbackPerformed'])
        self.assertTrue(receipt['rollbackReady'])
        self.assertFalse(receipt['activated'])
        self.assertTrue(all(self.states[label]['loaded'] for label in self.m.LABELS))
        backend_boot=self.events.index(('bootstrap','rollback',self.m.LABELS[0]))
        local_ready=self.events.index(('ready','rollback','http://127.0.0.1:8787/ready'))
        public_ready=self.events.index(('ready','rollback','https://anime.cognipin.com/ready'))
        backup_boot=self.events.index(('bootstrap','rollback',self.m.LABELS[1]))
        collector_boot=self.events.index(('bootstrap','rollback',self.m.LABELS[2]))
        self.assertLess(backend_boot,local_ready)
        self.assertLess(local_ready,public_ready)
        self.assertLess(public_ready,backup_boot)
        self.assertLess(backup_boot,collector_boot)
        self.assertTrue(receipt['rollbackOperationalSnapshot']['healthy'])
        self.assertGreater(self.m.instant(receipt['rollbackOperationalSnapshot']['measuredAt']),
                           self.m.instant(receipt['rollbackCollectorStartedAt']))
        self.assertEqual(receipt['rollbackBackupVerification']['mode'],'0600')

    def test_same_size_corruption_fails_activation_and_rollback_takes_verified_backup(self):
        self.inject_backup_fault='checksum'
        with self.assertRaises(SystemExit):self.execute()
        self.assert_old_pointers()
        receipt=json.loads((self.m.BASE/'activation-receipt.json').read_text())
        self.assertTrue(receipt['rollbackPerformed'])
        self.assertNotEqual(receipt['rollbackBackup']['file'],
                            'previously-20261015T162000000Z-'+'a'*12+'.dump')
        self.assertEqual(receipt['rollbackBackup']['sha256'],receipt['rollbackBackupVerification']['sha256'])

    def test_wrong_backup_size_fails_activation(self):
        self.inject_backup_fault='size'
        with self.assertRaises(SystemExit):self.execute()
        self.assert_old_pointers()
        self.assertTrue(self.m.receipt['rollbackPerformed'])

    def test_publicly_readable_backup_fails_activation(self):
        self.inject_backup_fault='mode'
        with self.assertRaises(SystemExit):self.execute()
        self.assert_old_pointers()
        self.assertTrue(self.m.receipt['rollbackPerformed'])

    def test_symlink_backup_fails_activation(self):
        self.inject_backup_fault='symlink'
        with self.assertRaises(SystemExit):self.execute()
        self.assert_old_pointers()
        self.assertTrue(self.m.receipt['rollbackPerformed'])

    def test_unhealthy_rollback_collector_never_claims_verified_recovery(self):
        self.inject_private_failure=True
        self.inject_rollback_collector_unhealthy=True
        with self.assertRaises(SystemExit):self.execute()
        self.assert_old_pointers()
        self.assertTrue(self.m.receipt['rollbackPointersRestored'])
        self.assertFalse(self.m.receipt['rollbackPerformed'])
        self.assertNotIn('rollbackReady',self.m.receipt)
        self.assertEqual(self.m.receipt['rollbackFailureClass'],'RuntimeError')

    def test_replacement_waits_for_captured_old_wrapper_after_registration_disappears(self):
        self.inject_delayed_old_pid=True
        self.states[self.m.LABELS[0]]['pid']=123456789
        self.execute()
        self.assertGreaterEqual(self.pid_probes,2)
        self.assertTrue(self.m.receipt['activated'])

    def test_transient_bootstrap_failure_retries_and_preserves_safe_diagnostic(self):
        self.inject_first_bootstrap_failure=True
        self.execute()
        self.assertTrue(self.m.receipt['activated'])
        attempts=self.m.receipt['bootstrapAttempts']
        self.assertEqual(len(attempts),1)
        self.assertEqual(attempts[0]['returnCode'],5)
        self.assertEqual(attempts[0]['label'],self.m.LABELS[0])
        self.assertIn('Input/output error',attempts[0]['stderr'])

    def test_bootstrap_retry_stops_on_external_plist_conflict(self):
        label=self.m.LABELS[0];path=self.m.LIVE/(label+'.plist')
        path.write_bytes((self.m.CANDIDATE/(label+'.plist')).read_bytes())
        expected=self.m.digest(path)
        self.states[label]={'loaded':False}
        self.inject_first_bootstrap_failure=True
        self.inject_external_change_after_bootstrap_failure=True
        with self.assertRaisesRegex(RuntimeError,'external plist conflict'):
            self.m.bootstrap(label,expected)
        self.assertEqual(path.read_bytes(),b'external concurrent plist change')
        self.assertEqual(len(self.commands),1)

    def test_bootstrap_does_not_retry_permanent_errors(self):
        label=self.m.LABELS[0];self.states[label]={'loaded':False}
        with patch.object(self.m,'run',return_value=SimpleNamespace(returncode=78,stderr='invalid configuration')) as command:
            with self.assertRaisesRegex(RuntimeError,'permanent'):
                self.m.bootstrap(label,self.m.digest(self.m.LIVE/(label+'.plist')))
            self.assertEqual(command.call_count,1)

    def test_bootstrap_never_double_loads_registered_job(self):
        label=self.m.LABELS[0]
        with self.assertRaisesRegex(RuntimeError,'unexpectedly registered'):
            self.m.bootstrap(label,self.m.digest(self.m.LIVE/(label+'.plist')))
        self.assertEqual(self.commands,[])

    def test_success_selects_exact_reviewed_pointers_and_writes_receipt(self):
        self.execute()
        self.assertEqual(len(self.node_calls), 2)
        for label in self.m.LABELS:
            self.assertEqual((self.m.LIVE/(label+'.plist')).read_bytes(),
                             (self.m.CANDIDATE/(label+'.plist')).read_bytes())
        receipt = json.loads((self.m.BASE / 'activation-receipt.json').read_text())
        self.assertTrue(receipt['activated'])
        self.assertFalse(receipt['rollbackPerformed'])
        self.assertFalse(receipt['productionRestorePerformed'])
        self.assertFalse(receipt['applicationDataManuallyWritten'])
        self.assertEqual(receipt['newBackupVerification']['sha256'],receipt['newBackup']['sha256'])
        self.assertEqual(receipt['newBackupVerification']['bytes'],receipt['newBackup']['bytes'])
        self.assertEqual(receipt['newBackupVerification']['mode'],'0600')

class InvocationContextTests(unittest.TestCase):
    def setUp(self):
        spec=importlib.util.spec_from_file_location('context_fixture',HERE/'activate-reviewed.py')
        self.m=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.m)

    def test_launchctl_preserves_inherited_operator_context(self):
        result=SimpleNamespace(returncode=0,stdout='',stderr='')
        with patch.object(self.m.subprocess,'run',return_value=result) as launch:
            self.m.run(['launchctl','print','gui/501/com.shan.previously'])
            self.assertIsNone(launch.call_args.kwargs['env'])

    def test_node_helpers_keep_scoped_production_environment(self):
        result=SimpleNamespace(returncode=0,stdout='',stderr='')
        with patch.object(self.m.subprocess,'run',return_value=result) as command:
            self.m.run([self.m.NODE,'--input-type=module','-e','/* parse-only fixture */'])
            self.assertIs(command.call_args.kwargs['env'],self.m.ENV)
            self.assertIn('PREVIOUSLY_ENV_FILE',command.call_args.kwargs['env'])

if __name__ == '__main__':
    unittest.main(verbosity=2)
