"""Build 31 evidence pages plus an optional approved creative page; never infer deployment from tests."""
from pathlib import Path
from html import escape
from datetime import datetime, timezone
import hashlib, json, math, re
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import Paragraph
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
QA = ROOT / 'docs/qa/2026-10-06'
REVIEW_QA = ROOT / 'docs/qa/2026-10-07/app-store'
OUT = ROOT / 'output/pdf/previously-release-plan.pdf'
OUT.parent.mkdir(parents=True, exist_ok=True)
W, H = 1200, 800
INK, MUTED, PAPER = '#171719', '#66666D', '#F5F5F7'
ORANGE, GREEN, RED, BLUE = '#F26945', '#28745A', '#B83832', '#2465BA'
pdfmetrics.registerFont(TTFont('Arial', '/System/Library/Fonts/Supplemental/Arial.ttf'))
pdfmetrics.registerFont(TTFont('ArialBold', '/System/Library/Fonts/Supplemental/Arial Bold.ttf'))
pdfmetrics.registerFontFamily('Arial', normal='Arial', bold='ArialBold')
receipts = {}

def read_receipt(path):
    path = Path(path)
    if not path.is_absolute(): path = ROOT / path
    if path.is_dir(): path = path / 'results.json'
    if not path.exists(): return {}
    try:
        raw = path.read_bytes()
        data = json.loads(raw)
    except (OSError, ValueError) as exc:
        raise RuntimeError(f'Unusable evidence receipt: {path}') from exc
    receipts[str(path.relative_to(ROOT))] = hashlib.sha256(raw).hexdigest()
    return data

def count_text(path):
    path = ROOT / path
    if not path.exists(): return {'passed': None, 'failed': None, 'total': None, 'files': None}
    raw = path.read_bytes()
    receipts[str(path.relative_to(ROOT))] = hashlib.sha256(raw).hexdigest()
    text = re.sub(r'\x1b\[[0-9;]*m', '', raw.decode())
    lines = re.findall(r'^\s*Tests\s+(.+)$', text, re.M)
    files = re.findall(r'^\s*Test Files\s+(.+)$', text, re.M)
    def amount(line, state):
        match = re.search(r'(\d+)\s+' + state, line)
        return int(match.group(1)) if match else 0
    line = lines[-1] if lines else ''
    return {'passed': amount(line, 'passed') if line else None,
            'failed': amount(line, 'failed') if line else None,
            'total': int(re.search(r'\((\d+)\)', line).group(1)) if re.search(r'\((\d+)\)', line) else None,
            'files': int(re.search(r'\((\d+)\)', files[-1]).group(1)) if files and re.search(r'\((\d+)\)', files[-1]) else None}

def count_operator_text(path):
    path = ROOT / path
    if not path.exists(): return {}
    raw = path.read_bytes()
    receipts[str(path.relative_to(ROOT))] = hashlib.sha256(raw).hexdigest()
    text = raw.decode()
    def amount(name):
        match = re.search(r'^\s*ℹ\s+' + name + r'\s+(\d+)\s*$', text, re.M)
        return int(match.group(1)) if match else None
    return {'summary': {'passed': amount('pass'), 'failed': amount('fail'), 'total': amount('tests')}}

native = read_receipt(QA / 'native-results.json')
load = read_receipt(QA / 'load-testing/final-results.json')
ops = read_receipt(QA / 'operations/compiled-runtime-proof.json')
backup = read_receipt(QA / 'operations/production-apple-backup-restore.json') or read_receipt(QA / 'operations/production-backup-restore.json')
post_cutover_restore = read_receipt(QA / 'operations/post-clerk-cutover-backup-restore.json')
actual_cutover = read_receipt(QA / 'operations/clerk-production-cutover.json')
actual_operations = read_receipt(QA / 'operations/actual-installed-live-receipt.json')
review_account = read_receipt(QA / 'app-store/review-account-provisioned.json')
candidate14_native = read_receipt(QA / 'native-live/candidate14-production-native.json')
candidate14_files = read_receipt(QA / 'native-live/candidate14-files-pending.json')
candidate14_erasure = read_receipt(QA / 'native-live/candidate14-erasure-native.json')
candidate14_archive = read_receipt(QA / 'archive14/archive-receipt.json')
candidate14_upload = read_receipt(QA / 'archive14/upload-receipt.json')
candidate14_selected = read_receipt(QA / 'app-store/build14-selected-receipt.json')
review_notes = read_receipt(QA / 'app-store/review-notes-saved-receipt.json')
review_validation = read_receipt(QA / 'app-store/review-validation-receipt.json')
review_credentials = read_receipt(QA / 'app-store/review-credentials-saved-receipt.json')
review_ready_draft = read_receipt(QA / 'app-store/review-validation-after-credentials.json')
review_fresh_native = read_receipt(QA / 'native-live/review-otp-native-recheck.json')
review_rejection = read_receipt(REVIEW_QA / 'rejection-receipt.json')
review_response_draft = read_receipt(REVIEW_QA / 'response-draft-saved-receipt.json')
review_package = read_receipt(REVIEW_QA / 'review-package-prepared.json')
review_samples = read_receipt(REVIEW_QA / 'sample-package-receipt.json')
review_budget_check = read_receipt(REVIEW_QA / 'review-template-budget-check.json')
native_provider_entry = read_receipt(QA / 'native-live/provider-enabled-recheck/result.json')
owner_provider_test = read_receipt(QA / 'native-live/provider-owner-testflight.json')
testflight_group = read_receipt(QA / 'app-store/testflight-build14-existing-group.json')
clerk_management = read_receipt(QA / 'app-store/clerk-access-only-plan.json')
build13_auth_failure = read_receipt(QA / 'native-live/build13-production-signin-blocked.json')
artwork_upload = read_receipt(QA / 'app-store/campaign-artwork-uploaded-receipt.json')
owner_declarations = read_receipt(QA / 'app-store/owner-declarations-authorized.json')
erasure_live = read_receipt(QA / 'native-live/live-account-erasure-provisioned.json')
google_client_milestone = read_receipt(QA / 'app-store/google-client-created-secret-remediation.json')
google_secret_retirement = read_receipt(QA / 'app-store/google-original-secret-retirement.json')
portrait_exports = read_receipt(QA / 'app-store/campaign-portrait-export-format.json')
header_export = read_receipt(QA / 'app-store/campaign-header-export-format.json')
legacy_backup = read_receipt(QA / 'operations/legacy-backup-retired.json')
legacy_logs = read_receipt(QA / 'operations/legacy-log-files-secured.json')
legacy_logs_retired = read_receipt(QA / 'operations/legacy-log-files-retired.json')
migrations = read_receipt(QA / 'operations/production-apple-additive-migration.json') or read_receipt(QA / 'operations/production-additive-migrations.json')
clerk = read_receipt(QA / 'operations/clerk-migration-proof.json')
clerk_instance = read_receipt(QA / 'operations/clerk-instance-verified.json')
clerk_dns = read_receipt(QA / 'app-store/clerk-dns-verified.json')
domain_http = read_receipt(QA / 'app-store/previously-domain-https.json')
google_oauth = read_receipt(QA / 'app-store/google-oauth.json')
provider_activation = read_receipt(QA / 'app-store/clerk-provider-activation-public-readback.json')
provider_frontend = read_receipt(QA / 'app-store/provider-frontend-readback.json')
store_urls = read_receipt(QA / 'app-store/canonical-store-urls.json')
age_rating = read_receipt(QA / 'app-store/age-rating-saved.json')
apple_setup = read_receipt(QA / 'app-store/apple-sign-in.json')
privacy_draft = read_receipt(QA / 'app-store/privacy-draft-receipt.json')
privacy_device_draft = read_receipt(QA / 'app-store/device-id-privacy-draft-saved.json')
privacy_published = read_receipt(QA / 'app-store/privacy-published-receipt.json')
privacy_draft_category_count = (len(privacy_device_draft.get('collectedCategories', []))
    if privacy_device_draft.get('draftSaved') is True else len(privacy_draft.get('dataTypes', [])))
sdk_privacy = read_receipt(QA / 'sdk-privacy-audit.json')
campaign = read_receipt('docs/release/2026-10-06/campaign-assets.json')
# Empty placeholders keep campaign imagery out until root supplies final approved assets.
CAMPAIGN_PANEL_PLACEHOLDERS = ['Home / resume', 'Library / progress', 'Schedule / next', 'Discover / catalogue']
CANONICAL_NATIVE_ICON_PLACEHOLDER = 'docs/qa/2026-10-06/archive13/native-icon-152.png'
current_artifact = read_receipt(QA / 'operations/apple-policy-artifact/artifact-manifest.json')
prod_audit = read_receipt(QA / 'operations/apple-policy-artifact/production-audit.json') or read_receipt(QA / 'operations/artifact-production-audit.json')
landing = read_receipt(QA / 'landing-release/vercel-production/promotion-receipt.json')
draft_candidates = []
for receipt_path in sorted({*list((QA/'landing-final').rglob('qualification-receipt.json')),
        *list((QA/'branding').rglob('qualification-receipt.json'))}):
    candidate = read_receipt(receipt_path)
    if (candidate.get('qualifiedDraftPublication') is True
            and candidate.get('canonicalOrigin') == 'https://previously.cognipin.com'
            and candidate.get('canonicalAliasMatchesCandidate') is True):
        dated = candidate.get('checkedAt') or candidate.get('promotedAt')
        if not dated: raise RuntimeError(f'Qualified landing receipt lacks a timestamp: {receipt_path}')
        draft_candidates.append((datetime.fromisoformat(dated.replace('Z','+00:00')),
            str(receipt_path.relative_to(QA)), candidate))
draft_landing_receipt, draft_landing = ('landing-final/draft-publication/qualification-receipt.json', {})
if draft_candidates:
    _, draft_landing_receipt, draft_landing = max(draft_candidates, key=lambda item:item[0])
effective_landing_receipt = 'landing-final/effective-publication/qualification-receipt.json'
effective_landing = read_receipt(QA / effective_landing_receipt)
public_http = read_receipt(QA / 'landing-release/vercel-production/public-http-assets.json')
public_browser = read_receipt(QA / 'landing-release/vercel-production/public-browser/browser-report.json')
release = read_receipt('docs/release/2026-10-06/release-status.json')
store_build = release.get('appStore', {}).get('finalBuild', 13)
upload_receipt = read_receipt(QA / f'archive{store_build}/upload-receipt.json')
selected_build_receipt = read_receipt(QA / f'app-store/build{store_build}-selected-receipt.json')
replacement_archive = read_receipt(QA / f'archive{store_build}/archive-receipt.json') if store_build != 13 else {}
units = count_text('docs/qa/2026-10-06/server-unit-final.txt')
qualified_units = read_receipt(QA / 'apple-deletion/unit-qualified.json')
if qualified_units:
    units = {'passed': qualified_units.get('numPassedTests'), 'failed': qualified_units.get('numFailedTests'),
        'total': qualified_units.get('numTotalTests'), 'files': len(qualified_units.get('testResults', []))}
ops_qualified = count_operator_text('docs/qa/2026-10-06/apple-deletion/ops-final-qualified.log')
protocol_path = load.get('sqlEvidence', {}).get('protocolPath') or 'docs/qa/2026-10-06/progress-faults/compiled-node24-apple-policy/results.json'
recovery_path = load.get('sqlEvidence', {}).get('recoveryPath') or 'docs/qa/2026-10-06/deletion-recovery/compiled-node24-apple-policy/results.json'
protocol = read_receipt(protocol_path)
recovery = read_receipt(recovery_path)
content_policy = read_receipt(QA / 'content-policy/compiled-node24-apple-policy/results.json')
deletion = read_receipt(QA / 'deletion-faults/qualified-node24-current/results.json')
status_recovery = read_receipt(QA / 'deletion-status-recovery/2026-10-06T11-13-37.432Z/results.json')
load_passed = load.get('qualified') is True and load.get('qualification') == 'passed'
load_state = 'PASSED' if load_passed else 'FAILED' if load.get('qualification') == 'failed' else 'PENDING'
prior_load = read_receipt(load['previousQualifiedReceiptPath']) if load.get('previousQualifiedReceiptPath') else {}
passed_seeds = list({str(s.get('seed')): s for s in native.get('seeds', [])
    if isinstance(s, dict) and s.get('seed') is not None
    and (s.get('status') == 'passed' or s.get('passed') is True)}.values())
seed_ids = {str(s.get('seed')) for s in native.get('seeds', []) if isinstance(s, dict) and s.get('seed') is not None}
seed_ids.update(str(s) for s in native.get('pendingSeeds', []))
seed_target = max(len(seed_ids), 3)
backend_live = release.get('backend', {}).get('productionCutoverVerified') is True
jobs_live = release.get('operations', {}).get('jobsInstalledVerified') is True
identities_migrated = (actual_cutover.get('realIdentitiesMigrated') == 4
    and actual_cutover.get('fullOwnedDataPreserved') is True)
post_cutover_restored = (post_cutover_restore.get('productionMappingsRestored') == 4
    and post_cutover_restore.get('bothOwnedScratchDatabasesRemoved') is True)
submitted = release.get('appStore', {}).get('submittedForReviewVerified') is True
review_rejected_verified = (review_rejection.get('appId') == '6818452741'
    and review_rejection.get('version') == '1.0'
    and review_rejection.get('build') == store_build
    and review_rejection.get('versionState') == 'Rejected'
    and review_rejection.get('submissionState') == 'Unresolved Issues'
    and review_rejection.get('specificCrashOrLoginDefectReported') is False
    and release.get('appStore', {}).get('submissionId') == review_rejection.get('submissionId')
    and release.get('appStore', {}).get('versionStatus') == 'Rejected')
review_response_draft_verified = (review_rejected_verified
    and review_response_draft.get('submissionId') == review_rejection.get('submissionId')
    and all(review_response_draft.get(name) is True for name in (
        'draftSavedVerified','draftContinueAndDeleteControlsObserved','allSixQuestionsCovered'))
    and review_response_draft.get('replySent') is False
    and review_response_draft.get('resubmitted') is False)
review_response_length = review_response_draft.get('bodyCharsIncludingTrailingNewline',0)
response_body_path = ROOT / review_response_draft.get('template','docs/release/2026-10-07/apple-review-response.txt')
prepared_notes_bytes = None
if review_response_draft_verified:
    response_body_bytes = response_body_path.read_bytes()
    response_body_sha = hashlib.sha256(response_body_bytes).hexdigest()
    if (response_body_sha != review_response_draft.get('bodySHA256')
            or len(response_body_bytes.decode()) != review_response_length):
        raise RuntimeError('Saved Apple reply draft does not match its public receipt.')
    receipts[str(response_body_path.relative_to(ROOT))] = response_body_sha
    prepared_notes_path = ROOT / 'docs/release/2026-10-07/apple-review-notes.txt'
    prepared_notes_bytes = prepared_notes_path.read_bytes()
    if prepared_notes_bytes != response_body_bytes:
        raise RuntimeError('Prepared Apple Notes template differs from the saved public reply draft.')
    receipts[str(prepared_notes_path.relative_to(ROOT))] = hashlib.sha256(prepared_notes_bytes).hexdigest()
