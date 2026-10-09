import Foundation
import Network
import Observation
import UIKit

// The trust layer: how fresh the data is, whether the device can reach anything, and which of the
// user's writes the server has not confirmed.
//
// It is a singleton rather than an `AppModel` extension because all of this is *stored* state and
// stored properties cannot live in an extension. It follows the `EpisodeNotifications.shared`
// precedent already in the app.
//
// Two rules it exists to enforce:
//   • a failure is never invisible and never auto-dismisses — it persists in `failedChanges`
//     until it is retried or discarded, and survives a relaunch (board 09/13);
//   • "offline" and "the server is unreachable" are different sentences, and which one the user
//     reads is decided by `isOnline` (NWPathMonitor), never guessed from an error.
@MainActor
@Observable
final class SyncCenter {

    static let shared = SyncCenter()

    // MARK: - Data classes and their staleness thresholds (board 09)

    enum DataClass: String, CaseIterable, Sendable {
        /// AniList airing instants. Wrong within half an hour is wrong.
        case exactAiring
        /// TMDB date-only schedule. A day's worth of drift is invisible; six hours is the limit.
        case dateOnlySchedule
        /// Titles, artwork, season structure. Changes on the order of days.
        case catalogue

        var threshold: Int64 {
            switch self {
            case .exactAiring: return 30 * Formatting.minuteMs
            case .dateOnlySchedule: return 6 * Formatting.H
            case .catalogue: return 24 * Formatting.H
            }
        }
    }

    // MARK: - Freshness
    //
    // There is exactly ONE freshness stamp in this app and `SyncCenter` does not own it: the model
    // that loads the library owns it (`AppModel.lastLoadedAt`) and `SyncCenter` reads it.
    // COHERENCE §1.3 spells that read `AppModel.shared?.lastLoadedAt`; neither `AppModel.shared`
    // nor `lastLoadedAt` exists in the tree yet — both are edits to `App/AppModel.swift`, a shared
    // file this track may not touch (filed as sharedFileRequest R2/SP-2) — so the read goes through
    // a closure the app installs once. The semantics are COHERENCE's: one stamp, owned by the
    // model, never copied here. A stored copy is exactly what lets Profile's "Synced 2 min ago"
    // and a screen's stale strip disagree, so both properties below are deliberately computed.

    /// What the live model currently knows about freshness. Read through `signals`, never stored.
    struct Signals: Equatable, Sendable {
        /// Epoch-ms of the last library payload that actually arrived. `0` = never.
        var lastLoadedAt: Int64 = 0
        /// A library request is in flight.
        var loading: Bool = false
    }

    /// Installed once, at the app root:
    /// ```
    /// SyncCenter.shared.signals = { [weak appModel] in
    ///     .init(lastLoadedAt: appModel?.lastLoadedAt ?? 0, loading: appModel?.loading ?? false)
    /// }
    /// ```
    /// Until it is installed, nothing can be stale and Profile reads "Not synced yet" — the honest
    /// reading of "this build has no freshness source wired", not a silent claim of freshness.
    /// Because the closure reads `@Observable` model properties, every SwiftUI view that renders
    /// `lastSyncedAt` / `checking` re-evaluates when the model's stamp moves.
    var signals: (@MainActor () -> Signals)?

    private var current: Signals { signals?() ?? Signals() }

    /// When the last library payload actually arrived. `nil` until the first successful load.
    var lastSyncedAt: Int64? {
        let ts = current.lastLoadedAt
        return ts > 0 ? ts : nil
    }

    /// A refresh is in flight. Drives Profile's "Checking for changes" line.
    var checking: Bool { current.loading }

    private var stamps: [DataClass: Int64] = [:]

    /// Optional per-class refinement: a surface that refreshes ONE class of data on its own (the
    /// schedule feed, say) stamps it here and that class stops inheriting the library-wide stamp.
    /// Nothing is required to call this — every class falls back to `lastSyncedAt`, so the stale
    /// strip works on a screen that never stamps anything.
    func stamp(_ dataClass: DataClass, at ts: Int64 = .nowMs) {
        stamps[dataClass] = ts
    }

    /// Elapsed ms since this class of data last arrived, or `nil` when it never has.
    func age(of dataClass: DataClass, now: Int64 = .nowMs) -> Int64? {
        guard let at = stamps[dataClass] ?? lastSyncedAt else { return nil }
        return max(0, now - at)
    }

