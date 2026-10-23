import SwiftUI
import UserNotifications

// One show's story at one frame — INSTAGRAM'S story, not an app screen laid over a poster (rebuilt
// 25 Sep: "The Story experience is utterly trashy!", owner). What that meant, measured against the
// app: the frame zoomed a 460-px AniList cover 1.34× (a banner 1.9×) to fill the glass, so every
// picture was soft; and over it sat a NEW EPISODE badge, a 34-pt title, a full-width amber capsule,
// a lock sentence and a "Show page" hint — five pieces of chrome where Instagram draws none.
//
// Instagram's anatomy, which this now is:
//   · a CARD under the status bar, 9:16 of the width, rounded — the picture WHOLE on a wash of its
//     own colour (`StoryArt`), never zoomed past its pixels;
//   · the segments and the header ride the card's top;
//   · at the card's foot, one caption (the episode, when it aired) and ONE sticker: "Mark as
//     watched" (the link sticker's white tag) until you have, then the emoji slider; for the next
//     episode, the countdown sticker with its reminder;
//   · under the card, on black, the reply row: the field (the episode's discussion), the heart, the
//     send.
//
// The mark here is a REAL progress write. Every decision reads the LIVE part
// (`appModel.franchise(id:)`), never the reel's snapshot: a frame's episode is watched iff
// `part.progress >= episode`, a derived fact with no local key. The unlock — the gels spark from
// behind the sticker, the tag answers "✓ Watched", the slider takes its place — plays on the
// model's change, so a mark made anywhere (the discussion sheet, an Undo) moves this page the same
// way.

// MARK: - Tokens

/// The story viewer's own tokens: a full-screen photo surface with its own over-art ink, scrims
/// and physics. The motion is the round-4 spike's, measured against Instagram's; everything here
/// collapses to `ThemeMotion.uiReduced` (a fade or a cut) under Reduce Motion at the call site.
enum StoryStyle {
    // Ink over the picture.
    static let ink = ThemeColor.textPrimary
    static let inkSecondary = ThemeColor.textPrimary.opacity(0.8)
    static let inkQuiet = ThemeColor.textPrimary.opacity(0.7)
    static let inkFaint = ThemeColor.textPrimary.opacity(0.6)

    // Grounds and scrims (the canvas is the app's black).
    static let artGround = ThemeColor.canvas
    static let backdrop = Color.black
    static let edgeDarken = ThemeColor.canvas
    static let topScrim = Color.black.opacity(0.42)
    static let bottomScrimMid = Color.black.opacity(0.25)
    static let bottomScrimFoot = Color.black.opacity(0.62)
    static let topScrimHeight: CGFloat = 120
    static let bottomScrimShare: CGFloat = 0.42
    static let cubeShade = ThemeColor.canvas
    static let cubeShadeMax: Double = 0.5

    // The card (Instagram's, measured on a 393-pt phone: 9:16 of the width, a ~10-pt corner).
    /// Width ÷ height.
    static let cardAspect: CGFloat = 9.0 / 16.0
    static let cardRadius: CGFloat = 10

    // The segments (Instagram's: 2 pt, a 3-pt gap, 8 pt in from the card's edges).
    static let segmentTrack = ThemeColor.textPrimary.opacity(0.32)
    static let segmentFill = ThemeColor.textPrimary
    static let segmentHeight: CGFloat = 2
    static let segmentGap: CGFloat = 3
    static let segmentTop: CGFloat = 8

    // Layout. The type is the app's, by role (`Typeface`): Outfit for the caption's title, the
    // sticker's label and the countdown; the content face for the rest.
    static let pageInset: CGFloat = 8
    static let lockupInset: CGFloat = ThemeSpace.x2
    static let headerTop: CGFloat = 6
    static let headerAvatar: CGFloat = 32
    static let headerName = TypeToken(.title, .semibold, 15, .subheadline, tracking: -0.10)
    static let headerMeta = TypeToken(.text, .regular, 15, .subheadline, tracking: -0.05)
    /// The caption at the card's foot: the episode, then when.
    static let captionTitle = TypeToken(.display, .semibold, 24, .title2, tracking: -0.35)
    static let captionMeta = TypeToken(.text, .medium, 15, .subheadline, tracking: -0.05)
    static let captionShadow = ShadowToken(color: .black.opacity(0.45), radius: 10, y: 1)
    static let captionInset: CGFloat = 16
    static let captionBottom: CGFloat = 20
    /// Sticker → caption.
    static let stickerGap: CGFloat = 18
    static let slotMinHeight: CGFloat = 76
    static let stickerMaxWidth: CGFloat = 300
    static let stickerSideRoom: CGFloat = 72
    /// Instagram's link sticker: a white tag, 44 tall, a 12-pt corner.
    static let tagHeight: CGFloat = 44
    static let tagRadius: CGFloat = 12
    static let tagLabel = TypeToken(.display, .semibold, 16, .callout, tracking: -0.15)
    static let tagShadow = ShadowToken(color: .black.opacity(0.28), radius: 14, y: 4)
    /// The countdown sticker.
    static let countdownRadius: CGFloat = 18
    static let countdownDigits = TypeToken(.display, .bold, 34, .largeTitle, tracking: -0.60, monospacedDigits: true)
    static let countdownTitle = TypeToken(.text, .semibold, 13, .footnote, tracking: 0.6)
    // The reply row under the card.
    static let replyRowHeight: CGFloat = 44
    static let replyRowPadding: CGFloat = ThemeSpace.x2
    static let replyStroke = ThemeColor.textPrimary.opacity(0.55)
    static let replyGround = Color.clear
    static let heartGlyph: CGFloat = 25

