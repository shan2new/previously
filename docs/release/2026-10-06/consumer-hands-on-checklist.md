# Consumer hands-on checks — Release 1.0 (14)

> Current update — 7 October 2026: [Apple rejected the owner-submitted 1.0 (14) for 2.1 Information Needed](/Users/shan2new/Projects/previously/docs/qa/2026-10-07/app-store/rejection-receipt.json). The earlier Ready for Review / final-submit-pending statements below are historical 6 October snapshots. Apple now requires a physical-device latest-OS recording and six factual answers in the reply and Review Notes. No specific crash/login defect or replacement build is requested. The recording and response/resubmission are not completed.

This is recommended remaining hands-on qualification using one existing iPhone and production build 1.0 (14). Record its model, iOS version, install source and test time. A run on another iOS version does not establish iOS 18 behavior. Missing local hardware/runtime is not an app defect or a new App Store submission requirement. No device purchase, paid service or licensing outreach is part of this checklist.

Current evidence: [production password/cold-restore/sign-out cycle](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/candidate14-production-native.json) and [two fresh reviewer password logins without OTP](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/review-otp-native-recheck.json) passed on the actual Release 14 iOS 27 simulator. [The latest inventory](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/accessible-native-surfaces.json) has no connected physical iPhone or iOS 18 runtime; ordinary Files selection remains limited by the current native driver. [The owner directly reports successful Google and Apple logins on the chosen iPhone/TestFlight path](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/provider-owner-testflight.json), recorded at 17:14:30 UTC. Model, iOS version, displayed build number and provider cold restore were not captured; the requested candidate was 1.0 (14). Phone Files/self-test is continuing; this report does not complete those checks or the device/cold-restore details.

[The effective website policy dated 6 October 2026 is published and verified](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/landing-final/effective-publication/qualification-receipt.json), with [independent canonical privacy readback](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/landing-final/effective-publication/root-canonical-privacy-readback.json). Files completion and live isolated erasure remain unverified; publication does not complete those journeys.

## Reviewer and everyday use

- [ ] Install/open 1.0 (14). Open, dismiss and reopen Sign in; it should remain responsive. Use the existing private App Review login. Expected route: email → password → Home, without OTP or “Use another method.” Do not change authentication settings or copy credentials into evidence.
- [ ] Confirm the original synthetic library: Attack on Titan watched through S1E1, with S1E2 next; Reacher has S1E1 next; Death Note is completed at 37 episodes. Preserve these entries.
- [ ] Open Home, Schedule, Feed, Library and Discover; open a show and its episode list, return, search for a title, replace the query and clear it. Verify the results match the current query and navigation remains usable. Public comments remain off.
- [ ] Complete the Files checks below. Use the added Cowboy Bebop entry for progress tests: mark episode 4, Undo to 3, then cold-launch and confirm 3. Briefly disconnect the network, mark 4, close/reopen, reconnect and confirm 4 remains after synchronization and another cold launch. Record pending/error behavior honestly.
- [ ] Play an available trailer; exercise pause, mute and fullscreen, then return with the same playback clock. Open a regional provider link and return. Test a larger text size, Reduce Motion, a short VoiceOver pass through tabs/progress/modal dismissal, and actual haptics. Record each separately; one screenshot proves none of these interactions.
- [ ] Sign out: welcome must hide the library. Cold-launch and sign in again; the same library must return without repeating first-run setup. Repeat the short search/progress readback on mobile data to establish an actual WAN path.

## Ordinary Files import and export

Put these existing synthetic documents in the iPhone's Files app using an existing transfer method; simulator staging is not evidence that they are visible on the phone:

- [Partial source](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/sample-import-files/review-partial.xml): one allowed title plus one adult exclusion.
- [All-skipped source](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/sample-import-files/review-all-skipped.xml): one adult exclusion only.

- [ ] Profile → Import your history → MyAnimeList → Choose the file. Select the partial document through the system picker. Preview must show Cowboy Bebop at 3 watched episodes and explain one adult title skipped, separately from unmatched/provider failures. Apply; cold-launch and confirm the allowed entry and original library are retained. [Declared source expectations](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/sample-import-files.json).
- [ ] Select the all-skipped document through the same picker. Verify zero eligible additions, an explanation of one adult exclusion, no usable Add action and no library change.
- [ ] Profile → Export library: exercise JSON and CSV through the ordinary share sheet and Save to Files. Reopen each saved file locally and check title/progress values. Keep exports private; record format, successful save/readback and counts rather than publishing account content.

