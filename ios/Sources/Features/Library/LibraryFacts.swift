import SwiftUI

// The Library's vocabulary, in one place.
//
// The panel's blocking finding was that the two Library surfaces disagreed about the same show:
// "Black Clover — Finished" in All titles and "Black Clover — Returns Oct 2026" under RETURNING one
// screen earlier, with "Finished" carrying the user's LIST state on one screen and the series'
// PRODUCTION state on the other. And "Attack on Titan — No date announced" filed under a section
// headed RETURNING, a heading its own detail screen contradicts three ways.
//
// Both are vocabulary problems, so the vocabulary moved out of the views:
//
//  * `LibrarySection` — the buckets, and the ONE classifier that fills them. `RETURNING` now means
//    "a date is known"; everything announced without one gets its own `ANNOUNCED` section, where
//    "No date announced" is the point rather than a contradiction.
//  * `ReturnFact` — one formatter for "when does it come back", at the shortest honest precision.
//    Four phrasings of one fact ("Returns Oct 2026" / "Returns in 2027" / "Returns Jan 2027" /
//    "Returns Late 2027") appeared within six rows because the ≤17-character branch passed the
//    server's prose through verbatim, capital and all.
//  * `LibraryRowFacts` — the row's two lines, ONE implementation, one rule per surface. The root
//    and All titles each had their own `rowMeta`/`rowLead` pair, which is how two Watching rows in
//    one list ended up disagreeing about whether a progress fact appears at all.

// MARK: - Sections

/// A Library bucket. Four of these are `AppModel.LibShelf` verbatim; the fifth exists because
/// "coming back" is two different facts wearing one word.
enum LibrarySection: Int, Hashable, Identifiable, CaseIterable {
    /// A next installment with a KNOWN future date. This is the only section allowed to promise.
    case returning
    /// A next installment is announced and undated. The absence of a date is the content here.
    case announced
    case watching
    case planned
    /// Nothing left to watch and nothing announced.
    case finished
    /// The user's own "not now" and "not for me" — each named by its status.
    case paused
    case dropped

    var id: Int { rawValue }

    /// The status shelves are named by `Copy.Status`, so a shelf heading, the detail picker and
    /// a catalogue row cannot spell one state three ways. The two future-facts have their own words.
    var label: String {
        switch self {
        case .returning: return Copy.Library.returning
        case .announced: return Copy.Library.announced
        case .watching:  return Copy.Status(.watching)
        case .planned:   return Copy.Status(.planned)
        case .finished:  return Copy.Status(.completed)
        case .paused:    return Copy.Status(.paused)
        case .dropped:   return Copy.Status(.dropped)
        }
    }

    /// Board 05 order — Returning · Watching · Planned · Watched — with `Announced` filed between
    /// Planned and Watched. It is the weakest signal on the screen (a sequel exists, nobody has
    /// said when), so it must not sit between the dated returns and the shows you are actually
    /// living with: seven "No date announced" rows pushed WATCHING a full screen down.
    var rank: Int {
        switch self {
        case .returning: return 0
        case .watching:  return 1
        case .planned:   return 2
        case .paused:    return 3
        case .announced: return 4
        case .finished:  return 5
        case .dropped:   return 6
        }
    }
}

/// The one classifier. Both Library surfaces route through it, so a show cannot be `RETURNING` on
/// the root and something else behind a `See all` that claims to show exactly that section.
@MainActor
enum LibraryShelving {
    static func section(of f: Franchise, appModel: AppModel) -> LibrarySection {
        switch appModel.libShelf(of: f) {
        case .planned:  return .planned
        case .watching: return .watching
        case .finished: return .finished
        case .paused:   return .paused
        case .dropped:  return .dropped
        case .comingBack:
            return ReturnFact.of(f, appModel: appModel).dated ? .returning : .announced
        }
    }
}

// MARK: - "When does it come back"