apple_physical_recording_required = (review_rejected_verified
    and any('Physical-device latest-OS screen recording' in item
        for item in review_rejection.get('requiredEvidence',[])))
consumer_ready = release.get('consumerReadyVerified') is True
candidate14_password_verified = (candidate14_native.get('candidate') == 14
    and candidate14_native.get('configuration') == 'Release'
    and candidate14_native.get('qaFixtureUsed') is False
    and all(candidate14_native.get(k) is True for k in (
    'productionPublicConfigurationVerified', 'ordinaryProductionReviewPasswordSignInPassed',
    'coldRestorePassed', 'signOutPassed', 'reloginPassed')))
provider_connections_enabled = (provider_frontend.get('productionFrontendOrigin') == 'clerk.previously.cognipin.com'
    and provider_frontend.get('bothProviderSignInFlagsEnabled') is True
    and provider_activation.get('productionInstance') == 'ins_3KJtgHKq296iry2eBmj1IkEQmpQ'
    and all(provider_frontend.get(name,{}).get('enabled') is True
        and provider_frontend.get(name,{}).get('authenticatable') is True
        and provider_frontend.get(name,{}).get('strategy') == strategy
        and 'Enabled' in provider_activation.get(name,{}).get('publicStatuses',[])
        for name,strategy in [('google','oauth_google'),('apple','oauth_apple')]))
native_provider_entry_verified = (provider_connections_enabled
    and native_provider_entry.get('app',{}).get('build') == '14'
    and native_provider_entry.get('app',{}).get('version') == '1.0'
    and native_provider_entry.get('app',{}).get('runtimeSourceSha256') == candidate14_native.get('runtimeSourceSHA256')
    and native_provider_entry.get('context',{}).get('configuration') == 'Release'
    and native_provider_entry.get('coldLaunchCompleted') is True
    and native_provider_entry.get('qaFixtureUsed') is False
    and native_provider_entry.get('providerButtons',{}).get('googleVisible') is True
    and native_provider_entry.get('providerButtons',{}).get('appleVisible') is True
    and native_provider_entry.get('google',{}).get('destinationHost') == 'accounts.google.com'
    and native_provider_entry.get('google',{}).get('emptyEmailOrPhoneFieldShown') is True
    and native_provider_entry.get('apple',{}).get('systemAppleAccountPrerequisiteShown') is True)
testflight_group_verified = (testflight_group.get('appId') == '6818452741'
    and testflight_group.get('version') == '1.0' and testflight_group.get('build') == 14
    and testflight_group.get('existingInternalGroup') == 'Friends & Family'
    and testflight_group.get('groupOrInvitesModified') is False)
owner_provider_test_reported = (provider_connections_enabled
    and owner_provider_test.get('evidenceMethod') == 'Direct owner report in this chat'
    and owner_provider_test.get('ownerSelectedPath') == 'Existing iPhone via TestFlight'
    and owner_provider_test.get('requestedVersion') == '1.0'
    and owner_provider_test.get('requestedBuild') == 14
    and owner_provider_test.get('googleSignInPassedOwnerReported') is True
    and owner_provider_test.get('appleSignInPassedOwnerReported') is True)
candidate14_auth_summary = ('Build 14 password cycle passed; owner reports both TestFlight SSO logins passed.'
    if candidate14_password_verified and owner_provider_test_reported
    else 'Build 14 password cycle passed; provider entry reached, SSO sessions unverified.'
    if candidate14_password_verified and native_provider_entry_verified
    else 'Build 14 password cycle passed; SSO connections enabled, sessions unverified.'
    if candidate14_password_verified and provider_connections_enabled
    else 'Build 14 password cycle passed; Google/Apple SSO pending.'
    if candidate14_password_verified else 'Actual production password and provider sign-in remain.')
legacy_log_retirement_verified = (legacy_logs_retired.get('bothRemovedVerified') is True
    and len(legacy_logs_retired.get('files',[])) == 2
    and {Path(f.get('path','')).name for f in legacy_logs_retired.get('files',[])} == {
        'com.shan.previously.out.log','com.shan.previously.err.log'}
    and all(f.get('removedVerified') is True and f.get('writerPresentAtDeletion') is False
        for f in legacy_logs_retired.get('files',[])))
legacy_log_summary = ('Two historical logs retired with owner approval.' if legacy_log_retirement_verified
    else 'Two historical logs remain restricted pending retirement.')
candidate14_files_verified = (candidate14_files.get('candidate') == 14
    and candidate14_files.get('noQAFixtureOrBackendOverride') is True
    and all(candidate14_files.get(k) is True for k in (
        'partialImportPreviewPassed', 'partialImportApplyPassed',
        'allSkippedPreviewPassed', 'saveToFilesExportPassed')))
candidate14_files_summary = ('Native Files import/export passed.' if candidate14_files_verified
    else 'Files sheet shown; selection/import/export proof pending.'
    if candidate14_files.get('ordinaryFilesSheetPresented') is True
    else 'Actual native Files import/export proof pending.')
candidate14_erasure_summary = ('Isolated QA deletion executed; provider/restart proof separate.'
    if candidate14_erasure.get('permanentDeletionExecuted') is True
    else 'Earlier QA attempt closed; consumer deletion remains unverified.'
    if review_fresh_native.get('disposableAttemptClosedUnderRootAuthorization') is True
        and candidate14_erasure.get('disposablePasswordLoginPassed') is not True
    else 'Isolated QA login passed; deletion remains.'
    if candidate14_erasure.get('disposablePasswordLoginPassed') is True
    else 'Isolated QA password accepted; Device Trust challenge pending.'
    if candidate14_erasure.get('disposablePasswordAccepted') is True
    else 'Isolated QA login in progress; no deletion performed.')
owner_declarations_verified = (owner_declarations.get('appStoreUiSavedVerified') is True
    and owner_declarations.get('contentRightsSurvivedReload') is True
    and owner_declarations.get('euDistributionStatus') == 'non-trader')
artwork_saved_verified = (artwork_upload.get('savedAndReloadedVerified') is True
    and artwork_upload.get('portraitCountAfterReload') == 4
    and artwork_upload.get('headerCountAfterReload') == 1)
privacy_labels_published = (privacy_published.get('publishedVerified') is True
    and privacy_published.get('persistedAfterReloadVerified') is True
    and privacy_published.get('appId') == '6818452741'
    and privacy_published.get('version') == '1.0'
    and privacy_published.get('categoryCount') == privacy_draft_category_count)
privacy_label_state = 'published' if privacy_labels_published else 'saved draft'
review_notes_saved = (review_notes.get('notesSavedVerified') is True
    and review_notes.get('persistedAfterReloadVerified') is True
    and review_notes.get('appId') == '6818452741' and review_notes.get('version') == '1.0')
review_draft_validated = (review_ready_draft.get('appId') == '6818452741'
    and review_ready_draft.get('version') == '1.0'
    and review_ready_draft.get('selectedBuild') == store_build
    and review_ready_draft.get('selectedVersion') == '1.0'
    and review_ready_draft.get('versionStatus') == 'Ready for Review'
    and review_ready_draft.get('draftCreated') is True
    and review_ready_draft.get('submitForReviewEnabled') is True
    and review_ready_draft.get('priorRequiredCredentialErrorsResolved') is True
    and review_ready_draft.get('submitted') is False)
review_credentials_saved = (review_draft_validated
    and review_credentials.get('appId') == '6818452741'
    and review_credentials.get('version') == '1.0'
    and review_credentials.get('selectedBuild') == store_build
    and review_credentials.get('reviewCredentialsSavedVerified') is True
    and review_credentials.get('persistedAfterReloadVerified') is True
    and review_credentials.get('usernamePopulated') is True
    and review_credentials.get('passwordPopulated') is True
    and review_credentials.get('saveDisabled') is True
    and review_credentials.get('approvedFillActions',{}).get('username') is True
    and review_credentials.get('approvedFillActions',{}).get('password') is True)
current_review_notes_saved = (review_credentials_saved
    and review_credentials.get('notesSavedVerified') is True
    and review_credentials.get('notesPersistedExact') is True
    and bool(review_credentials.get('notesSHA256')))
if current_review_notes_saved:
    review_notes_saved = True
review_notes_length = (review_credentials.get('notesLength')
    if current_review_notes_saved else review_notes.get('notesCharacterCount'))
reviewer_fresh_no_otp_verified = (candidate14_password_verified
    and review_fresh_native.get('candidate') == 14
    and review_fresh_native.get('configuration') == 'Release'
    and review_fresh_native.get('qaFixtureUsed') is False
    and review_fresh_native.get('runtimeSourceSHA256') == candidate14_native.get('runtimeSourceSHA256')
    and review_fresh_native.get('coldFreshRepeatPassed') is True
    and all(attempt.get('passwordLoginPassed') is True
        and attempt.get('firstFactorEmailCodeRequested') is False
        and attempt.get('secondOTPChallengeObserved') is False
        and attempt.get('OTPEntered') is False
        for attempt in (review_fresh_native.get('firstFreshReviewerAttempt',{}),
                        review_fresh_native.get('coldRetry',{}))))
candidate14_archive_verified = (candidate14_archive.get('build') == 14
    and candidate14_archive.get('version') == '1.0'
    and candidate14_archive.get('signatureVerifyPassed') is True
    and candidate14_archive.get('liveClerkPublicKeyMatchesPreparedConfiguration') is True
    and candidate14_archive.get('uidDeviceFamily') == [1]
    and candidate14_archive.get('knownQAFixtureMarkersAbsent') is True
    and bool(candidate14_native.get('runtimeSourceSHA256'))
    and candidate14_archive.get('runtimeSourceSHA256') == candidate14_native.get('runtimeSourceSHA256'))
candidate14_upload_verified = (candidate14_archive_verified
    and candidate14_upload.get('build') == 14 and candidate14_upload.get('version') == '1.0'
    and bool(candidate14_archive.get('archivePath'))
    and candidate14_upload.get('archivePath') == candidate14_archive.get('archivePath')
    and candidate14_upload.get('persistentArchiveStatus') == 'Uploaded to Apple'
    and candidate14_upload.get('submissionStatus') == 'Uploaded')
candidate14_selected_matches = (candidate14_selected.get('build') == 14
    and candidate14_selected.get('version') == '1.0')
candidate14_processing_verified = ((candidate14_upload_verified
    and candidate14_upload.get('appStoreProcessingVerified') is True)
    or (candidate14_selected_matches
        and candidate14_selected.get('processingCompleteVerified') is True))
candidate14_selected_verified = (candidate14_selected_matches
    and candidate14_selected.get('selectedOnVersionVerified') is True
    and candidate14_selected.get('savedAndReloadVerified') is True)
candidate14_store_stage = ('processed/selected' if candidate14_selected_verified and candidate14_processing_verified
    else 'selected' if candidate14_selected_verified else 'uploaded' if candidate14_upload_verified
    else 'signed archive' if candidate14_archive_verified else 'archive/upload pending')
native_predispatch_verified = native.get('preDispatchPersistenceVerified') is True
native_monitor_verified = native.get('monitorRestartVerified') is True
native_directed_verified = (isinstance(native.get('directedSelectedTotal'), int)
    and native.get('directedSelectedTotal', 0) > 0
    and native.get('directedSelectedPassed') == native.get('directedSelectedTotal')
    and native.get('directedFailed') == 0 and native.get('directedSkipped') == 0)
native_seeds_verified = (len(passed_seeds) == seed_target
    and native.get('qualificationStatus') == 'passed' and not native.get('pendingSeeds'))
production_archive = (native.get('productionArchive', {}) if store_build == 13
    else replacement_archive)
archive_verified = (production_archive.get('build') == store_build
    and production_archive.get('version') == '1.0'
    and production_archive.get('signatureVerifyPassed') is True
    and production_archive.get('liveClerkPublicKeyMatchesPreparedConfiguration') is True
    and production_archive.get('uidDeviceFamily') == [1])
upload_verified = (archive_verified and upload_receipt.get('build') == store_build
    and upload_receipt.get('version') == production_archive.get('version')
    and bool(production_archive.get('archivePath'))
    and upload_receipt.get('archivePath') == production_archive.get('archivePath')
    and upload_receipt.get('persistentArchiveStatus') == 'Uploaded to Apple'
    and upload_receipt.get('submissionStatus') == 'Uploaded')
selected_receipt_matches_build = (selected_build_receipt.get('build') == store_build
    and selected_build_receipt.get('version') == '1.0')
upload_processing_verified = ((upload_verified
    and upload_receipt.get('appStoreProcessingVerified') is True)
    or (selected_receipt_matches_build
        and selected_build_receipt.get('processingCompleteVerified') is True))
selected_build_verified = (selected_receipt_matches_build
    and selected_build_receipt.get('selectedOnVersionVerified') is True
    and selected_build_receipt.get('savedAndReloadVerified') is True)
store_stage = ('processed/selected' if selected_build_verified and upload_processing_verified
    else 'selected' if selected_build_verified else 'uploaded' if upload_verified
    else 'archive/upload pending')
sdk_archive_inventory = sdk_privacy.get(f'archive{store_build}Inventory', {})
sdk_archive_verified = (isinstance(sdk_archive_inventory, dict)
    and sdk_archive_inventory.get('status') == 'verified'
    and sdk_archive_inventory.get('count') == 4
    and sdk_privacy.get(f'actualArchive{store_build}', {}).get('appManifestMatchesApprovedShippingHash') is True)
clerk_instance_verified = clerk_instance.get('environmentType') == 'production' and clerk_instance.get('keyVerified') is True
clerk_dns_verified = clerk_dns.get('clerkDashboardAllFiveVerified') is True
domain_verified = domain_http.get('origin') == 'https://previously.cognipin.com' and domain_http.get('allExpected') is True
google_verified = google_oauth.get('productionSignInVerified') is True
google_secret_retirement_verified = (google_oauth.get('originalSecretRetirement') == 'disabled_and_deleted_verified_after_reload'
    and google_secret_retirement.get('verifiedAfterReload') is True
    and google_secret_retirement.get('original',{}).get('permanentlyDeleted') is True
    and google_secret_retirement.get('original',{}).get('presentAfterReload') is False
    and google_secret_retirement.get('replacement',{}).get('presentAfterReload') is True
    and google_secret_retirement.get('replacement',{}).get('statusAfterReload') == 'Enabled'
    and google_secret_retirement.get('replacement',{}).get('unchanged') is True)
