import Foundation
import SwiftUI

// QA controls exist only in the dedicated QA configuration. The ordinary app's Debug and
// Release builds do not accept endpoint, account or reset overrides from the environment.
#if PREVIOUSLY_QA
enum QARuntime {
    static var enabled: Bool { ProcessInfo.processInfo.environment["PREVIOUSLY_QA"] == "1" }

    static var baseURL: URL? {
        guard enabled else { return nil }
        let raw = ProcessInfo.processInfo.environment["PREVIOUSLY_QA_BASE_URL"] ?? "http://127.0.0.1:18787"
        guard let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            preconditionFailure("QA transport must use an explicit loopback HTTP origin")
        }
        return url
    }

    static func prepare() {
        guard enabled else { return }
        guard Bundle.main.bundleIdentifier == "com.cognipin.previously.qa" else {
            preconditionFailure("QA controls require the isolated QA application bundle")
        }
        _ = baseURL // Validate before any state is touched.
        stageFileSamples(resetExports: ProcessInfo.processInfo.environment["PREVIOUSLY_QA_RESET_LOCAL"] == "1")
        guard ProcessInfo.processInfo.environment["PREVIOUSLY_QA_RESET_LOCAL"] == "1" else { return }
        UserDefaults.standard.removePersistentDomain(forName: "com.cognipin.previously.qa")
        // These are the QA sandbox's directories, never the installed user's app container.
        for location in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            if let directory = FileManager.default.urls(for: location, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Files stay inside the explicitly enabled QA bundle. The tests must select them through
    /// the system document picker; staging never invokes an import or creates a server job.
    private static func stageFileSamples(resetExports: Bool) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            preconditionFailure("QA Documents directory is unavailable")
        }
        let samples = documents.appendingPathComponent("QA Samples", isDirectory: true)
        func entry(id: Int, title: String, watched: Int, status: String) -> String {
            "<anime><series_animedb_id>\(id)</series_animedb_id><series_title>\(title)</series_title><my_watched_episodes>\(watched)</my_watched_episodes><my_status>\(status)</my_status></anime>"
        }
        let allowed = entry(id: 900001, title: "QA Planned", watched: 3, status: "Watching")
        let skipped = entry(id: 900002, title: "QA Policy Omission", watched: 2, status: "Completed")
        do {
            try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
            for (name, entries) in [("qa-partial.xml", allowed + skipped), ("qa-all-skipped.xml", skipped)] {
                try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><myanimelist>\(entries)</myanimelist>".utf8)
                    .write(to: samples.appendingPathComponent(name), options: .atomic)
            }
            if resetExports {
                for name in ["previously-qa-export.json", "previously-library.csv"] {
                    let file = documents.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
            }
        } catch { preconditionFailure("Synthetic QA Files staging failed") }
    }

    /// Read-only filesystem oracle after a real Save to Files action. Only the known synthetic
    /// export names in this QA app's Documents are exposed, bounded to 256KiB; never temp staging.
    static func savedExport(_ format: String) -> String {
        guard enabled, Bundle.main.bundleIdentifier == "com.cognipin.previously.qa",
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return "unavailable" }
        let name = format == "json" ? "previously-qa-export.json" : "previously-library.csv"
        let url = documents.appendingPathComponent(name)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 256 * 1024, let data = try? Data(contentsOf: url) else { return "missing" }
        return data.base64EncodedString()
    }

    @MainActor static func bootstrap(_ auth: AuthManager) {
        guard enabled else { return }
        // Seed an identity once per explicitly reset sandbox. A real sign-out or deletion must
        // stay signed out across process launches, rather than silently recreating fixture-a.
        let remembered = UserDefaults.standard.string(forKey: "previously.devClerkId")
        let seededKey = "previously.qa.identitySeeded"
        guard remembered != nil || !UserDefaults.standard.bool(forKey: seededKey) else { return }
        let requested = ProcessInfo.processInfo.environment["PREVIOUSLY_QA_ACCOUNT"] ?? "fixture-a"
        let account = remembered?.isEmpty == false ? remembered! : requested
        guard ["fixture-a", "fixture-b"].contains(account) else {
            preconditionFailure("QA requires a synthetic fixture account")
        }
        auth.signInDev(clerkId: account)
        UserDefaults.standard.set(true, forKey: seededKey)
    }
}
#endif

