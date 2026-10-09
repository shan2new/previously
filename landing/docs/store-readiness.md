# Previously. — legal pages and store-readiness audit

Historical audit. Several findings below were addressed by October implementation work and must not be treated as current release status. The current preparation and evidence dependencies are recorded in [the 6 October Vercel handoff](vercel-release-2026-10-06.md).

Checked 5 September 2026. This is an implementation-grounded preparation report, not a guarantee of store approval or a legal opinion. The current iPhone build was inspected; no Android app was found or assessed.

## What the stores require

| Item                 | Apple App Store                                                                                                          | Google Play                                                                                                                                                  |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Privacy Policy       | Public policy URL and an accessible in-app link.                                                                         | Public, active, non-geofenced HTML policy; link in Play Console and in the app.                                                                              |
| Support              | Working support URL with current contact information.                                                                    | Public developer contact details and an operational user contact route.                                                                                      |
| Account deletion     | Apps supporting account creation must let users initiate complete account deletion in-app.                               | In-app deletion and an external request URL for apps with in-app account creation. A monitored customer-service email can be the web page’s request pathway. |
| Terms / EULA         | A custom EULA is optional; Apple’s standard EULA applies by default. Service terms can explain additional service rules. | Privacy and deletion obligations still apply; separate terms do not replace them. Any billing or category-specific terms need their own review.              |
| Privacy disclosures  | App Privacy answers must reflect the app and its partners, even for data used only for functionality.                    | Data safety answers must match actual app/SDK practices and the policy.                                                                                      |
| SDK/API declarations | Review required-reason APIs and SDK manifests/signatures in the archive.                                                 | Review the final Android app and SDK data behavior if an Android release is planned.                                                                         |

Primary sources, re-read in 2026:

- [Apple — App Review](https://developer.apple.com/app-store/review/): required working privacy/support links and complete metadata.
- [Apple — Account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/): delete the account and associated data; do not substitute deactivation.
- [Apple — Custom license agreement](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/): standard EULA applies when no custom agreement is provided.
- [Apple — App Privacy](https://developer.apple.com/app-store/app-privacy-details/): collected data and third-party disclosure definitions.
- [Apple — SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/): applicable manifest/signature and archive reporting requirements.
- [Google — User Data](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en): privacy policy content and Data safety alignment.
- [Google — Deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en): external URL, app/developer identification and working email/form pathways.

## Pages prepared locally

- `/privacy` — data categories, processing purposes, external providers, retention/deletion, user controls and unresolved operational facts.
- `/terms` — service scope, acceptable use, third-party catalog rights, Apple standard EULA relationship, consumer-rights preservation.
- `/support` — contact structure, safe support instructions, catalog issues, account help.
- `/delete-account` — intended external request pathway and complete-deletion scope.

These routes are **unpublished drafts**, carry `noindex`, and (apart from the functional support page) have a visible draft notice and are intentionally absent from the sitemap. Source lives in `lib/legal-content.ts` and `app/legal-document.tsx`. The local homepage footer links to them. Do not deploy the modified landing site until the drafts are finalized. The current public site remains unchanged.

## Verified submission blockers

1. **Public operator/contact resolved on 5 September.** The user confirmed Shantanu Sinha, shantanusinha95@gmail.com, https://github.com/shan2new and https://www.linkedin.com/in/shan2new. These are now configured in the local site. The request workflow and retention/deletion operations still need finalization.
2. **Legal URLs in the app still use `REPLACE_ME`.** `ios/project.yml` contains placeholders. Current Profile rows render unconditionally and `open(nil)` silently does nothing. Once final pages are live, configure `PRIVACY_POLICY_URL`, `TERMS_URL`, `SUPPORT_EMAIL`, regenerate through XcodeGen and check the actual release build.
3. **Account deletion is incomplete.** `server/src/routes/me.ts` deletes users, subscriptions, progress, preferences and notifications in a transaction. Neither it nor the iOS flow deletes the Clerk identity or revokes its sessions. Authentication upserts an empty database user when the same valid Clerk identity returns. An explicit full-account deletion workflow must address both stores and failure/retry behavior before claiming compliance.
4. **Local records survive deletion.** `RewatchStore.reset()` calls persistence that copies the old history to `sessions.backup.json`. `AppModel.teardown()` does not clear recent-search defaults or call `SyncCenter.teardown()`. App-generated JSON/CSV files remain in temporary storage. Cleanup needs to avoid races with detached persistence tasks. Do not claim all local data is erased today.
5. **Retention policy is undefined.** No source-configured expiry was found for personal data, logs or backups. Confirm actual retention, operational deletion handling and third-party retention. Do not invent a 30-day promise.
6. **Release auth/SDK settings need review.** The build default uses a Clerk test key. Provider settings, Sign in with Apple behavior/token revocation where relevant, processor practices and archive privacy declarations were not verified. No app-owned privacy manifest was found; that alone does not establish which declarations the final binary requires.

## Data inventory for policy and console answers

| Category              | Current evidence                                                                                                          | Console-review implication                                                                                                                                |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Identity              | Clerk ID, internal ID, optional email, created/last-opened timestamps in `server/src/db/schema.ts`.                       | Account-linked identifiers and email used for functionality need accurate disclosure. Verify additional Clerk-managed fields in the actual sign-in setup. |
| Watching activity     | Followed titles, statuses, episode counts, timestamps, notifications, preferences in the same schema.                     | Do not submit a blanket “no data collected” answer. Map categories to the store’s definitions.                                                            |
| Searches              | Requests can go to AniList/TMDB; configured correction sends trimmed query text to Cerebras (`services/queryCorrect.ts`). | Check remote retention and request logging before deciding whether a store-specific collection/ephemeral exception applies.                               |
| Local history         | Recent searches, rewatch files, show/image cache, exports in iOS code.                                                    | Distinguish local-only data from information actually sent off-device; verify device backup behavior.                                                     |
| Images and links      | ImageLoader fetches external hosts directly; trailers/links can involve destination services.                             | Disclose network requests and assess embedded content and provider practices.                                                                             |
| Logs                  | `Fastify({ logger: true })`; request URLs can include query strings. Infrastructure behavior not inspected.               | Verify IP/request retention, redaction and diagnostics purposes.                                                                                          |
| AI catalog enrichment | Grouping/news inputs are catalog metadata/public announcements; search correction is a separate user-query path.          | Do not imply all AI activity uses only public information, nor that personal watch history is sent when the defined inputs do not do so.                  |

App Privacy/Data safety forms cannot be responsibly finalized from source alone. The actual provider settings, retention practices and release binary must agree with the published policy. No forms were submitted, accounts deleted, or app/backend source changed by this audit.

## Finalization order

1. Public operator/contact is confirmed. Confirm launch regions/audience; define actual log/backup/support retention and inspect processor terms/settings.
2. Repair and test complete account deletion, including authentication and on-device cleanup; establish the external request operation.
3. Replace draft annotations with truthful effective policy language and appropriate legally reviewed terms. Set the effective date only when the policy takes effect.
4. Publish the four pages, include final pages in the sitemap, and verify anonymous HTML responses and contact/deletion routes.
5. Wire URLs into the release app and store listings. Complete privacy forms, archive declarations, age-rating/reviewer-access information and platform-specific checks.

The legal copy remains a draft because material facts and implementation are unresolved, not because a generic template is missing.
