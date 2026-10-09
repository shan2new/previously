# Reading product usage counts

`/internal/usage` is private aggregate instrumentation. Its current field names are retained for compatibility; operators should label them according to the actual SQL:

| API field | Meaning |
| --- | --- |
| `registered` | App-profile count: all rows in `users`, including retained legacy, synthetic and review profiles |
| `registered_7d` | App profiles created in the last seven days, with the same baseline caveat |
| `active_24h`, `active_7d` | Profiles whose latest confirmed app-open timestamp lies in that window |
| `library_users` | Profiles with at least one subscription row |
| `progress_users` | Profiles with at least one positive progress value |

These are not verified consumer counts, installations, Clerk billing MAU, acquisition attribution or retention cohorts. They contain no per-person event export, and ordinary API requests are not counted as app-open activity. A profile with old progress can remain in `progress_users` without recent use.

The release owner's prelaunch inventory on6October contained16 stored app profiles and four verified real returning Clerk identities; legacy/synthetic/review rows explain why raw profile totals can exceed the verified inventory. Preserve that recorded baseline when interpreting future growth, and compare provider billing limits with Clerk's own current usage. Do not purge retained records or infer real adoption merely to make this counter look cleaner.

Backend schema/runtime remain unchanged. The [capacity report](../load-testing/README.md) uses500 explicitly synthetic fixture accounts and does not establish500 real users. Live identity migration and production deployment receipts are maintained separately by the release owner.
