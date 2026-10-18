import Foundation
import Observation
import WidgetKit

// What the Home Screen widget draws (9 Oct 2026): the app writes this snapshot into the App Group
// container whenever the library changes (`AppModel+Widget.swift`), and the PreviouslyWidgets
// extension reads it (`NextUpWidget.swift`). This file is a member of BOTH targets. Pictures travel
// as files beside it (a poster and a logo per show), because a widget cannot fetch at render time.
struct NextUpSnapshot: Codable {
    /// The App Group both halves share. The capability must be on both App IDs (automatic signing
    /// registers it from the entitlements); without the group the writer does nothing.
    static let group = "group.com.cognipin.previously"
    static let widgetKind = "NextUp"
    static let file = "next-up.json"
    fileprivate static let ownerFile = "owner.json"

    /// A random generation changes at every logout/account switch. The key is already hashed by
    /// AccountLocalStore; neither the widget nor its files need a Clerk identity or credential.
    struct Owner: Codable, Equatable, Sendable {
        let key: String
        let generation: UUID
    }

    /// Real App Group storage in production; explicitly enabled QA uses its own app sandbox.
    static var directory: URL? {
        #if PREVIOUSLY_QA
        // The explicitly enabled, isolated app exercises the same writer/reader without borrowing
        // the installed user's App Group. The QA extension has no shared capability and stays empty.
        guard ProcessInfo.processInfo.environment["PREVIOUSLY_QA"] == "1",
              Bundle.main.bundleIdentifier == "com.cognipin.previously.qa" else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("widget", isDirectory: true)
        #else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("widget", isDirectory: true)
        #endif
    }

    struct Item: Codable, Identifiable {
        enum Kind: String, Codable {
            /// An episode out and unwatched (one).
            case out
            /// Several out and unwatched: `behind` says how many.
            case behind
            /// Nothing out: the next airing, at `airsAt`.
            case airing
            /// Nothing new: the show at the top of the queue.
            case resume
        }

        /// The franchise id — the deep link's subject (`previously://show/<id>`).
        let id: String
        let title: String
        /// "Season 2 · Episode 1" — the episode to watch, or the one that airs next.
        let line: String
        var kind: Kind
        var behind: Int = 0
        var airsAt: Date? = nil
        /// A TMDB airing carries a date, not a time: the widget says the day, never a clock.
        var dateOnly: Bool = false
        /// File names inside `directory`: the show's poster (JPEG) and its logo (PNG).
        var poster: String? = nil
        var logo: String? = nil
        /// The poster's palette colour, sRGB 0…1, for the widget's ground.
        var tint: [Double]? = nil
    }

    let owner: Owner
    var writtenAt: Date
    var items: [Item]

    /// Both the provider and artwork reader fail closed for old ownerless snapshots, signed-out
    /// storage, or an account switch during the read. A timeline's old entry is not authority.
    static func read(directory: URL? = Self.directory) -> NextUpSnapshot? {
        guard let directory, let owner = activeOwner(directory: directory),
              let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(NextUpSnapshot.self, from: data),
              snapshot.owner == owner, isCurrent(owner, directory: directory) else { return nil }
        return snapshot
    }

    static func isCurrent(_ owner: Owner?, directory: URL? = Self.directory) -> Bool {
        guard let owner, let directory else { return false }
        return activeOwner(directory: directory) == owner
    }

    static func artwork(_ name: String?, owner: Owner?, directory: URL? = Self.directory) -> Data? {
        guard let name, let owner, let directory, isCurrent(owner, directory: directory),
              name == URL(fileURLWithPath: name).lastPathComponent,
              name.hasPrefix(owner.generation.uuidString + "-"),
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              isCurrent(owner, directory: directory) else { return nil }
        return data
    }