    /// Past the class threshold. Never true before the first successful load: a page that has
    /// never loaded is not stale, it is loading. Artwork failures never reach here, so a failed
    /// poster can never mark a page stale.
    func isStale(_ dataClass: DataClass, now: Int64 = .nowMs) -> Bool {
        guard let age = age(of: dataClass, now: now) else { return false }
        return age >= dataClass.threshold
    }

    /// The timestamp the `StaleStrip` renders, or `nil` when nothing is stale.
    func staleSince(_ dataClass: DataClass, now: Int64 = .nowMs) -> Int64? {
        guard isStale(dataClass, now: now) else { return nil }
        return stamps[dataClass] ?? lastSyncedAt
    }

    /// Profile's account line, in precedence order: a real failure outranks a stale stamp, and a
    /// check in flight outranks a calm one.
    var localActivityRecoveryRequired = false

    func syncedLine(now: Int64 = .nowMs) -> String {
        if localActivityRecoveryRequired { return "Saved activity needs recovery" }
        if !failedChanges.isEmpty { return Copy.Toast.syncFailed(failedChanges.count) }
        if !journal.entries.isEmpty { return Copy.Toast.offlinePending }
        if checking { return Copy.State.checkingForChanges }
        guard let lastSyncedAt else {
            return isOnline ? Copy.State.neverSynced : Copy.State.couldNotCheck
        }
        return Copy.synced(at: lastSyncedAt, now: now)
    }

    // MARK: - Reachability

    /// The device believes it has a path to the network. A captive portal can report `true` while
    /// every request fails — accepted: claiming the user is offline when they are not is the
    /// worse lie, and the server-side copy is the honest fallback.
    private(set) var isOnline: Bool = true
    /// Low Data Mode is on for the current path. Story art and post media step down a size and
    /// neighbour prefetch stops (iD9).
    private(set) var isConstrained: Bool = false
    /// The current path is expensive (cellular, a personal hotspot) — the same step down.
    private(set) var isExpensive: Bool = false

    private var monitor: NWPathMonitor?
    private var monitoring = false
    private var monitorGeneration = 0
    #if PREVIOUSLY_QA
    private(set) var qaMonitorCallbacks = 0
    private(set) var qaMonitorGeneration = 0
    #endif