/// "Returns Oct 2" · "Returns Oct 2026" · "Returns 2027" · "Returns late 2027" · "No date announced".
///
/// A dated premiere among the parts is the best fact there is, so it wins. Otherwise the curated
/// release window is read at whatever precision it actually has — and re-emitted at the SHORTEST
/// honest granularity rather than passed through: the server sends human windows like
/// `October 2026`, and `Returns October 2026` is 20 characters in a 124-pt caption, which is how
/// the shelf ended up printing `Returns October…`. Board 09's rule is to drop a fact, never to
/// truncate one.
///
/// ONE grammar: `TemporalCopy.returns`'s verb followed by the date word at its own precision.
/// "Returns in 2027" beside "Returns Jan 2027" was two forms of one fact six rows apart, and the
/// preposition was the only difference a reader could see.
///
/// `dated` is false only for "No date announced" — the one caption that must never be amber, and
/// now also the thing that keeps a show out of a section headed RETURNING.
@MainActor
struct ReturnFact {
    /// The verb a dated fact wears. `returns` is the Library's word for a show that went away and
    /// is coming back ("Returns 3 Oct"); `premieres` is for a show you have not started, whose next
    /// installment does not come BACK to you (`premiere(of:appModel:)`).
    enum Verb {
        case returns, premieres

        /// The verb over an instant, on the day ladder `TemporalCopy.returns` uses: "Returns
        /// tomorrow" · "Premieres Friday" · "Premieres 9 Oct".
        func at(_ ts: Int64, now: Int64, anchor: Formatting.TimeAnchor) -> String {
            guard self == .premieres else { return TemporalCopy.returns(at: ts, now: now, anchor: anchor) }
            let day = TemporalCopy.airsCompact(at: ts, now: now, anchor: anchor)
            // "today" and "tomorrow" are common nouns mid-sentence; a weekday and a date are not.
            return TemporalCopy.premieres(day == "Today" || day == "Tomorrow" ? day.lowercased() : day)
        }

        /// The verb over a window it has no instant for — a month, a year, "late 2027". One prefix
        /// per verb, so the shelf cannot phrase the same fact two ways.
        /// SHARED-FILE REQUEST: `TemporalCopy.returns(window:)`, so the verb has exactly one home.
        func window(_ w: String) -> String {
            self == .returns ? "Returns \(w)" : TemporalCopy.premieres(w)
        }
    }

    let text: String
    /// The fact with its verb, always ("Returns 2027"). `text` drops the verb outside the horizon
    /// because the Returning shelf's header already says it; a list with no such header — All
    /// titles — printed "Watched · 2027", a year with no subject (review, 23 Sep).
    var sentence: String = ""
    let dated: Bool
    /// **The one flag that decides whether this fact is amber**, on the shelf and in the catalogue
    /// alike — the panel's `nextStepIsLead`.
    ///
    /// Amber means "a step you can take soon". A date fifteen months out is a note in the margin,
    /// and six of them on one shelf turned accent into the caption colour: every visible caption on
    /// the Library root was amber and none of them was an action. Inside the horizon the date
    /// leads on **both** surfaces; outside it, it rides the grey line on both. One derived value,
    /// two call sites, no drift — and it replaces the old `accentAllowed` rationing, which dimmed
    /// the fourth returning row at accessibility sizes for a reason the reader could not see.
    let soon: Bool

    /// Roughly two months. Long enough to cover "the next season starts soon", short enough that a
    /// shelf carrying amber still means something. **Milliseconds** — every instant in this app is
    /// (`AppModel.now` is `.nowMs`, `premiereAt` is `nextAiringAt`), and `Date.timeIntervalSince1970`
    /// is the one place seconds leak in, so it is converted at every crossing below.
    static let soonHorizon: Int64 = 60 * 86_400 * 1000

    /// The single seconds -> milliseconds crossing for a calendar date.
    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private static func known(_ text: String, at: Int64?, now: Int64) -> ReturnFact {
        let soon = at.map { $0 - now <= soonHorizon } ?? false
        // Inside the horizon the verb and the amber ("Returns 3 Oct" — a step); outside it the
        // window alone, grey ("Jan 2027"): one verb in two inks read as a rule the reader had
        // to guess (review i5). The section header already says Returning — and only "Returns"
        // drops: no header says Premiering, so "Premieres 2027" keeps its verb.
        let shown = soon ? text : Self.capitalisedFirst(text.replacingOccurrences(of: "^Returns ", with: "", options: .regularExpression))
        // One fact, one line: at the accessibility sizes All titles broke "Returns / 3 Oct" across
        // two lines (review, 23 Sep). A short fact binds like `Copy.plural`'s number and noun.
        func bound(_ s: String) -> String { s.count <= 24 ? s.replacingOccurrences(of: " ", with: "\u{00A0}") : s }
        return ReturnFact(text: bound(shown), sentence: bound(text), dated: true, soon: soon)
    }

