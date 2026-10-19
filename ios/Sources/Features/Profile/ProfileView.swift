import SwiftUI
import UIKit
import UserNotifications

// Profile, rebuilt 19 Oct ("Profile is the worst of all. It's so poorly built that I don't have words
// to explain. It is completely out of place with the rest of the app… watching isn't even needed
// there since Library is already there", owner).
//
// What it was: iOS Settings dropped into the app — a "Profile" bar with a text Done, a brown disc
// with an amber letter beside "Your account", a grey middot line of counts, a Watching shelf that
// repeated the Library, then stacked grey PLATES (Community, Settings, Account, Sign out, Delete)
// of 17-pt rows with glyphs, on a flat canvas. Every root of the app had left that language behind:
// they stand on the viewer's aurora (`AppGround`), name things in Outfit, separate with hairlines
// and small capitals, and keep their controls as pills and glass.
//
// What it is now, top to bottom, in that language:
//   · the GROUND is the roots' aurora; the bar is glass with one ✕, no title (the page names you);
//   · your SHOWS as a tilted wall of posters behind you, fading into the ground (`ProfileWall`);
//   · YOU, centred on its foot: the account's photo, else its initial in Outfit in a ring (`AccountGlyph`'s
//     anatomy at portrait size), the name in Outfit, the handle or the session under it;
//   · three COUNTS — episodes, watching, finished — a figure over its small-caps word, the two
//     statuses opening the Library on that shelf (the Watching shelf is gone: it was the Library's);
//   · the CONTROLS as flat rows on the ground, hairlines between them, under small-caps eyebrows
//     (Preferences, Library, Community, About) — the show page's `ShowInfoList` anatomy, not plates;
//   · Sign out as an outline pill, then the colophon (the mark, the version and the sync state, the
//     data credit), and Delete account last, a quiet destructive word under everything.
struct ProfileView: View {
    /// Dismiss the sheet and open the Library's titles filtered to this status — the counts' doors.
    /// `nil` for a presenter that has nowhere to send it: the counts are then not controls.
    var onOpenLibrary: ((WatchStatus) -> Void)? = nil
    /// Dismiss the sheet and open a show — Saved's route.
    var onOpenDetail: ((String) -> Void)? = nil

    @Environment(AppModel.self) private var appModel
    @Environment(AuthManager.self) private var auth
    @Environment(\.dismiss) private var dismiss
    /// Set by the feed on this sheet: closes it and opens a feed page (Saved → a post).
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
    @State private var confirmAppleManualDeletion = false
    @State private var discardTarget: UUID?
    @State private var signingOut = false
    @State private var deleting = false
    /// The one failure this screen has to report itself: the account deletion that did not happen.
    @State private var deleteFailure: String?
    @State private var signOutFailed = false
    /// Alerts are OFF in Settings: the app asks in-app before it sends anyone there.
    @State private var askOpenSettings = false
    /// `nil` until asked, and while the system has never been asked (nothing to report yet).
    @State private var notificationsOn: Bool?
    /// What the account looked like the last time the library actually loaded. The counts render
    /// from this when the network is gone, instead of disappearing.
    @State private var snapshot = ProfileSnapshot.load()

