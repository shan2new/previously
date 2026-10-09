import Foundation

extension WatchSession {
    var title: String { Copy.Progress.ordinalWatch(ordinal) }

    func subtitle(nextEpisode: Int?, now: Int64) -> String {
        if isActive {
            if let nextEpisode { return Copy.Progress.inProgress(nextEpisode: nextEpisode) }
            return "In progress"
        }
        if let cancelledAtEpisode {
            return "Cancelled at \(Copy.episodeInSentence(cancelledAtEpisode))"
        }
        return Copy.Progress.sessionSpan(started: startedAt, completed: completedAt == 0 ? nil : completedAt,
                                         episodes: episodes, now: now)
    }
}
