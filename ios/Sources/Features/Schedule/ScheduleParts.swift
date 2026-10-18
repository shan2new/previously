import SwiftUI

// Schedule's row and its calendar (6 Sep, evening — the second rebuild of this screen in a day).
//
// Two complaints settled it ("Lots of problem in the Schedule page", user):
//   1. "The calendar part is utterly confusing and poorly executed."
//   2. "There is no instant visual distinction between an episode that has been marked as
//      completed, not seen, and upcoming. Everything feels of the same weight."
//
// Four headers and three densities were built behind launch arguments and photographed side by
// side on the real account; the user picked the MONTH GRID behind a bar button, on COMPACT rows.
// What the photographs showed, in order of how much they mattered:
//
//   · The rail that shipped that morning was pointing at days the reader was not looking at. In
//     the capture the feed sat on Wednesday 2 Sep and Friday 4 Sep and NEITHER day was on the
//     rail — both had scrolled off its left edge while the selected capsule said "TODAY". NN/g's
//     eye-tracking puts ~1 % of attention past the edge of a horizontal strip, and a jump list
//     whose targets are off-screen is not a jump list. It also named every day twice: "WED 9" in
//     the rail, "WEDNESDAY · 9 SEP" in the feed a hundred points below.
//   · A list of only the non-empty days cannot show a month's SHAPE — which weeks are busy, which
//     are spent, which are empty — by construction. The grid can, and at rest it costs nothing.
//   · At a gutter-to-gutter 16:9 card an airing plus its day header is ~305 pt, so exactly two fit
//     between the chrome and the tab bar. A state ladder you can only see two rungs of is not a
//     ladder. The same feed at 104×59 runs six deep and ends on "That's everything through 18 Sep".
//
// The reference apps: animeschedule.net prints day headers and pages by WEEK, with no day picker;
// Fantastical's DayTicker pulls down into a month; Google Calendar's Schedule view puts the jump
// behind a month dropdown that OVERLAYS the agenda. Trakt v3 dropped its date picker entirely.

// MARK: - Debug

/// Capture-only launch arguments, in the family `-scheduleFilter` already uses.
enum ScheduleDebug {
    /// Start on an existing day for screenshot QA without tapping or changing account data.
    /// `-scheduleCaptureDay -1` shows yesterday's aired cards and watched controls.
    static var captureDay: Int? {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "-scheduleCaptureDay"),
              arguments.indices.contains(flag + 1) else { return nil }
        // UserDefaults treats negative offsets as another flag, not the requested day.
        return Int(arguments[flag + 1])
        #else
        return nil
        #endif
    }

    /// `-scheduleDemoCountdown 1`: the countdown on the NEXT airing whatever its day, so it can be
    /// photographed on a day with nothing airing. It changes what is DRAWN, never what is stored, and
    /// the count it draws is the real one.
    static var demoCountdown: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "scheduleDemoCountdown")
        #else
        return false
        #endif
    }

    /// `-scheduleDemoStates 1` — the test account has no AIRED-AND-UNWATCHED airing (both past
    /// slots are watched, and Mushoku is `planned`, so its four are correctly off the calendar),
    /// so the ladder cannot be photographed with all three rungs on real data. This draws the most
    /// recent aired airing as though it were still waiting. It changes what is DRAWN, never what
    /// is stored.
    static var demoStates: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "scheduleDemoStates")
        #else
        return false
        #endif
    }

    /// `-scheduleMonthOpen 1` — open with the calendar already down, for a capture.
    static var monthOpen: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "scheduleMonthOpen")
        #else
        return false
        #endif
    }
}

// MARK: - The state ladder

