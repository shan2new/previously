# Physical iPhone recording — Previously 1.0 (14)

Prepared 7 October 2026; **recording and deletion remain incomplete**. Apple's [actual message](/Users/shan2new/Projects/previously/docs/qa/2026-10-07/app-store/rejection-dom.txt) requires a physical-device recording starting with launch and showing use, registration, login and deletion. It identifies no specific defect or need for a new build.

## Start here

1. Sign in normally to the existing disposable QA account; add one show and save episode 1 watched.
2. Say **“QA ready”** and wait for root's ready baseline/target check **before Delete**.
3. Record Clip 1: launch, login, ordinary use, then your own **Delete account** after that check.
4. Wait for the passed post-check; only then record Clip 2's fresh disposable registration.

## Before recording

- Use your actual iPhone and TestFlight **Previously 1.0 (14)**. Save separate proof of the TestFlight version/build, **Settings → General → About** model/iOS version, and **General → Software Update**. Exclude serial numbers, IMEI and personal account details. Apple lists **iOS 27.0.1**, released 28 September 2026, as the latest public release on 7 October; confirm the current update offered on your phone. [Apple release list](https://support.apple.com/en-us/100100), [update instructions](https://support.apple.com/en-us/118575).
- Our recommended packaging is two labeled clips on the same phone: **existing disposable QA login/use/deletion first**, then **new disposable registration**. Each starts with app launch. The two-clip choice preserves the existing verifier; **Apple has not confirmed that it will accept this packaging**. Aim for 3–5 minutes of demonstration plus verification/wait time as practical guidance. Apple's request specifies neither that duration nor a single-take condition. Do not imply one account or continuous footage. [Actual request](/Users/shan2new/Projects/previously/docs/qa/2026-10-07/app-store/rejection-dom.txt), [recording research](/Users/shan2new/Projects/previously/docs/release/2026-10-07/spike-recording-evidence.md).
- Never delete the permanent App Review account, a migrated user, or your personal Google/Apple identity. The existing deletion QA credentials were supplied privately. No password, verification code or inbox should appear in shared footage. If a secret appears, keep the original private and flag the exact area for masking in an explicitly labeled Apple copy.
- Start Screen Recording in Control Centre, wait for the countdown, return to the Home Screen, then tap Previously. Stop with the recording indicator; save the original from Photos. [Apple instructions](https://support.apple.com/en-in/102653).

## Clip 1 — existing disposable account: login, ordinary use, deletion

**Prepare first:** sign in normally to the existing disposable QA account, completing Device Trust if requested; it has no reviewer exception. Add **exactly one show → Just starting**, mark **episode 1** watched, and wait for saving. Tell root **“QA ready”**. Root checks the target and captures `baseline_captured`; the earlier `baseline_not_ready` is insufficient. Then sign out so the clip shows login.

1. Record from the Home Screen; launch Previously. Use **Sign in → Enter your email → Continue → Enter password → Continue**, completing actual verification prompts privately. Do not substitute the reviewer to avoid verification. **Use another method → Sign in with your password** is a fallback only if offered; record the route that actually occurs.
2. Show **Home**, the one title and watched episode 1, then **Library, Schedule, Feed and Discover**. Open a search result; do not add another title or watch another episode before deletion. Open **Profile**, show settings and the **1.0 (14)** footer.
3. In **Profile → Delete account**, show **Delete your account?** and the irreversible deletion explanation. Confirm the named disposable identity privately with root. Root records its local deletion-start marker after the ready baseline. **You may press your own final Delete account button** once those safeguards are ready; an agent operating the irreversible button would need your action-time confirmation.
4. Record the result. **“Your account and tracking data have been deleted.”** means completed; **“Deletion requested…”** means pending; **Confirming deletion / Check status** means recovery. Report pending/recovery honestly. Relaunch once and show the signed-out welcome without the old library/session. Stop. Do not re-enter the deleted email: the combined form could start registration.
5. Root requires read-only `server_provider_erasure_verified` with five protected identities unchanged. **Wait before Clip 2.** No direct provider cleanup, baseline overwrite or deletion of another account.

## Clip 2 — new ordinary registration

After Clip 1's qualified post-check, use a separate unused, owner-controlled email. You enter the new password and accept applicable terms yourself. Root records this new disposable identity separately; no agent creates it or changes verification settings.

1. Record from the same phone's Home Screen; launch Previously. Use **Sign in → Enter your email → Continue** with the unused email. Build 14's combined form routes new email to registration; do not invent a **Sign up** button. This route is source-backed, not yet recorded on the phone.
2. Complete the actual prompts, which can include **Password / Choose your password**, **Check your email**, and **Profile details → Continue**. Keep password/code entry private; never weaken Device Trust or use a test code. Show the authenticated first-run screens: **What do you watch? → Continue**, **Pick your shows**, **Where are you? → Just starting**, then **Go to Home**.
3. Show the new library, a detail and one episode mark. Use **Profile → Sign out → Sign out**, sign in again, and show the library returns. Stop. Do not delete this new account without its own target/baseline plan.

## Applicable features and optional Files evidence

Public comments/replies are disabled in the qualified release. Anonymous numeric ratings are declared as UGC; show that interface if encountered. **Report… / Block…** reply controls and blocked accounts require enabled comments. Do not fabricate them or enable comments for the video. If the phone exposes user replies, report the difference and demonstrate available reporting/blocking. [UGC declaration](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/app-store/age-rating-saved.json), [UI gate](/Users/shan2new/Projects/previously/ios/Sources/Features/Profile/ProfileView.swift:808).

This release is free and has no paid feature or in-app purchase flow to demonstrate. External streaming services may charge separately; Previously does not stream full episodes. [Release notes](/Users/shan2new/Projects/previously/docs/release/2026-10-06/app-review-notes-draft.md:11).

If convenient, after the guarded erasure checks use the new disposable account for **Profile → Import your history → MyAnimeList → Choose the file**, then the existing synthetic partial/all-skipped XML samples, and **Profile → Export library → Save to Files**. Show preview notes and the actual saved file. This closes a separate outstanding consumer check; it is not an added requirement in Apple's message. [Samples and expected outcomes](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/sample-import-files.json), [earlier system-picker limitation](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/files-recheck/result.json).

## Evidence handoff and operator guard

Send root both originals, model/iOS/build/date and sanitized OS/TestFlight proof. Root reviews secrets, outcomes and timestamps before preparing Apple attachments/link and Notes. Simulator footage and earlier owner-reported SSO success cannot replace this physical recording.

Use **Photos → Share → AirDrop → your Mac** to transfer the original recordings. Wi-Fi and Bluetooth must be enabled and the devices nearby. Selective USB import into Photos is the free fallback using existing hardware. A wired QuickTime recording is another option, through **File → New Movie Recording → Camera: iPhone**. QuickTime exports MOV, so do not promise an MP4 export or rename the container. No official review-specific attachment size/type limit was established in the research; inspect the actual upload response. Marketing App Preview limits do not establish limits for this evidence. [Apple AirDrop](https://support.apple.com/guide/iphone/use-airdrop-to-send-items-iphcd8b9f0af/ios), [USB import](https://support.apple.com/en-us/120267), [QuickTime recording](https://support.apple.com/guide/quicktime-player/record-a-movie-qtp356b55534/mac), [QuickTime export](https://support.apple.com/guide/quicktime-player/export-movies-qtp20e395859/mac), [attachment findings](/Users/shan2new/Projects/previously/docs/release/2026-10-07/spike-recording-evidence.md).

When actual links and attachments are ready, validate the **Reply's 4,000-character** budget and **Review Notes' 4,000-byte** budget separately. The current identical templates are 3,584 characters and UTF-8 bytes including their final newline; replacement URLs may change this. [Apple Reply help](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages/), [Apple Notes reference](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/), [budget receipt](/Users/shan2new/Projects/previously/docs/qa/2026-10-07/app-store/review-template-budget-check.json).

Operator sequence: `live-erasure-verify.py baseline` → require `baseline_captured` → exact-target owner check → `live-erasure-qa.py mark-deletion-start --owner-action-authorized` (local marker only) → actual owner app deletion → `live-erasure-verify.py post` → require `server_provider_erasure_verified`. These private helpers are under `/Users/shan2new/.config/previously/release/`; [full verifier instructions](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/live-account-erasure-verification.md). The verifier requires exactly the five protected provider users plus its one disposable target. Fresh registration must therefore follow qualified post-checks. A backend restart is a separate operational check, not part of Apple's requested video.

Inspected now: message, build facts, UI labels, registration routing, samples and verifier guard. Still needed: physical recordings, device/latest-OS/build proof, registration/login/deletion outcomes, baseline/post readback and any claimed Files result. This preparation changed only this guide.

UI sources: [Sign-in presenter](/Users/shan2new/Projects/previously/ios/Sources/Auth/SignInView.swift:134), [resolved SDK new-email routing](/Users/shan2new/Projects/previously/ios/build/DerivedData/SourcePackages/checkouts/clerk-ios/Sources/ClerkKitUI/Components/Auth/AuthStartView.swift:528), [first-run labels](/Users/shan2new/Projects/previously/ios/Sources/DesignSystem/Copy+FirstRun.swift:18), [account confirmation labels](/Users/shan2new/Projects/previously/ios/Sources/DesignSystem/Copy+Screens.swift:101), [deletion outcome copy](/Users/shan2new/Projects/previously/ios/Sources/Features/Profile/AccountDeletionNotice.swift:7).