google_setup_verified = (google_oauth.get('clientCreated') is True
    and google_oauth.get('audience') == 'External'
    and google_oauth.get('publishingStatus') == 'In production'
    and set(google_oauth.get('googleConsentScopesConfigured', [])) == {
        'openid', 'https://www.googleapis.com/auth/userinfo.email',
        'https://www.googleapis.com/auth/userinfo.profile'}
    and google_oauth.get('gmailMailboxScopes') is False
    and not google_oauth.get('sensitiveScopes') and not google_oauth.get('restrictedScopes'))
google_setup_summary = ('Google consent/client in production; three basic identity scopes saved.'
    if google_setup_verified else 'Google consent/client setup remains.')
clerk_personal_api_blocked = (clerk_management.get('managementHTTP') == 401
    and clerk_management.get('missingClaimNames') == ['org_id']
    and clerk_management.get('actualWorkspace') == 'Personal workspace'
    and clerk_management.get('providerMutationPerformed') is False)
review_credentials_required = (not review_draft_validated
    and review_validation.get('appId') == '6818452741'
    and review_validation.get('selectedBuild') == store_build
    and review_validation.get('validationErrors') == [
        'User name - This field is required', 'Password - This field is required']
    and review_validation.get('submittedForReview') is False)
store_urls_verified = store_urls.get('versionLinksSaved') is True and store_urls.get('privacyLinksSaved') is True
age_rating_verified = age_rating.get('questionnaireSaved') is True
apple_relay_verified = apple_setup.get('privateRelaySenderRegistered') is True and apple_setup.get('privateRelaySenderSpfVerified') is True
apple_migration_verified = migrations.get('migration') == '0015_exotic_ezekiel' and migrations.get('dataUnchanged') is True
trailer_verified = native.get('trailerPrivacyLiveValidation', {}).get('status') == 'passed'
draft_landing_verified = (draft_landing.get('qualifiedDraftPublication') is True
    and draft_landing.get('canonicalOrigin') == 'https://previously.cognipin.com'
    and draft_landing.get('canonicalAliasMatchesCandidate') is True)
effective_policy_verified = (effective_landing.get('effectivePolicyPublished') is True
    and effective_landing.get('draft') is False
    and effective_landing.get('effectiveDate') == '6 October 2026'
    and effective_landing.get('canonicalOrigin') == 'https://previously.cognipin.com'
    and effective_landing.get('deploymentState') == 'READY'
    and effective_landing.get('target') == 'production'
    and effective_landing.get('canonicalAliasMatchesCandidate') is True
    and effective_landing.get('canonicalRouteBytesMatchVerifiedCandidate') == 8
    and effective_landing.get('publicAssetHashMatchesPerOrigin') == 27
    and effective_landing.get('historicalLogsAbsentVerified') is True
    and legacy_log_retirement_verified)
public_landing = effective_landing if effective_policy_verified else draft_landing
public_landing_receipt = effective_landing_receipt if effective_policy_verified else draft_landing_receipt
public_landing_verified = effective_policy_verified or draft_landing_verified
landing_fresh_layouts = draft_landing.get('freshHeroLayouts',
    draft_landing.get('freshResponsiveLayouts', draft_landing.get('newLegalMobileBrowserChecks')))
landing_fresh_layout_label = ('Fresh hero layouts' if 'freshHeroLayouts' in draft_landing
    else 'Fresh responsive layouts' if 'freshResponsiveLayouts' in draft_landing
    else 'New privacy mobile checks' if draft_landing.get('newPrivacyMobileBrowserChecks')
    else 'New legal mobile checks')
landing_fresh_gallery = draft_landing.get('freshHeroGalleryFlowChecks',
    draft_landing.get('newGalleryImageDialogAndSettledFocusChecks', 0))
landing_prior_home_refs = draft_landing.get('priorHomeUiReferenceRunSize', draft_landing.get('priorHomeUiChecksReused'))
landing_prior_device_refs = draft_landing.get('priorDeviceParagraphChecksReused', 0)
landing_prior_brand_layouts = draft_landing.get('priorBrandingResponsiveChecksReused', 0)
landing_prior_brand_gallery = draft_landing.get('priorBrandingGalleryChecksReused', 0)
for evidence_path in ['docs/release/2026-10-06/identity-cutover-recovery.md',
        'docs/qa/2026-10-06/operations/usage-semantics.md',
        'docs/release/2026-10-06/app-review-access-plan.md',
        'docs/release/2026-10-07/physical-device-recording-guide.md',
        'docs/release/2026-10-07/apple-review-response-draft.md']:
    evidence_file = ROOT / evidence_path
    if evidence_file.exists(): receipts[evidence_path] = hashlib.sha256(evidence_file.read_bytes()).hexdigest()
sealed_baseline_qualified = (load_passed and native_directed_verified and native_seeds_verified
    and units.get('failed') == 0 and native_predispatch_verified and native_monitor_verified)
campaign_assets_verified = False
campaign_panels = []
campaign_icon = None
if campaign.get('approvedForDossier') is True:
    campaign_panels = campaign.get('panels', [])
    campaign_icon = campaign.get('nativeIcon', {})
    if len(campaign_panels) != 4:
        raise RuntimeError('Approved campaign requires exactly four final portrait panels.')
    if campaign_icon.get('path') != CANONICAL_NATIVE_ICON_PLACEHOLDER:
        raise RuntimeError('Campaign must use the canonical icon extracted from production archive13.')
    for visual in [*campaign_panels, campaign_icon]:
        if Path(visual.get('path', '')).is_absolute():
            raise RuntimeError('Approved campaign asset paths must be relative to the project.')
        visual_path = (ROOT / visual.get('path', '')).resolve()
        if not visual_path.is_relative_to(ROOT) or not visual_path.is_file():
            raise RuntimeError('Approved campaign asset is missing or outside the project.')
        actual_sha = hashlib.sha256(visual_path.read_bytes()).hexdigest()
        if visual.get('sha256') != actual_sha:
            raise RuntimeError(f'Approved campaign asset hash differs: {visual_path.relative_to(ROOT)}')
        receipts[str(visual_path.relative_to(ROOT))] = actual_sha
    campaign_assets_verified = True

def tally(passed, total):
    return f'{passed:,} / {total:,}' if isinstance(passed, int) and isinstance(total, int) else 'Pending'
def summary_count(receipt):
    s = receipt.get('summary', {})
    return tally(s.get('passed'), s.get('total'))
def number(value, digits=0):
    return f'{value:,.{digits}f}' if isinstance(value, (int, float)) else '—'

def sync_evidence_companion(snapshot):
    evidence_path = HERE / 'evidence.json'
    prior = json.loads(evidence_path.read_text()) if evidence_path.exists() else {}
    historical = prior.get('historical_authoring_snapshot', prior)
    current = {
        'schemaVersion':2, 'revision_date':'2026-10-07',
        'scope':'Current PDF release snapshot; earlier authoring evidence is preserved below as historical and is not a current deployment claim.',
        'requested_outcome':'consumer-ready production iPhone app and exact final build actually submitted for App Store review',
        'original_snapshot':prior.get('original_snapshot',{}),
        'current_release_snapshot':snapshot,
        'provider_login_evidence_scope':'Owner-reported iPhone/TestFlight Google and Apple login PASS is separate from independently captured simulator entry checkpoints. Phone OS/model/build screen and authenticated session were not independently captured.',
        'retention_scope':snapshot.get('managedDiagnosticRetentionScope'),
        'receipt_paths':sorted(snapshot.get('receiptSha256',{})),
        'review_state_scope':'Owner submitted build 14 on 6 October. Current 7 October App Store status is Rejected / Unresolved Issues. Apple requests six information items and a physical-device latest-OS recording. The saved reply is an unsent draft; existing Review Notes have not been replaced.',
        'not_verified':['Apple-requested physical-device latest-OS recording','Completed review response sent, updated Review Notes and resubmission after rejection','Native consumer erasure and real Apple grant revocation','Native Files import/export completion','Minimum iOS18 and VoiceOver behavior','Independent physical/network/cold-restore qualification beyond the owner login report','Truthful eligibility of every selected storefront','Consumer-ready outcome'],
        'refreshed_pdf_status':{'pages':snapshot.get('pages'),'pdfSha256':snapshot.get('pdfSha256'),'builtAtUTC':snapshot.get('builtAtUTC'),'layoutIssues':snapshot.get('layoutIssues'),'visualReviewReceipt':'pdf-review-current.json'},
        'historical_authoring_snapshot':historical}
    evidence_path.write_text(json.dumps(current,indent=2)+'\n')

c = canvas.Canvas(str(OUT), pagesize=(W, H), pageCompression=1)
c.setTitle('Previously. The consumer release. | Revised 7 October 2026')
c.setAuthor('Prepared for Shantanu Sinha')
c.setSubject('Global iPhone release, zero new recurring spend, production readiness and actual review submission')
page_no = 0
checks = []
md = ['# Previously. The consumer release.',
      'Revised 7 October 2026. Original planning snapshot: main at 19649b3, 5 October. New qualification applies to the changed working tree and the artifacts named in the receipts.',
      'Outcome: a production-ready consumer app and the exact final build actually submitted for App Store review. Code qualification, deployed service, physical-device evidence and store submission are separate states. No provider licensing gate or outreach before market validation.']

def rect(x, y, w, h, fill, rad=0, stroke=None):
    c.setFillColor(HexColor(fill)); c.setStrokeColor(HexColor(stroke or fill))
    if rad: c.roundRect(x, H-y-h, w, h, rad, fill=1, stroke=bool(stroke))
    else: c.rect(x, H-y-h, w, h, fill=1, stroke=bool(stroke))
def line(x, y, x2, y2, color='#DADADD', width=1):
    c.setStrokeColor(HexColor(color)); c.setLineWidth(width); c.line(x, H-y, x2, H-y2)
def txt(s, x, y, size=18, color=INK, font='Arial', w=None, leading=None, record=True):
    s = str(s)
    if record: md.append(s.replace('<br/>', '\n').replace('<b>', '').replace('</b>', ''))
    if w is None:
        c.setFillColor(HexColor(color)); c.setFont(font, size); c.drawString(x, H-y-size*.82, s)
        if x+pdfmetrics.stringWidth(s, font, size)>W-36: checks.append(f'p{page_no} horizontal overflow: {s[:70]}')
        return size*1.25
    p = Paragraph(s.replace('\n', '<br/>'), ParagraphStyle('p', fontName=font, fontSize=size,
        leading=leading or size*1.37, textColor=HexColor(color), spaceAfter=0))
    _, hh = p.wrap(w, 1000); p.drawOn(c, x, H-y-hh)
    if y+hh>742: checks.append(f'p{page_no} vertical overflow at {y+hh:.0f}: {s[:65]}')
    return hh
def small(s, x=64, y=711, w=1060, color=MUTED): return txt(s, x, y, 11, color, w=w, leading=14, record=False)
def heading(kicker, title, subtitle=None, dark=False):
    global page_no
    page_no += 1
    rect(0, 0, W, H, INK if dark else PAPER)
    c.bookmarkPage(f'p{page_no}'); c.addOutlineEntry(title, f'p{page_no}', level=0)
    md.extend(['', f'## {page_no:02d} · {title}', ''])
    txt(kicker.upper(), 64, 38, 12, ORANGE, 'ArialBold', record=False)
    size = min(44, 1072 / max(pdfmetrics.stringWidth(title, 'ArialBold', 1), 1))
    txt(title, 64, 81, size, '#FFFFFF' if dark else INK, 'ArialBold', record=False)
    if subtitle: txt(subtitle, 64, 142, 18, '#BDBDC6' if dark else MUTED, w=1050)
    line(64, 756, 1136, 756, '#3A3A3E' if dark else '#DADADD')
    txt('PREVIOUSLY.  /  CONSUMER RELEASE', 64, 772, 10, '#ABABB5' if dark else MUTED, record=False)
    txt('REV. 07 OCT 2026', 922, 772, 10, '#ABABB5' if dark else MUTED, record=False)
    txt(f'{page_no:02d}', 1115, 770, 12, ORANGE, 'ArialBold', record=False)
def end(): c.showPage()
def label(s, x, y, color=ORANGE): txt(s.upper(), x, y, 11, color, 'ArialBold', record=False)
def bullet(title, body, x, y, w=480, dark=False):
    txt(title, x, y, 20, '#FFFFFF' if dark else INK, 'ArialBold')
    return txt(body, x, y+31, 16, '#BDBDC6' if dark else MUTED, w=w)+40
def node(x, y, w, h, title, body='', fill='#FFFFFF', accent=INK):
    rect(x, y, w, h, fill, 16)
    txt(title, x+22, y+20, 19, accent, 'ArialBold', w=w-44)
    if body: txt(body, x+22, y+54, 14, MUTED, w=w-44)
def arrow(x, y, x2, y2, color=ORANGE):
    line(x, y, x2, y2, color, 2)
    angle=math.atan2(y2-y, x2-x)
    for a in [angle+2.55, angle-2.55]: line(x2, y2, x2+9*math.cos(a), y2+9*math.sin(a), color, 2)
def table(headers, rows, widths, x=64, y=218, rowh=65, fs=15):
    xx=x
    for h,w in zip(headers,widths): txt(h,xx,y,11,MUTED,'ArialBold',w=w-18); xx+=w
    line(x,y+27,x+sum(widths),y+27); yy=y+42
    for row in rows:
        xx=x
        for i,(v,w) in enumerate(zip(row,widths)):
            hh=txt(v,xx,yy,fs,INK if i==0 else MUTED,'ArialBold' if i==0 else 'Arial',w=w-19)
            if hh>rowh-11: checks.append(f'p{page_no} row height overflow {hh:.0f}/{rowh}: {str(v)[:40]}')
            xx+=w
        line(x,yy+rowh-14,x+sum(widths),yy+rowh-14); yy+=rowh
    return yy
def photo(rel,x,y,h):
    from PIL import Image
    path=ROOT/rel; iw,ih=Image.open(path).size; w=h*iw/ih
    c.drawImage(str(path),x,H-y-h,width=w,height=h,mask='auto'); return w
def stat(x,y,value,title,body,color=GREEN,w=235,dark=False):
    txt(value,x,y,39,color,'ArialBold')
    txt(title,x,y+57,17,'#FFFFFF' if dark else INK,'ArialBold',w=w)
    txt(body,x,y+91,15,'#BDBDC6' if dark else MUTED,w=w)
def badge(s,x,y,color=GREEN,w=170):
    rect(x,y,w,30,color,15); txt(s,x+14,y+9,10,'#FFFFFF','ArialBold',record=False)

