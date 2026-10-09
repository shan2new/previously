# Previously · load testing

The working launch plan uses **15 requests/second as a planning peak**. This is a headroom assumption, not a forecast: 100 daily users making 4,000 requests/day average about **0.046 requests/second**. The qualifying test targets **75 requests/second for 15 minutes**, followed by a 150 requests/second burst and measured recovery. No new service, dependency purchase, or recurring spend is involved. gzip compression uses the free official Fastify plugin.

## Test design

| Phase | Offered rate | Duration | Purpose |
| --- | ---: | ---: | --- |
| Warmup | 15 req/s | 2 minutes | Establish normal latency and memory |
| Sustained | 75 req/s | 15 minutes | Five times the planning peak |
| Burst | 150 req/s | 1 minute | Short overload headroom |
| Recovery | 15 req/s | 5 minutes | Verify latency and memory settle |

The primary traffic follows a deterministic cycle: 30% library, 25% detail, 20% cached search, 10% feed, 5% notifications, 5% watch sessions, and 5% progress writes. Additional stress starts alongside sustained traffic: 200 cold searches across ten seconds and two simultaneous imports of 150 catalogue parts each. Imports use the same asynchronous preview and polling protocol as the iOS client; the production three-second provider pacer remains active.

Every run creates, migrates, seeds and removes its own `previously_qa_load_<uuid>` PostgreSQL database. It cannot accept a production target URL or database. Fixtures contain 500 accounts, 50 library titles/account, 1,000 franchises and 3,000 anime parts. Decoded library responses average about163KiB, including real response serialization and episode metadata. The final generator requests gzip and records encoded wire-body bytes separately from decoded JSON bytes. No production data is copied.

The final fixture uses deterministic natural prose varied by title and episode. Independent seed SQL verifies36,000 episode entries with31,415 distinct84-byte overviews, and1,000 distinct969-byte notes of150 words each. This replaces shared repeated paragraphs while keeping the decoded payload size comparable. Compression measurements apply to this particular fixture; they do not forecast production compression or WAN upload capacity.

The final server imports `buildServer` and its shared SQL client from **compiled `dist/server.js` and `dist/db/index.js`**, so the release artifact's production HTTP routes, identity/ownership handling, SQL and services execute. Only the QA wrapper uses workspace tsx. Compiled JS/maps, production source, migrations, ops helpers, build configuration and dependency lock are pinned by SHA256. Provider transport is replaced with deterministic 20 ms AniList responses; other outbound fetches and sockets are denied. Environment variables come from a small allowlist, provider credentials are explicitly empty, `.env` loading is disabled, and index/cron workers are not started. The final run enables the production account-deletion listener against an initialized, empty, independently owned scratch filesystem journal; reconciliation/fsync work executes idle. The journal is removed after owned processes stop. No production operational directory is read.

## Acceptance and evidence

Rates are open-loop fixed dispatch times, with no client retries. Maximum concurrency is 300; requests are counted as dropped if the generator is full or over 500 ms late. Reports retain offered, sent, completed and dropped counts, scheduling lag, route throughput, response bytes, latency percentiles, errors, query timings, CPU, event-loop delay and PostgreSQL activity.

Acceptance requires at least 98% of each offered rate completed, no request errors/5xx/timeouts/drops or incorrect ownership responses, core p95 below 1 second and p99 below 2 seconds, and all canonical progress values matching independent SQL reads. Both imports must finish 50 shows with no failed rows; 300 imported part counts are included in the SQL oracle.

Memory criteria were declared before the qualifying run: peak runtime RSS no more than 128 MiB above the final warmup baseline; peak heap used no more than 64 MiB above that baseline; final recovery minute median RSS no more than 32 MiB above the final sustained minute; and final four-minute recovery RSS slope at most 2 MiB/minute. This checks an observed plateau and recovery over 23 minutes, not unlimited uptime. The baseline excludes bulk fixture construction.

Query dispatch wait means the observed delay between handling a client query and the postgres driver's `onexecute` callback. It includes client scheduling, available connection and socket buffering, and only covers queries invoking that callback. It is **not an isolated pool-wait metric**. Total query duration and callback coverage are reported separately; PostgreSQL activity samples show database wait states.

Each run folder contains `traffic-results.json`, phase metrics, `server-metrics.json`, five-second server resource samples, fifteen-second host process samples, logs and `run-ledger.json`. The ledger records source revision/dirty state, exact scratch database identity and removal proof. Short `--quick` runs validate harness behavior and do not qualify capacity. `--calibrate` uses120s warmup,180s sustained,30s burst and60s recovery; it is a shared-host resource probe and cannot qualify capacity.

## Results

**The final Apple-deletion/content-policy candidate passed the complete 23-minute profile.** The [final receipt](final-results.json) binds the load fingerprint to immutable artifact `707891eaf17802cd9c62a8dbd2c1e1bb4ab03bfa187a892b4e94c00eb0272b07`; its [run-local copy](20261006T134459Z-711ca2c9/qualification-receipt.json) preserves this exact result. All 82,800 offered core requests completed with zero errors, 5xx, timeouts, drops or incorrect responses.

