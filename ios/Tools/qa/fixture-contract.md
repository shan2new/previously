# Native QA fixture contract

`fixture-server.mjs` is a dependency-free loopback HTTP service for the native UI suite. It loads no `.env`, database, provider API, production credentials or remote artwork. Its synthetic state is an oracle independent of the app's disk cache. It proves the client behaves against this controlled protocol; it does not establish that the production server behaves identically.

```sh
PREVIOUSLY_QA_CONTROL_TOKEN='<random local test token>' node ios/Tools/qa/fixture-server.mjs
node --test ios/Tools/qa/fixture-server.test.mjs
```

The token must be 8–256 characters. The service binds IPv4 `127.0.0.1:18787`, exits if the port is occupied, and never substitutes another port or listens publicly. `PREVIOUSLY_QA_PORT` can select another explicit loopback port. Stop with SIGINT/SIGTERM. No fixture data survives a process restart.

Application requests require exactly `Authorization: Bearer dev:fixture-a` or `Bearer dev:fixture-b`; `/health` alone is public. Unknown identities are rejected. Fixture A initially owns `qa-anime` (media `1001`, 3/12, Watching) and `qa-tv` (`2001`, 2/8, Watching). Fixture B initially owns only `qa-plan` (`3001`, 0/10, Planned). Titles are `QA Anime`, `QA Television`, `QA Planned`. All three parts have completed airing so progress controls have a finite, predictable ceiling.

Control requests require `X-Previously-QA-Token` and cannot be faulted. `/qa/…` is an alias for `/__qa/…`.

| Request | Meaning |
| --- | --- |
| `POST /__qa/reset {}` | Reset both accounts, faults and bounded logs. |
| `POST /__qa/reset {"account":"fixture-a"}` | Reset one account and its faults. |
| `GET /__qa/state?account=fixture-a` | Inspect canonical server state and counters. |
| `GET /__qa/logs` | Last 2,000 redacted application request records; control polling cannot evict writes. |
| `POST /__qa/fault` | Schedule one controlled fault with the body below. |
| `POST /__qa/deletion {"account":"fixture-a","mode":"pending"}` | Make deletion return 202 and status report pending identity cleanup. |
| `POST /__qa/deletion {"account":"fixture-a","mode":"complete"}` | Make deletion complete, or finish synthetic cleanup after erasure. |
| `POST /__qa/deletion {"account":"fixture-a","mode":"refuse-next"}` | Refuse the next DELETE with defined JSON 400 `unexpected body`, before mutation. |

```json
{"account":"fixture-a","kind":"drop-after-commit","path":"/me/progress","remaining":1}
```

Deletion-only faults `proxy-forbidden-after-commit` and `empty-success-after-commit` commit the
synthetic erasure, then replace its receipt with HTML 403 or undefined empty 204. Native tests
must keep the durable hold until an authoritative status read returns 200 complete or 202 pending.

`path` is an exact pathname (query excluded), or `/*` for every application pathname. `remaining` defaults to 1, bounded to 1–100; it decreases when an authenticated request consumes the fault. For sustained outage, set `kind:"offline", path:"/*", remaining:100`; the control channel remains available to inspect/reset state. Faults affect only their selected account.

| Kind | Effect |
| --- | --- |
| `drop-after-commit` | Mutate normally, then destroy the response socket once. A repeated absolute PUT returns the same canonical value with no second logical commit. Applies to successful mutation responses. |
| `before-commit` | Return JSON 503 before running the route. No state mutation. |
| `offline` | Destroy the socket before the route. No state mutation. |
| `delay` | Hold the selected request before running its route. `delayMs` defaults to 1000, bounded to 0–30000. Other requests run concurrently. |

State includes `fixtureVersion:"1"`, `account`, `subscriptions:[{franchiseId,status}]`, `progress:[{mediaId,episodes}]`, `erased`, `sessions`, and these counters:

- `progressCommits`: number of logical mutations changing the progress map. One compound progress request is one change; an identical replay is zero additional changes. Use this to check progress replay when the app also writes watch sessions.
- `commits`: number of mutations changing tracked domain state (subscriptions, progress, watch sessions/tombstones, toggles, import applications or erasure). Ancillary visit/preference changes and import preview bookkeeping are excluded.
- `mutationAttempts`: authenticated application mutation attempts, including rejected/faulted attempts. It is not a durable-effect count.
- `importApplications`: previews applied exactly once. Viewing/cancelling a preview never increments it.
- `faults:[{kind,path,remaining,inFlight}]`: synchronization evidence for each scheduled fault. For a delayed old search, await `remaining:0,inFlight:1` before issuing a newer query, then await `inFlight:0` before checking stale results. Reset removes these records.
- `deletionStatus`: active, pending or complete; `deletionRequests` counts actual DELETE calls; `deletionStatusReads` counts reconciliation GETs; `ordinaryRequestsAfterErasure` counts other rejected app requests after deletion. Control reads do not increment these counters.

`PUT /me/progress` writes an absolute value, clamps to the synthetic part total and returns `{ok:true,mediaId,episodes}`. Compound franchise progress is validated before any update. Erasure clears account state and leaves a process-local tombstone: ordinary subsequent app requests return 410, preventing delayed requests from resurrecting data. `GET /me/deletion` returns `{deleted,status}` without recreating an account; repeated DELETE returns the same cleanup state. Deleted watch-session IDs similarly return 410 on retry.

Search is a trimmed, case-insensitive substring of the three titles: `anime` finds only `qa-anime`, `plan` only `qa-plan`, and `television` only `qa-tv`; a blank query has no results. Feed/activity/recommendations are honest empty payloads, social comments are off, providers are disabled, and the one `QA` discovery genre uses only synthetic titles.

Import preview immediately returns an async-ready job for `QA Planned`, regardless of supplied source data; it makes no upstream call. Preview/cancel is read-only with respect to library state. Applying adds Planned if absent and is idempotent, account-owned and observable. This fixture does not test real export parsing, provider matching, background import durability or production deletion cleanup.

The request log records bounded method/path/account/outcome and valid mutation metadata (`operationID`, `writerID`, positive safe-integer `sequence`). The three mutation headers must be entirely absent for legacy clients or all valid; partial or malformed metadata returns 400 before route mutation. Tokens, bodies, queries and import usernames are excluded. This fixture logs transport identity but does not implement the production server's durable operation ledger or cross-writer conflict rules. The service is solely for local development builds and isolated test identities.

## Explicit process-kill controls

Two bounded hold faults (`hold-before-commit`, `hold-after-commit`) expose inFlight state and safely log the same operation metadata at the vulnerable interval. Token-protected `POST /__qa/release` accepts account/path/disposition (`abort` or `continue`). A held request automatically aborts after 30 seconds; account reset and fixture shutdown abort outstanding holds. Aborting before commit makes no domain effect; aborting after commit withholds only the receipt. Safe per-request numeric IDs keep duplicate lifecycle log records from inflating write-attempt counts.

`POST /__qa/trailer` accepts `{account, enabled}`. Default/reset is false. Only an explicit dedicated live-player validation returns Google’s documented IFrame demo video on qa-anime; the fixture itself still makes no upstream request. Core directed cases and monkey runs leave this off.