# 01 — Real app capture, with the actual requested outcome.
heading('Release dossier','The consumer release.',dark=True)
txt('Ready for people.\nReady for review.',64,216,54,'#FFFFFF','ArialBold',w=650,leading=63)
txt('Global iPhone launch.\nZero new recurring spend.\nHosted around the Mac Mini.',68,386,24,'#C7C7CE',w=600,leading=35)
rect(68,555,438,56,ORANGE,28); txt('OUTCOME: PRODUCTION + REVIEW SUBMISSION',88,576,12,INK,'ArialBold')
txt('Build 14 submitted 6 Oct; Apple requested more information.\nA physical recording and completed review response remain.',68,638,17,'#BDBDC6',w=630)
photo('docs/audits/2026-10-05/home-navigation/proposed-home.png',798,49,676)
small('Real native simulator capture, 5 Oct; Home correction recorded in build 12. It is not a physical production-candidate capture.',68,711,654,'#9898A4')
end()

# 02 — State ladder, rather than a vague readiness percentage.
heading('The outcome','Three states. One finished release.','Qualification proves a candidate. Production proves the consumer path. App Store status proves submission.')
for x,n,t,b,done in [(64,'01','Sealed build 13 baseline','42 directed checks / three seeds. Build 14 password proof is separate; backend SQL and 5× pass.',sealed_baseline_qualified),
                   (429,'02','Production consumer path','Live Clerk, old users preserved, jobs installed, effective policies and ordinary sign-in.',backend_live and consumer_ready),
                   (794,'03','Resolve Apple review','Owner submitted 6 Oct; rejected 7 Oct for additional information. Reply draft saved; recording missing.',submitted and not review_rejected_verified)]:
    txt(n,x,222,44,ORANGE,'ArialBold'); txt(t,x,286,22,INK,'ArialBold',w=310)
    txt(b,x,335,18,MUTED,w=309)
    current_rejection = n == '03' and review_rejected_verified
    badge('REJECTED' if current_rejection else 'VERIFIED' if done else 'PENDING',x,457,RED if current_rejection else GREEN if done else ORANGE,140)
arrow(379,295,412,295); arrow(744,295,777,295)
line(64,526,1136,526)
bullet('Confirmed scope','iPhone only, English-first global reach, free initially, comments and replies off. Keep the backend on the Mini and the landing on existing Vercel Hobby.',64,560,500)
bullet('No licensing work before validation','The owner deferred permission outreach and commercial reviews. They are not a release workstream. Revisit with real traction or a monetization decision.',638,560,498)
small('Source qualification is not a physical-device or production-auth claim. Final 5× capacity verdict is shown from its receipt on page 15; absent evidence remains pending.')
end()

# 03
heading('Product exploration','The core loop is already substantial.','The release is a dependable way to keep your place across anime and TV.')
steps=[('Choose','Anime, TV or both; country and services in first run.'),('Bring your library','AniList public list, MAL XML/gzip, TV Time CSV/ZIP.'),('Know what is next','Home, Schedule, franchise detail and an editorial feed.'),('Keep your place','Progress, status, batch actions, Undo and watch sessions.'),('Come back','Local reminders, recommendations and new-season context.')]
y=218
for i,(t,b) in enumerate(steps):
    rect(64,y+3,32,32,INK,16); txt(str(i+1),75,y+10,15,'#FFFFFF','ArialBold')
    txt(t,117,y,22,INK,'ArialBold'); txt(b,117,y+31,16,MUTED,w=601)
    if i<4: line(80,y+39,80,y+85,'#CBCBD2',2)
    y+=94
photo('docs/audits/2026-10-05/home-navigation/proposed-recent.png',821,196,500)
small('Historical builds 9–12 prove prior onboarding/import/detail/Home work. New 6 Oct simulator regressions exercise progress, account boundaries and deletion; actual production auth remains separate.')
end()

# 04
heading('Feature priorities','Finish the promises people rely on.','Qualification and deployment are separate. Production login, current failure tests and the store packet remain explicit.')
table(['PRIORITY','CAPABILITY / REMAINING WORK','CURRENT STATE'],[
('P0','Production sign-in and preserving existing users',('Four real identities preserved; ' if identities_migrated else 'User migration pending; ')+candidate14_auth_summary),
('P0','Saved progress, account isolation and full deletion','Recorded Retry + server replay proved. First-dispatch persistence and monitor restart '+('proved; live path pending.' if native_predispatch_verified and native_monitor_verified else 'still under qualification.')),
('P0','Consumer build, privacy and Apple review response',(f'Build {store_build} rejected: physical recording and completed reply remain. All six answers drafted; unsent.' if review_rejected_verified else f'Build {store_build} selected; consumer checks and review remain.')),
('P1','Imports survive a backend restart','Preview/apply state remains in memory; durable checkpoints are not implemented.'),
('P1','Edit country and services; useful long-absence reminders','Profile edit surface and APNs are future work; keep local-reminder limits clear.'),
('P1','Accessibility, small iPhone and regional finish','Physical VoiceOver, iOS 18, large text and real cellular remain unverified.'),
('P2','Trakt, exact rewatch imports, widgets and richer sharing','Use activation and repeat use to choose the next investment.')],[100,478,494],rowh=64,fs=15)
small('Comments/replies stay OFF. Android and payments are outside v1. Server-synced watch history and supported imports already exist. P0 denotes actual consumer trust or store completeness, not provider outreach.')
end()

# 05
heading('Trust / qualification','“Saved” and “deleted” must be true.',
        'Pre-dispatch persistence and recorded Retry are exercised.' if native_predispatch_verified else 'Pre-dispatch persistence is implemented. Fresh full qualification remains open.',dark=True)
label('SAVE',64,214)
save_nodes = [(64,'Persist intent','Owner + payload + stamp'),(335,'Send / retry','Order each writer’s intent'),(606,'Commit + receipt','Canonical state; replay once'),(877,'Retire safely','Clear only after acceptance')]
for x,t,b in save_nodes: node(x,247,246,111,t,b,fill='#F1F1F3')
for x in [310,581,852]: arrow(x,304,x+22,304)
txt('Persisted payload survives the first dispatch boundary.' if native_predispatch_verified else 'Pre-dispatch journal implemented; fresh kill-before-catch and full-suite qualification pending.',64,369,16,'#BDBDC6',w=1050)
label('ERASE',64,399)
for x,t,b in [(64,'Journal first','Durable request before TX'),(335,'Erase app rows','Transaction + hash marker'),(606,'Clean identity','Retry actual Clerk DELETE'),(877,'Reconcile status','Pending / complete; no upsert')]: node(x,431,246,111,t,b,fill='#F1F1F3')
for x in [310,581,852]: arrow(x,488,x+22,488)
txt('The uncertain response stays uncertain.',64,591,23,'#FFFFFF','ArialBold')
txt('Cold launch preserves a deletion hold. The status route reconciles the independent journal before reporting a result; reconciliation failures stay 5xx. Accepted erasure clears owner-scoped caches, retries and exports. Completed markers prevent account resurrection after restore.',64,631,18,'#BDBDC6',w=1048)
small('Apple deletion: fresh owner-bound credential, best-effort revocation, explicit manual fallback. Apple unavailability must not prevent app-data erasure. Live Clerk/Apple lifecycle proof remains pending.',64,716,1060,'#9898A4')
end()

# 06
heading('App Store / submission','Prepare one verifiable release packet.','The requested finish is the exact final build submitted for review, plus a service ready for its first consumers.')
cols=[(64,'Access',[
('Production identity','Matching live keys + expected issuer. Old test JWT key removed or replaced. No silent beta data reset.'),
('Reviewer path',('Two fresh build 14 password logins passed without OTP. Saved access passed draft validation on 6 Oct.' if reviewer_fresh_no_otp_verified and review_credentials_saved else 'Build 14 reviewer password cycle passed. Private ASC credential handoff remains.' if candidate14_password_verified else 'Working demo account or complete demo mode, real backend and clear instructions.')),
('Account lifecycle','In-app deletion and returning login. Exercise actual Clerk cleanup and Apple revocation where enabled.')]),
(435,'Binary & privacy',[
('Binary receipts',f'Store build {store_build}: {store_stage}. '+(f'Replacement 14: {candidate14_store_stage}. ' if store_build != 14 else '')+'Live Clerk key, iPhone-only, SDK27 / iOS18 minimum.'),
('Data inventory',('Four actual archive manifests verified. Device ID is linked, functionality-only/no tracking; '+str(privacy_draft_category_count)+' ASC categories '+privacy_label_state+'.' if sdk_archive_verified else 'Clerk vendor device ID needs manifest/ASC alignment; actual archive inventory pending.')),
('Login choices',('Google/Apple connections enabled; simulator entry checkpoints passed. Owner reports both iPhone/TestFlight logins work. Phone OS/build and sessions were not independently captured.' if owner_provider_test_reported else 'Google/Apple connections enabled. Cold build 14 shows both buttons; Google login and Apple Settings prerequisite reached. Authenticated native SSO remains unverified.' if native_provider_entry_verified else google_setup_summary+(' Google/Apple production connections enabled; authenticated native SSO remains unverified.' if provider_connections_enabled else ' Clerk Google/Apple connections and native SSO remain.')))]),
(806,'Storefront',[
('Saved metadata','Canonical URLs '+('saved' if store_urls_verified else 'pending')+'. Free pricing/global intent; Mac/Vision Pro off. Age '+(age_rating.get('calculatedRating','pending') if age_rating_verified else 'pending')+'; '+('4 screenshots + header saved.' if artwork_saved_verified else 'screenshots pending.')),
('Public information',('Support works. Policy effective 6 October 2026; routine retention disclosures match installed jobs. Consumer erasure/Files proof remain separate.' if effective_policy_verified else 'Support works. Legal content stays visibly draft until the live retention and deletion facts are verified.')),
('Current review',('Build 14 submitted 6 Oct; rejected 7 Oct under 2.1, Information Needed. Reply draft saved; physical recording and completed response remain.' if review_rejected_verified else f'Build {store_build}: {store_stage}. Review handoff remains.'))])]
for x,title,items in cols:
    txt(title,x,215,23,INK,'ArialBold'); line(x,252,x+327,252); y=276
    for t,b in items: y+=bullet(t,b,x,y,w=326)+20
small(('Reviewer fields and '+number(review_notes_length)+'-character Notes remain saved. The 7 Oct reply draft is unsent; Notes have not been replaced. Apple reports no specific crash/login defect or required new build. Consumer readiness remains unverified.' if review_rejected_verified else 'Saved reviewer access and draft validation do not establish a submitted or consumer-ready release.'))
end()

# 07
heading('Global reach','Global intent. Region-aware proof.','Maximise reach through a useful product, clear listing and fast onboarding; do not invent organic demand.')
table(['AREA','WHAT MUST WORK','PROOF TO KEEP'],[
('Enabled regions','Login, images, catalogue, support URLs and public API','Actual regional checks and physical cellular; the Mac’s network alone is insufficient.'),
('European Union','Truthful trader declaration and applicable verification',('Owner non-trader status saved and read back; regional eligibility stays separate.' if owner_declarations_verified else 'Owner’s actual ASC trader record; free pricing does not determine trader status.')),
('China mainland','Check filing fields and applicable local requirements','Owner’s actual ASC eligibility; enable only regions that can be truthfully configured.'),
('Time and catalogue','Locale/timezone/DST; date-only TV remains date-only','IN, US, UK and UTC+14 cases; unavailable streaming data stays explicit.'),
('Age and privacy','Saved 18+; Brazil 18+, Korea 19+; legacy OS<26 17+','Numeric UGC and possible YouTube ads declared. No age override.'),
('Accessible iPhones','iOS 18 support, small/older phone and current OS','VoiceOver, largest text, Reduce Motion, poor network and low memory.')],[191,456,425],rowh=76,fs=15)
small('Rating is not availability: Afghanistan/Entertainment is flagged. Apple’s broader Korea RCN criteria match Entertainment/frequent realistic violence; actual eligibility is unverified. Device, VoiceOver and WAN checks are recommended and remain unverified.')
end()

# 08
heading('Cost contract','Zero new recurring spend stays concrete.','Existing Apple membership, hardware, domain and subscriptions are already paid, as requested.')
table(['COMPONENT','IMPLEMENTED / CHOSEN','BOUNDARY'],[
('Backend + database','Existing Mini, Node 24, Fastify, PostgreSQL, launchd','No new hosting bill. One home site has no failover.'),
('Landing','Existing Vercel Hobby project; static Next export','Promoted and publicly qualified. No Pro trial, new project or paid functions.'),
('Authentication','Production Clerk Hobby; Apple relay SPF verified',('Four identities preserved. ' if identities_migrated else 'Migration pending. ')+candidate14_auth_summary),
('Errors + throughput','Private Mini metrics + sanitized capped local logs','No Sentry, Grafana or new monitoring vendor has been chosen.'),
('Product usage','Private aggregate SQL and 30-day ops snapshots','Current app-open/library/progress counts; cohort event ledger is P1.'),
('AI runtime','Production guards reject enabled chargeable features','Installed startup rejects paid grouping/query correction and enabled comments.'),
('Recovery','Private 7-day dumps + isolated restore + current ledger','Same-disk backup is useful recovery, not protection against losing the Mini.')],[205,455,412],rowh=64,fs=15)
small('No card-backed trial, promotional credit or future cloud free-tier allowance is a lasting free guarantee. Commercial hosting/provider review is deferred to validation or monetization. S06, S10–S11, S23–S24.')
end()

# 09
heading('Provider boundaries','Commercial review belongs later.','Owner decision: no licensing outreach, permission chase or provider gate before market validation.')
bullet('Keep a factual reference','AniList’s terms contain a competing-tracker restriction separate from revenue. Record the fact for the later commercial review without scheduling outreach or changing the validation scope.',64,224,505)
bullet('Small attribution polish','The native TMDB notice exists; an approved logo is still a P1 polish item. Keep relevant JustWatch credits. Do not assert written provider approval or commercial eligibility that has not been established.',638,224,498)
line(64,448,1136,448)
bullet('Trailer privacy matches the player','The source now uses youtube-nocookie.com and a non-persistent WebView. '+('Live player proof passed. ' if trailer_verified else 'Live player proof remains pending. ')+'Contextual ads may still appear. Controls, captions and unavailable-trailer fallback remain P1.',64,482,505)
bullet('Revisit when traction is real','Use sustained useful weekly use and an actual monetization decision to trigger the later review. There is no imposed user-count threshold. Free initially does not mean future commercial terms are already solved.',638,482,498)
small('S10 and S15–S18 remain later commercial references; no provider outreach was sent. '+('Owner content-rights and non-trader declarations are saved/read back; no provider agreement is inferred.' if owner_declarations_verified else 'Store content-rights declarations require the owner’s truthful answers.'))
end()

