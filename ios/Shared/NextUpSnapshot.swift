import Foundation

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

    /// The shared container, nil where the group is not provisioned (the QA build, a stale profile).
    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("widget", isDirectory: true)
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

    var writtenAt: Date
    var items: [Item]

    static func read() -> NextUpSnapshot? {
        guard let url = directory?.appendingPathComponent(file), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(NextUpSnapshot.self, from: data)
    }

    func write() throws {
        guard let dir = Self.directory else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: dir.appendingPathComponent(Self.file), options: .atomic)
    }

    /// The gallery's and the placeholder's shape — no real show.
    static let sample = NextUpSnapshot(writtenAt: Date(), items: [
        Item(id: "sample-1", title: "Your next show", line: "Season 2 · Episode 5", kind: .out),
        Item(id: "sample-2", title: "Another show", line: "Season 1 · Episode 9", kind: .airing,
             airsAt: Date().addingTimeInterval(3 * 3600)),
        Item(id: "sample-3", title: "A third", line: "Season 3 · Episode 2", kind: .resume),
    ])
}
