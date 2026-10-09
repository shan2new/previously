"""Qualify consumer content policy against a freshly owned loopback scratch database.

No target or database option exists. Uses the already-built production artifact;
never builds, installs dependencies, reads .env, or contacts real providers.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
output = (args.output or ROOT / 'docs/qa/2026-10-06/content-policy' / (stamp + '-' + uuid.uuid4().hex[:8])).resolve()
output.mkdir(parents=True, exist_ok=False)
os.chmod(output, 0o700)
name = 'previously_qa_content_' + uuid.uuid4().hex
assert re.fullmatch(r'previously_qa_content_[a-f0-9]{32}', name)
node = Path('/opt/homebrew/opt/node@24/bin/node')
assert node.is_file(), 'Installed Node 24 is required; no runtime installation is attempted'
env = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'LANG') if k in os.environ}
env['PATH'] = str(node.parent) + ':' + env.get('PATH', '')
env.update(DATABASE_URL=f'postgres://127.0.0.1:5432/{name}', DOTENV_CONFIG_PATH='/dev/null',
           APP_ENV='test', DEV_AUTH_BYPASS='1', CLERK_SECRET_KEY='', CLERK_JWT_KEY='',
           OPENROUTER_API_KEY='', CEREBRAS_API_KEY='', TMDB_ACCESS_TOKEN='', ANTHROPIC_API_KEY='',
           NEWS_AGENT_DISABLED='1', NEWS_CODEX_FALLBACK_ENABLED='0', GROUPING_LLM_DISABLED='1',
           SEARCH_CORRECT_DISABLED='1', SOCIAL_COMMENTS_ENABLED='0', MODERATION_ALERT_WEBHOOK_URL='',
           OBSERVABILITY_TOKEN=secrets.token_urlsafe(32),
           PREVIOUSLY_QA_RESULTS=str(output / 'results.json'))

def admin(query):
    return subprocess.run(['psql', '-h', '127.0.0.1', '-d', 'postgres', '-X', '-At',
                           '-v', 'ON_ERROR_STOP=1', '-v', f'qa_name={name}'], input=query,
                          text=True, capture_output=True, check=True, env=env, timeout=10).stdout.strip()

def fingerprint():
    for path in ('server/dist/server.js', 'server/dist/db/index.js', 'server/dist/services/consumerContent.js'):
        assert (ROOT / path).is_file(), 'Build the policy release artifact before invoking QA'
    paths = set()
    for directory in ('server/dist', 'server/ops', 'server/drizzle'):
        paths.update(p for p in (ROOT / directory).rglob('*') if p.is_file()
                     and p.suffix in ('.js', '.map', '.mjs', '.mts', '.json', '.sql'))
    paths.update(p for p in (ROOT / 'server/src').rglob('*.ts') if not p.name.endswith('.test.ts'))
    paths.update(ROOT / p for p in ('server/package.json', 'server/package-lock.json',
                                   'server/qa/content-policy.ts', 'server/qa/run-content-policy.py'))
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}

ledger = {'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'database': name, 'databaseCreated': False, 'databaseRemoved': False,
          'host': '127.0.0.1', 'productionDatabaseReadOrWritten': False, 'dotenvLoaded': False,
          'credentialsInherited': False, 'productionModule': 'server/dist/server.js',
          'transport': 'Fastify inject through production routes/auth; real disposable PostgreSQL',
          'nodeBinary': str(node), 'nodeVersion': subprocess.check_output([str(node), '--version'], env=env, text=True).strip()}
owned_ops = None
child = None
initial = None
exit_code = 1

def interrupt(signum, _frame):
    raise SystemExit(128 + signum)

prior = signal.signal(signal.SIGTERM, interrupt)
try:
    initial = fingerprint()
    (output / 'source-files.json').write_text(json.dumps(initial, indent=2) + '\n')
    assert admin("select count(*) from pg_database where datname = :'qa_name';") == '0'
    owned_ops = Path(tempfile.mkdtemp(prefix=name + '_ops_')).resolve()
    env['PREVIOUSLY_OPS_ROOT'] = str(owned_ops)
    ledger['ownedOpsRoot'] = str(owned_ops)
    with (output / 'ledger-bootstrap.log').open('w') as log:
        subprocess.run([str(node), '--input-type=module', '-e',
                        "import { persistDeletionRecords } from './ops/ledger.mjs'; await persistDeletionRecords([])"],
                       cwd=ROOT / 'server', env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=20)
    subprocess.run(['createdb', '-h', '127.0.0.1', name], env=env, check=True, timeout=20)
    ledger['databaseCreated'] = True
    with (output / 'migrations.log').open('w') as log:
        subprocess.run(['npm', 'run', 'db:migrate'], cwd=ROOT / 'server', env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    with (output / 'run.log').open('w') as log:
        child = subprocess.Popen([str(ROOT / 'server/node_modules/.bin/tsx'), 'qa/content-policy.ts'],
                                 cwd=ROOT / 'server', env=env, stdout=log, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        ledger['ownedHarnessPID'] = child.pid
        exit_code = child.wait(timeout=150)
        ledger['testExitCode'] = exit_code
    results = json.loads((output / 'results.json').read_text())
    assert results['passed'] is True and len(results['cases']) >= 18, 'Missing or insufficient policy evidence'
except BaseException as error:
    ledger['runError'] = f'{type(error).__name__}: {error}'
    exit_code = 1
finally:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    cleanup = []
    # Independent cleanup blocks ensure malformed evidence cannot prevent owned-resource removal.
    if child is not None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=5)
    try:
        if ledger['databaseCreated']:
            assert re.fullmatch(r'previously_qa_content_[a-f0-9]{32}', name)
            deadline = time.monotonic() + 8
            count = admin("select count(*) from pg_stat_activity where datname = :'qa_name';")
            while count != '0' and time.monotonic() < deadline:
                time.sleep(.1)
                count = admin("select count(*) from pg_stat_activity where datname = :'qa_name';")
            ledger['scratchConnectionsBeforeDrop'] = int(count)
            if count != '0':
                raise RuntimeError(f'Refusing drop: owned scratch still has {count} connections')
            subprocess.run(['dropdb', '-h', '127.0.0.1', name], env=env, check=True, timeout=20)
            ledger['databaseRemoved'] = admin("select count(*) from pg_database where datname = :'qa_name';") == '0'
            assert ledger['databaseRemoved'], 'Scratch database removal not verified'
    except BaseException as error:
        cleanup.append(f'database: {type(error).__name__}: {error}')
    try:
        if owned_ops is not None:
            assert owned_ops.name.startswith(name + '_ops_') and not owned_ops.is_symlink()
            shutil.rmtree(owned_ops)
            ledger['ownedOpsRemoved'] = not owned_ops.exists()
    except BaseException as error:
        cleanup.append(f'journal: {type(error).__name__}: {error}')
    try:
        if initial is not None:
            final = fingerprint()
            ledger['sourceChangedDuringRun'] = sorted(k for k in initial.keys() | final.keys() if initial.get(k) != final.get(k))
            if ledger['sourceChangedDuringRun']:
                exit_code = 1
    except BaseException as error:
        ledger['sourceEvidenceError'] = f'{type(error).__name__}: {error}'
        exit_code = 1
    if cleanup:
        ledger['cleanupErrors'] = cleanup
        exit_code = 1
    ledger['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    ledger['overallExitCode'] = exit_code
    (output / 'run-ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
    signal.signal(signal.SIGTERM, prior)
print(json.dumps({'output': str(output), **ledger}), flush=True)
raise SystemExit(exit_code)
