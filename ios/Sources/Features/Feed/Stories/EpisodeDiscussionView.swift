import SwiftUI

// One episode's discussion room (ios-spec §4.2, §4.9), as a sheet from a story's reply field or
// as a pushed page (a notification about an `ep:` reply lands here).
//
// The room is spoiler-gated ON THE SERVER; the client says open at once from the live part (the
// same two rules, iD16), and can only unlock later than the server, never earlier. Anatomy, both
// presentations: the show as the account, "Episode 5 discussion", "Spoilers for Episode 5 and
// earlier.", the rating sticker, then the replies (`CommentThreadSection`) with the sticky
// `InlineReplyComposer`. With comments off (`feedCapabilities.comments == false`): header + rating only.
//
// The replies read waits for the part's progress lane (the model's `loadComments`), so a mark made
// seconds ago has reached the server first; a room the server still locks while the client says
// open shows "Saving your progress" while the failed write replays, then reads once more.

struct EpisodeDiscussionView: View {
    enum Presentation { case sheet, page }

    let franchiseId: String
    let mediaId: Int
    let episode: Int
    let presentation: Presentation
    var focusCommentId: String? = nil
    var onOpenShow: ((String) -> Void)? = nil

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The full composer (the gate's steps, or the inline bar's ↗).
    @State private var composing: ComposeTarget?
    /// The inline bar's target when it is a reply to one reply.
    @State private var replyTarget: ComposeTarget?
    @State private var batchConfirm = false
    @State private var focused = false

    private var subject: String { ThreadSubject.episode(mediaId: mediaId, episode: episode) }
    private var host: String { ReceiptHost.story(mediaId, episode) }

