"""Run real-route deletion QA against a database created and removed by this invocation.

Never accepts a target URL or database name. No .env file is loaded. The PostgreSQL
admin connection is used only to create/check/drop a uniquely owned scratch database.
"""
from pathlib import Path
import argparse
import datetime
import json
import os
import re
import signal
import subprocess
import time
import uuid

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
output = (args.output or root / 'docs/qa/2026-10-06/deletion-faults' / (stamp + '-' + uuid.uuid4().hex[:8])).resolve()
output.mkdir(parents=True, exist_ok=False)
os.chmod(output, 0o700)
name = 'previously_qa_deletion_' + uuid.uuid4().hex
assert re.fullmatch(r'previously_qa_deletion_[a-f0-9]{32}', name)

# Start from a small allowlist rather than inheriting provider credentials or DATABASE_URL.
env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'LANG') if key in os.environ}
node_lts = Path('/opt/homebrew/opt/node@24/bin/node')
if not node_lts.is_file():
    raise RuntimeError('The qualified Node24 runtime is required')
env['PATH'] = str(node_lts.parent) + os.pathsep + env.get('PATH', '')
runtime_version = subprocess.check_output([str(node_lts), '--version'], env=env, text=True).strip()
if not runtime_version.startswith('v24.'):
    raise RuntimeError('Expected Node24 LTS')
env.update(
    DATABASE_URL=f'postgres://127.0.0.1:5432/{name}',
    DOTENV_CONFIG_PATH='/dev/null',
    APP_ENV='test', DEV_AUTH_BYPASS='1',
    CLERK_SECRET_KEY='', CLERK_JWT_KEY='', OPENROUTER_API_KEY='', CEREBRAS_API_KEY='',
    TMDB_ACCESS_TOKEN='', ANTHROPIC_API_KEY='', NEWS_AGENT_DISABLED='1',
    NEWS_CODEX_FALLBACK_ENABLED='0', GROUPING_LLM_DISABLED='1', SEARCH_CORRECT_DISABLED='1',
    SOCIAL_COMMENTS_ENABLED='0', MODERATION_ALERT_WEBHOOK_URL='',
    PREVIOUSLY_QA_RESULTS=str(output / 'results.json'),
)

def psql(query):
    return subprocess.run(
        ['psql', '-h', '127.0.0.1', '-d', 'postgres', '-X', '-At', '-v', 'ON_ERROR_STOP=1',
         '-v', f'qa_name={name}'],
        input=query, text=True, capture_output=True, check=True, env=env,
    ).stdout.strip()

assert psql("select count(*) from pg_database where datname = :'qa_name';") == '0'
ledger = {
    'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'database': name, 'host': '127.0.0.1', 'databaseCreated': False, 'databaseRemoved': False,
    'productionDatabaseReadOrWritten': False, 'dotenvLoaded': False,
    'nodeBinary': str(node_lts), 'nodeVersion': runtime_version,
    'independentFilesystemLedgerEnabled': False,
    'sourceRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
}
exit_code = 1
def interrupted(signum, _frame):
    raise SystemExit(128 + signum)

prior_sigterm = signal.signal(signal.SIGTERM, interrupted)
try:
    subprocess.run(['createdb', '-h', '127.0.0.1', name], check=True, env=env)
    ledger['databaseCreated'] = True
    with (output / 'migrations.log').open('w') as log:
        subprocess.run(['npm', 'run', 'db:migrate'], cwd=root / 'server', env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    with (output / 'run.log').open('w') as log:
        result = subprocess.run(
            [str(node_lts), '--import', 'tsx', str(root / 'server/qa/deletion-faults.ts')],
            cwd=root / 'server', env=env, stdout=log, stderr=subprocess.STDOUT, timeout=90,
        )
        exit_code = result.returncode
    ledger['testExitCode'] = exit_code
except BaseException as error:
    ledger['runError'] = f'{type(error).__name__}: {error}'
    exit_code = 1
finally:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    try:
        if ledger['databaseCreated']:
            # Refuse to terminate sessions or drop a database this run has not proved it owns.
            assert re.fullmatch(r'previously_qa_deletion_[a-f0-9]{32}', name)
            connections = psql("select count(*) from pg_stat_activity where datname = :'qa_name';")
            deadline = time.monotonic() + 5
            while connections != '0' and time.monotonic() < deadline:
                # PostgreSQL can observe a closing socket briefly after the child process exits.
                # Wait for natural drain; never terminate another session to force cleanup.
                time.sleep(0.1)
                connections = psql("select count(*) from pg_stat_activity where datname = :'qa_name';")
            if connections != '0':
                raise RuntimeError(f'Refusing drop: scratch database still has {connections} active connection(s)')
            subprocess.run(['dropdb', '-h', '127.0.0.1', name], check=True, env=env)
            ledger['databaseRemoved'] = True
    except BaseException as error:
        ledger['cleanupError'] = f'{type(error).__name__}: {error}'
        exit_code = 1
    finally:
        # A failed cleanup must remain visible, with the owned DB name for manual recovery.
        ledger['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        (output / 'run-ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
        signal.signal(signal.SIGTERM, prior_sigterm)
print(json.dumps(ledger))
raise SystemExit(exit_code)
