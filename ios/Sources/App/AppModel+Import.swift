import SwiftUI

// History import (4 Oct 2026): a list kept elsewhere — AniList, MyAnimeList, TV Time — brought in.
// The research behind first run (design/onboarding-2026-10-04/SPIKE.md) found it the year's
// biggest first-run feature (TV Time closed in July) and found what people resent about the
// importers: histories that arrive half-marked. So it is two steps — a PREVIEW that says in counts
// what will be added and what could not be placed, then the write — and the server never lowers a
// count or changes the status of a show already here (`server/src/import`).
//
// Shows the catalogue already holds are in the library the moment the import is applied; ones
// nobody has added before are fetched and added by the server afterwards — about five seconds a
// series, what they are watching first, so a long anime list takes the better part of an hour.
// This follows that tail: it asks how far it has got and reloads the library as shows arrive,
// whatever screen the viewer has moved on to. The server finishes whether or not the app is open.

/// `POST /me/import/preview`'s body: one source, and what the device read from it.
enum ImportRequest: Encodable, Sendable {
    case anilist(username: String)
    case mal(rows: [ImportMalRow])
    case tvtime(shows: [ImportTvShow])

    private enum Keys: String, CodingKey { case source, username, rows, shows }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .anilist(let username):
            try c.encode("anilist", forKey: .source)
            try c.encode(username, forKey: .username)
        case .mal(let rows):
            try c.encode("mal", forKey: .source)
            try c.encode(rows, forKey: .rows)
        case .tvtime(let shows):
            try c.encode("tvtime", forKey: .source)
            try c.encode(shows, forKey: .shows)
        }
    }
}

/// What an import would add (nothing is written yet).
struct ImportPreview: Decodable, Sendable {
    struct Unmatched: Decodable, Sendable {
        let count: Int
        let titles: [String]
    }
    let id: String
    let source: String
    /// What the list holds in ITS unit: an anime list's entries (a season, a film — the number
    /// their own profile shows), TV Time's shows.
    let listed: Int
    /// Shows the catalogue holds: added the moment the import is applied.
    let ready: Int
    /// Still to fetch, in the list's unit: added in the background.
    let toFetch: Int
    /// Episodes watched, across the whole list.
    let episodes: Int
    /// The ready shows by status (`watching`, `completed`, `planned`, `paused`, `dropped`).
    let byStatus: [String: Int]
    let unmatched: Unmatched
    let sample: [FranchiseSummary]
    /// Deliberately omitted titles; older servers do not send this field.
    let skipped: ImportSkipped?

    var total: Int { ready + toFetch }
    var adultSkipped: Int { skipped?.adultCount ?? 0 }
    /// An anime list counts ENTRIES, and this app keeps a series' seasons as one show: the two
    /// numbers differ, and the sheet never calls an entry a show.
    var countsEntries: Bool { source != "tvtime" }
}

extension AppModel {
    static let importProgressKey = "previously.import.progress"

    func resumeImport() {
        guard !isIsolated, !erasing else { return }
        if importProgress == nil,
           let data = AccountLocalStore.shared.read("import-progress.json", owner: accountStorage),
           let saved = try? JSONDecoder().decode(ImportProgress.self, from: data) {
            importProgress = saved
        }
        guard let progress = importProgress, !progress.isDone, importFollow == nil else { return }
        followImport(progress.id, shows: progress.shows)
    }

    /// After an import is applied: reload now (the ready shows are in), then follow the tail.
    /// `importProgress` keeps the last word on it — the sheet's done screen reads it — until the
    /// next import or a sign-out.
    func importApplied(_ progress: ImportProgress) async {
        importFollow?.cancel()
        let epoch = accountEpoch
        importProgress = progress
        await reload()
        guard !progress.isDone, epoch == accountEpoch else { return }
        followImport(progress.id, shows: progress.shows)
    }

    /// Asks how far the background part has got — every few seconds for the first minute (a short
    /// tail lands inside it), then four times a minute — and reloads the library when shows have
    /// arrived, and once more when it is done. Ninety minutes at most. A server that has
    /// forgotten the import (a restart) ends it, and what had not arrived is then SAID not to
    /// have (`abandoned`) — importing again picks it up; nothing is promised that will not come.
    private func followImport(_ id: String, shows: Int) {
        importFollow?.cancel()
        let epoch = accountEpoch
        importFollow = Task { [weak self] in
            var seen = shows
            var last: ImportProgress?
            var forgotten = false
            for tick in 0..<370 {
                try? await Task.sleep(for: .seconds(tick < 15 ? 4 : 15))
                guard let self, !Task.isCancelled, epoch == self.accountEpoch, self.importProgress?.id == id else { return }
                let progress: ImportProgress
                do { progress = try await self.api.importProgress(id: id) } catch {
                    if let status = (error as? APIError)?.status, status == 410 || status == 404 {
                        forgotten = true
                        break
                    }
                    continue
                }
                guard !Task.isCancelled, epoch == self.accountEpoch, self.importProgress?.id == id else { return }
                last = progress
                self.importProgress = progress
                if progress.shows != seen || progress.isDone {
                    seen = progress.shows
                    await self.reload()
                }
                if progress.isDone { self.importFollow = nil; return }
            }
            guard let self, !Task.isCancelled, epoch == self.accountEpoch, self.importProgress?.id == id else { return }
            // A vanished server job is final. A local polling limit or offline interval says
            // nothing about whether the server finished; do not turn those into failed imports.
            if let known = last ?? self.importProgress, known.id == id {
                self.importProgress = forgotten ? known.abandoned : known
            }
            self.importFollow = nil
            await self.reload()
        }
    }
}
