#!/usr/bin/env python3
"""Publish build-17 QA receipts only from one completed, unchanged 75+3 all-run.

Reads existing source/logs/Apple xcresults; never builds, installs, launches or contacts a
fixture/provider. Refuses incomplete/failed evidence and never overwrites published receipts.
"""
from __future__ import annotations

import argparse
import ast
import datetime as dt
import hashlib
import json
import math
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
SEEDS = [20261006, 60102620, 38654705664]
BUILD = "17"
ROOT_STATES = {"home", "schedule", "feed", "library", "discover", "anime-detail"}
COVERAGE_FIELDS = ["version", "caseName", "seed", "durationSeconds", "completedActions", "unavailableActions", "assertions", "states"]
FILES_CASES = {"files-partial-import", "files-all-skipped-import", "files-export-saved-copy"}


class EvidenceError(ValueError):
    pass


def require(value: bool, message: str) -> None:
    if not value:
        raise EvidenceError(message)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def source_paths(root: Path) -> list[Path]:
    paths = [path for directory in ("ios/Sources", "ios/Shared", "ios/Widgets", "ios/UITests")
             for path in (root / directory).rglob("*") if path.is_file()]
    paths.extend(root / name for name in ("ios/project.yml", "ios/Tools/qa/fixture-server.mjs"))
    for name in ("ios/Resources/PrivacyInfo.xcprivacy", "ios/Resources/Info.plist", "ios/Resources/QA-Info.plist",
                 "ios/Previously.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"):
        if (root / name).is_file():
            paths.append(root / name)
    return sorted(paths)


def source_fingerprint(root: Path) -> dict:
    digest = hashlib.sha256()
    paths = source_paths(root)
    for path in paths:
        digest.update(str(path.relative_to(root)).encode() + b"\0")
        digest.update(path.read_bytes() + b"\0")
    return {"sha256": digest.hexdigest(), "fileCount": len(paths)}


def expected_tests(root: Path) -> set[str]:
    runner = root / "ios/Tools/qa/run-native-qa.py"
    tree = ast.parse(runner.read_text())
    suites = None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "DIRECTED_SUITES" for target in node.targets):
            suites = ast.literal_eval(node.value)
    require(isinstance(suites, list), "Runner has no literal directed selection.")
    expected = set()
    for selector in suites:
        target, suite = selector.split("/")
        require(target in {"PreviouslyUITests", "PreviouslyStorageTests"}, "Unknown directed target.")
        source = (root / "ios/UITests" / (suite + ".swift")).read_text()
        methods = re.findall(r"^\s*(?:@Test\s+)?func\s+(test\w+)\s*\(", source, re.MULTILINE)
        require(bool(methods), "A selected suite has no named tests.")
        expected.update(suite + "/" + method for method in methods)
    require(len(expected) == 75, "Current directed source does not define exactly 75 selected tests.")
    require(sum(name.startswith("WidgetSnapshotTests/") for name in expected) == 10, "Ten named Swift Testing storage cases are required.")
    require(sum(name.startswith("AccountExportPreparationTests/") for name in expected) == 4, "Four export preparation cases are required.")
    require(sum(name.startswith("PreviouslyFilesTests/") for name in expected) == 3, "Three real Files cases are required.")
    return expected


def case_key(case: dict) -> str:
    suite = case["suite"].split("/")[-1].split(".")[-1]
    return suite + "/" + case["test"].removesuffix("()")


def passed_cases(cases: list, expected: set[str]) -> dict:
    require(isinstance(cases, list), "Named cases are unavailable.")
    keyed = {case_key(case): case for case in cases}
    require(len(keyed) == len(cases), "Named cases contain duplicates.")
    require(set(keyed) == expected, "Named cases do not equal the exact selected set.")
    require(all(case.get("status") == "passed" for case in keyed.values()), "A named case failed or skipped.")
    return keyed


