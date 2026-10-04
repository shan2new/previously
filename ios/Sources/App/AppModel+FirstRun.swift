import SwiftUI

// First run (4 Oct 2026): what a NEW account sees between signing in and its Home.
//
// It was one sheet ("What do you watch?") over an empty Home that said "Nothing to watch yet". The
// spike that led here (design/onboarding-2026-10-04/SPIKE.md) found the same three faults across
// the trackers: a forced minimum of picks and profile screens (Hobi), a history re-marked by hand
// episode by episode (Trakt's importer), and a first screen with nothing on it. So the flow is four
// questions, each answered by tapping pictures, every one skippable, and it ends on a Home that
// already holds the viewer's shows at the episode they are actually on:
//
//   what you watch → the shows you follow → where you are in each → your lineup (and alerts).
//
// WHO GETS IT. An account that has never answered the audience question AND has an empty library
// — a new account. An older account with shows but no answer keeps the one sheet
// (`audiencePromptDue`). The answer to the first question is the account's marker (it is written
// at once), and this device remembers that the flow is in hand (`FirstRun.pending`), so a launch
// that follows a quit mid-way resumes at the picker rather than opening an empty app. On another
// device such an account opens the app; its empty Home's button is the same picker.
//
// THE WRITES ARE QUIET. Nothing in the flow raises a receipt, an Undo or a haptic of the app's:
// the screens are the confirmation. Each show is ONE server call — membership, the status and the
// progress in one transaction (`saveProgressBatch`) — drawn into the library first
// (`insertPending`), so Home is composed under the flow before the calls return. A call that
// fails is filed where every failed write goes (Sync status, with its Retry) and its show leaves
// the library, as a membership write does.

enum FirstRunPhase: Equatable {
    /// Signed in, and whether this is a new account is not known yet (the library and the
    /// audience are on their way). Held on the brand, never on an empty Home.
    case checking
    /// A new account: the flow.
    case due
    /// The app.
    case done
}

enum FirstRun {
    /// The flow was begun on this device and not finished (a quit mid-way).
    private static let pendingKey = "previously.firstRun.pending"

    static var pending: Bool {
        get { UserDefaults.standard.bool(forKey: pendingKey) }
        set {
            if newValue { UserDefaults.standard.set(true, forKey: pendingKey) }
            else { UserDefaults.standard.removeObject(forKey: pendingKey) }
        }
    }

    /// What a launch knows before the network answers: a flow in hand resumes; a device that has
    /// the account's audience is an account that has been through this; otherwise ask the server.
    static var launchPhase: FirstRunPhase {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "firstRun") { return .due }
        #endif
        if pending { return .due }
        return Audience.storedChosen ? .done : .checking
    }

    /// How long the hold waits for the account's answer before the app opens anyway (a bad
    /// connection must not strand a signed-in viewer on the brand).
    static let checkPatience: Duration = .seconds(6)
}

/// Where a picked show stands, as the viewer said.
enum FirstRunPlacement: Equatable, Sendable {
    /// Everything released is watched (and the story's films with it).
    case caughtUp
    /// On `seasonId`, having watched `episode` of it; the seasons before it are watched.
    case partWay(seasonId: Int, episode: Int)
    /// Watching, from the first episode.
    case starting
    /// Planned.
    case later
}

/// One show's write, worked out from its placement: what goes to the server, and the same thing
/// applied to the copy the library draws meanwhile.
struct FirstRunWrite: Sendable {
    let parts: [FranchiseProgressValue]
    let status: WatchStatus

    init(_ f: Franchise, placement: FirstRunPlacement?, now: Int64) {
        switch placement {
        case .caughtUp:
            let batch = WatchedBatch(franchise: f, now: now)
            parts = batch.parts
            // Nothing released to mark (a premiere still ahead): it is simply followed.
            status = batch.parts.isEmpty ? (f.isReleasing ? .watching : .planned) : batch.status
        case .partWay(let seasonId, let episode):
            guard let part = f.parts.first(where: { $0.mediaId == seasonId }) else {
                parts = []; status = .watching; return
            }
            let ceiling = part.progressCeiling(now: now, anchor: f.timeAnchor)
            let own = FranchiseProgressValue(mediaId: seasonId, episodes: max(0, min(episode, ceiling)))
            parts = WatchedBatch(franchise: f, before: part, now: now).parts + (own.episodes > 0 ? [own] : [])
            status = .watching
        case .starting:
            parts = []; status = .watching
        case .later:
            parts = []; status = .planned
        case nil:
            // Not asked (skipped, or nothing to ask): the plain add's rule.
            parts = []; status = f.isReleasing ? .watching : .planned
        }
    }

    /// The show as the library draws it until the server's copy lands.
    func applied(to f: Franchise) -> Franchise {
        var out = f
        for value in parts { out = out.withUpdatedProgress(mediaId: value.mediaId, episodes: value.episodes) }
        return out.withStatus(status)
    }
}

extension AppModel {
    /// After the library and the audience have answered (`start()`): is this a new account?
    func resolveFirstRun() {
        guard firstRun == .checking else { return }
        // `syncAudience` raised the one-time question: the account has never answered. With no
        // shows either, it is new — the flow asks that question as its first step.
        if audiencePromptDue, library.isEmpty, !loadError, !accountSuspended {
            audiencePromptDue = false
            FirstRun.pending = true
            firstRun = .due
        } else {
            firstRun = .done
        }
    }

    /// The hold gives up: the app opens, and anything still owed is asked there.
    func abandonFirstRunCheck() {
        if firstRun == .checking { firstRun = .done }
    }

    /// The flow is over (finished, or skipped): the app.
    func finishFirstRun() {
        FirstRun.pending = false
        // An account that left before answering the first question is still asked it, once, by the
        // sheet — never silently filed as "both".
        if !audienceChosen { audiencePromptDue = true }
        firstRun = .done
    }

    /// Sign-out: the next account is looked at afresh.
    func resetFirstRun() {
        FirstRun.pending = false
        firstRun = .checking
    }

    /// One picked show, placed. Drawn now; canonical when the call returns. Returns whether the
    /// server took it.
    @discardableResult
    func placeFirstRunShow(_ f: Franchise, write: FirstRunWrite) async -> Bool {
        guard !isInLibrary(f.id) || pendingAdds.contains(f.id) else { return true }
        insertPending(write.applied(to: f))
        let task = enqueueBatch(f.id) { [weak self] in
            guard let self else { return }
            do {
                try await self.saveProgressBatch(f, parts: write.parts, status: write.status)
            } catch {
                guard !error.isCancellation else { return }
                self.withdrawPending(f.id)
                self.recordBatchFailure(franchiseId: f.id, title: f.title, parts: write.parts,
                                        status: write.status, error: error)
            }
        }
        await task.value
        return isInLibrary(f.id)
    }
}
