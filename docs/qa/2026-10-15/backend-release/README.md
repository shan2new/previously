# Previously backend closeout — 15 October 2026

**Deployed at 16:56:12 UTC after the second full 5× qualification passed.** All three supervised Previously jobs now point to the qualified 15 October immutable artifact. Fresh public readiness, a verified new backup, the operational collector and the compiled stale-report SELECT passed. The first failed capacity attempt and an initial failed activation/manual recovery are preserved below.

| State | Evidence |
| --- | --- |
| Current production artifact | `/Users/shan2new/Infra/previously/releases/20261015T152739Z/server` |
| Retained prior production artifact | `/Users/shan2new/Infra/previously/releases/20261006T123751Z/server` |
| Candidate manifest SHA256 | `1c93625ad9d87eb48a5fcc300781d0cb8235f7f1bea86ae35ec72b5a198eaeb4` |
| Actual activation | [activation-receipt.json](activation-receipt.json), finished 16:56:12.792 UTC |
| Fresh public health/readiness | [post-activation-public.json](post-activation-public.json): both 200 at 16:57:05 UTC |
| Final capacity status | [final-results.json](load-testing/final-results.json): passed, cleanup finished 16:50:07 UTC |
| Initial failed attempts | [capacity failure](load-testing/failed-initial-results.json), [activation failure](activation-first-failed-receipt.json), [manual recovery](activation-old-service-recovery.json) |

## What the candidate changes

The existing 9 October status rule now reaches the compiled production artifact: progress can move Planned to Watching or Completed, while newer explicit status choices, manual shelves and stamped replay ordering remain protected. The prior 6 October artifact lacked that rule. The earlier one-off owner backfill did not deploy it for future writes; this cutover ran no manual user-data backfill.

The stale-reports cron failure was reproduced in a fresh scratch database, including an empty report queue. Its raw SQL interpolated a JavaScript `Date` without the timestamp column encoder. The narrow fix uses Drizzle `lte(reports.createdAt, olderThan)`; it leaves comments disabled, keeps the job scheduled and continues propagating unrelated queue failures. No production reports were edited or resolved.

