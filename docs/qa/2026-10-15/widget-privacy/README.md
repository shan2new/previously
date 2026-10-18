# Widget account privacy

The 15 October audit found a source-confirmed account-isolation defect in build 15: one ownerless App Group snapshot survived logout, accepted deletion and account switching. An artwork fetch already in flight could publish the old account again after teardown. The audit did not perform a runtime reproduction or change an account.

The candidate now binds snapshots and artwork to a hashed account key plus random session generation. The app's synchronous storage writer checks that lease in memory and on disk; its asynchronous artwork helper checks again after the loader completes. The widget reader rejects missing, legacy or mismatched owners, including cached timeline entries belonging to a previous generation. Artwork filenames also carry the generation.

`AppModel.start` adopts the widget owner before fetching the library. A valid same-owner cold launch preserves its offline snapshot; another owner starts empty, including when offline. Teardown and signed-out cold cleanup invalidate the owner, remove the snapshot and all artwork, and request timeline reload. Sign-out also clears storage before awaiting Clerk, closing the process-kill window between durable SDK logout and local teardown. If sign-out fails, only the same still-signed-in account without an erasure/uncertainty marker can regain a fresh lease for future library updates. Confirmed erasure preparation also clears widget data; an unanswered deletion remains empty across cold launch. A definitive deletion refusal reactivates and republishes the current account's widget.

## Regression qualification

`WidgetSnapshotTests` contains ten named cases using the production shared storage writer and reader in disposable directories:

- Same-owner relaunch preserves its own snapshot and artwork.
- Logout removes the snapshot, referenced and unreferenced artwork, and invalidates the timeline.
- Account B stays empty before its first fetch and refuses A's stale snapshot write.
- Cold B activation invalidates a previous store instance's lease.
- Cold signed-out cleanup works without a previously activated in-memory owner.
- Ownerless legacy data and mismatched snapshots cannot be read.
- An uncancelled, delayed A artwork completion cannot recreate files after logout.
- A loader that ignores cancellation cannot publish after cancellation.
- A delayed A completion cannot overwrite cold B's snapshot or artwork.
- Logout and login to the same account reject the previous generation.

**All ten storage cases and four actual QA app lifecycle cases passed on build 17 / iOS 27.0.** [Named primary-artifact receipts](runtime-results.json) bind the cases and widget file hashes. The enclosing focused run had 24 passes and 5 failures in admission/Files journeys, so it does not qualify the full release. Swift Testing runs in the proper `PreviouslyStorageTests` unit target; the four lifecycle cases use `PreviouslyUITests`. Apple’s raw result tree supplies the ten names omitted by the pinned MCP CLI’s flattened list. Full release qualification remains pending.

`PreviouslyWidgetTests` adds four actual app lifecycle cases against the loopback fixture: A publication followed by logout, cold signed-out cleanup and offline B; a lost deletion receipt and cold uncertainty hold; a definitive refusal restoring A under a new generation; and a same-owner offline cold launch preserving its valid snapshot. These use the normal UI and actual model writer/guarded reader. Their execution is also pending.

In the dedicated QA configuration, the explicitly enabled `com.cognipin.previously.qa` app uses its own `ApplicationSupport/widget` directory. This executes the actual model writer, guarded reader and lifecycle cleanup without provisioning a capability or borrowing production storage. The override is compiled out of production; the QA widget extension has no shared capability and remains empty. The observable store snapshot supplies readiness evidence after debounced publication and cleanup (`qa.widget.owner`, `shows`, `generation`, `activeOwner`, `files`). The fixture has no artwork URLs; controlled helper tests cover delayed artwork publication separately.

These tests cover ownership and file publication. WidgetKit controls when an already rendered system widget refreshes; real App Group provisioning and Home/Lock Screen display remain separate from the injected-directory and QA app evidence. No production account, phone, backend, deployment, version counter or Apple review action is part of this change.