    private static func capitalisedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// A next installment really lies AHEAD: a dated premiere among the parts, or a curated one
    /// whose day has not already come — `AppModel.libShelf`'s own test for "coming back". `of`
    /// reads a stale curated day as "Returned 5 Jul", which is history, not a caption.
    static func isAhead(_ f: Franchise, appModel: AppModel) -> Bool {
        if appModel.nextPremiere(of: f) != nil { return true }
        guard let upcoming = f.upcoming else { return false }
        return upcoming.isFutureInstallment && !upcoming.hasArrived(now: appModel.nowMinute)
    }

    /// A Planned show's next dated installment, with ITS verb: "Premieres 9 Oct" (the series' own
    /// first episode) or "Season 3 premieres 20 Nov" (a later season of a show that has aired —
    /// "Premieres 20 Nov" alone told the reader Percy Jackson had never been on). The shelf and All
    /// titles said only "TV · 2026" / "Planned" about a show premiering in sixteen days (review,
    /// 23 Sep). "Returns" stays with the shows that went away: one you have not started does not
    /// come BACK to you. The verb always rides — no "Premiering" header lends it — and `soon`
    /// decides the amber exactly as it does for a return. Nil when nothing ahead is dated (no
    /// premiere, a rumour, a window already reached), so the caller keeps what it said before.
    static func premiere(of f: Franchise, appModel: AppModel) -> ReturnFact? {
        guard let parts = premiereParts(of: f, appModel: appModel) else { return nil }
        // No shelf header lends a Planned row its verb, so the fact always carries one.
        let sentence = parts.fact.sentence.isEmpty ? parts.fact.text : parts.fact.sentence
        guard let name = parts.installment else {
            return ReturnFact(text: sentence, sentence: sentence, dated: true, soon: parts.fact.soon)
        }
        let text = Copy.Library.premieres(installment: name, fact: sentence)
        return ReturnFact(text: text, sentence: text, dated: true, soon: parts.fact.soon)
    }