def validate_ledger(ledger: dict, expected: set[str], current: dict) -> list[dict]:
    require(ledger.get("status") == "passed" and bool(ledger.get("finishedAt")), "All-run ledger is not completed/passed.")
    require(ledger.get("fixtureStopped") is True, "Owned fixture cleanup is not confirmed.")
    require(not any(ledger.get(key) for key in ("error", "cleanupError")), "Ledger records an execution or cleanup error.")
    require(ledger.get("configuration") == "QA" and ledger.get("bundleID") == "com.cognipin.previously.qa", "Wrong QA target context.")
    invocation = ledger.get("invocation", {})
    required = {"requestedSuite": "all", "onlySuites": [], "seeds": SEEDS, "durationSeconds": 300,
                "scheme": "PreviouslyQA", "configuration": "QA", "bundleID": "com.cognipin.previously.qa"}
    require(all(invocation.get(key) == value for key, value in required.items()), "Explicit invocation is not the required full all-run.")
    require(str(invocation.get("sourceBuildNumber")) == BUILD, "Invocation source build is not 17.")
    require(type(invocation.get("maxActions")) is int and 5 <= invocation["maxActions"] <= 1000, "Missing bounded monkey action budget.")
    require(ledger.get("sourceFingerprint") == current, "Current source does not match qualified source.")
    runs = ledger.get("runs", [])
    require([run.get("name") for run in runs] == ["directed"] + [f"monkey-{seed}" for seed in SEEDS], "Exactly one directed phase followed by the three fixed seeds is required.")
    last_writes = last_ops = 0
    for index, run in enumerate(runs):
        require(run.get("status") == "passed" and run.get("exitCode") == 0, "A phase did not pass.")
        require(run.get("sourceFingerprint") == current, "Source changed during a phase.")
        count = 75 if index == 0 else 1
        require(run.get("counts") == {"passed": count, "failed": 0, "skipped": 0}, "A phase has incomplete, failed or skipped test counts.")
        selection = expected if index == 0 else {"PreviouslyMonkeyTests/testSeededMonkey"}
        require(set(run.get("expectedTests", [])) == selection and len(run["expectedTests"]) == len(selection), "The phase did not select exactly the expected named tests.")
        passed_cases(run.get("testCases"), selection)
        require(run.get("randomDurationSeconds") == 300 and run.get("seed") == SEEDS[0 if index == 0 else index - 1], "A phase has the wrong seed or requested duration.")
        audit = run.get("mutationAudit", {})
        require(audit.get("passed") is True and audit.get("failures") == [], "Mutation identity audit failed.")
        writes, operations = audit.get("protectedWrites"), audit.get("uniqueOperations")
        require(type(writes) is int and type(operations) is int and writes >= operations > 0, "Mutation audit contains no real protected operation evidence.")
        require(writes >= last_writes and operations >= last_ops, "Cumulative mutation counts moved backwards.")
        if index:
            require(writes > last_writes and operations > last_ops, "A monkey seed has no additional protected mutation evidence.")
            reports = [row for row in run.get("coverage", []) if row.get("caseName") == "monkey" and row.get("seed") == run["seed"]]
            require(len(reports) == 1, "Monkey needs exactly one matching actual coverage summary.")
            row = reports[0]
            require(type(row.get("durationSeconds")) in (int, float) and math.isfinite(row["durationSeconds"]) and row["durationSeconds"] >= 300, "Monkey session ended before the requested 300-second budget.")
            require(type(row.get("completedActions")) is int and row["completedActions"] > 5 and type(row.get("assertions")) is int and row["assertions"] > 0, "Monkey has insufficient completed action/assertion evidence.")
            require(ROOT_STATES.issubset(set(row.get("states", []))), "Monkey did not observe every root and anime detail.")
        last_writes, last_ops = writes, operations
    files = [row for row in runs[0].get("coverage", []) if row.get("caseName") in FILES_CASES]
    require(len(files) == 3 and {row["caseName"] for row in files} == FILES_CASES, "All three real Files coverage summaries are required.")
    require(all(row.get("completedActions", 0) > 0 and row.get("assertions", 0) > 0 for row in files), "Files summaries lack real action/assertion evidence.")
    return runs


