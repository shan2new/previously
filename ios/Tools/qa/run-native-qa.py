#!/usr/bin/env python3
"""Own a loopback fixture and run native QA through XcodeBuildMCP, without paid services."""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
DEFAULT_SEEDS = [20261006, 60102620, 38654705664]
CLI_PACKAGE = 'xcodebuildmcp@2.7.0'  # Verified installed CLI and structured test-case schema.
DIRECTED_SUITES = [
    'PreviouslyUITests/QAHarnessTests',
    'PreviouslyUITests/AccountLocalStoreTests',
    'PreviouslyUITests/AccountDeletionRequestTests',
    'PreviouslyUITests/ImportModelTests',
    'PreviouslyUITests/MutationJournalTests',
    'PreviouslyUITests/RewatchStoreTests',
    'PreviouslyUITests/PreviouslyDirectedTests',
    'PreviouslyUITests/PreviouslyDeletionTests',
    'PreviouslyUITests/PreviouslyAccountIsolationTests',
    'PreviouslyUITests/PreviouslyDurabilityTests',
]


def source_fingerprint(root=ROOT):
    paths = [path for directory in ['ios/Sources', 'ios/UITests']
             for path in (root / directory).rglob('*') if path.is_file()]
    paths.extend(root / name for name in ['ios/project.yml', 'ios/Tools/qa/fixture-server.mjs'])
    manifest = root / 'ios/Resources/PrivacyInfo.xcprivacy'
    if manifest.is_file():
        paths.append(manifest)
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(root)).encode() + b'\0')
        digest.update(path.read_bytes() + b'\0')
    return {'sha256': digest.hexdigest(), 'fileCount': len(paths)}


def coverage_summaries(body):
    """Read only compact coverage lines from this tool's saved log, never copy raw log contents."""
    try:
        result = json.loads(body)
        log = Path(result['data']['artifacts']['buildLogPath']).expanduser()
        lines = log.read_text().splitlines()
    except (ValueError, KeyError, TypeError, OSError):
        return []
    summaries = []
    fields = ['version', 'caseName', 'seed', 'durationSeconds', 'completedActions',
              'unavailableActions', 'assertions', 'states']
    for line in lines:
        if not line.startswith('QA_SUMMARY '):
            continue
        try:
            summary = json.loads(line.removeprefix('QA_SUMMARY '))
            if any(type(summary[key]) is not int or summary[key] < 0
                   for key in ['version', 'seed', 'completedActions', 'unavailableActions', 'assertions']):
                continue
            if not isinstance(summary['caseName'], str) or not isinstance(summary['states'], list):
                continue
            if not all(isinstance(state, str) for state in summary['states']):
                continue
            if type(summary['durationSeconds']) not in (int, float) or not math.isfinite(summary['durationSeconds']) or summary['durationSeconds'] < 0:
                continue
            summaries.append({key: summary[key] for key in fields})
        except (ValueError, KeyError, TypeError):
            continue
    return summaries