/// The three states an airing can be in, and the ONE place they are told apart.
///
/// What shipped put the three signals in three corners of a 249-pt card: the clock's colour at the
/// leading edge, the ring's presence at the trailing edge, a 26-pt check on the art's top-right —
/// and "watched" was `opacity(0.72)` over a photograph on black, which is not a state, it is a
/// haze. Jellyfin's #706 is the same bug with better contrast: readers cannot parse states that
/// differ only in glyph at the same weight ("I keep getting that small moment of excitement
/// thinking there is a new episode, and upon closer inspection it's just the same blue circle with
/// a check mark").
///
/// The fix is a LADDER at one x-position — the trailing slot, which every airing reserves whether
/// or not it has a control, so the eye runs down one column and reads:
///
///   · `upcoming` — an empty slot, and the time in accent. Nothing to do; the fact is the clock.
///   · `toWatch`  — the accent RING with its episode numeral. The only lit thing in the column.
///   · `watched`  — a settled DISC with a check, and the art dimmed a step below the ink. A tap
///                  on the disc marks it unwatched again (in the library).
///
/// The urgency also stops being inverted: the ring, not the clock, is what the accent buys on an
/// aired row, and a watched row gives up its picture's brightness rather than a tenth of its alpha.
enum AiringState: Equatable {
    case upcoming
    case toWatch
    case watched

    var isWatched: Bool { self == .watched }
}

/// The trailing column, at one width for all three states so the column exists even where it is
/// empty. 44 pt is the ring's own target; an upcoming row reserves it rather than closing the gap,
/// which is what let "watched" and "upcoming" look identical here before.
struct AiringStateControl: View {
    let state: AiringState
    let episode: Int
    /// The mark is mid-flight: the ring fills and the check draws in place (`MarkRing` owns it).
    let committing: Bool
    let title: String
    /// Marking this row would cover more than one episode.
    let batch: Bool
    let count: Int
    /// The show is in the library, so there is progress to write. A catalogue row that merely airs
    /// keeps the column's width and draws nothing in it.
    let canMark: Bool
    let action: () -> Void

