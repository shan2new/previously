import SwiftUI

// Schedule in the new language (25 Sep: "We need to Overhaul the Schedule Screen completely for this
// new awesome UX", owner). Three directions were photographed on the owner's own calendar — every
// airing an X post; X's compact agenda under day headings; the next thing to watch as one big card
// over the agenda — and the owner chose TONIGHT, then: "tonight still feels cluttered". Its day
// headings were 20-pt banners over one or two rows each (the 7 Sep finding again: ~40 % of the feed
// was banners), every upcoming line was amber, and an empty "Today" heading sat under a card that
// already said tonight. What it is now:
//   · the next thing to watch as ONE card (`ScheduleTonightCard`): the show's poster, one amber line
//     ("OUT NOW", "TONIGHT AT 7:30 PM", "SUNDAY AT 4:30 PM"), the show's logo else its name, the
//     episode, and the mark once it is out;
//   · then the agenda with THE DATE RIDING THE ROW (`ScheduleAgendaRow`, the 7 Sep anatomy): the
//     day once, in the date column, amber only on today; the show's face; its name; "Episode 14 ·
//     4:30 PM" in grey; the state ladder's slot (`AiringStateControl`). No day banners, no rules —
//     a day's break is the only space.
//   · since 16 Oct ("the way the font is being shown looks really cheapish", owner) the rows' TYPE
//     is their own, four styles on one scale (`ScheduleTypeScale`): the weekday in caps 11, the line
//     in Regular 14, the name in SemiBold 17, the numeral in Regular 22 — each block centred on the
//     face by its ink (`ScheduleInkCentre`), so the weekday's capitals sit level with the name's
//     and the numeral's foot with the caption's.

/// The agenda's columns, shared by the airing row and the empty day's row so the two line up. (Not
/// on the row: it is generic over its trailing view, and a generic type may not carry statics.)
enum AgendaMetrics {
    /// The show's face is its POSTER, 44×66 (19 Oct: "schedule feels 90% stunning but looses out the
    /// remaining 10%", owner). It was a 56-pt `ShowAvatar` — the iOS app icon's shape, 0.22
    /// continuous corners, cut from a poster's busiest square — so the screen read as a column of
    /// apps. Three faces were photographed on the owner's shows (that square, the poster, a 16:9
    /// scene; `design/schedule-faces-2026-10-19/`) and the owner chose the poster: the Library
    /// card's (`tilePoster`, titled where there is one), beside three lines of words.
    static let poster = CGSize(width: 44, height: 66)
    static let posterRadius: CGFloat = 6
    static var leading: CGFloat { ThemeMetrics.gutter - ThemeSpace.x1 }
    static var trailing: CGFloat { ThemeSpace.x3 }
    /// 8 above and below (was 6, 16 Oct): two 56-pt faces 12 pt apart read as one stack of tiles;
    /// at 16 each row is its own object, and a day's break (`ScheduleView.Metrics.dayGap`) is still
    /// twice that.
    static var vertical: CGFloat { ThemeSpace.x2 }
    /// The name → its line. Tight — they are one thought, and Outfit's line box already carries
    /// 0.30 em of air above the caption's capitals.
    static var titleGap: CGFloat { ThemeSpace.x0_5 }
}

/// Centres a block of text on its row by its INK — the first line's capitals to the last line's
/// baseline — rather than by its line boxes (16 Oct). Outfit's line box is 1.26 em, with 0.30 em of
/// air above its capitals and 0.26 em below its baseline, so a block centred by its boxes sits a
/// point or two off the face beside it, and off by a different amount for every size: the date
/// column (a big numeral with no descenders, all that air under it) rode two points higher than
/// the name and caption it stands beside.
struct ScheduleInkCentre: ViewModifier {
    /// The first line's capital height, in points at the current text size (`@ScaledMetric`).
    let capHeight: CGFloat

    func body(content: Content) -> some View {
        content.alignmentGuide(VerticalAlignment.center) { d in
            (d[VerticalAlignment.firstTextBaseline] - capHeight + d[VerticalAlignment.lastTextBaseline]) / 2
        }
    }
}

