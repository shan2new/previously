"""Prepare a distinct six-page closeout; render only after the coordinator releases capacity.

No import-time file writes, service calls, native builds or receipt mutation. Missing
evidence stays pending. Existing evidence and the historical 32-page PDF are inputs only.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
OUTPUT = ROOT / 'output/pdf/previously-release-closeout-2026-10-15.pdf'
SEEDS = {20261006, 60102620, 38654705664}
FILES_COVERAGE = {'files-partial-import', 'files-all-skipped-import', 'files-export-saved-copy'}
FILES_UI_TESTS = {
    'PreviouslyFilesTests/testAllSkippedMALFileRendersReasonWithoutApplyAction',
    'PreviouslyFilesTests/testJSONAndCSVSaveToFilesContainAccountCopyAndSurviveSignOut',
    'PreviouslyFilesTests/testPartialMALFilePreviewAndApplyThroughSystemPicker',
}


class Evidence:
    def __init__(self, manifest):
        self.manifest = manifest
        self.hashes = {}
        self.missing = []

    def read(self, alias):
        value = self.manifest['receipts'].get(alias)
        if not value:
            self.missing.append(alias)
            return {}
        return self.read_path(value, alias)

    def read_path(self, value, alias):
        path = (ROOT / value).resolve()
        if not path.is_relative_to(ROOT):
            raise ValueError(f'Receipt path must stay inside the project: {alias}')
        if not path.is_file():
            self.missing.append(alias)
            return {}
        raw = path.read_bytes()
        self.hashes[str(path.relative_to(ROOT))] = hashlib.sha256(raw).hexdigest()
        result = json.loads(raw)
        if not isinstance(result, dict):
            raise ValueError(f'Receipt must be an object: {alias}')
        return result


def case_key(case):
    suite = str(case.get('suite', '')).split('/')[-1].split('.')[-1]
    return suite+'/'+str(case.get('test', '')).removesuffix('()')


def native_directed_pass(data, count, *, phase_only=False):
    top_sha = data.get('sourceFingerprint', {}).get('sha256')
    runs = [r for r in data.get('runs', []) if r.get('name') == 'directed']
    if len(runs) != 1 or not top_sha:
        return False
    run = runs[0]
    expected = set(run.get('expectedTests', []))
    cases = run.get('testCases', [])
    passed = {case_key(t) for t in cases if t.get('status') == 'passed'}
    # Phase observation may survive a later seed failure. The default remains a
    # completed/passed whole-run requirement for sealed qualification consumers.
    return (data.get('status') in ({'running','passed','failed'} if phase_only else {'passed'})
            and run.get('status') == 'passed'
            and run.get('exitCode') == 0 and len(expected) == count
            and len(cases) == count and expected == passed
            and run.get('counts', {}).get('passed') == count
            and all(run.get('counts', {}).get(k) == 0 for k in ('failed', 'skipped'))
            and run.get('sourceFingerprint', {}).get('sha256') == top_sha)


def native_seed_pass(data, directed):
    sha = directed.get('sourceFingerprint', {}).get('sha256')
    runs = [r for r in data.get('runs', []) if r.get('seed') in SEEDS
            and str(r.get('name', '')).startswith('monkey')]
    return (sha is not None and data.get('status') == 'passed'
            and data.get('sourceFingerprint', {}).get('sha256') == sha
            and {r.get('seed') for r in runs} == SEEDS and len(runs) == 3
            and all(r.get('status') == 'passed' and r.get('exitCode') == 0
                    and r.get('randomDurationSeconds') == 300
                    and r.get('counts', {}).get('failed') == 0
                    and r.get('counts', {}).get('skipped') == 0
                    and r.get('sourceFingerprint', {}).get('sha256') == sha
                    and any(c.get('completedActions', 0) > 0 and c.get('assertions', 0) > 0
                            for c in r.get('coverage', [])) for r in runs))


def sealed_native_common(receipt, ledger, e):
    """Consume the actual summarizer contract, never a focused or stitched run."""
    relative = receipt.get('originalLedgerPath')
    invocation = receipt.get('invocation', {})
    required = {'requestedSuite':'all', 'onlySuites':[], 'durationSeconds':300,
                'scheme':'PreviouslyQA', 'configuration':'QA',
                'bundleID':'com.cognipin.previously.qa'}
    return (receipt.get('qualified') is True and receipt.get('status') == 'passed'
        and str(receipt.get('build')) == '17'
        and all(receipt.get(k) is True for k in ('fixtureStopped','sourceStillMatches','singleAllRun'))
        and ledger.get('fixtureStopped') is True and bool(ledger.get('finishedAt'))
        and receipt.get('sourceFingerprint') == ledger.get('sourceFingerprint')
        and isinstance(relative, str) and receipt.get('originalLedgerSHA256') == e.hashes.get(relative)
        and receipt.get('configuration') == 'QA' and receipt.get('scheme') == 'PreviouslyQA'
        and receipt.get('bundleID') == 'com.cognipin.previously.qa'
        and invocation == ledger.get('invocation')
        and all(invocation.get(k) == v for k,v in required.items())
        and str(invocation.get('sourceBuildNumber')) == '17'
        and set(invocation.get('seeds', [])) == SEEDS and len(invocation.get('seeds', [])) == 3
        and type(invocation.get('maxActions')) is int and 5 <= invocation['maxActions'] <= 1000)


def files_coverage_pass(rows):
    return (len(rows) == 3 and {r.get('caseName') for r in rows} == FILES_COVERAGE
        and all(r.get('completedActions',0) > 0 and r.get('assertions',0) > 0 for r in rows))


def evaluate(e):
    names = ('backendPrepared', 'backendLoad', 'backendFailedLoad', 'backendActivation',
             'activationFirstFailure', 'oldServiceRecovery', 'activationOutageReview',
             'activationGuardVerification', 'nativeSummary',
             'widget', 'admission', 'archive17', 'archiveSourceManifest', 'upload17',
             'releaseSimulator17', 'realErasure', 'filesRuntime', 'filesFocused',
             'failedNativeFull', 'failedNativeFullSecond', 'heroFocused', 'heroStaticReview',
             'nativeInProgress', 'historicalSourceSnapshot', 'providerPreflight', 'qaExactReadback',
             'productionSnapshot', 'productionTelemetry', 'archiveOrganizerCopy',
             'archiveInvocation', 'archiveToolReceipt', 'releaseSimulatorCompile',
             'releaseSimulatorCompileInvocation', 'releaseSimulatorCompileTool', 'finalNativeFailure',
             'archiveIndependentReview', 'qaStopAfterTimeout')
    d = {name: e.read(name) for name in names}
    # The actual sealed summary names one exact primary all-run ledger. Missing or
    # unknown schema remains pending; earlier focused passes are never stitched in.
    summary = d['nativeSummary']
    directed_path = summary.get('originalLedgerPath')
    monkey_path = directed_path
    d['nativeDirected'] = e.read_path(directed_path, 'nativeDirected') if isinstance(directed_path, str) else {}
    d['nativeMonkey'] = e.read_path(monkey_path, 'nativeMonkey') if isinstance(monkey_path, str) else {}
    expected_sha = e.manifest['expectedBackendSourceSha256']
    prepared = d['backendPrepared']
    load = d['backendLoad']
    activation = d['backendActivation']
    expected_phases = [('warmup',15,120,1800), ('sustained',75,900,67500),
                       ('burst',150,60,9000), ('recovery',15,300,4500)]
    actual_phases = [(p.get('name'),p.get('rps'),p.get('durationSeconds'),p.get('offered'))
                     for p in load.get('phases', [])]
    imports = load.get('importResults', [])
    d['backendPreparedPassed'] = (prepared.get('sourceSHA256') == expected_sha
        and prepared.get('serverUnitsPassed') == 1340
        and prepared.get('protocolChecksPassed') == 39
        and prepared.get('recoveryChecksPassed') == 6
        and prepared.get('contentPolicyChecksPassed') == 27
        and prepared.get('operationsChecksPassed') == 26
        and prepared.get('productionAuditAdvisories') == 0)
    d['capacityPassed'] = (load.get('qualified') is True and load.get('qualification') == 'passed'
        and load.get('artifact', {}).get('sourceSHA256') == expected_sha
        and load.get('artifact', {}).get('matchesLoadFingerprint') is True
        and load.get('coreRequests') == 82800 and load.get('coreOfferedRequests') == 82800
        and load.get('coldSearches') == 200 and load.get('concurrentImports') == 2
        and len(imports) == 2 and len({r.get('userIndex') for r in imports}) == 2
        and all(r.get('ok') is True and r.get('progress', {}).get('state') == 'done'
                and r.get('progress', {}).get('shows') == 50
                and r.get('progress', {}).get('failed') == 0
                and r.get('progress', {}).get('remaining') == 0 for r in imports)
        and actual_phases == expected_phases
        and all(p.get('completed') == p.get('offered') for p in load.get('phases', []))
        and load.get('writeOracleChecked') == 798
        and all(load.get(k) == 0 for k in ('errorCount', 'serverErrorCount', 'timeoutCount', 'droppedCount',
                                         'incorrectResponseCount', 'writeOracleMismatch'))
        and load.get('memory', {}).get('passed') is True
        and load.get('cleanup', {}).get('databaseRemoved') is True
        and load.get('cleanup', {}).get('ownedOpsRemoved') is True
        and load.get('cleanup', {}).get('scratchConnectionsBeforeDrop') == 0
        and load.get('sourceFrozen') is True and load.get('distFrozen') is True)
    first_failure = d['activationFirstFailure']
    outage = d['activationOutageReview']
    old_recovery = d['oldServiceRecovery']
    recovered = old_recovery.get('result', {})
    d['initialActivationFailed'] = (first_failure.get('activated') is False
        and first_failure.get('rollbackPointersRestored') is True
        and first_failure.get('rollbackPerformed') is False
        and bool(first_failure.get('rollbackFailureClass'))
        and outage.get('automaticRollbackSucceeded') is False)
    d['manualOldServiceRecovered'] = (d['initialActivationFailed']
        and outage.get('oldServicesManuallyBootstrapped') is True
        and all(recovered.get(k, {}).get('status') == 200
                and recovered.get(k, {}).get('body', {}).get('ok') is True for k in ('local','public'))
        and all(recovered.get(k, {}).get('loaded') is True for k in (
            'com.shan.previously','com.shan.previously.backup','com.shan.previously.ops'))
        and old_recovery.get('productionRestorePerformed') is False)
    new_backup = activation.get('newBackupVerification', {})
    d['activationPassed'] = (d['capacityPassed'] and activation.get('activated') is True
        and activation.get('sourceSHA256') == expected_sha
        and activation.get('localReady') is True and activation.get('publicReady') is True
        and activation.get('rollbackPerformed') is False
        and activation.get('newOperationalSnapshot', {}).get('healthy') is True
        and bool(activation.get('newBackup', {}).get('sourceFingerprint'))
        and activation.get('newBackup', {}).get('sourceFingerprint') == activation.get('postActivationProof', {}).get('sourceFingerprint')
        and new_backup.get('mode') == '0600' and new_backup.get('ownerVerified') is True
        and isinstance(new_backup.get('bytes'), int) and new_backup['bytes'] > 0
        and isinstance(new_backup.get('sha256'), str) and len(new_backup['sha256']) == 64)
    guards = d['activationGuardVerification']
    d['activationGuardChecksPassed'] = (guards.get('fixtureChecks') == 17
        and guards.get('nodeSnippetsSyntaxChecked') == 2
        and guards.get('realLaunchctlInvokedByFixtures') is False
        and guards.get('realDatabaseTouchedByFixtures') is False)
    production = d['productionSnapshot']
    probes = {(p.get('origin'),p.get('path')):p for p in production.get('probes', [])}
    jobs = production.get('jobs', [])
    backup_metadata = production.get('latestBackupMetadata', {})
    d['productionReadbackPassed'] = (d['activationPassed']
        and all(probes.get((origin,path),{}).get('status') == 200
                and probes[(origin,path)].get('ok') is True
                for origin in ('local','public') for path in ('/health','/ready'))
        and all(probes.get((origin,'/health/ready'),{}).get('status') == 404
                for origin in ('local','public'))
        and production.get('documentedReadinessPath') == '/ready'
        and production.get('healthReadyAliasImplemented') is False
        and len(jobs) == 3 and {j.get('label') for j in jobs} == {
            'com.shan.previously','com.shan.previously.backup','com.shan.previously.ops'}
        and all(j.get('loaded') is True and j.get('matchesActivationReceipt') is True
                and j.get('entryPathMatchesArtifact') is True
                and j.get('artifactPath') == activation.get('artifact') for j in jobs)
        and production.get('collector', {}).get('healthy') is True
        and backup_metadata.get('fileSizeMatches') is True
        and backup_metadata.get('fileMode') == '0o600'
        and backup_metadata.get('matchesActivatedSourceFingerprint') is True
        and backup_metadata.get('sha256FromManifest') == new_backup.get('sha256')
        and backup_metadata.get('checksumRecomputedInThisSnapshot') is False)
    telemetry = d['productionTelemetry']
    d['productionTelemetryObserved'] = (telemetry.get('metricsStatus') == 200
        and telemetry.get('usageStatus') == 200
        and isinstance(telemetry.get('metrics', {}).get('requests'),int)
        and isinstance(telemetry.get('metrics', {}).get('errors'),int)
        and all(isinstance(telemetry.get('usage', {}).get('counts', {}).get(k),int)
                for k in ('registered','active_24h','active_7d','library_users','progress_users')))
    sealed_native_summary = sealed_native_common(summary, d['nativeDirected'], e)
    directed_summary = summary.get('directed', {})
    selected = {case_key(t) for r in d['nativeDirected'].get('runs', [])
                if r.get('name') == 'directed' for t in r.get('testCases', [])}
    d['directedPassed'] = (sealed_native_summary and native_directed_pass(d['nativeDirected'], 75)
        and all(directed_summary.get(k) == v for k,v in {
            'total':75,'passed':75,'failed':0,'skipped':0,
            'swiftTestingStorage':10,'exportPreparation':4}.items())
        and len(directed_summary.get('namedTests', [])) == 75
        and set(directed_summary.get('namedTests', [])) == selected)
    monkey_summary = summary.get('monkey', {})
    d['seedsPassed'] = (d['directedPassed'] and native_seed_pass(d['nativeMonkey'], d['nativeDirected'])
        and set(monkey_summary.get('seeds', [])) == SEEDS
        and monkey_summary.get('passedSeeds') == 3
        and monkey_summary.get('requestedRandomDurationSecondsPerSeed') == 300
        and len(monkey_summary.get('runs', [])) == 3
        and {r.get('seed') for r in monkey_summary.get('runs', [])} == SEEDS)
    current_native = d['nativeInProgress']
    d['currentDirectedPhasePassed'] = (native_directed_pass(current_native,75,phase_only=True)
        and current_native.get('invocation', {}).get('requestedSuite') == 'all'
        and current_native.get('invocation', {}).get('onlySuites') == []
        and str(current_native.get('invocation', {}).get('sourceBuildNumber')) == '17')
    d['currentPassedSeeds'] = len([r for r in current_native.get('runs', [])
        if r.get('seed') in SEEDS and str(r.get('name','')).startswith('monkey-')
        and r.get('status') == 'passed' and r.get('exitCode') == 0
        and r.get('sourceFingerprint') == current_native.get('sourceFingerprint')
        and r.get('counts') == {'passed':1,'failed':0,'skipped':0}
        and any(c.get('completedActions',0) > 0 and c.get('assertions',0) > 0
                for c in r.get('coverage', []))])
    final_seed = [r for r in current_native.get('runs', []) if r.get('name') == 'monkey-38654705664']
    d['currentFullNativeFailed'] = (current_native.get('status') == 'failed'
        and current_native.get('fixtureStopped') is True and bool(current_native.get('finishedAt'))
        and d['currentDirectedPhasePassed'] and d['currentPassedSeeds'] == 2
        and len(final_seed) == 1 and final_seed[0].get('status') == 'failed'
        and final_seed[0].get('exitCode') == 124 and final_seed[0].get('counts') == {}
        and final_seed[0].get('reason') == 'The native test command exceeded its 1800-second budget.'
        and bool(final_seed[0].get('primaryResultError')))
    failure_audit = d['finalNativeFailure']
    primary_hashes = {row.get('path'):row.get('sha256') for row in failure_audit.get('primaryEvidence', [])}
    d['finalFailureAuditMatched'] = (d['currentFullNativeFailed'] and failure_audit.get('status') == 'failed'
        and failure_audit.get('qualified') is False and failure_audit.get('fullQualificationPassed') is False
        and failure_audit.get('classification') == 'external_command_timeout_with_incomplete_third_seed_result'
        and failure_audit.get('directedPassed') == 75 and failure_audit.get('monkeyCompletedPassed') == 2
        and failure_audit.get('monkeyRequested') == 3
        and failure_audit.get('sourceFingerprint') == current_native.get('sourceFingerprint')
        and failure_audit.get('readOnlyAuditCurrentFingerprint') == current_native.get('sourceFingerprint')
        and failure_audit.get('incompletePhase', {}).get('exitCode') == 124
        and failure_audit.get('incompletePhase', {}).get('recordedProductAssertionFailureObserved') is False
        and primary_hashes.get(e.manifest['receipts']['nativeInProgress']) == e.hashes.get(
            e.manifest['receipts']['nativeInProgress']))
    stop = d['qaStopAfterTimeout']
    d['qaStopReportedShutdown'] = (stop.get('exitCode') == 1
        and stop.get('toolResult', {}).get('didError') is True
        and any('code=405' in row.get('message','') and 'Shutdown' in row.get('message','')
                for row in stop.get('toolResult', {}).get('data', {}).get('diagnostics', {}).get('errors', [])))
    current_file_cases = [t for r in current_native.get('runs', []) if r.get('name') == 'directed'
                          for t in r.get('testCases', []) if case_key(t).startswith(
                              ('PreviouslyFilesTests/','AccountExportPreparationTests/'))]
    d['currentFilesPhasePassed'] = (d['currentDirectedPhasePassed'] and len(current_file_cases) == 7
        and len({case_key(t) for t in current_file_cases}) == 7
        and all(t.get('status') == 'passed' for t in current_file_cases))
    current_admission_cases = [t for r in current_native.get('runs', []) if r.get('name') == 'directed'
                               for t in r.get('testCases', []) if case_key(t).startswith('PreviouslyAdmissionTests/')]
    d['currentAdmissionPhasePassed'] = (d['currentDirectedPhasePassed'] and len(current_admission_cases) == 7
        and len({case_key(t) for t in current_admission_cases}) == 7
        and all(t.get('status') == 'passed' for t in current_admission_cases))
    admission_runs = d['admission'].get('runs', [])
    admission_cases = [t for r in admission_runs for t in r.get('testCases', [])
                       if t.get('suite') == 'PreviouslyAdmissionTests']
    d['admissionPassed'] = len(admission_cases) == 7 and all(t.get('status') == 'passed' for t in admission_cases)
    widget_cases = d['widget'].get('widgetCases', [])
    d['widgetPassed'] = len(widget_cases) == 14 and all(t.get('status') == 'passed' for t in widget_cases)
    archive = d['archive17']
    archive_inputs = d['archiveSourceManifest']
    source_proof = archive.get('provenance', {}).get('sourceManifest', {})
    archive_invocation = d['archiveInvocation']
    archive_tool = d['archiveToolReceipt']
    d['archivePassed'] = (str(archive.get('expectedBuild')) == '17'
        and archive_inputs.get('fileCount') == 596 and len(archive_inputs.get('files', [])) == 596
        and archive.get('status') == 'artifact_checks_passed'
        and len(archive.get('checks', {})) == 56
        and all(v is True for v in archive.get('checks', {}).values())
        and archive.get('failedChecks') == []
        and archive.get('observedCompileConfigurationPassed') is True
        and archive.get('suppliedSourceFreezeStillMatches') is True
        and source_proof.get('currentFilesMatch') is True and source_proof.get('changedPaths') == []
        and source_proof.get('sha256') == e.hashes.get(e.manifest['receipts']['archiveSourceManifest'])
        and archive_invocation.get('status') == 'tool_finished' and archive_invocation.get('exitCode') == 0
        and archive_invocation.get('archivePathExists') is True
        and archive_invocation.get('archivePath') == archive.get('archivePath')
        and archive_invocation.get('sourceManifestSHA256') == source_proof.get('sha256')
        and archive_invocation.get('stdout.jsonSHA256') == e.hashes.get(e.manifest['receipts']['archiveToolReceipt'])
        and archive_tool.get('didError') is False
        and archive_tool.get('data', {}).get('summary', {}).get('status') == 'SUCCEEDED'
        and archive.get('provenance', {}).get('compilerEvidence', {}).get('archiveSucceededMarker') is True)
    d['archiveNativeSourceLinked'] = (d['archivePassed'] and d['directedPassed'] and d['seedsPassed']
        and archive_inputs.get('nativeQAFingerprint') == summary.get('sourceFingerprint'))
    organizer = d['archiveOrganizerCopy']
    d['archiveOrganizerCopyVerified'] = (d['archivePassed']
        and organizer.get('copyVerified') is True and organizer.get('regularFilesCompared') == 73
        and organizer.get('mismatches') == [] and organizer.get('source') == archive.get('archivePath'))
    independent_archive = d['archiveIndependentReview']
    independent_provenance = independent_archive.get('provenance', {})
    d['independentArchiveReviewPassed'] = (d['archivePassed']
        and independent_archive.get('status') == 'evidence_chain_verified'
        and independent_archive.get('readOnlyInspection') is True and str(independent_archive.get('build')) == '17'
        and len(independent_archive.get('checks', {})) == 22
        and all(v is True for v in independent_archive.get('checks', {}).values())
        and independent_archive.get('failedChecks') == []
        and all(independent_provenance.get(key) == e.hashes.get(e.manifest['receipts'][alias])
                for key,alias in (
                    ('invocationSHA256','archiveInvocation'),('inspectionSHA256','archive17'),
                    ('sourceManifestFileSHA256','archiveSourceManifest'),('organizerReceiptSHA256','archiveOrganizerCopy'))))
    upload = d['upload17']
    d['uploadPassed'] = (d['archivePassed'] and str(upload.get('uploaded_build')) == '17'
        and upload.get('uploaded_version') == '1.0' and upload.get('upload_status') == 'uploaded'
        and upload.get('apple_upload_event', {}).get('state') == 'success')
    # Future human/runtime receipts require explicit exact-build claims. No fixture inference.
    d['releaseSimulatorPassed'] = (str(d['releaseSimulator17'].get('build')) == '17'
        and d['releaseSimulator17'].get('configuration') == 'Release'
        and d['releaseSimulator17'].get('qaFixtureUsed') is False
        and d['releaseSimulator17'].get('ordinaryProductionPasswordCyclePassed') is True)
    simulator_compile = d['releaseSimulatorCompile']
    simulator_invocation = d['releaseSimulatorCompileInvocation']
    simulator_tool = d['releaseSimulatorCompileTool']
    d['releaseSimulatorCompilePassed'] = (str(simulator_compile.get('build')) == '17'
        and simulator_compile.get('configuration') == 'Release'
        and simulator_compile.get('status') == 'compile_checks_passed'
        and len(simulator_compile.get('checks', {})) == 25
        and all(v is True for v in simulator_compile.get('checks', {}).values())
        and simulator_compile.get('failedChecks') == []
        and all(simulator_compile.get(k) is False for k in (
            'qaFixtureUsed','installPerformed','launchPerformed','sandboxResetPerformed','productionRuntimeVerified'))
        and simulator_compile.get('ordinaryProductionPasswordCyclePassed') is None
        and simulator_compile.get('sourceManifestSHA256') == e.hashes.get(
            e.manifest['receipts']['archiveSourceManifest'])
        and simulator_invocation.get('status') == 'tool_finished'
        and simulator_invocation.get('exitCode') == 0
        and simulator_invocation.get('stdout.jsonSHA256') == e.hashes.get(
            e.manifest['receipts']['releaseSimulatorCompileTool'])
        and simulator_tool.get('didError') is False
        and simulator_tool.get('data', {}).get('summary', {}).get('status') == 'SUCCEEDED'
        and simulator_tool.get('data', {}).get('summary', {}).get('target') == 'simulator')
    d['erasurePassed'] = (str(d['realErasure'].get('build')) == '17'
        and d['realErasure'].get('status') == 'server_provider_erasure_verified'
        and d['realErasure'].get('protectedIdentitiesUnchanged') is True)
    files = d['filesRuntime']
    file_cases = files.get('namedCases', [])
    expected_files = {name for name in selected if name.startswith(
        ('PreviouslyFilesTests/','AccountExportPreparationTests/'))}
    directed_files_coverage = [row for r in d['nativeDirected'].get('runs', [])
                              if r.get('name') == 'directed' for row in r.get('coverage', [])
                              if row.get('caseName') in FILES_COVERAGE]
    d['filesPassed'] = (d['seedsPassed'] and sealed_native_common(files, d['nativeDirected'], e)
        and files.get('originalLedgerPath') == summary.get('originalLedgerPath')
        and files.get('originalLedgerSHA256') == summary.get('originalLedgerSHA256')
        and files.get('counts') == {'passed':7,'failed':0,'skipped':0,'realFilesUI':3,'exportPreparation':4}
        and len(expected_files) == 7 and len(file_cases) == 7
        and {case_key(t) for t in file_cases} == expected_files
        and all(t.get('status') == 'passed' for t in file_cases)
        and files_coverage_pass(files.get('coverage', []))
        and files.get('coverage') == directed_files_coverage)
    focused = d['filesFocused']
    focused_runs = focused.get('runs', [])
    d['filesFocusedPassed'] = (native_directed_pass(focused, 3) and len(focused_runs) == 1
        and focused.get('fixtureStopped') is True
        and focused.get('configuration') == 'QA'
        and focused.get('bundleID') == 'com.cognipin.previously.qa'
        and {case_key(t) for t in focused_runs[0].get('testCases', [])} == FILES_UI_TESTS
        and files_coverage_pass(focused_runs[0].get('coverage', [])))
    prior_native = d['failedNativeFull']
    d['initialNativeFullFailed'] = (prior_native.get('status') == 'failed'
        and prior_native.get('qualified') is False
        and prior_native.get('directedCounts') == {'passed':64,'failed':11,'skipped':0}
        and prior_native.get('monkeysStarted') is False
        and len(prior_native.get('failureNames', [])) == 11)
    second_native = d['failedNativeFullSecond']
    d['secondNativeFullFailed'] = (second_native.get('status') == 'failed'
        and second_native.get('qualified') is False
        and second_native.get('directedCounts') == {'passed':74,'failed':1,'skipped':0}
        and second_native.get('monkeysStarted') is False
        and second_native.get('failureNames') == [
            'PreviouslyFilesTests/testJSONAndCSVSaveToFilesContainAccountCopyAndSurviveSignOut'])
    hero = d['heroFocused']
    d['heroFocusedPassed'] = (str(hero.get('build')) == '17' and hero.get('status') == 'passed'
        and hero.get('counts') == {'passed':2,'failed':0,'skipped':0}
        and hero.get('fixtureStopped') is True
        and len(hero.get('testCases', [])) == 2
        and {case_key(t) for t in hero.get('testCases', [])} == {
            'PreviouslyAccountIsolationTests/testOldOwnerDelayedWriteCannotRetryWithNewOwnerToken',
            'PreviouslyAccountIsolationTests/testOldOwnerFailedRetryAndCacheDoNotAppearForNewOwner'}
        and all(t.get('status') == 'passed' for t in hero.get('testCases', []))
        and hero.get('mutationAudit', {}).get('passed') is True)
    source_snapshot = d['historicalSourceSnapshot']
    d['historicalSourceSnapshotCaptured'] = (source_snapshot.get('fileCount') == 596
        and len(source_snapshot.get('files', [])) == 596
        and isinstance(source_snapshot.get('manifestSHA256'), str)
        and len(source_snapshot['manifestSHA256']) == 64
        and bool(source_snapshot.get('capturedAt'))
        and source_snapshot.get('nativeQAFingerprint') == hero.get('sourceFingerprint'))
    preflight = d['providerPreflight']
    d['providerReadPreflightPassed'] = (preflight.get('status') == 'provider_preflight_passed'
        and preflight.get('helperExitCode') == 0
        and preflight.get('providerOperations') == [
            {'method':'GET','resource':'/instance'},
            {'method':'GET','resource':'/v1/environment'},
            {'method':'GET','resource':'/users'}]
        and preflight.get('providerMutations') == 0
        and preflight.get('appRequestsOrSessionsCreated') == 0
        and all(preflight.get(k) is False for k in (
            'deletionMarkedStarted','currentDisposableProviderPresenceVerified',
            'currentDisposablePasswordVerified','freshDBReadPerformed',
            'readyBaselineCreatedOrReplaced','readyBaselineExists')))
    qa_readback = d['qaExactReadback']
    d['qaPresenceReadbackPassed'] = (qa_readback.get('status') == 'exact_qa_readback_completed'
        and qa_readback.get('httpStatus') == 200
        and qa_readback.get('expectedIdentityMatched') is True
        and qa_readback.get('passwordEnabled') is True
        and qa_readback.get('providerGETCount') == 1
        and qa_readback.get('providerMutations') == 0
        and qa_readback.get('appRequestsOrSessionsCreated') == 0
        and qa_readback.get('DBReadPerformed') is True
        and qa_readback.get('readOnlySQLVerified') is True
        and qa_readback.get('qaAppAccountPresent') is False
        and all(qa_readback.get(k) == 0 for k in (
            'qaLibraryEntryCount','qaProgressEntryCount','qaEpisodeSum'))
        and all(qa_readback.get(k) is False for k in (
            'deletionMarkedStarted','oneTitleOneEpisodeSetupReady',
            'readyBaselineCreatedOrReplaced','readyBaselineExists')))
    return d


def render(manifest_path, output=OUTPUT, *, draft=False):
    # PDF libraries and image reads occur only under an explicit --render invocation.
    from html import escape
    from PIL import Image
    from reportlab.pdfgen import canvas
    from reportlab.lib.colors import HexColor
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.platypus import Paragraph
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont

    manifest_raw = manifest_path.read_bytes()
    manifest = json.loads(manifest_raw)
    e = Evidence(manifest)
    d = evaluate(e)
    e.hashes[str(manifest_path.relative_to(ROOT))] = hashlib.sha256(manifest_raw).hexdigest()
    for asset in manifest['visuals'].values():
        path = ROOT / asset['path']
        if hashlib.sha256(path.read_bytes()).hexdigest() != asset['sha256']:
            raise ValueError('Visual asset changed; require an explicitly updated input manifest')
        e.hashes[asset['path']] = asset['sha256']
    for relative in manifest.get('textSources', []):
        path = ROOT / relative
        if not path.is_file():
            raise ValueError('Required evidence-semantics text is missing')
        e.hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    output = output.resolve()
    if draft and not output.is_relative_to(ROOT / 'tmp/pdfs'):
        raise ValueError('An initial draft must stay under tmp/pdfs')
    output.parent.mkdir(parents=True, exist_ok=True)
    pdfmetrics.registerFont(TTFont('Closeout', '/System/Library/Fonts/Supplemental/Arial.ttf'))
    pdfmetrics.registerFont(TTFont('CloseoutBold', '/System/Library/Fonts/Supplemental/Arial Bold.ttf'))
    pdfmetrics.registerFontFamily('Closeout', normal='Closeout', bold='CloseoutBold')
    c = canvas.Canvas(str(output), pagesize=(1200, 800), pageCompression=1)
    c.setTitle('Previously. Technical closeout | 15 October 2026')
    c.setAuthor('Prepared for Shantanu Sinha')
    ink, muted, paper, coral, green = '#171719', '#66666D', '#F5F5F7', '#F0563F', '#28745A'
    issues, prose, page = [], [], 0

    def box(x, y, w, h, color, radius=0):
        c.setFillColor(HexColor(color))
        c.roundRect(x, 800-y-h, w, h, radius, fill=1, stroke=0)

    def text(s, x, y, size=18, width=1072, color=ink, bold=False, max_height=160):
        prose.append(str(s))
        p = Paragraph(escape(str(s)).replace('\n', '<br/>'), ParagraphStyle('body',
            fontName='CloseoutBold' if bold else 'Closeout', fontSize=size, leading=size*1.34,
            textColor=HexColor(color)))
        _, height = p.wrap(width, 1000)
        if height > max_height or y+height > 742:
            issues.append({'page':page, 'text':str(s)[:80], 'y':y, 'height':height})
        p.drawOn(c, x, 800-y-height)
        return height

    def brand(x, y, size=18, dark=False):
        c.setFont('CloseoutBold', size)
        c.setFillColor(HexColor('#FFFFFF' if dark else ink))
        c.drawString(x, 800-y-size, 'Previously')
        c.setFillColor(HexColor(coral))
        c.drawString(x+pdfmetrics.stringWidth('Previously', 'CloseoutBold', size), 800-y-size, '.')

    def start(kicker, title, subtitle, dark=False):
        nonlocal page
        page += 1
        box(0, 0, 1200, 800, ink if dark else paper)
        brand(64, 32, 20, dark)
        text(kicker.upper(), 260, 42, 11, color=coral, bold=True)
        text(title, 64, 100, 43, color='#FFFFFF' if dark else ink, bold=True, max_height=120)
        text(subtitle, 64, 169, 17, color='#BDBDC6' if dark else muted, max_height=65)
        box(64, 756, 1072, 1, '#3A3A3E' if dark else '#DADADD')
        c.setFillColor(HexColor(muted)); c.setFont('Closeout', 10)
        c.drawString(64, 20, ('DRAFT / ' if draft else '')+'TECHNICAL CLOSEOUT / 15 OCT 2026')
        c.setFillColor(HexColor(coral)); c.setFont('CloseoutBold', 12)
        c.drawString(1118, 20, f'{page:02d}')
        prose.append(f'\n## {page:02d} {title}\n')

    def state(ok, pending='PENDING', failed=False):
        return 'PASSED' if ok else 'FAILED' if failed else pending

    def metric(x, y, value, label, body, width=240, passed=False, dark=False):
        text(value, x, y, 38, width, green if passed else coral, True, 75)
        text(label, x, y+59, 18, width, '#FFFFFF' if dark else ink, True, 65)
        text(body, x, y+112, 15, width, '#BDBDC6' if dark else muted, max_height=130)

    def photo(alias, x, y, w, h):
        path = ROOT / manifest['visuals'][alias]['path']
        iw, ih = Image.open(path).size
        scale = min(w/iw, h/ih)
        c.drawImage(str(path), x+(w-iw*scale)/2, 800-y-ih*scale,
                    iw*scale, ih*scale, mask='auto')

    start('Release 17 / evidence companion', 'Keep the place, keep the promise',
          ('DRAFT / Native qualification incomplete; distribution remains pending'
           if d['currentFullNativeFailed'] else 'DRAFT / Native and distribution qualification remain pending') if draft
          else 'A current technical closeout beside the historical release plan', True)
    # The cover uses approved marketing hardware; the native page uses an unaltered 9 Oct capture.
    photo('hero', 824, 230, 292, 470)
    text('Source is prepared\nQualification is explicit\nConsumers deserve the whole path', 64, 265, 30,
         700, '#FFFFFF', True, 160)
    text('iPhone only  /  Free initially  /  No new recurring spend\nMac Mini backend  /  Vercel landing',
         64, 455, 20, 700, '#BDBDC6', max_height=80)
    text('Native suite: '+state(d['directedPassed'] and d['seedsPassed'],
         pending='NOT QUALIFIED' if d['currentFullNativeFailed'] else 'PENDING')+'   |   5x: '+state(d['capacityPassed'])+
         '   |   Backend live: '+state(d['activationPassed']), 64, 579, 17, 710,
         coral, True, 65)
    text('Historical build 13 checks and 6 Oct load results do not qualify release 17.\nApple review closeout stays with the owner; no store action is implied.',
         64, 667, 14, 710, '#BDBDC6', max_height=60)
    photo('nativeIcon', 64, 718, 22, 22)
    text('Canonical native icon / actual archive asset', 103, 720, 11, 690, '#9898A4', max_height=20)
    c.showPage()

    start('Product / Add + Continue', 'An exact place, from the first tap',
          'Admission keeps the selected episode or season, including retry and a lost response')
    photo('episodes', 846, 238, 260, 464)
    for i, (title, body) in enumerate([
        ('Choose the intent', 'Accept the next episode, selected season or watched-through position. Cancellation leaves membership and progress untouched.'),
        ('Save it once', 'One operation retains the exact selection through retry. A committed write with a lost receipt must not add a second effect.'),
        ('Continue from there', 'Existing titles mark normally. A toolbar bulk action respects the chosen second season, rather than resetting to episode one.')]):
        y = 244+i*127
        text(f'0{i+1}', 64, y, 28, 80, coral, True, 45)
        text(title, 145, y, 23, 650, bold=True, max_height=40)
        text(body, 145, y+40, 17, 620, muted, max_height=80)
    text('7 / 7 admission cases passed in the current 75-case directed phase. The full run later timed out in its third seed; full qualification is unmet.'
         if d['currentAdmissionPhasePassed'] else
         '7 / 7 admission cases '+state(d['admissionPassed']).lower()+
         '. The focused enclosing run failed its three Files cases; it is not full-release qualification.',
         64, 660, 17, 740, green if d['admissionPassed'] else coral, max_height=70)
    text('Unaltered native capture, 9 Oct; visual context only, not release 17 execution proof.',
         64, 721, 11, 1040, muted, max_height=20)
    c.showPage()

    start('Native / trust boundaries', 'One account, one private library',
          'Snapshot ownership, Files behavior and full regression proof remain separate\nMonkey requests are 300-second budgets; XCTest idle waits also consume wall time')
    metric(64, 246, '14 named', 'Widget cases',
           'Ten storage and four QA app lifecycle cases '+state(d['widgetPassed']).lower()+
           '. Injected QA storage is separate from production App Group and WidgetKit refresh.', passed=d['widgetPassed'])
    metric(338, 246, '75', 'Directed selection',
           ('75/75 named cases passed in one sealed all-run, including ten storage and four export helpers.'
            if d['directedPassed'] else
            '75/75 directed phase passed. The same all-run later failed when the final seed hit its runner limit; phase passes do not seal qualification.'
            if d['currentFullNativeFailed'] else
            '75/75 directed phase passed in the fresh run. Full qualification awaits three matching seeds and completed cleanup.'
            if d['currentDirectedPhasePassed'] else
            'PENDING for the current source. Four export helpers expand the earlier selection; selection is not a pass.'), passed=d['directedPassed'] or d['currentDirectedPhasePassed'])
    metric(612, 246, str(d['currentPassedSeeds'])+' / 3' if d['currentFullNativeFailed'] else '3 x 300 s', 'Fixed monkey seeds',
           ('PASSED. Requested budgets; action cap applies. Sessions include setup, idle waits and oracle.'
            if d['seedsPassed'] else
            'Third seed hit the 30 min runner limit amid XCTest idle waits. Final assertions/oracle/relaunch unverified. Product defect and Mac-lock causality are unproven.'
            if d['currentFullNativeFailed'] else
            str(d['currentPassedSeeds'])+'/3 current seed phases passed; full receipt pending. Requested budgets are separate from wall time and XCTest idle waits.'), passed=d['seedsPassed'])
    metric(886, 246, '7 / 7' if d['currentFilesPhasePassed'] and not d['filesPassed'] else state(d['filesPassed']), 'Files journey',
           ('All seven Files/helper cases passed in the sealed full run. Synthetic samples and actual QA Files UI; physical/real-account proof is separate.'
            if d['filesPassed'] else
            'Seven Files/helper cases passed in the directed phase. No full success receipt: the third seed timed out. Fixture scope only.'
            if d['currentFilesPhasePassed'] and d['currentFullNativeFailed'] else
            'Focused 3/3 Files UI passed: picker imports and saved JSON/CSV copies. The full same-run seven-case Files/helper receipt remains pending.'
            if d['filesFocusedPassed'] else
            'Earlier export naming and repeat requests failed. Distinct types/coalescing need real Files UI and full same-run proof.'), passed=d['filesPassed'] or d['currentFilesPhasePassed'])
    box(64, 548, 1072, 133, '#FFFFFF', 16)
    text('Clear the old account before the next owner can read', 88, 571, 23, 1000, bold=True, max_height=40)
    text('Same-owner offline relaunch may retain its valid snapshot. Sign-out, account switch and uncertain deletion clear widget data and reject late writers. Real production erasure and physical widget refresh remain separate evidence.',
         88, 613, 17, 1000, muted, max_height=65)
    if d['initialNativeFullFailed']:
        text(('Prior full runs: 64/75 then 74/75; no monkeys. ' if d['secondNativeFullFailed'] else
              'Prior full run: 64/75; 11 failed, no monkeys. ')+
             'Separate focused results: hero '+('2/2' if d['heroFocusedPassed'] else 'pending')+
             ', Files '+('3/3' if d['filesFocusedPassed'] else 'pending')+'. '+
             'Common causation and pixel-level animation readiness remain unproven.',
             64, 700, 12, 1060, muted, max_height=40)
    c.showPage()

    start('Capacity / practical 5x qualification', 'Qualify the surge, preserve the failures',
          '15 requests/s is the working peak assumption, not an adoption forecast\nLocal API/PostgreSQL fixtures use deterministic providers; live-provider and WAN capacity remain separate')
    phases = {p.get('name'):p for p in d['backendLoad'].get('phases', [])}
    def latency(phase):
        p = phases.get(phase, {})
        return ('; p95/p99 '+str(p['p95Ms'])+'/'+str(p['p99Ms'])+' ms'
                if d['capacityPassed'] and isinstance(p.get('p95Ms'),(int,float))
                and isinstance(p.get('p99Ms'),(int,float)) else '')
    for i, (label, rate, detail, color) in enumerate([
        ('WORKING PEAK',15,'2 min warmup', '#2465BA'),
        ('SUSTAINED 5x',75,'15 min, 95% reads / 5% writes'+latency('sustained'), green),
        ('SHORT BURST',150,'1 min, then 5 min recovery'+latency('burst'),coral)]):
        y=249+i*88
        text(label,64,y+9,12,240,muted,True,30)
        text(str(rate),300,y,31,100,color,True,50)
        box(408,y+5,702,18,'#E2E2E7',9);box(408,y+5,702*rate/150,18,color,9)
        text(detail,408,y+36,15,690,muted,max_height=30)
    load_failed = d['backendLoad'].get('qualification') == 'failed'
    text('CURRENT CANDIDATE: '+state(d['capacityPassed'], failed=load_failed),64,548,27,1000,
         green if d['capacityPassed'] else coral,True,50)
    text('82,800 / 82,800 core requests; 200 cold searches; two 50-show imports. All 798 canonical checks matched. Errors, timeouts, drops, HTTP 5xx and incorrect responses: zero. Exact frozen artifact verified.'
         if d['capacityPassed'] else 'Required profile: 82,800 core requests, 200 cold searches, two 50-show imports and canonical write checks. PASS requires the exact immutable fingerprint and zero errors, drops, timeouts or write mismatches.',
         64,595,19,1060,muted,max_height=80)
    first_failure = d['backendFailedLoad']
    failed_history = ('First 15 Oct attempt failed: '+str(first_failure['timeoutCount'])+
        ' timeouts and '+str(first_failure['writeOracleMismatch'])+
        ' canonical mismatches. Shared-host contention correlated with the slowdown; sole causation is unproven. Preserve that failure and unchanged criteria.'
        if first_failure.get('qualification') == 'failed'
        and first_failure.get('timeoutCount') is not None
        and first_failure.get('writeOracleMismatch') is not None
        else 'First 15 Oct attempt evidence is unavailable; do not infer a clean history or substitute the 6 Oct pass.')
    text(failed_history,
         64,689,13,1060,muted,max_height=45)
    c.showPage()

    start('Mac Mini / useful operational evidence', 'Small service, visible behavior',
          'Capacity and deployment are distinct; the first activation and manual recovery remain in the record')
    activation_body = ('Corrected supervised activation passed at 16:56:12 UTC: matching fingerprint, readiness, backup and healthy collector. First attempt had an 85.96 s observed recovery window and required manual old-service recovery; automatic rollback did not restart it.'
        if d['activationPassed'] else
        'New activation remains pending after the first attempt failed. Old plist bytes were restored; automatic restart failed. The old three jobs were manually bootstrapped at 16:51:59 UTC; local/public readiness returned 200. No database restore.'
        if d['manualOldServiceRecovered'] else
        'Production activation: pending. Require matching capacity, exact pointers, a pre-activation restore, readiness, verified backup and a healthy collector. An incomplete or failed attempt is not activation proof.')
    if d['productionReadbackPassed']:
        activation_body = ('Corrected activation passed at 16:56:12 UTC with matching artifact, readiness, verified backup and collector. First attempt required manual recovery after an observed 85.96 s; automatic rollback did not restart it. At 18:23, backup metadata, size and 0600 mode remained intact; no new backup/checksum run.')
    for x,title,body in [
        (64,'A reproducible candidate','1,340 units / 39 SQL status and cron cases / 6 recovery / 27 content policy / 26 operator checks. Zero production advisories. Candidate preparation: '+state(d['backendPreparedPassed'])+'.'),
        (612,'Promote only the qualified artifact',activation_body)]:
        text(title,x,248,24,510,bold=True,max_height=65);text(body,x,320,18,510,muted,max_height=150)
    box(64,486,1072,1,'#DADADD')
    usage = (d['productionTelemetry'].get('usage', {}).get('counts', {}) if d['productionTelemetryObserved'] else
             d['backendActivation'].get('postActivationProof', {}).get('usage', {}).get('counts', {}))
    usage_body = ('18:23 UTC: '+str(usage['registered'])+' app profiles; last open in 24h: '+str(usage['active_24h'])+
        ', 7d: '+str(usage['active_7d'])+'. Library profiles '+str(usage['library_users'])+
        '; progress '+str(usage['progress_users'])+'. Includes legacy/QA/review identities; not consumer adoption, MAU or retention.'
        if d['productionTelemetryObserved'] else
        'At 16:56 UTC: '+str(usage['registered'])+' app profiles; '+str(usage['active_24h'])+
        ' active in 24h / '+str(usage['active_7d'])+' in 7d. Library profiles '+str(usage['library_users'])+
        '; progress profiles '+str(usage['progress_users'])+'. Confirmed app-open activity includes QA/review accounts; this is not consumer adoption or retention.'
        if d['activationPassed'] and all(isinstance(usage.get(k),int) for k in (
            'registered','active_24h','active_7d','library_users','progress_users')) else
        'Use actual activation and repeat use. Raw profile totals include QA/reviewer accounts; no new consumer counts or retention cohorts are asserted.')
    metrics = d['productionTelemetry'].get('metrics', {})
    operations_body = ('18:23 UTC: '+str(metrics['requests'])+' requests / '+str(metrics['errors'])+
        ' server errors since cutover; counters reset on restart. Local/public /health and /ready returned 200. Collector was healthy at 17:56, 27 min old.'
        if d['productionReadbackPassed'] and d['productionTelemetryObserved'] else
        'Private route-pattern/request-ID diagnostics, errors, RPS and latency. Inspect collector freshness, backup age, disk and pending erasure. No public uptime guarantee.')
    for x,title,body in [
        (64,'See errors and throughput',operations_body),
        (438,'Measure the useful loop',usage_body),
        (812,'Recover within the actual boundary',
         ('17 / 17 guard fixture checks recorded; captured PID/unload and bounded bootstrap repaired. ' if d['activationGuardChecksPassed'] else 'Guard repair qualification remains pending. ')+
         'First automatic rollback failed; manual recovery is separate. Same-Mac backups do not cover hardware loss.')]:
        text(title,x,521,20,320,bold=True,max_height=65);text(body,x,591,16,320,muted,max_height=130)
    if d['productionReadbackPassed']:
        text('Readiness: /ready. /health/ready is unimplemented (404). No new backup/checksum/restart was run; a scheduled stale-report tick remains unproven.',
             64,727,10,1072,muted,max_height=14)
    c.showPage()

    start('Handoff / technical and owner responsibilities', 'Every finish has its own receipt',
          'Keep candidate qualification, production operation, distribution and review distinct',True)
    rows=[('Native 17',state(d['directedPassed'] and d['seedsPassed'] and d['filesPassed'],
           pending='NOT QUALIFIED' if d['currentFullNativeFailed'] else 'PENDING'),
           ('75 directed and first two seeds passed; third exceeded the 30 min runner limit before final oracle/relaunch. Full qualification remains unmet.'
            if d['currentFullNativeFailed'] else
            'Complete the current 75 directed cases, three matching seeds and actual Files imports/exports.')),
          ('Production backend',state(d['capacityPassed'] and d['activationPassed']),
           'Preserve both the failed attempt and final exact-artifact capacity/activation receipts.'),
          ('Build 17 archive',state(d['archivePassed']),
           ('56 artifact checks'+(' + 22 evidence-chain checks' if d['independentArchiveReviewPassed'] else '')+
            ' passed, with observed Release compiler/source proof. Inputs captured 18:41 before native completion. Upload: '+state(d['uploadPassed'])+'; GUI needs Mac unlock.'
            if d['archivePassed'] else
            'Historical 17:35 input snapshot predates qualification. Archive: '+state(d['archivePassed'])+
            '; upload: '+state(d['uploadPassed'])+'. Separate artifact receipts are required.'
            if d['historicalSourceSnapshotCaptured'] else
            'Actual artifact, compiler/source/signature and upload receipts. Earlier build 16 upload is historical.')),
          ('Real consumer lifecycle',state(d['releaseSimulatorPassed'] and d['erasurePassed']),
           ('Release simulator: 25 compile checks; no install/launch. QA provider exists, SQL empty. Ordinary login/erasure need GUI unlock and a ready baseline.'
            if d['releaseSimulatorCompilePassed'] and d['qaPresenceReadbackPassed']
            and not (d['releaseSimulatorPassed'] and d['erasurePassed']) else
            'Dedicated QA provider/password verified; SQL has no app account/library/progress. Ready baseline and actual erasure remain pending.'
            if d['qaPresenceReadbackPassed'] and not (d['releaseSimulatorPassed'] and d['erasurePassed']) else
            'Three provider GETs passed; no disposable-account, database or erasure baseline was verified. Actual Release sign-in/erasure remain separate.'
            if d['providerReadPreflightPassed'] and not (d['releaseSimulatorPassed'] and d['erasurePassed']) else
            'Ordinary production Release sign-in and independently read-back account erasure; fixture results do not substitute.')),
          ('Apple review closeout','WITH OWNER',
           'Last independently read portal state is the 7 Oct information request. No fresh portal decision, recording, reply or resubmission is asserted here.')]
    for i,(title,status,body) in enumerate(rows):
        y=239+i*92
        text(title,64,y,21,390,'#FFFFFF',True,40)
        text(status,835,y+1,15,280,'#6BCCA2' if status=='PASSED' else coral,True,40)
        text(body,64,y+35,16,1060,'#BDBDC6',max_height=50)
    text('Free initially. Comments off. No licensing outreach before market validation. Physical/iOS 18/VoiceOver/WAN recommendations and Apple-requested recording retain their distinct scopes.',
         64,716,11,1060,'#9898A4',max_height=30)
    c.showPage();c.save()
    snapshot={'schemaVersion':1,'builtAtUTC':datetime.now(timezone.utc).isoformat(),
              'pdfPath':str(output),'pdfSha256':hashlib.sha256(output.read_bytes()).hexdigest(),'draft':draft,
              'builderPath':str(Path(__file__).resolve()),
              'builderSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'inputManifestPath':str(manifest_path),
              'inputManifestSha256':hashlib.sha256(manifest_raw).hexdigest(),
              'pages':page,'layoutIssues':issues,'receiptSha256':e.hashes,'missingAliases':e.missing,
              'verifiedStates':{k:v for k,v in d.items() if k.endswith('Passed')},
              'initialActivationFailed':d['initialActivationFailed'],
              'manualOldServiceRecovered':d['manualOldServiceRecovered'],
              'initialNativeFullFailed':d['initialNativeFullFailed'],
              'secondNativeFullFailed':d['secondNativeFullFailed'],
              'historicalSourceSnapshotCaptured':d['historicalSourceSnapshotCaptured'],
              'currentPassedSeeds':d['currentPassedSeeds'],
              'currentFullNativeFailed':d['currentFullNativeFailed'],
              'finalFailureAuditMatched':d['finalFailureAuditMatched'],
              'qaStopReportedShutdown':d['qaStopReportedShutdown'],
              'qaStopAppSuccessClaimed':False,
              'archiveNativeSourceLinked':d['archiveNativeSourceLinked'],
              'archiveOrganizerCopyVerified':d['archiveOrganizerCopyVerified'],
              'archiveInputsCapturedAtUTC':d['archiveSourceManifest'].get('capturedAt'),
              'productionTelemetryObserved':d['productionTelemetryObserved'],
              'productionSnapshotMeasuredAtUTC':d['productionSnapshot'].get('measuredAtUTC'),
              'collectorMeasuredAtUTC':d['productionSnapshot'].get('collector', {}).get('measuredAt'),
              'automaticRollbackSucceededOnFirstAttempt':d['activationOutageReview'].get('automaticRollbackSucceeded'),
              'capacityRunFinishedAtUTC':d['backendLoad'].get('runFinishedAt'),
              'initialObservedRecoveryWindowSeconds':d['activationOutageReview'].get('observedRecoveryWindowSeconds'),
              'activationDiagnosticBoundary':d['activationOutageReview'].get('diagnosticBoundary'),
              'requiresAllPageVisualReview':True,'historicalPdfModified':False,
              'proofBoundary':'Technical companion; no Apple action, actual adoption, universal uptime or consumer readiness inferred.'}
    (HERE/('draft-render-evidence.json' if draft else 'render-evidence.json')).write_text(json.dumps(snapshot,indent=2)+'\n')
    (HERE/('draft-closeout.md' if draft else 'closeout.md')).write_text('\n\n'.join(prose)+'\n')
    print(json.dumps({k:snapshot[k] for k in ('pdfPath','pages','layoutIssues','missingAliases')},indent=2))
    if issues:
        raise SystemExit('Render exists for repair; layout checks require correction before delivery')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs',type=Path,default=HERE/'receipt-inputs.json')
    parser.add_argument('--render',action='store_true',help='Only after the coordinator authorizes rendering')
    parser.add_argument('--draft',action='store_true',help='Pending technical-state visual draft; writes only under tmp/pdfs')
    parser.add_argument('--output',type=Path,help='Explicit output target; draft target must be under tmp/pdfs')
    args=parser.parse_args()
    if not args.render:
        parser.error('Source-only preparation. Rendering requires explicit --render after the quiet window.')
    output = args.output or (ROOT/'tmp/pdfs/previously-closeout-draft-20261015.pdf' if args.draft else OUTPUT)
    render(args.inputs.resolve(),output,draft=args.draft)


if __name__=='__main__':
    main()