    var body: some View {
        Group {
            switch state {
            case .toWatch where !canMark:
                Color.clear.frame(width: 44, height: 44)
            case .toWatch:
                // `lead: true` is what makes the ring ACCENT rather than `markRingIdle`. On a
                // schedule every unwatched aired row is a next step, so every one of them leads;
                // the episode list's "one accent ring in the column" rule is about a column of
                // episodes of ONE show, which this is not.
                // No numeral in the ring (26 Sep, "episode number for watch toggle is useless
                // duplication", owner): the row says "Episode 14" beside it.
                MarkRing(marked: committing,
                         style: .quiet,
                         lead: true,
                         episode: nil,
                         committing: committing,
                         label: batch ? "Mark \(Copy.episodes(count)) of \(title) as watched"
                                      : "Mark \(Copy.episode(episode)) of \(title) as watched",
                         markedLabel: Copy.Progress.episodeWatched(episode),
                         action: action)
            case .watched where canMark:
                // The disc UNDOES — the episode list's rule, and what the 20 Sep card's toggle did:
                // one tap marks this airing unwatched, and the exact count is confirmed first when
                // later episodes would go with it (`ScheduleView.toggleWatched`). Drawn inert, the
                // 25 Sep agenda left a mistaken mark with no way back on this screen ("Unable to
                // mark as unwatched… in the Schedule", owner).
                MarkRing(marked: true, style: .settled, episode: nil,
                         markedLabel: "Mark \(Copy.episode(episode)) of \(title) as unwatched",
                         action: action)
            case .watched:
                // A catalogue row (not in the library): the record, with nothing to undo.
                MarkRing(marked: true, style: .settled, episode: nil, action: {})
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            case .upcoming:
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .frame(width: 44)
    }
}

/// The directions' trailing slot (`Experience.doors`, 16 Oct): Schedule says WHEN and never marks
/// — the mark is Home's and the show page's. An aired row says "Out" (amber: the state "you can
/// watch it now"), a watched one wears a quiet tick, one still to come keeps the slot empty. The
/// row's tap opens the show on its episode, where the mark lives.
struct ScheduleOutMark: View {
    let state: AiringState

    var body: some View {
        Group {
            switch state {
            case .toWatch:
                Text(Copy.Schedule.outTag)
                    .type(ThemeType.scheduleCaps)
                    .textCase(.uppercase)
                    .foregroundStyle(ThemeColor.accent)
            case .watched:
                AppGlyph(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ThemeColor.textTertiary)
                    .accessibilityHidden(true)
            case .upcoming:
                Color.clear
            }
        }
        .frame(width: 44, height: 44)
    }
}

// The date RIDES THE ROW (7 Sep, kept by the 25 Sep rebuild — `ScheduleAgendaRow`). "The Schedule
// page looks good but it is ultra dense and extremely confusing" (user): measured then, six
// full-width day bands for five rows, ~40 % of the feed's height a banner introducing one row. The
// day is printed once, in its first row's date column, and a day's break is space. The 25 Sep
// spike's day headings made the same mistake again at 20 pt ("tonight still feels cluttered").

// MARK: - The date column

/// "WED" over "9" — the weekday in Schedule's caps, the numeral large and Regular. Today is accent,
/// the one rule this screen already follows for today. Empty on the second and later airings of a
/// day: the date is printed once and its rows stack under it, as every agenda does.
///
/// 16 Oct ("the way the font is being shown looks really cheapish", owner): the numeral was the
/// month grid's `feedDate` — SemiBold 18, a point bigger than the name beside it and as heavy, so
/// the margin read as a second name. Now `scheduleDate`, Regular 22: bigger, and plainly a
/// different KIND of thing — a calendar's margin. The pair is set close (no gap: Outfit's line box
/// already holds 0.26 em under the weekday and 0.30 em over the numeral) and sized so that, centred
/// on the face by its ink, the weekday's capitals stand level with the name's and the numeral's
/// foot with the caption's baseline. (The month grid keeps `feedDate`: its numerals live in 34-pt
/// discs.)
struct ScheduleDateColumn: View {
    let weekday: String?
    let numeral: String?
    let isToday: Bool
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    /// The weekday's capital height at the current text size (`ScheduleInkCentre`).
    @ScaledMetric(relativeTo: .caption2) private var capsCap: CGFloat = ScheduleTypeScale.caps * ScheduleTypeScale.capHeight

    /// Capped: uncapped it reaches ~70 pt at the accessibility sizes and eats the lane the names
    /// need.
    private static let width: CGFloat = 38
    private var w: CGFloat { min(Self.width * scale, Self.width + 16) }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if let weekday, let numeral {
                Text(weekday)
                    .type(ThemeType.scheduleCaps)
                    .textCase(.uppercase)
                    .foregroundStyle(isToday ? ThemeColor.accent : ThemeColor.textTertiary)
                Text(numeral)
                    .type(ThemeType.scheduleDate)
                    .foregroundStyle(isToday ? ThemeColor.accent : ThemeColor.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: w, alignment: .center)
        // An empty column (a day's later rows) has no capitals to centre by.
        .modifier(ScheduleInkCentre(capHeight: weekday == nil ? 0 : capsCap))
        .accessibilityHidden(true)
    }
}

// MARK: - The calendar

/// The month grid, behind the bar's calendar button.
///
/// At rest the screen has NO date chrome — the rows' dates are the calendar, which is what
/// animeschedule.net and Trakt v3 do. The grid is what the reader asks for, which is where
/// Fantastical (pull the DayTicker down) and Google Calendar (the month dropdown) both put it; it
/// is a TAP here rather than a pull because this screen already owns the pull gesture for refresh.
///
/// It OVERLAYS the feed rather than pushing it (Google Calendar's dropdown, not Fantastical's
/// inline expansion): 500 pt of grid inserted above a lazy stack shoved the reader's place three
/// screens down and back again on every toggle.
///
/// **The grid only answers for days the feed actually holds.** `AppModel.scheduleBack…scheduleAhead`
/// is a 22-day window; a month has thirty-odd. A cell outside the window used to be an ordinary
/// target that landed on "Nothing scheduled" — which is a lie, since the truth is that nothing is
/// KNOWN about 25 September. Those days are drawn quiet and are inert, and the month arrows stop
/// at the window's own months.
struct ScheduleMonthGrid: View {
    let todayNoon: Int64
    /// Day offset from today → how many airings that day carries.
    let counts: [Int: Int]
    /// Days with something still to come or still to watch.
    let live: Set<Int>
    let selected: Int
    /// The days the feed can actually answer for.
    let window: ClosedRange<Int>
    /// Days past the window that the feed's Later group lists — known too, since the feed draws
    /// them (review i3: October 19 was disabled "nothing known" on the day Later said Bleach).
    var extraDays: Set<Int> = []
    /// Which month is on screen, as a day offset from today of any day inside it.
    @Binding var monthAnchor: Int
    /// The tallest the panel may be — the feed's viewport, less the room the grid should not eat.
    /// A six-row month at the accessibility sizes is ~660 pt and the screen has ~650 to give.
    let maxHeight: CGFloat
    let onPick: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The numeral's disc, and the row's height with the dot under it.
    @ScaledMetric(relativeTo: .subheadline) private var scaledDisc: CGFloat = 34
    /// The height of everything above the weeks (the month row and the weekday letters), measured
    /// rather than assumed — both scale with Dynamic Type.
    @State private var headerH: CGFloat = 68

    private static let cal = Calendar(identifier: .gregorian)

    /// The disc scales with Dynamic Type up to the column it has to live in. Seven columns share
    /// ~353 pt, so a cell is ~50 wide; uncapped the disc reached ~78 at the accessibility sizes
    /// and seven of them forced the panel 180 pt wider than the screen — the arrows, Sunday and
    /// Saturday were all off the edges (captured 6 Sep). A grid's cell cannot be wider than a
    /// seventh of its grid, whatever the text size says.
    private var discSize: CGFloat { min(scaledDisc, 44) }

    /// A week's row: the numeral's disc, the gap, the dot.
    private var cellH: CGFloat { discSize + 3 + 6 }

    private func date(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: Double(todayNoon + Int64(offset) * Formatting.D) / 1000)
    }

    /// Offsets of the days drawn in the grid: the anchor month's days, preceded by blanks for the
    /// weekdays before the 1st. Sunday-first, stated by the app rather than read from the device's
    /// region, which resolves to Monday in much of the world (the user's rule, 6 Sep: "the mental
    /// model for anyone in general").
    private var slots: [Int?] {
        let cal = Self.cal
        let anchor = date(monthAnchor)
        guard let range = cal.range(of: .day, in: .month, for: anchor),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: anchor))
        else { return [] }
        // `.weekday` is 1 = Sunday … 7 = Saturday, so the lead-in is weekday − 1.
        let lead = cal.component(.weekday, from: first) - 1
        let firstOffset = cal.dateComponents([.day], from: cal.startOfDay(for: date(0)),
                                             to: cal.startOfDay(for: first)).day ?? 0
        return Array(repeating: nil, count: lead) + range.map { firstOffset + $0 - 1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: ThemeSpace.x2) {
                header
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        // Sunday-first: column 0 is Sunday whatever the device's region says.
                        Text(Formatting.weekdayLetterMonFirst((col + 6) % 7))
                            .type(ThemeType.feedEyebrow)
                            .textCase(.uppercase)
                            .foregroundStyle(ThemeColor.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, ThemeSpace.x1)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { if $0 > 0 { headerH = $0 } }
            let cells = slots
            let weekRows = (cells.count + 6) / 7
            // A `ScrollView` is GREEDY — it takes every point it is offered, and a `maxHeight` on
            // it or on the panel let it pad the surface out to the cap and centre the month inside
            // a hand's width of nothing. Its height is STATED: the weeks it has, or as much of them
            // as the screen can give, whichever is less.
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(0..<weekRows, id: \.self) { row in
                        // THE WEEK SEPARATOR (user, 6 Sep: "a visual cue for week separation is
                        // also necessary to avoid confusion"). Five rows of loose numerals in one
                        // field have nothing telling the eye where a week ends, so a date and the
                        // date below it read as neighbours. A hairline rule above each row but the
                        // first is what every month grid on the platform draws, and it is the
                        // lightest mark that can do it — `hairline` is white at 0.055.
                        if row > 0 {
                            Rectangle()
                                .fill(ThemeColor.hairline)
                                .frame(height: 1)
                                .padding(.horizontal, ThemeSpace.x1)
                        }
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { col in
                                let i = row * 7 + col
                                if i < cells.count, let offset = cells[i] {
                                    cell(offset)
                                } else {
                                    Color.clear.frame(maxWidth: .infinity).frame(height: cellH)
                                }
                            }
                        }
                        .padding(.vertical, ThemeSpace.x1)
                    }
                }
            }
            .frame(height: min(naturalWeeksH(weekRows), weeksBudget))
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, ThemeSpace.x2)
        .padding(.vertical, ThemeSpace.x3)
    }

    /// The weeks at their natural height — every row drawn, nothing scrolling. A row is the cells
    /// plus their padding, and every row but the first carries a 1-pt rule.
    private func naturalWeeksH(_ rows: Int) -> CGFloat {
        let row = cellH + ThemeSpace.x1 * 2
        return CGFloat(rows) * row + CGFloat(max(0, rows - 1))
    }

    /// What is left for the weeks once the month row, the weekday letters and the panel's own
    /// padding have taken theirs. A six-row month at the accessibility sizes wants more than the
    /// screen has to give, and this is what makes it scroll instead of running under the tab bar.
    private var weeksBudget: CGFloat {
        max(120, maxHeight - headerH - ThemeSpace.x3 * 2)
    }

    /// "September 2026" — the month NAMED, in the app's emphasis body, not an 11-pt grey eyebrow.
    /// A calendar's month is the one thing on the panel that says where you are.
    private var header: some View {
        HStack(spacing: 0) {
            arrow("chevron.left", step: -1, label: Copy.Schedule.previousMonth)
            Spacer(minLength: 0)
            Text(Formatting.fmtMonthNameYear(todayNoon + Int64(monthAnchor) * Formatting.D))
                .type(ThemeType.bodyEmphasis)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            arrow("chevron.right", step: 1, label: Copy.Schedule.nextMonth)
        }
    }

    /// A month arrow, live only while the window reaches into the month it would show. Past the
    /// horizon there is nothing to page to, and an arrow that pages to a blank month is an
    /// invitation to keep pressing it.
    private func arrow(_ glyph: String, step: Int, label: String) -> some View {
        let target = monthOffset(by: step)
        let reachable = target.map { monthIntersectsWindow($0) } ?? false
        return Button {
            guard let target else { return }
            withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                monthAnchor = target
            }
        } label: {
            AppGlyph(systemName: glyph).font(.system(size: 15, weight: .semibold))
        }
        .frame(width: 44, height: 34)
        .tint(ThemeColor.interactive)
        .disabled(!reachable)
        .opacity(reachable ? 1 : 0.25)
        .accessibilityLabel(label)
    }

    private func monthOffset(by step: Int) -> Int? {
        let cal = Self.cal
        guard let next = cal.date(byAdding: .month, value: step, to: date(monthAnchor)) else { return nil }
        return cal.dateComponents([.day], from: cal.startOfDay(for: date(0)),
                                  to: cal.startOfDay(for: next)).day
    }

    /// Does the month containing `offset` hold any day the feed can answer for?
    private func monthIntersectsWindow(_ offset: Int) -> Bool {
        let cal = Self.cal
        let anchor = date(offset)
        guard let range = cal.range(of: .day, in: .month, for: anchor),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: anchor)),
              let firstOffset = cal.dateComponents([.day], from: cal.startOfDay(for: date(0)),
                                                   to: cal.startOfDay(for: first)).day
        else { return false }
        let last = firstOffset + range.count - 1
        return (firstOffset <= window.upperBound && last >= window.lowerBound)
            || extraDays.contains { $0 >= firstOffset && $0 <= last }
    }

    /// One day. Apple Calendar's anatomy, which is the one every reader already knows: the numeral
    /// in a disc that fills when the day is SELECTED, today's numeral in the accent, and the day's
    /// content as a dot beneath. Every numeral is the same weight and size — TONE carries the
    /// hierarchy, as it does everywhere else in the app — because a grid of mixed weights reads as
    /// a grid of mistakes.
    private func cell(_ offset: Int) -> some View {
        let ts = todayNoon + Int64(offset) * Formatting.D
        let isToday = offset == 0
        let isSelected = offset == selected
        let known = window.contains(offset) || extraDays.contains(offset)
        let n = counts[offset] ?? 0
        return Button {
            onPick(offset)
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    if isSelected {
                        Circle().fill(ThemeColor.surfaceFloating)
                    }
                    Text("\(Formatting.localParts(ts).d)")
                        .type(ThemeType.feedDate)
                        .foregroundStyle(numeralInk(isToday: isToday, hasContent: n > 0))
                        // The numeral gives way inside the capped disc rather than pushing it.
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: discSize, height: discSize)
                // The day's content: amber while something on it is still to come or still to
                // watch, quiet once it is spent, nothing at all where there is none.
                Circle()
                    .fill(n == 0 ? .clear
                          : (live.contains(offset) ? ThemeColor.accent : ThemeColor.textTertiary))
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: cellH)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalendarCellPressStyle())
        // Outside the feed's window there is no answer to give: the day is drawn as context and
        // does not take a tap. "Nothing scheduled" would claim knowledge the app does not have.
        .disabled(!known)
        .opacity(known ? 1 : 0.4)
        .accessibilityLabel(Date(timeIntervalSince1970: Double(ts) / 1000)
            .formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(!known ? Copy.Schedule.beyondHorizon
                            : (n > 0 ? Copy.episodes(n) : Copy.Schedule.noEpisodes))
    }

    private func numeralInk(isToday: Bool, hasContent: Bool) -> Color {
        if isToday { return ThemeColor.accent }
        return hasContent ? ThemeColor.textPrimary : ThemeColor.textSecondary
    }
}

