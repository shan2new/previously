# Scoped read-only live erasure verifier

Prepared private helpers, both mode 0600:

- `/Users/shan2new/.config/previously/release/live-erasure-verify.py`
- `/Users/shan2new/.config/previously/release/live-erasure-readonly-db.mjs`

The Python entry point is the only operator command. It reads the existing disposable-account state and owner-only production config, validates the exact protected set of four migrated accounts plus the permanent review account, and calls only Clerk GET endpoints. It never creates a session, sends app requests, changes Device Trust, requests an OTP, provisions, patches or deletes an account. The Node subordinate accepts private input through a pipe and imports only installed `postgres`/`dotenv` libraries from the actual launchagent's immutable artifact. It does not import backend services or their side effects.

SQL is parameterized and limited to the exact six identities in one repeatable-read **READ ONLY** transaction, with bounded connection/statement/lock timeouts and an observed `transaction_read_only=on` guard. It returns counts and private row digests, rather than user-content dumps. It covers the 19 distinct account-erasure-plan tables, both sides of owner relationships, and child scopes using captured comment-parent keys. User visit timestamps are excluded from the protected identity digest; all other captured scoped data remains compared. A hash-only account tombstone and independent journal are expected retention, not active account data.

Journal inspection opens existing files read-only and validates the current snapshot's checksum plus the exact requested/completed/Apple-outcome markers. It does **not** call the runtime `readDeletionLedger` helper, because that helper creates/removes locks and enforces directory permissions. It creates no operational directories or ledger records. Identifiers, emails, session credentials and private identity/data digests remain only in owner-only files. Public output contains booleans, QA synthetic counts and declared outcomes.

## Correct lifecycle invocations

After native-live has completed ordinary login and acknowledged **one library title and one watched episode**, with the permanent review session's work finished:

```sh
python3 /Users/shan2new/.config/previously/release/live-erasure-verify.py baseline
```

`baseline_captured` is required before deletion. This saves `live-erasure-qa-baseline.json` privately, including the disposable internal key, any comment-parent keys, five protected scoped-data digests and provider-security projection. An earlier observation is saved separately as `live-erasure-qa-baseline-observation.json`; `ready:false` observations cannot substitute for the qualified baseline. The helper refuses baseline refresh after the existing deletion-start marker. It rechecks account ownership/lifecycle after its reads before saving and uses a private nonblocking operator lock.

Root controls the separately authorized consumer UI confirmation and records the existing marker before that action:

```sh
python3 /Users/shan2new/.config/previously/release/live-erasure-qa.py mark-deletion-start --owner-action-authorized
```

This command records a local marker only. It does not perform deletion. After the actual app deletion/recovery result:

```sh
python3 /Users/shan2new/.config/previously/release/live-erasure-verify.py post
```

Post mode requires both the deletion-start marker and a ready, exact-owner baseline. A successful `server_provider_erasure_verified` result requires the defined provider absence response, no active app account, zero remaining owned scopes, a completed SQL tombstone with the raw provider key cleared, intact requested/completed independent markers, the password-only case's actual `not_applicable` Apple outcome, and unchanged protected identities/security/scoped data. Anything unconfirmed or changed remains `verification_pending_or_mismatch`; no direct provider cleanup or baseline overwrite follows. Reader changes after baseline are refused rather than silently broadening its scope.

If root separately performs and records a graceful restart, the same readback can be labeled afterward:

```sh
python3 /Users/shan2new/.config/previously/release/live-erasure-verify.py post --checkpoint after-owner-restart
```

The label does not prove a restart occurred. Parent combines it with the independent operational restart receipt and native cold-launch/signed-out observations. No helper restarts any service.

## Actual preparation/readback

On 6 October 2026, the helper completed GET-only provider and READ ONLY SQL/journal observations. All five protected provider identities and database accounts were present; the separately provisioned QA identity still had **no app account, library or progress**. It had no deletion tombstone/marker. Thus `baseline_not_ready` is the honest current result and no ready baseline was saved. The five scoped observations are private, mode 0600. No Device Trust challenge or OTP withholding was bypassed. The final readback is `live-account-erasure-baseline-readback.json`.

Pure synthetic guards passed 9/9 for SQL/identity scoping and 4/4 for lifecycle/owner protection, with zero provider calls, SQL connections or real private inputs in those tests. These are helper checks; they do not count as native consumer-deletion qualification.

## Limits

The post path is prepared but has not run against a deleted live identity. Concurrent legitimate activity by a protected account may change its digest; the result must remain unresolved until that activity is explained, not be rewritten as unchanged. The helper does not prove the consumer UI confirmation, local cache purge, a physical-device/iOS 18 journey, lost-response recovery, stale-JWT replay, restored-backup behavior, an actual restart or Apple grant revocation. Those retain their separate evidence boundaries. The public reader does not disclose private row digests or full rows.
