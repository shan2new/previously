import Foundation
import OSLog
import UserNotifications

// Local "episode is out" alerts. AniList gives us each watching show's next airing instant
// (`nextAiringAt`), so the app schedules one local notification per show — no push
// infrastructure needed. AppModel re-syncs the pending set after every confirmed library
// change (reload / status change / remove), so the schedule always mirrors the library.
@MainActor
final class EpisodeNotifications {
    static let shared = EpisodeNotifications()
    nonisolated static let log = Logger(subsystem: "app.previously", category: "alerts")

    /// iOS caps pending local notifications at 64 per app; stay safely under it. One per show
    /// (only the next airing is known), soonest first — a library bigger than this keeps alerts
    /// for the 48 shows airing next.
    static let maxPending = 48

    private let center = UNUserNotificationCenter.current()
    /// Held strongly here — `center.delegate` is weak, and a deallocated delegate silently
    /// restores the "drop it" default.
    private let foregroundPresenter = ForegroundPresenter()

    /// Where a tapped alert lands: the route it carries (`userInfo["route"]`, an `OpenRoute`) —
    /// the show for an episode or premiere alert, the post for a reminder. Installed at launch by
    /// the app. Before this, tapping "Episode 12 is out now" merely foregrounded whatever tab was up.
    var onOpen: (@MainActor (OpenRoute) -> Void)? {
        get { foregroundPresenter.onOpen }
        set { foregroundPresenter.onOpen = newValue }
    }

    /// The key a request's route is stored under in `content.userInfo`.
    nonisolated static let routeKey = "route"

    /// Install the foreground presentation delegate. Called once at launch, before the window
    /// exists, because iOS only consults a delegate that was set by the end of launch.
    func registerForegroundPresenter() {
        center.delegate = foregroundPresenter
    }

    /// Ask for permission the first time it's worth having (an airing show was just added), so
    /// the system prompt lands with obvious context instead of firing at first launch.
    @discardableResult
    func requestPermissionIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    /// Where permission stands, asked of the system without prompting — the feed's reminder
    /// primer and the story's "Next episode" frame decide what to draw from it.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Alerts per show. One used to be all there was, so a viewer who got the alert for episode
    /// 5 and did not open the app for three weeks heard nothing about 6, 7 or 8 — the feature
    /// went quiet for exactly the person it exists to bring back. The per-part `airings` carry
    /// the next fortnight, so each show arms its next three within the budget.
    static let perShow = 3

