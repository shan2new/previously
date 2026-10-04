import SwiftUI

// Recently aired, made worth looking at (26 Sep: "recently air feels really dull and uninteresting.
// Not delightful at all", owner — it was Schedule's agenda row, a list under a billboard). Two
// directions, photographed on the owner's library before one is chosen (`-recentDirection
// drops|rings`, DEBUG; absent = the rows as they shipped):
//   · DROPS — Apple TV's Up Next: a shelf of wide cards, each the show's own scene (a TMDB backdrop,
//     textless where there is one) with its logo on it, the NEW tag, the mark in the corner, and the
//     run to watch and when it aired beneath;
//   · RINGS — the feed's stories on Home: Instagram's lit rings with NEW / 3 NEW, the show's face,
//     and a tap opens the story viewer on that show — the episode, its mark sticker and all.

enum RecentDirection: String {
    case rows, drops, rings

    static let active: RecentDirection = {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "recentDirection"), let d = RecentDirection(rawValue: raw) {
            return d
        }
        #endif
        return .drops
    }()
}

extension Franchise {
    /// A true landscape of the show for a wide card — a TMDB backdrop, textless first; never an
    /// AniList banner (its middle third is a pair of eyes in a 16:9 frame). Nil when the catalogue
    /// has none.
    var sceneArt: String? {
        let scenes = (artwork?.landscapes ?? []).filter { image in
            !image.url.contains("/anime/banner/") && (image.width ?? 16) > (image.height ?? 9)
        }
        return (scenes.first { ArtworkSet.nonEmpty($0.language) == nil } ?? scenes.first)?.url
    }
}

/// One DROPS card: the show's scene, 16:9, its logo at the foot on a shade, the NEW tag, the mark in
/// the corner; under it the run to watch and when it aired. A show with no scene wears its
/// best-looking poster, filled from its top (where the faces are).
struct HomeDropCard: View {
    let entry: AppModel.ScheduleEntry
    /// Episodes out and unwatched up to this one.
    let run: Int
    /// What there is to watch, in the page's words: "Season 2 · Episode 1", "Episodes 22–24".
    let line: String
    let now: Int64
    /// The card's width: the shelf's, or the page's when it is the only drop (a shelf of one runs
    /// gutter to gutter — at 300 pt it sat beside ninety points of nothing).
    var width: CGFloat = HomeDropCard.shelfWidth
    var committing: Bool = false
    let onOpen: () -> Void
    let onMark: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow: Color?

    static let shelfWidth: CGFloat = 300
    private var height: CGFloat { (width * 9 / 16).rounded() }

    private var f: Franchise { entry.franchise }
    private var scene: String? { f.sceneArt }
    private var poster: String? { PosterPick.shared.choice(for: f)?.url ?? f.portraitArt }

    private var aired: String { TemporalCopy.aired(at: entry.at, now: now, source: f.source) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.card, style: .continuous)
        VStack(alignment: .leading, spacing: ThemeSpace.x2) {
            Button(action: onOpen) {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let scene {
                            RemoteImageView(url: scene, contentMode: .fill, maxPixel: 1024, alignment: .center,
                                            placeholderHidden: true)
                        } else if let poster {
                            RemoteImageView(url: poster, contentMode: .fill, maxPixel: 1024, alignment: .top,
                                            placeholderHidden: true)
                        }
                    }
                    .frame(width: width, height: height)
                    .clipped()
                    LinearGradient(stops: [.init(color: .clear, location: 0.35),
                                           .init(color: .black.opacity(0.72), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                    name
                        .padding(ThemeSpace.x3)
                }
                .frame(width: width, height: height)
                .background(ThemeColor.surfaceRaised)
                .clipShape(shape)
                .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topLeading) {
                HomeNewTag(text: Copy.Stories.ringTag(run))
                    .padding(ThemeSpace.x2)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                HomeMarkDisc(committing: committing, label: Copy.Action.markEpisodeWatched(entry.episode), action: onMark)
                    .padding(ThemeSpace.x1)
            }
            // The card sits in its own light: a soft pool of the scene's colour under it, cast by
            // the card's own shape (Schedule's lit card) — a blurred layer flattened to its bounds
            // (`drawingGroup`) ends on the bounds' straight edges.
            .background {
                if let glow {
                    // Cast from the card's lower half: nothing of it rises past the card's top (a
                    // card waiting under the tab bar lit the bar's edge with its colour).
                    shape.fill(ThemeColor.canvas.shadow(.drop(color: glow.opacity(0.4), radius: 22, x: 0, y: 14)))
                        .padding(.horizontal, 18)
                        .padding(.top, height * 0.45)
                        .allowsHitTesting(false)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(line)
                    .type(ThemeType.bodyEmphasis)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .contentTransition(.numericText())
                Text(aired)
                    .type(ThemeType.caption)
                    .foregroundStyle(ThemeColor.textSecondary)
            }
            .lineLimit(1)
            .padding(.horizontal, ThemeSpace.x0_5)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(f.displayTitle), \(line), \(aired)")
        .task(id: scene ?? poster) {
            guard let url = scene ?? poster else { return }
            let tint = await PaletteCache.shared.resolve(url: url, maxPixel: 240)
            withAnimation(ThemeMotion.pick(ThemeMotion.uiPoster, reduceMotion: reduceMotion)) { glow = HeroLight.glow(tint) }
        }
    }

    /// The show's logo on its scene; the name in type where it has none.
    @ViewBuilder private var name: some View {
        if f.hasDrawableLogo, let logo = f.billboardLogo {
            ArtworkLogo(name: .logo(logo), title: f.displayTitle, height: 40, alignment: .bottomLeading)
                .frame(maxWidth: width * 0.55, alignment: .bottomLeading)
        } else {
            Text(f.displayTitle)
                .type(ThemeType.rowTitle)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(2)
                .shadow(.art)
        }
    }
}
