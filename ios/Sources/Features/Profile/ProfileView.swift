import SwiftUI
import UIKit
import UserNotifications

// Profile (spec board 08): the modal where trust is inspectable — who is signed in, whether the
// library is actually saved, every failed change with a way to fix it, and the two account actions
// that cannot be taken back.
//
// FIX ROUND 2. What the adversarial panel drew off `after-*.png`, and what replaces it:
//
//  • B1 — THE EXPORT MENU PROMISED A FEATURE THAT DOES NOT EXIST. "JSON — everything, for
//    re-import" in the one place a user goes when they are worried about their data. The owner's
//    decision is that there is no library import this round, so the copy stops claiming one:
//    "JSON — machine-readable". It also stops wrapping to two lines inside the menu.
//  • B2 — THE ACCOUNT DISC SAT ON TOP OF THE ARTWORK. A 56-pt disc with an opaque canvas
//    punch-through planted dead centre over the middle poster, slicing the GAME OF THRONES
//    logotype in half and eating the centre card at AX1. Two identity elements colliding, on the
//    identity screen. The disc now sits BELOW the fan with an 8-pt canvas ring between them, cuts
//    no hole in anything, and VoiceOver reads the identity block as "Signed in as …".
//  • B3 / M3 — RETRY AND DISCARD WERE TWO SUB-44-PT WORDS ~20 PT APART IN TWO COMPETING COLOURS,
//    aligned to the title's wrap point rather than to the row. They now sit on their OWN trailing
//    row inside the plate, 20 pt apart, differentiated by SHAPE and not only by colour — Retry is a
//    bordered 44-pt control, Discard change is a 44-pt destructive text action — and the failure's
//    subject, verb, reason and time each get their own slot instead of wrapping into each other.
//  • M1 — THE OPAQUE TOOLBAR GUILLOTINED THE CONTENT. `.toolbarBackground(canvas)` overrode the
//    `.chromeScrollEdgeHard(.top)` requested one line above it, so "SETTINGS" was bisected
//    horizontally through its x-height by a hard line. The system effect owns that edge now.
//  • M4 — THE OFFLINE STATE CLAIMED TO BE DOING WHAT IT COULD NOT, with two loading indicators at
//    once, and it DELETED the account summary rather than degrading it. Offline is now tested
//    first, there is never more than one indicator in the row, and the counts and the fan are
//    rendered from the last persisted snapshot.
//  • M6 — THE "ART-DERIVED" WASH WAS NOT DERIVED FROM THE ART and bled past its section, so the
//    same plate was warm brown at the top of the scroll and neutral grey further down. It reads the
//    CENTRE fan card and its ramp completes above the stats plate: every plate below sits on canvas.
//  • Plus: honest sync vocabulary (M12), the green decoration removed (M11), Paused given a home
//    (M13), the stats plate composed at AX1 (M2), pull-to-refresh removed from a sheet where it
//    fights interactive dismiss (M10), the severity gradient restored between Sign out and Delete
//    account (M8), and the wordmark's terminal period drawn once (m2).
struct ProfileView: View {
    /// Dismiss the sheet and open All titles filtered to this status. The feed's header disc — the
    /// one entry to this sheet — always wires it (RootView's `libraryRequest` route, 25 Sep); `nil`
    /// only for a presenter that has nowhere to send it, and the shelf's "See all" then is not drawn
    /// rather than pretending to be a control.
    var onOpenLibrary: ((WatchStatus) -> Void)? = nil
    /// Dismiss the sheet and open a show — the Watching shelf's and Saved's route.
    var onOpenDetail: ((String) -> Void)? = nil

    @Environment(AppModel.self) private var appModel
    @Environment(AuthManager.self) private var auth
    @Environment(\.dismiss) private var dismiss
    /// Set by the feed on this sheet: closes it and opens a feed page on Today (Saved → a post).
    @Environment(\.openFeedRoute) private var openFeedRoute
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hapticsOn = FeedbackCoordinator.enabled
    /// The sheet's own stack: Export and the Community pages are pushed here, inside the sheet.
    @State private var path: [ProfileRoute] = []
    /// Community rules, to read (the accept form is the composer's first step, never this row's).
    @State private var showRules = false
    /// "What do you watch?" (`AudienceChooser`).
    @State private var showAudience = false
    @State private var showImport = false
    #if DEBUG
    @State private var demoBusy = UserDefaults.standard.bool(forKey: "demoBusy")
    #endif
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var discardTarget: UUID?
    @State private var signingOut = false
    @State private var deleting = false
    /// The one failure this screen has to report itself: the account deletion that did not happen.
    @State private var deleteFailure: String?
    @State private var signOutFailed = false
    /// Alerts are OFF in Settings: the app asks in-app before it sends anyone there (CLAUDE.md's
    /// 5 Sep rule; review i5, F12 — the row jumped straight to the Settings app).
    @State private var askOpenSettings = false
    /// `nil` until asked, and while the system has never been asked (nothing to report yet).
    @State private var notificationsOn: Bool?
    /// Resolved here rather than read off `PaletteCache` synchronously: nothing else on this screen
    /// primes the cache on a cold open, so the wash would fall back to neutral.
    @State private var washTint: Color?
    /// Drives the wash out. Read from scroll geometry rather than a `GeometryReader` sentinel so
    /// nothing in the content tree has to know the wash exists. A `ScrollOffset`, not a bare
    /// `@State` (5 Sep): as screen state every scroll sample re-ran this whole body — the
    /// library counts, the shelf, the plates — and the sheet stuttered under the finger
    /// (sampled: `ProfileView.body` and `Franchise.resumePart` under the scroll). Only the
    /// wash's travel reads it.
    @State private var scroll: ScrollOffset = {
        let s = ScrollOffset()
        s.ceiling = 720
        return s
    }()
    /// Screen-space y of the shelf's top edge, measured at rest. The wash's ramp finishes here,
    /// so no container on this screen ever contains the END of a gradient (M2, M6).
    @State private var shelfTop: CGFloat = 0
    /// What the account looked like the last time the library actually loaded. The screen renders
    /// from this when the network is gone, instead of deleting the summary (M4).
    @State private var snapshot = ProfileSnapshot.load()

    /// Trailing indicators scale with the row titles they sit beside. At AX1 the fixed-size chevron
    /// and arrow shrank to specks against ~24-pt titles.
    @ScaledMetric(relativeTo: .body) private var indicatorSize: CGFloat = 14

