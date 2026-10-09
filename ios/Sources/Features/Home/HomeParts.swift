import SwiftUI
import UIKit

// Home's pieces: what it draws (`HomeFeed`, composed once per library and minute) and the views
// that draw it — the bar, the billboard, the Up next tiles. See `HomeView`.

// MARK: - What Home draws

/// The one thing to watch next, as the billboard says it.
struct HomeHero: Identifiable {
    enum Kind: Equatable {
        /// A drop you have not seen: `behind` episodes are out and unwatched on this part.
        case outNow(behind: Int)
        /// Nothing out anywhere: the next airing, at `at` (today's, else the week's first).
        case airing(at: Int64)
        /// Nothing new: the show at the top of your queue.
        case resume
    }

    let franchise: Franchise
    let part: FranchisePart
    /// The episode the billboard offers — the next to WATCH, or the one that airs next.
    let episode: Int
    let kind: Kind
    /// "Episode 24 aired yesterday", under a backlog's count: the drop, named.
    var drop: String? = nil

    var id: String { "\(franchise.id)/\(part.mediaId)/\(episode)" }

    /// Out, so there is something to mark.
    var canMark: Bool {
        if case .airing = kind { return false }
        return true
    }

    /// A DROP — an episode out and unwatched — the only thing the full-bleed billboard shows (9 Oct:
    /// "only the most recently aired franchise(s) should be shown in full bleed hero… upcoming and
    /// otherwise… loses the significance", owner). The rest is the quiet card.
    var isDrop: Bool {
        if case .outNow = kind { return true }
        return false
    }
}

/// A show in your queue, at the episode you left off.
struct HomeQueueItem: Identifiable, Equatable {
    let franchise: Franchise
    let part: FranchisePart
    /// Episodes out recently and unwatched — the NEW tag; 0 for a backlog.
    let fresh: Int

    var id: String { franchise.id }
    var episode: Int { part.progress + 1 }

    static func == (a: Self, b: Self) -> Bool {
        a.franchise.id == b.franchise.id && a.part.mediaId == b.part.mediaId
            && a.part.progress == b.part.progress && a.fresh == b.fresh
    }
}

/// One airing on the calendar, with its day — an episode out this past week and not marked
/// (Recently aired), or, for the billboard's last resort, the next one still to come.
struct HomeAiring: Identifiable {
    let entry: AppModel.ScheduleEntry
    /// Day offset from today: ≤ 0 for Recently aired, ≥ 0 for what is still to come.
    let day: Int
    /// Local noon of that day.
    let noon: Int64
    var id: String { entry.id }
}

struct HomeFeed {
    /// The billboard's pages: the DROPS of the past week, newest first, up to `billboardLimit` — a
    /// pager when there are several, the one billboard when there is one. Empty when nothing is out.
    var heroes: [HomeHero] = []
    /// With nothing out: the top of the queue, else the next airing — on the QUIET card (shorter,
    /// no badge), never the stage. Nil when the board is clear.
    var quiet: HomeHero?
    /// The past week's episodes you have not marked, newest first — the billboard's shows aside.
    var recent: [HomeAiring] = []
    /// The rest of your queue: shows the billboard and Recently aired do not already carry.
    var queue: [HomeQueueItem] = []

    /// How many rows a list shows before its header's chevron takes over.
    static let listLimit = 5
    /// How many drops the billboard pages through; the rest go to Recently aired.
    static let billboardLimit = 3

    /// The lead: the newest drop, else the quiet card's show.
    var hero: HomeHero? { heroes.first ?? quiet }
    /// Something on the billboard, full bleed or quiet.
    var hasBillboard: Bool { hero != nil }

    var isEmpty: Bool { hero == nil && recent.isEmpty && queue.isEmpty }
}

