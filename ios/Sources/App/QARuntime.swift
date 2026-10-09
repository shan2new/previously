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
        guard ProcessInfo.processInfo.environment["PREVIOUSLY_QA_RESET_LOCAL"] == "1" else { return }
        UserDefaults.standard.removePersistentDomain(forName: "com.cognipin.previously.qa")
        // These are the QA sandbox's directories, never the installed user's app container.
        for location in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            if let directory = FileManager.default.urls(for: location, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: directory)
            }
        }
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