/// One airing in the agenda: the date (on a day's first row only), the show's face, its name, what
/// airs and when, and the state ladder's slot.
struct ScheduleAgendaRow<Trailing: View>: View {
    let franchise: Franchise
    /// "SUN" over "27" — a day's first row only (Later: "OCT" over "19").
    let date: (top: String, numeral: String)?
    let isToday: Bool
    let line: String
    /// Under the caption, where the row is from a part other than the one the reader is in: the
    /// season ("Season 2"), so the caption keeps its time whatever the name's length (9 Oct: "Season
    /// 2 · Episode 2 · 7:30…" cut the one fact a schedule exists to give).
    var sub: String? = nil
    /// The line's two facts apart — what airs ("Episode 9", "Episodes 7–9") and when ("7:30 PM", "in
    /// 28 minutes", "All day") — for the poster's three stacked lines. Nil: the one `line`.
    var episode: String? = nil
    var when: String? = nil
    let state: AiringState
    /// What VoiceOver says for the row (the date column is hidden from it).
    let spoken: String
    /// What the lit Schedule adds (`ScheduleLit.swift`): the show's colour under its face, today's
    /// countdown. `.none` is the plain row (Home's Recently aired).
    var decor: ScheduleRowDecor = .none
    let onOpen: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The name's capital height at the current text size — what the words centre on the face by.
    @ScaledMetric(relativeTo: .headline) private var titleCap: CGFloat = ScheduleTypeScale.title * ScheduleTypeScale.capHeight
    /// The show's palette colour, once resolved (the cache answers at once on a later visit).
    @State private var resolvedHue: Color?

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize { stacked } else { inline }
        }
        .padding(.leading, AgendaMetrics.leading)
        .padding(.trailing, AgendaMetrics.trailing)
        .padding(.vertical, AgendaMetrics.vertical)
        .task(id: decor.hueURL) { await resolveHue() }
    }

    /// The show's colour, from the palette cache (a dictionary read) or once resolved.
    private var hue: Color? {
        resolvedHue ?? decor.hueURL.flatMap { PaletteCache.shared.tint(for: $0) }
    }

    private func resolveHue() async {
        guard let url = decor.hueURL, PaletteCache.shared.tint(for: url) == nil else { return }
        let resolved = await PaletteCache.shared.resolveIfAvailable(url: url, maxPixel: 160)
        guard !Task.isCancelled, let resolved else { return }
        withAnimation(ThemeMotion.uiPoster) { resolvedHue = resolved }
    }

    /// Date, face, words, ladder — four columns at four fixed x's, the words centred on the face by
    /// their ink.
    @ViewBuilder
    private var inline: some View {
        if let episode {
            posterInline(episode)
        } else {
            HStack(spacing: ThemeSpace.x3) {
                dateColumn
                Button(action: onOpen) {
                    HStack(spacing: ThemeSpace.x3) {
                        face
                        // The lane runs to the ladder (a trailing `Spacer` took 12 pt of the name's
                        // width for nothing), and the words centre on the face by their ink.
                        words
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(ScheduleInkCentre(capHeight: titleCap))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowPressStyle())
                .accessibilityLabel(spoken)
                .accessibilityHint(Copy.Accessibility.opensTheShowHint)
                trailing()
            }
        }
    }

    /// The air Outfit sets above the name's capitals (0.30 em, `ScheduleInkCentre`).
    @ScaledMetric(relativeTo: .headline) private var titleAir: CGFloat = ScheduleTypeScale.title * 0.30

    /// The date column's width (`ScheduleDateColumn`'s, capped the same way).
    @ScaledMetric(relativeTo: .subheadline) private var dateScale: CGFloat = 1
    private var dateWidth: CGFloat { min(38 * dateScale, 38 + 16) }

    /// Beside a POSTER the row is THREE text lines, the date in them (19 Oct: "Why aren't
    /// these horizontally aligned?… the last row is competing with the 2nd one", owner): the date
    /// and the words were each centred on the poster on their own, so "MON" and "19" shared no line
    /// with "Bleach" and "Episode 9". Now each line is a row on one baseline — the weekday with the
    /// name, the numeral with the episode — and the poster stands in its column, its top edge on the
    /// capitals' line. The third line, WHEN, is the weekday's small capitals ("7:30 PM", "ALL DAY", the
    /// countdown in the accent): a third level under the episode, not a second one beside it.
    private func posterInline(_ episode: String) -> some View {
        let watched = state.isWatched
        let poster = AgendaMetrics.poster
        return HStack(spacing: ThemeSpace.x3) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: ThemeSpace.x1) {
                    posterLine(poster.width) {
                        Text(date?.top ?? "")
                            .type(ThemeType.scheduleCaps)
                            .textCase(.uppercase)
                            .foregroundStyle(isToday ? ThemeColor.accent : ThemeColor.textTertiary)
                    } words: {
                        Text(franchise.displayTitle)
                            .type(ThemeType.scheduleTitle)
                            .foregroundStyle(watched ? ThemeColor.textTertiary : ThemeColor.textPrimary)
                            .lineLimit(2)
                    }
                    posterLine(poster.width) {
                        // The numeral sits ON the episode's baseline without making its line any
                        // taller: a 22-pt line pushed "Episode 9" a line's air away from the name.
                        Text(verbatim: "0")
                            .type(ThemeType.scheduleMeta)
                            .hidden()
                            .overlay(alignment: Alignment(horizontal: .center, vertical: .firstTextBaseline)) {
                                Text(date?.numeral ?? "")
                                    .type(ThemeType.scheduleDate)
                                    .foregroundStyle(isToday ? ThemeColor.accent : ThemeColor.textSecondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                    } words: {
                        Text([sub, episode].compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .type(ThemeType.scheduleMeta)
                            .foregroundStyle(watched ? ThemeColor.textTertiary : ThemeColor.textSecondary)
                            .lineLimit(2)
                    }
                    if let when {
                        posterLine(poster.width) {
                            Color.clear.frame(height: 0)
                        } words: {
                            Text(when)
                                .type(ThemeType.scheduleCaps)
                                .textCase(.uppercase)
                                .foregroundStyle(when == decor.accentTail ? ThemeColor.accent : ThemeColor.textTertiary)
                                .lineLimit(1)
                        }
                        .padding(.top, 2)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                // ONE top line: the weekday's capitals, the poster's top edge and the name's
                // capitals (Outfit sets 0.30 em of air above its capitals; the block gives it back).
                .padding(.top, -titleAir)
                .frame(minHeight: poster.height, alignment: .top)
                .overlay(alignment: .topLeading) {
                    face.padding(.leading, dateWidth + ThemeSpace.x3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            .accessibilityLabel(spoken)
            .accessibilityHint(Copy.Accessibility.opensTheShowHint)
            trailing()
        }
    }

    /// One line of the poster row: the date's part, the poster's column, the words — on ONE baseline.
    private func posterLine<D: View, W: View>(_ posterWidth: CGFloat, @ViewBuilder date: () -> D,
                                              @ViewBuilder words: () -> W) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ThemeSpace.x3) {
            date()
                .lineLimit(1)
                .frame(width: dateWidth)
            Color.clear.frame(width: posterWidth, height: 0)
            words()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// At the ACCESSIBILITY sizes the row unfolds, as the 7 Sep row did: the date, the face and the
    /// ladder keep one line and the words take the full width beneath them — four columns at that
    /// type left the name a lane narrower than one word.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: ThemeSpace.x2) {
            HStack(spacing: ThemeSpace.x3) {
                dateColumn
                face.accessibilityHidden(true)
                Spacer(minLength: 0)
                trailing()
            }
            Button(action: onOpen) {
                words
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            .accessibilityLabel(spoken)
            .accessibilityHint(Copy.Accessibility.opensTheShowHint)
        }
    }

    private var dateColumn: some View {
        ScheduleDateColumn(weekday: date?.top, numeral: date?.numeral, isToday: isToday)
    }

    /// The show's face, its poster (`faceArt`). A watched airing gives it up a step, as the ladder's
    /// disc says it is spent.
    ///
    /// Lit: the face sits in a breath of its own colour — the palette colour as light under it,
    /// drawn by a canvas-filled copy of its shape (the shadow is the colour; the fill is the page,
    /// so a watched face's lowered opacity never shows the colour through it).
    private var face: some View {
        faceArt
            .opacity(state.isWatched ? 0.55 : 1)
            .background {
                if decor.hueURL != nil, let light = ScheduleHue.glow(hue) {
                    RoundedRectangle(cornerRadius: AgendaMetrics.posterRadius, style: .continuous)
                        .fill(ThemeColor.canvas.shadow(.drop(
                            color: light.opacity(state.isWatched ? ScheduleWhisperMetrics.glowOpacityWatched
                                                                 : ScheduleWhisperMetrics.glowOpacity),
                            radius: ScheduleWhisperMetrics.glowRadius, x: 0, y: ScheduleWhisperMetrics.glowDrop)))
                        .transition(.opacity)
                }
            }
    }

    /// The show's poster, the Library card's (`tilePoster`, the titled one where there is one): at
    /// 44 pt a billboard's textless pick is a dark field of nothing.
    private var faceArt: some View {
        let shape = RoundedRectangle(cornerRadius: AgendaMetrics.posterRadius, style: .continuous)
        return RemoteImageView(url: franchise.tilePoster.url ?? franchise.portraitArt,
                               contentMode: .fill, maxPixel: 200, alignment: .top, placeholderHidden: true)
            .frame(width: AgendaMetrics.poster.width, height: AgendaMetrics.poster.height)
            .background(ThemeColor.surfaceRaised)
            .clipShape(shape)
            .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: FeedMetrics.hairline))
    }

    /// The name, then its line — and the part under the line where it must be named, at the line's
    /// size in the quieter ink, so the column holds two sizes, not three. Three inks down the
    /// column: the name in the text ink, the line a step under it, the part a step under that. A
    /// watched row gives the name and the line up to the quietest ink (the face gives up its light
    /// with them); size and weight still part the name from its line.
    ///
    /// The name takes two lines before an ellipsis (it took one): in the old 183-pt lane "That Time
    /// I Got Reincarnated as a Slime" was "That Time I Got Re…" — a row may grow; it may not lose
    /// the show.
    private var words: some View {
        VStack(alignment: .leading, spacing: AgendaMetrics.titleGap) {
            Text(franchise.displayTitle)
                .type(ThemeType.scheduleTitle)
                .foregroundStyle(state.isWatched ? ThemeColor.textTertiary : ThemeColor.textPrimary)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
            // The line and the part are one block, on their own leading.
            VStack(alignment: .leading, spacing: 0) {
                caption
                if let sub {
                    Text(sub)
                        .type(ThemeType.scheduleMeta)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .multilineTextAlignment(.leading)
    }

    /// "Episode 14 · 4:30 PM" — ONE concatenated `Text` (the row's rule), today's countdown in
    /// accent where it counts ("Episode 14 · in 2h 14m").
    private var caption: some View {
        captionText
            .type(ThemeType.scheduleMeta)
            .foregroundStyle(state.isWatched ? ThemeColor.textTertiary : ThemeColor.textSecondary)
            // Two lines before an ellipsis: a premiere's long caption wraps rather than losing its time.
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
    }

    private var captionText: Text {
        if let tail = decor.accentTail, line.hasSuffix(tail) {
            return Text(String(line.dropLast(tail.count))) + Text(tail).foregroundStyle(ThemeColor.accent)
        }
        return Text(line)
    }
}

/// A day with nothing on it — today, or a day picked on the grid: its date in the column, and one
/// grey line where the names are.
struct ScheduleEmptyDayRow: View {
    let weekday: String
    let numeral: String
    let isToday: Bool
    let text: String
    let spoken: String
    /// The line's capital height at the current text size (`ScheduleInkCentre`).
    @ScaledMetric(relativeTo: .subheadline) private var metaCap: CGFloat = ScheduleTypeScale.meta * ScheduleTypeScale.capHeight

    var body: some View {
        HStack(spacing: ThemeSpace.x3) {
            ScheduleDateColumn(weekday: weekday, numeral: numeral, isToday: isToday)
            Color.clear.frame(width: AgendaMetrics.poster.width, height: 1)
            // The airing row's line, in the quietest ink: an absence, not a fact.
            Text(text)
                .type(ThemeType.scheduleMeta)
                .foregroundStyle(ThemeColor.textTertiary)
                .modifier(ScheduleInkCentre(capHeight: metaCap))
            Spacer(minLength: 0)
        }
        .padding(.leading, AgendaMetrics.leading)
        .padding(.trailing, AgendaMetrics.trailing)
        .padding(.vertical, AgendaMetrics.vertical)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// The card's mark as X's pill: "Mark as watched" in ink on white until it is, then "Watched" in a
/// one-pixel outline with the check (a tap undoes).
struct ScheduleMarkPill: View {
    let watched: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AppGlyphLabel(watched ? Copy.Action.watched : Copy.Action.markWatched, systemName: watched ? "checkmark" : "plus")
                .type(ThemeType.feedNoteTitle)
                .foregroundStyle(watched ? ThemeColor.feedText : ThemeColor.canvas)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, ThemeSpace.x4)
                .frame(minHeight: 36)
                .background(watched ? AnyShapeStyle(Color.clear) : AnyShapeStyle(ThemeGradient.ivory), in: Capsule())
                .overlay(Capsule().strokeBorder(watched ? ThemeColor.feedText.opacity(0.4) : .clear, lineWidth: FeedMetrics.hairline))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedIconPressStyle())
        .accessibilityLabel(label)
    }
}

/// A label over the agenda — the month it crosses into, "LATER" — in Schedule's caps: the date
/// column's weekday style (one caps style in the list, 16 Oct), a step brighter, as it heads rows.
struct ScheduleEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .type(ThemeType.scheduleCaps)
            .textCase(.uppercase)
            .foregroundStyle(ThemeColor.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, ThemeMetrics.gutter)
            .accessibilityAddTraits(.isHeader)
    }
}