@MainActor
enum HomeCompose {
    static func feed(_ m: AppModel) -> HomeFeed {
        let now = m.nowMinute
        var out = HomeFeed()

        // Up next — Library's Continue rule: every Watching show with a part to resume. A fresh
        // drop leads (newest first); then what you are IN THE MIDDLE OF before what you have not
        // begun (a Watching show never started led the shelf as its biggest backlog — "Up next" is
        // continuing first); within each, the shelf's own order.
        let shelf: [HomeQueueItem] = m.watchingShelf.compactMap { f in
            guard let part = f.resumePart else { return nil }
            return HomeQueueItem(franchise: f, part: part, fresh: freshCount(f, part: part, now: now))
        }
        let rank = Dictionary(uniqueKeysWithValues: shelf.enumerated().map { ($1.id, $0) })
        let queue = shelf.sorted { a, b in
            if (a.fresh > 0) != (b.fresh > 0) { return a.fresh > 0 }
            if a.fresh > 0 {
                // The resume part's own drop: `Franchise.lastAired` reads only a RELEASING part,
                // and a finale's season has stopped releasing.
                let la = a.part.lastAired(now: now, anchor: a.franchise.timeAnchor) ?? 0
                let lb = b.part.lastAired(now: now, anchor: b.franchise.timeAnchor) ?? 0
                if la != lb { return la > lb }
            }
            let begunA = a.franchise.parts.contains { $0.progress > 0 }
            let begunB = b.franchise.parts.contains { $0.progress > 0 }
            if begunA != begunB { return begunA }
            return (rank[a.id] ?? 0) < (rank[b.id] ?? 0)
        }

        let days = m.scheduleDays
        // Recently aired — "what about previous week / unmarked episodes?" (owner, 26 Sep): what is
        // out from the last seven days (today included) and not marked, newest first, ONE ROW PER
        // SHOW — its newest episode ("Only the most recent episode of that series NOT multiple
        // unseen episodes", owner, same day). The row names the run still to watch ("Episodes
        // 22–24") and its ring marks through it, the count confirmed first.
        // The STORY's episodes only (`isMainStory`): the shorts that air beside a season are on the
        // calendar, and half an hour later than the episode — so, newest first, they were the one
        // row a show kept (Re:ZERO's "Break Time" for Season 4's finale, 4 Oct).
        var listed = Set<String>()
        let recent: [HomeAiring] = days
            .filter { $0.id <= 0 && $0.id > -7 }
            .flatMap { d in
                d.entries.filter { $0.aired && !$0.watched && $0.part.isMainStory }
                    .map { HomeAiring(entry: $0, day: d.id, noon: d.noon) }
            }
            .sorted { $0.entry.at > $1.entry.at }
            .filter { listed.insert($0.entry.franchise.id).inserted }
        // The billboard is for what you can WATCH — and only that (9 Oct: "only the most recently
        // aired franchise(s) should be shown in full bleed hero. It doesn't make sense to show what is
        // upcoming and otherwise in full bleed as it loses the significance", owner). Its pages are the
        // week's DROPS, newest first: a fresh drop on a show you are watching, and the newest episode
        // out this past week that you have not marked whichever shelf its show sits on (Recently
        // aired lists paused and finished shows too), one page per show, `billboardLimit` at most.
        // Before this the stage took the top of the queue and then tonight's airing when nothing was
        // out (26 Sep's ladder), which spent the full-bleed on things that were not news.
        var dated: [(hero: HomeHero, at: Int64)] = []
        for item in queue where item.fresh > 0 {
            let at = item.part.lastAired(now: now, anchor: item.franchise.timeAnchor) ?? 0
            dated.append((heroFor(item, now: now), at))
        }
        for airing in recent {
            guard let item = dropItem(airing, now: now) else { continue }
            dated.append((heroFor(item, now: now), airing.entry.at))
        }
        var paged = Set<String>()
        let heroes = dated.sorted { $0.at > $1.at }
            .filter { paged.insert($0.hero.franchise.id).inserted }
            .prefix(HomeFeed.billboardLimit)
            .map(\.hero)
        // Nothing out: the QUIET card — the top of your queue (something you can still watch), else
        // the next airing (today's, else the week's first) — shorter, badge-less, never the stage.
        var quiet: HomeHero?
        if heroes.isEmpty {
            if let item = queue.first {
                quiet = heroFor(item, now: now)
            } else if let next = days.filter({ $0.id >= 0 && $0.id < 7 })
                        .lazy.flatMap({ d in d.entries.filter { !$0.aired } }).first {
                quiet = HomeHero(franchise: next.franchise, part: next.part,
                                 episode: next.episode, kind: .airing(at: next.at))
            }
        }
        out.heroes = Array(heroes)
        out.quiet = quiet
        #if DEBUG
        // `-homeHero <franchiseId>` (DEBUG): photograph a given show on the billboard — its queue item,
        // else its next airing. It selects; it never fabricates.
        if let id = UserDefaults.standard.string(forKey: "homeHero"), let f = m.library.first(where: { $0.id == id }) {
            var forced: HomeHero?
            if let item = queue.first(where: { $0.id == id }) {
                forced = heroFor(item, now: now)
            } else if let part = f.resumePart {
                forced = heroFor(HomeQueueItem(franchise: f, part: part, fresh: freshCount(f, part: part, now: now)), now: now)
            } else if let next = days.lazy.flatMap(\.entries).first(where: { $0.franchise.id == id && !$0.aired }) {
                forced = HomeHero(franchise: f, part: next.part, episode: next.episode, kind: .airing(at: next.at))
            }
            if let forced {
                out.heroes = forced.isDrop ? [forced] : []
                out.quiet = forced.isDrop ? nil : forced
            }
        }
        #endif

        // Each show once, in the first place that carries it: the billboard, then Recently aired,
        // then Up next. What airs next is the Schedule tab's (26 Sep: the calendar is a tab again).
        let billboardShows = Set(out.heroes.map(\.franchise.id) + [out.quiet?.franchise.id].compactMap { $0 })
        out.recent = Array(recent.filter { !billboardShows.contains($0.entry.franchise.id) }.prefix(HomeFeed.listLimit))
        let recentShows = Set(out.recent.map(\.entry.franchise.id))
        out.queue = queue.filter { !billboardShows.contains($0.id) && !recentShows.contains($0.id) }
        return out
    }