    /// The same fact in two pieces — the installment it names ("Season 3"; nil for the series'
    /// own first episode) and the dated fact with its verb — for a caption that stacks them
    /// (Today's Planned posters: "Premieres 20 Nov" under Percy Jackson hid that two seasons are
    /// already out, review i3).
    ///
    /// The verb follows PROGRESS, on every surface (review i3): a show you have watched any of
    /// RETURNS ("Season 2 returns late 2026" — 3 Body Problem, Season 1 watched, read "Premieres
    /// late 2026" on Today and "Returns" on its own page); one you have not PREMIERES.
    static func premiereParts(of f: Franchise, appModel: AppModel) -> (installment: String?, fact: ReturnFact)? {
        guard isAhead(f, appModel: appModel) else { return nil }
        let verb: Verb = f.parts.contains(where: { $0.progress > 0 }) ? .returns : .premieres
        let fact = of(f, appModel: appModel, verb: verb)
        guard fact.dated else { return nil }
        // The series' own premiere needs no name. A later installment is named when the name is
        // one a badge could hold (`Copy.Release.announcement`'s rule: 16 characters, no "(Movie)"
        // kind) — "Infinity Castle Part 2 (movie) premieres…" is a paragraph, not a caption.
        let name: String? = {
            if let at = appModel.nextPremiere(of: f) {
                return f.parts.first { $0.premiereAt == at }?.canonicalLabel
            }
            return f.upcoming?.next?.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        guard f.parts.contains(where: { !$0.isUpcoming }), let name, !name.isEmpty,
              name.count <= 16, !name.contains("(") else { return (nil, fact) }
        return (name, fact)
    }

    /// Minute precision is all a return date needs; reading `nowMinute` keeps the Library from
    /// re-deriving every caption on the 20-second tick. `verb` is `.returns` everywhere but a
    /// Planned show's premiere (`premiere(of:appModel:)`).
    static func of(_ f: Franchise, appModel: AppModel, verb: Verb = .returns) -> ReturnFact {
        let now = appModel.nowMinute
        func unknown() -> ReturnFact {
            ReturnFact(text: TemporalCopy.returns(at: nil, now: now, anchor: f.timeAnchor),
                       dated: false, soon: false)
        }
        if let at = appModel.nextPremiere(of: f) {
            return known(verb.at(at, now: now, anchor: f.timeAnchor), at: at, now: now)
        }
        // An unconfirmed report is not a schedule (docs/api-contract.md): the server resolves its
        // window to `unknown`, and the caption says what it is — "Season 3 rumored" — rather than
        // filing a rumour under "No date announced", which reads as a confirmed sequel.
        if let upcoming = f.upcoming, upcoming.isRumored {
            return ReturnFact(text: Copy.Library.rumored(next: upcoming.next), dated: false, soon: false)
        }
        guard let upcoming = f.upcoming, let window = upcoming.releaseWindow,
              window.precision != .unknown, let parts = window.parts else { return unknown() }
        // Day precision inside the current year gets the friendly form — "Returns tomorrow",
        // "Returns Saturday", "Returns Oct 2" — which is also always the shortest.
        if window.precision == .day, parts.year == Formatting.localParts(now, anchor: .utcDate).y,
           let date = utcDay(y: parts.year, month: parts.month, day: parts.day) {
            let at = ms(date)
            return known(verb.at(at, now: now, anchor: .utcDate), at: at, now: now)
        }
        // Every other announced DATE settles at month-and-year: "Returns Oct 2026" fits, "Oct 2,
        // 2027" does not, and a day nine months out is not a fact anybody acts on. A curated
        // window is a calendar date, so it is read as one (`.utcDate`) whatever the source is.
        if window.precision == .day || window.precision == .month,
           let date = utcDay(y: parts.year, month: parts.month, day: 1) {
            let at = ms(date)
            return known(verb.window(LibraryDates.monthYear(at, anchor: .utcDate)), at: at, now: now)
        }
        // A quarter or a year is a WINDOW, and only the server's prose states it honestly: the
        // month inside `releaseWindow.date` is an ordering device ("Summer 2027" sorts as July),
        // never a month to print. Said in the same grammar as a date — "Returns summer 2027",
        // "Returns late 2026", "Returns 2027" — and never the server's capital dropped into the
        // middle of a sentence. A window is never `soon`: with no instant behind it the colour
        // rule has nothing to measure.
        let prose = upcoming.displayRelease.trimmingCharacters(in: .whitespacesAndNewlines)
        if prose.count == 4, Int(prose) != nil {
            return known(verb.window(prose), at: nil, now: now)
        }
        if !prose.isEmpty, prose.count <= 20 {
            return known(verb.window(ReturnFact.lowerFirst(prose)), at: nil, now: now)
        }
        // A window too long to state whole is reduced to its year rather than ellipsed.
        return known(verb.window(String(parts.year)), at: nil, now: now)
    }

    /// `String.lowercasedFirst()` lives `private` in `Copy.swift` and `fileprivate` again in
    /// `FranchiseDetailView.swift`; this is the same rule a third time.
    /// SHARED-FILE REQUEST: raise that helper's visibility rather than keeping three of it.
    nonisolated static func lowerFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    /// A curated release window is a calendar date, not an instant: read it in UTC or a device in
    /// UTC+9 reads "October 2026" as September.
    private static func utcDay(y: Int, month: Int, day: Int) -> Date? {
        var parts = DateComponents()
        parts.year = y; parts.month = month; parts.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: parts)
    }
}

/// The Library's one month-and-year date, for a Returning caption and a month header alike.
enum LibraryDates {
    /// "Oct 2026" — locale-ordered, read in `anchor`'s calendar so a TMDB date-only instant and
    /// an AniList instant each land in the month they actually belong to.
    ///
    /// Goes through `Formatting` rather than a private `DateFormatter`: two of those lived in this
    /// feature (one per surface) and neither honoured the time anchor. `prettyReleaseString` is
    /// the one `Formatting` path that already emits the "MMMyyyy" skeleton, so the parts are read
    /// in the right calendar here and formatted there.
    static func monthYear(_ ts: Int64, anchor: Formatting.TimeAnchor) -> String {
        Formatting.fmtMonthYear(ts, anchor: anchor)
    }
}

// MARK: - Row facts