    /// Rebuild the pending-notification set from the current library: an alert at air time for
    /// each watching show's next few episodes, soonest first, one round per show — and one for each
    /// feed reminder on a dated premiere (`reminders`, from `AppModel.reminderAlerts(now:)`), unless
    /// that premiere is already alerted as `premiere-<mediaId>`.
    func sync(library: [Franchise], reminders: [ReminderAlert] = [], now: Int64) async {
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
        guard authorized else { return }

        struct UpcomingAiring {
            let franchiseId: String
            let title: String
            let mediaId: Int
            let episode: Int?
            let airsAt: Int64
        }

        // Real instants only: a TV show on TMDB's dates alone (synthesized 17:00 UTC) would alert at
        // a meaningless instant; one at real instants (`timesExact`: a broadcast slot or a platform drop) alerts like anime.
        let perShow: [[UpcomingAiring]] = library
            .filter { $0.effectiveStatus == .watching && !$0.timeAnchor.isDateOnly }
            .compactMap { f -> [UpcomingAiring]? in
                guard let part = f.releasingPart else { return nil }
                var slots = part.airings
                    .filter { $0.at > now }
                    .sorted { $0.at < $1.at }
                    .prefix(EpisodeNotifications.perShow)
                    .map { UpcomingAiring(franchiseId: f.id, title: f.displayTitle, mediaId: part.mediaId,
                                          episode: $0.episode, airsAt: $0.at) }
                if slots.isEmpty, let at = part.nextAiringAt, at > now {
                    slots = [UpcomingAiring(franchiseId: f.id, title: f.displayTitle, mediaId: part.mediaId,
                                            episode: part.nextEpisodeNumber, airsAt: at)]
                }
                return slots.isEmpty ? nil : slots
            }
        // Round by round: every show keeps its soonest alert before any show gets its second,
        // so a large library never starves a show of its next episode for another's third.
        var upcoming: [UpcomingAiring] = []
        for rank in 0..<EpisodeNotifications.perShow {
            upcoming += perShow.compactMap { $0.count > rank ? $0[rank] : nil }
                .sorted { $0.airsAt < $1.airsAt }
        }
        // PREMIERES (review, 23 Sep): a season that has not started is never "releasing", so a
        // return — Black Clover's Season 2, a Planned show's first episode — never alerted at all,
        // and TV got nothing. One alert per tracked show (every status but Dropped) whose next
        // season is DATED within two months: anime at its minute, TV (date-only) at 9 AM local
        // on the day. They take their turn before any show's second episode.
        let horizon = now + 60 * Formatting.D
        let premieres: [(franchiseId: String, title: String, part: FranchisePart, at: Int64)] = library
            .filter { $0.effectiveStatus != .dropped }
            .compactMap { f in
                guard let part = f.parts.filter({ $0.premiereAt.map { $0 > now && $0 <= horizon } ?? false })
                    .min(by: { ($0.premiereAt ?? .max) < ($1.premiereAt ?? .max) }),
                      var at = part.premiereAt else { return nil }
                if f.timeAnchor.isDateOnly {
                    // The DAY is the UTC calendar day of the synthesized 17:00 UTC instant (the
                    // contract); read in the device's calendar it is the next day east of UTC+7,
                    // and the alert fired a day late (review i3). That day, at 9 AM local.
                    guard let nine = Self.nineAM(onUTCDateOf: at) else { return nil }
                    at = nine
                    guard at > now else { return nil }
                }
                return (f.id, f.displayTitle, part, at)
            }
        let firstRound = upcoming.prefix(perShow.count)
        upcoming = Array(firstRound) + premieres.map {
            UpcomingAiring(franchiseId: $0.franchiseId, title: $0.title, mediaId: $0.part.mediaId,
                           episode: nil, airsAt: $0.at)
        } + upcoming.dropFirst(perShow.count)
        let premiereIds = Set(premieres.map { $0.part.mediaId })

        // FEED REMINDERS (spec §4.4): a reminder set on a dated post fires at its premiere — the
        // minute for an exact instant, 9 AM local on the UTC date for a date-only one — unless that
        // premiere is already alerted as `premiere-<mediaId>` above (server §13.11). They take
        // their turn after the premieres and before any show's second episode.
        var reminderIds = Set<String>()
        let reminderSlots: [(alert: ReminderAlert, at: Int64)] = reminders
            .compactMap { r -> (alert: ReminderAlert, at: Int64)? in
                if let m = r.mediaId, premiereIds.contains(m) { return nil }
                guard let at = Self.fireTime(for: r), at > now, reminderIds.insert(r.postId).inserted else { return nil }
                return (r, at)
            }
            .sorted { $0.at < $1.at }

        let rest = Array(upcoming.dropFirst(perShow.count + premieres.count))
        let head = Array(upcoming.prefix(perShow.count + premieres.count))
        let headRequests = head.map { airing -> UNNotificationRequest in
            let premiere = premieres.first { $0.part.mediaId == airing.mediaId && premiereIds.contains(airing.mediaId) && airing.episode == nil }
            return Self.request(for: airing.franchiseId, title: airing.title, mediaId: airing.mediaId,
                                episode: airing.episode, premiereLabel: premiere?.part.canonicalLabel,
                                at: airing.airsAt, now: now)
        }
        let reminderRequests = reminderSlots.map { slot -> UNNotificationRequest in
            let content = UNMutableNotificationContent()
            content.title = slot.alert.title
            content.body = Copy.Alert.premiere(slot.alert.installment)
            content.sound = .default
            content.threadIdentifier = slot.alert.franchiseId
            content.userInfo = [Self.routeKey: OpenRoute.post(postId: slot.alert.postId, commentId: nil).encoded]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, Double(slot.at - now) / 1000), repeats: false)
            return UNNotificationRequest(identifier: "reminder-\(slot.alert.postId)", content: content, trigger: trigger)
        }
        let restRequests = rest.map { airing -> UNNotificationRequest in
            Self.request(for: airing.franchiseId, title: airing.title, mediaId: airing.mediaId,
                         episode: airing.episode, premiereLabel: nil, at: airing.airsAt, now: now)
        }
        let requests = Array((headRequests + reminderRequests + restRequests).prefix(EpisodeNotifications.maxPending))

        // The app schedules nothing else, so a full clear + re-add keeps this idempotent.
        center.removeAllPendingNotificationRequests()

        for request in requests {
            try? await center.add(request)
        }

        #if DEBUG
        // `-dumpAlerts 1`: what was armed, for QA (spec §6.4 item 12).
        if UserDefaults.standard.bool(forKey: "dumpAlerts") {
            let iso = ISO8601DateFormatter()
            let line = requests.map { r -> String in
                let delay = (r.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval ?? 0
                return "\(r.identifier),\(iso.string(from: Date(timeIntervalSince1970: Double(now) / 1000 + delay)))"
            }.joined(separator: ";")
            print("ALERTS \(line)")
        }
        #endif
    }

    /// An episode or premiere alert. Every request carries its route (`userInfo["route"]`), so a
    /// tap lands where the alert points without guessing from the thread.
    private static func request(for franchiseId: String, title: String, mediaId: Int, episode: Int?,
                                premiereLabel: String?, at: Int64, now: Int64) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = premiereLabel.map { Copy.Alert.premiere($0) } ?? Copy.Alert.episodeOut(episode)
        content.sound = .default
        content.threadIdentifier = franchiseId  // group repeat alerts per franchise
        content.userInfo = [routeKey: OpenRoute.show(franchiseId: franchiseId).encoded]
        let delay = max(1, Double(at - now) / 1000)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        return UNNotificationRequest(
            identifier: premiereLabel == nil ? "episode-\(mediaId)-\(episode ?? 0)" : "premiere-\(mediaId)",
            content: content,
            trigger: trigger
        )
    }

    /// When a feed reminder fires: the premiere's minute for an exact instant; 9 AM local on its
    /// UTC date for a date-only one (the TV premiere rule above). Nil when the day cannot be built.
    nonisolated static func fireTime(for reminder: ReminderAlert) -> Int64? {
        reminder.dateOnly ? nineAM(onUTCDateOf: reminder.at) : reminder.at
    }

    /// 9 AM local on the UTC calendar day of a date-only instant (a synthesized 17:00 UTC TMDB
    /// slot, or a feed premiere carried at 12:00 UTC of its day). Read in the device's calendar the
    /// instant is the next day east of UTC+7 — the alert used to fire a day late (review i3).
    nonisolated static func nineAM(onUTCDateOf at: Int64) -> Int64? {
        let p = Formatting.localParts(at, anchor: .utcDate)
        var local = DateComponents()
        local.year = p.y; local.month = p.mo; local.day = p.d; local.hour = 9
        var cal = Calendar.current
        cal.timeZone = .current
        guard let nine = cal.date(from: local) else { return nil }
        return Int64(nine.timeIntervalSince1970 * 1000)
    }

    /// Drop every alert this app owns — pending and already delivered. Sign-out calls this: the
    /// schedule is built from one account's library, so leaving it armed would announce the
    /// previous user's episodes to whoever signs in next (or to nobody at all).
    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}