extension View {
    @ViewBuilder func qaFilesEvidence() -> some View {
        #if PREVIOUSLY_QA
        if QARuntime.enabled {
            overlay(alignment: .topLeading) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 0) {
                        Text("QA saved JSON copy").accessibilityIdentifier("qa.files.saved.json")
                            .accessibilityValue(QARuntime.savedExport("json"))
                        Text("QA saved CSV copy").accessibilityIdentifier("qa.files.saved.csv")
                            .accessibilityValue(QARuntime.savedExport("csv"))
                    }
                    .font(.system(size: 1)).foregroundStyle(.clear).allowsHitTesting(false)
                }
            }
        } else { self }
        #else
        self
        #endif
    }

    @ViewBuilder func qaIdentifier(_ identifier: String) -> some View {
        #if PREVIOUSLY_QA
        accessibilityIdentifier(identifier)
        #else
        self
        #endif
    }

    @ViewBuilder func qaReadiness(auth: AuthManager, model: AppModel) -> some View {
        #if PREVIOUSLY_QA
        overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                Text("QA readiness")
                    .accessibilityIdentifier("qa.ready")
                    .accessibilityValue(auth.isSignedIn && model.lastLoadedAt > 0 && !model.loading ? "ready" : "loading")
                Text("QA reachability generation")
                    .accessibilityIdentifier("qa.network.generation")
                    .accessibilityValue(String(SyncCenter.shared.qaMonitorGeneration))
                Text("QA reachability callbacks")
                    .accessibilityIdentifier("qa.network.callbacks")
                    .accessibilityValue(String(SyncCenter.shared.qaMonitorCallbacks))
                Text("QA trailer provider state")
                    .accessibilityIdentifier("qa.trailer.state")
                    .accessibilityValue(TrailerPlaybackQAEvidence.shared.value)
                Text("QA recorded failures")
                    .accessibilityIdentifier("qa.sync.failure.count")
                    .accessibilityValue(String(SyncCenter.shared.failedChanges.count))
                Text("QA widget snapshot owner")
                    .accessibilityIdentifier("qa.widget.owner")
                    .accessibilityValue(NextUpSnapshotStore.shared.snapshot?.owner.key ?? "none")
                Text("QA widget snapshot shows")
                    .accessibilityIdentifier("qa.widget.shows")
                    .accessibilityValue(NextUpSnapshotStore.shared.snapshot?.items.map(\.id).joined(separator: ",") ?? "none")
                Text("QA widget snapshot generation")
                    .accessibilityIdentifier("qa.widget.generation")
                    .accessibilityValue(NextUpSnapshotStore.shared.snapshot?.owner.generation.uuidString ?? "none")
                Text("QA widget active owner")
                    .accessibilityIdentifier("qa.widget.activeOwner")
                    .accessibilityValue(NextUpSnapshotStore.shared.current?.key ?? "none")
                Text("QA widget stored files")
                    .accessibilityIdentifier("qa.widget.files")
                    .accessibilityValue({
                        _ = NextUpSnapshotStore.shared.revision
                        guard let directory = NextUpSnapshot.directory,
                              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return "0" }
                        return String(files.count)
                    }())
                Text("QA durable tracking intents")
                    .accessibilityIdentifier("qa.journal.count")
                    .accessibilityValue(String(SyncCenter.shared.qaJournalCount))
                ForEach(SyncCenter.shared.qaJournalProgress, id: \.mediaId) { value in
                    Text("QA durable progress")
                        .accessibilityIdentifier("qa.journal.progress.\(value.mediaId)")
                        .accessibilityValue(String(value.episodes))
                    Text("QA durable mutation stamp")
                        .accessibilityIdentifier("qa.journal.stamp.\(value.mediaId)")
                        .accessibilityValue("\(value.mutation.operationID.uuidString.lowercased())|\(value.mutation.writerID.uuidString.lowercased())|\(value.mutation.sequence)")
                }
                if case .dev(let account) = auth.mode {
                    Text("QA identity")
                        .accessibilityIdentifier("qa.account.\(account)")
                        .accessibilityValue(account)
                }
            }
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .allowsHitTesting(false)
        }
        .qaFilesEvidence()
        #else
        self
        #endif
    }

    @ViewBuilder func qaProgress(_ franchise: Franchise) -> some View {
        #if PREVIOUSLY_QA
        overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                Text("QA detail")
                    .accessibilityIdentifier("qa.detail.\(franchise.id)")
                ForEach(franchise.parts) { part in
                    Text("QA progress")
                        .accessibilityIdentifier("qa.progress.\(part.mediaId)")
                        .accessibilityValue(String(part.progress))
                }
            }
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .allowsHitTesting(false)
        }
        #else
        self
        #endif
    }
}
