"""Create the release-facing receipt from a completed full-duration owned QA run.

Reads saved evidence only. Short profiles cannot produce a capacity receipt.
"""
from pathlib import Path
import argparse
import hashlib
import json
import statistics

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'docs/qa/2026-10-06'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('run', type=Path)
parser.add_argument('--output', type=Path, default=BASE / 'load-testing/final-results.json')
parser.add_argument('--protocol-evidence', type=Path, default=BASE / 'progress-faults/compiled-node24-apple-policy')
parser.add_argument('--recovery-evidence', type=Path, default=BASE / 'deletion-recovery/compiled-node24-apple-policy')
parser.add_argument('--policy-evidence', type=Path, default=BASE / 'content-policy/compiled-node24-apple-policy')
parser.add_argument('--artifact-manifest', type=Path, default=BASE / 'operations/apple-policy-artifact/artifact-manifest.json')
args = parser.parse_args()
run = args.run.resolve()
assert run.is_relative_to(BASE / 'load-testing'), 'Receipt must use saved owned load evidence'

def read(path):
    return json.loads(path.read_text())

traffic = read(run / 'traffic-results.json')
ledger = read(run / 'run-ledger.json')
memory = read(run / 'memory-review.json')
metrics = read(run / 'server-metrics.json')
sources = read(run / 'source-files.json')
resources = read(run / 'server-resources.json')
artifact_path = args.artifact_manifest.resolve()
assert artifact_path.is_relative_to(BASE), 'Artifact proof must use saved release evidence'
artifact = read(artifact_path)
artifact_digest = hashlib.sha256(json.dumps(artifact['files'], sort_keys=True, separators=(',', ':')).encode()).hexdigest()
assert artifact_digest == artifact['sourceSHA256'], 'Artifact manifest digest must be valid'
artifact_unmapped = [key for key in artifact['files'] if 'server/' + key not in sources]
assert artifact_unmapped == ['ops/README.md'], 'Every executable artifact file must be pinned by the load run'
artifact_matches = all(sources['server/' + key] == value for key, value in artifact['files'].items()
                       if 'server/' + key in sources)
assert not traffic['quickHarnessOnly'] and not traffic.get('calibrationOnly'), 'Short profiles never qualify capacity'
phases = traffic['results']
assert [(p['name'], p['rps'], p['seconds']) for p in phases] == [
    ('warmup', 15, 120), ('sustained', 75, 900), ('burst', 150, 60), ('recovery', 15, 300)
], 'Unexpected full-duration profile'
assert ledger.get('finishedAt'), 'Owned run must finish cleanup before a final receipt'

sql_evidence = {}
same_compiled = True
for label, path in [('protocol', args.protocol_evidence), ('recovery', args.recovery_evidence),
                    ('policy', args.policy_evidence)]:
    path = path.resolve()
    assert path.is_relative_to(BASE), 'SQL proof must use saved owned QA evidence'
    raw = read(path / 'results.json')
    result = raw.get('summary') or {'total': len(raw['cases']),
        'passed': sum(case['status'] == 'passed' for case in raw['cases']),
        'failed': sum(case['status'] != 'passed' for case in raw['cases'])}
    sql_ledger = read(path / 'run-ledger.json')
    manifest = read(path / ('source-files.json' if label == 'policy' else 'compiled-files.json'))
    # Compare executed production modules/ops only. QA test modules are not loaded by the
    # production server and deliberately excluded by the capacity launcher's fingerprint.
    runtime = {key: value for key, value in manifest.items()
               if (key.startswith('server/dist/') or key.startswith('server/ops/'))
               and not key.endswith('.test.mjs')}
    assert runtime and any(key.startswith('server/dist/') for key in runtime)
    identical = all(sources.get(key) == value for key, value in runtime.items())
    same_compiled = same_compiled and identical
    sql_evidence.update({label + 'Passed': result['passed'], label + 'Total': result['total'],
                        label + 'Path': str(path.relative_to(ROOT)), label + 'CompiledMatches': identical})
    assert result['failed'] == 0 and sql_ledger['overallExitCode'] == 0
    assert sql_ledger['databaseRemoved'] and sql_ledger['scratchConnectionsBeforeDrop'] == 0
    if label in ('policy', 'recovery'):
        assert sql_ledger['ownedOpsRemoved']
    if label == 'policy':
        assert raw['passed'] and not any(raw['transport'][key] for key in ('blockedFetches', 'blockedSockets', 'unsupportedQueries'))

background = traffic['backgroundStress']
all_counts = phases + [background]
def total(key):
    return sum(p[key] for p in all_counts)

changed = ledger['sourceChangedDuringRun']
source_frozen = not changed
dist_frozen = not any(p.startswith('server/dist/') for p in changed)
cleanup = {key: ledger[key] for key in ('databaseRemoved', 'ownedOpsRemoved', 'scratchConnectionsBeforeDrop')}
provider = metrics['providerStats']
outbound = {'blockedFetches': provider['blockedRequests'],
            'blockedSockets': metrics['socketGuard']['rejectedConnections'],
            'unsupportedProviderQueries': provider['unsupportedQueries'],
            'syntheticAniListCalls': provider['anilistCalls']}
counts = {label: total(key) for label, key in [('errorCount', 'requestErrors'), ('serverErrorCount', 'serverErrors'),
                                             ('droppedCount', 'dropped'), ('timeoutCount', 'timeouts'),
                                             ('incorrectResponseCount', 'incorrectResponses')]}