    /// A recently aired episode as the billboard's item: its part at the episode you left off, with
    /// what is out and unwatched as the count — only while you are FOLLOWING that part (`isNews`),
    /// so a thousand-episode backlog that gained one this week stays a backlog, not a drop.
    private static func dropItem(_ airing: HomeAiring, now: Int64) -> HomeQueueItem? {
        let f = airing.entry.franchise, part = airing.entry.part
        // The airing has struck, whatever the catalogue's count says yet: a premiere is out while
        // its season still reads "not yet released" (Black Clover's Season 2, the morning after).
        let behind = max(part.unwatchedOut(now: now, anchor: f.timeAnchor), airing.entry.episode - part.progress)
        guard behind > 0, part.isNews(now: now, anchor: f.timeAnchor, window: AppModel.outNowWindow) else { return nil }
        return HomeQueueItem(franchise: f, part: part, fresh: behind)
    }

    /// Unwatched episodes of a drop inside the out-now window, on the part you would RESUME —
    /// `AppModel.outNow`'s own test, minus its "still releasing" gate: a FINALE is the freshest drop
    /// there is, and the season it ends stops releasing the moment it airs (Slime's Season 4,
    /// 25 Sep, was out of `outNow` the next morning with three episodes unwatched). Asked of the
    /// resume part itself: `Franchise.freshPart` answers the first part in catalogue order with a
    /// recent drop, which for Re:ZERO was a run of shorts — so its finale was not fresh at all.
    private static func freshCount(_ f: Franchise, part: FranchisePart, now: Int64) -> Int {
        let window = AppModel.outNowWindow
        let behind = part.unwatchedOut(now: now, anchor: f.timeAnchor)
        guard behind > 0, part.isNews(now: now, anchor: f.timeAnchor, window: window),
              let last = part.lastAired(now: now, anchor: f.timeAnchor), now - last <= window else { return 0 }
        return behind
    }

    private static func heroFor(_ item: HomeQueueItem, now: Int64) -> HomeHero {
        let f = item.franchise, part = item.part
        guard item.fresh > 0 else {
            return HomeHero(franchise: f, part: part, episode: item.episode, kind: .resume)
        }
        // The same count the NEW tag and the stories say: episodes out and unwatched on the part.
        let behind = item.fresh
        // The drop is named only under a backlog: with one episode out, "New episode" IS the drop.
        var drop: String?
        if behind > 1, let last = part.lastAired(now: now, anchor: f.timeAnchor) {
            drop = Copy.Progress.dropAired(episode: part.airedByNow(now: now, anchor: f.timeAnchor),
                                           when: TemporalCopy.aired(at: last, now: now, source: f.source))
        }
        return HomeHero(franchise: f, part: part, episode: item.episode, kind: .outNow(behind: behind), drop: drop)
    }
}

/// The composed feed, held by reference so a cache fill inside a body read never invalidates the
/// view (Schedule's `DerivedBox`).
@MainActor
final class HomeFeedBox {
    var key: AppModel.ScheduleFeedKey?
    var value = HomeFeed()
}

// MARK: - The bar's one moving fact

/// Whether the billboard has gone under the bar — written by the scroll probe, read only by the bar
/// (the app's rule: the scroll offset is never screen state).
@MainActor @Observable
final class HomeChrome: ScrollAwayChrome {
    private(set) var solid = false
    /// The page's content top in the window, to the pixel — read only by the bars' grounds
    /// (`HomeGroundWindow`), which draw the page's own ground where the page draws it.
    private(set) var contentTop: CGFloat = 0
    /// How far the bar's row has slid up: 0 (all there) … its height (gone) — the bars leave with
    /// a reader's scroll and return with it, as every root's do (`RootChromeState`, 4 Oct).
    private(set) var offset: CGFloat = 0
    /// The same title glow is visible through the bars as on the page behind them.
    private(set) var lighting = HomeLockupLighting()

    @ObservationIgnored private var billboardBottom: CGFloat = 0
    @ObservationIgnored private var copyTop: CGFloat = .infinity
    @ObservationIgnored private var lastY: CGFloat = 0
    /// The READER is moving the page (a finger, or its momentum) — not the app (a scroll to top).
    @ObservationIgnored private var following = false

    private var barBottom: CGFloat { ThemeMetrics.topSafeInset + FeedMetrics.headerRow }
    private var rowHeight: CGFloat { FeedMetrics.headerRow }

    var awayFraction: CGFloat { offset / rowHeight }

