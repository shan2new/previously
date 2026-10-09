import Foundation

// In-app account deletion — App Store guideline 5.1.1(v). `DELETE /me` on the backend erases the
// account's subscriptions, progress, notifications and the user row itself, in one transaction.
//
// It deliberately does NOT go through `APIClient`. That client is built for reads and for writes
// the app can replay: it retries transport failures and silently refreshes a 401. Both behaviours
// are wrong here. A request the app is not certain reached the server must be REPORTED, not quietly
// repeated, and a session that has expired must be re-authenticated by the user before their
// account is destroyed — not renewed behind a confirmation they gave a minute ago. One attempt,
// one answer, and the answer is shown to the user either way.
enum AccountDeletion {
    private static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
    enum Status: String, Decodable, Sendable { case active, pending, complete }
    enum AppleRevocation: String, Decodable, Sendable { case revoked, manual_required, not_applicable }
    struct Receipt: Sendable {
        let status: Status
        let appleRevocation: AppleRevocation?
    }

    @MainActor private static func holdKey(_ accountID: String?) -> String? {
        guard let accountID, !accountID.isEmpty else { return nil }
        return "previously.deletion.hold." + AccountLocalStore.ownerKey(for: accountID)
    }

    @MainActor static func hold(accountID: String?) {
        if let key = holdKey(accountID) { UserDefaults.standard.set(true, forKey: key) }
    }
    @MainActor static func clearHold(accountID: String?) {
        if let key = holdKey(accountID) { UserDefaults.standard.removeObject(forKey: key) }
    }
    @MainActor static func hasUnconfirmedRequest(accountID: String?) -> Bool {
        holdKey(accountID).map { UserDefaults.standard.bool(forKey: $0) } ?? false
    }
    @MainActor static func markAccepted(accountID: String?) {
        guard let accountID else { return }
        clearHold(accountID: accountID)
        MutationStamp.clear(accountID: accountID)
        UserDefaults.standard.set(true, forKey: "previously.deletion.accepted." + AccountLocalStore.ownerKey(for: accountID))
    }
    @MainActor static func wasAccepted(accountID: String?) -> Bool {
        guard let accountID else { return false }
        return UserDefaults.standard.bool(forKey: "previously.deletion.accepted." + AccountLocalStore.ownerKey(for: accountID))
    }

    /// Why the deletion did not happen, in the words the row prints. Never a status code: the user
    /// is being told whether their account still exists, and "500" does not answer that.
    enum Failure: LocalizedError, Equatable {
        /// There is no credential to send. The account was not touched.
        case notSignedIn
        /// The server answered, and the answer was not "deleted".
        case refused
        /// The request never got an answer. The account may or may not still exist.
        case unreachable

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "You’re signed out. Sign in again to delete your account."
            case .refused: return "The server refused this deletion request. Please try again."
            case .unreachable: return "We couldn’t confirm the deletion. Your changes are paused while we check."
            }
        }
    }

    /// Sends the deletion. Returns normally only when the server confirmed the erasure.
    ///
    /// The app uses a temporary bearer-only session; the transport remains injectable
    /// without a network; `token` is `AuthManager.currentToken`.
    @MainActor static func deleteAccount(baseURL: URL = AppConfig.apiBaseURL,
                              session: URLSession = transport,
                              apple: AppleDeletionAuthorization.Proof? = nil,
                              token: @MainActor () async -> String?) async throws -> Receipt {
        try await request(method: "DELETE", path: "me", baseURL: baseURL, session: session, apple: apple, token: token)
    }

    @MainActor static func status(baseURL: URL = AppConfig.apiBaseURL,
                       session: URLSession = transport,
                       token: @MainActor () async -> String?) async throws -> Receipt {
        try await request(method: "GET", path: "me/deletion", baseURL: baseURL, session: session, apple: nil, token: token)
    }

    @MainActor private static func request(method: String, path: String, baseURL: URL, session: URLSession,
                                apple: AppleDeletionAuthorization.Proof?,
                                token: @MainActor () async -> String?) async throws -> Receipt {
        guard let bearer = await token(), !bearer.isEmpty else { throw Failure.notSignedIn }

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apple {
            struct Body: Encodable { let apple: AppleDeletionAuthorization.Proof }
            request.httpBody = try JSONEncoder().encode(Body(apple: apple))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        switch http.statusCode {
        case 200:
            // Only a complete, defined receipt answers whether an uncertain DELETE committed.
            // A proxy's empty or unrelated success must never discard the durable write hold.
            guard let body = try? JSONDecoder().decode(Response.self, from: data) else {
                throw Failure.unreachable
            }
            if body.deleted, body.status == .complete { return Receipt(status: .complete, appleRevocation: body.appleRevocation) }
            if method == "GET", !body.deleted, body.status == .active { return Receipt(status: .active, appleRevocation: body.appleRevocation) }
            throw Failure.unreachable
        case 202:
            guard let body = try? JSONDecoder().decode(Response.self, from: data),
                  !body.deleted, body.status == .pending else { throw Failure.unreachable }
            return Receipt(status: .pending, appleRevocation: body.appleRevocation)
        case 401, 403:
            // A gateway can replace a committed response with an auth challenge. Having sent the
            // DELETE, these statuses cannot prove that it never reached the authoritative route.
            throw Failure.unreachable
        case 400, 422:
            // Only the route's defined, authenticated pre-mutation refusal is definitive.
            // A proxy HTML response or unknown route error says nothing about an earlier commit.
            struct Rejection: Decodable { let error: String }
            if method == "DELETE", let body = try? JSONDecoder().decode(Rejection.self, from: data),
               body.error == "unexpected body" { throw Failure.refused }
            throw Failure.unreachable
        default:
            throw Failure.unreachable
        }
    }

    private struct Response: Decodable { let deleted: Bool; let status: Status?; let appleRevocation: AppleRevocation? }
}
