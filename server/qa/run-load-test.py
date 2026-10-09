"""Run bounded HTTP load only against a fresh, owned loopback scratch database.

No target URL/database option exists. --quick validates the harness, never capacity.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import re
import secrets
import signal
import subprocess
import time
import uuid
import tempfile
import shutil

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
profile = parser.add_mutually_exclusive_group()
profile.add_argument('--quick', action='store_true')
profile.add_argument('--calibrate', action='store_true', help='390-second shared-host resource probe; never qualifies capacity')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
output = (args.output or ROOT / 'docs/qa/2026-10-06/load-testing' / (stamp + '-' + uuid.uuid4().hex[:8])).resolve()
output.mkdir(parents=True, exist_ok=False)
os.chmod(output, 0o700)
name = 'previously_qa_load_' + uuid.uuid4().hex
assert re.fullmatch(r'previously_qa_load_[a-f0-9]{32}', name)
env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'LANG') if key in os.environ}
node_lts = Path('/opt/homebrew/opt/node@24/bin/node')
assert node_lts.is_file(), 'Installed Node24LTS is required; no runtime installation is attempted'
env['PATH'] = str(node_lts.parent) + ':' + env.get('PATH', '')
env.update(DATABASE_URL=f'postgres://127.0.0.1:5432/{name}', DOTENV_CONFIG_PATH='/dev/null',
           NODE_OPTIONS='--max-old-space-size=256 --max-semi-space-size=8',
           APP_ENV='test', DEV_AUTH_BYPASS='1', CLERK_SECRET_KEY='', CLERK_JWT_KEY='',
           OPENROUTER_API_KEY='', CEREBRAS_API_KEY='', TMDB_ACCESS_TOKEN='', ANTHROPIC_API_KEY='',
           NEWS_AGENT_DISABLED='1', NEWS_CODEX_FALLBACK_ENABLED='0', GROUPING_LLM_DISABLED='1',
           SEARCH_CORRECT_DISABLED='1', SOCIAL_COMMENTS_ENABLED='0', MODERATION_ALERT_WEBHOOK_URL='',
           LOAD_READY_PATH=str(output / 'ready.json'), LOAD_RESULTS_DIR=str(output),
           LOAD_CONTROL_TOKEN=secrets.token_urlsafe(32), LOAD_QUICK='1' if args.quick else '0',
           LOAD_CALIBRATE='1' if args.calibrate else '0')
env['OBSERVABILITY_TOKEN'] = env['LOAD_CONTROL_TOKEN']

def psql(query):
    return subprocess.run(['psql', '-h', '127.0.0.1', '-d', 'postgres', '-X', '-At',
                           '-v', 'ON_ERROR_STOP=1', '-v', f'qa_name={name}'], input=query,
                          text=True, capture_output=True, check=True, env=env, timeout=10).stdout.strip()

def stop_owned(child):
    if child:
        # The launcher may exit before its descendants. Its owned process group is
        # still ours, and stopping it must not depend on the leader's poll result.
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=8)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=5)

def resource_sample():
    result = subprocess.run(['ps', '-A', '-o', 'pid=,pcpu=,rss=,comm='], text=True,
                            capture_output=True, env=env, timeout=5)
    processes = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            processes.append({'pid': int(fields[0]), 'cpuPercent': float(fields[1]),
                              'rssKiB': int(fields[2]), 'command': fields[3]})
    return {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'topByRSS': sorted(processes, key=lambda p: p['rssKiB'], reverse=True)[:30],
            'totalProcessRSSKiB': sum(p['rssKiB'] for p in processes)}

def source_snapshot():
    paths = set()
    # Pin the compiled artifact and its production sources independently. Tests
    # do not enter dist; operator scripts are also emitted in the release artifact.
    source_root = ROOT / 'server/src'
    paths.update(p for p in source_root.rglob('*') if p.is_file()
                 and p.suffix in ('.ts', '.json') and not p.name.endswith('.test.ts'))
    for directory in ('server/dist', 'server/drizzle', 'server/ops'):
        paths.update(p for p in (ROOT / directory).rglob('*') if p.is_file()
                     and p.suffix in ('.js', '.map', '.ts', '.sql', '.json', '.mjs', '.mts'))
    for relative in ('server/package.json', 'server/package-lock.json', 'server/drizzle.config.ts',
                     'server/tsconfig.json', 'server/tsconfig.build.json', 'server/dist/server.js',
                     'server/dist/db/index.js', 'server/qa/load-server.ts', 'server/qa/load-traffic.ts',
                     'server/qa/load-provider-stubs.ts', 'server/qa/run-load-test.py'):
        path = ROOT / relative
        if not path.is_file():
            raise RuntimeError(f'Required qualification source missing: {relative}')
        paths.add(path)
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}

def review_memory(samples):
    # Declared before the qualifying run. This finite run measures plateau/recovery,
    # not a claim that memory stays bounded for an unlimited period.
    mib = 1024 * 1024
    if not isinstance(samples, list) or not samples:
        raise ValueError('Resource evidence must contain a nonempty sample list')
    for sample in samples:
        if not isinstance(sample, dict) or not isinstance(sample.get('at'), str) or not isinstance(sample.get('phase'), str):
            raise ValueError('Malformed resource sample identity')
        for field in ('rss', 'heapUsed'):
            if not isinstance(sample.get(field), (int, float)) or isinstance(sample[field], bool) or not 0 <= sample[field] < float('inf'):
                raise ValueError(f'Malformed resource sample {field}')
    recovery = [s for s in samples if s['phase'] == 'recovery']
    sustained = [s for s in samples if s['phase'] == 'sustained']
    warmup = [s for s in samples if s['phase'] == 'warmup']
    def median(values):
        values = sorted(values)
        return values[len(values) // 2] if values else 0
    last_recovery = recovery[-12:]
    last_sustained = sustained[-12:]
    trend = recovery[-48:]
    slope = 0
    if len(trend) > 1:
        times = [datetime.datetime.fromisoformat(s['at'].replace('Z', '+00:00')).timestamp() / 60 for s in trend]
        mean_x = sum(times) / len(times)
        mean_y = sum(s['rss'] / mib for s in trend) / len(trend)
        denominator = sum((x - mean_x) ** 2 for x in times)
        slope = sum((x - mean_x) * (s['rss'] / mib - mean_y) for x, s in zip(times, trend)) / denominator if denominator else 0
    final_rss = median([s['rss'] for s in last_recovery]) / mib
    steady_rss = median([s['rss'] for s in last_sustained]) / mib
    active = [s for s in samples if s['phase'] in ('sustained', 'burst', 'recovery')]
    max_rss = max([s['rss'] for s in active], default=0) / mib
    max_heap = max([s['heapUsed'] for s in active], default=0) / mib
    baseline_rss = median([s['rss'] for s in warmup[-12:]]) / mib
    baseline_heap = median([s['heapUsed'] for s in warmup[-12:]]) / mib
    criteria = {'maxRSSGrowthOverWarmupMiB': 128, 'maxHeapUsedGrowthOverWarmupMiB': 64, 'recoveryMedianOverSteadyAllowanceMiB': 32,
                'lastFourMinuteRecoveryRSSSlopeMiBPerMinute': 2}
    qualified = len(recovery) >= 48 and len(sustained) >= 12 and len(warmup) >= 12
    passed = qualified and max_rss <= baseline_rss + 128 and max_heap <= baseline_heap + 64 and final_rss <= steady_rss + 32 and slope <= 2
    return {'criteria': criteria, 'qualifiedDuration': qualified, 'passed': passed,
            'maxRSSMiB': max_rss, 'maxHeapUsedMiB': max_heap,
            'warmupBaselineRSSMiB': baseline_rss, 'warmupBaselineHeapUsedMiB': baseline_heap,
            'lastMinuteSustainedMedianRSSMiB': steady_rss, 'lastMinuteRecoveryMedianRSSMiB': final_rss,
            'lastFourMinuteRecoveryRSSSlopeMiBPerMinute': slope,
            'meaning': 'Observed plateau/recovery within23minutes, not proof of unlimited uptime.'}

ledger = {'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'database': name,
          'host': '127.0.0.1', 'databaseCreated': False, 'databaseRemoved': False,
          'productionDatabaseReadOrWritten': False, 'dotenvLoaded': False,
          'credentialsInherited': False, 'quickHarnessOnly': args.quick or args.calibrate, 'calibrationOnly': args.calibrate,
          'nodeOptions': env['NODE_OPTIONS'],
          'nodeVersion': subprocess.check_output([str(node_lts), '--version'], text=True, env=env).strip(),
          'nodeBinary': str(node_lts),
          'productionModule': 'server/dist/server.js',
          'fingerprintBoundary': 'Compiled production JS/maps + production source including emitted operator scripts + migrations/ops/config/lock + four active QA files; excludes tests.',
          'sourceRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
          'dirtySource': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT)),
          'coResidentLimitation': 'Shared Mac Mini with normal services and native QA simulator; no production service altered.'}
server = traffic = None
owned_ops = None
harness_only = args.quick or args.calibrate
samples = []
initial_source = source_snapshot()
(output / 'source-files.json').write_text(json.dumps(initial_source, indent=2) + '\n')
exit_code = 1
def interrupted(signum, _frame):
    raise SystemExit(128 + signum)

prior_sigterm = signal.signal(signal.SIGTERM, interrupted)
try:
    assert psql("select count(*) from pg_database where datname = :'qa_name';") == '0'
    ledger['postgresVersion'] = psql('show server_version;')
    ledger['hardware'] = subprocess.check_output(['sysctl', '-n', 'hw.memsize', 'hw.logicalcpu'], text=True, env=env).splitlines()
    owned_ops = Path(tempfile.mkdtemp(prefix=name + '_ops_')).resolve()
    env['PREVIOUSLY_OPS_ROOT'] = str(owned_ops)
    ledger['ownedOpsRoot'] = str(owned_ops)
    ledger['ownedOpsRemoved'] = False
    with (output / 'ledger-bootstrap.log').open('w') as log:
        subprocess.run(['node', '--input-type=module', '-e',
                        "import { persistDeletionRecords } from './ops/ledger.mjs'; await persistDeletionRecords([])"],
                       cwd=ROOT / 'server', env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=20)
    ledger['hostMemoryBefore'] = subprocess.check_output(['sysctl', 'vm.swapusage'], text=True, env=env, timeout=5).strip()
    ledger['databaseCreationAttempted'] = True
    subprocess.run(['createdb', '-h', '127.0.0.1', name], check=True, env=env, timeout=20)
    ledger['databaseCreated'] = True
    with (output / 'migrations.log').open('w') as log:
        subprocess.run(['npm', 'run', 'db:migrate'], cwd=ROOT / 'server', env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    with (output / 'server.log').open('w') as server_log, (output / 'traffic.log').open('w') as traffic_log:
        server = subprocess.Popen([str(ROOT / 'server/node_modules/.bin/tsx'), 'qa/load-server.ts'],
                                  cwd=ROOT / 'server', env=env, stdout=server_log,
                                  stderr=subprocess.STDOUT, start_new_session=True)
        ledger['ownedServerPID'] = server.pid
        deadline = time.monotonic() + 120
        while not (output / 'ready.json').exists():
            if server.poll() is not None:
                raise RuntimeError(f'QA server exited {server.returncode}; see server.log')
            if time.monotonic() > deadline:
                raise TimeoutError('QA server did not become ready within 120 seconds')
            time.sleep(0.1)
        ready = json.loads((output / 'ready.json').read_text())
        assert ready['dbName'] == name
        assert re.fullmatch(r'http://127\.0\.0\.1:[0-9]+', ready['baseURL'])
        ledger['baseURL'] = ready['baseURL']
        traffic = subprocess.Popen([str(ROOT / 'server/node_modules/.bin/tsx'), 'qa/load-traffic.ts'],
                                   cwd=ROOT / 'server', env=env, stdout=traffic_log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        ledger['ownedTrafficPID'] = traffic.pid
        print(json.dumps({'running': True, 'output': str(output), 'quick': args.quick}), flush=True)
        deadline = time.monotonic() + (180 if args.quick else 600 if args.calibrate else 1600)
        next_sample = 0
        while traffic.poll() is None:
            now = time.monotonic()
            if now >= next_sample:
                samples.append(resource_sample())
                (output / 'host-resource-samples.json').write_text(json.dumps(samples, indent=2) + '\n')
                next_sample = now + 15
            if now > deadline:
                raise TimeoutError('Traffic run exceeded bounded deadline')
            time.sleep(0.5)
        ledger['testExitCode'] = traffic.returncode
        exit_code = traffic.returncode
except BaseException as error:
    ledger['runError'] = f'{type(error).__name__}: {error}'
    exit_code = 1
finally:
    # A second termination signal must not interrupt removal of owned resources.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    cleanup_errors = []
    for label, child in (('traffic', traffic), ('server', server)):
        try:
            stop_owned(child)
        except BaseException as error:
            cleanup_errors.append(f'{label}: {type(error).__name__}: {error}')
            exit_code = 1
    try:
        resources_path = output / 'server-resources.json'
        if resources_path.exists():
            memory = review_memory(json.loads(resources_path.read_text()))
            (output / 'memory-review.json').write_text(json.dumps(memory, indent=2) + '\n')
            ledger['memoryReviewPassed'] = memory['passed']
            if not harness_only and not memory['passed']:
                exit_code = 1
        elif not harness_only:
            raise RuntimeError('Full capacity qualification requires server resource evidence')
    except BaseException as error:
        ledger['resourceEvidenceError'] = f'{type(error).__name__}: {error}'
        ledger['memoryReviewPassed'] = False
        exit_code = 1
    # Evidence parsing and child-stop failures must never skip database cleanup.
    try:
        if ledger['databaseCreated'] or ledger.get('databaseCreationAttempted'):
            exists = psql("select count(*) from pg_database where datname = :'qa_name';") == '1'
            if not exists:
                ledger['databaseRemoved'] = True
            else:
                drain_deadline = time.monotonic() + 5
                count = psql("select count(*) from pg_stat_activity where datname = :'qa_name';")
                while count != '0' and time.monotonic() < drain_deadline:
                    time.sleep(0.1)
                    count = psql("select count(*) from pg_stat_activity where datname = :'qa_name';")
                ledger['scratchConnectionsBeforeDrop'] = int(count)
                if count != '0':
                    raise RuntimeError(f'Refusing drop: scratch has {count} connection(s) after bounded natural drain')
                subprocess.run(['dropdb', '-h', '127.0.0.1', name], check=True, env=env, timeout=20)
                ledger['databaseRemoved'] = psql("select count(*) from pg_database where datname = :'qa_name';") == '0'
                if not ledger['databaseRemoved']:
                    raise RuntimeError('Owned scratch database still exists after drop')
    except BaseException as error:
        cleanup_errors.append(f'database: {type(error).__name__}: {error}')
        exit_code = 1
    try:
        if owned_ops is not None:
            try:
                journal = owned_ops / 'deletions/current.json'
                if journal.is_file():
                    # No real identity ever enters the owned scratch ledger; preserve exact receipt.
                    (output / 'independent-ledger-final.json').write_bytes(journal.read_bytes())
                elif not harness_only:
                    raise RuntimeError('Full qualification requires independent journal evidence')
            finally:
                assert owned_ops.name.startswith(name + '_ops_') and not owned_ops.is_symlink()
                shutil.rmtree(owned_ops)
                ledger['ownedOpsRemoved'] = not owned_ops.exists()
        ledger['hostMemoryAfter'] = subprocess.check_output(['sysctl', 'vm.swapusage'], text=True, env=env, timeout=5).strip()
    except BaseException as error:
        cleanup_errors.append(f'owned journal: {type(error).__name__}: {error}')
        exit_code = 1
    try:
        final_source = source_snapshot()
        changed = sorted(k for k in initial_source.keys() | final_source.keys() if initial_source.get(k) != final_source.get(k))
        ledger['sourceChangedDuringRun'] = changed
        if changed and not harness_only:
            exit_code = 1
    except BaseException as error:
        ledger['sourceEvidenceError'] = f'{type(error).__name__}: {error}'
        exit_code = 1
    if cleanup_errors:
        ledger['cleanupErrors'] = cleanup_errors
    ledger['overallExitCode'] = exit_code
    ledger['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (output / 'run-ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
    signal.signal(signal.SIGTERM, prior_sigterm)
print(json.dumps({'output': str(output), **ledger}), flush=True)
raise SystemExit(exit_code)
