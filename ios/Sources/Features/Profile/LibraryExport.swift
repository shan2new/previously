import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// The account as a file (board 15: export is always free).
///
/// **JSON is the account's own copy** (`GET /me/export`, server §7.3): the library, the replies,
/// likes, saves, reminders, hides, ratings, blocks and reports — everything the server holds for
/// this account, in the file the server names (`previously-export-<date>.json`). It is fetched when
/// the person picks a destination, not when the screen opens: the route is rate limited to a few
/// exports an hour, and a screen that merely opened must not spend one. It works while the account
/// is suspended (server D12). A server that predates the route (404) gets the device's own library
/// export instead, as before — titles, statuses and progress, never account identifiers.
///
/// **CSV is the library, made on this device**: one row per part, for spreadsheets.
struct LibraryExport: Transferable {
    enum Format { case json, csv }
    /// Where the account's copy comes from. Nil for a model with no server behind it.
    let api: APIClient?
    /// The device's JSON copy, used only when the server has no export route.
    let local: Data
    let owner: AccountLocalStore.Snapshot?
    let isScratch: Bool
    private let preparation: AccountExportPreparation<Document>

    private struct Document: Sendable { let name: String; let data: Data }

    @MainActor
    init(appModel: AppModel) {
        self.api = appModel.isIsolated ? nil : appModel.api
        self.owner = appModel.accountStorage
        self.isScratch = appModel.isIsolated
        self.local = LibraryExport.makeJSON(appModel.library)
        self.preparation = AccountExportPreparation()
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { export in
            try await export.accountFile()
        }
    }

    /// Why the account's copy did not arrive, in the words a destination may show. Never a status
    /// code (board 14).
    enum Failure: LocalizedError {
        case unreachable
        case rateLimited
        /// `404 {"error":"account not found"}`: a suspended identity whose account was already
        /// erased (server §7.3 — the export only looks the account up, never re-creates it).
        case nothingToExport

        var errorDescription: String? {
            switch self {
            case .unreachable: return Copy.Account.exportFailed
            case .rateLimited: return Copy.Account.exportRateLimited
            case .nothingToExport: return Copy.Social.suspendedExportNothing
            }
        }
    }

    /// `404 account not found` — told apart from a server that has no export route (whose 404
    /// names the route), which falls back to the device's library.
    static func isAccountGone(_ error: APIError) -> Bool {
        error.status == 404 && error.socialError?.error.lowercased() == "account not found"
    }

    /// The server's export, under the server's name. Only a 404 — the route does not exist on this
    /// server — falls back to the device's library: any other failure is REPORTED, because a
    /// library-only file handed over in place of "everything in your account" would be a quieter
    /// version of the claim the row makes.
    @MainActor private func accountFile() async throws -> SentTransferredFile {
        let document = try await preparation.value(isCurrent: {
            isScratch || AccountLocalStore.shared.matches(owner)
        }) {
            guard let api else { return Document(name: "previously-library.json", data: local) }
            do {
                let file = try await api.accountExportFile()
                return Document(name: Self.fileName(suggested: file.suggestedFilename), data: file.data)
            } catch let error as APIError {
                if Self.isAccountGone(error) { throw Failure.nothingToExport }
                if error.status == 404 { return Document(name: "previously-library.json", data: local) }
                if case .rateLimited = error { throw Failure.rateLimited }
                throw Failure.unreachable
            } catch {
                throw Failure.unreachable
            }
        }
        return try write(name: document.name, data: document.data)
    }

    /// The server's file name, reduced to a bare `.json` name (it arrives from a header, so it is
    /// never trusted as a path); a dated default when the header named nothing usable.
    static func fileName(suggested: String?) -> String {
        let bare = (suggested ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        if bare.hasSuffix(".json"), bare.count > 5, bare.count <= 96,
           !bare.hasPrefix("."), bare.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return bare
        }
        let day = Date().formatted(.iso8601.year().month().day())
        return "previously-export-\(day).json"
    }

    @MainActor private func write(name: String, data: Data) throws -> SentTransferredFile {
        SentTransferredFile(try AccountExportStore.write(name: name, data: data, owner: owner, isScratch: isScratch))
    }

    /// Removes only app-managed share staging files. Copies saved by the user outside this
    /// sandbox remain theirs. Legacy staging folders had no owner and are never reused.
    @MainActor static func clearTemporaryFiles() {
        AccountExportStore.clearTemporaryFiles()
    }

    private static func makeJSON(_ library: [Franchise]) -> Data {
        struct Part: Encodable { let mediaId: Int; let label: String; let kind: String; let progress: Int; let totalEpisodes: Int }
        struct Row: Encodable { let id: String; let title: String; let source: String; let status: String; let parts: [Part] }
        let rows = library.map { f in
            Row(id: f.id, title: f.title, source: f.source.rawValue, status: f.effectiveStatus.rawValue,
                parts: f.parts.map { Part(mediaId: $0.mediaId, label: $0.canonicalLabel, kind: $0.kind.rawValue, progress: $0.progress, totalEpisodes: $0.totalEpisodes) })
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(rows)) ?? Data()
    }

    fileprivate static func makeCSV(_ library: [Franchise]) -> Data {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["title,source,status,part,kind,progress,total_episodes"]
        for f in library {
            for p in f.parts {
                lines.append([q(f.title), f.source.rawValue, f.effectiveStatus.rawValue, q(p.canonicalLabel), p.kind.rawValue, String(p.progress), String(p.totalEpisodes)].joined(separator: ","))
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}

/// CSV has its own fixed representation, so a destination cannot negotiate the account JSON
/// representation while the row and preview describe a spreadsheet.
struct LibraryCSVExport: Transferable {
    let data: Data
    let owner: AccountLocalStore.Snapshot?
    let isScratch: Bool

    @MainActor init(appModel: AppModel) {
        data = LibraryExport.makeCSV(appModel.library)
        owner = appModel.accountStorage
        isScratch = appModel.isIsolated
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            try await export.file()
        }
    }

    @MainActor private func file() throws -> SentTransferredFile {
        SentTransferredFile(try AccountExportStore.write(name: "previously-library.csv", data: data,
                                                       owner: owner, isScratch: isScratch))
    }
}