/// The two lines under a Library row title, resolved once for both surfaces.
///
/// `lead` is amber and is only ever a real NEXT STEP. `meta` is grey and states what the thing is
/// or where it stands. A fact never appears in both, and a section's own heading is never repeated
/// in the row underneath it.
@MainActor
struct LibraryRowFacts {
    var lead: String?
    var meta: String?
    /// A forward fact appended to `meta` in accent — "Watched · Returns 3 Oct" on ONE line. Two
    /// lines under one title lifted it out of the list's column (review, 5 Sep).
    var metaLead: String? = nil

    /// LIBRARY ROOT — a shelf, not a catalogue. Progress only: the status word is already the
    /// section heading 10 pt above, and printing it again is a row telling you what you just read.
    ///
    /// Colour is decided by `ReturnFact.soon` and nothing else. The old `accentAllowed` parameter
    /// rationed amber by ROW INDEX at accessibility sizes — the fourth returning row printed the
    /// identical fact in a different colour from the third, with nothing in the content to explain
    /// it. The horizon rule says the same thing honestly: near dates lead, far dates do not.
    static func root(_ f: Franchise, section: LibrarySection, appModel: AppModel) -> LibraryRowFacts {
        switch section {
        case .returning:
            let fact = ReturnFact.of(f, appModel: appModel)
            return fact.soon ? LibraryRowFacts(lead: fact.text, meta: nil)
                             : LibraryRowFacts(lead: nil, meta: fact.text)
        case .announced:
            // Never amber: the ABSENCE of a next step is not a next step.
            return LibraryRowFacts(lead: nil, meta: ReturnFact.of(f, appModel: appModel).text)
        case .watching:
            // ONE grammar, in one order: the step you owe → the day the next episode airs → the
            // date it comes back (else the announcement) → caught up. Since 23 Sep this shelf
            // holds only the Watching shows Next up does not (nothing to resume), so every branch
            // below the step is one it actually draws.
            // The shipped rows fell through to "TV · 2024" whenever a Watching show's current part
            // had not aired yet, so four consecutive Watching rows read "Caught up", "TV · 2024",
            // "Anime · 2019" and "Season 7 · Episode 5 next" with no visible reason for the change.
            //
            // A rewatch in flight is the one lead this shelf keeps: it is a step the user chose.
            if let re = rewatch(f) { return LibraryRowFacts(lead: re, meta: nil) }
            let now = appModel.nowMinute
            // The step itself rides the GREY line. Behind-counts and amber belong to Today — the
            // urgency pact — so the Library says where you stand and never how far behind you are.
            if let step = nextStep(f, now: now) {
                return LibraryRowFacts(lead: nil, meta: step)
            }
            // Caught up on a season still on air: the day the next episode lands ("Airs Friday",
            // Search's words for the same fact). A future air time is what amber MEANS; it is not
            // a count of what you owe.
            if let at = f.nextAiring(now: now) {
                let day = TemporalCopy.airsCompact(at: at, now: now, anchor: f.timeAnchor)
                return LibraryRowFacts(lead: Copy.Progress.episodeAirs(nil, when: day), meta: nil)
            }
            // The return date only replaces "Caught up" when there is genuinely nothing airing:
            // a show you are mid-season on says where you stand, not when its next season lands.
            if f.currentPart.map(\.isUpcoming) ?? true, ReturnFact.isAhead(f, appModel: appModel) {
                let fact = ReturnFact.of(f, appModel: appModel)
                if fact.dated {
                    // WITH its verb: `text` drops "Returns" for the Returning shelf, whose header
                    // lends it. Under WATCHING, ONE PIECE's caption read "2027" — a release year.
                    return fact.soon ? LibraryRowFacts(lead: fact.text, meta: nil)
                                     : LibraryRowFacts(lead: nil, meta: fact.sentence.isEmpty ? fact.text : fact.sentence)
                }
                // Announced, undated: the announcement is the fact — "Season 3 announced", the
                // show page's line under CAUGHT UP. "No date announced" alone says nothing under a
                // WATCHING header, and a rumour is not news enough to replace "Caught up".
                if f.upcoming?.isRumored != true, let news = f.releaseNews(now: now) {
                    return LibraryRowFacts(lead: nil, meta: news.headline)
                }
            }
            // `identity()` is NOT reachable from here. On the shelf you open to answer "what do I
            // owe", three consecutive rows answered with the year the show came out — "Attack on
            // Titan · Anime · 2013" — because `standing()` refused to speak without a current part.
            // A Watching show with nothing left in flight IS caught up; that is the whole meaning
            // of the word, and it is the only honest thing this row can say.
            return LibraryRowFacts(lead: nil, meta: standing(f) ?? Copy.Progress.caughtUp)
        case .paused:
            // Where you stopped, so picking it back up is one glance ("Season 2 · Episode 5 next").
            if let step = nextStep(f, now: appModel.nowMinute) { return LibraryRowFacts(lead: nil, meta: step) }
            return LibraryRowFacts(lead: nil, meta: settled(f, now: appModel.nowMinute) ?? identity(f))
        case .dropped:
            return LibraryRowFacts(lead: nil, meta: identity(f))
        case .planned, .finished:
            // A rewatch in flight outranks every settled word: it is forward-looking, so it leads.
            if let re = rewatch(f) { return LibraryRowFacts(lead: re, meta: nil) }
            // A Planned show you are part-way into says WHERE — "Season 5 · Episode 9 next" —
            // before anything else: "Anime · 2021" under 56 watched episodes told the reader the
            // app had forgotten them (iteration 2).
            if section == .planned, f.parts.contains(where: { $0.progress > 0 }),
               let step = nextStep(f, now: appModel.nowMinute) {
                return LibraryRowFacts(lead: nil, meta: step)
            }
            // A Planned show's premiere is the one date this shelf has to give ("Premieres 9 Oct"),
            // coloured by the same horizon as a return.
            if section == .planned, let fact = ReturnFact.premiere(of: f, appModel: appModel) {
                return fact.soon ? LibraryRowFacts(lead: fact.text, meta: nil)
                                 : LibraryRowFacts(lead: nil, meta: fact.text)
            }
            // A rumoured sequel rides a finished show's row ("Sequel series rumoured") — it is no
            // longer filed under Announced (`AppModel.libShelf`).
            if section == .finished, let up = f.upcoming, up.isRumored, !up.hasArrived(now: appModel.nowMinute) {
                return LibraryRowFacts(lead: nil, meta: Copy.Library.rumored(next: up.next))
            }
            return LibraryRowFacts(lead: nil, meta: settled(f, now: appModel.nowMinute) ?? identity(f))
        }
    }

