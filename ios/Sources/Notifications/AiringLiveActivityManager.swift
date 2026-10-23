import Foundation
import ActivityKit

// App-side lifecycle for the "episode airing soon" Live Activity. Without push updates an
// activity can only be started/updated while the app runs, so the model is deliberately simple:
// every ambient sync (launch, foreground, library change) picks the ONE soonest watching-show
// episode airing within the lead window and makes the activity match it. The countdown itself
// ticks natively in the widget (Text(timerInterval:)) — no updates needed while backgrounded.
@MainActor
final class AiringLiveActivityManager {
    static let shared = AiringLiveActivityManager()

    /// Start the lock-screen countdown when an episode airs within the next hour.
    nonisolated static let leadWindow: Int64 = 60 * Formatting.minuteMs
    /// Keep the activity visible this long after air time ("out now"), then let it go stale.
    nonisolated static let linger: Int64 = 15 * Formatting.minuteMs

    private struct Candidate: Sendable {
        let title: String
        let episode: Int?
        let airsAt: Int64
    }

    func sync(library: [Franchise], now: Int64) {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled

        // Real instants only: a TV show on TMDB's dates alone (synthesized 17:00 UTC) would count
        // down to a fictitious instant; one at TVmaze broadcast times counts down like anime.
        let candidate: Candidate? = enabled
            ? library
                .filter { $0.effectiveStatus == .watching && !$0.timeAnchor.isDateOnly }
                .compactMap { f -> Candidate? in
                    guard let part = f.releasingPart, let at = part.nextAiringAt else { return nil }
                    // Inside the window: airing within the next hour, or aired in the last 15 min.
                    guard at - now <= AiringLiveActivityManager.leadWindow,
                          now - at <= AiringLiveActivityManager.linger else { return nil }
                    return Candidate(title: f.title, episode: part.nextEpisodeNumber, airsAt: at)
                }
                .min { $0.airsAt < $1.airsAt }
            : nil

        // All ActivityKit access lives in one detached task: activity handles are fetched and
        // consumed in the same isolation region (Swift 6 rejects sending them across actors).
        Task.detached {
            let current = Activity<AiringActivityAttributes>.activities

            guard let candidate else {
                for activity in current {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                return
            }

            let airsAt = Date(timeIntervalSince1970: Double(candidate.airsAt) / 1000)
            let state = AiringActivityAttributes.ContentState(airsAt: airsAt)
            let staleDate = airsAt.addingTimeInterval(Double(AiringLiveActivityManager.linger) / 1000)
            let content = ActivityContent(state: state, staleDate: staleDate)

            // Already tracking this exact episode — refresh its state; end any strays.
            if let existing = current.first(where: {
                $0.attributes.franchiseTitle == candidate.title
                    && $0.attributes.episodeNumber == candidate.episode
            }) {
                await existing.update(content)
                for stray in current where stray.id != existing.id {
                    await stray.end(nil, dismissalPolicy: .immediate)
                }
                return
            }

            for activity in current {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            let attributes = AiringActivityAttributes(
                franchiseTitle: candidate.title,
                episodeNumber: candidate.episode
            )
            _ = try? Activity.request(attributes: attributes, content: content)
        }
    }

    /// End every activity this app started, unconditionally. Sign-out calls this — a lock-screen
    /// countdown for a show in the previous account's library outlives the session that made it,
    /// and nothing in `sync` can retire it once that library is gone.
    func endAll() {
        Task.detached {
            for activity in Activity<AiringActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
