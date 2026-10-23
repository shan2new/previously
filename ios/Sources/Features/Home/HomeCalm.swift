import SwiftUI

// Home in the CALM language, rebuilt 19 Oct after the owner opened build 18 on a caught-up account:
// "What the actual fuck is this trash UX? All of it?… this is the first thing a person opens up and
// is greeted with overwhelm". What the screen was, top to bottom: a 20-pt sentence saying there was
// nothing ("You're all caught up") with the one useful fact — the next airing — as a grey caption;
// a shelf of 300-pt news pictures, each a show's key art or a lettered YouTube still with the show's
// logo printed over it again; then TWO shelves of 150-pt posters of shows the viewer does not own,
// each under a 20-pt reason ("Because you're watching Mushoku Tensei"). Three picture formats at one
// weight, two thirds of the page about other shows, and the bars — transparent since 17 Oct —
// printing their glyphs over poster titles at rest and over section titles on a scroll.
//
// What it is now: your shows first; the news as headlines (`NewsRow`), not pictures; ONE shelf for
// you, last, headed by a short title with its reason under it; and the page fading out under both
// bars (`HeaderEdgeFade`) — the bars stay transparent, the ground shows through, and nothing reads under
// a glyph. Caught up, the state is one quiet line and YOUR next airings lead (`HomeComingUp`). Two
// leads were photographed the same evening — that, and the state in one line over the news led by
// one picture — and the owner chose COMING UP ("Coming up is better but needs refinement"). Its first
// cut borrowed Schedule's row and put the state under its title; the refinement:
//   · the state is the page's, not the section's: "You're all caught up" as its subline read as
//     "nothing is coming up";
//   · the row is Home's own, the News row's anatomy (a 120×68 scene, two lines beside it), so the page
//     has one row — Schedule's square faces beside News's wide pictures were two;
//   · WHEN leads the row's words, in the accent — "Tonight at 7:30 PM", the app's one temporal
//     ladder — where Schedule's calendar column ("TUE" over a 22-pt "20") made the reader do the
//     date's sums and was the loudest thing in the row.
// Then a second pass ("News too loud, For you too big, no clear lead", owner): the soonest airing
// is a CARD (`HomeComingUpCard`) with when it airs on Netflix's red strip ("Tonight 7:30 PM" —
// "remove at… move it to the hero with a red strip like Netflix does", owner), the news rows take
// a smaller picture and a lighter headline (`NewsRow(compact:)`), and For you's posters are 112 pt.
// Then a third ("at most 1 thing… if it is airing the same day… No point in showing you're caught up
// if a coming up item is there… News should be only shown for the latest update that came that day",
// owner): caught up, Home leads with TODAY's next airing as the card and no title, else the caught-up
// line; the news is today's latest update as one row, else nothing; the strip hugs its words.

