# Native replay review and focused repair

Reviewed `AppModel`, `SyncCenter`, `APIClient`, `AppModel+Rewatch` and `RewatchStore` on 6 October 2026. This review prompted the local Swift repair; native regression results are recorded by the main QA run.

## Single-part progress

Normal progress writes already have one serialized lane per media id. The newest queued target replaces an intermediate target while a PUT is in flight. `APIClient` finishes its bounded automatic retries before that lane sends the next write. A failed write is not filed if a newer target is already queued. These rules prevent the ordinary rapid-tap race on one part.

Two routes around that protection existed:

- A standing failure was not retired when a later write for the same part succeeded. Its captured Retry could send the older value after the newer success.
- Updating an existing failure changed its encoded intent but left its original Retry closure. Two failed writes could therefore display/store the second value while the current-launch Retry sent the first. A restored failure used its encoded second value, giving different current-launch versus relaunch behavior.

Current-launch and restored progress retries also called `putProgress` directly rather than the normal lane. The local patch replaces the saved closure when a row updates, routes Retry through the normal lane, waits for fresh work already active instead of appending old work, and retires only unchanged failure snapshots captured by a successful write. Progress failure rows remain persisted while Retry runs; a new failed attempt advances its version. Tracked Retry tasks and per-part tasks are canceled/guarded across account teardown.

Mark and Undo can have different standing failure keys for the same part. Retry now resolves the newest standing per-part intent using monotonically ordered record timestamps, with a stable tie break for older persisted files. An old row already superseded by a successful write sends nothing. The additional focused scenario fails Mark `N+1`, then fails Undo `N`, and presses the older Mark Retry; canonical storage must end at `N` and both obsolete failures must settle.

An independent source review also identified that an awaited lane can finish without sending its queued word, for example around erasure suspension/abort. Generic Retry completion no longer clears a single-part failure. Only `putProgress` explicitly acknowledges unchanged captured rows after a successful response or final `404 media not found`. This is source-derived hardening; the erasure timing sequence has not been reproduced in native QA.

The focused native oracle scenario is: read canonical value `N`; reject all three automatic PUT attempts for `N+1` before commit; wait for the failure row; save `N+2` successfully; verify the old failure/Retry disappeared, canonical storage remains `N+2`, and relaunch does not reintroduce the row. The complementary scenario rejects `N+1` and then `N+2`, presses Retry, and requires the fixture to receive `N+2` exactly once.

A race variant leaves the old failure standing, delays a fresh successful `N+2` PUT, and presses Retry while that PUT is active. No trailing `N+1` PUT may appear after `N+2`. Use fixture dispatch/completion receipts rather than sleeps to position the retry.

## Compound writes and sessions

Compound writes use a per-franchise chain and wait for active per-part lanes. A successful compound write now retires captured leaf progress failures for the saved parts. The current repair does not split/supersede an old multi-resource compound failure when only part of it is replaced by a later successful command. The real SQL stale-compound test remains a protocol/queue case to exercise before claiming full coverage.

Watch sessions have a separate serialized lane. Pending words are versioned per session, acknowledgements clear only the matching version, and the next send takes the session's current body. Within a live process this blocks an old save from following an acknowledged newer completion. The SQL stale-session sequence alone does not establish a native queue defect. `RewatchStore` still writes session and queue snapshots in unsequenced detached tasks; process/persistence race coverage remains separate from the in-memory ordering proof.

## Lifecycle limits

Teardown clears persisted SyncCenter failures and cancels model lanes. The patch adds cancellation and generation checks for explicit Retry tasks and old per-part completions. It does not create a durable outbox for a fresh write killed before its failure is recorded, establish multi-device conflict versions, scope every persisted file by account, or change provider authentication.

The server runner is separate: it accepts no production target, disables dotenv/provider credentials, creates and migrates its own scratch DB, never runs workers, and removes its owned DB only after verifying no active sessions. Its output ledger now records both run failures and cleanup failures; it refuses force termination/drop and preserves the scratch name for recovery if cleanup cannot complete. The last real SQL run still records 11 passes and 3 deliberately open protocol assertions.