    /// ALL TITLES — a catalogue that mixes every status, so the list state IS a fact and is always
    /// stated. One rule, no exceptions: state always, plus the one thing that is true about where
    /// you stand — caught up, or the season that is coming. The forward date rides the grey line
    /// here rather than the amber one; amber in a 300-row catalogue is reserved for the rows that
    /// are actually waiting on you.
    ///
    /// `stateIsGiven` is true when a status filter is active: the chip above the list already says
    /// "Watching", so printing it again on all ten rows is the row telling you what you just read.
    ///
    /// `compact` is the POSTER GRID asking the same question in a 136-pt cell. It is not a second
    /// implementation and it is not allowed to reach a different conclusion: the grid gets the same
    /// branches, with each fact stated at its shortest honest length and the joined second fact
    /// dropped (board 09 — drop a fact, never truncate one). The two view modes disagreeing about
    /// one show — grid "Episode 1 next" in amber, list "Watched" in grey, one segment apart — is
    /// what a user reads as the app losing their data, so the mode may change the layout and never
    /// the facts.
    static func catalogue(_ f: Franchise, appModel: AppModel,
                          stateIsGiven: Bool = false,
                          compact: Bool = false) -> LibraryRowFacts {
        let state: String? = stateIsGiven ? nil : listState(f)
        func joined(_ extra: String) -> String {
            guard let state else { return extra }
            // The separator travels WITH the fact it introduces: "Planned ·" never ends a line
            // with the fact on the next (iteration 2).
            return compact ? state : "\(state) \u{00B7}\u{00A0}\(extra)"
        }
        func lead(_ full: String) -> String {
            compact ? (shortStep(f, now: appModel.nowMinute) ?? full) : full
        }
        if let step = progress(f, now: appModel.nowMinute) {
            if !progressIsLead(f, now: appModel.nowMinute) {
                return LibraryRowFacts(lead: nil, meta: compact ? step : joined(step))
            }
            return LibraryRowFacts(lead: lead(step), meta: compact ? nil : state)
        }
        // A Planned show you are part-way into says where (iteration 2: "Planned" alone over 56
        // watched episodes of Mushoku).
        if f.effectiveStatus == .planned, f.parts.contains(where: { $0.progress > 0 }),
           let step = nextStep(f, now: appModel.nowMinute) {
            return LibraryRowFacts(lead: nil, meta: compact ? step : joined(step))
        }
        // A rewatch of a WATCHED show never reached `progress()` (it guards on `.watching`), so the
        // catalogue said "Watched" about a show the user is actively re-watching and nothing on any
        // surface said a session was in flight.
        if let re = rewatch(f) {
            return LibraryRowFacts(lead: lead(re), meta: compact ? nil : state)
        }
        // A near date is the same next step here as it is on the shelf, and it wears the same
        // colour — that is `ReturnFact.soon`'s whole job. A far date rides the GREY line joined to
        // the state: "Watched · Returns Oct 2026" is the sentence that stops the catalogue
        // contradicting the shelf, and thirteen amber dates in a thirty-row list would drown the
        // four rows that are actually waiting.
        // ...but only for a show that genuinely went away and is coming back. "Returns" is the
        // wrong verb for a Planned show you never started ("Planned · Returns 9 Oct") and for one
        // you are mid-way through ("Watching · Returns today"); the classifier already knows the
        // difference, so it decides.
        let fact = ReturnFact.of(f, appModel: appModel)
        if fact.dated, LibraryShelving.section(of: f, appModel: appModel) == .returning {
            if fact.soon {
                // The state and the date on ONE line, the date in accent.
                if compact || state == nil { return LibraryRowFacts(lead: fact.text, meta: nil) }
                return LibraryRowFacts(lead: nil, meta: state, metaLead: fact.text)
            }
            return LibraryRowFacts(lead: nil, meta: joined(fact.sentence.isEmpty ? fact.text : fact.sentence))
        }
        // ...and a Planned show's next installment PREMIERES, in the same two inks: "Planned ·
        // Premieres 9 Oct" with the date in accent inside the horizon, grey beyond it (review,
        // 23 Sep: the row said "Planned" and nothing else about a show sixteen days out).
        if f.effectiveStatus == .planned, let premiere = ReturnFact.premiere(of: f, appModel: appModel) {
            if premiere.soon {
                if compact || state == nil { return LibraryRowFacts(lead: premiere.text, meta: nil) }
                return LibraryRowFacts(lead: nil, meta: state, metaLead: premiere.text)
            }
            return LibraryRowFacts(lead: nil, meta: joined(premiere.text))
        }
        if let settled = settled(f, now: appModel.nowMinute) {
            return LibraryRowFacts(lead: nil, meta: joined(settled))
        }
        if let standing = standing(f) {
            return LibraryRowFacts(lead: nil, meta: joined(standing))
        }
        // With the state suppressed and nothing else to say, the row states what the thing IS
        // rather than going mute — a useful fact in place of a repeated one.
        return LibraryRowFacts(lead: nil, meta: state ?? identity(f))
    }