    /// Each signed-in lifecycle gets a new monitor; cancelled monitors cannot be restarted.
    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        monitorGeneration &+= 1
        let generation = monitorGeneration
        let monitor = NWPathMonitor()
        self.monitor = monitor
        #if PREVIOUSLY_QA
        qaMonitorGeneration = generation
        qaMonitorCallbacks = 0
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let constrained = path.isConstrained
            let expensive = path.isExpensive
            Task { @MainActor in
                guard let self, self.monitoring, self.monitorGeneration == generation else { return }
                #if PREVIOUSLY_QA
                self.qaMonitorCallbacks += 1
                #endif
                // Written only when they change: every body that reads one re-evaluates.
                if self.isOnline != satisfied { self.isOnline = satisfied }
                if self.isConstrained != constrained { self.isConstrained = constrained }
                if self.isExpensive != expensive { self.isExpensive = expensive }
            }
        }
        monitor.start(queue: DispatchQueue(label: "previously.reachability"))
    }

    func stopMonitoring() {
        guard monitoring else { return }
        monitoring = false
        monitorGeneration &+= 1
        monitor?.cancel()
        monitor = nil
    }

    // MARK: - Failed writes

    private(set) var failedChanges: [FailedChange] = []

    /// At least one failed change has something `Retry` can actually run. A banner or a Profile
    /// row whose Retry would be a no-op must not draw the button at all.
    var canRetryAny: Bool { failedChanges.contains { $0.canRetry(self) } }

    /// Replays a restored change's `WriteIntent` — the write itself, re-issued, not a reload that
    /// would only confirm the server never got it. Installed by the model in `start()`; captures
    /// it weakly, so it is wiring (like `signals`), not session state.
    var replay: (@MainActor (WriteIntent, MutationStamp?) async -> Void)?

    /// No failed change runs while set — not a Retry, not a restored intent, not the comment
    /// gate's `replayProgress`: every row reads as having nothing to run (`effectiveRetry` → nil),
    /// so the banner and Profile offer Discard only. Raised for an account deletion
    /// (`AppModel.prepareForErasure`) and a suspension (iD14), where every replay would either
    /// re-create an erased account's rows or answer 403 forever; lowered by `resumeReplay()` and
    /// by `teardown()` (the next sign-in starts clean).
    private(set) var replaySuspended = false

    func suspendReplay() {
        if !replaySuspended { replaySuspended = true }
    }

    func resumeReplay() {
        if replaySuspended { replaySuspended = false }
    }

    /// Keys the user has explicitly retried, and when. A re-record inside this window is a
    /// *directly* failed action and earns one `.directError`; an automatic failure is silent.
    private var userRetriedAt: [String: Int64] = [:]
    private static let directErrorWindow: Int64 = 30_000
    /// Attempts per key; also restored so a retried failure always advances its version.
    private var attempts: [String: Int] = [:]
    private var lastRecordAt: Int64 = 0
    /// Progress retries stay persisted until their awaited write settles. Running retries cannot
    /// be started twice, and teardown cancels them before another account can inherit the work.
    private var retryingIDs: Set<UUID> = []
    @ObservationIgnored private var retryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryGeneration = 0
    /// Set while a `retryAll()` batch is in flight, so the batch fires one error haptic, not N.
    private var batchRetryToken: UUID?
    private var batchErrorFired = false

    /// Records a write the server never accepted. Called by every mutation's `catch`.
    /// The local value is NOT rolled back for progress writes — the mark is a fact about the user.
    func record(command: String, title: String, reason: String, intent: WriteIntent? = nil,
                mutation: MutationStamp? = nil,
                retryable: Bool = true,
                retry: @escaping @MainActor () async -> Void) {
        let key = FailedChange.key(command: command, title: title, intent: intent)
        // Distinct ordering even when a Mark and Undo fail in the same millisecond. The maximum
        // is restored, so Retry can defend the newest part intent across process restarts too.
        let now = max(Int64.nowMs, lastRecordAt + 1)
        lastRecordAt = now
        attempts[key] = (attempts[key] ?? 0) + 1
        // One row per (command, title): a repeatedly failing write is one problem, not a list.
        if let i = failedChanges.firstIndex(where: { $0.key == key }) {
            failedChanges[i].reason = reason
            failedChanges[i].at = now
            failedChanges[i].attemptCount = attempts[key] ?? 1
            failedChanges[i].intent = intent ?? failedChanges[i].intent
            failedChanges[i].mutation = mutation
            failedChanges[i].retryable = retryable
            failedChanges[i].retry = retry
        } else {
            failedChanges.append(FailedChange(id: UUID(), command: command, title: title,
                                              reason: reason, at: now,
                                              attemptCount: attempts[key] ?? 1,
                                              intent: intent, mutation: mutation, retryable: retryable, retry: retry))
        }
        // Exactly one error haptic, and only when the user asked for this attempt themselves.
        // Inside a `retryAll()` batch that is one haptic for the whole batch, not one per row.
        if let asked = userRetriedAt[key], now - asked <= SyncCenter.directErrorWindow {
            userRetriedAt[key] = nil
            if batchRetryToken == nil {
                FeedbackCoordinator.fire(.directError)
            } else if !batchErrorFired {
                batchErrorFired = true
                FeedbackCoordinator.fire(.directError)
            }
        }
        persist()
    }

    func discard(_ id: UUID) {
        if let change = failedChanges.first(where: { $0.id == id }) {
            if let mutation = change.mutation,
               journal.entries.contains(where: { $0.mutation.operationID == mutation.operationID }),
               !journal.discard(operationID: mutation.operationID, owner: storageOwner) { return }
            if journal.restoreFailed, change.intent == nil,
               !journal.discardAll(owner: storageOwner) { return }
            attempts[change.key] = nil
            userRetriedAt[change.key] = nil
        }
        failedChanges.removeAll { $0.id == id }
        persist()
    }

    func discardAll() {
        guard journal.discardAll(owner: storageOwner) || storageOwner == nil else { return }
        failedChanges.removeAll()
        attempts.removeAll()
        userRetriedAt.removeAll()
        persist()
    }

    /// A snapshot identifies the exact standing failure a later successful write supersedes.
    /// Another failure recorded while that write awaits its response must remain retryable.
    struct FailureVersion: Equatable {
        let id: UUID
        let attemptCount: Int
        let intent: WriteIntent?
        let mutation: MutationStamp?

        init(_ change: FailedChange) {
            id = change.id
            attemptCount = change.attemptCount
            intent = change.intent
            mutation = change.mutation
        }
    }

    func progressFailureVersions(mediaIds: Set<Int>) -> [FailureVersion] {
        failedChanges.compactMap { change in
            guard case .progress(_, let mediaId, _)? = change.intent,
                  mediaIds.contains(mediaId) else { return nil }
            return FailureVersion(change)
        }
    }

    func latestProgressIntent(mediaId: Int) -> WriteIntent? {
        latestProgressChange(mediaId: mediaId)?.intent
    }

    func latestProgressChange(mediaId: Int) -> FailedChange? {
        failedChanges.enumerated().filter {
            if case .progress(_, let part, _)? = $0.element.intent { return part == mediaId }
            return false
        }.max {
            if let lhs = $0.element.mutation, let rhs = $1.element.mutation, lhs.writerID == rhs.writerID,
               lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            if $0.element.at != $1.element.at { return $0.element.at < $1.element.at }
            return $0.offset < $1.offset // Older persisted files may contain equal timestamps.
        }?.element
    }

    func settleFailures(_ versions: [FailureVersion]) {
        let settled = failedChanges.filter { change in
            versions.contains(FailureVersion(change)) && !journal.entries.contains {
                $0.mutation.operationID == change.mutation?.operationID
            }
        }
        guard !settled.isEmpty else { return }
        let ids = Set(settled.map(\.id))
        failedChanges.removeAll { ids.contains($0.id) }
        for change in settled {
            attempts[change.key] = nil
            userRetriedAt[change.key] = nil
        }
        persist()
    }

    func isRetrying(_ id: UUID) -> Bool { retryingIDs.contains(id) }

    /// Progress retries keep their failure row on disk until the awaited command succeeds.
    /// A re-recorded failure changes its version and cannot be cleared by the old completion.
    ///
    /// A row is **never** cleared when there is nothing to run: a restored change has no encoded
    /// closure, and if the app has not supplied `onRestoredRetry` the only honest behaviour is to
    /// leave the failure standing. Clearing it would delete the record, persist an empty list and
    /// let `syncedLine()` report "Everything synced" for a write that was never sent.
    func retry(_ id: UUID) {
        guard let change = failedChanges.first(where: { $0.id == id }),
              let run = change.effectiveRetry(self) else { return }
        let key = change.key
        userRetriedAt[key] = .nowMs
        let retained = change.retainsDuringRetry
        if !retained { failedChanges.removeAll { $0.id == id }; persist() }
        retryingIDs.insert(id)
        let generation = retryGeneration
        retryTasks[id] = Task { @MainActor in
            guard !Task.isCancelled, generation == self.retryGeneration else { return }
            await run()
            self.settleRetry(change, retained: retained, generation: generation)
            if generation == self.retryGeneration { self.retryTasks[id] = nil }
        }
    }

    /// A Retry task finished; completing an awaited lane alone does not prove a per-part PUT
    /// reached the server. That command acknowledges its captured failures explicitly on success
    /// or a final 404. An unsent/canceled lane therefore leaves its durable failure standing.
    /// Drop the haptic stamp so a later unrelated background failure cannot inherit the Retry tap.
    private func settleRetry(_ change: FailedChange, retained: Bool, generation: Int) {
        guard generation == retryGeneration else { return }
        retryingIDs.remove(change.id)
        if retained, !Task.isCancelled, !replaySuspended {
            switch change.intent {
            case .progress?: break // `putProgress` owns this receipt; a finished lane is insufficient.
            default: settleFailures([FailureVersion(change)])
            }
        }
        let key = change.key
        userRetriedAt[key] = nil
        // The attempt counter belongs to a standing failure. With no row left, a later unrelated
        // failure must read "1st attempt", not inherit this key's history for the whole session.
        if !failedChanges.contains(where: { $0.key == key }) { attempts[key] = nil }
    }

    // MARK: - Progress failures (the episode rooms' gate)

    /// A progress write for this part is standing in Sync status — the server has not got the
    /// user's last mark, so an episode room's gate would still read the old value.
    func hasFailedProgress(mediaId: Int) -> Bool {
        failedChanges.contains { $0.holdsProgress(mediaId: mediaId) }
    }

    /// Replays that part's failed progress write now (the row leaves first, as `retry(_:)` does;
    /// a write that fails again re-records itself) and answers whether the part is clear after it.
    /// Silent: this is the model making way for a comment, not a Retry the user pressed.
    @discardableResult
    func replayProgress(mediaId: Int) async -> Bool {
        guard let change = failedChanges.first(where: { $0.holdsProgress(mediaId: mediaId) }),
              let run = change.effectiveRetry(self) else { return !hasFailedProgress(mediaId: mediaId) }
        let generation = retryGeneration
        retryingIDs.insert(change.id)
        let task = Task { @MainActor in
            guard !Task.isCancelled, generation == self.retryGeneration else { return }
            await run()
            self.settleRetry(change, retained: true, generation: generation)
            if generation == self.retryGeneration { self.retryTasks[change.id] = nil }
        }
        retryTasks[change.id] = task
        await task.value
        return !hasFailedProgress(mediaId: mediaId)
    }

    func retryAll() {
        // Only the rows that actually have something to run leave the banner.
        let runnable = failedChanges.compactMap { change -> (FailedChange, @MainActor () async -> Void)? in
            guard let run = change.effectiveRetry(self) else { return nil }
            return (change, run)
        }
        guard !runnable.isEmpty else { return }
        let now: Int64 = .nowMs
        for (change, _) in runnable { userRetriedAt[change.key] = now }
        let removedIDs = Set(runnable.filter { !$0.0.retainsDuringRetry }.map(\.0.id))
        failedChanges.removeAll { removedIDs.contains($0.id) }
        retryingIDs.formUnion(runnable.map { $0.0.id })
        persist()
        // One Retry press is one transaction: the whole batch earns at most one `.directError`,
        // however many of its writes fail again and however far apart they land.
        let token = UUID()
        batchRetryToken = token
        batchErrorFired = false
        let generation = retryGeneration
        retryTasks[token] = Task { @MainActor in
            for (change, run) in runnable {
                guard !Task.isCancelled, generation == self.retryGeneration else { break }
                await run()
                self.settleRetry(change, retained: change.retainsDuringRetry, generation: generation)
            }
            if generation == self.retryGeneration {
                for (change, _) in runnable { self.retryingIDs.remove(change.id) }
                if batchRetryToken == token { batchRetryToken = nil }
                self.retryTasks[token] = nil
            }
        }
    }

    // MARK: - Banner suppression

    /// Profile lists every failed change with its reason, `Retry` and `Discard`, so the global
    /// banner would be a duplicate of the screen the user is already reading.
    var profileIsOpen: Bool = false

    /// 6 s, or 10 s while VoiceOver runs — an Undo the user cannot reach in time is not an Undo.
    var toastSeconds: Double { UIAccessibility.isVoiceOverRunning ? 10 : 6 }

    /// The error toast's lifetime, on the same rule. It carries no action, so it is shorter — but
    /// a VoiceOver user still has to be given time to hear it before it leaves.
    var errorSeconds: Double { UIAccessibility.isVoiceOverRunning ? 8 : 4 }

    // MARK: - Persistence
    //
    // Account-owned failures and the durable stamped journal survive a relaunch.
    // Their exact `WriteIntent` replays the mark after a relaunch rather than reloading
    // a library that never had it. A restored row without an intent keeps its place with
    // Discard as the only way out; it is never cleared as if it had succeeded.

    private static let storeKey = "previously.sync.failedChanges"
    private var storageOwner: AccountLocalStore.Snapshot?
    private let journal = MutationJournal()

    /// Called synchronously before any consumer tracking request or queued task starts.
    func stage(command: String, title: String, intent: WriteIntent, mutation: MutationStamp?) throws -> Bool {
        guard let mutation else { throw MutationJournal.JournalError.noCurrentOwner }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try journal.stage(command: command, title: title, intentData: encoder.encode(intent),
                                 mutation: mutation, coalescingKey: journalKey(intent))
    }

    private func journalKey(_ intent: WriteIntent) -> String? {
        switch intent {
        case .progress(_, let mediaId, _): return "progress:\(mediaId)"
        case .status(let id, _): return "status:\(id)"
        case .subscribe(let id, _, _), .unsubscribe(let id, _): return "membership:\(id)"
        default: return nil
        }
    }

    func acknowledgeMutation(_ mutation: MutationStamp?, owner: AccountLocalStore.Snapshot?) {
        guard let mutation else { return }
        let key = journal.entries.first { $0.mutation.operationID == mutation.operationID }?.coalescingKey
        guard journal.acknowledge(mutation, owner: owner) else { return }
        let before = failedChanges.count
        failedChanges.removeAll { change in
            guard let stamp = change.mutation else { return false }
            if stamp == mutation { return true }
            guard let key, let intent = change.intent, journalKey(intent) == key else { return false }
            return stamp.writerID == mutation.writerID && stamp.sequence <= mutation.sequence
        }
        if before != failedChanges.count { persist() }
    }

    #if PREVIOUSLY_QA
    var qaJournalCount: Int { journal.entries.count }
    var qaJournalProgress: [(mediaId: Int, episodes: Int, mutation: MutationStamp)] {
        journal.entries.compactMap { entry in
            guard let intent = try? JSONDecoder().decode(WriteIntent.self, from: entry.intentData),
                  case .progress(_, let mediaId, let episodes) = intent else { return nil }
            return (mediaId, episodes, entry.mutation)
        }
    }
    #endif

    private struct StoredChange: Codable {
        let id: UUID
        let command: String
        let title: String
        let reason: String
        let at: Int64
        let attemptCount: Int
        var intent: WriteIntent? = nil
        var mutation: MutationStamp? = nil
        var retryable: Bool? = nil
    }

    private init() {}

    func activateOwner(_ owner: AccountLocalStore.Snapshot?) {
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
        guard owner != storageOwner else { return }
        teardown()
        storageOwner = owner
        journal.activate(owner: owner)
        restore()
    }

    private func persist() {
        let rows = failedChanges.map {
            StoredChange(id: $0.id, command: $0.command, title: $0.title,
                         reason: $0.reason, at: $0.at, attemptCount: $0.attemptCount,
                         intent: $0.intent, mutation: $0.mutation, retryable: $0.retryable)
        }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? AccountLocalStore.shared.write(data, name: "failed-changes.json", owner: storageOwner)
    }

    private func restore() {
        let rows = AccountLocalStore.shared.read("failed-changes.json", owner: storageOwner)
            .flatMap { try? JSONDecoder().decode([StoredChange].self, from: $0) } ?? []
        let restoredRows = rows.filter { row in
            guard let stamp = row.mutation, let intent = row.intent, let key = journalKey(intent) else { return true }
            return !journal.entries.contains { entry in
                entry.coalescingKey == key && entry.mutation.writerID == stamp.writerID
                    && entry.mutation.sequence > stamp.sequence
            }
        }
        failedChanges = restoredRows.map {
            FailedChange(id: $0.id, command: $0.command, title: $0.title, reason: $0.reason,
                         at: $0.at, attemptCount: $0.attemptCount, intent: $0.intent,
                         mutation: $0.mutation, retryable: $0.retryable ?? true, retry: nil)
        }
        for entry in journal.entries.sorted(by: { $0.at < $1.at }) {
            guard !failedChanges.contains(where: { $0.mutation?.operationID == entry.mutation.operationID }) else { continue }
            let intent = try? JSONDecoder().decode(WriteIntent.self, from: entry.intentData)
            failedChanges.append(FailedChange(id: entry.mutation.operationID, command: entry.command, title: entry.title,
                reason: intent == nil ? "This saved change could not be restored. Discard it to make a fresh update." : Copy.Toast.offlinePending,
                at: entry.at, attemptCount: 0, intent: intent, mutation: entry.mutation, retryable: intent != nil, retry: nil))
        }
        if journal.restoreFailed {
            failedChanges.append(FailedChange(id: UUID(), command: "Sync", title: "",
                reason: "Some saved changes could not be restored. Discard them to make a fresh update.",
                at: .nowMs, attemptCount: 0, intent: nil, retryable: false, retry: nil))
        }
        attempts = Dictionary(failedChanges.map { ($0.key, $0.attemptCount) }, uniquingKeysWith: max)
        lastRecordAt = failedChanges.map(\.at).max() ?? 0
    }

    /// Sign-out: the next account must not inherit this one's failures.
    ///
    /// `lastSyncedAt` and `checking` are not cleared here because they are not stored here — the
    /// model's own teardown resets `lastLoadedAt`, and this centre follows it.
    ///
    /// `signals` is deliberately KEPT: it is the wiring, not session data, and it captures the
    /// model weakly. The root re-installs it on the next sign-in either way.
    func teardown() {
        retryGeneration += 1
        retryTasks.values.forEach { $0.cancel() }
        retryTasks = [:]
        retryingIDs = []
        failedChanges = []
        localActivityRecoveryRequired = false
        stamps = [:]
        attempts.removeAll()
        lastRecordAt = 0
        userRetriedAt.removeAll()
        batchRetryToken = nil
        batchErrorFired = false
        // The path monitor runs a dispatch queue for as long as it is started; a signed-out app
        // has nothing to be reachable to. The root restarts it on the next sign-in.
        stopMonitoring()
        // Captures the model weakly and the root re-installs it on the next sign-in; dropping it
        // here guarantees nothing restored can replay into the account that follows this one.
        replay = nil
        replaySuspended = false
        // The milestone ledger is per-account too: the next user's first season completion is
        // their own, not a token this one already spent.
        SeasonSweepLedger.reset()
        persist()
        storageOwner = nil
        journal.reset()
    }
}

