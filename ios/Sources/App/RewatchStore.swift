import Foundation
import Observation

// Watch sessions (spec board 06 · 13). Rewatching is first-class: every completed watch is a
// session; at most one session is active per franchise. The device keeps them — atomic JSON in
// Application Support with one backup generation — and, since 2 Oct 2026, so does the server
// (`/me/watch-sessions`), so a new phone or a reinstall gets the history back: every change queues
// one word for the server (newest word wins, per session) and `AppModel+Rewatch` sends the queue
// and folds the server's list back in. Progress itself stays on the server; sessions explain it.
struct WatchSession: Codable, Identifiable, Equatable, Sendable {
    enum Scope: Codable, Equatable, Sendable {
        case franchise
        case part(mediaId: Int)
    }

    let id: UUID
    let franchiseId: String
    let scope: Scope
    /// 1 = first watch, 2 = second watch, …
    let ordinal: Int
    var startedAt: Int64?
    var completedAt: Int64?
    var cancelledAt: Int64?
    var cancelledAtEpisode: Int?
    /// Episodes the session covers (for history copy); 0 when unknown.
    var episodes: Int
    /// Where the show stood BEFORE the rewatch zeroed it (mediaId → episodes) and its status, so
    /// stopping the rewatch puts it back — without them a finished show stopped at Episode 1 read
    /// "35 EPISODES LEFT" on Today (review i5, F3). Absent on sessions from older builds.
    var restoreProgress: [String: Int]? = nil
    var restoreStatus: String? = nil

    var isActive: Bool { completedAt == nil && cancelledAt == nil }
    var isCompleted: Bool { completedAt != nil }
}

@MainActor
@Observable
final class RewatchStore {
    static let shared = RewatchStore()

    private(set) var sessions: [WatchSession] = []

    struct Summary: Equatable {
        let completedCount: Int
        let active: WatchSession?
        let lastCompletedAt: Int64?
    }

