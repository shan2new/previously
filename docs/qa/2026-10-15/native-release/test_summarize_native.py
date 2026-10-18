"""Pure evidence-guard checks. Synthetic ledgers never become release receipts."""
import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("native_summarizer", Path(__file__).with_name("summarize-native.py"))
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


def synthetic_contract():
    expected = {f"WidgetSnapshotTests/testStorage{n}" for n in range(10)}
    expected |= {f"AccountExportPreparationTests/testExport{n}" for n in range(4)}
    expected |= {f"PreviouslyFilesTests/testFiles{n}" for n in range(3)}
    expected |= {f"OtherDirectedTests/testCase{n}" for n in range(58)}
    fingerprint = {"sha256": "a" * 64, "fileCount": 430}
    def cases(names):
        return [{"suite": name.split("/")[0], "test": name.split("/")[1], "status": "passed", "durationMs": 1} for name in sorted(names)]
    runs = []
    for index, name in enumerate(["directed"] + [f"monkey-{seed}" for seed in summary.SEEDS]):
        selected = expected if index == 0 else {"PreviouslyMonkeyTests/testSeededMonkey"}
        coverage = [{"version": 1, "caseName": item, "seed": summary.SEEDS[0], "durationSeconds": 10,
                     "completedActions": 5, "assertions": 2, "unavailableActions": 0, "states": []} for item in sorted(summary.FILES_CASES)] if index == 0 else [
            {"version": 1, "caseName": "monkey", "seed": summary.SEEDS[index - 1], "durationSeconds": 310,
             "completedActions": 100, "assertions": 50, "unavailableActions": 20, "states": sorted(summary.ROOT_STATES)}]
        runs.append({"name": name, "seed": summary.SEEDS[0 if index == 0 else index - 1], "randomDurationSeconds": 300,
                     "status": "passed", "exitCode": 0, "counts": {"passed": len(selected), "failed": 0, "skipped": 0},
                     "expectedTests": sorted(selected), "testCases": cases(selected), "coverage": coverage,
                     "sourceFingerprint": fingerprint,
                     "mutationAudit": {"passed": True, "protectedWrites": 10 + 2 * index, "uniqueOperations": 5 + index, "failures": []}})
    return expected, fingerprint, {"status": "passed", "finishedAt": "synthetic", "fixtureStopped": True,
        "configuration": "QA", "bundleID": "com.cognipin.previously.qa", "sourceFingerprint": fingerprint,
        "invocation": {"requestedSuite": "all", "onlySuites": [], "seeds": summary.SEEDS, "durationSeconds": 300,
                       "maxActions": 500, "scheme": "PreviouslyQA", "configuration": "QA", "bundleID": "com.cognipin.previously.qa", "sourceBuildNumber": "17"},
        "runs": runs}


class NativeReceiptGuards(unittest.TestCase):
    def setUp(self):
        self.expected, self.fingerprint, self.ledger = synthetic_contract()

    def rejected(self, change):
        altered = copy.deepcopy(self.ledger)
        change(altered)
        with self.assertRaises(summary.EvidenceError):
            summary.validate_ledger(altered, self.expected, self.fingerprint)

    def test_structural_validation_alone_does_not_publish(self):
        runs = summary.validate_ledger(self.ledger, self.expected, self.fingerprint)
        self.assertEqual(len(runs), 4)
        self.assertEqual(runs[-1]["mutationAudit"]["protectedWrites"], 16)
        # Cumulative phase16 is the total; adding10+12+14+16 would falsely report52.
        self.assertNotEqual(sum(run["mutationAudit"]["protectedWrites"] for run in runs), 16)

    def test_refuses_missing_or_focused_invocation_even_with_four_phases(self):
        self.rejected(lambda ledger: ledger.pop("invocation"))
        self.rejected(lambda ledger: ledger["invocation"].update(requestedSuite="directed"))
        self.rejected(lambda ledger: ledger["invocation"].update(onlySuites=["PreviouslyFilesTests"]))

    def test_refuses_missing_swift_testing_export_duplicate_or_failed_name(self):
        for suite in ("WidgetSnapshotTests", "AccountExportPreparationTests"):
            def remove(ledger):
                rows = ledger["runs"][0]["testCases"]
                index = next(i for i, row in enumerate(rows) if row["suite"] == suite)
                rows.pop(index)
            self.rejected(remove)
        self.rejected(lambda ledger: ledger["runs"][0]["testCases"].append(ledger["runs"][0]["testCases"][0]))
        self.rejected(lambda ledger: ledger["runs"][0]["testCases"][0].update(status="failed"))

    def test_refuses_changed_source_wrong_build_or_missing_cleanup(self):
        self.rejected(lambda ledger: ledger["runs"][1].update(sourceFingerprint={"sha256": "b" * 64, "fileCount": 430}))
        self.rejected(lambda ledger: ledger["invocation"].update(sourceBuildNumber="16"))
        self.rejected(lambda ledger: ledger.update(fixtureStopped=False))
        self.rejected(lambda ledger: ledger.update(status="running"))

    def test_refuses_wrong_short_or_unproductive_monkey(self):
        self.rejected(lambda ledger: ledger["runs"][2].update(seed=123))
        self.rejected(lambda ledger: ledger["runs"][1]["coverage"][0].update(durationSeconds=299))
        self.rejected(lambda ledger: ledger["runs"][1]["coverage"][0].update(completedActions=0))
        self.rejected(lambda ledger: ledger["runs"][1]["coverage"][0].update(states=["home"]))
        self.rejected(lambda ledger: ledger["runs"].pop())

    def test_refuses_no_new_or_failed_mutation_evidence(self):
        self.rejected(lambda ledger: ledger["runs"][1].update(mutationAudit=copy.deepcopy(ledger["runs"][0]["mutationAudit"])))
        self.rejected(lambda ledger: ledger["runs"][1]["mutationAudit"].update(failures=["missing stamp"]))

    def test_refuses_missing_real_files_summary(self):
        self.rejected(lambda ledger: ledger["runs"][0]["coverage"].pop())

    def test_actual_mutation_audit_rejects_changed_operation_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.log"
            stamp = {"operationID": "11111111-1111-4111-8111-111111111111", "writerID": "22222222-2222-4222-8222-222222222222", "sequence": 1}
            row = {"requestID": 1, "method": "PUT", "path": "/me/progress", "account": "fixture-a", "mutation": stamp}
            path.write_text(json.dumps(row) + "\n" + json.dumps(row) + "\n")
            self.assertEqual(summary.actual_mutation_audit(path)["protectedWrites"], 1)
            later = dict(row, requestID=2, mutation=dict(stamp, sequence=2))
            path.write_text(json.dumps(row) + "\n" + json.dumps(later) + "\n")
            with self.assertRaises(summary.EvidenceError):
                summary.actual_mutation_audit(path)


if __name__ == "__main__":
    unittest.main()