    /// "Caught up" — true of any Watching show with nothing left to watch, which now includes the
    /// case the shipped build fell through on: no current part at all.
    ///
    /// The `currentPart != nil` guard was the whole of B4. A show you are watching whose season has
    /// finished airing has no current part, so this returned nil and three consecutive WATCHING
    /// rows fell through to `identity()` — "Anime · 2013", "TV · 2024", "Anime · 2019". A release
    /// year is never an answer to "what do I owe". Having nothing in flight is exactly what being
    /// caught up means, so that is what it says.
    static func standing(_ f: Franchise) -> String? {
        guard f.effectiveStatus == .watching else { return nil }
        return Copy.Progress.caughtUp
    }

    /// The user's LIST state — never the series' production state. `completed` reads **Watched**;
    /// "Finished" is not in the app's vocabulary any more (`Copy.Status`), so the detail picker,
    /// the Profile tile and this list cannot spell one state three ways.
    static func listState(_ f: Franchise) -> String { listState(status: f.effectiveStatus) }

    static func listState(status: WatchStatus) -> String { Copy.Status(status) }

    /// An in-flight rewatch, whatever the list state says. It is the only forward-looking fact a
    /// *Watched* show can have, and until now no surface in the app printed it.
    static func rewatch(_ f: Franchise) -> String? {
        guard let active = RewatchStore.shared.activeSession(for: f.id),
              let p = f.currentPart else { return nil }
        return "\(active.title) \u{00B7} \(Copy.Progress.episodeNext(p.progress + 1))"
    }

