"""Small negative tests for release-evidence classification; no Apple tool calls."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("archive_verifier", Path(__file__).with_name("verify-archive.py"))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def compile_log(app_define="", widget_define=""):
    return "\n".join([
        "xcodebuild -configuration Release archive",
        f"/x/swiftc -module-name Previously -target arm64-apple-ios18.0 {app_define}",
        f"/x/swiftc -module-name PreviouslyWidgets -target arm64-apple-ios18.0 {widget_define}",
        "** ARCHIVE SUCCEEDED **",
    ])


class ArchiveEvidenceTests(unittest.TestCase):
    def test_missing_compiler_rows_never_attest_no_qa(self):
        result = verifier.compiler_evidence("** ARCHIVE SUCCEEDED **")
        self.assertFalse(result["bothRuntimeModulesObserved"])
        self.assertFalse(result["noQANorDebugDefinesInObservedCompilerInvocations"])

    def test_qa_define_in_either_runtime_target_fails(self):
        self.assertTrue(verifier.compiler_evidence(compile_log())["noQANorDebugDefinesInObservedCompilerInvocations"])
        for app, widget in (("-D PREVIOUSLY_QA", ""), ("", "-DPREVIOUSLY_QA"), ("-D DEBUG", "")):
            with self.subTest(app=app, widget=widget):
                self.assertFalse(verifier.compiler_evidence(compile_log(app, widget))["noQANorDebugDefinesInObservedCompilerInvocations"])

    def test_wrong_group_or_extension_apple_entitlement_fails(self):
        ent = {"com.apple.security.application-groups": [verifier.GROUP],
               "com.apple.developer.team-identifier": verifier.TEAM,
               "application-identifier": verifier.TEAM + "." + verifier.APP_ID + ".widgets"}
        self.assertTrue(all(verifier.entitlement_checks(ent, widget=True).values()))
        ent["com.apple.security.application-groups"] = ["group.some.other.app"]
        self.assertFalse(verifier.entitlement_checks(ent, widget=True)["sharedGroupExact"])
        ent["com.apple.developer.applesignin"] = ["Default"]
        self.assertFalse(verifier.entitlement_checks(ent, widget=True)["appleSignInCorrectScope"])

    def test_gui_compiler_paths_prove_release_without_cli_markers(self):
        text = "\n".join(f"/x/swiftc -module-name {name} -target arm64-apple-ios18.0 -output-file-map /archive/{name}/Release-iphoneos/{name}.build/output.json" for name in ("Previously", "PreviouslyWidgets"))
        result = verifier.compiler_evidence(text)
        self.assertTrue(result["releaseConfigurationMarker"])
        self.assertTrue(result["noQANorDebugDefinesInObservedCompilerInvocations"])
        self.assertFalse(result["archiveSucceededMarker"])
        self.assertFalse(result["releaseEvidence"]["CLIConfigurationArgument"])
        contradictory = verifier.compiler_evidence("-configuration Release\n" + text.replace("Release-iphoneos", "Debug-iphoneos"))
        self.assertFalse(contradictory["releaseConfigurationMarker"])

    def test_qa_file_exposure_and_insecure_transport_fail(self):
        previous = {"CFBundleDisplayName": "Previously.", "SupportEmail": "support@example.test"}
        info = dict(previous)
        self.assertTrue(all(verifier.production_metadata_checks(info, previous).values()))
        for key, value, check in (
            ("CFBundleDisplayName", "Previously QA", "noQADisplayOrBundleName"),
            ("UIFileSharingEnabled", True, "fileSharingAbsentOrFalse"),
            ("LSSupportsOpeningDocumentsInPlace", True, "openingDocumentsInPlaceAbsentOrFalse"),
            ("SupportEmail", "other@example.test", "supportEmailMatches16"),
            ("NSAppTransportSecurity", {"NSAllowsArbitraryLoads": True}, "noArbitraryATSLoads"),
            ("NSAppTransportSecurity", {"NSExceptionDomains": {"example.test": {"NSExceptionAllowsInsecureHTTPLoads": True}}}, "noArbitraryATSLoads"),
        ):
            with self.subTest(key=key, value=value):
                modified = dict(info, **{key: value})
                self.assertFalse(verifier.production_metadata_checks(modified, previous)[check])


if __name__ == "__main__":
    unittest.main()
