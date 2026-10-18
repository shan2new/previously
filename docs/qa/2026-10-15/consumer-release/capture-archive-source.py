#!/usr/bin/env python3
"""Read source and save a pre-archive manifest only after the exact native all-run qualifies."""
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[4]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        receipt_path = ROOT / "docs/qa/2026-10-15/native-release/native-results.json"
        native = json.loads(receipt_path.read_text())
        if native.get("qualified") is not True or native.get("build") != "17" or native.get("singleAllRun") is not True:
            raise ValueError("Final build17 single all-run receipt is required.")
        helper_path = ROOT / "docs/qa/2026-10-15/native-release/summarize-native.py"
        spec = importlib.util.spec_from_file_location("native_receipt_sources", helper_path)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        fingerprint = helper.source_fingerprint(ROOT)
        if fingerprint != native["sourceFingerprint"]:
            raise ValueError("Native-qualified source has changed.")
        ledger_path = ROOT / native["originalLedgerPath"]
        if sha(ledger_path) != native["originalLedgerSHA256"]:
            raise ValueError("Qualified original ledger changed.")
        paths = set(helper.source_paths(ROOT))
        paths.add(ROOT / "ios/Previously.xcodeproj/project.pbxproj")
        paths.update(path for path in (ROOT / "ios/Previously.xcodeproj/xcshareddata/xcschemes").rglob("*") if path.is_file())
        paths.update(path for path in (ROOT / "ios/Resources").rglob("*") if path.is_file())
        records = [{"path": str(path.relative_to(ROOT)), "sha256": sha(path)} for path in sorted(paths)]
        if helper.source_fingerprint(ROOT) != fingerprint:
            raise ValueError("Source changed during manifest capture.")
        output = args.output.resolve()
        if not output.is_relative_to(ROOT / "docs/qa/2026-10-15/consumer-release"):
            raise ValueError("Manifest must stay in the owned consumer-release evidence directory.")
        report = {"recordedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "build": "17",
                  "qualifiedNativeReceipt": str(receipt_path.relative_to(ROOT)), "qualifiedNativeReceiptSHA256": sha(receipt_path),
                  "qualifiedLedgerPath": native["originalLedgerPath"], "sourceFingerprint": fingerprint,
                  "files": records, "fileCount": len(records), "sourceCaptureSHA256": sha(Path(__file__)),
                  "boundary": "Current native-qualified inputs plus generated project/shared schemes/resources. This preserves a pre/post file equality record, not an independent reconstruction of compiler inputs or production runtime proof. Private signing configuration and keys are not read."}
        with output.open("x") as handle:
            handle.write(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"captured": True, "fileCount": len(records), "sourceFingerprint": fingerprint, "output": str(output)}))
        return 0
    except (OSError, ValueError, KeyError, TypeError):
        print(json.dumps({"captured": False, "reason": "Missing/changed final native evidence, source or output; no build or native activity performed."}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