    private var now: Int64 { appModel.now }
    private var sync: SyncCenter { SyncCenter.shared }
    private var isAX: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                page
                    .padding(.horizontal, ThemeMetrics.gutter)
                    .padding(.top, ThemeSpace.x2)
                    .padding(.bottom, ThemeSpace.x10)
            }
            .qaIdentifier("qa.scroll.profile")
            .scrollIndicators(.hidden)
            // Rows go out just before the bar's ✕, onto the ground — the roots' fade
            // (`HeaderEdgeFade`), never the system's frosted edge: a blur over this dark ground
            // comes out lighter than it, a grey band under the bar (16 Oct).
            .mask {
                GeometryReader { g in
                    let top = g.safeAreaInsets.top
                    VStack(spacing: 0) {
                        Color.clear.frame(height: max(0, top - 14))
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 26)
                        Color.black
                    }
                    .padding(.top, -top)
                }
            }
            .chromeScrollEdgeHidden(.top)
            .background {
                ZStack {
                    ThemeColor.canvas
                    AppGround()
                }
                .ignoresSafeArea()
            }
            .onChange(of: appModel.library.count, initial: true) { _, _ in
                if let fresh = ProfileSnapshot.capture(appModel.library, covers: []) {
                    fresh.save()
                    snapshot = fresh
                } else if sync.lastSyncedAt != nil, sync.isOnline {
                    // A library that LOADED and is empty is a real empty account, not a failure.
                    ProfileSnapshot.clear()
                    snapshot = ProfileSnapshot()
                }
            }
            // The page names you; the bar carries only the way out. VoiceOver still hears the title.
            .navigationTitle(Copy.Profile.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                ToolbarItem(placement: .topBarTrailing) {
                    // A glass DISC, not the toolbar's shared capsule (a pill round one glyph).
                    Button { dismiss() } label: {
                        AppGlyph(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ThemeColor.textPrimary)
                            .frame(width: 36, height: 36)
                            .chromeGlass(in: Circle(), interactive: true)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.Feed.closeViewer)
                    .qaIdentifier("qa.profile.done")
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
        // ALERTS, not `confirmationDialog`: a dimming scrim, an explicit Cancel, and the destructive
        // verb rendered as destructive — what a destructive confirmation needs.
        .alert(AccountCopy.signOutTitle, isPresented: $confirmSignOut) {
            Button(Copy.Confirm.cancel, role: .cancel) {}
            Button(AccountCopy.signOut, role: .destructive) { performSignOut() }
                .qaIdentifier("qa.signout.confirm")
        } message: {
            Text(signOutMessage)
        }
        .alert(AccountCopy.deleteTitle, isPresented: $confirmDelete) {
            Button(Copy.Confirm.cancel, role: .cancel) {}
            Button(AccountCopy.deleteConfirm, role: .destructive) { performDelete() }
                .qaIdentifier("qa.delete.confirm")
        } message: {
            Text(deleteMessage)
        }
        .alert(AccountCopy.deleteFailedTitle,
               isPresented: Binding(get: { deleteFailure != nil },
                                    set: { if !$0 { deleteFailure = nil } })) {
            Button(Copy.Action.done, role: .cancel) { deleteFailure = nil }
                .qaIdentifier("qa.delete.error.done")
        } message: {
            Text(deleteFailure ?? "")
                .qaIdentifier("qa.delete.error")
        }
        .alert("Apple sign-in couldn\u{2019}t be disconnected", isPresented: $confirmAppleManualDeletion) {
            Button(Copy.Confirm.cancel, role: .cancel) {}
            Button(AccountCopy.deleteConfirm, role: .destructive) { performDelete(allowManualAppleRevocation: true) }
        } message: {
            Text("You can still delete your Previously account and tracking data. " + AccountDeletionNotice.appleManualInstructions)
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
        // Discard permanently throws away a write the user made; it names the change.
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

    /// Who, how much, then the controls, then the way out.
    @ViewBuilder
    private var page: some View {
        VStack(spacing: 0) {
            // You, in front of your shows: the wall runs up under the bar and the portrait stands on
            // its foot.
            identity
                .padding(.top, ProfileWall.height - ProfileMetrics.portrait * 0.6)
                .background(alignment: .top) {
                    ProfileWall(posters: wallPosters)
                        .padding(.horizontal, -ThemeMetrics.gutter)
                        .padding(.top, -ThemeSpace.x2 - 80)
                }
            stats.padding(.top, ThemeSpace.x6)
            if !sync.failedChanges.isEmpty {
                syncFailures.padding(.top, ProfileMetrics.groupGap)
            }
            preferences.padding(.top, ProfileMetrics.groupGap)
            library.padding(.top, ProfileMetrics.groupGap)
            community.padding(.top, ProfileMetrics.groupGap)
            about.padding(.top, ProfileMetrics.groupGap)
            #if DEBUG
            developer.padding(.top, ProfileMetrics.groupGap)
            #endif
            signOutPill.padding(.top, ThemeSpace.x12)
            colophon.padding(.top, ThemeSpace.x10)
            // Delete account under everything: one of these two actions is routine and reversible,
            // the other is not, and a thumb should never confuse them.
            deleteLink.padding(.top, ThemeSpace.x5)
        }
    }

    // MARK: - You

    /// The account, centred: its portrait, its name in the display face, and one line under it —
    /// the handle the account replies under, else how this device is signed in.
    private var identity: some View {
        VStack(spacing: ThemeSpace.x3) {
            ProfilePortrait(identity: auth.identity, size: ProfileMetrics.portrait)
            VStack(spacing: ThemeSpace.x1) {
                Text(accountName)
                    .type(ThemeType.caughtUpTitle)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(isAX ? 3 : 1)
                    .minimumScaleFactor(0.7)
                if let subline {
                    Text(subline)
                        .type(ThemeType.feedSubhead)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signed in as \(accountName)")
        .accessibilityValue(subline ?? "")
        .accessibilityAddTraits(.isHeader)
    }

    /// "@mira.k" once the account has chosen a handle; else the session where it says something.
    private var subline: String? {
        if let handle = appModel.socialProfile?.handle { return Copy.Social.handle(handle) }
        return provenance.isEmpty ? nil : provenance
    }

    /// The wall's posters — what you have finished first, then what you watch, then the rest.
    private var wallPosters: [String] {
        let finished = appModel.library.filter { $0.status == .completed }
        let watching = appModel.library.filter { $0.status == .watching }
        let rest = appModel.library.filter { $0.status != .completed && $0.status != .watching }
        return (finished + watching + rest).compactMap { $0.tilePoster.url ?? $0.portraitArt }.prefix(15).map { $0 }
    }

    /// Three counts, each a figure over its word: what you have watched, and the two shelves that
    /// say where you are — which open the Library on that shelf.
    private var stats: some View {
        HStack(spacing: 0) {
            stat(episodesWatched, word: Copy.Profile.episodes, status: nil)
            statRule
            stat(count(of: .watching), word: Copy.Status(.watching), status: .watching)
            statRule
            stat(count(of: .completed), word: Copy.Profile.finished, status: .completed)
        }
        .padding(.vertical, ThemeSpace.x3)
        .overlay(alignment: .top) { ProfileHairline() }
        .overlay(alignment: .bottom) { ProfileHairline() }
    }

    private var statRule: some View {
        Rectangle().fill(ThemeColor.hairline).frame(width: ThemeMetrics.pixel, height: 32)
    }

    @ViewBuilder
    private func stat(_ value: Int?, word: String, status: WatchStatus?) -> some View {
        let figure = value.map { $0.formatted(.number.grouping(.automatic)) } ?? "\u{2014}"
        let label = VStack(spacing: 2) {
            Text(figure)
                .type(ThemeType.showTitleL)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(word)
                .type(ThemeType.scheduleCaps)
                .textCase(.uppercase)
                .foregroundStyle(ThemeColor.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        if let status, let onOpenLibrary {
            Button { dismiss(); onOpenLibrary(status) } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            .accessibilityHint(Copy.Profile.opensLibraryHint)
        } else {
            label
        }
    }

    // MARK: - Library counts

    /// Every EPISODE the account has marked — the story's episodes (`isMainStory`), capped at
    /// what has aired.
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
        // Unknown is not zero.
        return sync.lastSyncedAt == nil ? nil : 0
    }

    // MARK: - Groups

    private var preferences: some View {
        ProfileGroup(title: Copy.Profile.preferences) {
            // First: it decides what every suggestion in the app is.
            ProfileListRow(symbol: "tv", title: Copy.Watching.row, value: Copy.Watching.name(appModel.audience),
                           action: { showAudience = true })
            ProfileListRow(symbol: "bell", title: Copy.Profile.notifications,
                           value: notificationsOn.map { $0 ? Copy.State.on : Copy.State.off } ?? Copy.State.ask,
                           // This row leaves the app only once the system has been asked.
                           trailingGlyph: notificationsOn == nil ? "chevron.forward" : "arrow.up.forward",
                           action: { notificationsTapped() })
                .accessibilityHint(notificationsOn == nil ? "" : "Opens Settings")
                .task { await refreshNotificationsOn() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    Task { await refreshNotificationsOn() }
                }
            ProfileToggleRow(symbol: "hand.tap", title: Copy.Profile.haptics, isOn: $hapticsOn, separator: false)
        }
        .onChange(of: hapticsOn) { _, on in FeedbackCoordinator.enabled = on }
    }

    private var library: some View {
        ProfileGroup(title: Copy.Profile.library) {
            // A list kept elsewhere (AniList, MyAnimeList, TV Time), brought in at any time.
            ProfileListRow(symbol: "clock.arrow.circlepath", title: Copy.Import.row, action: { showImport = true })
                .qaIdentifier("qa.import.open")
            NavigationLink(value: ProfileRoute.export) {
                ProfileListRowLabel(symbol: "square.and.arrow.up", title: AccountCopy.export, separator: false)
            }
            .buttonStyle(GroupedRowPressStyle())
            .qaIdentifier("qa.export.open")
        }
    }

    /// What the social layer keeps for this account, and the controls App Review 1.2 asks to be
    /// reachable. With replies off on the server, Saved and Muted shows only — the two that still do
    /// something.
    private var community: some View {
        let comments = appModel.feedCapabilities.comments
        return ProfileGroup(title: Copy.Social.communityHeader) {
            communityLink(.saved, symbol: "bookmark", title: Copy.Social.savedTitle)
            if comments {
                communityLink(.identity, symbol: "at", title: Copy.Social.identityRow, value: identityValue)
                communityLink(.blocked, symbol: "person.crop.circle.badge.xmark", title: Copy.Social.blockedTitle)
            }
            communityLink(.muted, symbol: "speaker.slash", title: Copy.Social.mutedTitle, separator: comments)
            if comments {
                ProfileListRow(symbol: "text.book.closed", title: Copy.Social.rulesTitle, separator: false,
                               action: { showRules = true })
            }
        }
        // Once per session (the model keeps the answer).
        .task { await appModel.loadSocialProfile() }
    }

    /// "@mira.k" once chosen; "Not set" once the server has said so; nothing while unknown.
    private var identityValue: String? {
        guard let profile = appModel.socialProfile else { return nil }
        return profile.handle.map { Copy.Social.handle($0) } ?? Copy.Social.identityNotSet
    }

    private func communityLink(_ route: ProfileRoute, symbol: String, title: String,
                               value: String? = nil, separator: Bool = true) -> some View {
        NavigationLink(value: route) {
            ProfileListRowLabel(symbol: symbol, title: title, value: value, separator: separator)
        }
        .buttonStyle(GroupedRowPressStyle())
        .accessibilityValue(value ?? "")
    }

    /// Privacy, Terms and a way to reach a human — what guideline 5.1.1 asks for besides deletion.
    /// Every destination comes from a build setting through `AppConfig`.
    private var about: some View {
        ProfileGroup(title: Copy.Profile.about) {
            ProfileListRow(symbol: "hand.raised", title: AccountCopy.privacy, trailingGlyph: "arrow.up.forward",
                           action: { open(AppConfig.privacyURL) })
                .accessibilityHint("Opens in Safari")
                .accessibilityAddTraits(.isLink)
            ProfileListRow(symbol: "doc.text", title: AccountCopy.terms, trailingGlyph: "arrow.up.forward",
                           action: { open(AppConfig.termsURL) })
                .accessibilityHint("Opens in Safari")
                .accessibilityAddTraits(.isLink)
            ProfileListRow(symbol: "envelope", title: AccountCopy.support,
                           trailingGlyph: "arrow.up.forward", separator: false,
                           action: { open(AppConfig.supportURL) })
                .accessibilityHint("Opens Mail")
        }
    }

    #if DEBUG
    /// DEBUG only: the whole-app direction (`Experience`) and the busy-state fixture.
    private var developer: some View {
        ProfileGroup(title: "Developer") {
            Menu {
                ForEach(Experience.allCases) { e in
                    Toggle(isOn: Binding(get: { appModel.experience == e },
                                         set: { if $0 { appModel.setExperience(e) } })) {
                        Text(e.label)
                        Text(e.summary)
                    }
                }
            } label: {
                ProfileListRowLabel(symbol: "square.stack", title: "Version", value: appModel.experience.label,
                                    trailingGlyph: "chevron.up.chevron.down")
            }
            .buttonStyle(GroupedRowPressStyle())
            .qaIdentifier("qa.experience")
            ProfileToggleRow(symbol: "ladybug", title: "Demo: episode waiting", isOn: $demoBusy, separator: false)
                .onChange(of: demoBusy) { _, on in
                    UserDefaults.standard.set(on, forKey: "demoBusy")
                    Task { await appModel.reload() }
                }
        }
    }
    #endif

    // MARK: - Sync

    /// Drawn only while something failed: what could not be saved, each with what can be done.
    private var syncFailures: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: ThemeSpace.x2) {
                AppGlyph(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ThemeColor.warning)
                    .accessibilityHidden(true)
                ProfileEyebrow(text: Copy.Toast.syncFailed(sync.failedChanges.count), ink: ThemeColor.warning)
                Spacer(minLength: 0)
                if sync.canRetryAny && sync.failedChanges.count > 1 {
                    Button(AccountCopy.retryAll) { sync.retryAll() }
                        .buttonStyle(InlineLinkButtonStyle())
                }
            }
            .padding(.bottom, ThemeSpace.x1)
            ForEach(Array(sync.failedChanges.enumerated()), id: \.element.id) { i, change in
                failureRow(change, isLast: i == sync.failedChanges.count - 1)
            }
        }
        .overlay(alignment: .bottom) { ProfileHairline() }
    }

    /// One failed write: WHAT (the show, and when it failed), WHICH CHANGE, WHY, then WHAT TO DO.
    private func failureRow(_ change: FailedChange, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: ThemeSpace.x1) {
            #if PREVIOUSLY_QA
            if case .progress(_, let mediaId, let episodes)? = change.intent {
                Text("Pending progress")
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("qa.sync.pending.progress.\(mediaId)")
                    .accessibilityValue(String(episodes))
            }
            #endif
            HStack(alignment: .firstTextBaseline, spacing: ThemeSpace.x3) {
                Text(change.title)
                    .type(ThemeType.rowTitle)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: ThemeSpace.x2)
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
            actionRow(change)
                .padding(.top, ThemeSpace.x1)
        }
        .padding(.vertical, ThemeSpace.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { ProfileHairline() }
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

    /// Retry and Discard change, on their own row, both real 44-pt targets, told apart by shape.
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
                        .qaIdentifier(retryQAIdentifier(change))
                }
                Button(Copy.Confirm.discardChangeConfirm) { discardTarget = change.id }
                    .buttonStyle(InlineLinkButtonStyle(destructive: true))
                    .accessibilityHint("Throws this change away. It can\u{2019}t be undone.")
            }
        }
    }

    private func retryQAIdentifier(_ change: FailedChange) -> String {
        if case .progress(_, let mediaId, _)? = change.intent {
            return "qa.sync.retry.progress.\(mediaId)"
        }
        return "qa.sync.retry.\(change.id)"
    }

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

    /// The calm state, in the colophon: "Up to date · Checked just now", "You're offline", … —
    /// offline tested first.
    private var syncLine: String {
        let title: String
        if !sync.isOnline { title = EmptyStateCopy.offlineCached.title }
        else if sync.checking { title = Copy.State.checkingForChanges }
        else if sync.lastSyncedAt == nil { title = snapshot.isEmpty ? Copy.State.neverSynced : Copy.State.couldNotCheck }
        else { title = AccountCopy.upToDate }
        return [title, syncStamp].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private var syncStamp: String? {
        guard sync.isOnline, !sync.checking, let at = sync.lastSyncedAt else { return nil }
        return "Checked \(stampWord(at).lowercasedFirstWord())"
    }

    /// "Just now" · "12 min ago" · "9:41 AM" · "Aug 19".
    private func stampWord(_ ts: Int64) -> String {
        let elapsed = max(0, now - ts)
        let minutes = Int(elapsed / Formatting.minuteMs)
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if Formatting.dayDiff(ts: ts, now: now) == 0 { return Formatting.fmtTime(ts) }
        return TemporalCopy.dateWord(ts, now: now, anchor: .local)
    }

    // MARK: - Pages

    /// The pages this sheet pushes on its own stack.
    @ViewBuilder
    private func destination(_ route: ProfileRoute) -> some View {
        switch route {
        case .export:
            ExportOptionsView(appModel: appModel)
        case .saved:
            SavedPostsView(onOpenPost: openSavedPost, onOpenShow: { id in
                dismiss()
                if let onOpenDetail { onOpenDetail(id) } else { appModel.pendingOpen = id }
            })
        case .identity:
            IdentitySetupView(mode: .edit, onDone: { _ in
                if path.last == .identity { path.removeLast() }
            })
        case .blocked:
            BlockedAccountsView()
        case .muted:
            MutedShowsView()
        }
    }

    /// A saved post opens on the feed's own page for it: the presenter closes this sheet first.
    private func openSavedPost(_ postId: String) {
        if let openFeedRoute {
            openFeedRoute(.post(id: postId))
        } else {
            dismiss()
            appModel.pendingRoute = .post(postId: postId, commentId: nil)
        }
    }

    // MARK: - Sign out, the colophon, delete

    /// Routine and reversible: an outline pill, the app's quiet control, in ink.
    private var signOutPill: some View {
        Button { confirmSignOut = true } label: {
            ZStack {
                Text(AccountCopy.signOut)
                    .type(ThemeType.feedNoteTitle)
                    .opacity(signingOut ? 0 : 1)
                if signingOut { ProgressView().controlSize(.small).tint(ThemeColor.textSecondary) }
            }
            .foregroundStyle(ThemeColor.textPrimary)
            .padding(.horizontal, ThemeSpace.x6)
            .frame(height: 40)
            .background(ThemeColor.textPrimary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(ThemeColor.textPrimary.opacity(0.22), lineWidth: FeedMetrics.hairline))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(FeedIconPressStyle())
        .disabled(signingOut || deleting)
        .accessibilityHint("Your library stays in your account")
        .qaIdentifier("qa.signout")
    }

    /// The mark, the version and the sync state, and the data credit the TMDB terms require.
    private var colophon: some View {
        VStack(spacing: ThemeSpace.x2) {
            Wordmark(colophon: true)
            Text("\(version) \u{00B7} \(syncLine)")
                .type(ThemeType.caption)
                .foregroundStyle(ThemeColor.textTertiary)
                .monospacedDigit()
                .multilineTextAlignment(.center)
            Text("Data from AniList and TMDB. This product uses the TMDB API but is not endorsed "
                 + "or certified by TMDB.")
                .type(ThemeType.caption)
                .foregroundStyle(ThemeColor.textDisabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Not reversible: a quiet destructive word, last on the page.
    private var deleteLink: some View {
        Button { confirmDelete = true } label: {
            ZStack {
                Text(AccountCopy.delete).opacity(deleting ? 0 : 1)
                if deleting { ProgressView().controlSize(.small).tint(ThemeColor.destructive) }
            }
        }
        .buttonStyle(InlineLinkButtonStyle(destructive: true))
        .disabled(signingOut || deleting)
        .qaIdentifier("qa.delete.open")
        .accessibilityHint("Permanently deletes your account and library")
    }

    private var signOutMessage: String { Copy.Account.signOutMessage(pending: sync.failedChanges.count) }
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

    private func performDelete(allowManualAppleRevocation: Bool = false) {
        FeedbackCoordinator.fire(.destructive)
        withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) {
            deleting = true
        }
        let deletionOwner = appModel.currentAccountID
        let deletionEpoch = appModel.accountEpoch
        Task {
            var apple: AppleDeletionAuthorization.Proof?
            if !allowManualAppleRevocation, !auth.linkedAppleUserIDs.isEmpty {
                do { apple = try await AppleDeletionAuthorization.request(expectedUserIDs: auth.linkedAppleUserIDs) }
                catch {
                    guard deletionOwner == auth.accountID, deletionEpoch == appModel.accountEpoch else { return }
                    deleting = false
                    if (error as? AppleDeletionAuthorization.Failure) != .cancelled {
                        confirmAppleManualDeletion = true
                    }
                    return // A cancelled system confirmation must never dispatch DELETE.
                }
            }
            guard deletionOwner == auth.accountID, deletionEpoch == appModel.accountEpoch else { return }
            // Nothing the app sends may reach the server after the erasure: a late like, mark or
            // read would bring the account back (`prepareForErasure`).
            await appModel.prepareForErasure()
            guard deletionOwner == auth.accountID, deletionEpoch == appModel.accountEpoch else { return }
            do {
                let status = try await AccountDeletion.deleteAccount(apple: apple, token: {
                    guard deletionOwner == auth.accountID, deletionEpoch == appModel.accountEpoch else { return nil }
                    let token = await auth.currentToken()
                    return deletionOwner == auth.accountID && deletionEpoch == appModel.accountEpoch ? token : nil
                })
                guard deletionOwner == auth.accountID, deletionEpoch == appModel.accountEpoch else { return }
                AccountDeletion.markAccepted(accountID: appModel.currentAccountID)
                AccountDeletionNotice.record(status)
                // The account is gone; the session must go with it, the snapshot too, and the sheet
                // with both. A deleted account may not leave its counts on the device — so the
                // model is wiped FIRST, and the wipe never depends on Clerk's sign-out succeeding.
                ProfileSnapshot.clear()
                appModel.teardown()
                await auth.accountErased()
                deleting = false
                dismiss()
            } catch {
                guard deletionOwner == auth.accountID, deletionEpoch == appModel.accountEpoch else { return }
                if (error as? AccountDeletion.Failure) == .unreachable {
                    appModel.holdUnconfirmedErasure()
                } else { appModel.abortErasure() }
                deleting = false
                deleteFailure = (error as? LocalizedError)?.errorDescription
                    ?? AccountDeletion.Failure.refused.errorDescription
            }
        }
    }

    // MARK: - Helpers

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

/// Two formats, each with a real support line, on a pushed screen — the page's own flat rows on its
/// ground.
private struct ExportOptionsView: View {
    let appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ProfileGroup(title: nil) {
                    exportRow(format: .json, title: AccountCopy.exportJSON, subtitle: AccountCopy.exportJSONSub,
                              symbol: "curlybraces")
                    exportRow(format: .csv, title: AccountCopy.exportCSV, subtitle: AccountCopy.exportCSVSub,
                              symbol: "tablecells", separator: false)
                }
                Text(AccountCopy.exportFootnote)
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .padding(.top, ThemeMetrics.labelGap)
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x4)
        }
        .scrollIndicators(.hidden)
        .background {
            ZStack {
                ThemeColor.canvas
                AppGround()
            }
            .ignoresSafeArea()
        }
        .brandNavigationTitle(AccountCopy.export)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func exportRow(format: LibraryExport.Format, title: String, subtitle: String,
                           symbol: String, separator: Bool = true) -> some View {
        Group {
            if format == .json {
                ShareLink(item: LibraryExport(appModel: appModel),
                          preview: SharePreview("Previously library (\(title))")) {
                    ProfileListRowLabel(symbol: symbol, title: title, subtitle: subtitle,
                                        trailingGlyph: "square.and.arrow.up", separator: separator)
                }
            } else {
                ShareLink(item: LibraryCSVExport(appModel: appModel),
                          preview: SharePreview("Previously library (\(title))")) {
                    ProfileListRowLabel(symbol: symbol, title: title, subtitle: subtitle,
                                        trailingGlyph: "square.and.arrow.up", separator: separator)
                }
            }
        }
        .buttonStyle(GroupedRowPressStyle())
        .accessibilityLabel("Export as \(title)")
        .accessibilityHint(subtitle)
        .qaIdentifier(format == .json ? "qa.export.json" : "qa.export.csv")
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
/// they could not verify it anywhere else (M4). A small snapshot in the current account's local
/// directory keeps the frame available without exposing another account's cached artwork.
struct ProfileSnapshot: Codable, Equatable {
    var counts: [String: Int] = [:]
    var covers: [String] = []
    private var owner: AccountLocalStore.Snapshot? = nil
    private enum CodingKeys: String, CodingKey { case counts, covers }

    init() {}
    private init(counts: [String: Int] = [:], covers: [String] = [], owner: AccountLocalStore.Snapshot?) {
        self.counts = counts
        self.covers = covers
        self.owner = owner
    }

    /// Nothing remembered. The screen tells "never synced" apart from "couldn't check" with this.
    var isEmpty: Bool { counts.isEmpty && covers.isEmpty }

    private static let countsKey = "profile.snapshot.counts"
    private static let coversKey = "profile.snapshot.covers"

    @MainActor static func load() -> ProfileSnapshot {
        let owner = AccountLocalStore.shared.current
        guard let data = AccountLocalStore.shared.read("profile-snapshot.json", owner: owner),
              var decoded = try? JSONDecoder().decode(Self.self, from: data) else { return ProfileSnapshot(owner: owner) }
        decoded.owner = owner
        return decoded
    }

    /// `nil` when there is nothing worth remembering — an empty library must never overwrite a real
    /// snapshot, because "the request failed" and "the account is empty" arrive as the same value.
    @MainActor static func capture(_ library: [Franchise], covers: [String]) -> ProfileSnapshot? {
        guard !library.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for status in WatchStatus.allCases {
            counts[status.rawValue] = library.filter { $0.status == status }.count
        }
        return ProfileSnapshot(counts: counts, covers: covers, owner: AccountLocalStore.shared.current)
    }

    @MainActor func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? AccountLocalStore.shared.write(data, name: "profile-snapshot.json", owner: owner)
    }

    @MainActor static func clear() {
        AccountLocalStore.shared.remove("profile-snapshot.json", owner: AccountLocalStore.shared.current)
        let d = UserDefaults.standard
        d.removeObject(forKey: countsKey)
        d.removeObject(forKey: coversKey)
    }
}

// MARK: - The page's parts

private enum ProfileMetrics {
    /// The portrait: large enough to be the page's subject, small enough to leave the counts and the
    /// first group in the first screen.
    static let portrait: CGFloat = 88
    /// Between groups — a section's break, as Schedule's eyebrows stand.
    static let groupGap: CGFloat = ThemeSpace.x8
    /// A row: a finger tall and a little air.
    static let rowHeight: CGFloat = 52
    /// The glyph's column and its gap — where a row's hairline starts, under the title.
    static let glyphColumn: CGFloat = 24
    static let glyphGap: CGFloat = ThemeSpace.x3
}

/// The account's portrait: its photo where it has one, else its initial in the display face inside
/// a ring — the bar's `AccountGlyph` at the page's size, so the face that opened this sheet is the
/// face it opens on — else the ring round the person glyph.
private struct ProfilePortrait: View {
    let identity: AuthManager.AccountIdentity
    let size: CGFloat

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let photo = identity.imageURL {
                RemoteImageView(url: photo, contentMode: .fill, maxPixel: size * displayScale, placeholderHidden: true)
                    .frame(width: size, height: size)
                    .background(ThemeColor.surfaceRaised)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(ThemeColor.textPrimary.opacity(0.18), lineWidth: 1))
            } else {
                ZStack {
                    Circle().fill(ThemeColor.textPrimary.opacity(0.06))
                    Circle().strokeBorder(ThemeColor.textPrimary.opacity(0.9), lineWidth: size / 24)
                    if let initial = identity.initial {
                        Text(initial)
                            .font(Typeface.fixedFont(.display, .semibold, size * 0.44))
                            .foregroundStyle(ThemeColor.textPrimary)
                    } else {
                        AppGlyph(systemName: "person.fill")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(ThemeColor.textPrimary)
                            .offset(y: size * 0.03)
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A group's eyebrow: Schedule's small capitals ("NEXT WEEK", "LATER").
private struct ProfileEyebrow: View {
    let text: String
    var ink: Color = ThemeColor.textSecondary

    var body: some View {
        Text(text)
            .type(ThemeType.scheduleCaps)
            .textCase(.uppercase)
            .foregroundStyle(ink)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One physical pixel of the page's hairline.
private struct ProfileHairline: View {
    var body: some View {
        Rectangle().fill(ThemeColor.hairline).frame(height: ThemeMetrics.pixel)
    }
}

/// A group of rows on the ground: the eyebrow, then the rows, hairlines between them — no plate.
private struct ProfileGroup<Rows: View>: View {
    let title: String?
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                ProfileEyebrow(text: title).padding(.bottom, ThemeSpace.x1)
            }
            VStack(spacing: 0) { rows() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row's anatomy: the Tabler glyph in a column, the title, a value in the quiet ink, a small
/// trailing glyph — a hairline under it from the title's edge.
private struct ProfileListRowLabel: View {
    let symbol: String
    let title: String
    var titleInk: Color = ThemeColor.textPrimary
    var subtitle: String? = nil
    var value: String? = nil
    var trailingGlyph: String? = "chevron.forward"
    var separator = true

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .firstTextBaseline : .center, spacing: ProfileMetrics.glyphGap) {
            AppGlyph(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(ThemeColor.textSecondary)
                .frame(width: ProfileMetrics.glyphColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .type(ThemeType.body)
                    .foregroundStyle(titleInk)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .type(ThemeType.metadata)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: ThemeSpace.x2)
            if let value {
                Text(value)
                    .type(ThemeType.feedSubhead)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let trailingGlyph {
                AppGlyph(systemName: trailingGlyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ThemeColor.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: ProfileMetrics.rowHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if separator {
                ProfileHairline().padding(.leading, ProfileMetrics.glyphColumn + ProfileMetrics.glyphGap)
            }
        }
    }
}

/// A row that does something here.
private struct ProfileListRow: View {
    let symbol: String
    let title: String
    var value: String? = nil
    var trailingGlyph: String? = "chevron.forward"
    var separator = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProfileListRowLabel(symbol: symbol, title: title, value: value, trailingGlyph: trailingGlyph,
                                separator: separator)
        }
        .buttonStyle(GroupedRowPressStyle())
        .accessibilityValue(value ?? "")
    }
}

/// A row with a switch: the row's anatomy with the system toggle where the chevron would be, in the
/// accent — a switch reports selection, and selection in this app is one colour.
private struct ProfileToggleRow: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool
    var separator = true

    var body: some View {
        HStack(spacing: ProfileMetrics.glyphGap) {
            AppGlyph(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(ThemeColor.textSecondary)
                .frame(width: ProfileMetrics.glyphColumn)
            Toggle(title, isOn: $isOn)
                .type(ThemeType.body)
                .foregroundStyle(ThemeColor.textPrimary)
                .tint(ThemeColor.accent)
        }
        .frame(minHeight: ProfileMetrics.rowHeight)
        .overlay(alignment: .bottom) {
            if separator {
                ProfileHairline().padding(.leading, ProfileMetrics.glyphColumn + ProfileMetrics.glyphGap)
            }
        }
    }
}

// MARK: - The wall

/// Your shows as a WALL behind you: their posters in a tilted grid, dimmed, fading into the ground
/// before the name — Letterboxd's and Apple TV's collage, from your own library (19 Oct: the plain
/// rebuild "doesn't feel like a previously - the premium TV tracking app at all", owner; a split-flap
/// board of the counts was photographed beside it and the owner chose the wall,
/// `design/profile-2026-10-19/directions.jpg`).
private struct ProfileWall: View {
    let posters: [String]

    static let height: CGFloat = 300
    private static let poster = CGSize(width: 74, height: 111)

    var body: some View {
        let rows = stride(from: 0, to: posters.count, by: 5).map { Array(posters[$0..<min($0 + 5, posters.count)]) }
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { url in
                        RemoteImageView(url: url, contentMode: .fill, maxPixel: 240, alignment: .top, placeholderHidden: true)
                            .frame(width: Self.poster.width, height: Self.poster.height)
                            .background(ThemeColor.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .offset(x: r % 2 == 0 ? -20 : 22)
            }
        }
        .rotationEffect(.degrees(-9))
        .opacity(0.62)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height + 80, alignment: .center)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.85), location: 0.45),
                                     .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