| Final phase | Completed / offered | Actual rate | p95 / p99 |
| --- | ---: | ---: | ---: |
| Warmup | 1,800 / 1,800 | 15.000 req/s | 31 / 45 ms |
| Sustained | 67,500 / 67,500 | 74.997 req/s | 69 / 108 ms |
| Burst | 9,000 / 9,000 | 149.943 req/s | 117 / 143 ms |
| Recovery | 4,500 / 4,500 | 15.000 req/s | 30 / 42 ms |

All 200 cold searches succeeded. Both simultaneous imports completed 50 shows with zero failed rows in 14.14 and 16.17 seconds; 798 canonical progress checks had zero mismatches. The independent compiled protocol 31/31, deletion recovery 6/6 and content policy 27/27 receipts match the executed compiled files. This test does not exercise real provider quotas or Apple grant revocation.

Peak RSS was 200.66 MiB, 38.92 MiB above warmup; peak heap was 99.50 MiB, 30.21 MiB above warmup. Both satisfy the unchanged 128/64 MiB growth budgets. Final recovery median RSS was 142.77 MiB versus sustained 173.28 MiB; the final four-minute slope was 0.00077 MiB/minute, below the 2 MiB/minute limit. Sustained CPU median was 53.0% of one core; burst median was 91.9%. Observed GC wall durations totaled 28.636 seconds across the full run, with p99 3 ms and maximum 28.41 ms; these are not isolated GC CPU measurements.

Measurement began at 13:45:02.907 UTC; owned process drain and cleanup finished at 14:08:03.913939 UTC. [The ledger](20261006T134459Z-711ca2c9/run-ledger.json) proves unchanged source/dist, zero remaining scratch connections and removal of the owned database and filesystem journal. Native tests, fixture processes and archive work had stopped before measurement, as recorded in the [CPU quiet receipt](../archive13/cpu-quiet-receipt.json). Normal services on the shared Mini remained resident. All 406 provider calls used deterministic stubs; non-loopback fetch/socket attempt counters stayed zero. Encoded bodies totaled 345.64 MB versus 5.10 GB decoded JSON, for this varied fixture only; headers and framing are excluded.

Historical runs and initial failures remain below. The [compiled varied-fixture smoke](20261006T112709Z-0f072e37/traffic-results.json) failed its request criteria:584 of585 primary requests completed, with one warmup dispatch dropped after517.7ms scheduling lag. It had zero HTTP errors,5xx, timeouts or incorrect responses; ten cold searches, both50-show imports and325 canonical progress checks passed. The [ledger](20261006T112709Z-0f072e37/run-ledger.json) proves unchanged source/dist and removal of the owned database and journal with zero scratch connections. Native simulator QA was active. Host competition was observed, but the evidence does not isolate the cause of the scheduling delay. The failure is preserved; the later quiet-window full run used unchanged thresholds.

In that smoke, library bodies averaged167KB decoded and8.35KB encoded; across all routes the encoded-body reduction was about93.3%. These are fixture body measurements, excluding HTTP headers/framing. Its seconds-long phases and incomplete memory baselines cannot establish sustained capacity or recovery.

The corrected [quick smoke](20261006T100808Z-9a47a833/traffic-results.json) passed 585 primary requests, ten cold searches, both imports and 325 canonical progress checks. Its [ledger](20261006T100808Z-9a47a833/run-ledger.json) confirms scratch database removal. Earlier short runs preserve fixture serialization, instrumentation and synchronous-import harness failures; these were repaired in QA code without modifying production behavior.

The [frozen compiled Node24 build](20261006T113909Z-668a3f4c/qualification-receipt.json) subsequently passed the full23-minute profile:82,800/82,800 core requests, zero errors/5xx/timeouts/drops,200 cold searches, both50-show imports and798 canonical writes without mismatch. Sustained p95/p99 were67/95ms; burst122/147ms; recovery31/42ms. Peak RSS206.16MiB was51.59MiB above warmup and peak heap90.23MiB was26.35MiB above warmup, within the unchanged128/64MiB allowances. Final recovery median RSS135.98MiB was below sustained169.81MiB and its final-four-minute slope was−2.61MiB/minute. Source/dist hashes were unchanged and matched the compiled31+3 SQL qualification; owned database and journal were removed with zero connections. Native fixture/test processes had stopped before measurement; normal Mini services remained resident.

This earlier exact PASS is preserved as historical evidence. The final receipt above qualifies the newer Apple/content candidate separately.

**Initial full-duration result: request/latency/correctness criteria passed; memory criterion failed.** The [initial traffic receipt](20261006T101158Z-2e124101/traffic-results.json), [memory review](20261006T101158Z-2e124101/memory-review.json) and [cleanup ledger](20261006T101158Z-2e124101/run-ledger.json) preserve the result without relaxing thresholds.

