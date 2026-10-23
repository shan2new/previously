import Foundation

// Time/date formatting. Timestamps are milliseconds since epoch (Int64), matching the API
// contract; the conversion to/from `Date` happens at the networking layer.
//
// TWO CALENDARS, not one. Every helper below takes a `TimeAnchor` (defaulting to `.local`, the
// old behaviour) saying which calendar a timestamp must be read in:
//
//   • `.local`   — a real instant. AniList dates episodes to the minute, so its timestamps carry a
//                  genuine broadcast moment and are read in TimeZone.current.
//   • `.utcDate` — a DATE-ONLY fact. TMDB ships air dates with no clock and the server synthesizes
//                  them at 17:00 UTC (docs/api-contract.md), so the only true part of the
//                  timestamp is its UTC calendar day. Breaking it down locally pushes every
//                  timezone east of UTC+7 one day forward — a Sunday drop read "Monday" in JST.
//
// Two consequences the anchor enforces rather than documents:
//   (a) day labels, day diffs and day bucketing use the timestamp's OWN calendar day;
//   (b) a `.utcDate` timestamp NEVER yields a clock time or an hour-precision countdown —
//       `fmtTime` returns "" and `fmtCountdown` degrades to day precision.
//
// All human-facing month/weekday names and clock times come from DateFormatter, never from
// hand-built tables: a device set to 24-Hour Time must read "21:00", not "9:00 PM".

enum Formatting {
    // Millisecond constants mirroring format.ts (D = 86400e3, H = 3600e3).
    static let D: Int64 = 86_400_000
    static let H: Int64 = 3_600_000
    static let minuteMs: Int64 = 60_000

    static var tz: TimeZone { TimeZone.current }

    /// Which calendar a timestamp's day (and clock, if it has one) must be read in.
    /// Take it from the show (`Franchise.timeAnchor`, which knows a TV show at broadcast times), else
    /// from a `MediaSource` (`source.timeAnchor`, Models.swift) — never guess.
    enum TimeAnchor: Hashable, Sendable {
        /// A real instant: device-local calendar and clock.
        case local
        /// A date-only fact carried as a synthesized 17:00 UTC instant — only its UTC day is real.
        case utcDate

        /// True when the timestamp has no meaningful clock, only a day.
        var isDateOnly: Bool { self == .utcDate }

        var timeZone: TimeZone {
            switch self {
            case .local: return TimeZone.current
            case .utcDate: return TimeZone(secondsFromGMT: 0) ?? TimeZone.current
            }
        }
    }

    // MARK: - Calendar / parts

    /// Two calendars, built ONCE per (time zone, locale) and reused.
    ///
    /// `localParts` used to construct a `Calendar` on every call — 2.2 µs each on a Mac, and the
    /// Schedule feed called it 22 days × 2 passes × every airing show × ~30 times per render. A
    /// cached calendar is 0.65 µs, and the cache re-keys itself when the device's zone or locale
    /// changes so a travelling user never keeps yesterday's calendar.
    private final class CalendarStore: @unchecked Sendable {
        private let lock = NSLock()
        private var local: Calendar?
        private var utc: Calendar?
        private var stamp = ""

        func calendar(_ anchor: TimeAnchor) -> Calendar {
            lock.lock()
            defer { lock.unlock() }
            let current = "\(TimeZone.current.identifier)|\(Locale.current.identifier)"
            if current != stamp { local = nil; utc = nil; stamp = current }
            switch anchor {
            case .local:
                if let local { return local }
                let cal = Self.make(anchor); local = cal; return cal
            case .utcDate:
                if let utc { return utc }
                let cal = Self.make(anchor); utc = cal; return cal
            }
        }

        private static func make(_ anchor: TimeAnchor) -> Calendar {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = anchor.timeZone
            cal.locale = Locale.current
            return cal
        }
    }

    private static let calendars = CalendarStore()

    private static func calendar(_ anchor: TimeAnchor) -> Calendar {
        calendars.calendar(anchor)
    }