## Production Google and Apple sign-in

- [x] The owner saved the credentials and the stored Google/Apple connections were activated. [Public Dashboard readback](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/app-store/clerk-provider-activation-public-readback.json) and [production Frontend API readback at 17:00:53 UTC](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/app-store/provider-frontend-readback.json) confirm both enabled and authenticatable. Phone Google/Apple login is completed by the owner report below; no owner secret-entry step remains.
- [x] [The owner directly reports successful Google and Apple logins on the chosen iPhone/TestFlight path](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/provider-owner-testflight.json), recorded at 17:14:30 UTC. Model, iOS version, displayed build number and provider cold restore were not captured; the requested candidate was 1.0 (14). [Release 14 simulator entry checkpoints](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/provider-enabled-recheck/result.json) separately prove both buttons and ordinary provider entry; they stopped before personal authentication. No personal Google login or Apple Account setup on the Mac simulator is now requested.
- [ ] Recommended follow-up: record device model/OS/displayed build and exercise provider cold restore, sign-out/re-entry and cancel/back recovery if not already done. Keep identities private and separate from the disposable deletion target. Apple's optional email/name must not be assumed present; password-only deletion does not establish Apple grant revocation.

## Disposable account erasure

The permanent reviewer has its existing per-user Device Trust exception. The separate password-only erasure QA identity retains ordinary Device Trust: its correct password was accepted, but the new-device verification was not completed, and that attempt was closed. The owner is using the existing iPhone/TestFlight path and has received the disposable credentials only in private chat. No fresh verification prompt is currently known; complete ordinary verification privately if it appears. Do not reuse the reviewer exception, bypass the challenge or create another QA identity.

1. Continue the phone self-test, then switch to the already-provisioned disposable identity. Add exactly one library title and watch episode 1 through normal controls; confirm the acknowledged state. Report “QA ready” before Delete so root can capture the baseline. Do not use the personal Google/Apple account or permanent reviewer as the deletion target. No seed/deletion is yet reported.
2. Run the prepared read-only baseline helper:

   ```sh
   python3 /Users/shan2new/.config/previously/release/live-erasure-verify.py baseline
   ```

   Require `baseline_captured`, including the five protected identities: four migrated users and the permanent reviewer. The previous observation was `baseline_not_ready`; it cannot substitute. Avoid protected library changes until post-checks finish; explain a digest mismatch rather than replacing the baseline.
3. Open Profile → Delete account. Root verifies the exact disposable target and obtains the required action-time confirmation for permanent deletion before the final button. Then root records the local marker with the existing helper; it does not itself delete:

   ```sh
   python3 /Users/shan2new/.config/previously/release/live-erasure-qa.py mark-deletion-start --owner-action-authorized
   ```

4. Perform the confirmed app deletion. Record the actual result: completed, provider cleanup pending, or uncertain/recovery. Pending is not complete; uncertainty must retain the recovery/write hold. Cold-launch and verify no deleted library or accepted identity returns.
5. Run `python3 /Users/shan2new/.config/previously/release/live-erasure-verify.py post`. Require `server_provider_erasure_verified`: provider absent, owned-data scopes empty, completed hash-only tombstone/journal, password-only Apple outcome `not_applicable`, and all five protected identities/security/data unchanged. Leave a pending/mismatch result unresolved; do not directly clean up the provider or overwrite the baseline.
6. If root performs a separately recorded graceful backend restart, cold-launch again and repeat `post --checkpoint after-owner-restart`. The checkpoint label alone is not restart proof. [Exact helper scope and lifecycle](/Users/shan2new/Projects/previously/docs/qa/2026-10-06/native-live/live-account-erasure-verification.md).

Record pass/fail/pending per check with build, device/OS, actual steps and sanitized proof. Exclude credentials, verification codes, emails, provider IDs and private exports. Keep physical, iOS 18, VoiceOver, Files, provider and deletion outcomes distinct; update release readiness only from completed observations.