    // The picture (Instagram's fit-on-gradient; see `StoryArt`).
    static let titledZoom: CGFloat = 1.34
    static let landscapeZoom: CGFloat = 1.9
    static let landscapeBand: CGFloat = 0.62
    static let landscapeFall: CGFloat = 0.16
    static let landscapeFadeStart: CGFloat = 0.7
    static let landscapeBlur: CGFloat = 0.1
    static let landscapeGroundDim: Double = 0.3
    static let landscapeTintPixels: CGFloat = 320
    static let portraitPixelCap: CGFloat = 2560
    static let landscapePixelCap: CGFloat = 1600
    static let driftScale: CGFloat = 1.07
    static let drift = Animation.easeInOut(duration: 14).repeatForever(autoreverses: true)

    // Motion (the round-4 physics).
    static let open = Animation.spring(response: 0.44, dampingFraction: 0.88)
    static let openFade = Animation.easeOut(duration: 0.22)
    static let closeToRing = Animation.spring(response: 0.36, dampingFraction: 0.92)
    static let closeFade = Animation.easeIn(duration: 0.18)
    static let cubeTurn = Animation.spring(response: 0.42, dampingFraction: 0.92)
    static let cubeReturn = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let pullReturn = Animation.spring(response: 0.36, dampingFraction: 0.8)
    static let liftReturn = Animation.snappy
    static let holdIn = Animation.easeOut(duration: 0.16)
    static let holdOut = Animation.easeOut(duration: 0.18)
    static let frameFade = Animation.easeOut(duration: 0.16)
    static let unlockIn = Animation.snappy(duration: 0.24)
    static let unlockHold: Duration = .milliseconds(560)
    static let unlockHoldReduced: Duration = .milliseconds(60)
    static let sparkReachX: CGFloat = 200
    static let sparkReachY: CGFloat = 70
}

/// Where the card sits on the screen: under the status band, 9:16 of the width, with the reply
/// row's band left under it; a short phone gives the card what is left.
enum StoryCard {
    static func frame(in size: CGSize, insets: EdgeInsets) -> CGRect {
        let row = StoryStyle.replyRowHeight + 2 * StoryStyle.replyRowPadding + insets.bottom
        let natural = size.width / StoryStyle.cardAspect
        let height = max(0, min(natural, size.height - insets.top - row))
        return CGRect(x: 0, y: insets.top, width: size.width, height: height)
    }
}

/// The viewer's gesture physics (Instagram's, measured in the spike).
enum StoryPhysics {
    /// A drag commits to an axis past this distance.
    static let axisSlop: CGFloat = 12
    /// Past the first and last show the cube pushes back.
    static let edgeResistance: CGFloat = 0.18
    /// A turn commits past this share of the width, or this share predicted.
    static let turnShare: CGFloat = 0.28
    static let turnPredictedShare: CGFloat = 0.6
    /// A pull-down closes past these.
    static let closePull: CGFloat = 120
    static let closePredicted: CGFloat = 320
    /// A lift opens the show page past these (negative: up).
    static let liftMax: CGFloat = 140
    static let openLift: CGFloat = -70
    static let openLiftPredicted: CGFloat = -220
    /// How the page follows a lift, and the hint under it.
    static let liftParallax: CGFloat = 0.35
    static let liftHintFollow: CGFloat = 0.12
    static let liftHintReach: CGFloat = 70
    static let liftHintScale: CGFloat = 500
    static let liftHintMaxScale: CGFloat = 0.15
    /// The pull's shrink, rounding and follow.
    static let pullMaxShrink: CGFloat = 0.32
    static let pullShrinkDistance: CGFloat = 900
    static let pullMaxCorner: CGFloat = 34
    static let pullCornerRate: CGFloat = 3.2
    static let pullFollowX: CGFloat = 0.55
    static let pullFollowY: CGFloat = 0.9
    static let pullBackdropFade: CGFloat = 420
    static let pullBackdropMaxFade: CGFloat = 0.75
    /// A tap in the leading third goes back; anywhere else forward.
    static let backShare: CGFloat = 1.0 / 3.0
    /// The cube's hinge.
    static let cubePerspective: CGFloat = 0.42
    /// A capture's frozen clock holds the frame this far through.
    static let frozenFraction: Double = 0.38
}

