"""Run real-route progress QA against a database created and removed by this invocation.

Never accepts a target URL or database name. No .env file is loaded. The PostgreSQL
admin connection is used only to create/check/drop a uniquely owned scratch database.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import uuid
import time

root = Path(__file__).resolve().parents[2]

def compiled_snapshot():
    for relative in ('server/dist/server.js', 'server/dist/db/index.js'):
        assert (root / relative).is_file(), 'Build the production release artifact before running real-route QA'
    paths = [p for folder in ('server/dist', 'server/ops') for p in (root / folder).rglob('*')
             if p.is_file() and p.suffix in ('.js', '.map', '.mjs', '.mts', '.json')]
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=root / 'docs/qa/2026-10-06/progress-faults' / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]))
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
initial_compiled = compiled_snapshot()
(output / 'compiled-files.json').write_text(json.dumps(initial_compiled, indent=2) + '\n')
name = 'previously_qa_progress_' + uuid.uuid4().hex
assert re.fullmatch(r'previously_qa_progress_[a-f0-9]{32}', name)

# Start from a small allowlist rather than inheriting provider credentials or DATABASE_URL.
env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'LANG') if key in os.environ}
node_lts = Path('/opt/homebrew/opt/node@24/bin/node')
assert node_lts.is_file(), 'Installed Node24LTS is required; no runtime installation is attempted'
env['PATH'] = str(node_lts.parent) + ':' + env.get('PATH', '')
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
    'nodeVersion': subprocess.check_output([str(node_lts), '--version'], text=True, env=env).strip(),
    'nodeBinary': str(node_lts),
    'productionModule': 'server/dist/server.js', 'credentialsInherited': False,
    'sourceRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
}
exit_code = 1
try:
    subprocess.run(['createdb', '-h', '127.0.0.1', name], check=True, env=env)
    ledger['databaseCreated'] = True
    with (output / 'migrations.log').open('w') as log:
        subprocess.run(['npm', 'run', 'db:migrate'], cwd=root / 'server', env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    with (output / 'run.log').open('w') as log:
        result = subprocess.run(
            [str(root / 'server/node_modules/.bin/tsx'), str(root / 'server/qa/progress-faults.ts')],
            cwd=root / 'server', env=env, stdout=log, stderr=subprocess.STDOUT, timeout=90,
        )
        exit_code = result.returncode
    ledger['testExitCode'] = exit_code
except BaseException as error:
    ledger['runError'] = f'{type(error).__name__}: {error}'
    exit_code = 1
finally:
    try:
        final_compiled = compiled_snapshot()
        ledger['compiledChangedDuringRun'] = sorted(k for k in initial_compiled.keys() | final_compiled.keys()
                                                    if initial_compiled.get(k) != final_compiled.get(k))
        if ledger['compiledChangedDuringRun']:
            exit_code = 1
    except BaseException as error:
        ledger['compiledEvidenceError'] = f'{type(error).__name__}: {error}'
        exit_code = 1
    try:
        if ledger['databaseCreated']:
            # Refuse to terminate sessions or drop a database this run has not proved it owns.
            assert re.fullmatch(r'previously_qa_progress_[a-f0-9]{32}', name)
            connections = psql("select count(*) from pg_stat_activity where datname = :'qa_name';")
            deadline = time.monotonic() + 5
            while connections != '0' and time.monotonic() < deadline:
                time.sleep(0.1)
                connections = psql("select count(*) from pg_stat_activity where datname = :'qa_name';")
            ledger['scratchConnectionsBeforeDrop'] = int(connections)
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
        ledger['overallExitCode'] = exit_code
        (output / 'run-ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
print(json.dumps(ledger))
raise SystemExit(exit_code)