/// One write the server never accepted. `command` is a `Copy.Action` string, `reason` a
/// `Copy.Notice.reason(_:)` string — never a status code.
/// The write behind a failed change, in a form that survives a relaunch. Everything the app
/// writes that can fail into Sync status is one of these; a change that carries one can be
/// retried from any launch.
enum WriteIntent: Codable, Equatable, Sendable {
    case franchiseProgress(franchiseId: String, parts: [FranchiseProgressValue], status: WatchStatus?, removeMembership: Bool)
    case progress(franchiseId: String, mediaId: Int, episodes: Int)
    case status(franchiseId: String, status: String)
    case subscribe(franchiseId: String, title: String, status: String)
    case unsubscribe(franchiseId: String, title: String)
    /// A reply that never reached the server, replayed with the SAME client id (the server upserts
    /// on it, server §3.5). Rows stored before this case existed still decode.
    case comment(id: String, subject: String, parentId: String?, body: String, franchiseId: String, title: String)
}

struct FailedChange: Identifiable {
    let id: UUID
    let command: String
    let title: String
    var reason: String
    var at: Int64
    var attemptCount: Int
    /// The write itself, when it can be expressed — what a restored row retries with.
    var intent: WriteIntent?
    var mutation: MutationStamp? = nil
    var retryable = true
    /// `nil` for a change restored from a previous launch: the closure could not be encoded.
    var retry: (@MainActor () async -> Void)?