/// A Home section's header: the title (the section's door when it has one), and under it one quiet
/// line that says why — the reason a shelf is for you.
struct HomeSectionHeader: View {
    let title: String
    var subline: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeSpace.x0_5) {
            SectionHeaderRow(title, action: action)
            if let subline {
                Text(subline)
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Caught up, as a MOMENT (19 Oct, fourth pass: "You're all caught up feels so out of place. It
/// deserves some space to actually feel caught up", owner). It was a 13-pt line with a check over the
/// shelf. Now it has the top of the screen to itself: the committed mark's disc — the amber the app
/// spends on a mark that has landed, in a pool of its own light — the words set large, one sentence
/// under them, and room on both sides. Static: nothing moves, nothing per frame.
struct HomeCaughtUp: View {
    @ScaledMetric(relativeTo: .title2) private var disc: CGFloat = 56

    var body: some View {
        VStack(spacing: ThemeSpace.x4) {
            ZStack {
                EllipticalGradient(colors: [ThemeColor.accent.opacity(0.22), .clear],
                                   center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                    .frame(width: disc * 3.4, height: disc * 2.6)
                Circle()
                    .fill(ThemeGradient.accent)
                    .frame(width: disc, height: disc)
                    .overlay(Circle().strokeBorder(ThemeGradient.litEdgeStrong, lineWidth: 1))
                AppGlyph(systemName: "checkmark")
                    .font(.system(size: disc * 0.42, weight: .bold))
                    .foregroundStyle(ThemeColor.onAccent)
            }
            .frame(height: disc * 1.4)
            .accessibilityHidden(true)
            VStack(spacing: ThemeSpace.x2) {
                Text(Copy.Home.caughtUp.title)
                    .type(ThemeType.caughtUpTitle)
                    .foregroundStyle(ThemeColor.textPrimary)
                if let line = Copy.Home.caughtUp.supporting {
                    Text(line)
                        .type(ThemeType.prose)
                        .foregroundStyle(ThemeColor.textSecondary)
                }
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ThemeSpace.x10)
        .accessibilityElement(children: .combine)
    }
}

/// Caught up, the one thing COMING (19 Oct, third pass: "We should show at most 1 thing in the coming
/// up and that too if it is airing the same day. No need to have the title coming up", owner): your
/// next airing TODAY, as one card (`HomeComingUpCard`), else nothing — the rest of the week is
/// Schedule's. The card says what it is on its strip, so it carries no section title.
@MainActor
enum HomeComingUp {
    /// Today's next airing still to come on one of your shows, if any.
    static func today(_ appModel: AppModel) -> AppModel.ScheduleEntry? {
        appModel.scheduleDays.first(where: \.isToday)?.entries.first { !$0.aired }
    }
}

extension AppModel.ScheduleEntry {
    /// When it airs, in the app's one temporal ladder ("Airs in 9 min", "Tomorrow at 7:30 PM"), with
    /// Schedule's evening word: an airing later today, an hour or more away, is "Tonight at 7:30 PM".
    func homeWhen(now: Int64) -> String {
        let f = franchise
        if !dateOnly, at - now >= 60 * Formatting.minuteMs,
           Formatting.dayDiff(ts: at, now: now, anchor: f.timeAnchor) == 0,
           Formatting.isEvening(hour: Formatting.localParts(at, anchor: f.timeAnchor).hour) {
            return Copy.Schedule.tonightAt(Formatting.fmtTime(at, anchor: f.timeAnchor))
        }
        return TemporalCopy.airs(at: at, now: now, anchor: f.timeAnchor)
    }

    /// When it airs as a LABEL, for the lead card's strip (19 Oct: "remove at from tonight at 7:30PM
    /// and move it to the hero with a red strip like Netflix does", owner): the day and the clock,
    /// no preposition — "Tonight 7:30 PM", "Tomorrow 7:30 PM", "Thursday 7:30 PM", "Airs in 9 minutes"; a
    /// date-only airing is its day alone. The same ladder as `homeWhen`, cut for a tag.
    func homeStrip(now: Int64) -> String {
        let f = franchise
        let anchor = f.timeAnchor
        let delta = at - now
        if !dateOnly, delta > 0, delta < 60 * Formatting.minuteMs {
            return Copy.Home.inMinutes(max(1, Int(delta / Formatting.minuteMs)))
        }
        let day = Formatting.dayDiff(ts: at, now: now, anchor: anchor)
        let time = dateOnly ? "" : Formatting.fmtTime(at, anchor: anchor)
        let word: String
        switch day {
        case 0: word = !time.isEmpty && Formatting.isEvening(hour: Formatting.localParts(at, anchor: anchor).hour)
            ? Copy.Home.tonight : Copy.Home.today
        case 1: word = Copy.Home.tomorrow
        case 2...6: word = Formatting.fmtDayLong(ts: at, now: now, anchor: anchor)
        default: word = TemporalCopy.dateWord(at, now: now, anchor: anchor)
        }
        return time.isEmpty ? word : "\(word) \(time)"
    }

    /// What airs: "Episode 9", or a premiere by its part, "Season 2 premiere".
    var homeWhat: String {
        guard episode == 1 else { return Copy.episode(episode) }
        return Copy.Schedule.premiere(Copy.compactPartLabel(part.canonicalLabel))
    }
}

/// Home's LEAD card, one anatomy for what is OUT and what airs TODAY (19 Oct: "can we make this Hero
/// card similar to the today upcoming one?", owner — a drop was a picture with a NEW tag and two
/// lines hung under it, under a "Recently aired" title; today's airing was this): the show's scene
/// in the gutters at 16:9, its logo centred, what to watch under it, and WHEN on Netflix's red STRIP
/// at the foot ("…move it to the hero with a red strip like Netflix does", owner) — "Aired Saturday"
/// for a drop, "Tonight 7:30 PM" for today's airing. Nothing hangs under the card and it carries no
/// section title: the strip says what it is. A drop can be marked (`corner`); an airing cannot.
struct HomeLeadCard<Corner: View>: View {
    let franchise: Franchise
    /// "Season 2 · Episode 3", "Episodes 22–24", "Episode 9", "Season 2 premiere".
    let what: String
    let strip: String
    var width: CGFloat = HomeLeadCard.fullWidth
    let onOpen: () -> Void
    @ViewBuilder var corner: () -> Corner

    @Environment(AppModel.self) private var appModel

    /// Gutter to gutter: the card when it is the only one.
    static var fullWidth: CGFloat { ThemeMetrics.windowWidth - 2 * ThemeMetrics.gutter }

    private var f: Franchise { franchise }
    private var height: CGFloat { (width * 9 / 16).rounded() }
    /// The logo keeps its share of the card on a shelf's narrower one.
    private var logoHeight: CGFloat { max(32, (44 * width / Self.fullWidth).rounded()) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.card, style: .continuous)
        Button(action: onOpen) {
            ZStack(alignment: .bottom) {
                HomeShowScene(franchise: f, width: width, height: height)
                LinearGradient(stops: [.init(color: .clear, location: 0.34),
                                       .init(color: .black.opacity(0.78), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 0) {
                    name
                    Text(what)
                        .type(ThemeType.metadataEmphasis)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .shadow(.art)
                        .contentTransition(.numericText())
                        .padding(.top, ThemeSpace.x1)
                        .padding(.bottom, ThemeSpace.x2)
                    HomeAirStrip(text: strip)
                }
            }
            .frame(width: width, height: height)
            .background(ThemeColor.surfaceRaised)
            .clipShape(shape)
            .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
        }
        .buttonStyle(OverArtPressStyle())
        .overlay(alignment: .topTrailing) { corner() }
        .frame(width: width, alignment: .leading)
        .franchiseQuickActions(appModel.isInLibrary(f.id) ? f : nil, appModel: appModel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(f.displayTitle), \(what), \(strip)")
        .accessibilityHint(Copy.Accessibility.opensTheShowHint)
    }

    /// The show's logo on its scene, centred over the strip; the name in type where it has none.
    @ViewBuilder private var name: some View {
        if f.hasDrawableLogo, let logo = f.billboardLogo {
            ArtworkLogo(name: .logo(logo), title: f.displayTitle, height: logoHeight, alignment: .bottom)
                .frame(maxWidth: width * 0.6)
        } else {
            Text(f.displayTitle)
                .type(ThemeType.rowTitle)
                .foregroundStyle(ThemeColor.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .shadow(.art)
                .padding(.horizontal, ThemeSpace.x4)
        }
    }
}

/// The lead row as a FOCUS carousel (19 Oct: "the current hero could be larger here and as we slide
/// to the next the next becomes bigger", owner): the card in front at full size and nearly the
/// page's width, the next a step smaller beside it, and the step follows the finger
/// (`.interactive`) — the card coming in grows as it arrives, the one leaving shrinks. A side card
/// leans toward the one in front (scaled from its near edge), so the peek stays a peek. A render
/// pass, never a body re-run. Reduce Motion keeps every card its size and only dims the sides.
struct HomeLeadFocus: ViewModifier {
    let reduceMotion: Bool

    /// The card in front: most of the page, with the next one's edge in view.
    static var cardWidth: CGFloat { (HomeLeadCard<EmptyView>.fullWidth * 0.88).rounded() }
    /// A side card's size against the one in front.
    static let sideScale: CGFloat = 0.86

    func body(content: Content) -> some View {
        content.scrollTransition(.interactive, axis: .horizontal) { card, phase in
            let t = min(1, abs(phase.value))
            return card
                .scaleEffect(reduceMotion ? 1 : 1 - (1 - Self.sideScale) * t,
                             anchor: phase.value > 0 ? .leading : .trailing)
                .opacity(1 - 0.3 * t)
        }
    }
}

/// Today's airing as the lead card (`HomeLeadCard`): nothing to mark yet.
struct HomeComingUpCard: View {
    let entry: AppModel.ScheduleEntry
    let now: Int64
    var width: CGFloat = HomeLeadCard<EmptyView>.fullWidth
    let onOpen: () -> Void

    var body: some View {
        HomeLeadCard(franchise: entry.franchise, what: entry.homeWhat, strip: entry.homeStrip(now: now),
                     width: width, onOpen: onOpen) { EmptyView() }
    }
}

/// Netflix's tag on a picture's foot: a red strip, its top corners rounded, touching the edge, the
/// words in white — when the episode aired, or when it airs. The tags' capitals (`heroBadge`, 11-pt
/// bold, the NEW tag's and the show page's badge's), not 13-pt words (19 Oct: "Aired Saturday strip
/// needs to be smaller so that it doesn't compete with the Hero AND still is catchy enough",
/// owner): smaller, and the red and the capitals keep it the first thing the eye finds.
struct HomeAirStrip: View {
    let text: String

    var body: some View {
        Text(text)
            .type(ThemeType.heroBadge)
            .textCase(.uppercase)
            .foregroundStyle(.white)
            .lineLimit(1)
            // Tight to its words (third pass: "the Tonight strip has too much padding", owner).
            .padding(.horizontal, 6)
            .padding(.top, 3)
            .padding(.bottom, 2)
            .background(ThemeColor.strip,
                        in: UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous))
    }
}

/// A show's SCENE in a frame (Recently aired's picture): its textless backdrop, else its picked
/// poster filled from the top.
struct HomeShowScene: View {
    let franchise: Franchise
    let width: CGFloat
    let height: CGFloat

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let pixels = min(1024, width * displayScale)
        Group {
            if let url = franchise.sceneArt {
                RemoteImageView(url: url, contentMode: .fill, maxPixel: pixels, alignment: .center,
                                placeholderHidden: true)
            } else if let poster = PosterPick.shared.choice(for: franchise)?.url ?? franchise.portraitArt {
                RemoteImageView(url: poster, contentMode: .fill, maxPixel: pixels, alignment: .top,
                                placeholderHidden: true)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

