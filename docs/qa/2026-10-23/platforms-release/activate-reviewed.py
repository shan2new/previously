"""Execute the reviewed Previously artifact activation (23 Oct night: every streaming platform, split by origin).

The evening's helper (../drops-release/activate-reviewed.py) with this release's paths and pinned
hashes: same hash-guarded stop/replace/bootstrap and rollback. Qualification: 1,372 unit tests,
typecheck, compiled smoke on scratch, production audit 0. Migration 0018 (media.origin_countries, a
nullable column) was applied before this runs, from the new artifact, after a verified backup.

The transaction performs no manual production account/report writes, migrations,
credential edits or live-database restore. Normal service workers resume after boot.
All three launchd pointers are hash guarded and restored on any post-stop failure.
"""
from pathlib import Path
import datetime
import hashlib
import json
import os
import re
import stat
import subprocess
import time
import urllib.request

BASE = Path(__file__).resolve().parent
HOME = Path('/Users/shan2new')
NODE = '/opt/homebrew/opt/node@24/bin/node'
OPS = HOME / 'Infra/previously'
CANDIDATE = OPS / 'install-candidates/20261023T163910Z'
OLD = OPS / 'releases/20261023T160259Z/server'
NEW = OPS / 'releases/20261023T163910Z/server'
LIVE = HOME / 'Library/LaunchAgents'
LABELS = ['com.shan.previously', 'com.shan.previously.backup', 'com.shan.previously.ops']
DOMAIN = 'gui/' + str(os.getuid())
EXPECTED = '7418cf2909cb1a54179bc8c05d59579c6a286bc070cf4d1588cda07a98d34c12'
ENV = {k: os.environ[k] for k in ['HOME', 'LANG', 'TMPDIR'] if k in os.environ}
ENV.update(PATH='/opt/homebrew/opt/node@24/bin:/opt/homebrew/bin:/usr/bin:/bin',
           PREVIOUSLY_ENV_FILE=str(HOME / '.config/previously/release/production.env'),
           PREVIOUSLY_OPS_ROOT=str(OPS), NODE_ENV='production', APP_ENV='production',
           DOTENV_CONFIG_PATH='/dev/null')
receipt = {'startedAt': None, 'activated': False, 'rollbackPerformed': False,
           'applicationDataManuallyWritten': False, 'productionRestorePerformed': False,
           'configurationChanged': False, 'schemaChanged': False}

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def save():
    temp = BASE / 'activation-receipt.pending.json'
    temp.write_text(json.dumps(receipt, indent=2) + '\n')
    temp.replace(BASE / 'activation-receipt.json')

