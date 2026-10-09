# Previously: monkey testing and exploratory QA

Added 6 October 2026 and updated during implementation. The earlier dossier covered failure injection and device checks but did not specify randomized UI testing adequately. A free local native harness now exists; [recorded native results](../../qa/2026-10-06/native-qa.md) and [machine-readable receipts](../../qa/2026-10-06/native-results.json) distinguish completed checks from pending runs. This document remains the broader QA plan.

## What we have and what is missing

At the 5 October inspection, the server run passed 1,240 tests across 76 files. `ios/project.yml` then declared the app and widget extension, with no native UI-test target or XCTest/XCUI harness. Those observations are the historical baseline, not the current implementation.

The 6 October implementation adds a separate `PreviouslyQA` scheme/application sandbox, a native test target, stable control identifiers, two synthetic accounts, an independent canonical-state oracle, controlled transport faults and a process-owning local runner. The latest completed directed receipt passed 27 selected tests with zero skips; the current full seeded rerun is tracked in the linked results. Actual watch-history, account-scoped storage/export, progress Retry and uncertain deletion regressions are included. Neither server unit tests nor the harness's own guard checks are counted as UI journeys.

Use Apple's [XCTest and XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation) on the existing Mac and owned iPhone. It provides UI interaction and inspection; seeded action selection, fixtures, failure injection and data invariants would be our own harness. No paid device farm or new subscription is needed. UI tests are built and signed separately; use the final TestFlight candidate for the physical exploratory pass and tie both to the same source revision.

## Three complementary layers

| Layer | Purpose | Starting budget |
| --- | --- | --- |
| Stateful monkey runs | Discover unexpected combinations of valid user actions | After relevant UI/sync changes: three fixed seeds, five minutes each |
| Directed failure scenarios | Exercise precise persistence and identity boundaries | Run the targeted cases below when affected code changes and for a candidate |
| Human exploratory QA | Notice confusing feedback, visual failures, keyboard and gesture problems | Fifteen minutes on an owned iPhone per candidate; expand when issues emerge |

The implemented first qualification uses three fixed five-minute seeds on one iPhone 14 Pro simulator, serially. Extend later candidates to a supported older OS/smaller screen when that runtime is available; a complete matrix on every edit is unnecessary on the shared 16 GB Mini. Actual action counts depend on UI speed. Report completed actions, meaningful states and assertions instead of inventing a coverage percentage from elapsed time.

These are initial engineering budgets, not certification or a promise of complete coverage. Beta recruitment and market validation can continue. The initial harness and account/fault regressions are implemented; imports through the actual Files picker and physical-device checks remain explicitly outside that synthetic run.

## Make random actions useful

1. Create a UI-test target, stable accessibility identifiers for important controls, and a scratch backend with two synthetic accounts. Use a versioned fixture containing anime, TV, completed/in-progress/planned titles, an empty library variant and small import files.
2. Choose actions from the current screen's valid, hittable controls. The implemented weighting is 40% navigation, 30% progress/Undo, 20% search/input, and 10% profile open/dismiss. Record the chosen action and target identifier. Keep destructive account actions in the explicit scenarios below; actual Files import needs a separate deliberate case.
3. Mix fast repeats and interrupted transitions with normal interactions. Bound every wait and use a recovery check for stuck sheets or loading states. Record whether the action succeeded, was unavailable, or timed out; never silently count a skipped action as coverage.
4. Assert after mutations and lifecycle transitions. At the end, relaunch and compare the UI with independently queried scratch-server state. Use the documented conflict policy to determine expected results when multiple devices write.
5. Freeze or record fixture data, time, response order and fault schedule where relevant. A random seed alone cannot reproduce a failure that depends on uncontrolled network timing. Persist the exact action trace as well.

A general action run stays inside the app. External links, OS account dialogs and provider sign-in should have bounded, deliberate cases so the runner does not wander into unrelated apps or third-party settings.

## Failure matrix

| Area | Sequence | Invariant / evidence |
| --- | --- | --- |
| Progress and Undo | Rapidly change progress; Undo; leave detail; reopen from another tab | All entry points converge to canonical server progress; no duplicate effect |
| Offline intent | Disconnect, change progress, background/relaunch, reconnect | Pending intent survives and is visible until the server acknowledges it |
| Commit uncertainty | Server commits, response is dropped, app is terminated, operation retried twice | One logical effect; no lost acknowledged write or false saved receipt |
| Account race | A starts a delayed request, signs out, B signs in, A's response arrives | A's library, recents, queued work, tokens and backups cannot appear under B |
| Account teardown | Sign out offline; relaunch; sign in with a different account | Ownership checks remain correct across persisted state and late writers |
| Import | Preview/cancel/repeat; background during apply; restart scratch worker | Import truthfully reports its state; retry/resume cannot duplicate progress |
| Deletion | Accept deletion, lose response, relaunch; retry provider cleanup | Pending versus complete is truthful; erased data does not reappear |
| Messy input | Empty/whitespace, long pasted text, emoji, non-Latin text; clear/retype quickly | UI remains usable; malformed requests are handled; old results do not overwrite newer intent |
| Lifecycle and UI | Rapid tab/sheet/back changes; background/foreground; dismiss keyboard; deny notifications | No dead end, stuck overlay, unbounded loading or loss of local state |
| Dependency behavior | Scratch responses with delay, timeout, 401, 429 and 5xx | Useful cached data survives; retry is bounded; failure is visible and actionable |

Fault timing should use controlled test transport or a scratch API proxy, not arbitrary sleeps. Fault controls must be excluded from the production build. Directed tests must also exercise normal production behavior without hooks. All destructive scenarios use disposable accounts and isolated services; never restart or fill the disk of the shared production backend to create a fault.

## Physical iPhone session

Run the exact candidate from TestFlight. Move quickly through the five tabs, open and dismiss sheets during loading, edit progress and Undo, use the actual Files picker for import, background and relaunch, and switch between Wi-Fi and cellular/offline. Check keyboard dismissal, largest text, VoiceOver focus, interrupted animations and a denied-notification state. Record build and OS. The fifteen-minute session is an initial exploration budget; complete the separate accessibility/device checklist as well.

## Triage and regression

For each failure preserve build/commit, OS/device, fixture version, account alias, seed, exact action and fault trace, screenshot/video, crash or hang report, redacted request IDs, expected state and observed state. Reduce the trace to the smallest useful reproduction. Add that reproduction as a deterministic regression before returning to broad random runs.

Prioritize cross-account disclosure, destructive data loss, duplicate committed effects, false save/deletion receipts and erased-data resurrection as P0. Classify crashes and navigation failures by impact and reproducibility; do not classify every visual glitch as P0. Record passed, failed, skipped and not-run separately. Zero crashes in a short random run is useful evidence, not a claim that the app is reliable in every condition.

This plan uses existing local hardware and free tools. Completed test receipts and their limits are recorded separately; it adds no provider licensing gate or paid service.