def primary_cases(bundle: Path) -> tuple[list, str]:
    tool = Path("/Applications/Xcode.app/Contents/Developer/usr/bin/xcresulttool")
    result = subprocess.run([str(tool), "get", "test-results", "tests", "--path", str(bundle), "--compact"],
                            check=True, capture_output=True, timeout=60)
    tree = json.loads(result.stdout)
    cases = []
    def visit(node):
        if node.get("nodeType") == "Test Case":
            suite, method = node["nodeIdentifier"].rsplit("/", 1)
            cases.append({"suite": suite, "test": method.removesuffix("()"), "status": node.get("result", "unknown").lower(),
                          "durationMs": round(node.get("durationInSeconds", 0) * 1000)})
        for child in node.get("children", []):
            visit(child)
    for node in tree["testNodes"]:
        visit(node)
    return cases, hashlib.sha256(result.stdout).hexdigest()


def coverage_from_log(path: Path) -> list:
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        if not line.startswith("QA_SUMMARY "):
            continue
        row = json.loads(line.removeprefix("QA_SUMMARY "))
        require(all(type(row.get(key)) is int and row[key] >= 0 for key in ("version", "seed", "completedActions", "unavailableActions", "assertions")), "Invalid coverage counters in actual log.")
        require(type(row.get("durationSeconds")) in (int, float) and math.isfinite(row["durationSeconds"]) and row["durationSeconds"] >= 0, "Invalid coverage duration.")
        require(isinstance(row.get("caseName"), str) and isinstance(row.get("states"), list) and all(isinstance(state, str) for state in row["states"]), "Invalid coverage context.")
        rows.append({key: row[key] for key in COVERAGE_FIELDS})
    return rows


def actual_mutation_audit(path: Path) -> dict:
    protected = re.compile(r"^/me/(?:progress|franchises/[^/]+/progress|subscriptions(?:/[^/]+)?|watch-sessions/[^/]+)$")
    uuid = re.compile(r"^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$")
    operations, sequences, seen = {}, {}, set()
    writes = 0
    for line in path.read_text().splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("method") not in ("POST", "PUT", "PATCH", "DELETE") or not protected.fullmatch(row.get("path", "")) or row.get("account") not in ("fixture-a", "fixture-b"):
            continue
        request = row.get("requestID")
        require(type(request) is int and request > 0, "Protected request lacks an actual safe request identifier.")
        if request not in seen:
            writes += 1
            seen.add(request)
        stamp = row.get("mutation", {})
        require(all(isinstance(stamp.get(key), str) and uuid.fullmatch(stamp[key]) for key in ("operationID", "writerID")), "Protected write lacks UUID mutation metadata.")
        require(type(stamp.get("sequence")) is int and 1 <= stamp["sequence"] <= 9_007_199_254_740_991, "Invalid mutation sequence.")
        operation = (row["account"], stamp["operationID"])
        sequence = (row["account"], stamp["writerID"], stamp["sequence"])
        metadata = (stamp["writerID"], stamp["sequence"])
        require(operation not in operations or operations[operation] == metadata, "An operation changed writer or sequence on retry.")
        require(sequence not in sequences or sequences[sequence] == stamp["operationID"], "A writer sequence identifies multiple operations.")
        operations[operation], sequences[sequence] = metadata, stamp["operationID"]
    return {"passed": True, "protectedWrites": writes, "uniqueOperations": len(operations), "failures": []}