| Initial full phase | Completed / offered | Actual elapsed rate | p50 / p95 / p99 |
| --- | ---: | ---: | ---: |
| Warmup |1,800 /1,800 |15.000 req/s |18 /30 /37 ms |
| Sustained |67,500 /67,500 |75.000 req/s |12 /78 /107 ms |
| Burst |9,000 /9,000 |149.910 req/s |12 /131 /157 ms |
| Recovery |4,500 /4,500 |15.000 req/s |18 /29 /34 ms |

All82,800 primary requests completed with zero errors, timeouts,5xx, drops or incorrect responses. All200 cold searches materialized synthetic catalogue entries. Both simultaneous imports finished50 shows/0 failures in14.1 and16.2 seconds. The final write oracle checked798 values without mismatch. Independent read-only SQL audits during sustained traffic and recovery checked74,802 unchanged/imported progress rows plus subscriptions and catalogue counts, with zero mismatches; see [audit SQL](independent-audit.sql), [sustained receipt](20261006T101158Z-2e124101/independent-sql-audit.json) and [recovery receipt](20261006T101158Z-2e124101/independent-sql-recovery-audit.json).

Peak sampled RSS492 MiB stayed within its budget; peak heap used286 MiB exceeded warmup135 MiB +64 MiB. Heap had a67–286 MiB sawtooth during sustained/burst traffic and ended recovery at75 MiB. Recovery RSS median338 MiB was below warmup413 MiB; its final four-minute slope was−14.5 MiB/minute. This finite evidence supports transient allocation/garbage collection, with no observed increasing retained heap, but it **does not pass the declared peak budget**. The final candidate will use an explicit old-space/young-space V8 budget and record GC timing/CPU against unchanged criteria. Node24.21.0 LTS is selected by child-process PATH; the earlier Node25.9.0 evidence remains historical.

The initial source monitor also flagged two unrelated deletion QA files added during measurement. Neither was imported or executed by this run; production source remained unchanged. Its overly broad snapshot is narrowed in the final launcher. Initial send-lag quantiles are excluded from conclusions because a negative early timer sample could corrupt histogram bins; positive max scheduling lag and request-latency histograms remain valid. Final reporting clamps early scheduling samples and uses completion/actual elapsed time including drain.

Initial measurement began10:12:01.091 UTC and finished/drained at10:35:01.856 UTC. The ledger proves zero remaining scratch connections and removal. The shared16 GB M4 Mini had normal services/Chrome/CoreSimulator resident; host process samples record competitors. A midrun3.8 GiB host swap reading has no initial baseline and is not attributed to this backend. Results apply to dirty source base19649b3 before ordered-intent and compression changes.

## Limits and reproduction

The [Node24 calibration](20261006T105455Z-d476dfb1/traffic-results.json) completed20,700 core requests,200 cold searches and both imports, with zero request errors/drops or canonical mismatches. Its [ledger](20261006T105455Z-d476dfb1/run-ledger.json) records both owned database and FS journal removal. It used `--max-old-space-size=256 --max-semi-space-size=8`, a measured280MiB V8 heap limit, gzip and ordered mutation stamps. **It does not qualify capacity:** sustained traffic lasted3minutes, recovery1minute, native simulator/build contention remained, and executed source changed during this calibration.

| Calibration phase | Completed | Actual rate | p95 / p99 |
| --- | ---: | ---: | ---: |
| Warmup |1,800 |15.000 req/s |82 /1,185 ms |
| Sustained |13,500 |75.000 req/s |103 /214 ms |
| Burst |4,500 |149.408 req/s |174 /219 ms |
| Recovery |900 |15.000 req/s |180 /543 ms |

Peak sampled RSS206.7MiB and heap99.7MiB were55.6MiB/28.6MiB above warmup; the60-second recovery is too short for the declared four-minute trend criterion. Sustained CPU median55.8% of one core and burst104.8% include compression worker threads; GC wall entries totaled4.64seconds during180-second sustained traffic and1.62seconds during30-second burst. These entries are pause/wall observations, not isolated GC CPU. Encoded response bodies were63.2MB versus1.28GB decoded JSON. No controlled A/B comparison isolates the effects of Node version, dependencies, protocol, gzip, heap flags or host contention. The final full-duration compiled-runtime run retains the original acceptance thresholds.

These are loopback tests on the shared 16 GB Mac Mini with normal co-resident services. They exclude public internet/tunnel/TLS loss, real provider variability or quotas, live Apple/Clerk token verification, physical-device behavior and non-anime catalogue coverage. Host samples record actual competing processes. A passing run establishes local cached-backend headroom for this workload, not an unmeasured global launch capacity.

```sh
python3 server/qa/run-load-test.py --quick  # harness smoke only
python3 server/qa/run-load-test.py --calibrate  # resource probe only
python3 server/qa/run-load-test.py          # full23-minute profile
```

Sources: [launcher](../../../../server/qa/run-load-test.py), [open-loop traffic](../../../../server/qa/load-traffic.ts), [scratch server](../../../../server/qa/load-server.ts), [provider stubs](../../../../server/qa/load-provider-stubs.ts). See the [consolidated QA report](../README.md), [progress fault findings](../progress-faults/README.md), and [release monkey QA plan](../../../release/2026-10-05/monkey-qa.md).