    /// The page's content top, in the window, and the billboard's height (0 without one).
    func track(contentTop y: CGFloat, billboard: CGFloat) {
        let px = ThemeMetrics.pixel
        let top = (y / px).rounded() * px
        if top != contentTop { contentTop = top }
        // The bars ride a reader's scroll (VoiceOver keeps them).
        let scrolled = -y
        let dy = scrolled - lastY
        lastY = scrolled
        if following, !UIAccessibility.isVoiceOverRunning {
            let next: CGFloat = scrolled <= 0 ? 0 : min(max(offset + dy, 0), rowHeight)
            if abs(next - offset) >= 0.5 || (next == 0 && offset != 0) { offset = next }
        }
        billboardBottom = y + billboard
        if billboard == 0 { copyTop = .infinity }
        update()
    }

    /// The billboard's lockup top, in the window: the bar takes the canvas the moment the copy
    /// reaches it — the art may pass under the glyphs on its veil, words may not (the badge and
    /// the episode read through the bar's icons otherwise).
    func trackCopy(top: CGFloat) {
        copyTop = top
        update()
    }

    func trackLighting(_ next: HomeLockupLighting) {
        if lighting != next { lighting = next }
    }

    private func update() {
        let next = copyTop < barBottom + 12 || billboardBottom < barBottom + 24
        if next != solid { solid = next }
    }

    /// The page's scroll phase: only a reader's scroll moves the bars, and at rest they are either
    /// shown or gone.
    func phase(_ phase: ScrollPhase) {
        following = phase == .interacting || phase == .decelerating
        guard phase == .idle, offset > 0, offset < rowHeight else { return }
        let gone = offset > rowHeight / 2 && lastY > rowHeight
        withAnimation(Self.motion) { offset = gone ? rowHeight : 0 }
    }

    func reveal() {
        guard offset != 0 else { return }
        withAnimation(Self.motion) { offset = 0 }
    }

    private static var motion: Animation {
        ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }
}

// MARK: - The bar

/// X's row, as the feed's: you on the left, the mark alone in the middle — the scroll-to-top.
/// (The calendar glyph on the right went when Schedule became a tab again, 26 Sep.) Over the
/// billboard it is only its glyphs on the art's veil; once the billboard has passed under it, the
/// canvas and one physical pixel of rule.
struct HomeHeader: View {
    let chrome: HomeChrome
    /// The bar's ground once solid: the PAGE'S OWN ground, seen through the bar (`HomeGroundWindow`)
    /// — the show's hue at canvas depth over the billboard, the canvas further down — so the bar
    /// is FLUSH with what it sits on, never a black lid over a tinted page nor a tinted one over
    /// the canvas.
    var ground: HomePageGround = .canvas
    /// The veil the glyphs and the clock stand on while art is under them — the billboard's
    /// protection (`HeroProtection`), nil with no billboard. PINNED here: on the billboard it
    /// scrolled away with the page, and the picture, moving slower, slid bare under the clock.
    var veil: Double? = nil
    let onProfile: () -> Void
    let onTop: () -> Void

    @Environment(AuthManager.self) private var auth