def collect(run_dir: Path, root: Path) -> tuple[dict, dict]:
    run_dir = run_dir.resolve(strict=True)
    root = root.resolve(strict=True)
    require(run_dir.parent == root / "ios/Tools/qa/.runs", "Run must be one direct owned .runs directory.")
    ledger_path = run_dir / "ledger.json"
    initial_ledger_hash = sha(ledger_path)
    ledger = json.loads(ledger_path.read_text())
    require(ledger.get("startedAt") == run_dir.name, "Ledger run identity does not match its evidence directory.")
    expected = expected_tests(root)
    fingerprint = source_fingerprint(root)
    versions = re.findall(r"CURRENT_PROJECT_VERSION:\s*[\"']?(\d+)", (root / "ios/project.yml").read_text())
    require(bool(versions) and set(versions) == {BUILD}, "Current project source build is not exactly17.")
    runs = validate_ledger(ledger, expected, fingerprint)
    evidence = []
    for index, run in enumerate(runs):
        name = run["name"]
        selection = expected if index == 0 else {"PreviouslyMonkeyTests/testSeededMonkey"}
        bundle = run_dir / (name + ".xcresult")
        require(bundle.is_dir() and Path(run["resultBundle"]).resolve() == bundle, "A result bundle is missing or borrowed from another phase/run.")
        actual, primary_hash = primary_cases(bundle)
        primary = passed_cases(actual, selection)
        require(canonical(primary) == canonical(passed_cases(run["testCases"], selection)), "Ledger and actual Apple named results disagree.")
        named_path = run_dir / (name + "-named-cases.json")
        saved = passed_cases(json.loads(named_path.read_text()), selection)
        require(canonical(primary) == canonical(saved), "Saved named results disagree with actual Apple artifact.")
        tool_path = run_dir / (name + ".json")
        tool = json.loads(tool_path.read_text())
        data = tool["data"]
        require(tool.get("didError") is False and data["summary"]["status"] == "SUCCEEDED" and data["summary"]["counts"] == run["counts"], "Actual MCP receipt did not succeed with matching counts.")
        tool_cases = data["testCases"]
        tool_keys = set()
        for case in tool_cases:
            key = case_key(case)
            require(key in primary and case.get("status") == primary[key]["status"], "MCP and Apple disagree about a named case.")
            require(key not in tool_keys, "MCP receipt repeats a named case.")
            tool_keys.add(key)
        # Pinned CLI omits Swift Testing from its flattened list; only those ten may be absent.
        require(selection - tool_keys <= {key for key in selection if key.startswith("WidgetSnapshotTests/")}, "MCP receipt omitted a non-Swift-Testing case.")
        log_path = Path(data["artifacts"]["buildLogPath"]).expanduser().resolve(strict=True)
        require(coverage_from_log(log_path) == run["coverage"], "Actual raw log coverage disagrees with ledger.")
        evidence.append({"name": name, "toolReceiptPath": str(tool_path.relative_to(root)), "toolReceiptSHA256": sha(tool_path),
                         "primaryResultBundle": str(bundle.relative_to(root)), "primaryInfoSHA256": sha(bundle / "Info.plist"),
                         "primaryNamedTreeSHA256": primary_hash, "savedNamedCasesSHA256": sha(named_path),
                         "rawBuildLogPath": str(log_path), "rawBuildLogSHA256": sha(log_path)})
    audit = actual_mutation_audit(run_dir / "fixture.log")
    require(audit == runs[-1]["mutationAudit"], "Final mutation receipt disagrees with actual full fixture log.")
    require(source_fingerprint(root) == fingerprint and sha(ledger_path) == initial_ledger_hash, "Evidence source changed during summarization.")
    directed = runs[0]
    monkeys = []
    prior = directed["mutationAudit"]
    for run in runs[1:]:
        report = next(row for row in run["coverage"] if row["caseName"] == "monkey")
        monkeys.append({"seed": run["seed"], "requestedRandomDurationSeconds": 300, "observedSessionDurationSeconds": report["durationSeconds"],
                        "completedActions": report["completedActions"], "assertions": report["assertions"], "unavailableActions": report["unavailableActions"],
                        "states": report["states"], "additionalProtectedWrites": run["mutationAudit"]["protectedWrites"] - prior["protectedWrites"],
                        "additionalUniqueOperations": run["mutationAudit"]["uniqueOperations"] - prior["uniqueOperations"]})
        prior = run["mutationAudit"]
    common = {"schemaVersion": 1, "qualified": True, "status": "passed", "build": BUILD,
              "recordedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "originalLedgerPath": str(ledger_path.relative_to(root)),
              "evidencePath": str(run_dir.relative_to(root)), "originalLedgerSHA256": initial_ledger_hash, "sourceFingerprint": fingerprint,
              "revision": ledger.get("revision"), "dirty": ledger.get("dirty"), "configuration": "QA", "scheme": "PreviouslyQA",
              "bundleID": "com.cognipin.previously.qa", "invocation": ledger["invocation"], "fixtureStopped": True,
              "sourceStillMatches": True, "singleAllRun": True, "verifierSHA256": sha(Path(__file__)),
              "runnerSHA256": sha(root / "ios/Tools/qa/run-native-qa.py"), "provenance": evidence,
              "boundaries": ["One completed fixture-based simulator all-run only; no passes stitched from earlier runs.",
                             "Build17 is source/invocation provenance. This does not verify a production Release archive, physical device, minimum-iOS18 runtime or real-provider account.",
                             "Monkey session duration includes setup, requested random interaction budget and final oracle/cold relaunch. The source also has a maxActions cap; no exact random-subinterval duration is inferred.",
                             "Mutation counts are cumulative per runner phase. The final full-log audit is the total; phase totals must not be added.",
                             "Apple named test results, actual QA_SUMMARY logs and loopback fixture operation metadata were re-read; this does not test real provider quotas or WAN behavior."]}
    native = dict(common, directed={"total": 75, "passed": 75, "failed": 0, "skipped": 0,
                                  "swiftTestingStorage": 10, "exportPreparation": 4,
                                  "namedTests": sorted(expected)},
                  monkey={"seeds": SEEDS, "passedSeeds": 3, "requestedRandomDurationSecondsPerSeed": 300,
                          "completedActions": sum(item["completedActions"] for item in monkeys),
                          "assertions": sum(item["assertions"] for item in monkeys),
                          "unavailableActions": sum(item["unavailableActions"] for item in monkeys), "runs": monkeys},
                  mutationAudit=dict(audit, fixtureLogSHA256=sha(run_dir / "fixture.log")))
    file_names = {key for key in expected if key.startswith(("PreviouslyFilesTests/", "AccountExportPreparationTests/"))}
    files = dict(common, namedCases=[case for case in directed["testCases"] if case_key(case) in file_names],
                 counts={"passed": 7, "failed": 0, "skipped": 0, "realFilesUI": 3, "exportPreparation": 4},
                 coverage=[row for row in directed["coverage"] if row["caseName"] in FILES_CASES],
                 assertionMeaning={"testJSONAndCSVSaveToFilesContainAccountCopyAndSurviveSignOut":
                     "Passed frozen test asserts actual saved JSON/canonical account and CSV contents, zero fetch on open, one JSON fetch, no added CSV fetch, saved-copy equality after sign-out and cold relaunch.",
                     "testPartialMALFilePreviewAndApplyThroughSystemPicker": "Passed frozen test asserts real picker input, preview omissions, explicit apply, expected progress/status and other fixture account unchanged.",
                     "testAllSkippedMALFileRendersReasonWithoutApplyAction": "Passed frozen test asserts visible omission reason, no Apply, and unchanged fixture membership/progress."})
    files["boundaries"] = common["boundaries"] + ["Saved-file bytes/request counts are asserted by named frozen-source UI tests, not duplicated as unrecorded numeric measurements in this summary.",
                                                                 "QA uses its own Files Documents domain and synthetic samples. User-saved copies intentionally survive account cleanup; app-managed staging has a separate cleanup path."]
    return native, files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--repo", type=Path, default=ROOT)
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).parent)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    try:
        native, files = collect(args.run_dir, args.repo)
        outputs = [args.output_dir / "native-results.json", args.output_dir / "files-results.json"]
        if not args.verify_only:
            require(args.output_dir.resolve().is_relative_to((args.repo / "docs/qa/2026-10-15").resolve()), "Output must remain in the owned dated QA documentation tree.")
            require(args.output_dir.is_dir() and not any(path.exists() for path in outputs), "Output directory is missing or a receipt already exists; never overwrite evidence.")
            created = []
            try:
                for path, body in zip(outputs, (native, files)):
                    with path.open("x") as handle:
                        created.append(path)
                        handle.write(json.dumps(body, indent=2) + "\n")
            except OSError:
                for path in created:
                    path.unlink(missing_ok=True)
                raise
        print(json.dumps({"qualified": True, "build": BUILD, "directedPassed": 75, "monkeySeeds": SEEDS,
                          "originalLedgerPath": native["originalLedgerPath"], "wroteReceipts": not args.verify_only}, indent=2))
        return 0
    except EvidenceError as error:
        print(json.dumps({"qualified": False, "status": "evidence_rejected", "reason": str(error), "successReceiptsWritten": False}))
        return 1
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        # Never echo raw logs, command argv or fixture control credentials on malformed evidence.
        print(json.dumps({"qualified": False, "status": "evidence_rejected", "reason": "Missing, failed, changed, incomplete or inconsistent all-run evidence; no success receipts were written."}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
