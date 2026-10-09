# Consumer v1 privacy submission inventory

This packet records implemented behavior for the next consumer build. It is not a claim that App Store Connect answers, production identity cutover or the effective policy have already been published.

| Data | Linked to the account | Used for tracking | Purpose in the consumer build |
| --- | --- | --- | --- |
| Email address | Yes | No | App functionality: sign-in and account ownership |
| Name | Yes | No | App functionality: authentication/profile identity |
| User ID | Yes | No | App functionality, product personalization, first-party usage analytics |
| Device ID | Yes when authenticated | No | Clerk vendor device identifier for authentication/app functionality |
| Other user content | Yes | No | Library/history sync, recommendations and aggregate library/progress use |
| Product interaction | Yes | No | App-open stamps, preferences and useful actions; functionality, personalization and first-party aggregates |

The privacy manifest now declares those purposes. This adds no analytics SDK, client event stream, advertising identifier, session replay or cross-company tracking. `/internal/usage` exposes only private aggregate account/app-open/library/progress counts. The underlying app-open and saved-data fields remain account-linked until erasure. Proposed activation and retention-cohort events in the release plan are not implemented.

Public comments and replies remain off for v1. Previously retained moderation/security restrictions can remain separately after account erasure. Accepted deletion erases app-owned tracking data transactionally; Clerk cleanup can remain pending and is retried durably. An unknown deletion response keeps the device hold until canonical status reconciliation. Minimal hashed erasure markers prevent restored data or old sessions from recreating a deleted account.

Implemented retention code limits rolling backup pairs and sanitized logs to seven days, and operational/usage aggregate snapshots to thirty days. Actual production backup/restore passed, including the additive Apple-outcome migration. The owner approved retirement of the older June manual dump, and its removal is recorded. The new scheduled retention jobs are prepared but not installed. Matching production Clerk credentials are saved privately; provider activation, existing-user migration and the running service's authentication cutover remain pending. Legal pages therefore remain explicitly draft. Same-disk backup is not hardware-loss recovery.

Review the actual configured Clerk instance and enabled identity providers before final answers. Authentication processors can also hold ordinary connection/security records under their own policies. Catalogue providers, image hosts and trailer/player endpoints receive the connection and request information needed to deliver their content. No app claim should imply that these providers receive nothing.

The installed Clerk iOS1.5.8 source sends the vendor device identifier with authenticated Frontend API requests. The shipping disclosure must include Device ID for app functionality. Production telemetry events are rejected by the inspected SDK collector; this source finding is not a live-network capture or final archive privacy report. The manifest-only declaration update follows the frozen native suite, before the signed archive. The landing source now explicitly describes these authentication identifiers; its final matching publication is pending.

Before submission, confirm the final archive contains this manifest, inspect the bundled Clerk manifests and privacy report, align the App Store Connect answers with the effective policy, and verify the real sign-in/deletion path. Account lifecycle and final binary verification are consumer requirements; provider licensing outreach remains deferred by owner decision.

Apple defines Analytics to include understanding product use, feature effectiveness and audience characteristics. The purpose mapping above is an implementation-based interpretation of [Apple App Privacy details](https://developer.apple.com/app-store/app-privacy-details/) and [privacy manifest documentation](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests), checked 6 October 2026.
