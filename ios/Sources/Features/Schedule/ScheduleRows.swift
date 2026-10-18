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
    /// The show's face: 56 since 9 Oct (was X's 40 — "the Schedule screen just feels poorly made",
    /// owner; the rows had lost their art to a row of badges).
    static var avatar: CGFloat { 56 }
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

    /// Date, face, words, ladder — four columns at four fixed x's.
    private var inline: some View {
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

    /// The show as an ACCOUNT — the feed's rounded square (`ShowAvatar`; circles are people and
    /// the story tray), so a show wears one face on every screen. A watched airing gives it up a
    /// step, as the ladder's disc says it is spent.
    ///
    /// Lit: the face sits in a breath of its own colour — the palette colour as light under it,
    /// drawn by a canvas-filled copy of its shape (the shadow is the colour; the fill is the page,
    /// so a watched face's lowered opacity never shows the colour through it).
    private var face: some View {
        ShowAvatar(franchise: franchise, size: AgendaMetrics.avatar)
            .opacity(state.isWatched ? 0.55 : 1)
            .background {
                if decor.hueURL != nil, let light = ScheduleHue.glow(hue) {
                    ShowAvatar.shape(AgendaMetrics.avatar)
                        .fill(ThemeColor.canvas.shadow(.drop(
                            color: light.opacity(state.isWatched ? ScheduleWhisperMetrics.glowOpacityWatched
                                                                 : ScheduleWhisperMetrics.glowOpacity),
                            radius: ScheduleWhisperMetrics.glowRadius, x: 0, y: ScheduleWhisperMetrics.glowDrop)))
                        .transition(.opacity)
                }
            }
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
            Color.clear.frame(width: AgendaMetrics.avatar, height: 1)
            // The airing row's line, in the quietest ink: an absence, not a fact.
            Text(text)
                .type(ThemeType.scheduleMeta)
                .foregroundStyle(ThemeColor.textTertiary)
                .modifier(ScheduleInkCentre(capHeight: metaCap))
            Spacer(minLength: 0)
        }
        .frame(minHeight: AgendaMetrics.avatar)
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