    var body: some View {
        ZStack {
            Button(action: onTop) {
                PreviouslyMark(width: FeedHeader.markWidth, style: .glyph, ink: ThemeColor.feedText)
                    .padding(.horizontal, ThemeSpace.x3)
                    .frame(minHeight: FeedMetrics.headerRow)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FeedIconPressStyle())
            .accessibilityLabel(Copy.Feed.scrollToTop)
            HStack(spacing: 0) {
                Button(action: onProfile) {
                    AccountDisc(identity: auth.identity, diameter: 32, quiet: true)
                        .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight,
                               alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FeedIconPressStyle())
                .accessibilityLabel(Copy.Feed.profile)
                .qaIdentifier("qa.profile.open")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .frame(height: FeedMetrics.headerRow)
        // The row leaves with the scroll (and the tab bar with it); the veil and the status
        // band's ground stay for the clock.
        .modifier(RootChromeFade(chrome: chrome))
        .modifier(RootChromeSlide(chrome: chrome))
        .background(alignment: .top) { HomeHeaderGround(chrome: chrome, ground: ground, veil: veil) }
    }
}

/// The bar's veil, ground and rule — with `HomeGroundWindow`, the only readers of `HomeChrome`.
private struct HomeHeaderGround: View {
    let chrome: HomeChrome
    let ground: HomePageGround
    let veil: Double?

    private var band: CGFloat { ThemeMetrics.topSafeInset + FeedMetrics.headerRow }

    var body: some View {
        // The solid ground goes up with the row, down to the status band alone.
        let away = chrome.offset
        ZStack(alignment: .top) {
            if let veil {
                HeroTopVeil(band: band, ramp: 100, strength: veil)
                    .opacity(chrome.solid ? 0 : 1)
            }
            HomeGroundWindow(chrome: chrome, ground: ground, top: -away, height: band)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(ThemeColor.feedSeparator).frame(height: FeedMetrics.hairline)
                }
                .offset(y: -away)
                .opacity(chrome.solid ? 1 : 0)
        }
        // From the window's top edge: the status band is the bar's too.
        .frame(height: FeedMetrics.headerRow, alignment: .top)
        .offset(y: -ThemeMetrics.topSafeInset)
        .animation(ThemeMotion.uiGentle, value: chrome.solid)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - The billboard

/// The next thing to watch, full bleed — the retired Today billboard's grammar, which the owner
/// asked back for Home ("let's make it like the full bleed art it was earlier", 26 Sep): the show's
/// best-looking POSTER composited whole, breathing and stretching with a pull, the bar's veil over
/// its top and a scrim sized to the copy that lands on canvas; then, centred, the state in its
/// badge, the show's logo else its name, the episode, where you are, the drop, and the mark.
///
/// The STAGE — the picture, its pick, its arrival, the scrim and the glow — is `ShowBillboard`
/// (DesignSystem), shared with the show page and Schedule's card since 9 Oct; this view is Home's
/// LOCKUP on it. GLOW (26 Sep: "utterly delightful and an eye candy without going overboard", then
/// "Glow is sick", owner — `HomeHeroScene.swift`): light and depth, nothing added to the page.
///
/// A mark is a small event, not a jump: the pill says "Watched" for a beat (`committing`) as a ring
/// leaves it (`MarkPulse`), then the count, the episode and the bar ROLL to the next one (numeric
/// text, one spring), and a show you have caught up on hands the frame to the next thing
/// (`HomeView`'s handoff).
struct HomeBillboard: View {
    let hero: HomeHero
    let now: Int64
    let height: CGFloat
    /// The status bar and the bar's row: the veil protects it, and a titled poster starts under it.
    let band: CGFloat
    /// The mark is mid-flight: the pill wears its watched state until the write lands.
    var committing: Bool = false
    /// The palette colour of the art (`HomeView` resolves it: the page is painted from it too) and
    /// the ground the frame lands on — the show's hue at canvas depth.
    var tint: Color? = nil
    var landing: Color = ThemeColor.canvas
    let onOpen: () -> Void
    let onMark: () -> Void
    var onArtLoaded: (() -> Void)? = nil
    /// The lockup's top in the window, for the bar (`HomeChrome.trackCopy`).
    var onCopyTop: ((CGFloat) -> Void)? = nil
    /// The picture the billboard settled on — the page is painted from its colour.
    var onArt: ((String?) -> Void)? = nil
    var onLightingChange: ((HomeLockupLighting) -> Void)? = nil
    /// The QUIET card (9 Oct): nothing is out, so this is the top of the queue or the next airing —
    /// shorter, its state as a quiet eyebrow instead of the badge; the stage is for drops.
    var quiet: Bool = false
    /// This page reports to the bar and the launch (`onCopyTop`, `onLightingChange`, `onArtLoaded`):
    /// the pager's current page only, so three pages do not take turns writing the chrome's one fact.
    var reportsChrome: Bool = true

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ShowBillboard(franchise: hero.franchise, height: height, band: band, tint: tint, landing: landing,
                      onOpen: onOpen, onArtLoaded: onArtLoaded, onCopyTop: onCopyTop, onArt: onArt,
                      onLightingChange: onLightingChange, reportsChrome: reportsChrome,
                      accessibilityLabel: "\(badge), \(hero.franchise.displayTitle), \(line)",
                      accessibilityHint: Copy.Accessibility.opensTheShowHint) { name, arrival in
            lockup(name: name, arrival: arrival)
        }
    }


    /// `name`: the show's logo on a clean picture; nothing where the picture's own title is in view
    /// (`.embedded` — at the accessibility sizes the name is always set in type).
    private func lockup(name: BillboardName, arrival: BillboardArrival) -> some View {
        let f = hero.franchise
        return VStack(spacing: ThemeSpace.x3) {
            // The words are the picture's, not controls: a tap on them is a tap on the billboard.
            VStack(spacing: ThemeSpace.x2) {
                if quiet {
                    // The quiet card states its moment in a label, not a tag: a tag is for news.
                    Text(badge)
                        .type(ThemeType.feedEyebrow)
                        .textCase(.uppercase)
                        .foregroundStyle(ThemeColor.textPrimary.opacity(0.72))
                        .lineLimit(2)
                        .shadow(.art)
                        .modifier(arrival.line(0))
                } else {
                    HeroBadge(text: badge)
                        .contentTransition(.numericText(countsDown: true))
                        .modifier(arrival.line(0))
                }
                if case .logo = name, name.hasGraphicLogo, !typeSize.isAccessibilitySize {
                    // The title card: a halo of its own light, resolving out of a blur.
                    ArtworkLogo(name: name, title: f.displayTitle, height: quiet ? 72 : 96, halo: 0.55)
                        .padding(.horizontal, ThemeSpace.x8)
                        .padding(.vertical, ThemeSpace.x1)
                        .modifier(arrival.logo)
                } else if name != .embedded || typeSize.isAccessibilitySize {
                    Text(f.displayTitle)
                        .type(ThemeType.displayXL)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
                        .minimumScaleFactor(0.82)
                        .shadow(.art)
                        .modifier(arrival.line(1))
                }
                Text(line)
                    .type(ThemeType.heroMeta)
                    .foregroundStyle(ThemeColor.textPrimary.opacity(0.88))
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .contentTransition(.numericText())
                    .shadow(.art)
                    .modifier(arrival.line(2))
                if let progress {
                    ProgressBar(value: progress, spoken: nil)
                        .frame(maxWidth: 200)
                        .padding(.top, ThemeSpace.x1)
                        .modifier(arrival.line(2))
                }
                if let drop = hero.drop {
                    Text(drop)
                        .type(ThemeType.feedSmall)
                        .foregroundStyle(ThemeColor.textPrimary.opacity(0.66))
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                        .shadow(.art)
                        .modifier(arrival.line(3))
                }
            }
            .multilineTextAlignment(.center)
            .allowsHitTesting(false)
            if hero.canMark {
                ScheduleMarkPill(watched: committing,
                                 label: committing ? Copy.Progress.episodeWatched(hero.episode)
                                                   : Copy.Action.markEpisodeWatched(hero.episode),
                                 action: onMark)
                    .animation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion), value: committing)
                    .background { MarkPulse(fired: committing, reduceMotion: reduceMotion) }
                    .disabled(committing)
                    .modifier(arrival.line(4))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// Where you are in the season — nothing on a season not started.
    private var progress: Double? {
        let part = hero.part
        let total = max(part.progressDenominator(now: now, anchor: hero.franchise.timeAnchor), part.progress)
        return total > 0 && part.progress > 0 ? Double(part.progress) / Double(total) : nil
    }

    /// The state, in the badge.
    var badge: String {
        let f = hero.franchise
        switch hero.kind {
        case .outNow(let behind):
            // BEHIND a broadcast that is still going; LEFT in a season that has finished — the old
            // Today's badge vocabulary ("4 EPISODES BEHIND", "13 EPISODES LEFT").
            guard behind > 1 else { return Copy.Home.newEpisode }
            return hero.part.isReleasing ? Copy.Progress.behind(behind) : Copy.Progress.left(behind)
        case .resume:
            // "Continue" over a show you have not begun read as the app forgetting you (the queue
            // carries unstarted Watching shows too): the Planned command's own two words. On the
            // quiet card the eyebrow names the place ("Up next"); the pill carries the verb.
            if quiet { return Copy.Home.upNext }
            return Copy.Today.startOrContinue(f)
        case .airing(let at):
            let delta = at - now
            if !f.timeAnchor.isDateOnly, delta >= 60 * Formatting.minuteMs,
               Formatting.dayDiff(ts: at, now: now, anchor: f.timeAnchor) == 0,
               Formatting.isEvening(hour: Formatting.localParts(at, anchor: f.timeAnchor).hour) {
                return Copy.Schedule.tonightAt(Formatting.fmtTime(at, anchor: f.timeAnchor))
            }
            return TemporalCopy.airs(at: at, now: now, source: f.source)
        }
    }

    /// "Season 4 · Episode 22" — the billboard stands alone, so it names the season.
    var line: String {
        hero.franchise.watchContext(part: hero.part, episode: hero.episode)
    }
}

// MARK: - The billboard's pages

/// Several drops this week: the billboard PAGES through them, newest first (Apple TV's Up Next hero
/// — 9 Oct, "the most recently aired franchise(s)", owner), one show a page, the dots at the foot.
/// Each page is the one billboard; only the page in front reports to the bar and the launch.
struct HomeBillboardPager: View {
    let heroes: [HomeHero]
    /// The page in front, by franchise id (`scrollPosition`).
    @Binding var page: String?
    let now: Int64
    let height: CGFloat
    let band: CGFloat
    /// The mark in flight is the front page's.
    var committing: Bool = false
    let tint: (HomeHero) -> Color?
    let landing: (HomeHero) -> Color
    let onOpen: (HomeHero) -> Void
    let onMark: (HomeHero) -> Void
    var onArtLoaded: (() -> Void)? = nil
    var onCopyTop: ((CGFloat) -> Void)? = nil
    var onArt: ((HomeHero, String?) -> Void)? = nil
    var onLightingChange: ((HomeLockupLighting) -> Void)? = nil

    @Environment(AppModel.self) private var appModel

    private var frontId: String { page ?? heroes.first?.franchise.id ?? "" }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(heroes) { hero in
                    let front = hero.franchise.id == frontId
                    HomeBillboard(hero: hero, now: now, height: height, band: band,
                                  committing: committing && front,
                                  tint: tint(hero), landing: landing(hero),
                                  onOpen: { onOpen(hero) },
                                  onMark: { onMark(hero) },
                                  onArtLoaded: onArtLoaded,
                                  onCopyTop: onCopyTop,
                                  onArt: { onArt?(hero, $0) },
                                  onLightingChange: onLightingChange,
                                  reportsChrome: front)
                        .franchiseQuickActions(appModel.isInLibrary(hero.franchise.id) ? hero.franchise : nil,
                                               appModel: appModel)
                        .containerRelativeFrame(.horizontal)
                        .id(hero.franchise.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        // A pull stretches a page's picture up past the frame, as the one billboard's does.
        .scrollClipDisabled()
        .frame(height: height)
        .overlay(alignment: .bottom) {
            HomePageDots(count: heroes.count, current: heroes.firstIndex { $0.franchise.id == frontId } ?? 0)
                .padding(.bottom, 7)
                .allowsHitTesting(false)
        }
    }
}

/// Apple TV's page dots: the page in front in ink, the rest at a third.
struct HomePageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(ThemeColor.textPrimary.opacity(index == current ? 0.92 : 0.36))
                    .frame(width: 5, height: 5)
            }
        }
        .animation(ThemeMotion.uiGentle, value: current)
        .accessibilityHidden(true)
    }
}