The exact lock now resolves `@modelcontextprotocol/sdk` 1.32.1, addressing [GHSA-6qxp-vccf-f47h](https://github.com/modelcontextprotocol/typescript-sdk/security/advisories/GHSA-6qxp-vccf-f47h). Direct dependency requirements are unchanged. The immutable candidate contains production dependencies only; its [production audit](artifact/production-audit.json) reports zero advisories. The initially observed advisory is preserved in [production-audit.json](production-audit.json). This does not assert a breach occurred.

## Completed checks

These receipts qualify the deployed artifact through isolated fixtures. The separate activation receipt records the production cutover.

| Check | Result | Evidence |
| --- | ---: | --- |
| Full server unit suite | 1,340/1,340 across 81 files | [server-unit.txt](server-unit.txt) |
| Focused library/moderation tests | 30/30 | [focused-unit.txt](focused-unit.txt) |
| Type checking and compiled build | Passed | [typecheck.txt](typecheck.txt), [build.txt](build.txt) |
| Ops tests, including owned PostgreSQL restore | 26/26 | [ops-tests.txt](ops-tests.txt) |
| Real-route progress/status/cron SQL faults | 39/39 | [protocol-final/results.json](protocol-final/results.json) |
| Durable deletion recovery | 6/6 | [recovery-final/results.json](recovery-final/results.json) |
| Consumer content policy | 27/27 | [policy-final/results.json](policy-final/results.json) |
| Short load-harness smoke | 585 core requests, zero errors/drops/mismatches | [quick-smoke/traffic-results.json](load-testing/quick-smoke/traffic-results.json) |
| Activation transaction fixtures | 17/17; two Node snippets syntax checked | [activation-guard-tests.txt](activation-guard-tests.txt), [activation-helper-verification.json](activation-helper-verification.json) |

The isolated SQL/load launchers use owned databases, synthetic identities and deterministic provider stubs. Their ledgers record cleanup and unchanged executed modules. The short smoke cannot qualify capacity. Six-October capacity receipts certify their historical artifact, not this candidate.

## First full 5× run: failed and preserved

The working traffic expectation remains 15 requests/second. The unchanged qualification profile is 15 RPS for two minutes, 75 RPS for fifteen minutes, 150 RPS for one minute, then 15 RPS for five minutes. Its 95% reads/5% writes run alongside 200 cold searches and two independent fifty-show imports. This is a practical local workload assumption, not a demand forecast or public WAN/provider-capacity guarantee.

The first attempt ran 15:33–15:56 UTC. Warmup, sustained and burst phases had zero errors or drops. Sustained p95/p99 were 62/90 ms; burst p95/p99 were 108/131 ms. Late recovery incurred **294 client total-timeout errors at the unchanged 5,000 ms limit**, leaving 82,506 of 82,800 core requests completed. It had zero HTTP 5xx, non-2xx responses, incorrect response shapes or dropped offers.

The canonical oracle checked 798 rows and found two mismatches. Its expectations record successful client receipts; five progress writes timed out, so a committed write with a lost receipt can exceed that acknowledged expectation. The removed scratch database prevents operation-level reconstruction of this particular failure. These two oracle failures remain failures; focused lost-receipt/replay tests do not turn this capacity run into a pass.

Memory passed its predeclared limits: peak RSS 178.98 MiB and heap 103.93 MiB, growth 6.56/34.09 MiB over warmup. Sources and compiled modules stayed unchanged. No real-provider socket was attempted; all owned database/filesystem resources were removed after zero remaining connections.

Independent Kestrel compiler/test activity overlapped the slowdown: the captured peak compiler sample used about six CPU cores, and host swap usage increased from 3,678 to 4,949.56 MiB. PostgreSQL dispatch/query delays increased; sampled activity showed no lock waits, database errors or server OOM/crash. This establishes material shared-host interference and a temporal correlation, not definitive sole causation or a confirmed product defect. No other project or service was stopped or changed. Read the [sanitized diagnosis](load-testing/failed-initial-diagnosis.json) and [full run evidence](load-testing/full-20261015).

## Successful full rerun

Two aggregate host samples, fifteen seconds apart, confirmed zero native compiler/simulator CPU and no app/test runners before the rerun. Normal shared Mini services remained resident. The second run used the same runtime/artifact, traffic profile and thresholds from 16:27:03 to 16:50:07 UTC.

| Phase | Completed | p95 | p99 |
| --- | ---: | ---: | ---: |
| Warmup, 15 RPS × 120 seconds | 1,800 | 32 ms | 38 ms |
| Sustained, 75 RPS × 900 seconds | 67,500 | 62 ms | 91 ms |
| Burst, 150 RPS × 60 seconds | 9,000 | 104 ms | 129 ms |
| Recovery, 15 RPS × 300 seconds | 4,500 | 31 ms | 39 ms |

All **82,800 core requests**, 200 cold searches and two concurrent fifty-show imports passed with zero errors, HTTP 5xx, timeouts, dropped offers or incorrect responses. All 798 canonical write checks matched. Peak RSS was 215.20 MiB, growth 28.38 MiB over warmup; peak heap was 97.99 MiB, growth 27.97 MiB. Recovery RSS slope was 0.231 MiB/minute. Every unchanged memory criterion passed.

The executed source/dist remained frozen. All 466 installed artifact files matched the reviewed manifest; 465 matched the load fingerprint, with the documentation-only ops README intentionally excluded from that runtime fingerprint. The same compiled modules passed the 39/6/27 SQL suites. The launcher recorded zero real-provider attempts and removed its owned database/filesystem root after zero connections remained. The [run-local final receipt](load-testing/second-20261015/final-results.json) preserves this pass separately from the failed first run.

## Production activation and recovered failure

The first activation stopped old jobs at **16:50:33.467 UTC**. Immediate new-job bootstrap failed; automatic rollback restored the exact old plist files but failed to start the services. Manual bootstrap of those same prior-production jobs restored availability, with the first preserved local/public 200 and fresh healthy collector observation at **16:51:59.428 UTC**. The 85.96-second stop-to-observed-recovery window is recorded in [the outage review](activation-first-outage-review.json). This was not a successful automatic rollback, and no backup was restored over production.

The original generic command wrapper did not retain the failing CLI code/stderr, so a sole cause is unproven. A later sanitized-environment idle-backup bootstrap succeeded; environment alone is not established as the cause. The [shutdown timing](activation-first-shutdown-timing.json) shows the old backend received shutdown about seven milliseconds after `bootout` returned, exposing an active-job unload/drain race.

The corrected [activation helper](activate-reviewed.py) preserves the operator context for launchctl, retains scoped private Node/PG environments, waits for the exact captured old PID and service registration to disappear, and checks exact plist bytes before every bounded bootstrap retry. Permanent errors and external conflicts stop retries; registered jobs are not loaded twice. Seventeen fixture regressions and [a real idle-backup bootstrap](launchctl-inherited-backup-proof.json) passed before retrying. Fixture tests use owned files and mocked processes; they are not a real production rollback drill.

The approved retry succeeded at **16:56:12.792 UTC** without bootstrap retries. A fresh private 13,850,011-byte preactivation dump restored in 1.277 seconds to an owned scratch database; it contained seventeen users before/after the current deletion-journal sweep, and the scratch database was dropped. Only the three reviewed Previously job pointers changed. The new backend, backup and collector all loaded; the triggered daily backup job and fresh collector exited zero.

The new daily-job dump is 13,850,011 bytes, SHA256 `ab307f51120411bd0deb94739fd05cd380bf644fb705408a8280d8dcc99ed82d`. Independent verification confirmed its checksum, size, owner and mode0600. Its operational source fingerprint `d21f09b6e96725c99f6addce4c039b817fea2e2f32ae444f30cfb262061af4b7` matches the installed artifact. This fingerprint uses the ops manifest convention; the artifact's separate canonical manifest digest is shown above.

The fresh 16:56:12 collector was healthy with public readiness, about 10 GiB free disk and zero pending deletions. Private metrics/usage returned200; anonymous loopback diagnostics returned404. Comments remained disabled. The new compiled stale-report SELECT succeeded on production with count0. It invoked no report alerts/webhook and changed no reports. The next hourly stale-report schedule has not yet been observed; absence of a post-cutover failure alone is not proof that it ran. Public health/readiness were independently200 at16:57:05 UTC.

No manual account/report backfill, schema/configuration/credential/DNS/provider change, live-database restore or Apple action occurred. Normal service workers resumed with the new process. The coordinator was explicitly released to resume native work after the completed cutover.

The collector's existing healthy status checks public readiness, completed backup metadata with a matching file size and age no greater than 26 hours, at least 2 GiB free disk and retry identities for pending deletion. Backup SHA256 is checked at creation and restore verification; hourly collection does not rehash every dump. Operators must also inspect the snapshot timestamp. Same-disk backups retain the accepted Mac/storage-loss limitation.

The finite local 23-minute pass does not prove public WAN/provider capacity or unlimited uptime under arbitrary shared-host work. This backend closeout does not certify native or physical-device flows. The release owner is handling Apple review closeout separately.