    private static func date(_ ts: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ts) / 1000.0)
    }

    struct LocalParts {
        var y: Int
        var mo: Int // 1-12
        var d: Int
        var hour: Int // 0-23
        var minute: Int
        var wd: Int // 0=Sun .. 6=Sat
    }

    /// Break a ms-epoch timestamp into calendar/clock parts, read in `anchor`'s calendar.
    /// `hour`/`minute` are only meaningful for `.local` — a `.utcDate` timestamp always reports
    /// the synthesized 17:00 and must never be shown or thresholded on.
    static func localParts(_ ts: Int64, anchor: TimeAnchor = .local) -> LocalParts {
        let c = calendar(anchor).dateComponents([.year, .month, .day, .hour, .minute, .weekday],
                                                from: date(ts))
        // Calendar.weekday is 1=Sunday..7=Saturday; we use 0=Sun..6=Sat.
        return LocalParts(
            y: c.year ?? 0,
            mo: c.month ?? 1,
            d: c.day ?? 1,
            hour: c.hour ?? 0,
            minute: c.minute ?? 0,
            wd: ((c.weekday ?? 1) - 1)
        )
    }

    /// A UTC instant marking midnight of the calendar day containing `ts`, read in `anchor`.
    /// Normalized into one shared space so day keys are comparable across anchors: the key of a
    /// TMDB date-only timestamp (its UTC day) subtracts cleanly from the key of "now" (local day).
    static func localDayKey(_ ts: Int64, anchor: TimeAnchor = .local) -> Int64 {
        let p = localParts(ts, anchor: anchor)
        return utcTimestamp(y: p.y, mo: p.mo, d: p.d) ?? 0
    }

    /// Midnight-UTC ms-epoch for a bare (y, mo, d) triple — the day-key builder.
    static func utcTimestamp(y: Int, mo: Int, d: Int) -> Int64? {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d
        guard let date = calendar(.utcDate).date(from: c) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Monday-first weekday index (0=Mon .. 6=Sun).
    static func localMondayCol(_ ts: Int64, anchor: TimeAnchor = .local) -> Int {
        (localParts(ts, anchor: anchor).wd + 6) % 7
    }

    // MARK: - Locale-aware formatters
    //
    // DateFormatter is expensive to build, so formatters are cached per (skeleton, time zone) and
    // dropped wholesale whenever the locale, its hour cycle (the 24-Hour Time switch) or the
    // system time zone changes — a cached formatter would otherwise keep printing "9:00 PM" after
    // the user flips the setting.
    private final class FormatterStore: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: DateFormatter] = [:]
        private var stamp = ""

        /// `skeleton` is a Unicode date-format template ("MMMd"); the empty string means the
        /// locale's SHORT TIME style, which is what honours the 24-Hour Time setting.
        func formatter(_ skeleton: String, _ timeZone: TimeZone) -> DateFormatter {
            lock.lock()
            defer { lock.unlock() }

            let locale = Locale.current
            let current = "\(locale.identifier)|\(locale.hourCycle)|\(TimeZone.current.identifier)"
            if current != stamp {
                cache.removeAll()
                stamp = current
            }

            let key = "\(skeleton)|\(timeZone.identifier)"
            if let cached = cache[key] { return cached }

            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            if skeleton.isEmpty {
                f.dateStyle = .none
                f.timeStyle = .short
            } else {
                f.setLocalizedDateFormatFromTemplate(skeleton)
            }
            cache[key] = f
            return f
        }
    }

    private static let formatters = FormatterStore()

    private static func formatter(_ skeleton: String, _ anchor: TimeAnchor) -> DateFormatter {
        formatters.formatter(skeleton, anchor.timeZone)
    }

    private static func string(_ ts: Int64, _ skeleton: String, _ anchor: TimeAnchor) -> String {
        formatter(skeleton, anchor).string(from: date(ts))
    }

    /// `ts` formatted from a Unicode date-format TEMPLATE ("dMMM", "EEEEdMMMM") in `anchor`'s
    /// calendar, through the cached, locale-aware formatters — never a `DateFormatter` built per call
    /// (the spike's `FeedTime.format` built one per stamp, per row, per body). The template orders
    /// and punctuates itself per locale ("3 Oct" / "Oct 3"). An empty template is the locale's short
    /// time, which a `.utcDate` timestamp must never be asked for (its clock is synthesized).
    static func formatted(_ ts: Int64, skeleton: String, anchor: TimeAnchor) -> String {
        string(ts, skeleton, anchor)
    }

    // Weekday/month NAMES depend on the locale only, never the time zone, so they always come off
    // the local formatter regardless of the anchor the day itself was computed in.
    static func weekdayShort(_ wd: Int) -> String {
        let symbols = formatter("EEEE", .local).shortStandaloneWeekdaySymbols ?? []
        return symbols.indices.contains(wd) ? symbols[wd] : ""
    }

    /// "W" for a Sunday-first weekday index — the locale's own one-letter form.
    static func weekdayLetter(_ wd: Int) -> String {
        let symbols = formatter("EEEE", .local).veryShortStandaloneWeekdaySymbols ?? []
        return symbols.indices.contains(wd) ? symbols[wd] : ""
    }

    /// "Wed" for a Monday-first column (the day strip's and the day header's calendar).
    static func weekdayShortMonFirst(_ col: Int) -> String { weekdayShort((col + 1) % 7) }

    /// "W" for a Monday-first column — the locale's own one-letter form, not the first
    /// character of a name that has no reason to be Latin.
    static func weekdayLetterMonFirst(_ col: Int) -> String {
        let symbols = formatter("EEEE", .local).veryShortStandaloneWeekdaySymbols ?? []
        let wd = (col + 1) % 7
        return symbols.indices.contains(wd) ? symbols[wd] : ""
    }

    static func weekdayFull(_ wd: Int) -> String {
        let symbols = formatter("EEEE", .local).standaloneWeekdaySymbols ?? []
        return symbols.indices.contains(wd) ? symbols[wd] : ""
    }

    // MARK: - Countdown / clock (hour precision — `.local` only)

    /// Minute-precise wait ("2d 4h" / "31m" / "now"). A `.utcDate` timestamp has no clock to count
    /// down to, so it degrades to the day-precision span instead of inventing hours.
    static func fmtCountdown(target: Int64, now: Int64, anchor: TimeAnchor = .local) -> String {
        if anchor.isDateOnly { return fmtRelSpanShort(ts: target, now: now, anchor: anchor) }
        var s = max(0, target - now)
        if s < minuteMs { return "now" }
        let d = s / D
        s -= d * D
        let h = s / H
        s -= h * H
        let m = s / minuteMs
        // A zero unit is dropped: "in 1h", not "in 1h 0m" (the hero's fact line, 4 Sep).
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// Locale-correct clock time ("9:00 PM", or "21:00" on a 24-hour device).
    /// Empty for a `.utcDate` timestamp: its clock is synthesized, so there is no time to print.
    static func fmtTime(_ ts: Int64, anchor: TimeAnchor = .local) -> String {
        guard !anchor.isDateOnly else { return "" }
        return string(ts, "", anchor)
    }

    /// Elapsed time since `ts`. Minute/hour precision for a real instant; a `.utcDate` timestamp
    /// degrades to whole days ("today" / "3d ago") because its hours are fabricated.
    static func fmtAgo(ts: Int64, now: Int64, anchor: TimeAnchor = .local) -> String {
        if anchor.isDateOnly {
            let d = -dayDiff(ts: ts, now: now, anchor: anchor)
            return d <= 0 ? "today" : "\(d)d ago"
        }
        let s = max(0, now - ts)
        let m = s / minuteMs
        if m < 1 { return "just now" }
        if m < 60 { return "\(m)m ago" }
        // Rounded, like `TemporalCopy.aired`: 1 h 55 min is "2h ago", not "1h ago".
        let h = max(1, Int((Double(m) / 60).rounded()))
        if h < 24 { return "\(h)h ago" }
        return "\(h / 24)d ago"
    }

    // MARK: - Day words / day spans

    /// Whole-DAY difference between two instants: 0 = same day, +1 = tomorrow, −1 = yesterday.
    /// `ts` is read in `anchor`'s calendar; `now` is always the device's local day (it *is* a real
    /// instant). The single definition every day-word/day-span helper below is built on.
    static func dayDiff(ts: Int64, now: Int64, anchor: TimeAnchor = .local) -> Int {
        let a = localDayKey(ts, anchor: anchor)
        let b = localDayKey(now, anchor: .local)
        return Int((Double(a - b) / Double(D)).rounded())
    }

    /// "Today" / "Tomorrow" / "Yesterday" / short weekday.
    static func fmtDay(ts: Int64, now: Int64, anchor: TimeAnchor = .local) -> String {
        let diff = dayDiff(ts: ts, now: now, anchor: anchor)
        if diff == 0 { return "Today" }
        if diff == 1 { return "Tomorrow" }
        if diff == -1 { return "Yesterday" }
        return weekdayShort(localParts(ts, anchor: anchor).wd)
    }

    /// Day-only ("date, not time") word: Today / Tomorrow / Yesterday / <full weekday> within a
    /// week, else "Mon D" ("May 4"). The long-weekday sibling of `fmtDay`, and the only day label
    /// a date-only (TV) release should ever use.
    static func fmtDayLong(ts: Int64, now: Int64, anchor: TimeAnchor = .local) -> String {
        let diff = dayDiff(ts: ts, now: now, anchor: anchor)
        if diff == 0 { return "Today" }
        if diff == 1 { return "Tomorrow" }
        if diff == -1 { return "Yesterday" }
        if diff > 1 && diff < 7 { return weekdayFull(localParts(ts, anchor: anchor).wd) }
        // The past week by name too — "Aired Tuesday", "Since Monday", as the ladder documents:
        // two days ago printed "Aired 22 Sep" (review i3). Messages dates the past week the same way.
        if diff < -1 && diff > -7 { return weekdayFull(localParts(ts, anchor: anchor).wd) }
        return fmtMonthDay(ts, anchor: anchor)
    }

    /// The one "when does this land" label. Anime gets day + clock ("Tomorrow 9:00 PM"); a
    /// date-only release gets a day word alone ("Tomorrow" / "Thursday" / "May 4").
    static func fmtWhen(ts: Int64, now: Int64, anchor: TimeAnchor = .local) -> String {
        if anchor.isDateOnly { return fmtDayLong(ts: ts, now: now, anchor: anchor) }
        return "\(fmtDay(ts: ts, now: now, anchor: anchor)) \(fmtTime(ts, anchor: anchor))"
    }

    /// Relative day/week/month span for date-only releases — day precision only, never minutes:
    /// "today" / "in 3d" / "in 2wk" / "in 2mo". The TV analogue of the anime `fmtCountdown`.
    /// Empty for a date already in the past: there is no span left to count down.
    static func fmtRelSpan(ts: Int64, now: Int64, anchor: TimeAnchor = .local) -> String {
        let short = fmtRelSpanShort(ts: ts, now: now, anchor: anchor)
        if short.isEmpty || short == "today" { return short }
        return "in \(short)"
    }

    /// Bare day-precision span with no "in " prefix — "today" / "1d" / "3d" / "2wk" / "2mo".
    /// For trailing accents that supply their own context.
    ///
    /// A date in the PAST returns "" rather than "today". These spans describe a wait, and a
    /// timestamp we've already passed describes none — a stale `nextAiringAt` that the source
    /// hasn't advanced yet used to render as a permanent "today" (a week-old Saturday slot read
    /// "Sat · today" every day since). Callers treat "" as "nothing to say".
    static func fmtRelSpanShort(ts: Int64, now: Int64, anchor: TimeAnchor = .local) -> String {
        let d = dayDiff(ts: ts, now: now, anchor: anchor)
        if d < 0 { return "" }
        if d == 0 { return "today" }
        if d < 7 { return "\(d)d" }
        if d < 30 { return "\((d + 3) / 7)wk" }
        return "\(max(1, (d + 15) / 30))mo"
    }

    /// A compact two-line date badge for a date-only (TV) release: (top day/date, bottom relative
    /// span) — e.g. ("Sun","in 4d"), ("May 4","2wk"), ("Today","today").
    static func fmtDayBadge(ts: Int64, now: Int64, anchor: TimeAnchor = .local) -> (top: String, bottom: String) {
        let diff = dayDiff(ts: ts, now: now, anchor: anchor)
        // Past dates have no countdown to give — "Jul 29 / today" would be a lie.
        if diff < 0 { return ("Aired", fmtMonthDay(ts, anchor: anchor)) }
        let top: String
        if diff == 0 { top = "Today" }
        else if diff == 1 { top = "Tomorrow" }
        else if diff > 1 && diff < 7 { top = weekdayShort(localParts(ts, anchor: anchor).wd) }
        else { top = fmtMonthDay(ts, anchor: anchor) }
        return (top, fmtRelSpan(ts: ts, now: now, anchor: anchor))
    }

    // MARK: - Dates

    /// "May 4" — locale-ordered (a device set to en_GB reads "4 May").
    static func fmtMonthDay(_ ts: Int64, anchor: TimeAnchor = .local) -> String {
        string(ts, "MMMd", anchor)
    }

    /// "Jun 24, 2026" — a year-qualified date, used for premieres that can be far in the future.
    static func fmtFullDate(_ ts: Int64, anchor: TimeAnchor = .local) -> String {
        string(ts, "MMMdyyyy", anchor)
    }

    /// "Oct 2026" — a month-precision date: Library's Returning captions and its month headers.
    static func fmtMonthYear(_ ts: Int64, anchor: TimeAnchor = .local) -> String {
        string(ts, "MMMyyyy", anchor)
    }

    /// "September 2026" — the month NAMED, for a calendar's own header, where the month is the one
    /// fact the panel exists to state. `fmtMonthYear`'s "SEP 2026" is a caption's abbreviation.
    static func fmtMonthNameYear(_ ts: Int64, anchor: TimeAnchor = .local) -> String {
        // "MMMMy", matching Android: ICU's best-pattern lookup there answers the four-y skeleton
        // with a pattern that has no separator ("September2026"), and one skeleton across the two
        // platforms is the only way that stays true.
        string(ts, "MMMMy", anchor)
    }

    /// Prettify a curated release string from FranchiseUpcoming. A bare ISO date or year-month
    /// becomes a friendly label ("2026-07-05" -> "Jul 5, 2026", "2026-10" -> "Oct 2026");
    /// anything else (already-human windows like "October 2026", "2027", "TBA") passes through.
    /// Parsed as a bare calendar date, so it is formatted in UTC and never shifts a day.
    static func prettyReleaseString(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: "-").map(String.init)
        guard parts.count >= 2, let y = Int(parts[0]), let m = Int(parts[1]),
              (1000...9999).contains(y), (1...12).contains(m) else { return s }
        if parts.count >= 3, let d = Int(parts[2]), (1...31).contains(d),
           let ts = utcTimestamp(y: y, mo: m, d: d) {
            return fmtFullDate(ts, anchor: .utcDate)
        }
        if parts.count == 2, let ts = utcTimestamp(y: y, mo: m, d: 1) {
            return string(ts, "MMMyyyy", .utcDate)
        }
        return s
    }

    /// "Sunday, July 19" — the device's own today, so always local.
    static func fmtTodayDate(_ now: Int64) -> String {
        string(now, "EEEEMMMMd", .local)
    }

    /// Short-month "today" line for the Today header: "Sunday, Jul 19".
    static func fmtTodayDateShort(_ now: Int64) -> String {
        string(now, "EEEEMMMd", .local)
    }

    /// The app's single definition of when "tonight"/"evening" starts, shared by the greeting,
    /// Library's day-part label, and Schedule's hero eyebrow.
    static func isEvening(hour: Int) -> Bool { hour >= 18 }

    static func greetingFor(_ now: Int64) -> String {
        let h = localParts(now, anchor: .local).hour
        if h < 5 { return "Late night" }
        if h < 12 { return "Good morning" }
        if !isEvening(hour: h) { return "Good afternoon" }
        return "Good evening"
    }

    /// col 0=Mon .. 6=Sun
    static func weekdayNameMonFirst(_ col: Int) -> String {
        weekdayFull((col + 1) % 7)
    }

    // MARK: - Text

    /// Strip HTML tags and decode entities from a synopsis. Returns the FULL cleaned text —
    /// visual clamping (lineLimit + "Read more") is the view's job, not a data-layer truncation.
    static func stripHtml(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = decodeHtmlEntities(noTags)
        let collapsed = decoded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode the HTML entities that actually occur in AniList descriptions: numeric forms and
    /// the common named ones. `&amp;` is decoded LAST so `&amp;lt;` yields `&lt;`, not `<`.
    static func decodeHtmlEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = decodeNumericEntities(s)
        let named: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
            ("&nbsp;", " "), ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"),
            ("&hellip;", "\u{2026}"), ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
            ("&amp;", "&"),  // must stay last
        ]
        for (entity, char) in named {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }

    private static let numericEntityRegex = try! NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);")

    /// Decode `&#8217;` / `&#x2019;` style numeric character references.
    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in numericEntityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let code = ns.substring(with: m.range(at: 1))
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let value, let scalar = Unicode.Scalar(value) {
                out.append(Character(scalar))
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

// MARK: - Current "now" helper

extension Int64 {
    /// Current wall-clock time in ms since epoch.
    static var nowMs: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}