def mutation_log_audit(path):
    """Check all new native protected writes, including watch-session writes, in the owned log."""
    protected = re.compile(r'^/me/(?:progress|franchises/[^/]+/progress|subscriptions(?:/[^/]+)?|watch-sessions/[^/]+)$')
    uuid_pattern = re.compile(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$')
    operations = {}
    sequences = {}
    checked = 0
    request_ids = set()
    failures = []
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return {'passed': False, 'protectedWrites': 0, 'uniqueOperations': 0, 'failures': ['Owned fixture log is unavailable.']}
    for line in lines:
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if item.get('method') not in ['POST', 'PUT', 'PATCH', 'DELETE'] or not protected.fullmatch(item.get('path', '')):
            continue
        if item.get('account') not in ['fixture-a', 'fixture-b']:
            continue
        request_id = item.get('requestID')
        if type(request_id) is int:
            if request_id not in request_ids:
                checked += 1
                request_ids.add(request_id)
        else:
            checked += 1  # Historical fixtures did not expose a safe per-request identifier.
        stamp = item.get('mutation')
        if not isinstance(stamp, dict) or not all(isinstance(stamp.get(key), str) and uuid_pattern.fullmatch(stamp[key])
                                                for key in ['operationID', 'writerID']) \
                or type(stamp.get('sequence')) is not int or not 1 <= stamp['sequence'] <= 9_007_199_254_740_991:
            failures.append(f"Missing or invalid mutation stamp: {item['method']} {item['path']} {item['account']}")
            continue
        operation = (item['account'], stamp['operationID'])
        sequence = (item['account'], stamp['writerID'], stamp['sequence'])
        metadata = (stamp['writerID'], stamp['sequence'])
        if operation in operations and operations[operation] != metadata:
            failures.append('One operation changed writer/sequence between attempts.')
        if sequence in sequences and sequences[sequence] != stamp['operationID']:
            failures.append('One writer sequence was reused for a different operation.')
        operations[operation] = metadata
        sequences[sequence] = stamp['operationID']
    return {'passed': not failures, 'protectedWrites': checked, 'uniqueOperations': len(operations), 'failures': failures[:20]}


def stop_owned(process):
    if process is None:
        return
    # start_new_session=True gives each owned child this process-group ID. Even if the
    # leader just exited, terminate any surviving children in its own group.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            # TimeoutExpired includes argv, which contains the ephemeral control token.
            raise RuntimeError('An owned QA process did not stop within the cleanup budget.') from None


def terminate_runner(signum, _frame):
    # Turning SIGTERM into a Python unwind runs child and fixture finally blocks.
    raise SystemExit(128 + signum)


def selected_test_cases(selected, root=ROOT):
    expected = set()
    for selector in selected:
        parts = selector.split('/')
        if len(parts) != 2 or parts[0] != 'PreviouslyUITests':
            raise RuntimeError('QA selection must name an explicit PreviouslyUITests class.')
        suite = parts[1]
        source = root / 'ios/UITests' / f'{suite}.swift'
        methods = re.findall(r'^\s*func\s+(test\w+)\s*\(', source.read_text(), re.MULTILINE)
        if not methods:
            raise RuntimeError(f'No explicit tests were discovered for {suite}.')
        expected.update((suite, method) for method in methods)
    if not expected:
        raise RuntimeError('QA cannot run an empty test selection.')
    return expected


def classify_result(body, exit_code, expected):
    """Fail closed unless every selected test has a named, passed receipt."""
    answer = {'passed': False, 'counts': {}, 'testCases': [],
              'expectedTests': sorted('/'.join(case) for case in expected)}
    try:
        result = json.loads(body)
        data = result['data']
        summary = data['summary']
        counts = summary['counts']
        cases = data['testCases']
        if not isinstance(counts, dict) or not isinstance(cases, list):
            raise TypeError('invalid structured fields')
        if any(type(counts.get(key)) is not int or counts[key] < 0 for key in ['passed', 'failed', 'skipped']):
            raise TypeError('invalid count')
        answer.update(counts=counts, testCases=cases)
        observed = set()
        for case in cases:
            suite = case['suite'].split('/')[-1].split('.')[-1]
            method = case['test'].removesuffix('()')
            if case['status'] != 'passed':
                answer['reason'] = 'At least one named test did not pass.'
                return answer
            observed.add((suite, method))
        missing = expected - observed
        if missing:
            answer['missingTests'] = sorted('/'.join(case) for case in missing)
            answer['reason'] = 'Selected test cases were absent from the structured receipt.'
        elif not expected or exit_code != 0 or result.get('didError') is not False or summary['status'] != 'SUCCEEDED':
            answer['reason'] = 'The test command or structured summary did not succeed.'
        elif counts['passed'] < len(expected) or counts['failed'] != 0 or counts['skipped'] != 0:
            answer['reason'] = 'Summary counts did not confirm every selected test passed without skips.'
        else:
            answer['passed'] = True
    except (ValueError, KeyError, TypeError, AttributeError):
        answer['reason'] = 'Tool did not return a verifiable structured test result.'
    return answer


def run_native_command(command, raw):
    child = subprocess.Popen(command, cwd=ROOT, stdout=raw, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        try:
            return child.wait(timeout=1800)
        except subprocess.TimeoutExpired:
            # Preserve redacted partial output and classify as failure, without printing argv.
            return 124
    finally:
        stop_owned(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator-id', required=True)
    parser.add_argument('--suite', choices=['smoke', 'directed', 'monkey', 'all'], default='smoke')
    parser.add_argument('--only-suite', action='append', choices=[item.split('/')[-1] for item in DIRECTED_SUITES] + ['PreviouslyTrailerTests'],
                        help='Focused native class selection, valid only with --suite directed.')
    parser.add_argument('--seed', action='append', type=int)
    parser.add_argument('--duration', type=int, default=300)
    parser.add_argument('--max-actions', type=int, default=500)
    parser.add_argument('--port', type=int, default=18787)
    args = parser.parse_args()
    if not 10 <= args.duration <= 300 or not 5 <= args.max_actions <= 1000:
        parser.error('Use duration 10–300 seconds and max-actions 5–1000.')
    if not 1024 <= args.port <= 65535:
        parser.error('Use an unprivileged explicit loopback port.')
    seeds = args.seed or DEFAULT_SEEDS
    if any(not 0 <= seed < 2**64 for seed in seeds):
        parser.error('Seeds must be unsigned 64-bit integers.')

    if args.only_suite and args.suite != 'directed':
        parser.error('--only-suite is valid only with --suite directed.')
    directed_selection = ['PreviouslyUITests/' + name for name in args.only_suite] if args.only_suite else DIRECTED_SUITES

    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    output = ROOT / 'ios/Tools/qa/.runs' / stamp
    output.mkdir(parents=True, mode=0o700)
    token = secrets.token_urlsafe(32)
    base = f'http://127.0.0.1:{args.port}'
    env = dict(os.environ, PREVIOUSLY_QA_CONTROL_TOKEN=token, PREVIOUSLY_QA_PORT=str(args.port))
    fixture = None
    fixture_log = None
    ledger = {'startedAt': stamp, 'simulatorId': args.simulator_id, 'configuration': 'QA',
              'bundleID': 'com.cognipin.previously.qa', 'fixtureVersion': '1',
              'cliPackage': CLI_PACKAGE, 'status': 'running', 'runs': []}
    previous_sigterm = signal.signal(signal.SIGTERM, terminate_runner)
    try:
        fixture_log = (output / 'fixture.log').open('w')
        fixture = subprocess.Popen(['node', str(ROOT / 'ios/Tools/qa/fixture-server.mjs')],
                                   env=env, stdout=fixture_log, stderr=subprocess.STDOUT, start_new_session=True)
        # A token-authenticated oracle verifies this is our fixture, never an occupied service.
        ready = False
        for _ in range(100):
            if fixture.poll() is not None:
                raise RuntimeError('Fixture exited; inspect fixture.log (an occupied port is never reused).')
            try:
                request = urllib.request.Request(base + '/__qa/state?account=fixture-a',
                                                  headers={'X-Previously-QA-Token': token})
                with urllib.request.urlopen(request, timeout=0.2) as response:
                    ready = json.load(response)['fixtureVersion'] == '1'
                if ready:
                    break
            except (OSError, ValueError):
                time.sleep(0.05)
        if not ready:
            raise RuntimeError('Owned fixture did not become ready.')
        subprocess.run(['xcodegen', 'generate'], cwd=ROOT / 'ios', check=True)
        ledger['revision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        ledger['dirty'] = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True))
        ledger['sourceFingerprint'] = source_fingerprint()
        plans = []
        if args.suite in ('directed', 'all'):
            plans.append(('directed', seeds[0], directed_selection, args.duration))
        if args.suite == 'smoke':
            plans.append(('smoke', seeds[0], ['PreviouslyUITests/PreviouslyMonkeyTests'], 10))
        if args.suite in ('monkey', 'all'):
            plans.extend((f'monkey-{seed}', seed, ['PreviouslyUITests/PreviouslyMonkeyTests'], args.duration)
                         for seed in seeds)
        for name, seed, selected, duration in plans:
            expected = selected_test_cases(selected)
            print(f'Running {name}: seed {seed}, random budget {duration}s, QA bundle only.', flush=True)
            invocation = {
                'projectPath': str(ROOT / 'ios/Previously.xcodeproj'), 'scheme': 'PreviouslyQA',
                'configuration': 'QA', 'simulatorId': args.simulator_id,
                'derivedDataPath': str(ROOT / 'ios/Tools/qa/.runs/DerivedData'),
                'testRunnerEnv': {'PREVIOUSLY_QA_CONTROL_TOKEN': token, 'PREVIOUSLY_QA_BASE_URL': base,
                                  'PREVIOUSLY_QA_SEED': str(seed), 'PREVIOUSLY_QA_DURATION_SECONDS': str(duration),
                                  'PREVIOUSLY_QA_MAX_ACTIONS': str(args.max_actions)},
                'extraArgs': ['-parallel-testing-enabled', 'NO', '-resultBundlePath', str(output / f'{name}.xcresult')]
                             + ['-only-testing:' + item for item in selected]
            }
            # Keep tool output off the console and redact the ephemeral control token before saving.
            with tempfile.TemporaryFile(mode='w+') as raw:
                exit_code = run_native_command(['npx', '--yes', CLI_PACKAGE, 'simulator', 'test', '--json',
                                                json.dumps(invocation), '--output', 'json'], raw)
                raw.seek(0)
                body = raw.read().replace(token, '[redacted-control-token]')
            (output / f'{name}.json').write_text(body)
            classification = classify_result(body, exit_code, expected)
            passed = classification.pop('passed')
            coverage = coverage_summaries(body)
            mutation_audit = mutation_log_audit(output / 'fixture.log')
            fingerprint = source_fingerprint()
            if fingerprint != ledger['sourceFingerprint']:
                passed = False
                classification['reason'] = 'Native or fixture source changed during qualification.'
            if not mutation_audit['passed']:
                passed = False
                classification['reason'] = 'An owned native write omitted or changed its persistent mutation identity.'
            if passed and selected == ['PreviouslyUITests/PreviouslyMonkeyTests']:
                reports = [item for item in coverage if item['caseName'] == 'monkey' and item['seed'] == seed]
                if len(reports) != 1 or reports[0]['completedActions'] == 0 or reports[0]['assertions'] == 0:
                    passed = False
                    classification['reason'] = 'The selected monkey lacks one verifiable action/assertion coverage log.'
            record = {'name': name, 'seed': seed, 'randomDurationSeconds': duration,
                      'status': 'passed' if passed else 'failed', 'exitCode': exit_code,
                      'resultBundle': str(output / f'{name}.xcresult'), 'coverage': coverage,
                      'mutationAudit': mutation_audit,
                      'sourceFingerprint': fingerprint, **classification}
            if exit_code == 124:
                record['reason'] = 'The native test command exceeded its 1800-second budget.'
            ledger['runs'].append(record)
            (output / 'ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
            print(f"{name}: {record['status']} {record.get('counts', {})}", flush=True)
            if not passed:
                ledger['status'] = 'failed'
                print(f'Failure evidence: {output}', flush=True)
                return 1
        print(f'QA evidence: {output}', flush=True)
        ledger['status'] = 'passed'
        return 0
    except BaseException as error:
        ledger['status'] = 'interrupted' if isinstance(error, (SystemExit, KeyboardInterrupt)) else 'failed'
        ledger['error'] = 'Run interrupted.' if ledger['status'] == 'interrupted' else str(error).replace(token, '[redacted-control-token]')
        raise
    finally:
        # A second termination during bounded cleanup must not orphan the owned fixture.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            try:
                stop_owned(fixture)
            except (OSError, RuntimeError) as cleanup_error:
                ledger['status'] = 'failed'
                ledger['cleanupError'] = str(cleanup_error).replace(token, '[redacted-control-token]')
                raise
            finally:
                if fixture_log is not None:
                    fixture_log.close()
                ledger['fixtureStopped'] = fixture is None or fixture.poll() is not None
                ledger['finishedAt'] = dt.datetime.now(dt.timezone.utc).isoformat()
                (output / 'ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
        finally:
            signal.signal(signal.SIGTERM, previous_sigterm)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f'Native QA runner failed: {error}', file=sys.stderr)
        raise SystemExit(1)