    var retainsDuringRetry: Bool {
        switch intent {
        case .progress?, .franchiseProgress?: return true
        default: return false
        }
    }

    /// Identity for de-duplication: the same command on the same title is one problem — except a
    /// per-part progress write, which is also keyed by its part: two seasons of one show that both
    /// failed are two writes, and the second must not overwrite the first's intent (the episode
    /// gate asks for each part by media id, `hasFailedProgress`).
    var key: String { FailedChange.key(command: command, title: title, intent: intent) }
    static func key(command: String, title: String, intent: WriteIntent? = nil) -> String {
        if case .progress(_, let mediaId, _)? = intent { return "\(command)\u{1F}\(title)\u{1F}\(mediaId)" }
        return "\(command)\u{1F}\(title)"
    }

    /// This row carries a progress write for that part — its own `.progress`, or a one-call
    /// `.franchiseProgress` that includes it (the add-with-progress path).
    func holdsProgress(mediaId: Int) -> Bool {
        switch intent {
        case .progress(_, let m, _)?: return m == mediaId
        case .franchiseProgress(_, let parts, _, _)?: return parts.contains { $0.mediaId == mediaId }
        default: return false
        }
    }

    /// The retry to actually run — the recorded closure, or the model replaying the stored
    /// intent for a restored row. `nil` when there is nothing to run: a missing retry must never
    /// be mistaken for a successful one, so there is deliberately no empty-closure fallback here.
    @MainActor
    func effectiveRetry(_ center: SyncCenter) -> (@MainActor () async -> Void)? {
        guard retryable, !center.replaySuspended, !center.isRetrying(id) else { return nil }
        if let retry { return retry }
        guard let intent, let replay = center.replay else { return nil }
        return { await replay(intent, mutation) }
    }

    /// Whether `Retry` can do anything for this row. A row with no runnable retry keeps its place
    /// in the banner; Profile shows `Discard` as the only way out until `replay` is installed.
    @MainActor
    func canRetry(_ center: SyncCenter) -> Bool { effectiveRetry(center) != nil }
}
