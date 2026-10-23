import Foundation

// The stories tray: one reel per library show with a fresh drop. Stories stay CLIENT-DERIVED (brief
// §4) — they come from the library's own airings, which are time-zone dependent and already right
// here — so this is pure code over `[Franchise]`, memoised by the model (`AppModel.storyReels`),
// never built in a body. Ported from the spike's story builder and its `galleryArt`, with the
// bugs the maps found fixed (see `StoryReel.build`).

/// One picture a frame draws.
struct StoryPicture: Hashable, Sendable {
    let url: String?
    /// A 2:3 poster (fills the tall frame) rather than a 16:9 landscape (set across the top).
    let portrait: Bool
    /// The poster prints the show's logotype — a story zooms past it rather than set its own header
    /// over someone else's lettering.
    let titled: Bool
}

struct StoryFrame: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case episode, next }

    /// `"<franchiseId>:<episode>"` | `"<franchiseId>:next"`.
    let id: String
    let kind: Kind
    let episode: Int
    /// The slot, from `part.airings` (nil = unknown).
    let at: Int64?
    let art: StoryPicture
    let isFinale: Bool
}

struct StoryReel: Identifiable, Hashable, Sendable {
    let franchiseId: String
    /// The releasing part. LOGIC re-reads the live part by this id (`appModel.franchise(id:)`); the
    /// reel keeps only the strings it draws, so a show removed mid-story still renders its frame.
    let mediaId: Int
    let source: MediaSource
    /// `displayTitle`, for the bubble and the header.
    let showTitle: String
    let partLabel: String
    /// `FeedAvatar.candidates(franchise)`, computed once.
    let avatarCandidates: [String]
    let frames: [StoryFrame]
    let unwatched: Int
    let latestAired: Int64

    var seen: Bool { unwatched == 0 }
    var id: String { franchiseId }
    /// The show's calendar (`Franchise.timeAnchor`): real instants for anime and TV at broadcast times.
    let anchor: Formatting.TimeAnchor

    /// How long a drop stays in the tray: a week, plus the six hours that keep last week's
    /// episode up until this week's airs on a slow sync.
    static let freshWindow: Int64 = 7 * Formatting.D + 6 * Formatting.H

    /// The statuses whose shows have a tray: you follow them, or finished and a new season started.
    private static let trayStatuses: Set<WatchStatus> = [.watching, .paused, .completed]