    var body: some View {
        switch presentation {
        case .page:
            content
                .brandNavigationTitle(Copy.Stories.discussionTitle(episode))
                .navigationBarTitleDisplayMode(.inline)
        case .sheet:
            NavigationStack {
                content
                    .brandNavigationTitle(Copy.Stories.discussionTitle(episode))
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .perfScreen("Discussion")
        }
    }

    // MARK: The page

    private var content: some View {
        let access = effectiveAccess
        let open = access == .open
        let comments = appModel.feedCapabilities.comments
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    if open {
                        EpisodeRatingSlider(mediaId: mediaId, episode: episode)
                            .frame(maxWidth: StoryStyle.stickerMaxWidth)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, ThemeMetrics.gutter)
                            .padding(.bottom, ThemeSpace.x5)
                            .transition(.opacity)
                    }
                    if presentation == .sheet {
                        ReceiptLine(host: host)
                    }
                    Rectangle()
                        .fill(ThemeColor.feedSeparator)
                        .frame(height: FeedMetrics.hairline)
                    if comments {
                        replies(access: access)
                    }
                }
                .padding(.bottom, ThemeSpace.x8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // A pushed page keeps the tab bar's clearance under the lane's (the pushed scaffold's
            // own margin is the same value); a sheet has neither bar nor lane.
            .laneClearance(appModel, base: presentation == .page ? ThemeMetrics.tabBarClearance : 0)
            .background(ThemeColor.canvas.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    // As a sheet it covers the tab bar's lane ("Reply deleted", "Blocked @dex", a
                    // report's receipt): the lane sits here, above the reply bar, which stays put.
                    if presentation == .sheet { CoverLane() }
                    if comments, open, !threadLocked {
                        InlineReplyComposer(target: target, replyingTo: $replyTarget,
                                            onFullComposer: { composing = $0 },
                                            onSent: {
                                                withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                                                    proxy.scrollTo(CommentThreadSection.headerID, anchor: .top)
                                                }
                                            })
                    }
                }
            }
            .onChange(of: appModel.thread(subject)?.items.count ?? 0) { _, count in
                guard count > 0, !focused, let focusCommentId else { return }
                focused = true
                withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(focusCommentId, anchor: .center)
                }
            }
        }
        .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: open)
        .task { await appModel.loadEpisodeRoom(mediaId: mediaId, episode: episode) }
        .onChange(of: open) { _, nowOpen in
            // A mark made here (or in the story behind the sheet): a room the server locked when
            // it was last read is read again, now that the progress is on its way.
            guard nowOpen, comments, appModel.thread(subject)?.locked == true else { return }
            Task { await appModel.loadComments(subject, sort: appModel.thread(subject)?.sort ?? .top, reset: true) }
        }
        .sheet(item: $composing) { ComposeSheet(target: $0) }
        .alert(Copy.Confirm.batchMarkTitle(batchCount), isPresented: $batchConfirm) {
            Button(Copy.Confirm.batchMarkConfirm(batchCount)) { commitBatch() }
            Button(Copy.Confirm.cancel, role: .cancel) {}
        } message: {
            Text(batchMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                onOpenShow?(franchiseId)
            } label: {
                HStack(spacing: FeedMetrics.gap) {
                    ShowAvatar(candidates: showCandidates, size: FeedMetrics.avatar)
                    VStack(alignment: .leading, spacing: ThemeSpace.x0_5) {
                        Text(showTitle)
                            .type(ThemeType.feedName)
                            .foregroundStyle(ThemeColor.feedText)
                            .lineLimit(2)
                        if let partLabel {
                            Text(Copy.watchContext(part: partLabel, episode: episode))
                                .type(ThemeType.feedMeta)
                                .foregroundStyle(ThemeColor.feedSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: FeedMetrics.actionHitHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpenShow == nil)
            .accessibilityElement(children: .combine)
            .accessibilityHint(onOpenShow == nil ? "" : Copy.Feed.goTo(showTitle))

            Text(Copy.Stories.discussionTitle(episode))
                .type(ThemeType.feedLightLarge)
                .foregroundStyle(ThemeColor.feedText)
                .padding(.top, ThemeSpace.x3 + ThemeSpace.x0_5)
            Text(Copy.Stories.spoilers(episode))
                .type(ThemeType.feedSubhead)
                .foregroundStyle(ThemeColor.feedSecondary)
                .padding(.top, ThemeSpace.x1)
                .padding(.bottom, ThemeSpace.x4)
        }
        // The replies' own inset (16 since 16 Oct — it was 10, and this header 10 + 6 to reach the
        // gutter), so the show's face and the repliers' share a column.
        .padding(.horizontal, FeedMetrics.inset)
        .padding(.top, ThemeSpace.x3)
    }

    // MARK: Replies and their gate

    @ViewBuilder
    private func replies(access: EpisodeAccess) -> some View {
        let thread = appModel.thread(subject)
        switch access {
        case .unaired:
            lockLine(Copy.Stories.lockedUnaired(episode), glyph: "clock")
        case .unwatched, .unknown:
            VStack(alignment: .leading, spacing: ThemeSpace.x4) {
                lockLine(Copy.Stories.lockedUnwatched(episode), glyph: "lock.fill")
                if let part = livePart, part.progress < episode {
                    Button(action: mark) { Text(markLabel(part)).lineLimit(2).multilineTextAlignment(.center) }
                        .buttonStyle(PrimaryButtonStyle2())
                        .padding(.horizontal, ThemeMetrics.gutter)
                }
            }
        case .open:
            if let thread, thread.locked {
                if thread.loading, thread.access == .unwatched {
                    // The mark is still on its way to the server (§4.2 step 3).
                    HStack(spacing: ThemeSpace.x2) {
                        ProgressView().controlSize(.small).tint(ThemeColor.feedSecondary)
                        Text(Copy.Stories.savingProgress)
                            .type(ThemeType.feedSmall)
                            .foregroundStyle(ThemeColor.feedSecondary)
                    }
                    .padding(.horizontal, ThemeMetrics.gutter)
                    .padding(.vertical, ThemeSpace.x5)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                } else if thread.access == .unaired {
                    lockLine(Copy.Stories.lockedUnaired(episode), glyph: "clock")
                } else {
                    // The server still says unwatched after the replay: the write did not land.
                    VStack(spacing: ThemeSpace.x2) {
                        lockLine(Copy.Stories.lockedUnwatched(episode), glyph: "lock.fill")
                        Button(Copy.Action.tryAgain) {
                            Task { await appModel.loadComments(subject, sort: thread.sort, reset: true) }
                        }
                        .buttonStyle(TertiaryButtonStyle2())
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                CommentThreadSection(subject: subject, franchiseTitle: showTitle,
                                     focusCommentId: focusCommentId) { replyTarget = $0 }
            }
        }
    }

    private func lockLine(_ text: String, glyph: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ThemeSpace.x2) {
            AppGlyph(systemName: glyph)
                .font(.footnote.weight(.semibold))
            Text(text)
                .type(ThemeType.feedSubhead)
        }
        .foregroundStyle(ThemeColor.feedSecondary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeSpace.x6)
        .padding(.bottom, ThemeSpace.x2)
        .accessibilityElement(children: .combine)
    }

    // MARK: Gate

    /// The client's gate from the live part; a show outside the library asks the server's room.
    private var effectiveAccess: EpisodeAccess {
        let client = appModel.clientEpisodeAccess(franchiseId: franchiseId, mediaId: mediaId, episode: episode)
        guard client == .unknown else { return client }
        return appModel.episodeRoom(mediaId: mediaId, episode: episode)?.access ?? .unknown
    }

    private var threadLocked: Bool { appModel.thread(subject)?.locked == true }

    // MARK: Mark (the lock's way out)

    private var livePart: FranchisePart? {
        appModel.franchise(id: franchiseId)?.parts.first { $0.mediaId == mediaId }
    }

    private func markLabel(_ part: FranchisePart) -> String {
        episode == part.progress + 1
            ? Copy.Action.markEpisodeWatched(episode)
            : Copy.Action.markThrough(from: part.progress + 1, to: episode)
    }

    private var batchCount: Int { max(1, episode - (livePart?.progress ?? 0)) }

    private var batchMessage: String {
        guard let part = livePart else { return "" }
        return Copy.Confirm.batchMarkMessage(title: showTitle, season: part.label, from: part.progress, to: episode)
    }

    /// The same write as the story's: `markNext` for the next episode, the exact-count confirmation
    /// then `markThrough` further ahead. The receipt sits in this room (`ReceiptLine`), under the
    /// sticker that the mark just opened.
    private func mark() {
        guard let part = livePart, part.progress < episode else { return }
        if episode == part.progress + 1 {
            guard let undo = appModel.markNext(franchiseId: franchiseId, mediaId: mediaId) else { return }
            present(undo)
        } else {
            batchConfirm = true
        }
    }

    private func commitBatch() {
        guard let undo = appModel.markThrough(franchiseId: franchiseId, mediaId: mediaId,
                                              episode: episode, present: false) else { return }
        present(undo)
    }

    /// In the sheet (over the story, where the lane is hidden) the receipt is drawn in this room,
    /// under the story's own host so the frame behind shows the same Undo; as a pushed page the
    /// lane is on screen and takes it.
    private func present(_ undo: UndoState) {
        let inPlace = presentation == .sheet && undo.mediaId == mediaId && undo.episode == episode
        appModel.presentUndo(inPlace ? undo.placed(at: host) : undo)
        if inPlace { Announce.status(undo.message) }
    }

    // MARK: The show

    /// The library's copy, else whatever loaded response knows the show (a notification can land
    /// here for a show outside the library).
    private var showStub: Franchise? {
        if let f = appModel.franchise(id: franchiseId) { return f }
        for state in appModel.feedTabs.values {
            if let hit = state.response?.franchises.first(where: { $0.id == franchiseId }) { return hit.stub }
        }
        return appModel.reminderFranchises[franchiseId]?.stub
    }

    private var showTitle: String {
        showStub?.displayTitle ?? appModel.activity.first { $0.franchiseId == franchiseId }?.title ?? ""
    }

    private var showCandidates: [String] {
        showStub.map(FeedAvatar.candidates) ?? []
    }

    private var partLabel: String? {
        appModel.franchise(id: franchiseId)?.parts.first { $0.mediaId == mediaId }?.label
    }

    private var target: ComposeTarget {
        ComposeTarget(subject: subject, franchiseId: franchiseId, franchiseTitle: showTitle, episode: episode)
    }
}