    private var now: Int64 { appModel.now }
    private var sync: SyncCenter { SyncCenter.shared }
    private var isAX: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .top) {
                // The field TRAVELS WITH THE IDENTITY BLOCK it belongs to. Painted fixed to the
                // screen it stayed where it was while the plates slid through it, so the SETTINGS
                // plate was warm at the top of the scroll and the ACCOUNT plate neutral grey
                // further down — one component, two hues, decided by scroll position (M6).
                // Masking alone cannot fix that: "ends above the stats plate" is only true at
                // rest. Anchoring it to the content is.
                // Flat, as Today is (25 Sep): the wash that travelled with the identity block is
                // gone with every root's.
                ScrollView {
                    sheetContent
                        .padding(.horizontal, ThemeMetrics.gutter)
                        .padding(.top, ThemeSpace.x4)
                }
                .scrollIndicators(.hidden)
                // The sheet had no bottom inset, so the last line of the colophon ended flush
                // against the bezel — text sliced by the screen edge.
                .safeAreaPadding(.bottom, 34)
                // The system's own scroll edge, and ONLY it. Round 2 asked for `.hard` here and then
                // overrode it two lines later with an opaque `toolbarBackground`, which hard-clips
                // instead of blurring: "SETTINGS" was cut horizontally through its x-height by a
                // sharp line under the title (M1). `.hard` is the correct variant for art-backed
                // content and it is what iOS 26 ships for exactly this case.
                .chromeScrollEdgeHard(.top)
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top
                } action: { _, y in
                    scroll.set(y)
                }
            }
            .background(ThemeColor.canvas.ignoresSafeArea())
            .task(id: washArtwork) {
                washTint = await PaletteCache.shared.resolve(url: washArtwork, maxPixel: 360)
            }
            .onChange(of: appModel.library.count, initial: true) { _, _ in
                if let fresh = ProfileSnapshot.capture(appModel.library, covers: liveCovers) {
                    fresh.save()
                    snapshot = fresh
                } else if sync.lastSyncedAt != nil, sync.isOnline {
                    // A library that LOADED and is empty is a real empty account, not a failure —
                    // and the memory has to go with it, or the last show the user removed keeps
                    // posing as their artwork. Only a successful, online load may clear it.
                    ProfileSnapshot.clear()
                    snapshot = ProfileSnapshot()
                }
            }
            // A real inline navigation bar: VoiceOver announces the screen, and the system's own
            // scroll-edge material takes over from the wash as it fades.
            .brandNavigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Plain text where iOS puts plain text. On this SDK the capsule is the
                    // toolbar's own shared glass, so `buttonStyle` alone does not remove it.
                    // The app's one toolbar-action recipe: confirm = `bodyEmphasis` + interactive.
                    // This was the one Done set in raw SF outside the ramp.
                    Button(Copy.Action.done) { dismiss() }
                        .buttonStyle(.plain)
                        .type(ThemeType.bodyEmphasis)
                        .foregroundStyle(ThemeColor.interactive)
                }
                .chromeSharedBackgroundHidden()
            }
            .navigationDestination(for: ProfileRoute.self) { route in
                destination(route)
            }
        }
        .sheet(isPresented: $showRules) {
            CommunityRulesSheet(mode: .read, onAccepted: { _ in })
        }
        .sheet(isPresented: $showImport) {
            ImportView(appModel: appModel) { _ in showImport = false }
        }
        .sheet(isPresented: $showAudience) {
            AudienceChooser(mode: .settings, onDone: { showAudience = false })
        }
        .onAppear { sync.profileIsOpen = true }
        .onDisappear { sync.profileIsOpen = false }
        // ALERTS, not `confirmationDialog`. On this SDK a confirmation dialog renders as a
        // source-anchored card that suppresses its own `.cancel` button — the capture showed one
        // red "Sign out" capsule floating over undimmed content, so the only way to back out of a
        // destructive confirmation was to tap outside it, which is undiscoverable. An alert is the
        // presentation that guarantees the three things this moment needs: a dimming scrim, an
        // explicit Cancel, and the destructive verb rendered as destructive. The panel's REVIEW
        // lens read these as hand-rolled and HIG/MOTION both verified in code that they are
        // genuine `.alert`s in iOS 26's left-aligned style — the dispute is settled: keep them.
        .alert(AccountCopy.signOutTitle, isPresented: $confirmSignOut) {
            Button(Copy.Confirm.cancel, role: .cancel) {}
            Button(AccountCopy.signOut, role: .destructive) { performSignOut() }
        } message: {
            Text(signOutMessage)
        }
        .alert(AccountCopy.deleteTitle, isPresented: $confirmDelete) {
            Button(Copy.Confirm.cancel, role: .cancel) {}
            Button(AccountCopy.deleteConfirm, role: .destructive) { performDelete() }
        } message: {
            Text(deleteMessage)
        }
        .alert(AccountCopy.deleteFailedTitle,
               isPresented: Binding(get: { deleteFailure != nil },
                                    set: { if !$0 { deleteFailure = nil } })) {
            Button(Copy.Action.done, role: .cancel) { deleteFailure = nil }
        } message: {
            Text(deleteFailure ?? "")
        }
        .alert(Copy.Account.signOutFailedTitle, isPresented: $signOutFailed) {
            Button(Copy.Action.done, role: .cancel) { signOutFailed = false }
        } message: {
            Text(Copy.Account.signOutFailedMessage)
        }
        .alert(Copy.Notice.alertsOffTitle, isPresented: $askOpenSettings) {
            Button(Copy.Notice.openSettings) { open(URL(string: UIApplication.openSettingsURLString)) }
            Button(Copy.Confirm.notNow, role: .cancel) {}
        } message: {
            Text(Copy.Notice.alertsOffMessage)
        }
        // Discard permanently throws away a write the user made. It names the change it is about to
        // destroy — "Discard" alone beside a show name is genuinely ambiguous about its object.
        .alert(Copy.Confirm.discardChangeTitle,
               isPresented: Binding(get: { discardTarget != nil },
                                    set: { if !$0 { discardTarget = nil } })) {
            Button(Copy.Confirm.cancel, role: .cancel) { discardTarget = nil }
            Button(Copy.Confirm.discardChangeConfirm, role: .destructive) {
                if let id = discardTarget { sync.discard(id) }
                discardTarget = nil
            }
        } message: {
            Text(discardMessage)
        }
    }

    /// Where the wash has to be gone by: the top edge of the stats plate. Measured at rest; the
    /// fallback covers the first frame before any geometry has been reported.
    private var washFadeEnd: CGFloat { shelfTop > 120 ? shelfTop : 260 }

    /// Reading order: who, what they are watching, then the controls — the App Store account
    /// sheet's order. A plate of three display numerals sat between the name and the shelf and
    /// read as a dashboard; the counts are one quiet line under the name now.
    @ViewBuilder
    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity
            watchingShelf.padding(.top, ThemeSpace.x6)
            if !sync.failedChanges.isEmpty {
                syncSection.padding(.top, ThemeMetrics.sectionGap)
            }
            community.padding(.top, ThemeMetrics.sectionGap)
            settings.padding(.top, ThemeMetrics.sectionGap)
            if sync.failedChanges.isEmpty {
                syncFootnote.padding(.top, ThemeSpace.x2)
            }
            accountSection.padding(.top, ThemeMetrics.sectionGap)
            signOutSection.padding(.top, ThemeMetrics.sectionGap)
            colophon.padding(.top, ThemeSpace.x10)
            // Delete account below the colophon, not 10 pt under Sign out: one of these is
            // routine and reversible, the other is not, and the layout should never let a thumb
            // confuse them. This is where iOS Settings puts it too.
            deleteSection.padding(.top, ThemeSpace.x8)
        }
    }

    // MARK: - Identity

    /// Who: the disc, the name, how this device is signed in, and the library in one line — a
    /// leading row, the way the App Store's and Settings' account rows are built. The centred
    /// 72-pt disc under a display-size name was a template's opening, not an account's.
    private var identity: some View {
        HStack(alignment: .center, spacing: ThemeSpace.x4) {
            avatar
            VStack(alignment: .leading, spacing: ThemeSpace.x0_5) {
                Text(accountName)
                    .type(ThemeType.showTitleL)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // "Signed in" under an email address said nothing (review, 5 Sep); the line is
                // drawn only when it names something.
                if !provenance.isEmpty {
                    Text(provenance)
                        .type(ThemeType.metadata)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .lineLimit(1)
                }
                if let librarySummary {
                    Text(librarySummary)
                        .type(ThemeType.metadata)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .padding(.top, ThemeSpace.x0_5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ThemeSpace.x1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signed in as \(accountName)")
        .accessibilityValue([provenance, librarySummary].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }

    /// "635 episodes · 5 watching · 13 watched": the plate's three numerals as one fact.
    private var librarySummary: String? {
        var parts: [String] = []
        if let n = episodesWatched { parts.append(Copy.episodes(n)) }
        for status in [WatchStatus.watching, .completed] {
            if let n = count(of: status), n > 0 { parts.append("\(n) \(Copy.Status(status).lowercased())") }
        }
        // Three numerals, one line. The minor statuses wrapped "6 planned" onto a line of its
        // own (review, 5 Sep); they are the shelf's, not the identity's.
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Three of the account's own covers, fanned. The screen's subject is a library and it drew no
    /// image at all — the code even documented removing the art rather than fixing the crop that
    /// made it ugly. These posters are already decoded in `ImageCache`; the fan costs nothing and it
    /// is the only place on a settings surface where identity art belongs.
    ///
    /// Separation is by LIGHT, not by fading the artwork: the outer cards were flattened to 0.82
    /// with a hairline between them, so the trio read as one torn strip. Each card carries its own
    /// contact shadow and the centre one the hero shadow, which is what makes three overlapping
    /// objects read as three objects (m11).
    private var posterFan: some View {
        ZStack {
            ForEach(Array(fanCovers.enumerated()), id: \.offset) { i, cover in
                let isCentre = i == fanCovers.count / 2
                PosterSlot(url: cover,
                           width: PosterSize.focus.size.width,
                           height: PosterSize.focus.size.height,
                           radius: PosterSize.focus.radius,
                           shadow: isCentre ? .artHero : .art)
                    .rotationEffect(.degrees(fanAngle(i)), anchor: .bottom)
                    .offset(x: fanOffset(i))
                    .opacity(isCentre ? 1 : 0.92)
                    .zIndex(isCentre ? 1 : 0)
            }
        }
        .accessibilityHidden(true)
    }

    private func fanAngle(_ i: Int) -> Double {
        guard fanCovers.count > 1 else { return 0 }
        return [-7.0, 0, 7.0][i]
    }

    private func fanOffset(_ i: Int) -> CGFloat {
        guard fanCovers.count > 1 else { return 0 }
        return [-58, 0, 58][i]
    }

    /// Covers loaded right now, in the model's urgency order (`orderedLibrary`).
    private var liveCovers: [String] {
        let covers = orderedLibrary.compactMap(\.portraitArt)
        if covers.count >= 3 { return Array(covers.prefix(3)) }
        return Array(covers.prefix(1))
    }

    /// Up to three covers. Always 1 or 3 — a two-poster "fan" has no centre. When the library has
    /// not loaded (offline, cold launch) the last three are drawn from the snapshot: `URLCache`
    /// still has the bytes, so the fan survives the failure instead of being deleted by it (M4).
    private var fanCovers: [String] {
        liveCovers.isEmpty ? snapshot.covers : liveCovers
    }

    /// The account's letter, on the one warm disc this screen is allowed.
    ///
    /// `AccountDisc` with `AuthManager.identity` — the SAME derivation the feed's header disc uses. Two
    /// independent ones produced "U" there (off the raw Clerk id) and "Y" here (off this screen's
    /// own fallback label): one user, two meaningless letters, one tap apart. It never draws
    /// `person.fill`; with nothing nameable it draws the brand mark.
    private var avatar: some View {
        AccountDisc(identity: auth.identity, diameter: 56)
            // A ring of canvas, not a hole in the artwork. The disc no longer overlaps the fan, so
            // there is nothing to punch through — the ring is what separates it from the wash.
            .overlay(Circle().strokeBorder(ThemeColor.hairline, lineWidth: 1).padding(-5))
            .shadow(.art)
            .accessibilityHidden(true)
    }

    // MARK: - Library counts

    /// Every EPISODE the account has marked — the story's episodes (`isMainStory`), capped at
    /// what has aired. 81 House of the Dragon featurettes and 13 marks on an unaired season sat
    /// inside "1,319 episodes" (review, 23 Sep).
    private var episodesWatched: Int? {
        if !appModel.library.isEmpty {
            let now = appModel.now
            return appModel.library.reduce(0) { total, f in
                total + f.parts.filter { $0.isMainStory && $0.kind != .movie }
                    .reduce(0) { $0 + min($1.progress, max($1.markTarget(now: now), 0)) }
            }
        }
        return sync.lastSyncedAt == nil ? nil : 0
    }

    private func count(of status: WatchStatus) -> Int? {
        if !appModel.library.isEmpty {
            return appModel.library.filter { $0.status == status }.count
        }
        if let known = snapshot.counts[status.rawValue] { return known }
        // A library that loaded successfully and is empty is a real zero. One that has never
        // arrived is unknown, and unknown is not zero.
        return sync.lastSyncedAt == nil ? nil : 0
    }

    /// Statuses with no tile of their own. "Paused" appeared in "Black Clover · Moved to Paused"
    /// and nowhere else in the app — a user who paused a show watched Watching drop by one and saw
    /// nothing appear anywhere (M13). It gets a line here whenever it is non-zero, which keeps the
    /// three-up strip (the best-composed object on the screen) intact.
    private var minorStatusLine: String? {
        // Planned joins the line (2 Sep): the plate's third tile is the episodes total now, and a
        // plan is a smaller fact about a library than what has actually been watched.
        let parts = [WatchStatus.planned, .paused, .dropped].compactMap { status -> String? in
            guard let n = count(of: status), n > 0 else { return nil }
            return "\(n) \(Copy.Status(status).lowercased())"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Watching (the person's television, as art)

    /// The shows the account is watching, in the order Today ranks them: what has a new episode,
    /// then what is mid-season, then the rest. This is the one thing a profile in a TV app should
    /// show that a settings screen cannot — the screen used to go straight from three numbers to
    /// a sync row. Netflix's own profile tab opens on the person's list for the same reason.
    ///
    /// EVERY Watching show, the live ones first: the shelf is headed "Watching" under a line that
    /// says "6 watching", and it stopped at the three with a live claim (review, 23 Sep).
    private var shelfItems: [Franchise] {
        let live = appModel.watchingShelf
        var seen = Set(live.map(\.id))
        var wider = live
        for f in appModel.library where f.effectiveStatus == .watching && seen.insert(f.id).inserted {
            wider.append(f)
        }
        return Array(wider.prefix(12))
    }

    @ViewBuilder
    private var watchingShelf: some View {
        let items = shelfItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
                SectionHeaderRow(Copy.Label.watching,
                                 actionLabel: onOpenLibrary == nil ? nil : Copy.Action.seeAll,
                                 action: onOpenLibrary.map { open in { dismiss(); open(.watching) } })
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                        ForEach(items) { f in
                            let caption = shelfCaption(f)
                            // Library's Watching shelf, the same anatomy (review i3: one name,
                            // two shelves) — the show's own poster naming it, the fact in the band.
                            ArtworkPoster(url: f.tilePoster.url, name: f.tilePoster.name, title: f.displayTitle,
                                          detailInset: ThemeSpace.x2,
                                          detailsInBand: true,
                                          fixedAspect: 2.0 / 3.0,
                                          onOpen: { if let onOpenDetail { dismiss(); onOpenDetail(f.id) } }) {
                                if PosterCaption.style == .band {
                                    Text(caption?.text ?? "")
                                        .type(ThemeType.caption)
                                        .foregroundStyle(caption?.lead == true ? ThemeColor.accent : ThemeColor.textPrimary)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2, reservesSpace: true)
                                        .minimumScaleFactor(0.85)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    PosterCaptionText(title: f.displayTitle, fact: caption?.text, lead: caption?.lead ?? false)
                                }
                            }
                            .frame(width: PosterSize.todayShelf.size.width)
                            .accessibilityLabel([f.displayTitle, caption?.text].compactMap { $0 }.joined(separator: ", "))
                            .accessibilityHint(onOpenDetail == nil ? "" : Copy.Accessibility.opensTheShowHint)
                        }
                    }
                    .padding(.leading, ThemeMetrics.gutter)

                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                // Art may run off the trailing edge; TYPE may not. See `shelfScroller`.
                .shelfScroller()
                // The section sits inside the page gutter; the shelf runs edge to edge.
                .padding(.horizontal, -ThemeMetrics.gutter)
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { y in
                // At REST only, and only when it moved: `<= 1` was also true through a
                // rubber-band pull, where the shelf's global edge changes every frame — and each
                // write re-ran this whole body under the finger (sampled 5 Sep: 500-ms stalls on
                // a pull at the top). `shelfTop` is the resting edge; it is measured once.
                if scroll.y == 0, abs(y - shelfTop) > 0.5 { shelfTop = y }
            }
        }
    }

    /// Today's shelf-caption grammar, verbatim: a forward-looking fact is amber, a state is grey.
    private func shelfCaption(_ f: Franchise) -> (text: String, lead: Bool)? {
        switch appModel.shelfState(of: f) {
        case .newEpisode:
            // The count Today's badge carries at the same minute (review, 5 Sep: "New
            // episode" here, "3 EPISODES BEHIND" there).
            let behind = f.releasingPart.map { $0.behind(now: now, anchor: f.timeAnchor) } ?? 0
            // Amber only while the drop is today's fact (review i4): the Up next card prints the
            // same count in grey, and one screen may not read one number two ways.
            let struck = f.lastAired(now: now).map { Formatting.dayDiff(ts: $0, now: now, anchor: f.timeAnchor) == 0 } ?? false
            return behind > 1 ? (Copy.Progress.behind(behind), struck) : (Copy.Label.newEpisode, true)
        case .backlog:
            guard let p = f.resumePart else { return nil }
            // The show page's and All titles' words for the same show: a count of what you are
            // behind while it airs, "Episode N next" once its run is over (review, 23 Sep: Bleach
            // was "Episode 3 next" here and "6 episodes behind" everywhere else).
            if p.isReleasing { return (Copy.Progress.behind(f.continueBacklog), false) }
            // A film is named, never "Episode 1 next" (iteration 2: Demon Slayer's film).
            if p.kind == .movie { return (p.canonicalLabel, false) }
            // Once the run is over, what is LEFT of the story — Today's badge and the show page
            // say "63 episodes left" for the same show (review i4, P21: "Episode 3 next" here).
            let left = max(p.markTarget(now: now) - p.progress, f.seriesLeft(now: now))
            return (left > 1 ? Copy.Progress.left(left) : Copy.Progress.lastEpisodeOfTheSeason, false)
        case .airingWait:
            if let at = f.nextAiring(now: now) {
                return (TemporalCopy.airsCompact(at: at, now: now, source: f.source), true)
            }
            return (Copy.Progress.caughtUp, false)
        case .premiereSoon:
            return (TemporalCopy.returns(at: appModel.nextPremiere(of: f), now: now, source: f.source), true)
        case nil: return (Copy.Progress.caughtUp, false)
        }
    }

    // MARK: - Sync

    /// Drawn only while something failed: the summary row is a heading, not a button, because
    /// the plate below it carries real controls and a row cannot be two things.
    private var syncSection: some View {
        GroupedList(header: "Sync") {
            ProfileRowLabel(symbol: syncGlyph,
                            symbolTint: syncTint,
                            title: syncTitle,
                            separator: true) {
                if sync.canRetryAny && sync.failedChanges.count > 1 {
                    Button(AccountCopy.retryAll) { sync.retryAll() }
                        .buttonStyle(InlineLinkButtonStyle())
                }
            }

            // No glyph on the detail rows: the section's state is declared ONCE, above them. A
            // stack of identical triangles down one plate is the same defect as a column of
            // grey check discs — the alarm stops being an alarm.
            ForEach(Array(sync.failedChanges.enumerated()), id: \.element.id) { i, change in
                failureRow(change, isLast: i == sync.failedChanges.count - 1)
            }
        }
    }

    /// The calm state, as the footnote iOS prints under a group ("Last backup: …"): one line,
    /// no plate, no button. A "Sync" plate with its own control beside a check mark was the most
    /// SaaS object on the screen for a fact that needs no action while it is true.
    private var syncFootnote: some View {
        HStack(alignment: .firstTextBaseline, spacing: ThemeSpace.x2) {
            if let glyph = syncGlyph {
                AppGlyph(systemName: glyph)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(syncTint)
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.mini).tint(ThemeColor.textTertiary)
            }
            Text([syncTitle, syncStamp].compactMap { $0 }.joined(separator: " \u{00B7} "))
                .type(ThemeType.caption)
                .foregroundStyle(ThemeColor.textTertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, ThemeSpace.x4)
        .accessibilityElement(children: .combine)
    }

    /// One failed write, with the two things a user can actually do about it.
    ///
    /// The shipped row put "Black Clover · Moved to Paused" and "Couldn't reach the server · 8:44
    /// PM" through a text column narrowed by a fixed action lane, so the title wrapped at half the
    /// available width, the middot dangled at a line end and the clock was orphaned on line two —
    /// while Retry and Discard sat as two ~28-pt words in two competing colours ~20 pt apart, with
    /// the destructive one a mis-tap away from the recovery one (B3, M3).
    ///
    /// Four slots, in reading order: WHAT (the show, plus when it failed), WHICH CHANGE, WHY, and
    /// then — on its own row, clear of the text — WHAT TO DO.
    private func failureRow(_ change: FailedChange, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: ThemeSpace.x1) {
            HStack(alignment: .firstTextBaseline, spacing: ThemeSpace.x3) {
                Text(change.title)
                    .type(ThemeType.rowTitle)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: ThemeSpace.x2)
                // Its own slot. Joined to the reason with a middot it was the half that wrapped.
                Text(Formatting.fmtTime(change.at))
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Text(change.command)
                .type(ThemeType.rowMeta)
                .foregroundStyle(ThemeColor.textSecondary)
                .lineLimit(2)
            Text(failureReason(change))
                .type(ThemeType.metadata)
                .foregroundStyle(ThemeColor.textTertiary)
                .lineLimit(2)

            // Shape, not only colour, tells these two apart: one is a bordered control and the
            // other is a plain destructive verb. Two identically-shaped capsules differing only in
            // ink is the pattern that makes a destructive action a mis-tap.
            actionRow(change)
                .padding(.top, ThemeSpace.x1)
        }
        .padding(.leading, ThemeSpace.x4 + 22 + ThemeSpace.x3)
        .padding(.trailing, ThemeSpace.x4)
        .padding(.vertical, ThemeSpace.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(ThemeColor.separatorQuiet).frame(height: 1)
                    .padding(.leading, ThemeSpace.x4 + 22 + ThemeSpace.x3)
            }
        }
        .contextMenu {
            if change.canRetry(sync) {
                Button { sync.retry(change.id) } label: {
                    AppGlyphLabel(Copy.Action.retry, systemName: "arrow.clockwise")
                }
            }
            Button(role: .destructive) { discardTarget = change.id } label: {
                AppGlyphLabel(Copy.Confirm.discardChangeConfirm, systemName: "trash")
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Retry and Discard change, on their own row, 20 pt apart, both real 44-pt targets. At
    /// accessibility sizes they stack rather than shrink.
    @ViewBuilder
    private func actionRow(_ change: FailedChange) -> some View {
        let layout = isAX
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: ThemeSpace.x2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: ThemeSpace.x5))
        HStack {
            Spacer(minLength: 0)
            layout {
                if change.canRetry(sync) {
                    Button(Copy.Action.retry) { sync.retry(change.id) }
                        .buttonStyle(CompactActionButtonStyle())
                }
                Button(Copy.Confirm.discardChangeConfirm) { discardTarget = change.id }
                    .buttonStyle(InlineLinkButtonStyle(destructive: true))
                    .accessibilityHint("Throws this change away. It can\u{2019}t be undone.")
            }
        }
    }

    /// "Couldn't reach the server". The reason string comes from `Copy.Notice.reason(_:)` at record
    /// time and is shared with the sync banner on the roots; softening "Server error" belongs in
    /// `Copy` so both say the same thing, and that edit is filed as a shared request. Until it
    /// lands this maps the one engineer-vocabulary string on the way to the screen — and passes
    /// anything else through, so it becomes a no-op the moment the shared copy changes.
    private func failureReason(_ change: FailedChange) -> String {
        change.reason == Copy.Notice.serverError ? AccountCopy.couldNotReachServer : change.reason
    }

    /// The confirmation names the change it is about to destroy.
    private var discardMessage: String {
        guard let id = discardTarget,
              let change = sync.failedChanges.first(where: { $0.id == id }) else {
            return Copy.Confirm.discardChangeMessage
        }
        return "\u{201C}\(change.title) \u{00B7} \(change.command)\u{201D}. "
            + Copy.Confirm.discardChangeMessage
    }

    /// The state, in one sentence. **Offline is tested first**: the shipped order tested
    /// `checking` first, so a device whose `NWPathMonitor` had already reported no path still
    /// watched "Checking for changes" spin until the request timed out, and nothing on the screen
    /// ever said the user was offline (M4).
    private var syncTitle: String {
        if !sync.failedChanges.isEmpty { return Copy.Toast.syncFailed(sync.failedChanges.count) }
        if !sync.isOnline { return EmptyStateCopy.offlineCached.title }
        if sync.checking { return Copy.State.checkingForChanges }
        // Nothing has arrived THIS LAUNCH. "Not synced yet" is only true if there is also nothing
        // remembered — with a snapshot's counts and posters on screen it is the screen
        // contradicting itself, and it was the wording that left "Checking for changes" looking
        // like the terminal state of an unreachable server.
        if sync.lastSyncedAt == nil {
            return snapshot.isEmpty ? Copy.State.neverSynced : Copy.State.couldNotCheck
        }
        // "Everything synced / Just now / Sync now" said "sync" three times and stated one thing
        // twice. Three slots, three words, same information: `Up to date` / `Checked just now` /
        // `Sync` (M12). Mapped here rather than in `Copy.swift`, which this track does not own; the
        // string change is filed as a shared request, and this becomes a no-op when it lands.
        return AccountCopy.upToDate
    }

    /// Just the WHEN — and never a stamp of the last successful check underneath "1 change couldn't
    /// sync", which is a contradiction.
    private var syncStamp: String? {
        guard sync.failedChanges.isEmpty else { return nil }
        if !sync.isOnline { return AccountCopy.offlineSupporting }
        if sync.checking { return nil }
        guard let at = sync.lastSyncedAt else {
            // Say what is on screen. The counts and the fan are real; they are just not fresh.
            return snapshot.isEmpty ? nil : AccountCopy.showingSavedCopy
        }
        return "Checked \(stampWord(at).lowercasedFirstWord())"
    }

    /// "Just now" · "12 min ago" · "9:41 AM" · "Aug 19". Same ladder as `Copy.synced(at:now:)`
    /// without the verb the title already carries.
    private func stampWord(_ ts: Int64) -> String {
        let elapsed = max(0, now - ts)
        let minutes = Int(elapsed / Formatting.minuteMs)
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if Formatting.dayDiff(ts: ts, now: now) == 0 { return Formatting.fmtTime(ts) }
        return TemporalCopy.dateWord(ts, now: now, anchor: .local)
    }

    /// `nil` means "a spinner belongs in this column instead" — which is how the row guarantees it
    /// never shows two indicators for one wait.
    private var syncGlyph: String? {
        if !sync.failedChanges.isEmpty { return "exclamationmark.triangle.fill" }
        if !sync.isOnline { return "wifi.slash" }
        if sync.checking { return nil }
        if sync.lastSyncedAt == nil {
            return snapshot.isEmpty ? "arrow.triangle.2.circlepath" : "wifi.exclamationmark"
        }
        // A bare check, in the text ramp. The shipped glyph was a filled `success` disc — the only
        // green in the app, spent decorating a settled state, in a band that already held an amber
        // "Sync now" and an amber "Done" (M11). Colour is not what says "fine"; the sentence is.
        return "checkmark"
    }

    private var syncTint: Color {
        // `warning`, not `destructive`. One token for every non-destructive failure edge: Schedule
        // renders the same class of failure in warning yellow, and red beside a red Delete account
        // row makes a recoverable write failure look like data loss (M3, SYS-4f).
        if !sync.failedChanges.isEmpty { return ThemeColor.warning }
        if !sync.isOnline { return ThemeColor.textSecondary }
        if sync.lastSyncedAt == nil {
            // A read that could not be made is the same class of edge as a write that could not:
            // one `warning` token for both, never `destructive`, which is for destructive verbs.
            return snapshot.isEmpty ? ThemeColor.textTertiary : ThemeColor.warning
        }
        return ThemeColor.textSecondary
    }

    /// Offline, there is nothing for Sync to do, so the control is not drawn: a live-looking button
    /// that cannot work is worse than no button.
    private var syncCanRefresh: Bool { sync.isOnline && !sync.checking }

    // MARK: - Community (iD13)

    /// What the social layer keeps for this account, and the controls App Review 1.2 asks to be
    /// reachable: Saved (the only place saved posts live), how the account appears on its replies,
    /// who it has blocked, which shows it muted, and the rules it agreed to.
    ///
    /// With replies switched off on the server (`feedCapabilities.comments`, spec §4.9) the group is
    /// Saved and Muted shows only — the two that still do something. The name and username, the
    /// rules and the block list are the plumbing of user content, and with no user content on
    /// screen they are rows that promise a community the build does not have (the server answers
    /// the identity writes and new blocks `404 comments disabled` then, too).
    private var community: some View {
        let comments = appModel.feedCapabilities.comments
        return GroupedList(header: Copy.Social.communityHeader) {
            communityLink(.saved, symbol: "bookmark", title: Copy.Social.savedTitle)
            if comments {
                communityLink(.identity, symbol: "at", title: Copy.Social.identityRow, value: identityValue)
                communityLink(.blocked, symbol: "person.crop.circle.badge.xmark", title: Copy.Social.blockedTitle)
            }
            communityLink(.muted, symbol: "speaker.slash", title: Copy.Social.mutedTitle, separator: comments)
            if comments {
                ProfileRow(symbol: "text.book.closed",
                           title: Copy.Social.rulesTitle,
                           separator: false,
                           action: { showRules = true }) {
                    trailingGlyph("chevron.forward", tint: ThemeColor.textDisabled, scale: 0.86)
                }
            }
        }
        // Once per session (the model keeps the answer); the identity row's value waits for it.
        .task { await appModel.loadSocialProfile() }
    }

    /// "@mira.k" once the account has chosen one; "Not set" once the server has said it has not;
    /// nothing while the question is still out (a guess would be a claim either way).
    private var identityValue: String? {
        guard let profile = appModel.socialProfile else { return nil }
        return profile.handle.map { Copy.Social.handle($0) } ?? Copy.Social.identityNotSet
    }

    private func communityLink(_ route: ProfileRoute, symbol: String, title: String,
                               value: String? = nil, separator: Bool = true) -> some View {
        NavigationLink(value: route) {
            ProfileRowLabel(symbol: symbol, title: title, separator: separator, indicateWait: false) {
                HStack(spacing: ThemeSpace.x2) {
                    if let value {
                        Text(value)
                            .type(ThemeType.metadata)
                            .foregroundStyle(ThemeColor.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    trailingGlyph("chevron.forward", tint: ThemeColor.textDisabled, scale: 0.86)
                }
            }
        }
        .buttonStyle(GroupedRowPressStyle())
        .accessibilityValue(value ?? "")
    }

    /// The pages this sheet pushes on its own stack.
    @ViewBuilder
    private func destination(_ route: ProfileRoute) -> some View {
        switch route {
        case .export:
            ExportOptionsView(appModel: appModel, indicatorSize: indicatorSize)
        case .saved:
            SavedPostsView(onOpenPost: openSavedPost, onOpenShow: { id in
                dismiss()
                // The presenter's route when it gave one; else the model's pending show, which
                // RootView answers the same way (Today, every feed cover closed, the show pushed).
                if let onOpenDetail { onOpenDetail(id) } else { appModel.pendingOpen = id }
            })
        case .identity:
            IdentitySetupView(mode: .edit, onDone: { _ in
                // Back to the sheet, whose row now reads the new handle off the model.
                if path.last == .identity { path.removeLast() }
            })
        case .blocked:
            BlockedAccountsView()
        case .muted:
            MutedShowsView()
        }
    }

    /// A saved post opens on Today, the feed's own page for it: the feed closes this sheet first
    /// and pushes the post once it is down. Without that hand-off (a presenter that set none) the
    /// same route goes through the model's pending route, which RootView answers the same way.
    private func openSavedPost(_ postId: String) {
        if let openFeedRoute {
            openFeedRoute(.post(id: postId))
        } else {
            dismiss()
            appModel.pendingRoute = .post(postId: postId, commentId: nil)
        }
    }

    // MARK: - Settings

    private var settings: some View {
        GroupedList(header: "Settings") {
            // First: it decides what every suggestion in the app is.
            ProfileRow(symbol: "tv",
                       title: Copy.Watching.row,
                       action: { showAudience = true }) {
                HStack(spacing: ThemeSpace.x2) {
                    Text(Copy.Watching.name(appModel.audience))
                        .type(ThemeType.metadata)
                        .foregroundStyle(ThemeColor.textTertiary)
                    trailingGlyph("chevron.forward", tint: ThemeColor.textTertiary)
                }
            }
            .accessibilityValue(Copy.Watching.name(appModel.audience))
            // A list kept elsewhere (AniList, MyAnimeList, TV Time), brought in — any time, not
            // only at first run.
            ProfileRow(symbol: "clock.arrow.circlepath",
                       title: Copy.Import.row,
                       action: { showImport = true }) {
                trailingGlyph("chevron.forward", tint: ThemeColor.textTertiary)
            }
            ProfileRow(symbol: "bell",
                       title: "Notifications",
                       action: { notificationsTapped() }) {
                HStack(spacing: ThemeSpace.x2) {
                    // The row said nothing about the one thing it is for. A user who declined
                    // the system prompt had no way to learn, here, that alerts are off.
                    // The state, always (interactive review: the row carried no value and threw
                    // the user out to Settings on a not-yet-asked account).
                    Text(notificationsOn.map { $0 ? Copy.State.on : Copy.State.off } ?? Copy.State.ask)
                        .type(ThemeType.metadata)
                        .foregroundStyle(ThemeColor.textTertiary)
                    // This row leaves the app — once the system has been asked. Before that the
                    // tap asks IN the app, so the external arrow and its hint would promise a
                    // trip to Settings that does not happen (review, 23 Sep).
                    if notificationsOn != nil {
                        trailingGlyph("arrow.up.forward", tint: ThemeColor.textTertiary)
                    } else {
                        trailingGlyph("chevron.forward", tint: ThemeColor.textTertiary)
                    }
                }
            }
            .accessibilityValue(notificationsOn.map { $0 ? Copy.State.on : Copy.State.off } ?? Copy.State.ask)
            .accessibilityHint(notificationsOn == nil ? "" : "Opens Settings")
            .task { await refreshNotificationsOn() }
            // Back from Settings: the sheet is still up, so the row re-reads the answer.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await refreshNotificationsOn() }
            }

            ProfileRowLabel(symbol: "hand.tap",
                            title: "Haptics") {
                // `.fixedSize()` is the whole fix for the stretched switch: without it the row's
                // layout stretched the track to ~61×29 against the native 51×31 and rendered the
                // knob as a rounded pill instead of a circle. It is a real `Toggle`, not inside a
                // `Button`'s label, so VoiceOver announces the switch trait and its On/Off value.
                // Amber, not system green: a switch reports selection, and selection in this app
                // is one colour.
                Toggle("Haptics", isOn: $hapticsOn)
                    .labelsHidden()
                    .fixedSize()
                    .tint(ThemeColor.accent)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            }

            #if DEBUG
            // DEBUG ONLY. The QA account is permanently caught up, so the states Today exists to
            // serve cannot be reached on a real device by tapping the icon — and a launch
            // argument (`-demoBusy 1`) is not something you can pass from the Home screen. This
            // row is the same fixture behind a switch, so the busy screen can be FELT on a phone
            // rather than judged from a video (user, 6 Sep: "I need to see it visually man on my
            // phone to get a feel of it"). Compiled out of Release entirely.
            ProfileRowLabel(symbol: "ladybug",
                            title: "Demo: episode waiting") {
                Toggle("Demo: episode waiting", isOn: $demoBusy)
                    .labelsHidden()
                    .fixedSize()
                    .tint(ThemeColor.accent)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            }
            .onChange(of: demoBusy) { _, on in
                UserDefaults.standard.set(on, forKey: "demoBusy")
                // The fixture is applied as the payload decodes, so the library has to come
                // round again for the switch to mean anything.
                Task { await appModel.reload() }
            }
            #endif

            // A PUSH, not a menu: the pushed screen gives each format a title and a real support
            // line, and covers nothing (the menu anchored itself over the row that raised it).
            NavigationLink(value: ProfileRoute.export) {
                ProfileRowLabel(symbol: "square.and.arrow.up",
                                title: AccountCopy.export,
                                separator: false) {
                    trailingGlyph("chevron.forward", tint: ThemeColor.textDisabled, scale: 0.86)
                }
            }
            .buttonStyle(GroupedRowPressStyle())
        }
        .onChange(of: hapticsOn) { _, on in
            FeedbackCoordinator.enabled = on
            // The system switch already plays its own click; a second one was a double tap.
        }
    }

    // MARK: - Account (App Store guideline 5.1.1)

    /// Privacy, Terms and a way to reach a human — the three things guideline 5.1.1 asks for
    /// besides deletion.
    ///
    /// Every destination comes from a build setting through `AppConfig`, never a URL written into
    /// copy: a placeholder baked into a shipped string is a broken Privacy Policy link, which is
    /// itself a rejection.
    ///
    /// **The case rule, settled (m6):** Title Case is for the NAMES OF WORKS, and a privacy policy
    /// and terms of use are named documents — "Privacy Policy", "Terms of Use". Everything else on
    /// this screen is a verb phrase in sentence case, including "Contact support", which is an
    /// action and not the name of a document. Two conventions, one rule, no exceptions.
    private var accountSection: some View {
        GroupedList(header: "Account") {
            legalRow(symbol: "hand.raised", title: AccountCopy.privacy, url: AppConfig.privacyURL,
                     hint: "Opens in Safari", isLink: true)
            legalRow(symbol: "doc.text", title: AccountCopy.terms, url: AppConfig.termsURL,
                     hint: "Opens in Safari", isLink: true)
            legalRow(symbol: "envelope",
                     title: AccountCopy.support,
                     subtitle: AppConfig.supportEmail,
                     url: AppConfig.supportURL,
                     hint: "Opens Mail",
                     isLink: false,
                     separator: false)
        }
    }

    private func legalRow(symbol: String, title: String, subtitle: String? = nil,
                          url: URL?, hint: String, isLink: Bool,
                          separator: Bool = true) -> some View {
        ProfileRow(symbol: symbol,
                   title: title,
                   subtitle: subtitle,
                   separator: separator,
                   action: { open(url) }) {
            trailingGlyph("arrow.up.forward", tint: ThemeColor.textTertiary)
        }
        .accessibilityHint(hint)
        .accessibilityAddTraits(isLink ? [.isLink] : [])
    }

    // MARK: - Sign out / delete

    /// A `GroupedRow`, not a centred word. The colour carries the weight — but only on the LABEL:
    /// a fully saturated destructive icon on a routine, reversible action made Sign out and Delete
    /// account read as a pair of equal choices (M8).
    private var signOutSection: some View {
        GroupedList {
            ProfileRow(symbol: "rectangle.portrait.and.arrow.right",
                       symbolTint: ThemeColor.textSecondary,
                       title: AccountCopy.signOut,
                       titleTint: ThemeColor.destructive,
                       separator: false,
                       action: { confirmSignOut = true }) {
                // Every other write in the app is optimistic and shows its result immediately; the
                // one that cannot be undone showed nothing at all, so a user who waited a second
                // tapped Sign out again.
                if signingOut {
                    ProgressView().controlSize(.small).tint(ThemeColor.textSecondary)
                        .frame(width: 44, height: 44)
                }
            }
            .disabled(signingOut || deleting)
            .accessibilityHint("Your library stays in your account")
        }
    }

    /// Its own plate, below the colophon: one of these two rows is reversible and the other is not,
    /// and the layout should never let a thumb confuse them.
    private var deleteSection: some View {
        GroupedList {
            ProfileRow(symbol: "trash",
                       symbolTint: ThemeColor.destructive,
                       title: AccountCopy.delete,
                       titleTint: ThemeColor.destructive,
                       subtitle: AccountCopy.deleteSubtitle,
                       separator: false,
                       action: { confirmDelete = true }) {
                if deleting {
                    ProgressView().controlSize(.small).tint(ThemeColor.destructive)
                        .frame(width: 44, height: 44)
                }
            }
            .disabled(signingOut || deleting)
            // VoiceOver carries a severity that colour alone no longer does.
            .accessibilityHint("Permanently deletes your account and library")
        }
    }

    /// One outcome, one supporting sentence. Two sentences delivering one reassurance is against
    /// the voice note (m8) — the pending-changes case earns its second clause because it carries a
    /// second fact.
    private var signOutMessage: String { Copy.Account.signOutMessage(pending: sync.failedChanges.count) }

    /// The blast radius, in the user's own numbers (shared with the suspended screen).
    private var deleteMessage: String { Copy.Account.deleteMessage(titles: appModel.library.count) }

    /// Not asked yet → the system prompt here, then the row reads its answer; asked → Settings.
    private func notificationsTapped() {
        if notificationsOn == nil {
            Task { @MainActor in
                _ = await EpisodeNotifications.shared.requestPermissionIfNeeded()
                await refreshNotificationsOn()
            }
        } else if notificationsOn == false {
            askOpenSettings = true
        } else {
            open(URL(string: UIApplication.openSettingsURLString))
        }
    }

    private func refreshNotificationsOn() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral: notificationsOn = true
        case .denied: notificationsOn = false
        default: notificationsOn = nil
        }
    }

    private func performSignOut() {
        FeedbackCoordinator.fire(.destructive)
        withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) {
            signingOut = true
        }
        Task {
            let signedOut = await auth.signOut()
            signingOut = false
            // Deletion had a failure alert; sign-out had none. Same moment, same answer.
            if !signedOut { signOutFailed = true }
        }
    }

    private func performDelete() {
        FeedbackCoordinator.fire(.destructive)
        withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) {
            deleting = true
        }
        Task {
            // Nothing the app sends may reach the server after the erasure: a late like, mark or
            // read would bring the account back (`prepareForErasure`).
            await appModel.prepareForErasure()
            do {
                try await AccountDeletion.deleteAccount(token: auth.currentToken)
                // The account is gone; the session must go with it, the snapshot too, and the sheet
                // with both. A deleted account may not leave its counts on the device — so the
                // model is wiped FIRST, and the wipe never depends on Clerk's sign-out succeeding.
                ProfileSnapshot.clear()
                appModel.teardown()
                await auth.accountErased()
                deleting = false
                dismiss()
            } catch {
                // Not deleted: what the erasure held back (marks, likes, replies) goes now.
                appModel.abortErasure()
                deleting = false
                deleteFailure = (error as? LocalizedError)?.errorDescription
                    ?? AccountDeletion.Failure.refused.errorDescription
            }
        }
    }

    // MARK: - About

    /// How the screen ends: the mark, the version, and the attribution the TMDB terms require —
    /// set as fine print, because that is what it is.
    private var colophon: some View {
        VStack(spacing: ThemeSpace.x2) {
            // The shared lockup (the filed hoist landed with the cohesion pass): one drawing of
            // the logo for the whole app — this footer had drifted into an accent-period variant
            // while Today's header drew the period in text ink.
            Wordmark(colophon: true)
            Text(version)
                .type(ThemeType.caption)
                .foregroundStyle(ThemeColor.textTertiary)
                .monospacedDigit()
            // Verbatim-correct and App Review looks for it — the STRING is untouched. Only the
            // MEASURE changes: at 300 pt the first line ended on the article "the", and narrowing
            // it further only bought a three-line set with "by TMDB." orphaned on the last (m3).
            // 330 pt is the width at which the two lines break after a noun.
            Text("Data from AniList and TMDB. This product uses the TMDB API but is not endorsed "
                 + "or certified by TMDB.")
                .type(ThemeType.caption)
                .foregroundStyle(ThemeColor.textDisabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
                .padding(.top, ThemeSpace.x2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Helpers

    /// A trailing indicator that scales with the row's text. Fixed-size glyphs shrank to specks
    /// against ~24-pt titles at AX1.
    private func trailingGlyph(_ symbol: String, tint: Color, scale: CGFloat = 1) -> some View {
        AppGlyph(systemName: symbol)
            .font(.system(size: indicatorSize * scale, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 44)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
    }

    private func open(_ url: URL?) {
        guard let url else {
            // A legal destination that is not configured is a build problem, not a runtime state
            // to render — it can never reach a shipping build, where `PRIVACY_POLICY_URL` /
            // `TERMS_URL` / `SUPPORT_EMAIL` are all set. It is logged rather than asserted: a
            // developer build that traps on a Privacy Policy tap is a worse debugging experience
            // than one line in the console, and QA runs against Debug builds.
            #if DEBUG
            print("[Profile] A legal or support destination is not configured for this build.")
            #endif
            return
        }
        openURL(url)
    }

    /// A Clerk user id is not a name. `AccountIdentity` already answers this, once, for every
    /// surface — this screen no longer decides it for itself.
    private var accountName: String { auth.identity.displayName }

    /// The one fact a profile screen exists to answer besides "who": how this device is signed in.
    ///
    /// "Developer session" is a debug string one build configuration away from a TestFlight
    /// screenshot, so it is gated (M5). A Release build that somehow reaches dev mode says the true
    /// thing instead of the embarrassing one.
    private var provenance: String {
        switch auth.identity.provenance {
        case .developer:
            #if DEBUG
            return "Developer session"
            #else
            return ""
            #endif
        default:
            return ""
        }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    /// The library in the model's urgency order (what has a new episode, then what is mid-season,
    /// then the rest) — so the sheet's wash and its poster fan are drawn from the shows the person
    /// is actually watching, instead of an unrelated one.
    private var orderedLibrary: [Franchise] {
        let ranked = appModel.outNow + appModel.keepWatching
        let rest = appModel.library.filter { f in !ranked.contains(where: { $0.id == f.id }) }
        return ranked + rest.filter { $0.status == .watching } + rest.filter { $0.status != .watching }
    }

    /// **The CENTRE card of the fan**, not the first title in the library.
    ///
    /// The wash claimed to be art-derived and was not: it took its colour from an off-screen cover
    /// and then forced the accent's hue, so the field was the same warm brown whichever three
    /// posters were on screen — the one screen that guarantees three covers took its colour from
    /// none of them (M6). It is now sampled from the poster the eye is actually resting on.
    private var washArtwork: String? {
        guard !fanCovers.isEmpty else { return nil }
        return fanCovers[fanCovers.count / 2]
    }
}

// MARK: - Copy

/// The strings this screen introduces. Not in `Copy.swift` because that table is shared design
/// system and this track does not own it; the destructive and legal vocabulary is kept in one
/// place here so no row can invent its own wording.
private enum AccountCopy {
    static let signOut = Copy.Action.signOut
    static let signOutTitle = Copy.Account.signOutTitle
    static let delete = Copy.Action.deleteAccount
    static let deleteSubtitle = Copy.Account.deleteSubtitle
    static let deleteTitle = Copy.Account.deleteTitle
    static let deleteConfirm = Copy.Account.deleteConfirm
    static let deleteFailedTitle = Copy.Account.deleteFailedTitle
    static let privacy = Copy.Action.privacyPolicy
    static let terms = Copy.Action.termsOfUse
    static let support = Copy.Action.contactSupport
    static let upToDate = Copy.Account.upToDate
    static let syncNow = Copy.Action.syncNow
    static let retryAll = Copy.Action.retryAll
    static let couldNotReachServer = Copy.Account.couldNotReachServer
    static let offlineSupporting = Copy.Account.offlineSupporting
    static let showingSavedCopy = Copy.Account.showingSavedCopy
    static let signedIn = Copy.Account.signedInWithClerk
    static let export = "Export library"
    static let exportSubtitle = "Every title with progress and status"
    /// **Not "for re-import".** There is no import path in this build, and the export screen is the
    /// one place a user reads when they are worried about their data — a false claim there is worse
    /// than a missing feature (B1). What the file IS, never what it could one day be fed back into.
    static let exportJSON = "JSON"
    /// The account's own copy from the server (`LibraryExport`), not only the library.
    static let exportJSONSub = Copy.Account.exportJSONSubtitle
    static let exportCSV = "CSV"
    static let exportCSVSub = "One row per title, for spreadsheets"
    static let exportFootnote = Copy.Account.exportFootnote
}

// MARK: - Routes

/// The pages Profile pushes inside its own sheet.
private enum ProfileRoute: Hashable {
    case export
    case saved
    case identity
    case blocked
    case muted
}

// MARK: - Export

/// Two formats, each with a real support line, on a pushed screen the row's chevron already
/// promised. The `Menu` this replaces anchored itself over the row that raised it and wrapped both
/// of its items to two lines (m12).
private struct ExportOptionsView: View {
    let appModel: AppModel
    let indicatorSize: CGFloat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GroupedList {
                    exportRow(format: .json,
                              title: AccountCopy.exportJSON,
                              subtitle: AccountCopy.exportJSONSub,
                              symbol: "curlybraces")
                    exportRow(format: .csv,
                              title: AccountCopy.exportCSV,
                              subtitle: AccountCopy.exportCSVSub,
                              symbol: "tablecells",
                              separator: false)
                }
                Text(AccountCopy.exportFootnote)
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .padding(.horizontal, ThemeSpace.x4)
                    .padding(.top, ThemeMetrics.labelGap)
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x4)
        }
        .scrollIndicators(.hidden)
        .background(ThemeColor.canvas.ignoresSafeArea())
        .brandNavigationTitle(AccountCopy.export)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func exportRow(format: LibraryExport.Format, title: String, subtitle: String,
                           symbol: String, separator: Bool = true) -> some View {
        ShareLink(item: LibraryExport(appModel: appModel, format: format),
                  preview: SharePreview("Previously library (\(title))")) {
            ProfileRowLabel(symbol: symbol,
                            title: title,
                            subtitle: subtitle,
                            separator: separator,
                            indicateWait: false) {
                AppGlyph(systemName: "square.and.arrow.up")
                    .font(.system(size: indicatorSize, weight: .semibold))
                    .foregroundStyle(ThemeColor.textTertiary)
                    .frame(width: 28, height: 44)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            }
        }
        .buttonStyle(GroupedRowPressStyle())
        .accessibilityLabel("Export as \(title)")
        .accessibilityHint(subtitle)
    }
}

private extension String {
    /// "Just now" → "just now", so it can follow a verb without shouting.
    func lowercasedFirstWord() -> String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

// MARK: - Snapshot

/// What the account looked like the last time its library actually arrived.
///
/// The screen had no memory at all, so an offline open collapsed from `fan + disc + name + counts +
/// sync + settings` to `disc + name + sync + settings`: the stats plate and the artwork were
/// REMOVED rather than degraded, and the user lost the only summary of their account exactly when
/// they could not verify it anywhere else (M4). Three integers and three URLs in `UserDefaults` is
/// the whole cost of the frame surviving the failure.
struct ProfileSnapshot: Equatable {
    var counts: [String: Int] = [:]
    var covers: [String] = []

    /// Nothing remembered. The screen tells "never synced" apart from "couldn't check" with this.
    var isEmpty: Bool { counts.isEmpty && covers.isEmpty }

    private static let countsKey = "profile.snapshot.counts"
    private static let coversKey = "profile.snapshot.covers"

    static func load() -> ProfileSnapshot {
        let d = UserDefaults.standard
        return ProfileSnapshot(counts: d.dictionary(forKey: countsKey) as? [String: Int] ?? [:],
                               covers: d.stringArray(forKey: coversKey) ?? [])
    }

    /// `nil` when there is nothing worth remembering — an empty library must never overwrite a real
    /// snapshot, because "the request failed" and "the account is empty" arrive as the same value.
    static func capture(_ library: [Franchise], covers: [String]) -> ProfileSnapshot? {
        guard !library.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for status in WatchStatus.allCases {
            counts[status.rawValue] = library.filter { $0.status == status }.count
        }
        return ProfileSnapshot(counts: counts, covers: covers)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(counts, forKey: Self.countsKey)
        d.set(covers, forKey: Self.coversKey)
    }

    static func clear() {
        let d = UserDefaults.standard
        d.removeObject(forKey: countsKey)
        d.removeObject(forKey: coversKey)
    }
}

// MARK: - Wash

/// The ambient field behind the identity block — the local stand-in for the shared `ArtBackdrop`
/// fix filed with this pass.
///
/// It draws NO image. `ArtBackdrop` blurs the poster's own top-left corner, which is why this
/// screen measured rgb(66,80,94) on one side against rgb(29,49,67) on the other: a blurred crop of
/// an off-centre region is lit by whatever happened to be in that region, and a 2.2× left-to-right
/// falloff reads as a bug, not as atmosphere. An elliptical field centred on the top edge is even
/// by construction.
///
/// Two things changed this round (M6):
///  • The tint is the CENTRE fan card's palette, resolved by the view that owns the fan.
///  • The hue is no longer PINNED to the accent. A straight 50/50 RGB mix with amber turned a steel
///    blue cover grey, so round 2 anchored the hue outright — and the field then read identically
///    whatever was in the library, i.e. exactly like a static brand gradient. It now travels 55 %
///    of the way from the artwork's hue to the brand's along the shorter arc: the app stays inside
///    a warm range, and a blue-led library is visibly bluer than a red-led one.
///  • It ENDS. The field used to run the whole scroll, so the SETTINGS plate was warm brown at the
///    top of the scroll and the ACCOUNT plate neutral grey further down — one component, two hues,
///    depending on scroll position. Its ramp now completes above the stats plate.
/// The wash, travelling with the content: the ONE view on this screen that reads the scroll
/// offset, so a scroll sample invalidates it and nothing else.
private struct ProfileWashTravel<Content: View>: View {
    let scroll: ScrollOffset
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().offset(y: -max(0, scroll.y))
    }
}

private struct ProfileWash: View {
    var tint: Color?
    /// Screen-space y where the field must be fully gone.
    var fadeEnd: CGFloat

    /// Where the field is allowed to start: the bottom of the navigation bar. Above this there is
    /// nothing to see, and the ramp below it means the bar's bottom edge is never a seam.
    private var barBottom: CGFloat { ThemeMetrics.topSafeInset + 44 }
    private var rampIn: CGFloat { 90 }
    private var rampOut: CGFloat { 110 }

    /// How far the field is allowed to travel from the brand's hue, in turns. ±0.035 ≈ ±13°, which
    /// on this accent (31°) spans **18° to 44°** — a blue- or red-led library reads orange-red, a
    /// green- or teal-led one reads gold. Visibly different libraries, one warm range.
    ///
    /// A free 55 % mix was tried first and is wrong on real artwork: Wistoria's cover derives a
    /// teal, and 55 % of the way from teal to amber is **olive** — a full-screen green field on a
    /// warm-branded app. Interpolating toward a hue and clamping the distance to it are not the
    /// same operation, and only the second one has a floor.
    private static let hueTravel: CGFloat = 0.035

    /// The signed shorter arc from `from` to `to`, in turns.
    private static func arc(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
        var delta = to - from
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
        return delta
    }

    private var warm: Color {
        var bh: CGFloat = 0, bs: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var ah: CGFloat = 0, asat: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        UIColor(tint ?? PaletteCache.fallback).getHue(&bh, saturation: &bs, brightness: &bb, alpha: &ba)
        UIColor(ThemeColor.accent).getHue(&ah, saturation: &asat, brightness: &ab, alpha: &aa)
        // The artwork chooses the DIRECTION and the saturation; the brand chooses the range.
        let travel = max(-Self.hueTravel, min(Self.hueTravel, Self.arc(ah, bh)))
        var hue = ah + travel
        if hue < 0 { hue += 1 } else if hue > 1 { hue -= 1 }
        let saturation = min(max(bs * 0.5 + asat * 0.5, 0.30), asat)
        return Color(hue: Double(hue), saturation: Double(saturation), brightness: 0.85)
    }

    var body: some View {
        let height = max(fadeEnd + 40, 420)
        EllipticalGradient(
            stops: [
                .init(color: warm.opacity(0.28), location: 0.00),
                .init(color: warm.opacity(0.16), location: 0.42),
                .init(color: warm.opacity(0.09), location: 0.62),
                .init(color: warm.opacity(0.04), location: 0.80),
                .init(color: .clear, location: 1.00),
            ],
            center: UnitPoint(x: 0.5, y: 0.42),
            startRadiusFraction: 0,
            endRadiusFraction: 0.92
        )
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .top)
        // Nothing above the bar, a 90-pt ramp under it, and a 110-pt ramp OUT that lands exactly on
        // the stats plate's top edge — so no plate on this screen ever contains the end of a
        // gradient, which is what produced the visible horizontal tone step inside the stats card.
        .mask(
            VStack(spacing: 0) {
                Color.clear.frame(height: barBottom)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: rampIn)
                Rectangle().fill(.black)
                    .frame(height: max(0, fadeEnd - barBottom - rampIn - rampOut))
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: rampOut)
                Spacer(minLength: 0)
            }
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Section

// `ProfileSection` folded back into `GroupedList` (cohesion pass, 30 Aug): the two had
// converged to identical geometry, and the one thing this copy added — the `.isHeader` trait on
// the label — now lives on the shared primitive.

// MARK: - Rows

/// A settings row, in the shape this screen needs: one monochrome glyph column, a title, one
/// support line, and a trailing control area.
///
/// It is deliberately not `GroupedRow`: that primitive paints a tinted 28-pt tile behind its
/// symbol, hard-codes `success` as its toggle tint and has no destructive or in-flight state.
/// The geometry, the plate, the press style and the quiet separator all still come from the
/// design system.
private struct ProfileRowLabel<Trailing: View>: View {
    /// `nil` keeps the column's width and draws a `RefreshIndicator` in it — which is how the row
    /// guarantees a wait is shown once, in one place, and never as a glyph plus a spinner.
    let symbol: String?
    var symbolTint: Color = ThemeColor.textSecondary
    var symbolWeight: Font.Weight = .medium
    let title: String
    var titleTint: Color = ThemeColor.textPrimary
    var subtitle: String? = nil
    var separator = true
    /// When true the empty glyph column shows the in-flight indicator instead of nothing.
    var indicateWait = true
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Glyph column + its gap. The separator starts where the TITLE starts, never at the plate
    /// edge — an inset separator is what makes a group read as one thing.
    private var textInset: CGFloat { ThemeSpace.x4 + 22 + ThemeSpace.x3 }

    var body: some View {
        // At accessibility sizes a two-line title makes a vertically centred glyph sit beside the
        // SUBTITLE. Baseline alignment keeps it with the line it belongs to.
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .firstTextBaseline : .center,
               spacing: ThemeSpace.x3) {
            Group {
                if let symbol {
                    AppGlyph(systemName: symbol)
                        .font(.system(size: 16, weight: symbolWeight))
                        .foregroundStyle(symbolTint)
                } else if indicateWait {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ThemeColor.textTertiary)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: ThemeSpace.x0_5) {
                Text(title)
                    .type(ThemeType.body)
                    .foregroundStyle(titleTint)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .type(ThemeType.metadata)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: ThemeSpace.x2)
            trailing()
        }
        .padding(.leading, ThemeSpace.x4)
        .padding(.trailing, ThemeSpace.x2)
        .padding(.vertical, ThemeSpace.x2)
        .frame(minHeight: ThemeMetrics.rowCompact)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if separator {
                Rectangle().fill(ThemeColor.separatorQuiet).frame(height: 1)
                    .padding(.leading, textInset)
            }
        }
    }
}

private struct ProfileRow<Trailing: View>: View {
    let symbol: String?
    var symbolTint: Color = ThemeColor.textSecondary
    var symbolWeight: Font.Weight = .medium
    let title: String
    var titleTint: Color = ThemeColor.textPrimary
    var subtitle: String? = nil
    var separator = true
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            ProfileRowLabel(symbol: symbol, symbolTint: symbolTint, symbolWeight: symbolWeight,
                            title: title, titleTint: titleTint, subtitle: subtitle,
                            separator: separator, indicateWait: false, trailing: trailing)
        }
        .buttonStyle(GroupedRowPressStyle())
    }
}