imports = traffic['importResults']
oracle = traffic['canonicalWriteOracle']
qualified = (ledger['overallExitCode'] == 0 and traffic['qualifiedDuration']
             and traffic['passedRequestAndLatencyCriteria'] and memory['qualifiedDuration'] and memory['passed']
             and source_frozen and dist_frozen and same_compiled and artifact_matches
             and cleanup['databaseRemoved'] and cleanup['ownedOpsRemoved'] and cleanup['scratchConnectionsBeforeDrop'] == 0
             and not any(counts.values()) and oracle['mismatchCount'] == 0
             and all(p['achievedRPS'] >= p['rps'] * .98 and p['latency']['p95Ms'] < 1000
                     and p['latency']['p99Ms'] < 2000 for p in phases)
             and len(imports) == 2 and all(i['ok'] and i['progress']['shows'] == 50
                                         and i['progress']['failed'] == 0 for i in imports)
             and outbound['blockedFetches'] == 0 and outbound['blockedSockets'] == 0
             and outbound['unsupportedProviderQueries'] == 0)

resource_summary = {}
for phase in phases:
    rows = [r for r in resources if r['phase'] == phase['name']]
    resource_summary[phase['name']] = {
        'samples': len(rows),
        'cpuMedianPercentOfOneCore': statistics.median(r['cpuPercentOfOneCore'] for r in rows),
        'cpuMaxPercentOfOneCore': max(r['cpuPercentOfOneCore'] for r in rows),
        'eventLoopDelayMaxMs': max(r['eventLoopDelayMaxMs'] for r in rows),
    }

receipt = {
    'schemaVersion': 1, 'qualification': 'passed' if qualified else 'failed', 'qualified': qualified,
    'evidencePath': str(run.relative_to(ROOT)),
    'measurementStartedAt': metrics['phaseSnapshots'][1]['startedAt'],
    'runStartedAt': ledger['startedAt'], 'runFinishedAt': ledger['finishedAt'],
    'runtime': {key: ledger[key] for key in ('nodeVersion', 'nodeBinary', 'nodeOptions', 'productionModule',
                                          'sourceRevision', 'dirtySource')},
    'compiledManifestPath': str((run / 'source-files.json').relative_to(ROOT)),
    'artifact': {
        'path': artifact['artifact'], 'sourceSHA256': artifact['sourceSHA256'],
        'manifestPath': str(artifact_path.relative_to(ROOT)), 'matchesLoadFingerprint': artifact_matches,
        'mappedFiles': len(artifact['files']) - len(artifact_unmapped),
        'excludedDocumentation': artifact_unmapped,
        'productionDependenciesOnly': artifact['productionDependenciesOnly'],
        'productionAuditAdvisories': artifact['productionAuditAdvisories'],
        'credentialsIncluded': artifact['credentialsIncluded'],
        'installedAtArtifactCapture': artifact['installed'],
    },
    'coreRequests': sum(p['completed'] for p in phases),
    'coreOfferedRequests': sum(p['offered'] for p in phases),
    'coldSearches': background['routes']['cold-search']['completed'],
    'concurrentImports': len(imports), 'importResults': imports,
    'phases': [{'name': p['name'], 'rps': p['rps'], 'durationSeconds': p['seconds'],
                'actualElapsedSeconds': p['actualElapsedMs'] / 1000, 'achievedRPS': p['achievedRPS'],
                'offered': p['offered'], 'completed': p['completed'],
                'p95Ms': p['latency']['p95Ms'], 'p99Ms': p['latency']['p99Ms'],
                'sendLagP99Ms': p['sendLag']['p99Ms'], 'routes': p['routes']} for p in phases],
    **counts, 'writeOracleChecked': oracle['checked'], 'writeOracleMismatch': oracle['mismatchCount'],
    'heapDeltaMiB': memory['maxHeapUsedMiB'] - memory['warmupBaselineHeapUsedMiB'],
    'rssDeltaMiB': memory['maxRSSMiB'] - memory['warmupBaselineRSSMiB'],
    'memory': memory, 'outbound': outbound, 'sourceFrozen': source_frozen, 'distFrozen': dist_frozen,
    'cleanup': cleanup, 'sqlEvidence': sql_evidence,
    'responseBytes': {'wireBodyBytes': total('wireBytes'), 'decodedBodyBytes': total('jsonBytes'),
                      'boundary': 'Response bodies only; excludes headers and HTTP framing. Fixture compression is not a production forecast.'},
    'resourceSummary': resource_summary, 'gc': metrics['gc'],
    'queryPhases': metrics['phaseSnapshots'], 'fixtures': traffic['fixtures'],
    'hostSwapBefore': ledger['hostMemoryBefore'], 'hostSwapAfter': ledger['hostMemoryAfter'],
    'boundaries': traffic['limitations'] + [
        'Shared Mini normal services remain resident; no dedicated-host or global WAN capacity proof.',
        'Independent import accounts do not cover simultaneous import versus ordinary edit on the same account.',
        'SQL dispatch callback includes scheduling/connection/socket delays, has partial coverage, and is not isolated pool wait.',
        'GC observations are wall durations, not isolated GC CPU. No forced GC.',
        'A finite 23-minute plateau/recovery test does not prove unlimited uptime.',
    ],
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({'qualified': qualified, 'output': str(args.output), 'coreRequests': receipt['coreRequests']}))