/// Why a page asks the viewer's clock to hold.
enum StoryHold: Hashable {
    case confirming     // the batch mark's exact-count alert
    case rating         // a finger on the rating sticker
    case prompt         // the system's notification prompt
    case menu           // the ··· dialog
}

/// What a page can ask of the viewer.
struct StoryPageActions {
    var next: () -> Void
    var previous: () -> Void
    var nextShow: (() -> Void)?
    var previousShow: (() -> Void)?
    var close: () -> Void
    var openShow: () -> Void
    var mute: () -> Void
    var discuss: (_ episode: Int) -> Void
    var hold: (_ reason: StoryHold, _ on: Bool) -> Void
    /// The frame starts over — after a mark lands, the reader gets a whole frame with the room.
    var restart: () -> Void
}

// MARK: - The page

struct StoryPage: View, @MainActor Equatable {
    let reel: StoryReel
    let frame: Int
    /// The viewer's clock on the ACTIVE page only; a neighbour turning in has none.
    let clock: StoryClock?
    let insets: EdgeInsets
    let chromeHidden: Bool
    let active: Bool
    let lift: CGFloat
    let actions: StoryPageActions

    /// Closures are not compared: they reach the viewer's state through its `@State` storage, so an
    /// older copy calls the same thing. A cube drag re-runs the viewer every touch move; with this,
    /// no page body runs for it.
    static func == (a: StoryPage, b: StoryPage) -> Bool {
        a.reel == b.reel && a.frame == b.frame && a.clock === b.clock && a.insets == b.insets
            && a.chromeHidden == b.chromeHidden && a.active == b.active && a.lift == b.lift
    }

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var menuOpen = false

    private var current: StoryFrame { reel.frames[min(max(0, frame), max(0, reel.frames.count - 1))] }

    var body: some View {
        let f = current
        GeometryReader { geo in
            let card = StoryCard.frame(in: geo.size, insets: insets)
            let shape = RoundedRectangle(cornerRadius: StoryStyle.cardRadius, style: .continuous)
            ZStack(alignment: .topLeading) {
                StoryStyle.backdrop
                // The card: the picture, its two scrims, the segments and header, the frame.
                ZStack(alignment: .top) {
                    StoryArt(art: f.art)
                        .frame(width: card.width, height: card.height)
                        .id(f.id)
                        .transition(.opacity)
                    scrims(card.size)
                        .opacity(chromeHidden ? 0 : 1)
                        .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 0) {
                        StorySegmentBar(count: reel.frames.count, current: frame, clock: active ? clock : nil)
                            .padding(.top, StoryStyle.segmentTop)
                        header(f)
                            .padding(.top, StoryStyle.headerTop)
                        StoryCardContent(reel: reel, frame: f, active: active, cardWidth: card.width,
                                         actions: actions)
                            .id(f.id)
                    }
                    .padding(.horizontal, StoryStyle.pageInset)
                    .opacity(chromeHidden ? 0 : 1)
                }
                .frame(width: card.width, height: card.height)
                .clipShape(shape)
                .offset(y: card.minY)

                // Under the card, on black: Instagram's reply row.
                StoryReplyRow(reel: reel, frame: f, actions: actions)
                    .padding(.horizontal, StoryStyle.pageInset + ThemeSpace.x1)
                    .frame(width: card.width, height: StoryStyle.replyRowHeight)
                    .offset(y: card.maxY + StoryStyle.replyRowPadding)
                    .opacity(chromeHidden ? 0 : 1)
            }
            .offset(y: lift * StoryPhysics.liftParallax)
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog(reel.showTitle, isPresented: $menuOpen, titleVisibility: .hidden) {
            Button(Copy.Feed.goTo(reel.showTitle)) { actions.openShow() }
            Button(Copy.Feed.mute(reel.showTitle)) { actions.mute() }
            Button(Copy.Confirm.cancel, role: .cancel) {}
        }
        .onChange(of: menuOpen) { _, open in actions.hold(.menu, open) }
    }

    // MARK: Scrims

