"""Prepare a private immutable Previously backend; never install, read live config or start it."""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'server'
NODE = Path('/opt/homebrew/opt/node@24/bin/node')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--evidence', type=Path, required=True)
args = parser.parse_args()
evidence = args.evidence.resolve()
assert evidence.is_relative_to(ROOT / 'docs/qa'), 'Evidence must stay in the dated QA tree'
assert not evidence.exists(), 'Never replace prior qualification evidence'
evidence.mkdir(parents=True, mode=0o700)
stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
release = Path.home() / 'Infra/previously/releases' / stamp
assert not release.exists(), 'Never replace an existing artifact'
artifact = release / 'server'
artifact.mkdir(parents=True, mode=0o700)
for folder in [release, artifact]: folder.chmod(0o700)
env = {key: os.environ[key] for key in ['PATH', 'HOME', 'TMPDIR', 'LANG'] if key in os.environ}
env['PATH'] = str(NODE.parent) + ':' + env.get('PATH', '')
runtime = subprocess.check_output([str(NODE), '--version'], text=True, env=env).strip()
assert runtime.startswith('v24.'), 'Use the installed Node24 LTS only'
assert (SOURCE / 'dist/index.js').is_file(), 'Build the compiled production entry first'

def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()

paths = set()
for folder, suffixes in [('src', {'.ts', '.json'}), ('dist', {'.js', '.map', '.json'}),
                         ('drizzle', {'.sql', '.json'}), ('ops', {'.mjs', '.mts', '.md'})]:
    base = SOURCE / folder
    assert base.is_dir() and not base.is_symlink()
    for path in base.rglob('*'):
        assert not path.is_symlink(), 'Source links must not escape the release whitelist'
        if path.is_file() and path.suffix in suffixes and not path.name.endswith('.test.ts'):
            paths.add(path)
paths.update(SOURCE / name for name in ['package.json', 'package-lock.json'])
files = {str(path.relative_to(SOURCE)): sha(path) for path in sorted(paths)}
assert files and 'dist/index.js' in files and not any('.env' in name for name in files)
for name, digest in files.items():
    source = SOURCE / name; target = artifact / name
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copyfile(source, target)
    target.chmod(0o600)
    assert sha(target) == digest, 'Source changed during artifact capture'
# Dependencies are installed from the reviewed exact lock in the candidate, never the live path.
with (evidence / 'npm-ci.txt').open('w') as log:
    subprocess.run(['npm', 'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund'],
                   cwd=artifact, env=env, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=180)
with (evidence / 'production-audit.json').open('w') as log:
    audit = subprocess.run(['npm', 'audit', '--omit=dev', '--json'], cwd=artifact, env=env,
                           stdout=log, stderr=subprocess.PIPE, timeout=60)
report = json.loads((evidence / 'production-audit.json').read_text())
assert audit.returncode == 0 and report.get('metadata', {}).get('vulnerabilities', {}).get('total') == 0, 'Production dependency audit must be clean'
for tool in ['vitest', 'typescript', 'drizzle-kit', 'tsx']:
    assert not (artifact / 'node_modules' / tool).exists(), 'Development tools must not ship'
assert all(sha(SOURCE / name) == digest and sha(artifact / name) == digest for name, digest in files.items()), 'Artifact/source changed during preparation'
assert not (artifact / '.env').exists(), 'Configuration stays outside the immutable artifact'
# npm may legitimately create package executable links; preserve their targets/execute bits while
# removing writable permissions from every actual file and directory. No live tree is traversed.
for path in artifact.rglob('*'):
    if path.is_file() and not path.is_symlink(): path.chmod(stat.S_IMODE(path.stat().st_mode) & ~0o222)
for path in sorted([p for p in artifact.rglob('*') if p.is_dir() and not p.is_symlink()], key=lambda p: len(p.parts), reverse=True): path.chmod(0o500)
artifact.chmod(0o500)
digest = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
manifest = {'capturedAt': datetime.now(timezone.utc).isoformat(), 'artifact': str(artifact),
            'runtime': runtime, 'runtimeBinary': str(NODE), 'files': files, 'sourceSHA256': digest,
            'sourceRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
            'productionDependenciesOnly': True, 'productionAuditAdvisories': 0,
            'credentialsIncluded': False, 'installScriptsExecuted': False,
            'artifactWritePermissionsRemoved': True, 'installed': False}
output = evidence / 'artifact-manifest.json'
output.write_text(json.dumps(manifest, indent=2) + '\n'); output.chmod(0o600)
print(json.dumps({key:manifest[key] for key in ['artifact','sourceSHA256','runtime','installed']}))