def digest(path):
    assert path.is_file() and not path.is_symlink(), 'unsafe activation file'
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(args, timeout=60, check=True):
    # launchctl belongs to the logged-in operator's bootstrap context. Do not strip
    # its inherited macOS session environment or change any launchd job environment.
    # Node/PG helpers retain the private, explicitly scoped production environment.
    result = subprocess.run(args, env=None if Path(args[0]).name == 'launchctl' else ENV,
                            text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError('reviewed operational command failed: ' + Path(args[0]).name)
    return result

def node(code, timeout=120):
    result = run([NODE, '--input-type=module', '-e', code], timeout)
    return json.loads(result.stdout.strip().splitlines()[-1])

def state(label):
    result = run(['launchctl', 'print', DOMAIN + '/' + label], check=False)
    if result.returncode:
        return {'loaded': False}
    result_state = {'loaded': True}
    for key, pattern in [('state', r'^\s*state = (.+)$'), ('pid', r'^\s*pid = (\d+)$'),
                         ('runs', r'^\s*runs = (\d+)$'), ('lastExitCode', r'^\s*last exit code = (-?\d+)$')]:
        found = re.search(pattern, result.stdout, re.M)
        if found:
            result_state[key] = found.group(1) if key == 'state' else int(found.group(1))
    return result_state

def wait_until(predicate, timeout, message):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(1)
    raise RuntimeError(message)

def ready(url):
    try:
        # Match the installed Node collector's anonymous probe. Cloudflare rejects the
        # default Python user agent, which would otherwise cause a false rollback.
        request = urllib.request.Request(url, headers={'Cache-Control': 'no-cache', 'User-Agent':'node'})
        with urllib.request.urlopen(request, timeout=3) as response:
            return response.status == 200 and json.loads(response.read(1024)).get('ok') is True
    except Exception:
        return False

def replace_plist(source, destination):
    temp = destination.with_name(destination.name + '.previously-activation-pending')
    with temp.open('xb') as stream:
        os.chmod(temp, 0o600)
        stream.write(source.read_bytes())
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, destination)
    descriptor = os.open(destination.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

def stop_all():
    for label in reversed(LABELS):
        prior = state(label)
        if prior['loaded']:
            # Respect the reviewed per-job launchd drain budgets, including pg_dump.
            budget = 375 if label.endswith('.backup') else 60 if label.endswith('.ops') else 55
            run(['launchctl', 'bootout', DOMAIN + '/' + label],
                timeout=budget)
            # bootout can return before the running wrapper receives SIGTERM. Wait
            # for the exact captured PID and service registration to disappear.
            wait_until(lambda: not state(label)['loaded']
                       and (not prior.get('pid') or not pid_alive(prior['pid'])),
                       budget, 'reviewed job did not finish unloading')

def pid_alive(pid):
    try:
        os.kill(pid, 0)  # Existence probe only; never terminates another process.
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

def bootstrap(label, expected_hash):
    path = LIVE / (label + '.plist')
    def attempt():
        if digest(path) != expected_hash:
            raise RuntimeError('external plist conflict during bootstrap')
        if state(label)['loaded']:
            raise RuntimeError('job unexpectedly registered before bootstrap')
        result = run(['launchctl', 'bootstrap', DOMAIN, str(path)], check=False)
        if result.returncode == 0:
            return True
        # Own command, known plist only: preserve safe launchctl diagnostics without
        # printing environment, Node stderr, credentials or arbitrary process argv.
        receipt.setdefault('bootstrapAttempts', []).append({'at':now(), 'label':label,
            'returnCode':result.returncode, 'stderr':result.stderr[:600]})
        if result.returncode not in (5, 36):
            raise RuntimeError('permanent reviewed job bootstrap failure')
        return False
    wait_until(attempt, 45, 'reviewed job bootstrap failed')

def instant(value):
    parsed = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('operational timestamp has no timezone')
    return parsed.timestamp()

def fresh_backup_since(after):
    rows = [json.loads(p.read_text()) for p in (OPS / 'backups').glob('previously-*.manifest.json')]
    latest = max(rows, key=lambda row: instant(row['createdAt']), default=None)
    return latest if latest and instant(latest['createdAt']) > instant(after) else None

def verify_backup(row):
    if not re.fullmatch(r'previously-\d{8}T\d{9}Z-[a-f0-9]{12}\.dump', row.get('file', '')):
        raise ValueError('new backup file name is invalid')
    path = OPS / 'backups' / row['file']
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
        raise ValueError('new backup file is not private and owned')
    if type(row.get('bytes')) is not int or info.st_size != row['bytes']:
        raise ValueError('new backup size differs from its manifest')
    if not re.fullmatch(r'[a-f0-9]{64}', row.get('sha256', '')) or digest(path) != row['sha256']:
        raise ValueError('new backup checksum differs from its manifest')
    return {'file':row['file'], 'bytes':info.st_size, 'sha256':row['sha256'],
            'mode':'0600', 'ownerVerified':True, 'verifiedAt':now()}

def fresh_status_since(after):
    try:
        row = json.loads((OPS / 'status.json').read_text())
    except FileNotFoundError:
        return None
    return row if row.get('healthy') is True and instant(row['measuredAt']) > instant(after) else None

def start_dependents(after, expected_files, prefix=''):
    bootstrap(LABELS[1], expected_files[LABELS[1]+'.plist'])
    run(['launchctl', 'kickstart', DOMAIN + '/' + LABELS[1]])
    wait_until(lambda: fresh_backup_since(after) and state(LABELS[1]).get('state') != 'running'
               and state(LABELS[1]).get('lastExitCode') == 0, 100, 'new backup job failed')
    backup = fresh_backup_since(after)
    verification = verify_backup(backup)
    receipt[prefix + 'Backup'] = backup
    receipt[prefix + 'BackupVerification'] = verification
    collector_start = now()
    bootstrap(LABELS[2], expected_files[LABELS[2]+'.plist'])
    wait_until(lambda: fresh_status_since(collector_start)
               and state(LABELS[2]).get('state') != 'running'
               and state(LABELS[2]).get('lastExitCode') == 0, 60, 'new operational snapshot failed')
    receipt[prefix + 'OperationalSnapshot'] = fresh_status_since(collector_start)
    receipt[prefix + 'CollectorStartedAt'] = collector_start

def activate():
    global receipt
    receipt['startedAt'] = now()
    stopped = False
    try:
        manifest = json.loads((BASE / 'artifact/artifact-manifest.json').read_text())
        assert manifest['artifact'] == str(NEW) and manifest['sourceSHA256'] == EXPECTED
        assert hashlib.sha256(json.dumps(manifest['files'],sort_keys=True,separators=(',',':')).encode()).hexdigest() == EXPECTED
        assert all(digest(NEW / name) == value for name, value in manifest['files'].items())
        candidate = json.loads((CANDIDATE / 'candidate-manifest.json').read_text())
        reviewed = {
            'com.shan.previously.plist':'da6c239f665eb9b900a8c598a683896e8194b521238b3af3fab40b358307783e',
            'com.shan.previously.backup.plist':'0e76af3750fc52ca7dac8fec9ec1333a10580f15423fa622685263c21addbc5f',
            'com.shan.previously.ops.plist':'3958b7730541ae4367c7a8af899ba1a947437cb5cf306818f6c88792dd69651f',
            'rollback/com.shan.previously.plist':'9d2807eaacab18bcd1033b5bad7081fc75754b13c0f21bd454491d66640d465a',
            'rollback/com.shan.previously.backup.plist':'79112f893730554901df3b036873ccc0a48fd6dd0a0b6ccd53f9f6121086efff',
            'rollback/com.shan.previously.ops.plist':'884a5bd5b2e2c7f39008422a4764f111c0f7bb397cdae0a142ffa0e621f9e885',
        }
        assert candidate['files'] == reviewed
        assert all(digest(CANDIDATE / name) == value for name, value in candidate['files'].items())
        assert all(digest(LIVE / (label + '.plist')) == candidate['files']['rollback/' + label + '.plist'] for label in LABELS)
        assert all(state(label)['loaded'] for label in LABELS)
        receipt.update(artifact=str(NEW), sourceSHA256=EXPECTED, qualification='unit 1372/1372, typecheck, compiled smoke (scratch), production audit 0, migration 0018 applied',
                       candidateDirectory=str(CANDIDATE), previousArtifact=str(OLD), artifactFilesVerified=len(manifest['files']))
        save()
        # pg_dump is read-only. The restore helper only creates/drops its own uniquely named DB.
        backup = node(f"""
          import {{ join }} from 'node:path';
          import {{ performance }} from 'node:perf_hooks';
          const root={json.dumps(str(OLD))};
          const {{backupDatabase}}=await import(root+'/ops/backup.mjs');
          const {{restoreCheck}}=await import(root+'/ops/restore-check.mjs');
          const {{opsRoot,config}}=await import(root+'/ops/common.mjs');
          const m=await backupDatabase();
          const path=join(opsRoot(),'backups',m.file.replace(/\\.dump$/,'.manifest.json'));
          const began=performance.now(); const restore=await restoreCheck(path);
          const values=await config();
          const {{default:postgres}}=await import(root+'/node_modules/postgres/src/index.js');
          const u=new URL(values.DATABASE_URL);u.pathname='/postgres';
          const sql=postgres(u.toString(),{{max:1,connect_timeout:10}});
          const rows=await sql`select count(*)::int as count from pg_database where datname=${{restore.scratch}}`;
          await sql.end({{timeout:5}});
          if(rows[0].count!==0)throw new Error('restore scratch retained');
          console.log(JSON.stringify({{createdAt:m.createdAt,manifestPath:path,bytes:m.bytes,sha256:m.sha256,
            tocEntries:m.tocEntries,restore,restoreElapsedSeconds:(performance.now()-began)/1000,scratchRemoved:true}}));
        """, timeout=360)
        receipt['preactivationBackupRestore'] = backup
        save()
        # Recheck after backup/restore, immediately before touching the three reviewed jobs.
        assert all(digest(LIVE / (label + '.plist')) == candidate['files']['rollback/' + label + '.plist'] for label in LABELS)
        stopped = True
        stop_all()
        receipt['oldJobsStoppedAt'] = now()
        for label in LABELS:
            assert digest(LIVE / (label + '.plist')) == candidate['files']['rollback/' + label + '.plist']
            replace_plist(CANDIDATE / (label + '.plist'), LIVE / (label + '.plist'))
        receipt['installedAt'] = now()
        bootstrap(LABELS[0], candidate['files'][LABELS[0]+'.plist'])
        wait_until(lambda: ready('http://127.0.0.1:8787/ready'), 45, 'new local readiness failed')
        wait_until(lambda: ready('https://anime.cognipin.com/ready'), 45, 'new public readiness failed')
        start_dependents(receipt['installedAt'], candidate['files'], prefix='new')
        # Read-only aggregate probes: no user endpoints, provider calls, report changes, or backfill.
        receipt['postActivationProof'] = node(f"""
          const root={json.dumps(str(NEW))};
          const {{config,sourceFingerprint}}=await import(root+'/ops/common.mjs');
          const values=await config();Object.assign(process.env,values);
          const {{env}}=await import(root+'/dist/env.js');
          const {{staleOpenReports}}=await import(root+'/dist/services/moderation.js');
          const {{sql}}=await import(root+'/dist/db/index.js');
          let reports;try{{reports=await staleOpenReports(new Date(Date.now()-12*3600000));}}
          finally{{await sql.end({{timeout:5}});}}
          const headers={{Authorization:'Bearer '+values.OBSERVABILITY_TOKEN}};
          const metricsResponse=await fetch('http://127.0.0.1:8787/internal/metrics',{{headers,signal:AbortSignal.timeout(8000)}});
          const usageResponse=await fetch('http://127.0.0.1:8787/internal/usage',{{headers,signal:AbortSignal.timeout(8000)}});
          if(metricsResponse.status!==200||usageResponse.status!==200)throw new Error('private observability unavailable');
          const metrics=await metricsResponse.json();const usage=await usageResponse.json();
          const anonMetrics=await fetch('http://127.0.0.1:8787/internal/metrics',{{signal:AbortSignal.timeout(8000)}});
          const anonUsage=await fetch('http://127.0.0.1:8787/internal/usage',{{signal:AbortSignal.timeout(8000)}});
          if(anonMetrics.status!==404||anonUsage.status!==404||env.SOCIAL_COMMENTS_ENABLED)throw new Error('privacy policy changed');
          console.log(JSON.stringify({{measuredAt:new Date().toISOString(),reportsAggregate:reports,commentsEnabled:false,
            metrics,usage,anonymousMetricsStatus:anonMetrics.status,anonymousUsageStatus:anonUsage.status,
            sourceFingerprint:(await sourceFingerprint()).sha256}}));
        """, timeout=40)
        proof = receipt['postActivationProof']
        assert receipt['newBackup']['sourceFingerprint'] == proof['sourceFingerprint']
        assert proof['metrics']['startedAt'] >= datetime.datetime.fromisoformat(receipt['installedAt']).timestamp()*1000
        assert all(digest(LIVE / (label + '.plist')) == candidate['files'][label + '.plist'] for label in LABELS)
        receipt['jobStates'] = {label: state(label) for label in LABELS}
        assert receipt['jobStates'][LABELS[0]].get('state') == 'running'
        receipt.update(activated=True, finishedAt=now(), localReady=True, publicReady=True)
        save()
        print(json.dumps({'activated':True,'receipt':str(BASE/'activation-receipt.json'),'artifact':str(NEW)}))
    except BaseException as error:
        receipt['failureClass'] = type(error).__name__
        receipt['failedAt'] = now()
        if stopped:
            try:
                stop_all()
                for label in LABELS:
                    name = label + '.plist'
                    assert digest(LIVE / name) in [candidate['files'][name], candidate['files']['rollback/' + name]], 'external plist conflict'
                    replace_plist(CANDIDATE / 'rollback' / name, LIVE / name)
                receipt['rollbackPointersRestored'] = True
                receipt['rollbackStartedAt'] = now()
                old_files = {label+'.plist':candidate['files']['rollback/'+label+'.plist'] for label in LABELS}
                bootstrap(LABELS[0], old_files[LABELS[0]+'.plist'])
                wait_until(lambda: ready('http://127.0.0.1:8787/ready') and ready('https://anime.cognipin.com/ready'),45,'rollback readiness failed')
                start_dependents(receipt['rollbackStartedAt'], old_files, prefix='rollback')
                receipt.update(rollbackPerformed=True, rollbackReady=True, rollbackAt=now())
            except BaseException as rollback_error:
                receipt['rollbackFailureClass'] = type(rollback_error).__name__
        save()
        print(json.dumps({'activated':False,'failureClass':receipt['failureClass'],
                          'rollbackPerformed':receipt['rollbackPerformed'],'receipt':str(BASE/'activation-receipt.json')}))
        raise SystemExit(1)

if __name__ == '__main__':
    activate()