    /// One reel per library show with an aired, unwatched-or-just-watched drop in the last
    /// `freshWindow`. Frames: each unwatched episode (the four newest at most), else the latest aired
    /// one; then the next slot when there is one.
    ///
    /// Changes from the spike (each a bug the maps found):
    /// - The status is `effectiveStatus` (the spike read the raw `status`, which a library row built
    ///   from `subscription` alone leaves nil), and `tracksAirings` gates it like every calendar surface.
    ///   A MUTED show keeps its reel: a mute silences the show's NEWS ("You muted news from …"), and a
    ///   reel is the user's own library episode — after this build the only one-tap mark on Today.
    /// - Freshness is read only through the airings-aware ladder (`lastAired` / `airedByNow` /
    ///   `upcomingAiring`) in the show's own calendar (CLAUDE.md, "Freshness is derived from airings").
    /// - A part with nothing aired has no reel (the spike drew "Episode 0").
    /// - A "next" slot that is already counted as aired is not a next frame.
    /// - Art goes through `WideArt.storyResolution` (a screen-sized TMDB bucket), never `original`.
    /// - The order is deterministic: unseen first, newest drop first, then `franchiseId`.
    ///
    /// Pure and nonisolated (`FeedAvatar.candidates` is `nonisolated`): the model memoises it, and
    /// the DEBUG regression may call it from anywhere.
    static func build(library: [Franchise], now: Int64, constrained: Bool) -> [StoryReel] {
        var reels: [StoryReel] = []
        for f in library where f.tracksAirings && trayStatuses.contains(f.effectiveStatus) {
            guard let part = f.releasingPart else { continue }
            let anchor = f.timeAnchor
            guard let last = part.lastAired(now: now, anchor: anchor), now - last <= freshWindow else { continue }
            let aired = part.airedByNow(now: now, anchor: anchor)
            guard aired > 0 else { continue }
            let unwatched = max(0, aired - part.progress)
            let gallery = galleryArt(f, part: part, constrained: constrained)
            func finale(_ episode: Int) -> Bool { part.totalEpisodes > 0 && episode == part.totalEpisodes }
            func slot(_ episode: Int) -> Int64? { part.airings.first { $0.episode == episode }?.at }

            var frames: [StoryFrame] = []
            if unwatched > 0 {
                let first = max(part.progress + 1, aired - 3)   // the four newest at most
                for (i, ep) in (first...aired).enumerated() {
                    frames.append(StoryFrame(id: "\(f.id):\(ep)", kind: .episode, episode: ep, at: slot(ep),
                                             art: gallery[i % gallery.count], isFinale: finale(ep)))
                }
            } else {
                frames.append(StoryFrame(id: "\(f.id):\(aired)", kind: .episode, episode: aired,
                                         at: slot(aired) ?? last, art: gallery[0], isFinale: finale(aired)))
            }
            if let nextAt = part.upcomingAiring(now: now, anchor: anchor) {
                let slotted = part.airings.first { $0.at == nextAt }?.episode
                    ?? (nextAt == part.nextAiringAt ? part.nextEpisodeNumber : nil)
                let ep = slotted ?? (aired + 1)
                if ep > aired {
                    frames.append(StoryFrame(id: "\(f.id):next", kind: .next, episode: ep, at: nextAt,
                                             art: gallery[frames.count % gallery.count], isFinale: finale(ep)))
                }
            }
            reels.append(StoryReel(franchiseId: f.id, mediaId: part.mediaId, source: f.source,
                                   showTitle: f.displayTitle, partLabel: part.label,
                                   avatarCandidates: FeedAvatar.candidates(f), frames: frames,
                                   unwatched: unwatched, latestAired: last, anchor: anchor))
        }
        // Unseen first, newest drop first — Instagram's order; the id breaks a tie.
        return reels.sorted { a, b in
            if a.seen != b.seen { return !a.seen }
            if a.latestAired != b.latestAired { return a.latestAired > b.latestAired }
            return a.franchiseId < b.franchiseId
        }
    }

    /// Different pictures for successive frames — the textless key art first, then a TRUE landscape,
    /// the titled poster last — so a three-episode story is not one still three times. Never empty.
    private static func galleryArt(_ f: Franchise, part: FranchisePart, constrained: Bool) -> [StoryPicture] {
        var out: [StoryPicture] = []
        var seen = Set<String>()
        func add(_ url: String?, portrait: Bool, titled: Bool) {
            guard let url = ArtworkSet.nonEmpty(url), seen.insert(url).inserted else { return }
            out.append(StoryPicture(url: WideArt.storyResolution(url, constrained: constrained),
                                    portrait: portrait, titled: titled))
        }
        add(f.textlessPortrait, portrait: true, titled: false)
        // Only positively textless key art is claimed untitled (`ArtworkImage.isTextlessKeyArt`): a
        // missing language tag is not evidence the poster carries no logotype.
        for p in (f.artwork?.portraits ?? []).prefix(8) where p.isTextlessKeyArt && p.url != f.portraitArt {
            add(p.url, portrait: true, titled: false)
        }
        // A 4.75:1 AniList banner is not a frame's landscape (its middle third is a pair of eyes).
        if let wide = [part.landscapeArt, f.landscapeArt].compactMap({ $0 })
            .first(where: { !$0.contains("/anime/banner/") }) {
            add(wide, portrait: false, titled: false)
        }
        add(f.portraitArt, portrait: true, titled: f.textlessPortrait == nil)
        add(part.portraitArt, portrait: true, titled: true)
        if out.isEmpty { out.append(StoryPicture(url: nil, portrait: true, titled: true)) }
        return out
    }
}