// MARK: - The page's ground

/// Measured once when the title lays out; scrolling does not change its geometry.
struct HomeLockupLighting: Equatable {
    var copyHeight: CGFloat = 220
    var visible = false

    var bottomInset: CGFloat { ThemeSpace.x5 + copyHeight * 0.55 }
}

/// Shared by the billboard and the bars' windows. Repeating only the base gradient omits this
/// light where it crosses the bar's edge and leaves a straight, darker band under the title.
struct HomeLockupGlow: View {
    let tint: Color?
    let lighting: HomeLockupLighting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 400

    var body: some View {
        EllipticalGradient(colors: [(HeroLight.glow(tint) ?? .clear).opacity(0.26), .clear],
                           center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
            .frame(width: ThemeMetrics.windowWidth * 1.5, height: Self.height)
            .blendMode(.plusLighter)
            .opacity(lighting.visible ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 1.2), value: lighting.visible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The page under the billboard in the show's hue (26 Sep, "maybe add subtle gradient too", owner):
/// the colour the billboard's scrim lands on, held for a breath, then easing to canvas over half a
/// screen — with one faint pool of the tint's light where the first section sits. The show page's
/// ground (`DetailTint`, the `medium` strength the owner settled on 24 Sep), shorter: Home is not
/// the show's page, so the hue is where the billboard is and gone by Up next. It scrolls with the
/// content, drawn once — no image, nothing per frame.
struct HomeGround: View {
    let tint: Color?
    let top: Color
    let billboard: CGFloat

    /// How far below the billboard the hue takes to reach the canvas.
    static let fade: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            top.frame(height: max(0, billboard))
            LinearGradient(stops: [.init(color: top, location: 0),
                                   .init(color: top, location: 0.18),
                                   .init(color: ThemeColor.canvas, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fade)
                .overlay {
                    // The pool is an ellipse wholly INSIDE the fade: nothing at the billboard's
                    // foot, nothing at the sides, its light where the first section sits. Centred
                    // near the top with a radius past the box, it began at full strength on the
                    // billboard's bottom edge — a line across the page under the mark ("the seam
                    // looks ugly", owner, 4 Oct).
                    EllipticalGradient(colors: [(tint ?? .clear).opacity(DetailTint.groundPool), .clear],
                                       center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                        .blendMode(.plusLighter)
                }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What the page is standing on: the canvas, or a show's hue under and below its billboard.
enum HomePageGround: Equatable {
    case canvas
    case show(tint: Color?, top: Color, billboard: CGFloat)
}

/// The tab bar's ground on Home: the page's own, under the icons — and leaving with them, slid
/// down by what the bar has gone (`AppTabBar` rides the same state).
struct HomeFootGround: View {
    let chrome: HomeChrome
    let ground: HomePageGround
    /// The tab bar's top edge at rest, in the window.
    let barTop: CGFloat

    var body: some View {
        let away = chrome.awayFraction * ThemeMetrics.tabBarVisualHeight
        HomeGroundWindow(chrome: chrome, ground: ground, top: barTop + away,
                         height: ThemeMetrics.tabBarVisualHeight)
            .offset(y: away)
    }
}

/// A bar's ground as a WINDOW onto the page's: the same `HomeGround`, drawn where the page draws
/// it, cut to the bar. The page's ground is a gradient with a pool of light in it, so no single
/// colour is flush with it for longer than a point of scroll — the tab bar was painted the hue's
/// top colour, sat a shade off the page behind it, and snapped to canvas when the header turned
/// solid (4 Oct). With `HomeHeaderGround`, the only reader of `HomeChrome.contentTop`: a scroll
/// frame re-runs this body and nothing else.
struct HomeGroundWindow: View {
    let chrome: HomeChrome
    let ground: HomePageGround
    /// The bar's own top edge, in the window.
    let top: CGFloat
    let height: CGFloat

    var body: some View {
        ThemeColor.canvas
            .frame(height: height)
            .overlay(alignment: .top) {
                if case .show(let tint, let colour, let billboard) = ground {
                    HomeGround(tint: tint, top: colour, billboard: billboard)
                        .frame(height: billboard + HomeGround.fade, alignment: .top)
                        .overlay(alignment: .top) {
                            HomeLockupGlow(tint: tint, lighting: chrome.lighting)
                                .offset(y: billboard - chrome.lighting.bottomInset - HomeLockupGlow.height / 2)
                        }
                        .offset(y: chrome.contentTop - top)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Up next

/// One show in the queue as the LIBRARY'S poster card (`ArtworkPoster`, 150 pt, 2:3 — the card For
/// you's tiles are too): the poster whole, where you are as a bar right under it (Netflix's
/// Continue Watching), the show and the episode, a NEW tag on a fresh drop, and the mark as the
/// card's corner control — a check on the poster's glass, as For you's add is a plus. Posters are
/// the art every show has, anime included; the 16:9 card this replaced composited a cover in a box
/// for most of the queue ("Up Next visuals feel utter trash", owner, 26 Sep).
struct HomeUpNextTile: View {
    let item: HomeQueueItem
    let now: Int64
    /// The mark is mid-flight: the disc fills and the check lands before the tile moves on.
    var committing: Bool = false
    let onOpen: () -> Void
    let onMark: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    /// The show's picture on Home (`PosterPick`: the best-looking poster it has, any season), else
    /// the season's own cover until the pick lands.
    private var pick: PosterPick.Choice? { PosterPick.shared.choice(for: item.franchise) }
    private var poster: String? { pick?.url ?? item.part.portraitArt ?? item.franchise.portraitArt }

    /// Where you are in the season — nothing on a season not started.
    private var ratio: Double? {
        let total = max(item.part.progressDenominator(now: now, anchor: item.franchise.timeAnchor), item.part.progress)
        return total > 0 && item.part.progress > 0 ? Double(item.part.progress) / Double(total) : nil
    }

    private var line: String { item.franchise.watchContext(part: item.part, episode: item.episode) }

    var body: some View {
        let f = item.franchise
        ArtworkPoster(url: poster, name: pick?.tileName(for: f) ?? .type, title: f.displayTitle, detailsInBand: true,
                      cornerMark: AnyView(
                        HomeMarkDisc(committing: committing,
                                     label: Copy.Action.markEpisodeWatched(item.episode), action: onMark)
                      ),
                      fixedAspect: 2.0 / 3.0, onOpen: onOpen,
                      openLabel: "\(f.displayTitle), \(line)") {
            VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                // The bar sits right under the picture, the full width of the card — never over
                // the art, where it would fight the poster's own lettering. A show not begun keeps
                // the bar's room, so every caption on the shelf shares one baseline.
                if let ratio {
                    ProgressBar(value: ratio, spoken: nil)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(height: 3)
                }
                PosterCaptionText(title: f.displayTitle.shelfShortened(fitting: 26), fact: line)
                    .contentTransition(.numericText())
            }
        }
        .overlay(alignment: .topLeading) {
            if item.fresh > 0 {
                HomeNewTag(text: Copy.Stories.ringTag(item.fresh))
                    .padding(ThemeSpace.x2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: ForYouShelves.tileWidth(typeSize))
    }
}

/// The mark on a poster's corner — For you's add disc, with a check: glass at rest; while the write
/// lands, the accent disc with the check drawn in `onAccent` (the owned mark), one pulse.
struct HomeMarkDisc: View {
    var committing: Bool = false
    let label: String
    let action: () -> Void

    @ScaledMetric(relativeTo: .caption) private var disc: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(committing ? ThemeColor.accent : ThemeColor.scrimStrong)
                Circle().strokeBorder(committing ? .clear : ThemeColor.posterEdge, lineWidth: FeedMetrics.hairline)
                AppGlyph(systemName: "checkmark")
                    .font(.system(size: disc * 0.46, weight: .bold))
                    .foregroundStyle(committing ? ThemeColor.onAccent : ThemeColor.textPrimary)
            }
            .frame(width: disc, height: disc)
            .scaleEffect(committing && !reduceMotion ? 1.12 : 1)
            .animation(ThemeMotion.pick(ThemeMotion.uiMilestone, reduceMotion: reduceMotion), value: committing)
            .frame(width: max(44, disc + 12), height: max(44, disc + 12))
            .contentShape(Circle())
        }
        .buttonStyle(OverArtPressStyle())
        .padding(-ThemeSpace.x1)
        .disabled(committing)
        .accessibilityLabel(label)
    }
}

/// The NEW tag on a fresh drop's art — the episode list's tag (`onAccent` on `accent`): amber is
/// STATE here, never an action.
struct HomeNewTag: View {
    let text: String

    var body: some View {
        Text(text)
            .type(ThemeType.feedEyebrow)
            .foregroundStyle(ThemeColor.onAccent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(ThemeGradient.accent, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}
