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

/// The agenda's columns, shared by the airing row and the empty day's row so the two line up. (Not
/// on the row: it is generic over its trailing view, and a generic type may not carry statics.)
enum AgendaMetrics {
    static var avatar: CGFloat { 40 }
    static var leading: CGFloat { ThemeMetrics.gutter - ThemeSpace.x1 }
    static var trailing: CGFloat { ThemeSpace.x3 }
    static var vertical: CGFloat { ThemeSpace.x1 + 2 }
}

/// One airing in the agenda: the date (on a day's first row only), the show's face, its name, what
/// airs and when, and the state ladder's slot.
struct ScheduleAgendaRow<Trailing: View>: View {
    let franchise: Franchise
    /// "SUN" over "27" — a day's first row only (Later: "OCT" over "19").
    let date: (top: String, numeral: String)?
    let isToday: Bool
    let line: String
    let state: AiringState
    /// What VoiceOver says for the row (the date column is hidden from it).
    let spoken: String
    /// What the lit Schedule adds (`ScheduleLit.swift`): the show's colour under its face, today's
    /// countdown. `.none` is the plain row (Home's Recently aired).
    var decor: ScheduleRowDecor = .none
    let onOpen: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var typeSize
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
                    words
                    Spacer(minLength: 0)
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

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(franchise.displayTitle)
                .type(ThemeType.feedName)
                .foregroundStyle(state.isWatched ? ThemeColor.feedSecondary : ThemeColor.feedText)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            caption
        }
        .multilineTextAlignment(.leading)
    }

    /// "Episode 14 · 4:30 PM" — ONE concatenated `Text` (the row's rule), today's countdown in
    /// accent where it counts ("Episode 14 · in 2h 14m").
    private var caption: some View {
        captionText
            .type(ThemeType.feedMeta)
            .foregroundStyle(ThemeColor.feedSecondary)
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
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

    var body: some View {
        HStack(spacing: ThemeSpace.x3) {
            ScheduleDateColumn(weekday: weekday, numeral: numeral, isToday: isToday)
            Color.clear.frame(width: AgendaMetrics.avatar, height: 1)
            Text(text)
                .type(ThemeType.feedMeta)
                .foregroundStyle(ThemeColor.feedSecondary)
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

/// A label over the agenda — the month it crosses into, "LATER" — in Schedule's caps.
struct ScheduleEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .type(ThemeType.feedEyebrow)
            .textCase(.uppercase)
            .foregroundStyle(ThemeColor.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, ThemeMetrics.gutter)
            .accessibilityAddTraits(.isHeader)
    }
}