// An episode alert most often fires while you're IN the app — that's what "it's out now" means.
// Without a delegate iOS suppresses it entirely, so the one notification the app schedules was
// silently dropped at exactly its most likely moment. Present it like any other alert.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onOpen: (@MainActor (OpenRoute) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// The tap. The request's `userInfo["route"]` says where it goes; an alert armed before routes
    /// existed falls back to its `threadIdentifier`, the franchise id every alert is filed under.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let content = response.notification.request.content
        let encoded = content.userInfo[EpisodeNotifications.routeKey] as? String
        let route: OpenRoute
        if let encoded, let decoded = OpenRoute(encoded: encoded) {
            route = decoded
        } else {
            let id = content.threadIdentifier
            guard !id.isEmpty else { return }
            route = .show(franchiseId: id)
        }
        EpisodeNotifications.log.info("alert opened: \(response.notification.request.identifier, privacy: .public)")
        await MainActor.run { onOpen?(route) }
    }
}

/// A feed reminder on a dated premiere, armed as a local alert (spec §4.4). Built by
/// `AppModel.reminderAlerts(now:)` from the reminders the server holds and the posts on screen.
struct ReminderAlert: Equatable, Sendable {
    let postId: String
    let franchiseId: String
    /// The show's `displayTitle`.
    let title: String
    /// The post's installment ("" allowed) — the alert's body names it.
    let installment: String
    /// `post.part?.mediaId` — the premiere dedupe against `premiere-<mediaId>`.
    let mediaId: Int?
    /// The premiere instant.
    let at: Int64
    let dateOnly: Bool
}