    /// What the server still has to hear about one session. Newest word wins: one entry per id, and
    /// `version` tells an acknowledgement apart from a newer word that landed while it was in flight.
    struct PendingWrite: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case save, delete }
        let kind: Kind
        let version: Int
        /// Retries and cold-launch replay retain this operation; a changed intent receives a new
        /// stamp. Optional only so older pending files decode before their first-send upgrade.
        var mutation: MutationStamp? = nil
    }

    private struct SyncState: Codable {
        var pending: [UUID: PendingWrite] = [:]
        /// Ids the server has acknowledged. One missing from its list was deleted on another device.
        var synced: Set<UUID> = []
        /// Ids the server refused for good (their franchise is gone): kept here, never re-sent.
        var refused: Set<UUID> = []
        /// A superseded receipt did not accept the local body. Retain the need to read canonical
        /// history if that read fails or the app closes. Optional for older sync files.
        var needsCanonicalRead: Bool? = nil
    }

    @ObservationIgnored private var sync = SyncState()
    @ObservationIgnored private var writeVersion = 0
    /// Bumped by every change: a server list read across one is not folded in over it.
    @ObservationIgnored private(set) var revision = 0
    /// Called after every local change; the model sends the queue (`AppModel.flushWatchSessions`).
    @ObservationIgnored var onChange: (() -> Void)?

    private let storage: AccountLocalStore
    private var owner: AccountLocalStore.Snapshot?

    init(directory: URL? = nil) {
        storage = directory.map { AccountLocalStore(directory: $0) } ?? .shared
        // An explicitly supplied scratch directory is for regression tests, never a production
        // fallback. The shared store remains empty until authentication identifies its owner.
        if directory != nil {
            owner = storage.activate(accountID: "scratch-rewatch")
            load()
        }
    }

    func activate(owner: AccountLocalStore.Snapshot?) {
        guard self.owner != owner else { return }
        self.owner = owner
        sessions = []
        sync = SyncState()
        writeVersion = 0
        revision &+= 1
        if storage.matches(owner) { load() }
    }

    // MARK: - Queries

    func sessions(for franchiseId: String) -> [WatchSession] {
        sessions.filter { $0.franchiseId == franchiseId }.sorted { $0.ordinal > $1.ordinal }
    }

    func activeSession(for franchiseId: String) -> WatchSession? {
        sessions.first { $0.franchiseId == franchiseId && $0.isActive }
    }

    func summary(for franchiseId: String) -> Summary {
        let mine = sessions.filter { $0.franchiseId == franchiseId }
        return Summary(completedCount: mine.filter(\.isCompleted).count,
                       active: mine.first(where: \.isActive),
                       lastCompletedAt: mine.compactMap(\.completedAt).max())
    }

    // MARK: - Commands

    /// Starts a rewatch. The first watch is recorded implicitly (dates unknown) when no session
    /// exists yet, so the new one is the second watch. Returns the new active session.
    @discardableResult
    func startRewatch(franchiseId: String, scope: WatchSession.Scope, startedAt: Int64, episodes: Int,
                      restoreProgress: [Int: Int]? = nil, restoreStatus: String? = nil) -> WatchSession {
        var mine = sessions.filter { $0.franchiseId == franchiseId }
        var made: [UUID] = []
        if mine.isEmpty {
            let first = WatchSession(id: UUID(), franchiseId: franchiseId, scope: .franchise, ordinal: 1,
                                     startedAt: nil, completedAt: 0, cancelledAt: nil, cancelledAtEpisode: nil, episodes: episodes)
            sessions.append(first)
            mine.append(first)
            made.append(first.id)
        }
        let ordinal = (mine.map(\.ordinal).max() ?? 0) + 1
        let session = WatchSession(id: UUID(), franchiseId: franchiseId, scope: scope, ordinal: ordinal,
                                   startedAt: startedAt, completedAt: nil, cancelledAt: nil, cancelledAtEpisode: nil, episodes: episodes,
                                   restoreProgress: restoreProgress.map { Dictionary(uniqueKeysWithValues: $0.map { (String($0.key), $0.value) }) },
                                   restoreStatus: restoreStatus)
        sessions.append(session)
        // The implicit first watch (when it was just made) goes up before the rewatch it explains.
        changed(.save, made + [session.id])
        return session
    }

    func complete(_ id: UUID, at ts: Int64) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].completedAt = ts
        changed(.save, [id])
    }

    func cancel(_ id: UUID, atEpisode episode: Int, at ts: Int64) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].cancelledAt = ts
        sessions[i].cancelledAtEpisode = episode
        changed(.save, [id])
    }

    func setStartDate(_ id: UUID, to ts: Int64) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].startedAt = ts
        changed(.save, [id])
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        changed(.delete, [id])
    }

    func deleteAll(for franchiseId: String) {
        let ids = sessions.filter { $0.franchiseId == franchiseId }.map(\.id)
        sessions.removeAll { $0.franchiseId == franchiseId }
        changed(.delete, ids)
    }

    /// Sign-out: sessions belong to the account that made them. The server keeps its copy; the
    /// next sign-in reads it back.
    func reset() {
        sessions = []
        sync = SyncState()
        writeVersion = 0
        revision += 1
        onChange = nil
        // Remove both generations and the queue. Writing an empty primary would first rotate
        // the old owner's private history into the backup.
        for name in ["sessions.json", "sessions.backup.json", "sessions-sync.json"] {
            storage.remove(name, owner: owner)
        }
        owner = nil
    }

    // MARK: - Server sync (driven by AppModel+Rewatch)

    var hasPendingWrites: Bool { !sync.pending.isEmpty || needsCanonicalRead }
    var hasUnsentWrites: Bool { !sync.pending.isEmpty }
    var needsCanonicalRead: Bool { sync.needsCanonicalRead == true }

    /// The oldest unsent word, and the session as it stands now (nil for a delete).
    func nextPendingWrite() -> (id: UUID, write: PendingWrite, session: WatchSession?)? {
        guard storage.matches(owner),
              let oldest = sync.pending.min(by: { $0.value.version < $1.value.version }) else { return nil }
        let id = oldest.key
        var write = oldest.value
        if write.mutation == nil {
            guard let mutation = MutationStamp.fresh(owner: owner, storage: storage) else { return nil }
            write.mutation = mutation
            sync.pending[id] = write
        }
        // Persist the exact operation before any HTTP attempt. A failed local write holds the
        // queue; otherwise a lost server receipt plus process crash would mint a second operation.
        guard persistSync() else { return nil }
        return (id, write, write.kind == .save ? sessions.first { $0.id == id } : nil)
    }

    /// The server took `write`. The word is done unless a newer one replaced it meanwhile.
    func acknowledge(_ id: UUID, _ write: PendingWrite, applied: Bool = true) {
        guard storage.matches(owner) else { return }
        if sync.pending[id] == write { sync.pending[id] = nil }
        switch write.kind {
        case .save: sync.synced.insert(id)
        case .delete: sync.synced.remove(id)
        }
        if !applied { sync.needsCanonicalRead = true }
        persistSync()
    }

    /// The server will never take `write` (400/404: the franchise is gone). The session stays on
    /// this device; the word is dropped and the id never re-sent.
    func refuse(_ id: UUID, _ write: PendingWrite) {
        if sync.pending[id] == write { sync.pending[id] = nil }
        sync.refused.insert(id)
        persistSync()
    }

    /// 410: the session was deleted on another device. It goes here too.
    func deletedElsewhere(_ id: UUID, _ write: PendingWrite) {
        guard sync.pending[id] == write else { return }
        sync.pending[id] = nil
        sync.synced.remove(id)
        sessions.removeAll { $0.id == id }
        revision += 1
        persist()
    }

    /// Folds the server's list in, unless a local change landed after it was read (`revision`,
    /// read before the request) — then the next sync tries again. The server's copy wins for every
    /// session with no unsent word; a session it once acknowledged and no longer lists was deleted
    /// on another device; one it never saw (made before sync, or offline) is queued to go up.
    @discardableResult
    func merge(server: [WatchSession], readAt readRevision: Int) -> Bool {
        guard storage.matches(owner), readRevision == revision else { return false }
        sync.needsCanonicalRead = nil
        let serverIds = Set(server.map(\.id))
        var merged: [WatchSession] = []
        for remote in server {
            switch sync.pending[remote.id]?.kind {
            case .save?: merged.append(sessions.first { $0.id == remote.id } ?? remote)
            case .delete?: continue
            case nil:
                merged.append(remote)
                sync.synced.insert(remote.id)
            }
        }
        var unsent: [UUID] = []
        for local in sessions where !serverIds.contains(local.id) {
            if let pending = sync.pending[local.id] {
                if pending.kind == .save { merged.append(local) }
                continue
            }
            if sync.synced.remove(local.id) != nil { continue }
            merged.append(local)
            if !sync.refused.contains(local.id) { unsent.append(local.id) }
        }
        if merged != sessions { sessions = merged }
        if unsent.isEmpty {
            revision += 1
            persist()
        } else {
            changed(.save, unsent)
        }
        return true
    }

    /// Every local change: queue its words, save, and let the model send them.
    private func changed(_ kind: PendingWrite.Kind, _ ids: [UUID]) {
        for id in ids {
            writeVersion += 1
            sync.pending[id] = PendingWrite(kind: kind, version: writeVersion,
                                            mutation: MutationStamp.fresh(owner: owner, storage: storage))
        }
        revision += 1
        persist()
        onChange?()
    }

    // MARK: - Persistence (atomic, one backup generation)

    private func load() {
        sessions = []
        for name in ["sessions.json", "sessions.backup.json"] {
            if let data = storage.read(name, owner: owner),
               let decoded = try? JSONDecoder().decode([WatchSession].self, from: data) {
                sessions = decoded
                break
            }
        }
        if let data = storage.read("sessions-sync.json", owner: owner), let decoded = try? JSONDecoder().decode(SyncState.self, from: data) {
            sync = decoded
            writeVersion = decoded.pending.values.map(\.version).max() ?? 0
        }
    }

    private func persist() {
        guard storage.matches(owner) else { return }
        do {
            if let previous = storage.read("sessions.json", owner: owner) {
                try storage.write(previous, name: "sessions.backup.json", owner: owner)
            }
            try storage.write(JSONEncoder().encode(sessions), name: "sessions.json", owner: owner)
        } catch {
            // Atomic writes retain the previous generation. The current session stays in memory.
        }
        persistSync()
    }

    @discardableResult
    private func persistSync() -> Bool {
        guard storage.matches(owner), let data = try? JSONEncoder().encode(sync) else { return false }
        do {
            try storage.write(data, name: "sessions-sync.json", owner: owner)
            return true
        } catch { return false }
    }
}