    fileprivate static func activeOwner(directory: URL) -> Owner? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(ownerFile)),
              let owner = try? JSONDecoder().decode(Owner.self, from: data), !owner.key.isEmpty else { return nil }
        return owner
    }

    fileprivate func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// The gallery's and the placeholder's shape — no real show.
    static let sample = NextUpSnapshot(owner: Owner(key: "preview", generation: UUID()), writtenAt: Date(), items: [
        Item(id: "sample-1", title: "Your next show", line: "Season 2 · Episode 5", kind: .out),
        Item(id: "sample-2", title: "Another show", line: "Season 1 · Episode 9", kind: .airing,
             airsAt: Date().addingTimeInterval(3 * 3600)),
        Item(id: "sample-3", title: "A third", line: "Season 3 · Episode 2", kind: .resume),
    ])
}

/// The app's only widget writer. All account changes and physical writes are synchronous on the
/// main actor; an awaited image load must regain the same lease before it can create any file.
/// The injected directory/callback let regressions exercise these production paths safely.
@MainActor
@Observable
final class NextUpSnapshotStore {
    static let shared = NextUpSnapshotStore(directory: NextUpSnapshot.directory) {
        WidgetCenter.shared.reloadTimelines(ofKind: NextUpSnapshot.widgetKind)
    }

    private let directory: URL?
    private let invalidateTimeline: () -> Void
    private(set) var current: NextUpSnapshot.Owner?
    private(set) var revision = 0

    /// Also lets QA readiness observe actual publication/cleanup, rather than an earlier library
    /// render which happened before the debounced writer ran.
    var snapshot: NextUpSnapshot? {
        _ = revision
        return NextUpSnapshot.read(directory: directory)
    }

    init(directory: URL?, invalidateTimeline: @escaping () -> Void = {}) {
        self.directory = directory
        self.invalidateTimeline = invalidateTimeline
    }

    @discardableResult
    func activate(ownerKey: String?) throws -> NextUpSnapshot.Owner? {
        guard let ownerKey, !ownerKey.isEmpty, let directory else {
            clear()
            return nil
        }
        if let current, current.key == ownerKey, matches(current) { return current }
        // A same-account cold launch keeps its valid offline widget. A different owner, a legacy
        // file or an interrupted cleanup gets a new generation and no inherited artwork/history.
        if current == nil, let saved = NextUpSnapshot.activeOwner(directory: directory), saved.key == ownerKey {
            current = saved
            invalidateTimeline()
            return saved
        }
        clear()
        let owner = NextUpSnapshot.Owner(key: ownerKey, generation: UUID())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try folder.setResourceValues(resources)
            try JSONEncoder().encode(owner).write(to: directory.appendingPathComponent(NextUpSnapshot.ownerFile), options: .atomic)
            current = owner
            return owner
        } catch {
            clear()
            throw error
        }
    }

    func matches(_ owner: NextUpSnapshot.Owner) -> Bool {
        current == owner && NextUpSnapshot.isCurrent(owner, directory: directory)
    }

    func clear() {
        current = nil
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            // Invalidate the reader first, even if removing an artwork file subsequently fails.
            try? Data("null".utf8).write(to: directory.appendingPathComponent(NextUpSnapshot.ownerFile), options: .atomic)
            try? FileManager.default.removeItem(at: directory)
        }
        revision &+= 1
        invalidateTimeline()
    }

    func write(items: [NextUpSnapshot.Item], owner: NextUpSnapshot.Owner) throws {
        guard !Task.isCancelled, matches(owner), let directory else { throw CancellationError() }
        let snapshot = NextUpSnapshot(owner: owner, writtenAt: Date(), items: items)
        try snapshot.encoded().write(to: directory.appendingPathComponent(NextUpSnapshot.file), options: .atomic)
        revision &+= 1
        invalidateTimeline()
    }

    /// The loader may ignore cancellation (the shared image pipeline does). Ownership is checked
    /// after it completes and immediately before writing, with no intervening suspension point.
    func loadArtwork(name: String, owner: NextUpSnapshot.Owner,
                     load: @MainActor () async throws -> Data) async throws -> String {
        guard !Task.isCancelled, matches(owner), !name.isEmpty,
              name == URL(fileURLWithPath: name).lastPathComponent, !name.hasPrefix(".") else { throw CancellationError() }
        let data = try await load()
        guard !Task.isCancelled, matches(owner), let directory else { throw CancellationError() }
        let filename = owner.generation.uuidString + "-" + name
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return filename
    }
}
