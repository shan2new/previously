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
    var hero: HomeHero?
    /// The past week's episodes you have not marked, newest first — the billboard's show aside.
    var recent: [HomeAiring] = []
    /// The rest of your queue: shows the billboard and Recently aired do not already carry.
    var queue: [HomeQueueItem] = []

    /// How many rows a list shows before its header's chevron takes over.
    static let listLimit = 5

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
        // The billboard is something you can WATCH before anything you can only wait for (26 Sep:
        // "it shows Mushoku Tensei as the Hero but it is upcoming, while I haven't watched Slime
        // that aired yesterday", owner — tonight's airing used to outrank the queue). In order: a
        // fresh drop on a show you are watching, newest first; else the newest episode out this
        // past week that you have not marked, whichever shelf its show sits on (Recently aired
        // lists paused and finished shows too); else the top of your queue; and only when nothing
        // at all is out, the next airing — today's, else the week's first.
        var hero: HomeHero?
        if let item = queue.first(where: { $0.fresh > 0 }) {
            hero = heroFor(item, now: now)
        } else if let item = recent.lazy.compactMap({ dropItem($0, now: now) }).first {
            hero = heroFor(item, now: now)
        } else if let item = queue.first {
            hero = heroFor(item, now: now)
        } else if let next = days.filter({ $0.id >= 0 && $0.id < 7 })
                    .lazy.flatMap({ d in d.entries.filter { !$0.aired } }).first {
            hero = HomeHero(franchise: next.franchise, part: next.part,
                            episode: next.episode, kind: .airing(at: next.at))
        }
        #if DEBUG
        // `-homeHero <franchiseId>` (DEBUG): photograph a given show on the billboard — its queue item,
        // else its next airing. It selects; it never fabricates.
        if let id = UserDefaults.standard.string(forKey: "homeHero"), let f = m.library.first(where: { $0.id == id }) {
            if let item = queue.first(where: { $0.id == id }) {
                hero = heroFor(item, now: now)
            } else if let part = f.resumePart {
                hero = heroFor(HomeQueueItem(franchise: f, part: part, fresh: freshCount(f, part: part, now: now)), now: now)
            } else if let next = days.lazy.flatMap(\.entries).first(where: { $0.franchise.id == id && !$0.aired }) {
                hero = HomeHero(franchise: f, part: next.part, episode: next.episode, kind: .airing(at: next.at))
            }
        }
        #endif
        out.hero = hero

        // Each show once, in the first place that carries it: the billboard, then Recently aired,
        // then Up next. What airs next is the Schedule tab's (26 Sep: the calendar is a tab again).
        let heroShow = hero?.franchise.id
        out.recent = Array(recent.filter { $0.entry.franchise.id != heroShow }.prefix(HomeFeed.listLimit))
        let recentShows = Set(out.recent.map(\.entry.franchise.id))
        out.queue = queue.filter { $0.id != heroShow && !recentShows.contains($0.id) }
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
/// best-looking POSTER (`PosterPick`) composited whole in a frame that is nearly its own shape,
/// breathing (`ArtHeader(drift:)`) and stretching with a pull, the bar's veil over its top and a
/// scrim sized to the copy that lands on canvas; then, centred, the state in its badge, the show's
/// logo else its name, the episode, where you are, the drop, and the mark.
///
/// GLOW (26 Sep: "utterly delightful and an eye candy without going overboard", then "Glow is sick",
/// owner — `HomeHeroScene.swift`): light and depth, nothing added to the page. The arrival plays as
/// the launch's curtain lifts (never under it): the picture settles into focus, the logo resolves
/// out of a blur with a halo of its own light, the words rise beneath it. The picture moves at a
/// little under half the page's speed and leans with the phone (`HeroTilt`); the lockup sits in a
/// pool of the poster's colour. Everything still is Reduce Motion's.
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

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The launch in progress: the arrival plays as its curtain lifts, not under it.
    @Environment(LaunchHandoff.self) private var launch: LaunchHandoff?
    @State private var lightness: Double?
    @State private var copyHeight: CGFloat = 220
    /// The lockup has arrived (once per billboard): the words rise in over the art, a beat apart.
    @State private var arrived = false

    /// The splash has begun to lift (always, after a launch).
    private var curtainUp: Bool { launch?.emerging ?? true }
    /// The picture and the name this billboard settled on (`settle`) — never changed under the
    /// reader afterwards.
    @State private var settled: Shown?
    /// The picture is on screen; then the logo has resolved (the arrival, `stage`).
    @State private var artIn = false
    @State private var logoIn = false

    struct Shown: Equatable {
        let art: WideArt
        let name: BillboardName
    }

    /// How long the billboard waits for the show's pick (`PosterPick`, graded on first sight) before
    /// it takes the catalogue's own picture. A pick is kept for good, so this is a first visit's wait.
    private static let pickPatience: Duration = .milliseconds(2000)

    private var lighting: HomeLockupLighting {
        HomeLockupLighting(copyHeight: copyHeight, visible: artIn && curtainUp)
    }

    /// A pick made before this billboard existed — on its first frame.
    private var storedPick: Shown? { PosterPick.shared.choice(for: hero.franchise).map(shown(from:)) }

    private func shown(from pick: PosterPick.Choice) -> Shown {
        Shown(art: WideArt.billboard(portrait: pick.url, landscape: nil), name: pick.billboardName(for: hero.franchise))
    }

    /// The show's best-looking poster, any season ("choose the best-looking poster, even if it is
    /// from an earlier season", owner, 26 Sep), when it is known or becomes known within
    /// `pickPatience`; else the catalogue's selection. Once.
    private func settle() async {
        let f = hero.franchise
        if settled == nil, !PosterPick.candidates(for: f).isEmpty {
            let deadline = ContinuousClock.now + Self.pickPatience
            while PosterPick.shared.choice(for: f) == nil, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard !Task.isCancelled, settled == nil else { return }
        let pick = PosterPick.shared.choice(for: f)
        let next = pick.map(shown(from:)) ?? Shown(art: f.billboardArt, name: f.billboardName)
        PerfProbe.mark("billboard-settled", pick == nil ? "catalogue" : "pick")
        settled = next
        onArt?(next.art.url)
    }

    /// The picture is on screen (the launch waits for this). Its arrival — into focus, then the
    /// logo, then the words — plays once the curtain is up (`stage`).
    private func artLoaded() {
        onArtLoaded?()
        if !artIn { artIn = true }
    }

    /// The arrival, once the picture is here AND the splash is lifting: the picture settles into
    /// focus now, the words rise from a beat later, the logo resolves among them.
    private func stage() async {
        guard artIn, curtainUp, !arrived else { return }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 120))
        // The title card first — the logo resolves as the badge lands — then the words beneath.
        logoIn = true
        arrived = true
    }

    var body: some View {
        // Nothing but the ground until the picture is settled: never one poster, then another.
        let shown = settled ?? storedPick
        let art = shown?.art ?? WideArt(landscape: nil, portrait: nil)
        let name = shown?.name ?? hero.franchise.billboardName
        let strength = HeroProtection.strength(lightness: lightness)
        let h = height
        let still = reduceMotion
        ZStack(alignment: .bottom) {
            Button(action: onOpen) {
                ArtHeader(url: art.url, height: h, tint: tint, scrimTop: 0, scrimBottom: 0,
                          focus: .top, portraitSource: art.portraitSource, portraitFill: true, drift: true,
                          ultraWide: art.ultraWide, onArtLoaded: artLoaded,
                          // A poster's own logotype is INK a veil cannot remove: a name set in
                          // type starts its poster under the bar (the old Today's rule).
                          topInset: name == .type ? band : 0,
                          groundDim: HeroProtection.groundDim(strength)) { EmptyView() }
                    // The picture arrives into focus, and leans with the phone — a hair larger than
                    // its frame, so a lean never shows an edge.
                    .modifier(FocusSettle(settled: artIn && curtainUp, reduceMotion: reduceMotion))
                    .scaleEffect(still ? 1 : 1.035, anchor: .center)
                    .modifier(TiltShift(amount: still ? 0 : 6))
            }
            .buttonStyle(.plain)
            // A pull stretches the picture up into the space it opens, from its foot; scrolling
            // on, it moves at a little under half the page's speed — depth, read from geometry in
            // the render pass (`visualEffect`), so neither ever re-runs a body.
            .visualEffect { content, proxy in
                let y = proxy.frame(in: .scrollView).minY
                let pull = max(0, y)
                let push = still ? 0 : min(max(0, -y), h) * 0.42
                return content
                    .scaleEffect(1 + pull / max(h, 1), anchor: .bottom)
                    .offset(y: push)
            }
            // Nothing of the PICTURE below the frame — it leans and moves with the scroll inside
            // it — while a pull may still stretch it up past the top. The picture alone: the
            // lockup's light is not cut here (below).
            .clipShape(BelowClip())
            .accessibilityLabel("\(badge), \(hero.franchise.displayTitle), \(line)")
            .accessibilityHint(Copy.Accessibility.opensTheShowHint)

            HeroCopyScrim(copyHeight: copyHeight, strength: strength, landing: landing)
                // The lockup sits in a pool of the poster's own light, not on a dead ground. An
                // ellipse that is spent at its own rim, centred on the lockup and free to run past
                // the billboard's foot onto the page (an overlay, so its size is not the
                // billboard's): as a circle wider than its frame, cut again by the billboard, it
                // ended on two straight lines under the mark ("the seam looks ugly", owner, 4 Oct).
                .overlay(alignment: .bottom) {
                    HomeLockupGlow(tint: tint, lighting: lighting)
                        .offset(y: HomeLockupGlow.height / 2 - lighting.bottomInset)
                }

            lockup(name: name)
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.bottom, ThemeSpace.x5)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { copyHeight = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { onCopyTop?($0) }
        }
        .frame(height: h)
        .frame(maxWidth: .infinity)
        .onAppear { if !reduceMotion { HeroTilt.shared.start() } }
        .onDisappear { if !reduceMotion { HeroTilt.shared.stop() } }
        .task(id: art.url) {
            guard art.url != nil else { return }
            _ = await PaletteCache.shared.resolve(url: art.url, maxPixel: 360)
            lightness = PaletteCache.shared.lightness(for: art.url)
        }
        .task(id: hero.franchise.id) { await settle() }
        .task {
            // The arrival is staged on the picture and the curtain (`stage`); this is the net for a
            // billboard whose picture never comes. Under Reduce Motion the words are simply there.
            guard !arrived else { return }
            if reduceMotion {
                arrived = true
                logoIn = true
                return
            }
            try? await Task.sleep(for: .milliseconds(3000))
            if !arrived { arrived = true; logoIn = true }
        }
        .task(id: artIn && curtainUp) { await stage() }
        .onChange(of: lighting, initial: true) { _, next in onLightingChange?(next) }
    }

    /// One line of the lockup rising in, `index` beats after the first (Apple TV's billboard copy).
    private func arrival(_ index: Int) -> some ViewModifier {
        HomeArrival(shown: arrived, delay: Double(index) * 0.07, reduceMotion: reduceMotion)
    }

    /// `name`: the show's logo on a clean picture; nothing where the picture's own title is in view
    /// (`.embedded` — at the accessibility sizes the name is always set in type).
    private func lockup(name: BillboardName) -> some View {
        let f = hero.franchise
        return VStack(spacing: ThemeSpace.x3) {
            // The words are the picture's, not controls: a tap on them is a tap on the billboard.
            VStack(spacing: ThemeSpace.x2) {
                HeroBadge(text: badge)
                    .contentTransition(.numericText(countsDown: true))
                    .modifier(arrival(0))
                if case .logo = name, name.hasGraphicLogo, !typeSize.isAccessibilitySize {
                    // The title card: a halo of its own light, resolving out of a blur.
                    ArtworkLogo(name: name, title: f.displayTitle, height: 96, halo: 0.55)
                        .padding(.horizontal, ThemeSpace.x8)
                        .padding(.vertical, ThemeSpace.x1)
                        .modifier(LogoResolve(shown: logoIn, reduceMotion: reduceMotion))
                } else if name != .embedded || typeSize.isAccessibilitySize {
                    Text(f.displayTitle)
                        .type(ThemeType.displayXL)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
                        .minimumScaleFactor(0.82)
                        .shadow(.art)
                        .modifier(arrival(1))
                }
                Text(line)
                    .type(ThemeType.heroMeta)
                    .foregroundStyle(ThemeColor.textPrimary.opacity(0.88))
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .contentTransition(.numericText())
                    .shadow(.art)
                    .modifier(arrival(2))
                if let progress {
                    ProgressBar(value: progress, spoken: nil)
                        .frame(maxWidth: 200)
                        .padding(.top, ThemeSpace.x1)
                        .modifier(arrival(2))
                }
                if let drop = hero.drop {
                    Text(drop)
                        .type(ThemeType.feedSmall)
                        .foregroundStyle(ThemeColor.textPrimary.opacity(0.66))
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                        .shadow(.art)
                        .modifier(arrival(3))
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
                    .modifier(arrival(4))
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
            // carries unstarted Watching shows too): the Planned command's own two words.
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

/// A line of the billboard's copy arriving: 10 pt below and clear, then in place — on one gentle
/// curve, `delay` after the first. Under Reduce Motion it is simply there.
private struct HomeArrival: ViewModifier {
    let shown: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .animation(reduceMotion ? nil : ThemeMotion.uiGentle.delay(delay), value: shown)
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