    /// A short shade under the header and a soft one under the caption — the picture stays the
    /// picture between them.
    private func scrims(_ size: CGSize) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [StoryStyle.topScrim, StoryStyle.topScrim.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: StoryStyle.topScrimHeight)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(stops: [
                    .init(color: StoryStyle.bottomScrimMid.opacity(0), location: 0),
                    .init(color: StoryStyle.bottomScrimMid, location: 0.45),
                    .init(color: StoryStyle.bottomScrimFoot, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: size.height * StoryStyle.bottomScrimShare)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    // MARK: Header

    private func header(_ f: StoryFrame) -> some View {
        HStack(spacing: ThemeSpace.x2) {
            Button(action: actions.openShow) {
                HStack(spacing: ThemeSpace.x2) {
                    FeedAvatar(candidates: reel.avatarCandidates, size: StoryStyle.headerAvatar)
                    Text(reel.showTitle)
                        .type(StoryStyle.headerName)
                        .foregroundStyle(StoryStyle.ink)
                        .lineLimit(1)
                    let stamp = headerStamp(f)
                    if !stamp.isEmpty {
                        Text(stamp)
                            .type(StoryStyle.headerMeta)
                            .foregroundStyle(StoryStyle.inkQuiet)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .frame(minHeight: FeedMetrics.actionHitHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Feed.goTo(reel.showTitle))
            Spacer(minLength: 0)
            Button { menuOpen = true } label: {
                AppGlyph(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(StoryStyle.ink)
                    .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FeedIconPressStyle())
            .accessibilityLabel(Copy.Feed.more)
            Button(action: actions.close) {
                AppGlyph(systemName: "xmark")
                    .font(.title3)
                    .foregroundStyle(StoryStyle.ink)
                    .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FeedIconPressStyle())
            .accessibilityLabel(Copy.Stories.close)
        }
        .padding(.leading, ThemeSpace.x1)
    }

    /// Instagram's grey stamp beside the name: how long ago the episode dropped.
    private func headerStamp(_ f: StoryFrame) -> String {
        guard f.kind == .episode, let at = f.at else { return "" }
        return TemporalCopy.feedStamp(at, dateOnly: reel.anchor.isDateOnly, now: appModel.nowMinute)
    }

    // MARK: Spoken form (§5.5)

    /// The badge a frame's VoiceOver value leads with: the newest aired frame of a reel with
    /// something unseen is NEWS; the upcoming frame is a state. (No longer drawn — Instagram's frame
    /// wears no badge; the tray's ring says what is new.)
    static func badge(reel: StoryReel, frame f: StoryFrame) -> String? {
        switch f.kind {
        case .next:
            return f.isFinale ? Copy.Stories.badgeFinaleNext : Copy.Stories.badgeNextEpisode
        case .episode:
            let latest = reel.frames.last { $0.kind == .episode }?.episode
            if f.episode == latest, !reel.seen {
                return f.isFinale ? Copy.Stories.badgeNewFinale : Copy.Stories.badgeNewEpisode
            }
            return nil
        }
    }

    /// The line under the episode: "Season 4 · Aired 2h ago" · "Season 4 · Airs Friday at 7:30 PM ·
    /// in 2d 4h". A date-only (TMDB) slot has no clock to count down to, so it states the day.
    static func meta(reel: StoryReel, frame f: StoryFrame, now: Int64) -> String {
        switch f.kind {
        case .episode:
            guard let at = f.at else { return Copy.Stories.meta(season: reel.partLabel, moment: Copy.Stories.outNow) }
            return Copy.Stories.meta(season: reel.partLabel,
                                     moment: TemporalCopy.aired(at: at, now: now, anchor: reel.anchor))
        case .next:
            guard let at = f.at else { return Copy.Stories.meta(season: reel.partLabel, moment: "") }
            let airs = TemporalCopy.airsSentence(at: at, now: now, anchor: reel.anchor)
            // "Airs in 27 min" already counts down; a date-only slot has no clock to count to.
            let counts = !reel.anchor.isDateOnly && at - now >= 60 * Formatting.minuteMs
            let moment = counts
                ? Copy.Stories.airsCountdown(airs, wait: Formatting.fmtCountdown(target: at, now: now, anchor: reel.anchor))
                : airs
            return Copy.Stories.meta(season: reel.partLabel, moment: moment)
        }
    }

    /// The caption's second line: the moment alone for an aired episode ("Season 4 · Aired
    /// Wednesday"); the airing sentence, without the countdown the sticker already shows, for the
    /// next one.
    static func captionMeta(reel: StoryReel, frame f: StoryFrame, now: Int64) -> String {
        switch f.kind {
        case .episode:
            return meta(reel: reel, frame: f, now: now)
        case .next:
            guard let at = f.at else { return Copy.Stories.meta(season: reel.partLabel, moment: "") }
            return Copy.Stories.meta(season: reel.partLabel,
                                     moment: TemporalCopy.airsSentence(at: at, now: now, anchor: reel.anchor))
        }
    }

    /// What VoiceOver says for a frame after the show's name: "New episode, Episode 5, Season 4 ·
    /// Aired 2h ago".
    static func spoken(reel: StoryReel, frame f: StoryFrame, now: Int64) -> String {
        Copy.Stories.pageValue(badge: badge(reel: reel, frame: f), episode: f.episode,
                               meta: meta(reel: reel, frame: f, now: now))
    }
}

// MARK: - The card's foot: one sticker, one caption

/// Everything at the card's foot for ONE frame — keyed by the frame's id, so its unlock, its alert
/// state and its pending receipt never leak into the next frame of the same reel.
private struct StoryCardContent: View {
    let reel: StoryReel
    let frame: StoryFrame
    let active: Bool
    let cardWidth: CGFloat
    let actions: StoryPageActions

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    /// The tag has been pressed (or the part moved past this episode elsewhere): the tag answers,
    /// the gels spark, and the slider waits a beat before it takes the tag's place.
    @State private var unlocking = false
    @State private var unlockTask: Task<Void, Never>?
    @State private var sparks = 0
    /// The mark's receipt, presented when the slider has landed (the app's rule: a single mark's
    /// Undo arrives when its handoff settles).
    @State private var pendingReceipt: UndoState?
    @State private var batch: BatchMark?
    @State private var alertStatus: UNAuthorizationStatus?

    private struct BatchMark: Equatable {
        let from: Int
        let episode: Int
        let season: String
        var count: Int { episode - from }
    }

    private var e: Int { frame.episode }
    private var host: String { ReceiptHost.story(reel.mediaId, e) }
    /// The band the sticker reserves under itself for the mark's receipt: the line and its gap.
    private var receiptBand: CGFloat { ReceiptLine.height + ThemeSpace.x2 }

    /// The LIVE part — never the reel's snapshot.
    private var livePart: FranchisePart? {
        appModel.franchise(id: reel.franchiseId)?.parts.first { $0.mediaId == reel.mediaId }
    }

    private var watched: Bool {
        guard frame.kind == .episode, let part = livePart else { return false }
        return part.progress >= e
    }

    var body: some View {
        let isWatched = watched
        let rated = isWatched && !unlocking
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: ThemeSpace.x4)
            sticker(rated: rated)
                .frame(maxWidth: .infinity)
                .padding(.bottom, StoryStyle.stickerGap)
            caption
        }
        .padding(.horizontal, StoryStyle.captionInset - StoryStyle.pageInset)
        .padding(.bottom, StoryStyle.captionBottom)
        .onChange(of: isWatched) { was, now in
            if now, !was {
                // A mark from anywhere (this tag, the discussion sheet) plays the unlock.
                if !unlocking { runUnlock() }
            } else if !now {
                // An Undo: the tag comes back at once.
                unlockTask?.cancel()
                unlockTask = nil
                unlocking = false
            }
        }
        .onDisappear {
            unlockTask?.cancel()
            unlockTask = nil
            flushReceipt()
            if batch != nil { batch = nil; actions.hold(.confirming, false) }
        }
        .alert(Copy.Confirm.batchMarkTitle(batch?.count ?? 1),
               isPresented: Binding(get: { batch != nil }, set: { if !$0 { batch = nil } }),
               presenting: batch) { b in
            Button(Copy.Confirm.batchMarkConfirm(b.count)) { commitBatch(b) }
            Button(Copy.Confirm.cancel, role: .cancel) {}
        } message: { b in
            Text(Copy.Confirm.batchMarkMessage(title: reel.showTitle, season: b.season, from: b.from, to: b.episode))
        }
        .onChange(of: batch == nil) { _, none in if none { actions.hold(.confirming, false) } }
    }

    // MARK: Caption

    /// Instagram's text on a story: the episode in bold white, when it aired under it, a soft shadow
    /// for the picture it sits on. The page's ONE VoiceOver element (§5.5): the show, then the
    /// frame, with the viewer's moves and the mark as named actions and the frame as the adjustable
    /// value.
    private var caption: some View {
        let now = appModel.nowMinute
        return VStack(alignment: .leading, spacing: ThemeSpace.x0_5) {
            Text(Copy.episode(e))
                .type(StoryStyle.captionTitle)
                .foregroundStyle(StoryStyle.ink)
            Text(StoryPage.captionMeta(reel: reel, frame: frame, now: now))
                .type(StoryStyle.captionMeta)
                .foregroundStyle(StoryStyle.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .shadow(StoryStyle.captionShadow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reel.showTitle)
        .accessibilityValue(StoryPage.spoken(reel: reel, frame: frame, now: now))
        // A double-tap is the story's tap forward, said explicitly rather than synthesised at the
        // element's centre.
        .accessibilityAction { actions.next() }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: actions.next()
            case .decrement: actions.previous()
            @unknown default: break
            }
        }
        .modifier(StoryNamedActions(actions: actions, markLabel: markActionLabel, onMark: mark))
        .accessibilitySortPriority(2)
    }

    private var markActionLabel: String? {
        guard frame.kind == .episode, !watched, let part = livePart else { return nil }
        return markLabel(part)
    }

    // MARK: The sticker

    @ViewBuilder
    private func sticker(rated: Bool) -> some View {
        switch frame.kind {
        case .episode:
            ZStack(alignment: .bottom) {
                if rated {
                    EpisodeRatingSlider(mediaId: reel.mediaId, episode: e,
                                        onInteracting: { actions.hold(.rating, $0) })
                        .frame(maxWidth: min(StoryStyle.stickerMaxWidth, max(0, cardWidth - StoryStyle.stickerSideRoom)))
                        // The mark's receipt ("✓ Episode 5 watched · Undo") hangs from the slider's
                        // foot as an OVERLAY, into a band it reserves — a receipt never moves the
                        // page (CLAUDE.md, iteration 1).
                        .overlay(alignment: .bottom) {
                            ReceiptLine(host: host)
                                .offset(y: receiptBand)
                        }
                        .padding(.bottom, receiptBand)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .asymmetric(insertion: .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity),
                                                  removal: .opacity))
                } else if livePart != nil {
                    markTag
                        .transition(.asymmetric(
                            insertion: .opacity.animation(ThemeMotion.pick(ThemeMotion.uiSettle.delay(0.16), reduceMotion: reduceMotion)),
                            removal: .opacity.animation(ThemeMotion.pick(ThemeMotion.uiDismiss, reduceMotion: reduceMotion))))
                }
            }
            // Behind the sticker, so the gels burst OUT from behind the tag rather than across its
            // words — and survive the tag leaving.
            .background(alignment: .bottom) {
                GelSpark(trigger: sparks, reachX: StoryStyle.sparkReachX, reachY: StoryStyle.sparkReachY)
                    .frame(height: 48)
            }
        case .next:
            StoryCountdownSticker(reel: reel, frame: frame, alertStatus: alertStatus,
                                  onTurnOnAlerts: { Task { await turnOnAlerts() } },
                                  onOpenSettings: {
                                      if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                                  })
                .task { alertStatus = await EpisodeNotifications.shared.authorizationStatus() }
        }
    }

    /// Instagram's link sticker, as the mark: a white tag with a ring and the words. It answers
    /// "✓ Watched" in place while the slider comes in behind it.
    private var markTag: some View {
        Button(action: mark) {
            HStack(spacing: ThemeSpace.x2) {
                AppGlyph(systemName: unlocking ? "checkmark.circle.fill" : "circle")
                    .font(StoryStyle.tagLabel.font)
                    // A Tabler picture, not an SF Symbol: the ring crossfades to the check.
                    .contentTransition(.opacity)
                ZStack {
                    if unlocking {
                        Text(Copy.Stories.watched).transition(swap)
                    } else if let part = livePart {
                        Text(markLabel(part))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .transition(swap)
                    }
                }
            }
            .type(StoryStyle.tagLabel)
            .foregroundStyle(ThemeColor.stickerInk)
            .padding(.horizontal, ThemeSpace.x4)
            .frame(minHeight: StoryStyle.tagHeight)
            .background(ThemeColor.stickerCard, in: RoundedRectangle(cornerRadius: StoryStyle.tagRadius, style: .continuous))
            .shadow(StoryStyle.tagShadow)
            .contentShape(RoundedRectangle(cornerRadius: StoryStyle.tagRadius, style: .continuous))
        }
        .buttonStyle(FeedIconPressStyle())
        // It never greys out while the slider opens: a disabled tag for half a second read as a
        // failure. It simply stops taking touches.
        .allowsHitTesting(!unlocking)
    }

    /// "Mark Episode 5 as watched" for the next episode; a range further ahead confirms first.
    private func markLabel(_ part: FranchisePart) -> String {
        e == part.progress + 1
            ? Copy.Action.markEpisodeWatched(e)
            : Copy.Action.markThrough(from: part.progress + 1, to: e)
    }

    // MARK: Mark

    private func mark() {
        guard !unlocking, let part = livePart, part.progress < e else { return }
        if e == part.progress + 1 {
            // `markNext` signs the write itself (`.commitLight`, `.success` for a finish); the
            // view fires nothing on top.
            guard let undo = appModel.markNext(franchiseId: reel.franchiseId, mediaId: reel.mediaId) else { return }
            route(undo)
        } else {
            batch = BatchMark(from: part.progress, episode: e, season: part.label)
            actions.hold(.confirming, true)
        }
    }

    private func commitBatch(_ b: BatchMark) {
        guard let undo = appModel.markThrough(franchiseId: reel.franchiseId, mediaId: reel.mediaId,
                                              episode: b.episode, present: false) else { return }
        route(undo)
    }

    /// The receipt goes under this frame's slider when the write is THIS episode's; `markNext` may
    /// have advanced another part (this one at its ceiling), and that receipt belongs to the lane.
    private func route(_ undo: UndoState) {
        guard undo.mediaId == reel.mediaId, undo.episode == e, watched else {
            appModel.presentUndo(undo)
            return
        }
        pendingReceipt = undo.placed(at: host)
        runUnlock()
    }

    private func runUnlock() {
        unlockTask?.cancel()
        if !reduceMotion { sparks &+= 1 }
        withAnimation(ThemeMotion.pick(StoryStyle.unlockIn, reduceMotion: reduceMotion)) { unlocking = true }
        let hold = reduceMotion ? StoryStyle.unlockHoldReduced : StoryStyle.unlockHold
        unlockTask = Task { @MainActor in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) { unlocking = false }
            unlockTask = nil
            flushReceipt()
            if active { actions.restart() }
        }
    }

    private func flushReceipt() {
        guard let receipt = pendingReceipt else { return }
        pendingReceipt = nil
        appModel.presentUndo(receipt)
        Announce.status(receipt.message)
    }

    // MARK: Alerts (the countdown sticker's reminder)

    private func turnOnAlerts() async {
        actions.hold(.prompt, true)
        defer { actions.hold(.prompt, false) }
        let allowed = await EpisodeNotifications.shared.requestPermissionIfNeeded()
        if allowed { await appModel.alertsWereAllowed() }
        await ScheduleReminders.shared.refresh()
        alertStatus = await EpisodeNotifications.shared.authorizationStatus()
    }

    /// The handoff for a label that changes its words: out first, in a beat later — two
    /// sentences superimposed read as a smear.
    private var swap: AnyTransition {
        reduceMotion
            ? .opacity.animation(ThemeMotion.uiReduced)
            : .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.94)).animation(ThemeMotion.uiSettle.delay(0.16)),
                removal: .opacity.animation(ThemeMotion.uiDismiss))
    }
}