# 10
heading('Landing / effective policy' if effective_policy_verified else 'Landing / public draft','Previously has its own live address.',('Policy effective 6 October 2026. Qualified static legal publication on the existing Vercel Hobby project.' if effective_policy_verified else 'Updated static export on the existing Vercel Hobby project. Policy remains visibly draft with no effective date.'))
stat(64,224,number(effective_landing.get('freshCanonicalLegalMobileLayouts')) if effective_policy_verified else number(landing_fresh_layouts) if draft_landing_verified else 'Pending','Canonical legal layouts' if effective_policy_verified else landing_fresh_layout_label,'8 fresh candidate layouts; 5 fresh canonical mobile layouts.' if effective_policy_verified else 'New narrow evidence; historical checks stay scoped references.')
stat(429,224,number(public_landing.get('anonymousRoutesPerOrigin')) if public_landing_verified else 'Pending','Routes per public origin','Canonical bytes match the verified candidate; existing aliases retained.')
stat(794,224,number(public_landing.get('publicAssetHashMatchesPerOrigin')) if public_landing_verified else 'Pending','Asset hashes per origin','Original image/font bytes match the qualified source assets.')
line(64,421,1136,421)
node(64,456,511,122,'previously.cognipin.com','Eight routes '+('verified. ' if public_landing_verified else 'pending. ')+'152px native icon used on site/Clerk; coral period. Visible CSS Dynamic Island; original raster unchanged.')
node(625,456,511,122,'Scope of fresh and prior evidence',('Fresh: 8 candidate / 5 canonical legal layouts; 4 navigation / 1 settled anchor. Prior: 19 Home / 3 hero / 4 gallery. Product-tour/image bytes unchanged.' if effective_policy_verified else number(landing_fresh_layouts)+' fresh layouts / '+number(landing_fresh_gallery)+' gallery. Prior brand: '+number(landing_prior_brand_layouts)+' layouts / '+number(landing_prior_brand_gallery)+' gallery. Historical: '+number(draft_landing.get('priorLegalMobileChecksReused',0))+' legal / '+number(landing_prior_device_refs)+' paragraph / '+number(landing_prior_home_refs)+' Home refs.'))
txt('Current public deployment',64,613,19,INK,'ArialBold')
txt(public_landing.get('deploymentId','Pending') if public_landing_verified else landing.get('deploymentId','Pending'),64,646,15,BLUE,w=1020)
small('Proof: '+public_landing_receipt+'. Source SHA '+public_landing.get('sourceManifestSha256','pending')[:7]+'; rollback '+public_landing.get('rollbackDeploymentId','pending')[:12]+('. Draft=false/effective 6 Oct. Consumer workflows and the current Apple response remain separate.' if effective_policy_verified else '. Draft=true; effective policy, auth, retention and submission remain separate.'))
end()

# 11
heading('Architecture','One small service. Clear boundaries.','Stay on the Mini. Promote one compiled artifact and keep private state outside the checkout.')
node(64,233,229,112,'iPhone','Owner-scoped cache\nJournal before dispatch')
node(365,233,230,112,'Stable HTTPS ingress','Existing Cloudflare tunnel\nLoopback API binding')
arrow(303,289,357,289)
rect(640,195,519,385,'#E8E8ED',20); label('MAC MINI / PRIVATE',667,211)
arrow(604,289,658,289)
node(671,240,230,110,'Compiled API','Node 24 · dist/index.js\n256 MiB old-space budget')
node(969,240,167,110,'PostgreSQL','Pool max 10\nVersioned migrations')
arrow(907,293,958,293)
node(671,397,230,125,'Bounded jobs','Cron overlap guard\nDurable erasure retry')
node(969,397,167,125,'Providers','Cached reads\nBounded calls')
arrow(785,358,785,388); arrow(907,458,958,458)
node(64,410,229,112,'Vercel landing','Static marketing + support\nIndependent of Mini uptime')
node(365,410,230,112,'Private operations','Metrics + usage + readiness\nBackup + current journal')
arrow(663,355,596,433)
txt('The migration seam already exists.',64,610,23,INK,'ArialBold')
txt('Environment configuration, PostgreSQL state, provider adapters and compiled JavaScript travel together. Keep mutable journals, backups and logs private. Durable import checkpoints remain P1; do not depict an implemented general job queue.',64,649,18,MUTED,w=1040)
small('The immutable Node24 artifact is installed. Public/local readiness and graceful restart pass; candidate14 production password login/restore/relogin have a separate actual receipt.' if jobs_live and candidate14_password_verified else 'Production consumer login remains separate from installed-service readiness.')
end()

# 12
heading('Observability','See errors. See throughput. See freshness.','Private Mini endpoints and the free hourly collector are installed; fresh healthy status and graceful restart pass.' if jobs_live else 'Private endpoints and collector are prepared; installation remains separate.',dark=True)
for x,n,l in [(64,'Errors','Route pattern / code / request ID'),(338,'Latency','Server p50 / p95 / p99'),(612,'Throughput','Requests / useful writes'),(886,'Recovery','Backup / erasure / disk')]:
    label(n,x,222); txt('PRIVATE',x,260,30,'#FFFFFF','ArialBold'); txt(l,x,313,15,'#BDBDC6',w=244)
line(64,368,1136,368,'#3A3A3E')
rows=[('API','Aggregate errors, latency, rate, in-flight work and runtime memory; diagnostics require a private token.'),('Jobs','Structured job names, overlap protection, bounded shutdown and durable identity-erasure retry.'),('Operations','Hourly snapshots: loopback metrics/usage, public readiness, backup freshness and disk.'),('Failure state','A failed collection writes unhealthy + timestamp; stale snapshots are not displayed as healthy.'),('Privacy','No raw searches, emails, tokens or account IDs in app logs. Static job names only; no session replay.')]
y=399
for a,b in rows: txt(a,64,y,18,'#FFFFFF','ArialBold'); txt(b,278,y,17,'#BDBDC6',w=852); y+=54
small('Managed logs: daily files / 8 MiB×16; removal scheduled 7 days after last entry (~8-day record bound). Aggregates 30 days. '+legacy_log_summary+' Production age-expiry and external alerts remain unverified.',64,700,1065,'#9898A4')
end()

# 13
heading('Service objectives','Use practical limits. Act on failures.','These are initial operational targets, not a public uptime promise or measured month of production service.')
table(['SIGNAL','INITIAL TARGET / TRIGGER','ACTION'],[
('Availability','99.5% monthly planning target; no home-site failover','Use public /ready and inspect failed snapshots. Regional independent probes remain to be set up.'),
('Core latency','Warm reads p95 ≤500 ms; writes p95 ≤800 ms at server','Compare to the fixed 5× scratch run. Cellular/global RTT is additional.'),
('Errors','Core 5xx <1%; no incorrect writes or lost acknowledged intent','Inspect route/code/request ID. Expected auth/validation 4xx are not server failures.'),
('Freshness','Successful hourly catalogue sync; investigate >2 h stale','Keep last-known content. Inspect bounded job outcome and upstream timeout.'),
('Erasure + backup','Investigate pending cleanup >1 h; backup >26 h old','Retry identity cleanup and repair backup job. Do not promise a cleanup deadline not yet proven live.'),
('Host pressure','Disk <20 GB; memory/pool wait or event-loop lag sustained','Stop nonessential work first. Share the 16 GB Mini deliberately; inspect actual process state.')],[200,443,429],rowh=76,fs=15)
small('Hourly collector is installed; timestamped healthy status is verified. External alerts and monthly uptime remain unmeasured. Avoid high-cardinality labels, paid overage and unrealistic million-user targets.')
end()

# 14
heading('Recovery / verified','The database backup really restores.','Actual migrated database: isolated restore completed without replacing or restarting the live service.')
for x,t,b in [(64,'1. Private dump','Custom pg_dump\nManifest + SHA + TOC'),(344,'2. Owned scratch','Unique temporary DB\nNever restore over live'),(624,'3. Sweep erasure','Reapply current journal\nVerify owned relationships'),(904,'4. Inspect + clean','Counts / invariants\nDrop scratch database')]: node(x,225,232,148,t,b)
for x in [304,584,864]: arrow(x,298,x+31,298)
stat(64,427,number(post_cutover_restore.get('qualifiedRestore',{}).get('usersAfter')) if post_cutover_restored else 'Pending','Users in post-cutover restore','Four production mappings and exact 20 owned tables match; live database untouched.',GREEN if post_cutover_restored else ORANGE,w=440)
stat(649,427,'7 days','Installed backup policy' if jobs_live else 'Prepared backup policy','At most 7 daily dump/manifest pairs. First daily job exited 0; actual dump hash and size match.',GREEN if jobs_live else ORANGE,w=435)
line(64,617,1136,617)
txt('Deletion markers must outlive the restored copy.',64,640,23,INK,'ArialBold')
txt('Apply the current erasure journal before reopening. A new production-identity backup passed two isolated restore checks; ordinary restore does not translate older development identifiers.',64,677,16,MUTED,w=1045,leading=20)
small('June24 '+('retired with owner approval.' if legacy_backup.get('removed') is True else 'retirement unverified.')+' Post-cutover baseline qualified; daily/hourly jobs installed. Same-disk only. '+legacy_log_summary,64,723)
end()

# 15 — Rate bars have one shared 150 RPS scale; full verdict from final receipt only.
heading('Capacity / 5×','Expect a small launch. Qualify the surge.','Scenarios: 100 / 500 / 2,000 registered and 20 / 100 / 400 DAU. These are planning envelopes, not demand forecasts.')
for i,(name,rate,color,detail) in enumerate([('WORKING PEAK',15,BLUE,'Expected peak · planning assumption'),('5× QUALIFICATION',75,GREEN,'15 minutes · core routes + 5% writes'),('SHORT BURST',150,ORANGE,'1 minute · then 5 minutes recovery')]):
    y=223+i*103
    label(name,64,y,color); txt(str(rate),285,y-8,40,color,'ArialBold'); txt('req/s',379,y+13,17,MUTED)
    rect(495,y+4,641,22,'#E3E3E8',11); rect(495,y+4,641*rate/150,22,color,11)
    txt(detail,495,y+39,16,MUTED,w=635)
line(64,526,1136,526)
verdict_color=GREEN if load_passed else RED if load_state=='FAILED' else ORANGE
badge('FINAL RUN: '+load_state,64,558,verdict_color,220)
txt(number(load.get('coreRequests'))+' requests' if isinstance(load.get('coreRequests'), int) else 'Changed candidate awaiting a fresh run',327,559,21,INK,'ArialBold',w=806)
if isinstance(load.get('coreRequests'), int):
    txt(f"Errors {number(load.get('errorCount'))} · dropped {number(load.get('droppedCount'))} · wrong writes {number(load.get('writeOracleMismatch'))} · heap delta {number(load.get('heapDeltaMiB'),1)} MiB",64,611,17,MUTED,w=1055)
else:
    txt('200 cold searches + 2 concurrent imports; real migrated scratch PostgreSQL, synthetic providers and fixed resource bounds.',64,611,18,MUTED,w=1044)
txt('40 requests per DAU/day → 4,000/day at the working scenario. Global network latency, real providers and live identity are separate consumer checks.',64,663,17,MUTED,w=1045)
small('Current frozen artifact: 75 RPS for 15 min, p95/p99 69/108 ms; 150 RPS burst 117/143 ms. All 82,800 core requests and fixed resource bounds passed. Loopback/stub-provider proof excludes global WAN/auth quotas.',64,712)
end()

# 16
heading('Product usage','Measure the useful loop.','Current private aggregates exist. Retention cohorts and acquisition attribution still need a small event ledger.')
for i,(a,b) in enumerate([('Install','ASC download'),('Start','App open'),('Activate','Library + sync'),('Use','Progress saved'),('Return','Useful next-week action')]):
    x=64+i*219; node(x,224,198,111,a,b)
    if i<4: arrow(x+202,279,x+215,279)
table(['MEASURE','DEFINITION / CURRENT STATUS','HOW TO USE IT'],[
('Current aggregates','App profiles, confirmed app-open stamps, library and positive progress counts','registered counts all DB profiles, including legacy/test/review. No consumer cohort or billing-MAU claim.'),
('Activation · P1','≥3 distinct library titles + one confirmed sync within 24 h','Manual or imported setup counts. Requires event time and defined eligible cohort.'),
('Useful weekly use · P1','Account with confirmed progress save or library change in the week','Use successful server commits; report client-only click counts separately.'),
('Week-1 return · P1','Activated cohort with useful action on days 7–13 / eligible cohort','Show numerator + denominator. Small samples do not establish market validation.')],[222,473,377],y=381,rowh=74,fs=15)
small('6 Oct prelaunch baseline: 16 stored profiles / four real returning identities. Legacy/test rows and later reviewer/erasure QA are separate from consumer growth; raw totals are not adoption, retention cohorts or market validation. See operations/usage-semantics.md.')
end()

# 17
heading('Analytics / proposed P1','A small event ledger is enough.','No paid analytics dependency. Do not present the proposed cohort system as implemented.')
y=224
for a,b in [('Capture useful decisions','first_open, onboarding_complete, import_preview/apply/failure, follow_saved, progress_saved and sync_failed. Avoid noisy taps and impression streams.'),
            ('Trust successful commits','Record confirmed library/progress/import results after commit. Deduplicate events. Exclude dev, owner, reviewer and erasure QA identities from customer cohorts.'),
            ('Keep payloads narrow','Event/version, timestamp, build and coarse source only. Account link only when necessary and erased with the account. No email, raw search, title history or advertising ID.')]: y+=bullet(a,b,64,y,515)+26
rect(638,219,498,440,'#E8E8ED',18)
txt('144,000',666,254,57,INK,'ArialBold'); txt('proposed events / month at 400 DAU',666,329,17,MUTED,w=435)
txt('400 × 12 events/day × 30 days',666,375,20,INK,'ArialBold',w=436)
txt('512 bytes/event → about 74 MB payload/month before indexes. Measure actual storage before setting a larger budget.',666,422,17,MUTED,w=430)
txt('Current operational snapshots: aggregate counts retained 30 days. This is not a raw product event table or a cohort report.',666,512,17,MUTED,w=430)
txt('No session replay. Privacy disclosures must describe the actual implementation and choices.',666,592,16,MUTED,w=430)
small('Apple’s usage metrics are opt-in and privacy-thresholded. First-party counts do not automatically mean cross-company tracking; ATT answers follow actual behavior. S04, S19–S20.')
end()

# 18
heading('Acquisition / $0','Reach comes from a sharper promise.','Anime and TV, one dependable place to keep your place. Optimize the first successful session before buying reach.')
for x,n,t,b in [(64,'01','Earn the install','Use real screenshots: what aired, where you stopped and one franchise across seasons.'),(435,'02','Lower switch cost','Show supported AniList, MAL and TV Time imports, preview workflow and honest limits.'),(806,'03','Earn the next week','Fast first library, trustworthy progress and useful release context. System rating prompt only after a successful moment.')]:
    txt(n,x,223,48,ORANGE,'ArialBold'); txt(t,x,287,23,INK,'ArialBold'); txt(b,x,329,18,MUTED,w=320)