// MARK: - Wire format (`/me/watch-sessions`, docs/api-contract.md "Watch sessions")

/// `PUT /me/watch-sessions/:id`: the whole session. Nil fields are omitted; the server reads them as null.
struct WatchSessionBody: Encodable, Sendable {
    let franchiseId: String
    let scopeMediaId: Int?
    let ordinal: Int
    let startedAt: Int64?
    let completedAt: Int64?
    let cancelledAt: Int64?
    let cancelledAtEpisode: Int?
    let episodes: Int
    let restoreProgress: [String: Int]?
    let restoreStatus: String?

    init(_ s: WatchSession) {
        franchiseId = s.franchiseId
        if case .part(let mediaId) = s.scope { scopeMediaId = mediaId } else { scopeMediaId = nil }
        ordinal = s.ordinal
        startedAt = s.startedAt
        completedAt = s.completedAt
        cancelledAt = s.cancelledAt
        cancelledAtEpisode = s.cancelledAtEpisode
        episodes = s.episodes
        restoreProgress = s.restoreProgress
        restoreStatus = s.restoreStatus
    }
}

/// One session from `GET /me/watch-sessions`.
struct WatchSessionWire: Decodable, Sendable {
    let id: String
    let franchiseId: String
    let scopeMediaId: Int?
    let ordinal: Int
    let startedAt: Int64?
    let completedAt: Int64?
    let cancelledAt: Int64?
    let cancelledAtEpisode: Int?
    let episodes: Int?
    let restoreProgress: [String: Int]?
    let restoreStatus: String?
}

struct WatchSessionsResponse: Decodable, Sendable {
    let sessions: [WatchSessionWire]
}

extension WatchSession {
    /// nil for an id that is not a UUID (never sent by this server).
    init?(wire w: WatchSessionWire) {
        guard let id = UUID(uuidString: w.id) else { return nil }
        self.init(id: id, franchiseId: w.franchiseId, scope: w.scopeMediaId.map { .part(mediaId: $0) } ?? .franchise,
                  ordinal: w.ordinal, startedAt: w.startedAt, completedAt: w.completedAt, cancelledAt: w.cancelledAt,
                  cancelledAtEpisode: w.cancelledAtEpisode, episodes: w.episodes ?? 0,
                  restoreProgress: w.restoreProgress, restoreStatus: w.restoreStatus)
    }
}