// MARK: - The countdown sticker

/// Instagram's countdown sticker, for the next episode: a white card with the episode, the time
/// left in big numerals, and the reminder — the REAL alert state, never a promise: "Episode alert
/// on" when the episode's alert is armed; "Turn on episode alerts" while permission was never asked
/// (an explicit affordance, so it may raise the prompt); "Episode alerts are off" + Open Settings
/// when denied. A date-only (TMDB) slot has no clock to count to or alert at: the day, and nothing
/// to arm.
private struct StoryCountdownSticker: View {
    let reel: StoryReel
    let frame: StoryFrame
    let alertStatus: UNAuthorizationStatus?
    let onTurnOnAlerts: () -> Void
    let onOpenSettings: () -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let now = appModel.nowMinute
        VStack(spacing: ThemeSpace.x2) {
            Text(Copy.episode(frame.episode).uppercased())
                .type(StoryStyle.countdownTitle)
                .foregroundStyle(ThemeColor.stickerInk.opacity(0.55))
            Text(when(now: now))
                .type(StoryStyle.countdownDigits)
                .foregroundStyle(ThemeColor.stickerInk)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            reminder
        }
        .padding(.horizontal, ThemeSpace.x5)
        .padding(.vertical, ThemeSpace.x4)
        .frame(maxWidth: StoryStyle.stickerMaxWidth)
        .background(ThemeColor.stickerCard, in: RoundedRectangle(cornerRadius: StoryStyle.countdownRadius, style: .continuous))
        .shadow(StoryStyle.tagShadow)
        .accessibilityElement(children: .contain)
    }

    /// "5d 3h" to a timed slot; the day for a date-only one.
    private func when(now: Int64) -> String {
        guard let at = frame.at else { return Copy.Stories.badgeNextEpisode }
        return Formatting.fmtCountdown(target: at, now: now, anchor: reel.anchor)
    }

    @ViewBuilder
    private var reminder: some View {
        if !reel.anchor.isDateOnly {
            if ScheduleReminders.shared.has(mediaId: reel.mediaId, episode: frame.episode) {
                AppGlyphLabel(Copy.Stories.alertOn, systemName: "bell.fill")
                    .type(ThemeType.metadataEmphasis)
                    .foregroundStyle(ThemeColor.stickerInk.opacity(0.7))
                    .frame(minHeight: FeedMetrics.actionHitHeight)
            } else {
                switch alertStatus {
                case .notDetermined?:
                    Button(action: onTurnOnAlerts) {
                        AppGlyphLabel(Copy.Stories.turnOnAlerts, systemName: "bell")
                            .type(ThemeType.metadataEmphasis)
                            .foregroundStyle(ThemeColor.stickerCard)
                            .padding(.horizontal, ThemeSpace.x4)
                            .frame(minHeight: StoryStyle.tagHeight - ThemeSpace.x2)
                            .background(ThemeColor.stickerInk, in: Capsule())
                            .frame(minHeight: FeedMetrics.actionHitHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FeedIconPressStyle())
                case .denied?:
                    Button(action: onOpenSettings) {
                        VStack(spacing: 0) {
                            Text(Copy.Notice.alertsOffTitle)
                                .type(ThemeType.metadata)
                                .foregroundStyle(ThemeColor.stickerInk.opacity(0.6))
                            Text(Copy.Notice.openSettings)
                                .type(ThemeType.metadataEmphasis)
                                .foregroundStyle(ThemeColor.stickerInk)
                        }
                        .frame(minHeight: FeedMetrics.actionHitHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(FeedIconPressStyle())
                default:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - The reply row

/// Instagram's row under the card: the field (the episode's discussion — its room keeps its own
/// spoiler lock), the heart and the send. The field only while comments are on; the heart only for
/// an episode you have watched (the room's rule); the send always.
private struct StoryReplyRow: View {
    let reel: StoryReel
    let frame: StoryFrame
    let actions: StoryPageActions

    @Environment(AppModel.self) private var appModel

    private var e: Int { frame.episode }
    private var subject: String { ThreadSubject.episode(mediaId: reel.mediaId, episode: e) }

    private var watched: Bool {
        guard frame.kind == .episode,
              let part = appModel.franchise(id: reel.franchiseId)?.parts.first(where: { $0.mediaId == reel.mediaId })
        else { return false }
        return part.progress >= e
    }

    var body: some View {
        HStack(spacing: ThemeSpace.x3) {
            if appModel.feedCapabilities.comments {
                field
            } else {
                Spacer(minLength: 0)
            }
            if watched { heart }
            share
        }
    }

    private var field: some View {
        let count = appModel.commentCount(subject)
        return Button { actions.discuss(e) } label: {
            HStack(spacing: ThemeSpace.x2) {
                Text(Copy.Stories.commentOnEpisode(e))
                    .type(ThemeType.storyReply)
                    .foregroundStyle(StoryStyle.ink.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text(FeedCount.text(count))
                        .type(ThemeType.feedCount)
                        .foregroundStyle(StoryStyle.inkFaint)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, ThemeSpace.x4)
            .frame(maxWidth: .infinity, minHeight: StoryStyle.replyRowHeight)
            .overlay(Capsule().strokeBorder(StoryStyle.replyStroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(FeedIconPressStyle())
        .accessibilityLabel(Copy.Stories.commentOnEpisode(e))
        .accessibilityValue(count > 0 ? Copy.Feed.replies(count) : "")
    }

    private var heart: some View {
        let liked = appModel.isLiked(subject)
        let likes = appModel.likeCount(subject)
        return Button {
            // `toggleLike` signs the way ON with `.selection` itself (iD21).
            appModel.toggleLike(subject, franchiseId: reel.franchiseId)
        } label: {
            LikeGlyph(liked: liked, size: StoryStyle.heartGlyph, idle: StoryStyle.ink)
                .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedIconPressStyle())
        .accessibilityLabel(liked ? Copy.Stories.unlikeEpisode : Copy.Stories.likeEpisode)
        .accessibilityValue(likes > 0 ? Copy.Feed.likes(likes) : "")
    }

    private var share: some View {
        ShareLink(item: Copy.Stories.shareEpisode(show: reel.showTitle, season: reel.partLabel, episode: e)) {
            AppGlyph(systemName: "paperplane")
                .font(.title2)
                .foregroundStyle(StoryStyle.ink)
                .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedIconPressStyle())
        .accessibilityLabel(Copy.Feed.share)
    }
}

// MARK: - VoiceOver's moves

/// The viewer's moves as named actions on the page's one element (the auto-advance never runs
/// under VoiceOver or Switch Control, so these ARE the way through).
private struct StoryNamedActions: ViewModifier {
    let actions: StoryPageActions
    /// The mark's own tag label, when the frame can be marked.
    let markLabel: String?
    let onMark: () -> Void

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if let markLabel {
                Button(markLabel, action: onMark)
            }
            Button(Copy.Stories.next, action: actions.next)
            Button(Copy.Stories.previous, action: actions.previous)
            if let nextShow = actions.nextShow {
                Button(Copy.Stories.nextShow, action: nextShow)
            }
            if let previousShow = actions.previousShow {
                Button(Copy.Stories.previousShow, action: previousShow)
            }
            Button(Copy.Stories.showPage, action: actions.openShow)
            Button(Copy.Stories.close, action: actions.close)
        }
    }
}