line(64,501,1136,501)
bullet('First 30 days','Recruit 20–30 people across anime, TV and mixed use. Publish a concise demo, import guide and build notes in your own channels and communities that permit promotion. No paid ads or purchased reviews.',64,541,500)
bullet('Expand from observed value','Check install→activation first, then eligible week-1 return. Localize store copy where impressions and conversion justify it. Start with counts and interviews; A/B tests need adequate traffic.',638,541,498)
small('20–30 testers is a recruitment goal, not expected demand. Existing Apple product-page/acquisition tools may help measure reach. No campaign or unsolicited messages have been sent. S21–S22.')
end()

# 19
heading('Customer guide','Make the first ten minutes obvious.','Landing, onboarding and support should tell one accurate story.')
table(['WHEN','WHAT THE PERSON DOES','WHAT WE MUST EXPLAIN'],[
('First launch','Sign in → choose Anime/TV/Both → country/services','Why an account helps; optional setup can be skipped safely.'),
('Bring history','AniList public list; MAL XML/gzip; TV Time CSV/ZIP','Preview before Add. TV Time progress is approximate; no exact original rewatch dates.'),
('Add a show','Search → detail → Planned / Start / part-way / caught up','Status differs from progress. A future episode is not an aired one.'),
('Daily use','Home for next action; Schedule for dates; Library for status','Same show detail from each entry point; Undo stays available.'),
('Come back','Feed, recommendations and relevant local reminders','Local notification window is finite; refresh after a long absence. TV dates are date-only.'),
('A failure','Keep cached library → inspect sync status → Retry/discard','Pending is not synced. Separate offline from service unavailable.'),
('Leave','Profile → export / sign out / delete','Imported source account is separate. App erasure and identity cleanup have truthful states.')],[152,466,454],rowh=64,fs=15)
small(candidate14_files_summary+' '+candidate14_erasure_summary+' Physical iCloud Files, poor-network first launch and actual consumer TestFlight remain separate.')
end()

# 20 — The actual 7 Oct information request changes the review handoff, not the qualified artifact.
heading('Apple review / information needed','Show the real consumer journey.','Owner submitted build 14 on 6 Oct. Apple rejected it on 7 Oct under 2.1, citing limited review history and requesting six information items.')
phases=[('1','Record the physical iPhone flow','Required / missing',
        'Latest OS, submitted 1.0 (14): launch, ordinary use, login, deletion and registration. Use the guarded disposable-account sequence; no actual recording or deletion is verified.',
        'Start here: one show + episode 1 → “QA ready” → baseline check → owner deletion → post-check → fresh registration.'),
        ('2','Complete the six factual answers','6 answers drafted',
        'Recording; purpose/audience; feature access and samples; external services; regional behavior; relevant authorization if applicable. No separate provider rights document has been supplied.',
        'Reply: '+number(review_response_length)+' / 4,000 characters. Prepared Notes: '+number(len(prepared_notes_bytes) if prepared_notes_bytes is not None else None)+' / 4,000 UTF-8 bytes. Both include the final newline; 416 remain in each limit.'),
        ('3','Attach evidence and update Notes','Draft saved / unsent',
        'Replace the recording and sample placeholders. The 594-byte synthetic XML ZIP is validated but unuploaded. Existing '+number(review_notes_length)+'-character Review Notes remain unchanged.',
        'Keep reviewer credentials private. Clips must demonstrate actual outcomes; simulator and owner SSO reports do not replace the video.'),
        ('4','Reply and retain the review result','Not sent',
        'Send the completed packet only after recording review, and retain Apple’s reply/status. Resubmission is unverified; the current resubmit control is disabled. No replacement build is requested.',
        'Apple identifies no specific crash or login defect. Code/build changes require an actual defect or a new request, not the rejection label.')]
for i,(n,t,d,b,e) in enumerate(phases):
    y=218+i*119; rect(64,y+3,44,44,INK,22); txt(n,80,y+13,21,'#FFFFFF','ArialBold')
    txt(t,132,y,23,INK,'ArialBold'); txt(d,948,y+5,17,ORANGE,'ArialBold')
    txt(b,132,y+36,16,MUTED,w=984); txt(e,132,y+83,14,GREEN,'ArialBold',w=980)
small('Current receipts: docs/qa/2026-10-07/app-store/{rejection-receipt,response-draft-saved-receipt,review-package-prepared}.json. Licensing outreach remains outside the pre-validation plan.')
end()

# 21
heading('Acceptance backlog / A','Protect identity and saved progress.','Stable workstream IDs retain the connection to the original plan, with current evidence and remaining consumer proof.')
items=[('W1 · Production identity',('SSO PASS / owner report' if owner_provider_test_reported else 'Connections enabled / SSO unverified' if provider_connections_enabled else 'SSO connection pending'),('Four identities preserved; Clerk/DNS and enabled connections/FAPI verified. Owner reports both iPhone/TestFlight logins passed; phone OS/build/session were not independently captured.' if owner_provider_test_reported else 'Four identities preserved; live Clerk/DNS verified. Stored connections/FAPI flags are enabled. Cold build 14 reached Google login and Apple Account prerequisite; authenticated sessions unverified.' if native_provider_entry_verified else 'Four identities preserved; live Clerk/DNS verified. Google/Apple stored connections are Enabled; production frontend flags are authenticatable. Native authenticated sessions remain unverified.' if provider_connections_enabled else 'Four identities preserved; live Clerk/DNS verified. Google client in production. Supported config API rejects missing org_id in Personal workspace; Google/Apple connections and native SSO remain.' if clerk_personal_api_blocked else 'Four identities preserved; live Clerk and five DNS records verified. '+google_setup_summary+' Clerk connections/native Google and Apple proof remain.'),'Proof: actual cutover + post-realm restore; '+candidate14_auth_summary,'Guide: clerk-cutover.md; provider-frontend-readback.json; provider-owner-testflight.json; provider-enabled-recheck/result.json'),
       ('W2 · Account lifecycle','Backend proved; live pending','Fresh owner-bound Apple exchange/revoke and conservative outcomes are implemented. App erasure precedes exchange; unavailable proof/provider keeps erasure available with manual fallback.','Proof: 1,328 units include 21 Apple cryptographic cases; 6 current SQL recovery cases. Real Apple/Clerk and native lifecycle remain pending.','E03–E05; apple-deletion/README.md; Apple TN3194'),
       ('W3 · Saved progress','Boundary proved' if native_predispatch_verified and native_monitor_verified else 'Fresh qualification pending','Stamped replay and canonical receipts exist. Native now journals owner/payload/stamp before dispatch and recreates the monitor; '+('named tests pass.' if native_predispatch_verified and native_monitor_verified else 'full directed qualification is pending.')+' Rewatch guards newer intent.','Proof: use current native first-dispatch/monitor flags and named tests; prior 31 SQL and cold Retry counts remain scoped to their artifacts.','E06; compiled-node24-final/results.json; native-results.json'),
       ('W4 · Privacy + store','Rejected / reply draft',('Website policy effective 6 October. ' if effective_policy_verified else 'Website policy remains draft. ')+('Four archive manifests verified; ' if sdk_archive_verified else 'Final archive manifests pending; ')+str(privacy_draft_category_count)+' ASC categories '+privacy_label_state+'. Five Store assets remain saved.',
        'Build 14 submitted 6 Oct, rejected 7 Oct. Saved '+number(review_response_length)+'-character draft is unsent; recording/attachments/Notes remain.',
        'E01, E09; 7 Oct rejection-receipt.json; response-draft-saved-receipt.json; review-package-prepared.json')]

y=201
for ident,state,work,proof,ref in items:
    txt(ident,64,y,21,INK,'ArialBold'); txt(state,850,y+2,13,ORANGE,'ArialBold')
    txt(work,64,y+32,15,MUTED,w=1058); txt(proof,64,y+79,14,INK,w=1058)
    small(ref,64,y+109,1060); line(64,y+128,1136,y+128); y+=132
end()

# 22
heading('Acceptance backlog / B','Keep operations small and useful.','Free operation and maintainability are implemented without adding monitoring vendors or unrealistic scale.')
items=[('W5 · Content policy + polish','Backend proved / P1','Explicit adult=true/Hentai filtering and import skips are implemented; 27 current real-PG policy cases pass. Ecchi/mature ratings remain; saved App Store rating is 18+.',('Live privacy-enhanced trailer controls and rotation pass.' if trailer_verified else 'Live trailer privacy proof remains pending.')+' VoiceOver, captions and TMDB logo polish remain P1; no licensing outreach.','E10; compiled-node24-apple-policy/results.json; age-rating-saved.json'),
       ('W6 · Hard $0 operation','Production guards active','Installed production startup rejects chargeable grouping/query correction and enabled comments. Immutable process uses prepared live config. Clerk/Vercel stay on existing free plans.','Proof: exact artifact/plist hashes, startup/readiness and guarded paths. No trial, paid feature or automatic paid upgrade enabled.','E11; runtimePolicy.ts + releaseConfig.ts; actual-installed-live-receipt.json'),
       ('W7 · Recoverable service','Jobs / restart verified','Immutable Node24 artifact 123751 is installed; audit 0 and smoke pass. Daily/hourly jobs and post-identity backup are verified. Old mutable dev plist is unsafe rollback.','Proof: 26 checks; two isolated post-realm restores, exact four mappings/20 tables; SIGTERM exit0/readiness200. '+('Historical logs retired; ' if legacy_log_retirement_verified else 'Legacy logs remain; ')+'same-disk only.','E12–E14; actual-installed-live-receipt.json; post-clerk-cutover-backup-restore.json; legacy-log-files-retired.json'),
       ('W8 · Consumer qualification','Recording / erasure pending',candidate14_auth_summary+' '+candidate14_files_summary+' '+candidate14_erasure_summary,
        'Apple now requires a physical latest-OS recording of launch/use/registration/login/deletion. iOS 18, VoiceOver and WAN checks remain recommended and unverified.',
        'E07–E08, E15; 7 Oct physical-device-recording-guide.md; owner recording and real erasure readback remain')]

y=201
for ident,state,work,proof,ref in items:
    txt(ident,64,y,21,INK,'ArialBold'); txt(state,807,y+3,12,ORANGE,'ArialBold')
    txt(work,64,y+32,15,MUTED,w=1058); txt(proof,64,y+79,14,INK,w=1058)
    small(ref,64,y+109,1060); line(64,y+128,1136,y+128); y+=132
end()

# 23
heading('QA / monkey testing','Test the mess, then replay it.','Seeded actions discover paths. Directed assertions and real data checks decide whether the app kept its promises.',dark=True)
for x,n,t,b in [(64,'01','Choose valid actions','Seeded taps, swipes, back, sheets, search, progress, Undo and dismissals.'),(429,'02','Check the result','Check responsive controls, canonical progress, pending sync and account ownership.'),(794,'03','Keep the evidence','Record build/fixture/seed, actions, faults and the first failing state.')]:
    txt(n,x,220,38,ORANGE,'ArialBold'); txt(t,x,280,23,'#FFFFFF','ArialBold'); txt(b,x,324,18,'#BDBDC6',w=310)
    line(x,421,x+310,421,'#45454C')
arrow(382,289,412,289); arrow(747,289,777,289)
txt(tally(len(passed_seeds),seed_target)+' completed passing seeds',64,469,30,GREEN if len(passed_seeds)==seed_target else ORANGE,'ArialBold',w=1060)
bullet('Sealed build 13 run','Three fixed seeds × 300 seconds on one iPhone 14 Pro simulator. These receipts do not qualify the changed build 14 auth code.',64,530,496,dark=True)
bullet('What it does not prove','The QA app uses synthetic identities and a controlled backend. Physical production TestFlight, real Files, VoiceOver, old OS and real provider timing remain separate.',640,530,493,dark=True)
small('Sealed build 13: '+number(native.get('seededCompletedActions'))+' actions / '+number(native.get('seededDriverAssertions'))+' driver assertions; '+number(native.get('mutationAudit', {}).get('protectedWrites'))+' protected writes / '+number(native.get('mutationAudit', {}).get('uniqueOperations'))+' unique operations. Build 14 password cycle is separately proved; no inherited full-suite, SSO or physical/WAN claim.',64,702,1060,'#BDBDC6')
c.linkURL('https://developer.apple.com/documentation/xcuiautomation',(64,H-735,1136,H-715),relative=0,thickness=0)
end()

# 24
heading('QA / deliberate faults','Break the flow. Verify the data.','Adverse interleavings are exercised through production source and actual migrated scratch PostgreSQL.')
table(['JOURNEY','FAULT / EDGE','PROVEN IN THIS SCOPE'],[
('Progress + Undo','Lost receipt, duplicate retry, older uncommitted intent, compound rollback','One logical commit; new reset/Undo wins; canonical values and receipt/cursor rollback.'),
('Account boundary','Owner A→B with delayed failure/response; cold launch; stale writer','Native owner isolation and independent SQL ownership; no old retry under new token.'),
('Delete + restart','Provider pending, lost response, failed TX with precommit journal','App rows erased on reconciliation; durable pending or complete marker; no resurrection.'),
('Status uncertainty','GET status during failed rollback reconciliation, then retry','5xx stays unknown; GET alone recovers and erases before pending; later write denied.'),
('Operation recovery','Scratch restore with completed hash marker; injected provider 404','Restored deleted identity swept; completion cannot downgrade. No real Clerk network used.'),
('Remaining consumer paths','Live erasure, Files, accessibility and older iOS','Password cycle passed on 14; '+('owner SSO report separate. ' if owner_provider_test_reported else 'SSO pending. ')+'Files sheet shown; full import/export and consumer erasure remain.')],[163,433,476],rowh=74,fs=15)
small('Real provider calls are prohibited in the final capacity/SQL harness. Fault evidence is versioned and scratch cleanup is recorded. No destructive scenario was injected into the live consumer database.')
end()