    /// The catalogue's forward-looking step, in amber, and only when there genuinely is one. A
    /// settled state ("Caught up", "Watched twice") is never a lead.
    static func progress(_ f: Franchise, now: Int64) -> String? {
        guard f.effectiveStatus == .watching, let p = f.currentPart, !p.isUpcoming else { return nil }
        if let re = rewatch(f) { return re }
        // The AIRINGS-derived count, the one Today and the show page print — the catalogue's
        // hourly `episodesBehind` lagged a drop by up to an hour (iteration 2).
        if p.isReleasing {
            let behind = p.behind(now: now, anchor: f.timeAnchor)
            return behind > 0 ? Copy.Progress.behind(behind) : nil
        }
        return nextStep(f, now: now)
    }

    /// Amber is for a drop that is FRESH (inside the Now Bar's live window), grey for an older
    /// backlog — the rule Today and Profile already follow for the same count (iteration 2:
    /// All titles alone printed Bleach's 11-day-old "6 episodes behind" in amber).
    static func progressIsLead(_ f: Franchise, now: Int64) -> Bool {
        guard f.effectiveStatus == .watching, let p = f.currentPart, p.isReleasing,
              let last = p.lastAired(now: now, anchor: f.timeAnchor) else { return true }
        return now - last <= AppModel.nowBarLiveWindow
    }

    /// "Season 7 · Episode 5 next" / "Episode 5 next" — the next episode that exists and has aired,
    /// or nil when there is nothing to watch. `Franchise.watchContext(part:episode:)` is THE
    /// context rule (season only on a multi-part show) and `Copy.Progress.next` the only postfix.
    static func nextStep(_ f: Franchise, now: Int64) -> String? {
        guard let p = f.currentPart, !p.isUpcoming, p.markTarget(now: now) > p.progress else { return nil }
        return Copy.Progress.next(context: f.watchContext(part: p, episode: p.progress + 1))
    }

    /// The same step with its context dropped — "Episode 5 next" where the row says "Season 7 ·
    /// Episode 5 next". A 136-pt grid cell has room for one fact, and the episode is the one you
    /// act on; the season (and the rewatch ordinal) stay in the list, which has the width for them.
    static func shortStep(_ f: Franchise, now: Int64) -> String? {
        guard let p = f.currentPart, !p.isUpcoming else { return nil }
        if p.isReleasing { return p.episodesBehind > 0 ? Copy.Progress.behind(p.episodesBehind) : nil }
        return p.markTarget(now: now) > p.progress ? Copy.Progress.episodeNext(p.progress + 1) : nil
    }

    /// Where a show stands when there is nothing to do about it. "Caught up" is a claim, so it is
    /// made only about a part that actually exists and has actually been caught.
    static func settled(_ f: Franchise, now: Int64) -> String? {
        if f.effectiveStatus == .completed {
            let watched = RewatchStore.shared.summary(for: f.id).completedCount
            if watched >= 2 { return Copy.Progress.watchedTimes(watched) }
        }
        return nil
    }

    /// "Anime · 2021" / "TV · 2024" — what the thing is and when it started. The original's line,
    /// and the only honest thing to say about a show you have not started.
    static func identity(_ f: Franchise) -> String {
        guard let y = f.year else { return f.kindWord }
        return "\(f.kindWord) \u{00B7} \(y)"
    }
}

// MARK: - Copy staged here

// Library strings added while `Copy+Library.swift` was out of this pass's hands. They belong in
// `Copy.Library` proper; they live here only until that file is next open.
extension Copy.Library {
    /// "Season 3 premieres 20 Nov" — a LATER installment's premiere, named, so a show that has
    /// already aired never reads as brand new. `fact` is the premiere sentence itself ("Premieres
    /// 20 Nov", `TemporalCopy.premieres`); the installment's words bind like its date does, so the
    /// line can only break between the two.
    ///
    /// TWO facts now — "Season 2 · Returns late 2026" — joined so a line may only break AFTER the
    /// dot: as one sentence it broke "Season 2" / "returns late 2026", a lower-case line start
    /// flagged in three review rounds (UX-N15).
    static func premieres(installment: String, fact: String) -> String {
        "\(installment.replacingOccurrences(of: " ", with: "\u{00A0}"))\u{00A0}\u{00B7} \(fact)"
    }
}
