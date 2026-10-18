#!/usr/bin/env python3
"""Record the local native inputs before an archive; never builds or changes them."""
from pathlib import Path
import argparse
import datetime
import hashlib
import importlib.util
import json
import subprocess


ROOT = Path(__file__).resolve().parents[4]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    paths = set()
    for directory in ['ios/Sources', 'ios/Shared', 'ios/Widgets', 'ios/Resources', 'ios/UITests']:
        paths.update(p for p in (ROOT / directory).rglob('*') if p.is_file())
    for name in ['ios/project.yml', 'ios/Previously.xcodeproj/project.pbxproj',
                 'ios/Previously.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
                 'ios/Tools/qa/fixture-server.mjs', 'ios/Tools/qa/fixture-server.test.mjs',
                 'ios/Tools/qa/run-native-qa.py', 'ios/Tools/qa/run-native-qa.test.py']:
        paths.add(ROOT / name)
    paths.update((ROOT / 'ios/Previously.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
    if any(p.is_symlink() or not p.is_file() for p in paths):
        raise ValueError('Native inputs must be existing regular files')
    records = [{'path': str(p.relative_to(ROOT)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
               for p in sorted(paths)]
    spec = importlib.util.spec_from_file_location('native_qa_runner', ROOT / 'ios/Tools/qa/run-native-qa.py')
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    result = {
        'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'repository': str(ROOT),
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'nativeQAFingerprint': runner.source_fingerprint(ROOT),
        'fileCount': len(records),
        'manifestSHA256': hashlib.sha256(json.dumps(records, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
        'files': records,
        'boundary': 'Local inputs at this time; archive build and source continuity require separate receipts.',
    }
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps({k: result[k] for k in ['capturedAt', 'head', 'nativeQAFingerprint', 'fileCount', 'manifestSHA256']}))


if __name__ == '__main__':
    main()