# 25
heading('QA / executed evidence','Proof, with its boundaries.','Native counts belong to sealed build 13. Build 14 password-cycle proof, fixture, SQL and operations receipts stay separate.')
stat(64,220,tally(native.get('directedProductPassed'),native.get('directedProductTotal')),'Build 13 product checks',number(native.get('directedUIJourneyPassed'))+' UI journeys + '+number(native.get('directedActualModelPassed'))+' actual model regressions.')
stat(337,220,tally(native.get('fixturePassed'),native.get('fixtureTotal')),'Fixture checks','Controlled faults, reset races and protocol/account isolation.')
stat(610,220,summary_count(protocol),'Real SQL progress','Ordered writes, stale replay, Undo, ownership and canonical data.')
stat(883,220,summary_count(recovery),'SQL Apple recovery','Current independent journal and Apple outcome restore/replay cases.')
line(64,417,1136,417)
table(['SUPPORTING CHECK','CURRENT RECEIPT','BOUNDARY'],[
('Build 13 selected suite',tally(native.get('directedSelectedPassed'),native.get('directedSelectedTotal'))+' · '+number(native.get('directedHarnessPassed'))+' harness checks','Sealed baseline: product total above; harness checks are not customer journeys.'),
('Runner + fixed seeds',tally(native.get('runnerGuardPassed'),native.get('runnerGuardTotal'))+' guards · '+tally(len(passed_seeds),seed_target)+' seeds','Count only completed passing seeds; 300 s budget each.'),
('Server units',tally(units.get('passed'),units.get('total'))+' · '+number(units.get('files'))+' files','Current non-load backend proof; includes 21 Apple cryptographic service cases.'),
('Operational scripts',summary_count(ops_qualified)+' · Node24 compiled entry','Current dump/restore and pre0015 restore cases; no job installation claim.')],[260,387,425],y=430,rowh=60,fs=14)
small('Backend non-load checks pass. Sealed build 13: '+(number(native.get('directedSelectedPassed'))+' directed checks pass' if native_directed_verified else 'directed qualification pending')+'; three fixed seeds '+('pass' if native_seeds_verified else 'pending')+'. Build 14 password proof and '+('owner SSO report are separate; ' if owner_provider_test_reported else 'SSO proof are separate; ')+'live erasure and device/network checks remain.')
end()

# 26
heading('Maintainability / future move','Portability is a boundary, not a rewrite.','Promote a reproducible compiled artifact now. Move hosting only when measured needs justify a new budget.')
bullet('Current runtime is reproducible','Node 24.21.0, compiled dist/index.js, npm ci --omit=dev and immutable working directory. Actual compiled JavaScript is fingerprinted. Private environment and mutable ops state live outside the artifact.',64,224,504)
bullet('Quality remains cheap','Strict types, meaningful unit tests, actual PostgreSQL transaction/replay checks and native account/storage regressions run on the owned Mini. Keep source and final load artifact frozen during qualification.',638,224,495)
line(64,460,1136,460)
bullet('Migrate on a measured trigger','Repeated power/ISP incidents, inadequate recovery, sustained CPU/pool saturation after tuning, or network latency hurting activation. User count alone is not a migration threshold. Import persistence remains P1.',64,500,504)
bullet('Future AWS / GCP / Azure','The same compiled service, PostgreSQL, provider adapters and worker boundaries can move. Rehearse restore, cut over one hostname, validate writes and preserve rollback. Cloud egress/DB/backup costs require a fresh decision.',638,500,495)
audit_count=prod_audit.get('metadata',{}).get('vulnerabilities',{}).get('total')
small(f'Final production-artifact audit: {number(audit_count)} advisory entries. Four moderate dev-tool entries are outside the production-only artifact. Earlier 5 Oct audit (5 high / 5 moderate) is historical, not current. No cloud deployment or Git push is claimed.')
end()

# 27
heading('Evidence ledger','Know the artifact. Know the limit.','5 Oct source, 6 Oct qualification and 7 Oct review evidence remain separate; no green test is silently promoted to a live claim.')
table(['CLASS','LATEST EVIDENCE','LIMIT'],[
('5 Oct snapshot','19649b3; original 1,240-unit log, inventory and build12 archive','Historical baseline; old auth/config/audit findings were superseded in changed source.'),
('6 Oct native',number(native.get('directedSelectedPassed'))+' selected / '+number(native.get('directedProductPassed'))+' product; '+tally(len(passed_seeds),seed_target)+' seeds','Sealed build 13 '+('passes' if native_directed_verified and native_seeds_verified else 'pending')+'; build 14 password cycle has separate proof.'),
('6 Oct SQL','Current 31 progress, 6 Apple recovery, 27 content-policy cases','Actual migrated scratch PostgreSQL; synthetic provider transport; no live grant revocation.'),
('Production database','Additive schema plus four real identities mapped to live Clerk','Four identities preserved. Restart/readiness pass; candidate14 production password path passes.'),
('Actual recovery','Post-cutover dump restored 16 users; both scratch DBs removed','Four exact production mappings/20 tables match. June dump retired; '+('historical logs retired; ' if legacy_log_retirement_verified else 'legacy logs retained; ')+'same-disk only.'),
('Public landing',('Effective 6 Oct; 5 canonical / 8 candidate legal layouts; 8 routes / 27 assets' if effective_policy_verified else 'Draft '+('verified' if draft_landing_verified else 'pending')+'; '+number(landing_fresh_layouts)+' fresh hero / '+number(landing_fresh_gallery)+' gallery; 8 routes / '+number(draft_landing.get('publicAssetHashMatchesPerOrigin'))+' assets'),('4 navigation / 1 anchor; prior 19 Home / 3 hero / 4 gallery. Public copy/bytes do not qualify consumer workflows.' if effective_policy_verified else 'Prior brand '+number(landing_prior_brand_layouts)+'/'+number(landing_prior_brand_gallery)+'; legal '+number(draft_landing.get('priorLegalMobileChecksReused',0))+'/paragraph '+number(landing_prior_device_refs)+'/Home '+number(landing_prior_home_refs)+' refs. Effective policy/identity/retention are separate.')),
('Current Apple review','Build 1.0 (14) owner-submitted 6 Oct; rejected 7 Oct, 2.1 Information Needed','Physical recording missing; 3,584-character reply draft saved, unsent. Notes/samples not updated.')],[175,477,420],rowh=64,fs=15)
small('Receipt hashes are recorded in render-evidence.json at build time. Failed initial load, concurrent unit timeout and unpromoted landing-build attempts remain in the QA record rather than being removed.')
end()

# 28
heading('Source index / local','A reviewable path back to the work.','Repository-relative references; the companion evidence file links source and receipts without copying private user data.')
refs=[('E01','ios/project.yml; releaseConfig; clerk-cutover.md','Final Release keys, issuer, binary and migration'),
('E02','server/src/auth/{clerk,authConfig,identity}.ts','Identity verification and expected issuer'),
('E03','server/src/services/{erasure,deletionLedger}.ts; server/ops/ledger.mjs','Durable deletion + independent journal'),
('E04','ios/.../Profile/AccountDeletion.swift; App/RootView.swift','Cold uncertainty hold and truthful notices'),
('E05','ios/Sources/App/{AppModel,AccountLocalStore,RewatchStore}.swift','Owner scope and stale local-writer rejection'),
('E06','ios/Sources/App/{MutationJournal,SyncCenter}.swift; clientMutations.ts','Pre-dispatch payload + replay; fresh qualification'),
('E07','design/onboarding-2026-10-04/IMPORT-VERIFICATION.md','Historical supported imports and limitations'),
('E08','docs/history-import-release-2026-10-04.md; franchise-cta/','Historical builds10/11 interaction proof'),
('E09','landing/lib/legal-content.ts; landing/docs/vercel-release-2026-10-06.md','Effective disclosures / qualified publication' if effective_policy_verified else 'Draft disclosures and publication prerequisites'),
('E10','ios/.../Trailer/TrailerPlayback.swift; server/qa/content-policy.ts','Trailer privacy + consumer content filtering'),
('E11','server/src/{env,runtimePolicy,releaseConfig}.ts','Free-runtime production guards'),
('E12','server/src/{server,index,observability}.ts; sync/cron.ts','Metrics, bounded cron and graceful lifecycle'),
('E13','server/src/import/{previews,service}.ts','In-memory import state remains P1'),
('E14','server/ops/; docs/qa/2026-10-06/operations/','26 checks, actual 0015 and backup/restore'),
('E15','docs/qa/2026-10-06/{native-results.json,load-testing/}','Current native + final compiled capacity receipts')]
y=217
for ident,path,desc in refs:
    txt(ident,64,y,13,ORANGE,'ArialBold'); txt(path,119,y,12,INK,w=700); txt(desc,840,y,12,MUTED,w=293); y+=32
small('Exact paths and current line links are in evidence.md. Source state is not a deployed-service claim. The independent journal contains private pending identifiers and never belongs in the landing upload or document.')
end()

# 29–30 — Official references are dated; no freshly checked claim is invented.
sources=[
('S01','Apple App Review Guidelines','https://developer.apple.com/app-store/review/guidelines/','Completeness, account access, login, UGC and privacy.'),
('S02','Apple upcoming requirements','https://developer.apple.com/news/upcoming-requirements/','Recheck upload SDK and age-rating requirements at submission.'),
('S03','Apple account deletion','https://developer.apple.com/support/offering-account-deletion-in-your-app/','Account deletion initiated in app; full lifecycle matters.'),
('S04','Apple App Privacy details','https://developer.apple.com/app-store/app-privacy-details/','Disclose actual identity, usage and diagnostics behavior.'),
('S05','Apple SDK requirements','https://developer.apple.com/support/third-party-SDK-requirements/','Applicable privacy manifests and signatures.'),
('S06','Apple Developer Program','https://developer.apple.com/programs/','Existing membership is paid; no new recurring spend assumed.'),
('S07','Apple screenshot specifications','https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/','Use current iPhone screenshot slots and shipping behavior.'),
('S08','Apple EU trader requirements','https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/','Owner supplies truthful status and applicable verification.'),
('S09','Apple regional ratings / RCN','https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/','Broader Korea RCN criteria; actual availability remains unverified.'),
('S10','Vercel Hobby','https://vercel.com/docs/plans/hobby','Existing free personal/non-commercial hosting; review before commercial change.'),
('S11','Clerk pricing','https://clerk.com/pricing','Verify actual production plan and quota; no trial or paid add-on.'),
('S12','Next.js static exports','https://nextjs.org/docs/app/guides/static-exports','Official Next static HTML/CSS/JS export used for landing.'),
('S13','Next.js on Vercel','https://vercel.com/docs/frameworks/full-stack/nextjs','Framework output detection; avoid explicit out override.'),
('S14','Apple XCUIAutomation','https://developer.apple.com/documentation/xcuiautomation','Local free native UI automation framework.'),
('S15','AniList API terms','https://docs.anilist.co/guide/terms-of-use','Record for later commercial review; no outreach in validation.'),
('S16','TMDB API FAQ','https://developer.themoviedb.org/docs/faq','Non-commercial API use and attribution reference.'),
('S17','YouTube privacy-enhanced embeds','https://support.google.com/youtube/answer/171780','Non-personalized embed behavior; ads may still appear.'),
('S18','Apple sign-in deletion / TN3194','https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple','Revoke tokens; manual fallback when credentials are absent.'),
('S19','Apple usage analytics','https://developer.apple.com/help/app-store-connect-analytics/engagement/app-usage','Opt-in usage data and active-device definitions.'),
('S20','Apple privacy and tracking','https://developer.apple.com/app-store/user-privacy-and-data-use/','Actual tracking behavior determines ATT disclosures.'),
('S21','Apple custom product pages','https://developer.apple.com/app-store/custom-product-pages/','Audience-specific store pages and acquisition measurement.'),
('S22','Apple product page optimization','https://developer.apple.com/help/app-store-connect/create-product-page-optimization-tests/overview-of-product-page-optimization/','Experiment only when counts support an inference.'),
('S23','Clerk migration overview','https://clerk.com/docs/guides/development/migrating/overview','Development identities need a safe production migration.'),
('S24','Clerk production environments','https://clerk.com/docs/guides/development/managing-environments','Live production configuration differs from development.')]
for idx in range(2):
    heading('Source index / official',f'Primary references. {idx+1} / 2','References reviewed 5-6 Oct; Apple revocation and YouTube embed guidance reviewed 6 Oct. Recheck at submission.')
    y=211
    for code,name,url,desc in sources[idx*12:(idx+1)*12]:
        txt(code,64,y,13,ORANGE,'ArialBold'); txt(name,121,y,17,BLUE,'ArialBold')
        c.linkURL(url,(120,H-y-21,642,H-y+3),relative=0,thickness=0)
        txt(desc,652,y,14,MUTED,w=481); md.append(f'[{name}]({url})')
        line(64,y+31,1136,y+31); y+=41
    small('Clickable blue links are factual references, distinct from proposed targets and owner decisions. Monitoring-vendor plans are not part of the implemented zero-spend solution.')
    end()

# 31
heading('Release decision','Build trust. Reach people.',dark=True)
txt('Protect their progress.\nMake the first session easy.\nResolve the App Store review.',64,225,53,'#FFFFFF','ArialBold',w=1060,leading=67)
label('CURRENT STATUS',64,475)
txt('Consumer ready' if consumer_ready else 'Production consumer proof pending',64,507,27,GREEN if consumer_ready else ORANGE,'ArialBold')
txt(f'Build {store_build}: Rejected 2.1; saved reply remains unsent' if review_rejected_verified else 'Submitted for App Store review' if submitted else f'Build {store_build}: review handoff pending',64,551,24,RED if review_rejected_verified else GREEN if submitted else '#FFFFFF','ArialBold',w=1050)
txt('Four users preserved, installed operations and frozen 5× capacity pass. Build 14 password proof and owner-reported SSO remain scoped. Apple now needs the physical latest-OS recording and six answers; live erasure and Files proof remain.',64,604,21,'#BDBDC6',w=1035,leading=29)
small('Keep v1 free and public comments off. Use actual activation and repeat-use evidence to choose P1 work, future commercial review and any cloud move. No provider licensing outreach before validation.',64,714,1060,'#9898A4')
end()

# Optional 32 — Root approves final corrected images before this page can appear.
# Marketing visual representations never substitute for production-auth or consumer proof.
if campaign_assets_verified:
    from PIL import Image
    heading('Launch creative / approved','One brand. Four first impressions.','Four corrected screenshots and header are saved in App Store Connect. Marketing representations remain separate from actual production proof.',dark=True)
    for i, panel in enumerate(campaign_panels):
        x, y, box_w, box_h = 64+i*274, 223, 250, 435
        panel_path = ROOT / panel['path']
        iw, ih = Image.open(panel_path).size
        if ih <= iw: raise RuntimeError('Campaign panels must be portrait images.')
        scale = min(box_w/iw, box_h/ih)
        dw, dh = iw*scale, ih*scale
        c.drawImage(str(panel_path),x+(box_w-dw)/2,H-y-dh,dw,dh,mask='auto')
        txt(panel.get('label',CAMPAIGN_PANEL_PLACEHOLDERS[i]),x,671,13,'#BDBDC6',w=box_w)
    c.drawImage(str(ROOT/campaign_icon['path']),64,H-714-24,24,24,mask='auto')
    txt('Canonical native icon · approved creative assets are fingerprinted with this render.',104,719,11,'#BDBDC6',w=1029)
    end()