/// A calendar cell's press feedback: the app's compression floor and a dip, nothing painted.
struct CalendarCellPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.985 : 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(ThemeMotion.pick(ThemeMotion.uiPress, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}

// MARK: - The week strip (19 Oct)

/// THE TOP CALENDAR, as a WEEK (19 Oct: "In schedule I'd like to see a top calendar too right which
/// works in sync with the list scroll and vice-versa", owner): Apple Calendar's week row under the
/// title — the weekday's letter over the numeral, today's in the accent, the day at the top of the
/// list in a filled disc, and a dot under each day that carries something (amber while something on
/// it is still to come or to watch). It is ALWAYS the week of the day the list is showing, so it can
/// never point at days the reader is not looking at — the defect that took the day rail out on
/// 6 Sep, whose capsules had scrolled away from the feed they named. Two ways in, both the list's:
/// a tap on a day scrolls the list to it, and a swipe across the strip goes to the next or previous
/// week and takes the list to that week's first day with something on it. The month grid stays
/// behind the bar's calendar glyph for anything further.
///
/// Sunday-first, as the month grid is ("the mental model for anyone in general", 6 Sep). Days
/// outside the window the list can answer for are drawn as context and take no tap.
struct ScheduleWeekStrip: View {
    let todayNoon: Int64
    /// Day offset from today → how many airings that day carries.
    let counts: [Int: Int]
    /// Days with something still to come or still to watch.
    let live: Set<Int>
    /// The day at the top of the list.
    let selected: Int
    /// The days the list can answer for.
    let window: ClosedRange<Int>
    /// Days past the window that the list's Later group lists — known too: the strip follows the
    /// list onto them, as the month grid does (`ScheduleMonthGrid.extraDays`).
    var extraDays: Set<Int> = []
    let onPick: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var scaledDisc: CGFloat = 34
    /// The week on screen; it follows `selected` on the strip's own animation, so a new week slides
    /// in from the side it lies on.
    @State private var shown: Int?
    @State private var forward = true

    /// Seven columns share the gutter's width: the disc can never be wider than a seventh of it.
    private var disc: CGFloat { min(scaledDisc, 44) }

    /// Today's weekday, Sunday = 0.
    private var todayColumn: Int { Formatting.localParts(todayNoon).wd }

    /// The week a day falls in, counted from the week holding today.
    private func week(of offset: Int) -> Int {
        let n = offset + todayColumn
        return n >= 0 ? n / 7 : -((-n + 6) / 7)
    }

    private func offset(week: Int, column: Int) -> Int { week * 7 + column - todayColumn }

    private func known(_ offset: Int) -> Bool { window.contains(offset) || extraDays.contains(offset) }

    var body: some View {
        let w = shown ?? week(of: selected)
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { col in
                cell(offset(week: w, column: col), column: col)
            }
        }
        .id(w)
        .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        // A swipe is a WEEK, the platform's way: the list goes to it.
        .gesture(DragGesture(minimumDistance: 16).onEnded { g in
            guard abs(g.translation.width) > max(36, abs(g.translation.height)) else { return }
            go(by: g.translation.width < 0 ? 1 : -1)
        })
        .onChange(of: selected, initial: true) { _, day in
            let next = week(of: day)
            guard next != shown else { return }
            guard let current = shown else { shown = next; return }
            forward = next > current
            withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) { shown = next }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Schedule.week)
        .accessibilityAction(named: Copy.Schedule.nextWeek) { go(by: 1) }
        .accessibilityAction(named: Copy.Schedule.previousWeek) { go(by: -1) }
    }

    /// The next or previous week, if the window reaches it: the list goes to its first day with
    /// something on it — or, with nothing, its first day the list can answer for, which then says
    /// "Nothing scheduled".
    private func go(by step: Int) {
        // Past the window the weeks are sparse (a Later day here and there): the swipe goes to the
        // next week that holds a day the list can show, never to a week of disabled days.
        let last = week(of: max(window.upperBound, extraDays.max() ?? window.upperBound))
        let first = week(of: window.lowerBound)
        var target = (shown ?? week(of: selected)) + step
        while target >= first && target <= last {
            let days = (0..<7).map { offset(week: target, column: $0) }.filter(known)
            if let day = days.first(where: { (counts[$0] ?? 0) > 0 }) ?? days.first {
                onPick(day)
                return
            }
            target += step
        }
    }

    /// One day: Apple Calendar's anatomy, the month grid's ink (`ScheduleMonthGrid.cell`).
    private func cell(_ offset: Int, column: Int) -> some View {
        let ts = todayNoon + Int64(offset) * Formatting.D
        let isToday = offset == 0
        let isSelected = offset == selected
        let known = known(offset)
        let n = counts[offset] ?? 0
        return Button {
            onPick(offset)
        } label: {
            VStack(spacing: 4) {
                Text(Formatting.weekdayLetter(column))
                    .type(ThemeType.scheduleCaps)
                    .textCase(.uppercase)
                    .foregroundStyle(isToday ? ThemeColor.accent : ThemeColor.textTertiary)
                ZStack {
                    if isSelected {
                        Circle().fill(isToday ? ThemeColor.accent : ThemeColor.textPrimary)
                    }
                    Text("\(Formatting.localParts(ts).d)")
                        .type(ThemeType.feedDate)
                        .foregroundStyle(numeralInk(isToday: isToday, isSelected: isSelected, hasContent: n > 0))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: disc, height: disc)
                .animation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion), value: isSelected)
                Circle()
                    .fill(n == 0 ? .clear : (live.contains(offset) ? ThemeColor.accent : ThemeColor.textTertiary))
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, ThemeSpace.x1)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalendarCellPressStyle())
        .disabled(!known)
        .opacity(known ? 1 : 0.3)
        .accessibilityLabel(Date(timeIntervalSince1970: Double(ts) / 1000)
            .formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(!known ? Copy.Schedule.beyondHorizon
                            : (n > 0 ? Copy.episodes(n) : Copy.Schedule.noEpisodes))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func numeralInk(isToday: Bool, isSelected: Bool, hasContent: Bool) -> Color {
        if isSelected { return isToday ? ThemeColor.onAccent : ThemeColor.canvas }
        if isToday { return ThemeColor.accent }
        return hasContent ? ThemeColor.textPrimary : ThemeColor.textSecondary
    }
}
