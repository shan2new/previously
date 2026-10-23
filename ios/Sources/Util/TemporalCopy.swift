import Foundation

// One temporal expression per item (spec board 03/09). Exact instants (AniList, and TV at real
// broadcast times) get a clock; date-only releases (TMDB's dates) get a day word; unknown says unknown. Evaluated in the user's current
// calendar; precedence for the past is top-down: relative → same calendar day → yesterday → weekday → date.
enum TemporalCopy {
    /// "Airs in 27 min" · "Today at 8:30 PM" · "Tomorrow at 8:30 PM" · "Friday at 8:30 PM" ·
    /// "Aug 28 at 8:30 PM" · "Aug 28, 2027 at 8:30 PM" — or for date-only: "Today" · "Tomorrow" ·
    /// "Friday" · "Aug 28" · "Aug 28, 2027".
    static func airs(at ts: Int64, now: Int64, anchor: Formatting.TimeAnchor) -> String {
        let delta = ts - now
        if !anchor.isDateOnly {
            if delta < 60 * Formatting.minuteMs && delta > 0 {
                return "Airs in \(max(1, Int(delta / Formatting.minuteMs))) min"
            }
            let time = Formatting.fmtTime(ts, anchor: anchor)
            switch Formatting.dayDiff(ts: ts, now: now, anchor: anchor) {
            case 0: return "Today at \(time)"
            case 1: return "Tomorrow at \(time)"
            case 2...6: return "\(Formatting.fmtDayLong(ts: ts, now: now, anchor: anchor)) at \(time)"
            default: return "\(dateWord(ts, now: now, anchor: anchor)) at \(time)"
            }
        }
        switch Formatting.dayDiff(ts: ts, now: now, anchor: anchor) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return Formatting.fmtDayLong(ts: ts, now: now, anchor: anchor)
        default: return dateWord(ts, now: now, anchor: anchor)
        }
    }

    /// `airs` as a sentence with its verb, for a line that stands alone under an episode's name:
    /// "Airs today at 8:30 PM" · "Airs Friday at 8:30 PM" · "Airs 30 Sep at 6:30 PM" · "Airs in
    /// 27 min". A bare "30 Sep at 6:30 PM" under "Aired 16 Sep" and "Aired today" read as a
    /// fragment (review, 23 Sep).
    static func airsSentence(at ts: Int64, now: Int64, anchor: Formatting.TimeAnchor) -> String {
        let bare = airs(at: ts, now: now, anchor: anchor)
        if bare.hasPrefix("Airs ") { return bare }
        for word in ["Today", "Tomorrow"] where bare.hasPrefix(word) {
            return "Airs " + word.lowercased() + bare.dropFirst(word.count)
        }
        return "Airs " + bare
    }

    /// Compact form for narrow captions: "Today" · "Tomorrow" · "Wednesday" · "Aug 28".
    ///
    /// **The compact form drops the CLOCK. It never drops the day word or a preposition.**
    ///
    /// It used to drop both: one frame of Detail showed "Tomorrow at 8:30 PM" (`airs`) directly
    /// beside "Wed 6:30 PM" (this), and two rows of Search showed "Fri 9:30 PM" above
    /// "29 Aug 2:00 PM" — three renderings of "when it airs" in one product, with no rule a reader
    /// could infer, all so a caption could save six characters. Abbreviating the day to "Wed" is
    /// what makes the two forms look like different grammars; the clock is the part a 100-pt
    /// caption genuinely has no room for, and the part the schedule already states elsewhere.
    ///
    /// The day ladder is `airs`'s ladder verbatim, so the two can never drift again.
    static func airsCompact(at ts: Int64, now: Int64, anchor: Formatting.TimeAnchor) -> String {
        switch Formatting.dayDiff(ts: ts, now: now, anchor: anchor) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return Formatting.fmtDayLong(ts: ts, now: now, anchor: anchor)
        default: return dateWord(ts, now: now, anchor: anchor)
        }
    }

    /// "Aired just now" · "Aired 27 min ago" · "Aired 10h ago" · "Aired yesterday" · "Aired Wednesday" ·
    /// "Aired Aug 19". Date-only sources never get a clock: "Aired today" · "Aired yesterday" · …
    static func aired(at ts: Int64, now: Int64, anchor: Formatting.TimeAnchor) -> String {
        let elapsed = now - ts
        let days = -Formatting.dayDiff(ts: ts, now: now, anchor: anchor)
        if !anchor.isDateOnly {
            if elapsed < 5 * Formatting.minuteMs { return "Aired just now" }
            if elapsed < 60 * Formatting.minuteMs { return "Aired \(Int(elapsed / Formatting.minuteMs)) min ago" }
            // ROUNDED, never truncated: 1 h 55 min read "Aired 1h ago" (review, 23 Sep).
            if days == 0 { return "Aired \(max(1, Int((Double(elapsed) / Double(Formatting.H)).rounded())))h ago" }
        } else if days == 0 {
            return "Aired today"
        }
        switch days {
        case 1: return "Aired yesterday"
        case 2...6: return "Aired \(Formatting.fmtDayLong(ts: ts, now: now, anchor: anchor))"
        default: return "Aired \(dateWord(ts, now: now, anchor: anchor))"
        }
    }

    static let noDateAnnounced = "No date announced"
    /// "Premieres Oct 2" — an announced first air date.
    static func premieres(_ date: String) -> String { "Premieres \(date)" }
    /// The same announced date for a show you have already been watching — the Library's verb
    /// ("Returns 3 Oct"), so a shelf and a show page never name one date two ways.
    static func returnsOn(_ date: String) -> String { "Returns \(date)" }

    /// "Returns tomorrow" · "Returns Friday" · "Returns Oct 2" · "Returns in 2027" · "No date announced".
    /// A date that has passed says so ("Returned Jul 5") — the catalogue's note can outlive the
    /// premiere by weeks, and every past day used to read "Returns today".
    static func returns(at ts: Int64?, now: Int64, anchor: Formatting.TimeAnchor) -> String {
        guard let ts else { return noDateAnnounced }
        switch Formatting.dayDiff(ts: ts, now: now, anchor: anchor) {
        case ..<0: return "Returned \(dateWord(ts, now: now, anchor: anchor))"
        case 0: return "Returns today"
        case 1: return "Returns tomorrow"
        case 2...6: return "Returns \(Formatting.fmtDayLong(ts: ts, now: now, anchor: anchor))"
        default: return "Returns \(dateWord(ts, now: now, anchor: anchor))"
        }
    }

    /// "Since Tuesday" · "Since Aug 12".
    static func since(_ ts: Int64, now: Int64) -> String {
        let days = -Formatting.dayDiff(ts: ts, now: now)
        switch days {
        case 0: return "Since earlier today"
        case 1: return "Since yesterday"
        case 2...6: return "Since \(Formatting.fmtDayLong(ts: ts, now: now))"
        default: return "Since \(dateWord(ts, now: now, anchor: .local))"
        }
    }

    /// "Aug 28" in the current year, "Aug 28, 2027" otherwise.
    ///
    /// The year is never string-joined on. `"\(md), \(a.y)"` produced **"31 Mar, 2013"** on a
    /// day-first device — a comma between a day-first date and its year, which no locale writes
    /// (en-GB is "31 Mar 2013", en-US "Mar 31, 2013") — and it was on every row of every episode
    /// list. `fmtFullDate` already carries the "MMMdyyyy" skeleton, which orders and punctuates
    /// itself per locale; a hand-assembled date cannot.
    static func dateWord(_ ts: Int64, now: Int64, anchor: Formatting.TimeAnchor) -> String {
        let a = Formatting.localParts(ts, anchor: anchor), b = Formatting.localParts(now, anchor: anchor)
        return a.y == b.y
            ? Formatting.fmtMonthDay(ts, anchor: anchor)
            : Formatting.fmtFullDate(ts, anchor: anchor)
    }

    // MARK: - The feed

    /// X's stamp on a post or a reply: "now", "5m", "2h", then "3d" for the past week, then the date
    /// ("15 Jun"), with the year once it is not this one ("15 Jun 2025"). A DATE-ONLY fact never gets
    /// minutes or hours (its clock is not a fact): "Today", then days, then the date, all read in its
    /// own UTC day. Nothing is stamped in the FUTURE: news cannot have happened after now, so an
    /// instant ahead of the device's clock (skew, or a publisher's day ahead of ours) is "now", and a
    /// date-only fact dated ahead of today (a JST publisher's "tomorrow") is "Today" — never "-1d".
    /// Words from `Copy.Feed`.
    static func feedStamp(_ at: Int64, dateOnly: Bool, now: Int64) -> String {
        let anchor: Formatting.TimeAnchor = dateOnly ? .utcDate : .local
        if !dateOnly {
            let minutes = max(0, now - at) / Formatting.minuteMs
            if minutes < 1 { return Copy.Feed.stampNow }
            if minutes < 60 { return Copy.Feed.stampMinutes(Int(minutes)) }
            let hours = minutes / 60
            if hours < 24 { return Copy.Feed.stampHours(Int(hours)) }
        }
        let days = Formatting.dayDiff(ts: at, now: now, anchor: anchor)
        if days >= 0 { return Copy.Feed.stampToday }
        if days > -7 { return Copy.Feed.stampDays(-days) }
        return Formatting.formatted(at, skeleton: sameYear(at, now, anchor) ? "dMMM" : "dMMMyyyy", anchor: anchor)
    }

    /// The "when" inside a premiere headline, lower case where it is a word: "today", "tomorrow",
    /// "this Friday" (2–6 days out), else the date with its weekday ("Friday 3 October", and the year
    /// once it is not this one). Read in the premiere's own calendar (`FeedPremiere.anchor`), so a
    /// date-only premiere never moves a day east of UTC+7.
    ///
    /// A premiere whose day has PASSED (`premiereHasPassed`) reads in the past, for
    /// `Copy.Feed.headlinePremiered`: "yesterday", the weekday within the week ("Tuesday", the
    /// `aired` ladder's), else the same dated form. The server drops a research post once its
    /// installment airs, but its sync runs hourly and a saved or opened post composes by id — and
    /// "premieres Wednesday 24 September" printed two days after it did was a lie.
    static func premiereWhen(_ at: Int64, anchor: Formatting.TimeAnchor, now: Int64) -> String {
        switch Formatting.dayDiff(ts: at, now: now, anchor: anchor) {
        case 0: return Copy.Feed.premieresToday
        case 1: return Copy.Feed.premieresTomorrow
        case 2...6: return Copy.Feed.premieresThis(Formatting.fmtDayLong(ts: at, now: now, anchor: anchor))
        case -1: return Copy.Feed.premieredYesterday
        case -6 ... -2: return Formatting.fmtDayLong(ts: at, now: now, anchor: anchor)
        default:
            return Formatting.formatted(at, skeleton: sameYear(at, now, anchor) ? "EEEEdMMMM" : "EEEEdMMMMyyyy",
                                        anchor: anchor)
        }
    }

    /// The premiere's day is behind today (read in its own calendar): the headline says
    /// "premiered", and no "Premieres …" line is added to a sentence.
    static func premiereHasPassed(_ at: Int64, anchor: Formatting.TimeAnchor, now: Int64) -> Bool {
        Formatting.dayDiff(ts: at, now: now, anchor: anchor) < 0
    }

    /// The previous visit as a phrase for "You’ve seen everything new since …": "this morning" /
    /// "this afternoon" / "this evening" (the same day, by the hour the visit began), "yesterday",
    /// the weekday within the week ("Tuesday"), else the date ("12 Sep", with the year once it is
    /// not this one). A visit is a real instant, read in the device's calendar.
    static func sinceVisit(_ at: Int64, now: Int64) -> String {
        switch Formatting.dayDiff(ts: at, now: now, anchor: .local) {
        case 0:
            let hour = Formatting.localParts(at, anchor: .local).hour
            if hour < 12 { return Copy.Feed.sinceMorning }
            return hour < 17 ? Copy.Feed.sinceAfternoon : Copy.Feed.sinceEvening
        case -1:
            return Copy.Feed.sinceYesterday
        case -6 ... -2:
            return Formatting.formatted(at, skeleton: "EEEE", anchor: .local)
        default:
            return Formatting.formatted(at, skeleton: sameYear(at, now, .local) ? "dMMM" : "dMMMyyyy", anchor: .local)
        }
    }

    /// Whether `ts` (read in `anchor`) falls in the device's current year.
    private static func sameYear(_ ts: Int64, _ now: Int64, _ anchor: Formatting.TimeAnchor) -> Bool {
        Formatting.localParts(ts, anchor: anchor).y == Formatting.localParts(now, anchor: .local).y
    }

    /// A date range — "24 May – 29 Jul", "10 Dec 2024 – 3 Feb 2025". One formatter, so the two ends
    /// agree with each other and with `dateWord`, and the year is never implied away inside a form.
    ///
    /// Within two taps the shipped build showed "31 Mar, 2013", "24 May – 29 Jul" (no year at all),
    /// "10 Dec, 2024" and "24 May 2026" — four formats, two of them in adjacent rows of one list.
    static func dateRange(_ from: Int64, _ to: Int64, now: Int64,
                          anchor: Formatting.TimeAnchor = .local) -> String {
        let a = Formatting.localParts(from, anchor: anchor)
        let b = Formatting.localParts(to, anchor: anchor)
        let thisYear = Formatting.localParts(now, anchor: anchor).y
        // A span that crosses a year, or sits in a year that is not this one, states both years.
        guard a.y == b.y, a.y == thisYear else {
            return "\(Formatting.fmtFullDate(from, anchor: anchor)) \u{2013} \(Formatting.fmtFullDate(to, anchor: anchor))"
        }
        return "\(Formatting.fmtMonthDay(from, anchor: anchor)) \u{2013} \(Formatting.fmtMonthDay(to, anchor: anchor))"
    }
}