c.save()
(HERE/'release-plan.md').write_text('\n\n'.join(part for part in md if str(part).strip())+'\n')
(HERE/'sources.json').write_text(json.dumps([dict(id=a,title=b,url=d,note=e) for a,b,d,e in sources],indent=2)+'\n')
(HERE/'layout-checks.json').write_text(json.dumps({'pages':page_no,'issues':checks},indent=2)+'\n')
(HERE/'render-evidence.json').write_text(json.dumps({'schemaVersion':1,'revision':'2026-10-07',
    'builtAtUTC':datetime.now(timezone.utc).isoformat(),'pdfSha256':hashlib.sha256(OUT.read_bytes()).hexdigest(),
    'originalSourceRevision':'19649b3748eac6ca7508f86ad96be9f533406fcb',
    'receiptSha256':receipts,'counts':{'serverUnits':units,'nativeProductPassed':native.get('directedProductPassed'),
    'nativeProductTotal':native.get('directedProductTotal'),'completedPassingSeeds':len(passed_seeds),'seedTarget':seed_target,
    'progressSQL':protocol.get('summary',{}),'deletionSQL':deletion.get('summary',{}),'recoverySQL':recovery.get('summary',{}),
    'statusRecoverySQL':status_recovery.get('summary',{}),'operations':ops_qualified.get('summary',{}).get('passed')},
    'finalCapacityQualification':load_state,'nativePreDispatchPersistenceVerified':native_predispatch_verified,'nativeMonitorRestartVerified':native_monitor_verified,
    'nativeDirectedQualificationVerified':native_directed_verified,
    'nativeSeedQualificationVerified':native_seeds_verified,
    'nativeQualificationScope':'sealed build 13 baseline; does not qualify changed build 14 auth code',
    'sealedNativeBaselineRuntimeSha256':native.get('runtimeCodeFingerprint',{}).get('sha256'),
    'productionArchiveVerifiedFromReceipt':archive_verified,'nativeUploadVerifiedFromReceipt':upload_verified,
    'appStoreProcessingVerified':upload_processing_verified,'actualSdkArchiveInventoryVerified':sdk_archive_verified,
    'finalBuildSelectedVerifiedFromReceipt':selected_build_verified,
    'fourRealIdentitiesMigratedVerified':identities_migrated,
    'postClerkCutoverRestoreVerified':post_cutover_restored,
    'actualGracefulRestartVerified':actual_operations.get('gracefulRestart',{}).get('oldWrapperExitedZero') is True,
    'ordinaryReviewAccountProvisioned':review_account.get('actualOrdinaryReviewAccountReadyForNativeLogin') is True,
    'candidate14ActualProductionPasswordCycleVerified':candidate14_password_verified,
    'candidate14RuntimeSourceSha256':candidate14_native.get('runtimeSourceSHA256'),
    'candidate14SignedArchiveVerified':candidate14_archive_verified,
    'candidate14UploadVerified':candidate14_upload_verified,
    'candidate14ProcessingVerified':candidate14_processing_verified,
    'candidate14SelectedVerified':candidate14_selected_verified,
    'candidate14StoreStage':candidate14_store_stage,
    'candidate14FilesSheetPresented':candidate14_files.get('ordinaryFilesSheetPresented') is True,
    'candidate14FilesImportExportVerified':candidate14_files_verified,
    'candidate14FilesStatus':candidate14_files.get('status','pending'),
    'candidate14ErasureStatus':candidate14_erasure.get('status','pending'),
    'candidate14IsolatedNativeDeletionExecuted':candidate14_erasure.get('permanentDeletionExecuted') is True,
    'targetAppStoreBuild':store_build,
    'selectedAppStoreBuild':store_build if selected_build_verified else None,
    'ownerDeclarationsSavedVerified':owner_declarations_verified,
    'publicReviewNotesSavedVerified':review_notes_saved,
    'publicReviewNotesLength':review_notes_length,
    'publicReviewNotesSha256':review_credentials.get('notesSHA256') if current_review_notes_saved else review_notes.get('notesSHA256'),
    'reviewerCredentialsSavedSupported':review_credentials_saved,
    'reviewCredentialReadbacksRedacted':review_credentials.get('usernameReadbackRedacted') is True and review_credentials.get('passwordReadbackRedacted') is True,
    'reviewCredentialExactByteEqualityVerified':review_credentials.get('credentialExactPersistenceVerification',{}).get('verified') is True,
    'readyForReviewDraftValidated':review_draft_validated,
    'readyForReviewDraftScope':'Historical 6 October pre-submission validation; superseded for current review state by 7 October rejection',
    'ownerSubmittedBeforeRejectionVerified':submitted and review_rejected_verified,
    'appStoreCurrentReviewState':review_rejection.get('versionState') if review_rejected_verified else release.get('appStore',{}).get('versionStatus'),
    'appStoreCurrentSubmissionState':review_rejection.get('submissionState') if review_rejected_verified else release.get('appStore',{}).get('reviewSubmissionStatus'),
    'appStoreRejectionVerified':review_rejected_verified,
    'appStoreRejectionSubmissionId':review_rejection.get('submissionId') if review_rejected_verified else None,
    'appleInformationRequestHeading':review_rejection.get('messageHeading'),
    'appleSpecificCrashOrLoginDefectReported':review_rejection.get('specificCrashOrLoginDefectReported'),
    'appleReplacementBuildRequiredByMessage':review_rejection.get('replacementBuildRequiredByMessage'),
    'applePhysicalLatestOsRecordingRequired':apple_physical_recording_required,
    'applePhysicalRecordingVerified':review_rejection.get('recordingVerified') is True,
    'appleReviewResponseDraftSavedVerified':review_response_draft_verified,
    'appleReviewResponseDraftCharacters':review_response_length,
    'appleReviewResponseBudget':review_response_draft.get('replyBudget'),
    'appleReviewResponseBudgetUnit':'Unicode characters',
    'appleReviewNotesBudget':review_response_draft.get('notesBudget'),
    'appleReviewNotesBudgetUnit':'UTF-8 bytes',
    'applePreparedReviewNotesUtf8Bytes':len(prepared_notes_bytes) if prepared_notes_bytes is not None else None,
    'appleBudgetOfficialSources':{
        'reviewNotes':'https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/',
        'reply':'https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages/'},
    'appleReviewResponseDraftSha256':review_response_draft.get('bodySHA256'),
    'sixRequestedAnswersDrafted':review_response_draft_verified,
    'appleReviewResponseSentVerified':review_response_draft.get('replySent') is True,
    'appleReviewNotesUpdatedAfterRejectionVerified':review_response_draft.get('notesReplaced') is True,
    'appleReviewSamplesUploadedVerified':review_response_draft.get('samplesUploaded') is True,
    'appleReviewSampleZipIntegrityVerified':review_samples.get('archiveIntegrityVerified') is True,
    'appleReviewSampleZipBytes':review_samples.get('bytes'),
    'appleResubmittedAfterRejectionVerified':review_response_draft.get('resubmitted') is True,
    'reviewerTwoFreshPasswordLoginsWithoutOtpVerified':reviewer_fresh_no_otp_verified,
    'reviewerNoOtpProofScope':'dedicated review account on Release 14 iOS 27 simulator; no consumer/global/SSO/device claim',
    'actualReviewValidationRequiresCredentials':review_credentials_required,
    'reviewValidationGenericErrorObserved':False if review_draft_validated else bool(review_validation.get('additionalGenericBanner')),
    'historicalReviewValidationGenericErrorObserved':bool(review_validation.get('additionalGenericBanner')),
    'clerkPersonalWorkspaceConfigApiBlocked':clerk_personal_api_blocked,
    'temporaryClerkManagementTokensRemoved':clerk_management.get('localTokenVerifierCodeURLRemoved') is True,
    'clerkManagementAccessJWTExpiryUTC':clerk_management.get('actualJWTExpiryUTC'),
    'appStorePrivacyLabelsPublishedVerifiedFromReceipt':privacy_labels_published,
    'websitePolicyPublicationScope':'qualified effective static publication; consumer workflows and Store labels retain separate evidence' if effective_policy_verified else 'draft landing; Store labels do not make website policy effective',
    'effectiveWebsitePolicyPublishedVerified':effective_policy_verified,
    'effectiveWebsitePolicyDate':effective_landing.get('effectiveDate') if effective_policy_verified else None,
    'currentLandingDeployment':public_landing.get('deploymentId'),
    'currentLandingSourceManifestSha256':public_landing.get('sourceManifestSha256'),
    'effectiveLandingBrowserChecks':{'freshCandidateLegalMobileLayouts':effective_landing.get('freshCandidateLegalMobileLayouts'),
        'freshCanonicalLegalMobileLayouts':effective_landing.get('freshCanonicalLegalMobileLayouts'),
        'freshLegalNavigationChecks':effective_landing.get('freshLegalNavigationChecks'),
        'freshSettledRetentionAnchorChecks':effective_landing.get('freshSettledRetentionAnchorChecks'),
        'priorHomeReference':effective_landing.get('priorHomeUiReferenceRunSize'),
        'priorHeroReference':effective_landing.get('priorHeroHardwareResponsiveChecks'),
        'priorGalleryReference':effective_landing.get('priorGalleryFlowChecks')},
    'storeArtworkUploadedVerified':artwork_saved_verified,
    'portraitExportsFormatVerified':portrait_exports.get('passed') is True,
    'headerExportFormatVerified':header_export.get('passed') is True,
    'campaignCreativePageIncluded':campaign_assets_verified,
    'productionClerkInstanceVerified':clerk_instance_verified,'productionClerkDnsVerified':clerk_dns_verified,
    'canonicalLandingHttpsVerified':domain_verified,'googleProductionSignInVerified':google_verified,
    'googleProductionConsentClientSetupVerified':google_setup_verified,
    'unusedGoogleOriginalCredentialRetirementVerified':google_secret_retirement_verified,
    'unusedGoogleOriginalCredentialRetirementCompletedAt':google_secret_retirement.get('completedAt'),
    'googleClerkConnectionEnabled':provider_connections_enabled,
    'appleClerkConnectionEnabled':provider_connections_enabled,
    'productionProviderConnectionsEnabledVerified':provider_connections_enabled,
    'productionProviderConfigurationObservedAtUTC':provider_frontend.get('observedAtUTC'),
    'nativeProviderButtonsAndEntryCheckpointsVerified':native_provider_entry_verified,
    'nativeProviderEntryScope':'cold Release 14 iOS 27 simulator; Google empty login page and Apple Account Settings prerequisite, no authenticated SSO session',
    'googleAuthenticatedNativeSessionVerified':native_provider_entry.get('google',{}).get('authenticatedAppSessionProven') is True,
    'appleAuthenticatedNativeSessionVerified':native_provider_entry.get('apple',{}).get('authenticatedAppSessionProven') is True,
    'googleOwnerReportedTestFlightSignInPassed':owner_provider_test_reported,
    'appleOwnerReportedTestFlightSignInPassed':owner_provider_test_reported,
    'ownerTestFlightSignInEvidenceMethod':owner_provider_test.get('evidenceMethod'),
    'ownerTestFlightDeviceBuildIndependentlyRead':owner_provider_test.get('buildNumberIndependentlyReadFromOwnerDevice') is True,
    'ownerTestFlightSignInScope':'Google/Apple login only on owner-selected iPhone/TestFlight; phone model/OS/build screen, cold restore, Files, erasure, VoiceOver and WAN unverified',
    'existingTestFlightBuild14GroupVerified':testflight_group_verified,
    'testFlightPhysicalInstallVerified':testflight_group.get('physicalInstallProven') is True,
    'deviceQualificationScope':'Apple 7 October message requires a physical-device latest-OS recording. Earlier owner-reported SSO login is separate; additional iOS18/VoiceOver/WAN qualification remains recommended and unverified.',
    'draftLandingPublicationVerified':draft_landing_verified,'draftLandingDeployment':draft_landing.get('deploymentId'),
    'draftLandingSourceManifestSha256':draft_landing.get('sourceManifestSha256'),
    'draftLandingBrowserChecks':{'newLegalMobile':draft_landing.get('newLegalMobileBrowserChecks'),
        'newPrivacyMobile':draft_landing.get('newPrivacyMobileBrowserChecks'),
        'freshLayoutCount':landing_fresh_layouts,'freshLayoutScope':landing_fresh_layout_label,
        'freshHeroLayouts':draft_landing.get('freshHeroLayouts'),
        'freshHeroGalleryFlowChecks':draft_landing.get('freshHeroGalleryFlowChecks'),
        'freshResponsiveLayouts':draft_landing.get('freshResponsiveLayouts'),'freshGalleryChecks':landing_fresh_gallery,
        'priorBrandingResponsiveReference':landing_prior_brand_layouts,
        'priorBrandingGalleryReference':landing_prior_brand_gallery,
        'priorDeviceParagraphReference':landing_prior_device_refs,
        'priorLegalScopedReuse':draft_landing.get('priorLegalMobileChecksReused'),
        'priorHomeScopedReference':landing_prior_home_refs},
    'legacyLogRetirementVerified':legacy_log_retirement_verified,
    'managedDiagnosticRetentionScope':'Daily capped files scheduled for removal seven days after last entry; individual records can be about eight days old. This is not exact per-record seven-day deletion.',
    'canonicalStoreUrlsSavedVerified':store_urls_verified,
    'ageQuestionnaireSavedVerified':age_rating_verified,'calculatedAgeRating':age_rating.get('calculatedRating'),
    'savedPrivacyDraftCategories':privacy_draft_category_count,
    'sdkDeviceIdDisclosureNeeded':sdk_privacy.get('clerk', {}).get('deviceIDPrivacyDisclosureNeeded') is True,
    'finalSdkArchiveInventory':sdk_archive_inventory or 'pending',
    'applePrivateRelaySenderVerified':apple_relay_verified,'currentBackendArtifact':current_artifact.get('artifact'),
    'productionAppleAdditiveMigrationVerified':apple_migration_verified,
    'trailerPrivacyLiveValidationVerified':trailer_verified,
    'previousCapacityQualification':prior_load.get('qualification'),
    'productionBackendCutoverVerified':backend_live,'jobsInstalledVerified':jobs_live,
    'consumerReadyVerified':consumer_ready,'submittedForReviewVerified':submitted,
    'contentPolicyCases':len(content_policy.get('cases', [])),'currentOperatorChecks':ops_qualified.get('summary', {}),
    'pages':page_no,'layoutIssues':checks,'requiresVisualInspection':True},indent=2)+'\n')
sync_evidence_companion(json.loads((HERE/'render-evidence.json').read_text()))
print(json.dumps({'pdf':str(OUT),'pages':page_no,'layout_issues':checks,'finalCapacity':load_state},indent=2))
