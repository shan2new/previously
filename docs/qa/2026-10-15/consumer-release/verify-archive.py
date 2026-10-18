#!/usr/bin/env python3
"""Read-only archive inspection. Never builds, signs, installs, launches or uploads.

Only --output writes a report, using exclusive creation to preserve prior receipts.
The public Clerk key is compared in memory and is never included in output.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import plistlib
import re
import shlex
import subprocess
import sys
from pathlib import Path

APP_ID = "com.cognipin.previously"
GROUP = "group.com.cognipin.previously"
TEAM = "YLPZXZS2F4"
PRIVACY_PATHS = {
    "PrivacyInfo.xcprivacy",
    "Clerk_ClerkKit.bundle/PrivacyInfo.xcprivacy",
    "Clerk_ClerkKitUI.bundle/PrivacyInfo.xcprivacy",
    "PhoneNumberKit_PhoneNumberKit.bundle/PrivacyInfo.xcprivacy",
}
DATA_TYPES = {
    "NSPrivacyCollectedDataType" + suffix
    for suffix in ("DeviceID", "EmailAddress", "UserID", "Name", "OtherUserContent", "ProductInteraction")
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def command(*args: str) -> subprocess.CompletedProcess:
    # Commands are fixed read-only Apple inspection tools, never a caller-supplied executable.
    return subprocess.run(args, capture_output=True, check=False, timeout=60)


def signing(bundle: Path) -> dict:
    verification = command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle))
    ent = command("/usr/bin/codesign", "--display", "--entitlements", ":-", str(bundle))
    entitlements = plistlib.loads(ent.stdout) if ent.returncode == 0 else {}
    profile_path = bundle / "embedded.mobileprovision"
    profile = {}
    if profile_path.is_file():
        decoded = command("/usr/bin/security", "cms", "-D", "-i", str(profile_path))
        if decoded.returncode == 0:
            profile = plistlib.loads(decoded.stdout)
    expiry = profile.get("ExpirationDate")
    now = dt.datetime.now(dt.timezone.utc)
    return {
        "signatureValid": verification.returncode == 0,
        "entitlements": entitlements,
        "embeddedProfilePresent": profile_path.is_file(),
        "profileDecoded": bool(profile),
        "profileNotExpired": bool(expiry and expiry.replace(tzinfo=dt.timezone.utc) > now),
        "profileExpiresAt": expiry.isoformat() if expiry else None,
        "profileAppGroupMatches": profile.get("Entitlements", {}).get("com.apple.security.application-groups") == [GROUP],
        "profileApplicationIdentifierMatches": profile.get("Entitlements", {}).get("application-identifier") == entitlements.get("application-identifier"),
    }


def compiler_evidence(text: str) -> dict:
    modules: dict[str, list[dict]] = {"Previously": [], "PreviouslyWidgets": []}
    for line in text.splitlines():
        if "/swiftc " not in line or "-module-name " not in line:
            continue
        try:
            words = shlex.split(line)
        except ValueError:
            continue
        name = words[words.index("-module-name") + 1]
        if name not in modules:
            continue
        defines = []
        for index, word in enumerate(words):
            if word == "-D" and index + 1 < len(words):
                defines.append(words[index + 1])
            elif word.startswith("-D") and len(word) > 2:
                defines.append(word[2:])
        target = words[words.index("-target") + 1] if "-target" in words else ""
        output_map = words[words.index("-output-file-map") + 1] if "-output-file-map" in words else ""
        release_output = bool(re.search(r"/Release-iphoneos/" + re.escape(name) + r"\.build/", output_map))
        output_config = re.search(r"/([^/]+)-iphoneos/" + re.escape(name) + r"\.build/", output_map)
        modules[name].append({"defines": sorted(set(defines)), "target": target, "releaseObjectOutputPath": release_output,
                              "objectOutputConfiguration": output_config.group(1) if output_config else None})
    both = all(modules.values())
    no_qa = both and all(
        "PREVIOUSLY_QA" not in row["defines"] and "DEBUG" not in row["defines"]
        for rows in modules.values() for row in rows
    )
    device = both and all(re.fullmatch(r"arm64-apple-ios18(?:\.0)?", row["target"])
                             for rows in modules.values() for row in rows)
    cli_release = "-configuration Release" in text
    release_outputs = both and all(row["releaseObjectOutputPath"] for rows in modules.values() for row in rows)
    contradictory_output = any(row["objectOutputConfiguration"] not in (None, "Release") for rows in modules.values() for row in rows)
    return {
        "archiveSucceededMarker": "** ARCHIVE SUCCEEDED **" in text,
        "releaseConfigurationMarker": bool(release_outputs or (cli_release and not contradictory_output)),
        "releaseEvidence": {"CLIConfigurationArgument": cli_release, "bothModuleObjectOutputsUnderReleaseIPhoneOS": bool(release_outputs)},
        "bothRuntimeModulesObserved": both,
        "noQANorDebugDefinesInObservedCompilerInvocations": no_qa,
        "observedCompilerInvocationsTargetDeviceMin18": bool(device),
        "modules": modules,
        "boundary": "A supplied text log is evidence, not a cryptographic binding between source and binary. GUI logs need no CLI configuration or success banner: per-module Release-iphoneos object output paths identify configuration. Incremental builds can omit compiler invocations; missing evidence stays pending.",
    }


def production_metadata_checks(info: dict, previous: dict) -> dict:
    ats = info.get("NSAppTransportSecurity", {})
    broad_keys = ("NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsForMedia", "NSAllowsArbitraryLoadsInWebContent")
    exceptions = ats.get("NSExceptionDomains", {})
    return {
        "productionDisplayNameMatches16": bool(previous.get("CFBundleDisplayName") and info.get("CFBundleDisplayName") == previous["CFBundleDisplayName"]),
        "noQADisplayOrBundleName": all(not re.search(r"\bqa\b", str(info.get(key, "")), re.IGNORECASE) for key in ("CFBundleDisplayName", "CFBundleName", "CFBundleIdentifier")),
        "fileSharingAbsentOrFalse": info.get("UIFileSharingEnabled") in (None, False),
        "openingDocumentsInPlaceAbsentOrFalse": info.get("LSSupportsOpeningDocumentsInPlace") in (None, False),
        "supportEmailMatches16": bool(previous.get("SupportEmail") and info.get("SupportEmail") == previous["SupportEmail"]),
        "noArbitraryATSLoads": all(ats.get(key) in (None, False) for key in broad_keys) and all(
            row.get("NSExceptionAllowsInsecureHTTPLoads") in (None, False)
            and row.get("NSTemporaryExceptionAllowsInsecureHTTPLoads") in (None, False)
            for row in exceptions.values()
        ),
    }


def entitlement_checks(ent: dict, widget: bool) -> dict:
    identifier = APP_ID + (".widgets" if widget else "")
    return {
        "sharedGroupExact": ent.get("com.apple.security.application-groups") == [GROUP],
        "teamExact": ent.get("com.apple.developer.team-identifier") == TEAM,
        "applicationIdentifierExact": ent.get("application-identifier") == TEAM + "." + identifier,
        "appleSignInCorrectScope": "com.apple.developer.applesignin" not in ent if widget else ent.get("com.apple.developer.applesignin") == ["Default"],
    }


def find_app(archive: Path) -> Path:
    apps = list((archive / "Products" / "Applications").glob("*.app"))
    if len(apps) != 1:
        raise ValueError("Expected exactly one archived application")
    return apps[0]


def inspect(args: argparse.Namespace) -> dict:
    archive = args.archive.resolve(strict=True)
    baseline = args.baseline.resolve(strict=True)
    app, previous = find_app(archive), find_app(baseline)
    widgets = list((app / "PlugIns").glob("*.appex"))
    if len(widgets) != 1:
        raise ValueError("Expected exactly one embedded widget extension")
    widget = widgets[0]
    app_info, widget_info, prior_info = map(lambda p: load_plist(p / "Info.plist"), (app, widget, previous))
    root_info = load_plist(archive / "Info.plist")
    key, prior_key = app_info.get("ClerkPublishableKey", ""), prior_info.get("ClerkPublishableKey", "")
    checks = {
        "appBundle": app_info.get("CFBundleIdentifier") == APP_ID,
        "widgetBundle": widget_info.get("CFBundleIdentifier") == APP_ID + ".widgets",
        "version": app_info.get("CFBundleShortVersionString") == "1.0" and widget_info.get("CFBundleShortVersionString") == "1.0",
        "build": app_info.get("CFBundleVersion") == args.expected_build and widget_info.get("CFBundleVersion") == args.expected_build,
        "iPhoneOnly": app_info.get("UIDeviceFamily") == [1] and widget_info.get("UIDeviceFamily") == [1],
        "minimum18": app_info.get("MinimumOSVersion") == "18.0" and widget_info.get("MinimumOSVersion") == "18.0",
        "devicePlatform": all(i.get("DTPlatformName") == "iphoneos" and i.get("CFBundleSupportedPlatforms") == ["iPhoneOS"] for i in (app_info, widget_info)),
        "productionAPI": app_info.get("APIBaseURL") == "https://anime.cognipin.com",
        "canonicalPrivacy": app_info.get("PrivacyPolicyURL") == "https://previously.cognipin.com/privacy",
        "canonicalTerms": app_info.get("TermsURL") == "https://previously.cognipin.com/terms",
        "publicKeyLiveAndMatchesQualified16": bool(key.startswith("pk_live_") and prior_key.startswith("pk_live_") and key == prior_key),
        "baselineBuild16": prior_info.get("CFBundleVersion") == "16",
        "baselineProductionBundle": prior_info.get("CFBundleIdentifier") == APP_ID,
        "baselineSignatureValid": command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(previous)).returncode == 0,
        "nonExemptEncryptionFalse": app_info.get("ITSAppUsesNonExemptEncryption") is False,
        "widgetExtensionPoint": widget_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
    }
    checks.update(production_metadata_checks(app_info, prior_info))
    previous_widgets = list((previous / "PlugIns").glob("*.appex"))
    previous_widget_info = load_plist(previous_widgets[0] / "Info.plist") if len(previous_widgets) == 1 else {}
    checks["widgetProductionDisplayNameMatches16"] = bool(previous_widget_info.get("CFBundleDisplayName") and widget_info.get("CFBundleDisplayName") == previous_widget_info["CFBundleDisplayName"])
    checks["widgetNoQADisplayOrBundleName"] = all(not re.search(r"\bqa\b", str(widget_info.get(key, "")), re.IGNORECASE) for key in ("CFBundleDisplayName", "CFBundleName", "CFBundleIdentifier"))
    checks["widgetNoArbitraryATSLoads"] = production_metadata_checks(widget_info, previous_widget_info)["noArbitraryATSLoads"]
    targets = []
    for kind, bundle, info in (("app", app, app_info), ("widget", widget, widget_info)):
        sign = signing(bundle)
        checks.update({kind + key[0].upper() + key[1:]: value for key, value in entitlement_checks(sign["entitlements"], kind == "widget").items()})
        for field in ("signatureValid", "embeddedProfilePresent", "profileDecoded", "profileNotExpired", "profileAppGroupMatches", "profileApplicationIdentifierMatches"):
            checks[kind + field[0].upper() + field[1:]] = sign[field]
        binary = bundle / info["CFBundleExecutable"]
        arch_result = command("/usr/bin/lipo", "-archs", str(binary))
        architectures = arch_result.stdout.decode(errors="replace").split()
        checks[kind + "Arm64Only"] = arch_result.returncode == 0 and architectures == ["arm64"]
        macho = command("/usr/bin/otool", "-l", str(binary))
        build_versions = re.findall(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\d+)\s+minos ([\d.]+)", macho.stdout.decode(errors="replace"))
        checks[kind + "MachODeviceMin18"] = macho.returncode == 0 and build_versions == [("2", "18.0")]
        targets.append({"kind": kind, "bundle": str(bundle), "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                        "architectures": architectures, "binarySHA256": digest(binary), "infoSHA256": digest(bundle / "Info.plist"),
                        "sdk": info.get("DTSDKName"), "xcodeBuild": info.get("DTXcodeBuild"), "signing": sign})
    privacy = []
    actual_paths = {str(p.relative_to(app)) for p in app.rglob("PrivacyInfo.xcprivacy")}
    checks["exactExpectedPrivacyManifests"] = actual_paths == PRIVACY_PATHS
    for relative in sorted(actual_paths):
        path = app / relative
        item = load_plist(path)
        old = previous / relative
        privacy.append({"path": relative, "sha256": digest(path), "matchesQualified16": old.is_file() and digest(path) == digest(old)})
        checks["privacyNoTracking:" + relative] = item.get("NSPrivacyTracking", False) is False and not item.get("NSPrivacyTrackingDomains", []) and all(row.get("NSPrivacyCollectedDataTypeTracking") is False for row in item.get("NSPrivacyCollectedDataTypes", []))
    own_privacy = load_plist(app / "PrivacyInfo.xcprivacy")
    checks["appDeclaredDataTypesExact"] = {row.get("NSPrivacyCollectedDataType") for row in own_privacy.get("NSPrivacyCollectedDataTypes", [])} == DATA_TYPES
    checks["userDefaultsReasonCA92.1"] = any(row.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults" and "CA92.1" in row.get("NSPrivacyAccessedAPITypeReasons", []) for row in own_privacy.get("NSPrivacyAccessedAPITypes", []))
    if args.compiler_log and args.compiler_log.read_bytes().startswith(b"\x1f\x8b"):
        raise ValueError("An xcactivitylog needs structured parsing or a full text transcript; it is not plain text")
    compiler = compiler_evidence(args.compiler_log.read_text(errors="replace")) if args.compiler_log else None
    provenance = {"compilerLogPath": str(args.compiler_log.resolve()) if args.compiler_log else None,
                  "compilerLogSHA256": digest(args.compiler_log) if args.compiler_log else None,
                  "compilerEvidence": compiler, "sourceManifest": None}
    if args.source_manifest:
        manifest = json.loads(args.source_manifest.read_text())
        records = manifest["files"]
        root = args.repo.resolve()
        changed = []
        for record in records:
            relative = Path(record["path"])
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Source manifest paths must be repository-relative")
            path = root / relative
            if not path.is_file() or digest(path) != record["sha256"]:
                changed.append(str(relative))
        provenance["sourceManifest"] = {"path": str(args.source_manifest.resolve()), "sha256": digest(args.source_manifest), "fileCount": len(records), "currentFilesMatch": not changed, "changedPaths": changed}
    artifact_pass = all(checks.values())
    compile_pass = bool(compiler and all(compiler[key] for key in ("releaseConfigurationMarker", "bothRuntimeModulesObserved", "noQANorDebugDefinesInObservedCompilerInvocations", "observedCompilerInvocationsTargetDeviceMin18")))
    source_pass = bool(provenance["sourceManifest"] and provenance["sourceManifest"]["currentFilesMatch"])
    return {
        "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "archivePath": str(archive), "baselineArchivePath": str(baseline),
        "expectedBuild": args.expected_build, "archiveCreationDate": root_info.get("CreationDate"),
        "status": "artifact_checks_passed" if artifact_pass else "artifact_checks_failed", "checks": checks,
        "failedChecks": [name for name, passed in checks.items() if not passed], "targets": targets, "privacy": privacy,
        "provenance": provenance, "observedCompileConfigurationPassed": compile_pass, "suppliedSourceFreezeStillMatches": source_pass,
        "verifierSHA256": digest(Path(__file__)), "readOnly": True,
        "boundaries": [
            "Compile flags remain unverified without both app and widget compiler commands in a supplied Release archive log.",
            "A supplied source manifest proves only that its listed current files are unchanged. It does not independently bind those inputs to this Mach-O or attest the manifest's creation time or completeness.",
            "get-task-allow can be true in a development-signed archive. App Store distribution signing and Apple upload processing require separate receipts.",
            "An iPhoneOS archive cannot run in CoreSimulator. QA and production-configured Release simulator variants can share source/configuration but are different executables, entitlements and storage environments.",
            "This inspection does not prove physical-device widgets, real-account erasure, provider auth, launch success, TestFlight availability, Apple review or approval.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, default=Path("ios/build/Previously-16.xcarchive"))
    parser.add_argument("--expected-build", default="17")
    parser.add_argument("--compiler-log", type=Path)
    parser.add_argument("--source-manifest", type=Path, help="Optional pre-archive {files:[{path,sha256}]} receipt")
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--output", type=Path, help="New report only; refuses overwrite")
    args = parser.parse_args()
    try:
        report = inspect(args)
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException, subprocess.TimeoutExpired):
        # Suppress command text, raw plists and public key values on malformed inputs.
        print(json.dumps({"status": "inspection_error", "detail": "Missing or malformed archive, baseline, manifest, log or inspection output; no mutation performed."}))
        return 2
    serialized = json.dumps(report, indent=2, default=str) + "\n"
    if args.output:
        with args.output.open("x") as handle:
            handle.write(serialized)
    print(serialized, end="")
    return 0 if not report["failedChecks"] else 1


if __name__ == "__main__":
    sys.exit(main())
