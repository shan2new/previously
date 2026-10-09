import Foundation

/// Share staging files belong to the captured account. Writes and cleanup share the main actor
/// with account teardown, so a late transfer cannot recreate private files after sign-out.
@MainActor
enum AccountExportStore {
    static func write(name: String, data: Data, owner: AccountLocalStore.Snapshot?,
                      isScratch: Bool = false, storage: AccountLocalStore? = nil,
                      directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let storage = storage ?? AccountLocalStore.shared
        guard isScratch || storage.matches(owner) else { throw CancellationError() }
        guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent,
              !name.hasPrefix(".") else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = directory.appendingPathComponent("PreviouslyExports", isDirectory: true)
            .appendingPathComponent(owner?.ownerKey ?? "scratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Copies saved outside the app-managed staging folder remain the user's own files.
    static func clearTemporaryFiles(directory: URL = FileManager.default.temporaryDirectory) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("PreviouslyExports", isDirectory: true))
        if let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix("export-") {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
