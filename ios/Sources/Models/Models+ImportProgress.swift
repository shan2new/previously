import Foundation

/// Deliberate catalogue-policy omissions are separate from unmatched titles and fetch failures.
struct ImportSkipped: Codable, Sendable, Equatable {
    struct Reasons: Codable, Sendable, Equatable {
        let adultContent: Int?

        enum CodingKeys: String, CodingKey { case adultContent = "adult_content" }
    }

    let count: Int
    let reasons: Reasons

    var adultCount: Int { max(0, reasons.adultContent ?? 0) }
}

struct ImportProgress: Codable, Sendable, Equatable {
    let id: String
    let state: String
    /// Shows in the library from this import so far.
    let shows: Int
    /// Still to fetch, in the list's unit.
    let remaining: Int
    let failed: Int
    /// Missing on older servers and in older saved progress; it means no reported omissions.
    let skipped: ImportSkipped?

    init(id: String, state: String, shows: Int, remaining: Int, failed: Int, skipped: ImportSkipped? = nil) {
        self.id = id
        self.state = state
        self.shows = shows
        self.remaining = remaining
        self.failed = failed
        self.skipped = skipped
    }

    var isDone: Bool { state == "done" }
    var adultSkipped: Int { skipped?.adultCount ?? 0 }

    /// A forgotten job cannot deliver its remaining titles. Keep deliberate policy omissions
    /// unchanged: they were never queued fetches and must not become provider failures.
    var abandoned: ImportProgress {
        ImportProgress(id: id, state: "done", shows: shows, remaining: 0,
                       failed: failed + remaining, skipped: skipped)
    }
}
