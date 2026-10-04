import Foundation

extension Error {
    /// A request cancelled by its own task — the next keystroke, a popped screen, a superseded
    /// refresh. Surfaces as `URLError.cancelled` (wrapped by `APIClient` as `.transport`) or
    /// `CancellationError`. Never a failure to show the user.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if (self as? URLError)?.code == .cancelled { return true }
        if let api = self as? APIError, case let .transport(inner) = api,
           (inner as? URLError)?.code == .cancelled {
            return true
        }
        return false
    }
}
import os

// Supplies the current bearer token for outgoing requests. Implemented by the auth layer
// (Clerk session token, or a `dev:<clerkId>` token for local DEV_AUTH_BYPASS testing).
protocol TokenProvider: Sendable {
    func currentToken() async -> String?
    /// Whether an identity exists at all, independent of whether a token can be MINTED right now.
    /// Offline, a Clerk session still exists on this device; its ~60 s JWT does not. The two must
    /// never be confused: one is a signed-out user, the other is a user on a train.
    func hasSession() async -> Bool
    /// A FRESH token, skipping any cache.
    func refreshedToken() async -> TokenRefreshOutcome
}

/// What a forced refresh learned. `.notRefreshable` is a FINAL answer from the issuer (a `dev:`
/// token has nothing to renew; Clerk says there is no session) — a 401 against it ends the
/// session. `.failed` is a network problem, which says nothing about the credentials, so the
/// session is KEPT and the request reports `.transport`.
enum TokenRefreshOutcome: Sendable {
    case token(String)
    case notRefreshable
    case failed(Error)
}

/// What the transport layer learned about a failed request. The distinction that matters is
/// `isSessionEnding`: exactly one case ends the session, and a Cloudflare 403 is not it.
enum APIError: LocalizedError {
    case invalidURL
    /// A 401 that survived a forced token refresh. The session is gone.
    case unauthorized
    /// 403, a WAF/captive-portal HTML body at any status, or a non-JSON payload. The credentials
    /// were never the problem, so the SESSION IS KEPT and the surface shows stale / no-cache.
    case infrastructure(Int, String)
    /// 429 that outlived the retry budget — or whose wait (`Retry-After`, else the body's
    /// `retryAfter`) is longer than a retry could ever fit (iD15). Carries the UNCLAMPED seconds.
    case rateLimited(retryAfter: TimeInterval?)
    /// `403 { error: 'account_suspended' }` (server D12): a banned account. NOT session-ending — the
    /// account still signs out and still deletes itself; the model covers the app instead (iD14).
    case suspended
    case http(Int, String)
    case decoding(Error)
    case transport(Error)

    /// User-facing text, and nothing else. `APIError` is a `LocalizedError`, so this IS what
    /// `error.localizedDescription` yields — which makes it the one place a status code or a MIME
    /// type could leak into the UI (board 14 forbids both). It therefore cannot contain one: every
    /// case answers with plain language, and the technical detail lives in `diagnostic`, which only
    /// the logger reads. A surface may render this or a `Copy.Notice` string; either is safe.
    var errorDescription: String? {
        switch self {
        // Verbatim board 09. Post-A2 this reads `Copy.State.signedOut` — see the report.
        case .unauthorized: return "You\u{2019}re signed out. Sign in again to continue."
        case .invalidURL, .infrastructure, .rateLimited, .suspended, .http, .decoding, .transport:
            return failureReason
        }
    }

    /// Log-only detail: status codes, MIME types, body text. Written to the unified log by the
    /// throw sites in `send`; never rendered in any surface.
    var diagnostic: String {
        switch self {
        case .invalidURL: return "invalid-url"
        case .unauthorized: return "unauthorized"
        case let .infrastructure(code, kind): return "infrastructure status=\(code) kind=\(kind)"
        case let .rateLimited(after): return "rate-limited retryAfter=\(after.map { String(Int(min($0, RetryPolicy.maxRetryAfterRaw))) } ?? "-")"
        case .suspended: return "account-suspended"
        case let .http(code, body): return "http status=\(code) body=\(body.prefix(200))"
        case let .decoding(err): return "decoding \(err)"
        case let .transport(err): return "transport \(err)"
        }
    }

    /// The predicate callers should use to decide whether to sign the user out, once `AppModel`
    /// adopts it (SP-2). It still branches on `catch APIError.unauthorized` today, which is the
    /// same test spelled out longhand — but only this predicate survives adding a case.
    var isSessionEnding: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    /// The short, non-technical reason a Sync-status row renders. Never a status code (board 14).
    var failureReason: String {
        switch self {
        case .unauthorized: return "Signed out"
        case .rateLimited: return "Rate limited"
        case .suspended: return Copy.Notice.suspended
        case let .transport(err):
            switch (err as? URLError)?.code {
            case .timedOut: return "Timed out"
            default: return "No connection"
            }
        case .infrastructure, .http, .decoding, .invalidURL: return "Server error"
        }
    }
}

extension APIError {
    /// The HTTP status of a final non-2xx answer the transport passed through (`.http`); nil for
    /// every other case. 404/409/410/422 arrive here — they are final and never retried.
    var status: Int? {
        if case let .http(code, _) = self { return code }
        return nil
    }

    /// The social routes' machine-readable error body (`{ error, reason?, retryAfter?,
    /// currentVersion? }`, server §3.4) of an `.http` answer; nil when the body is not one.
    var socialError: SocialError? {
        guard case let .http(_, body) = self, let data = body.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(SocialError.self, from: data)
    }
}

/// The search route's full response: results plus the two honesty fields board 07 needs.
struct SearchResponse: Sendable {
    let franchises: [FranchiseSummary]
    /// The query the server actually searched, when it silently corrected ours.
    let correctedQuery: String?
    /// What we typed, echoed back — the "Search instead for X" half of board 07's correction line.
    let originalQuery: String?
    /// Per-catalogue outcome — `ok` / `failed` / `disabled`. A catalogue that FAILED is not a
    /// catalogue with no matches.
    let sources: [String: String]?
}

extension CharacterSet {
    /// Characters safe inside a single query VALUE. Starts from `.urlQueryAllowed` and removes
    /// the delimiters it permits (`&` splits parameters, `=` splits key/value, `+` decodes as a
    /// space on the server, `?`/`#` end the component).
    static let strictQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}

/// Coalesces concurrent token refreshes into ONE network call, and reuses its result for a short
/// window afterwards so a burst of 401s (six parallel requests on a cold launch) cannot become a
/// refresh storm.
actor TokenRefresher {
    /// Long enough to cover one screen's fan-out, short enough that a genuinely new 401 refetches.
    private static let reuseWindow: TimeInterval = 3

    /// Same subsystem/category as `APIClient.log`, so `auth.refresh` lines interleave with the
    /// request lines in one `log stream --predicate 'subsystem == "com.cognipin.previously"'`.
    private static let log = Logger(subsystem: "com.cognipin.previously", category: "api")

    private var inFlight: Task<TokenRefreshOutcome, Never>?
    private var lastToken: String?
    private var lastAt: Date?

    /// The `auth.refresh` log lines live HERE, inside the actor, not at the call site: one
    /// `begin`/`end` pair is emitted per actual refresh, so a burst of six concurrent 401s prints
    /// one pair plus five `coalesced`/`reused` lines. Logging at the call site would print six of
    /// each and make single-flight unverifiable from `log stream`.
    func token(from provider: TokenProvider) async -> TokenRefreshOutcome {
        if let lastAt, let lastToken, Date().timeIntervalSince(lastAt) < TokenRefresher.reuseWindow {
            TokenRefresher.log.error("auth.refresh reused")
            return .token(lastToken)
        }
        if let inFlight {
            TokenRefresher.log.error("auth.refresh coalesced")
            return await inFlight.value
        }
        TokenRefresher.log.error("auth.refresh begin")
        let task = Task { await provider.refreshedToken() }
        inFlight = task
        let value = await task.value
        inFlight = nil
        switch value {
        case .token: TokenRefresher.log.error("auth.refresh end(changed:true)")
        // The issuer had nothing to renew — a `dev:` token, or no Clerk session. NOT a network call.
        case .notRefreshable: TokenRefresher.log.error("auth.refresh end(changed:false, notRefreshable)")
        case .failed: TokenRefresher.log.error("auth.refresh end(changed:false, unreachable)")
        }
        // ONLY a success primes the reuse window. Caching a refresh that failed because Clerk was
        // unreachable would replay that failure to every 401 for the next 3 s, turning one network
        // blip into a session-wide teardown.
        if case let .token(fresh) = value {
            lastToken = fresh
            lastAt = Date()
        }
        return value
    }
}

/// Bounded, jittered backoff. Two retries add at most ~1.6 s to a failing request, so a skeleton
/// can never hang on a flaky upstream — and a request that will fail, fails inside the 15 s budget.
enum RetryPolicy {
    static let maxRetries = 2
    private static let base: [TimeInterval] = [0.4, 1.2]

    /// The whole LOGICAL request's wall-clock budget: one full 15 s attempt plus at most ~1.6 s of
    /// backoff. Every attempt and every sleep is spent from this one budget, because a per-attempt
    /// timeout stacks — three fresh 15 s attempts against a black hole is 45 s of skeleton.
    static let budget: TimeInterval = 16.6
    /// A retry is only worth starting if this much of the budget survives the backoff sleep;
    /// it is also the floor on any single attempt's timeout.
    static let minAttempt: TimeInterval = 2

    /// Whether another attempt fits: retries left, AND enough budget after the sleep to make one.
    static func canRetry(attempt: Int, delay: TimeInterval, deadline: Date) -> Bool {
        attempt < maxRetries && deadline.timeIntervalSinceNow - delay >= minAttempt
    }

    /// `attempt` is 1-based (the delay BEFORE retry #1). ±20 % jitter de-synchronises a fan-out.
    static func delay(attempt: Int) -> TimeInterval {
        let d = base[min(max(attempt, 1), base.count) - 1]
        return d * Double.random(in: 0.8...1.2)
    }

    /// The longest wait a retry will sleep. A 429 asking for more is not retried at all (iD15): no
    /// retry after it could land inside the request's budget.
    static let maxRetryAfter: TimeInterval = 8

    /// `Retry-After` in seconds or as an HTTP-date, clamped so a hostile header cannot stall the UI.
    static func retryAfter(_ header: String?) -> TimeInterval? {
        retryAfterRaw(header).map { min($0, maxRetryAfter) }
    }

    /// A sanity ceiling on a REPORTED wait (a day), so a hostile header can never overflow an
    /// integer conversion downstream. Not a retry clamp: anything above `maxRetryAfter` is not retried.
    static let maxRetryAfterRaw: TimeInterval = 86_400

    /// `Retry-After` UNCLAMPED to the retry ceiling (never negative, at most a day): what the server
    /// actually asked for, so a caller can tell "wait 3 s" (retry) from "wait 10 minutes" (give up and
    /// say so).
    static func retryAfterRaw(_ header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) {
            return seconds.isFinite ? min(max(seconds, 0), maxRetryAfterRaw) : nil
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = fmt.date(from: header) else { return nil }
        return min(max(date.timeIntervalSinceNow, 0), maxRetryAfterRaw)
    }
}

// URLSession-backed client implementing every endpoint in the API contract.
final class APIClient: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: TokenProvider
    private let refresher = TokenRefresher()
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Told about a `403 account_suspended` from ANY route, before the error is thrown — so the
    /// model raises its suspension from one place (not only the feed and social calls) and a
    /// caller's `catch` already sees it: a library reload, a progress lane or a SyncCenter replay
    /// never files "Account suspended" as a failure that retries forever. Installed once by
    /// `AppModel.start()`.
    var onSuspended: (@MainActor @Sendable () -> Void)?

    /// While set, every request refuses before it is sent — a `CancellationError`, which every
    /// caller already treats as "not a failure" (no Sync status row, no error surface). Raised by
    /// `AppModel.prepareForErasure()` for the seconds an account deletion takes, so nothing the app
    /// asks for in that window can re-create the erased account's rows (the server's `authenticate`
    /// upserts a user for any valid JWT); lowered by `abortErasure()` and by the next `start()`.
    /// `AccountDeletion` does not use this client, so the DELETE itself is never refused.
    var halted = false

    /// The longest any single attempt may wait. `send` clamps each attempt to whatever is left of
    /// the whole-request budget, so this is a ceiling, never an addend.
    static let requestTimeout: TimeInterval = 15

    /// Owned, not `.shared`: the default 60 s request timeout means a black-holed upstream leaves a
    /// skeleton on screen for a minute. 15 s bounds the failure; the frame moves on.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = APIClient.requestTimeout
        // Resource cap = the logical budget + 1 s. `timeoutIntervalForRequest` is an INTER-PACKET
        // timeout: an upstream that trickles one byte every 14 s never trips it, so this is the
        // only true wall-clock ceiling, and it must not outlive `RetryPolicy.budget`.
        config.timeoutIntervalForResource = RetryPolicy.budget + 1
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }

    init(baseURL: URL = AppConfig.apiBaseURL,
         tokenProvider: TokenProvider,
         session: URLSession? = nil) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session ?? APIClient.makeSession()
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Endpoints
    //
    // Every call states its own retryability. It is a required argument, not a default, because
    // exactly one endpoint in this app is unsafe to replay (`/me/opened`) and the next endpoint
    // someone adds must make that decision consciously.

    func health() async throws -> OKResponse {
        try await request("/health", auth: false, idempotent: true)
    }

    func trending(limit: Int = 30) async throws -> [FranchiseSummary] {
        let res: FranchiseListResponse = try await request("/franchises/trending?limit=\(limit)", idempotent: true)
        return res.franchises
    }

    /// First run's picker: the catalogue's best-known shows for the viewer's audience
    /// (`GET /franchises/starter`). A server that predates the route answers 404 — the caller
    /// falls back to the chart.
    func starter(limit: Int = 60) async throws -> [FranchiseSummary] {
        let res: FranchiseListResponse = try await request("/franchises/starter?limit=\(limit)", idempotent: true)
        return res.franchises
    }

    /// What is airing now, by the chart (`status=RELEASING`), for the viewer's audience.
    func airingNow(limit: Int = 60) async throws -> [FranchiseSummary] {
        let res: FranchiseListResponse = try await request("/franchises/trending?limit=\(limit)&status=RELEASING",
                                                           idempotent: true)
        return res.franchises
    }

    // MARK: History import (`Features/Import`)

    /// What an import WOULD add — nothing is written (`POST /me/import/preview`). Not retried by
    /// the transport: each call reads an upstream list, and the server rations them.
    func importPreview(_ request: ImportRequest) async throws -> ImportPreview {
        struct Job: Decodable {
            let id: String
            let state: String
            let preview: ImportPreview?
            let error: String?
        }
        var job: Job = try await self.request("/me/import/preview?async=1", method: "POST", body: request, idempotent: false)
        // Each request retains the normal transport budget. Reading a large export can take
        // minutes without a held connection, and cancelling the sheet cancels this loop.
        while job.state == "reading" {
            try await Task.sleep(for: .seconds(2))
            job = try await self.request("/me/import/\(Self.segment(job.id))/preview", idempotent: true)
        }
        if let preview = job.preview { return preview }
        throw APIError.http(422, job.error ?? "import_unavailable")
    }

    /// Write a previewed import. Applying twice is a no-op the second time, so a replay is safe.
    func importApply(id: String) async throws -> ImportProgress {
        try await request("/me/import/\(Self.segment(id))/apply", method: "POST", idempotent: true)
    }

    /// How far an applied import's background part has got. 410 once the server has forgotten it.
    func importProgress(id: String) async throws -> ImportProgress {
        try await request("/me/import/\(Self.segment(id))", idempotent: true)
    }

    /// The full search response, including what the server corrected and which catalogue failed.
    /// `exact` opts out of the server's spell-correction.
    func search(query: String, exact: Bool = false) async throws -> SearchResponse {
        // .urlQueryAllowed leaves `&`, `+`, and `=` unescaped, which corrupts the q parameter
        // (searching "X & Y" truncated at the ampersand). Escape the value strictly.
        let q = query.addingPercentEncoding(withAllowedCharacters: .strictQueryValueAllowed) ?? ""
        let res: SearchEnvelope = try await request("/search?q=\(q)" + (exact ? "&exact=1" : ""), idempotent: true)
        return SearchResponse(franchises: res.franchises,
                              correctedQuery: res.correctedQuery,
                              originalQuery: res.originalQuery ?? query,
                              sources: res.sources)
    }

    /// Results-only convenience for callers that do not render the honesty fields.
    ///
    /// A bare `search(query:)` resolves to THIS overload (Swift prefers the candidate that needs no
    /// defaulted arguments). To get the full `SearchResponse`, pass `exact:` explicitly or annotate
    /// the result — `let res: SearchResponse = try await api.search(query: q, exact: false)`.
    func search(query: String) async throws -> [FranchiseSummary] {
        try await search(query: query, exact: false).franchises
    }

    /// `country` (ISO 3166-1 alpha-2) selects `audience.contentRating` for the viewer's market;
    /// the server never substitutes another market's rating, so a miss is `nil`, not "US".
    func franchise(id: String, country: String? = nil) async throws -> Franchise {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let query = country.map { "?country=\($0)" } ?? ""
        return try await request("/franchises/\(encoded)\(query)", idempotent: true)
    }

    /// Country-specific streaming availability, read apart from the franchise so a cold provider
    /// lookup never delays the show page (docs/api-contract.md, WatchAvailability).
    func watchProviders(id: String, country: String) async throws -> WatchAvailability {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await request("/franchises/\(encoded)/watch-providers?country=\(country)", idempotent: true)
    }

    func library() async throws -> LibraryResponse {
        try await request("/me/library", idempotent: true)
    }

    /// "Recommended for you" — server-ranked, second-degree (docs/api-contract.md). An older
    /// server answers 404; the caller hides the shelf.
    // MARK: Audience (`GET` / `PUT /me/preferences`, `audience`)

    /// The account's audience; nil when it has never answered (or the server predates the field).
    func audience() async throws -> Audience? {
        struct Preferences: Decodable { let audience: String? }
        let res: Preferences = try await request("/me/preferences", idempotent: true)
        return res.audience.flatMap(Audience.init(rawValue:))
    }

    /// Sets the account's audience. The other preferences are left as they are.
    func saveAudience(_ value: Audience) async throws {
        struct Body: Encodable { let audience: String }
        struct Saved: Decodable { let audience: String? }
        let saved: Saved = try await request("/me/preferences", method: "PUT",
                                             body: Body(audience: value.rawValue), idempotent: true)
        // A server that does not keep the field yet answers without it: the choice stays owed.
        guard saved.audience == value.rawValue else { throw APIError.infrastructure(503, "audience not saved") }
    }

    func recommendations(limit: Int = 12) async throws -> RecommendationsResponse {
        try await request("/me/recommendations?limit=\(limit)", idempotent: true)
    }

    /// "Not interested" / "Already seen" on a recommendation (a server-side upsert).
    func recommendationFeedback(key: String, kind: String) async throws {
        let _: NoContent = try await request("/me/recommendations/feedback", method: "POST",
                                             body: RecommendationFeedbackBody(key: key, kind: kind),
                                             idempotent: true)
    }

    /// Takes a "Not interested" / "Already seen" back (the receipt's Undo).
    func removeRecommendationFeedback(key: String) async throws {
        let _: NoContent = try await request("/me/recommendations/feedback", method: "DELETE",
                                             body: RecommendationFeedbackBody(key: key, kind: nil),
                                             idempotent: true)
    }

    /// The account's watch sessions (first watches and rewatches), deleted ones excluded.
    func watchSessions() async throws -> [WatchSessionWire] {
        let res: WatchSessionsResponse = try await request("/me/watch-sessions", idempotent: true)
        return res.sessions
    }

    /// Creates or replaces one session, whole. 410 = deleted on another device; 404 = its
    /// franchise is gone. Both are final.
    func putWatchSession(id: UUID, _ body: WatchSessionBody) async throws {
        let _: NoContent = try await request("/me/watch-sessions/\(id.uuidString.lowercased())", method: "PUT",
                                             body: body, idempotent: true)
    }

    func deleteWatchSession(id: UUID) async throws {
        let _: NoContent = try await request("/me/watch-sessions/\(id.uuidString.lowercased())", method: "DELETE",
                                             idempotent: true)
    }

    /// A catalogue title with no local franchise yet, materialised (or found) by the server —
    /// the franchise a recommendation's tap opens.
    func resolveFranchise(source: MediaSource, externalId: Int) async throws -> FranchiseSummary {
        try await request("/franchises/resolve", method: "POST",
                          body: ResolveBody(source: source.rawValue, externalId: externalId),
                          idempotent: true)
    }

    @discardableResult
    func subscribe(franchiseId: String, status: WatchStatus? = nil) async throws -> OKResponse {
        // A server-side upsert: replaying it lands on the same row with the same status.
        try await request("/me/subscriptions", method: "POST",
                          body: SubscribeBody(franchiseId: franchiseId, status: status),
                          idempotent: true)
    }

    @discardableResult
    func setStatus(franchiseId: String, status: WatchStatus) async throws -> OKResponse {
        let encoded = franchiseId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? franchiseId
        return try await request("/me/subscriptions/\(encoded)", method: "PATCH",
                                 body: StatusBody(status: status), idempotent: true)
    }

    @discardableResult
    func unsubscribe(franchiseId: String) async throws -> OKResponse {
        let encoded = franchiseId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? franchiseId
        return try await request("/me/subscriptions/\(encoded)", method: "DELETE", idempotent: true)
    }

    @discardableResult
    func setProgress(mediaId: Int, episodes: Int) async throws -> OKResponse {
        // Absolute value, not a delta — replaying it is a no-op.
        try await request("/me/progress", method: "PUT",
                          body: ProgressBody(mediaId: mediaId, episodes: episodes), idempotent: true)
    }

    func setFranchiseProgress(franchiseId: String, parts: [FranchiseProgressValue],
                              status: WatchStatus?) async throws -> FranchiseProgressResponse {
        let encoded = franchiseId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? franchiseId
        return try await request("/me/franchises/\(encoded)/progress", method: "PUT",
                                 body: FranchiseProgressBody(parts: parts, status: status), idempotent: true)
    }

    @discardableResult
    func markOpened() async throws -> OpenedResponse {
        // NOT retryable: it stamps `lastOpenedAt` and returns the PREVIOUS value. A replay would
        // return "now" and destroy "since you were last here" — the recap's whole premise.
        try await request("/me/opened", method: "POST", idempotent: false)
    }

    // MARK: - Feed (server §2.8)
    //
    // Path ids are OPAQUE (a PostId carries colons) and percent-encoded as one path segment; query
    // values go through `.strictQueryValueAllowed`. Toggles below are absolute set-state (PUT = on,
    // DELETE = off), so replaying any of them is a no-op.

    /// `since` is this session's visit anchor (the `prevOpenedAt` its own `POST /me/opened`
    /// answered). When sent, the server orders and marks `fresh` against it and echoes it as the
    /// response's `prevOpenedAt`; when nil (or not positive) the key is omitted and the server
    /// reads its stored anchor.
    ///
    /// `episodes=1` on Following asks for the "Episode N is out" posts (4 Oct): the server sends
    /// them only to a build that says it can draw them — an older one reads an unknown kind as an
    /// announcement.
    func feed(tab: FeedTab, since: Int64? = nil) async throws -> FeedResponse {
        var path = "/me/feed?tab=\(tab.rawValue)"
        if tab == .following { path += "&episodes=1" }
        if let since, since > 0 { path += "&since=\(since)" }
        return try await request(path, idempotent: true)
    }

    /// A post page. `post.id` in the answer is CANONICAL (an adopted `catalog:` id answers as its
    /// `news:` post) — the thread subject.
    func feedPost(id: String) async throws -> FeedPostDetail {
        try await request("/feed/posts/\(Self.segment(id))", idempotent: true)
    }

    func saved() async throws -> SavedResponse {
        try await request("/me/saved", idempotent: true)
    }

    func reminders() async throws -> RemindersResponse {
        try await request("/me/reminders", idempotent: true)
    }

    // MARK: - Social toggles (server §3.2)

    func setLike(subject: String, on: Bool) async throws {
        let _: NoContent = try await request("/me/likes", method: on ? "PUT" : "DELETE",
                                             body: SubjectBody(subject: subject), idempotent: true)
    }

    func setSave(postId: String, on: Bool) async throws {
        let _: NoContent = try await request("/me/saves", method: on ? "PUT" : "DELETE",
                                             body: PostIdBody(postId: postId), idempotent: true)
    }

    func setReminder(postId: String, on: Bool) async throws {
        let _: NoContent = try await request("/me/reminders", method: on ? "PUT" : "DELETE",
                                             body: PostIdBody(postId: postId), idempotent: true)
    }

    /// `.post` hides one post (target a PostId); `.show` mutes a show (target its franchise id).
    func setHide(kind: FeedHide.Kind, target: String, on: Bool) async throws {
        // `.unknown` is a DECODED value (a hide this build cannot read); it is never written.
        guard kind != .unknown else { throw APIError.invalidURL }
        let _: NoContent = try await request("/me/hides", method: on ? "PUT" : "DELETE",
                                             body: HideBody(kind: kind.rawValue, target: target), idempotent: true)
    }

    func hides() async throws -> HidesResponse {
        try await request("/me/hides", idempotent: true)
    }

    /// `score` 0…100 sets the rating; nil clears it.
    func setRating(mediaId: Int, episode: Int, score: Int?) async throws {
        if let score {
            let _: NoContent = try await request("/me/ratings", method: "PUT",
                                                 body: RatingBody(mediaId: mediaId, episode: episode,
                                                                  score: min(100, max(0, score))),
                                                 idempotent: true)
        } else {
            let _: NoContent = try await request("/me/ratings", method: "DELETE",
                                                 body: RatingKeyBody(mediaId: mediaId, episode: episode),
                                                 idempotent: true)
        }
    }

    func setBlock(userId: String, on: Bool) async throws {
        let _: NoContent = try await request("/me/blocks", method: on ? "PUT" : "DELETE",
                                             body: BlockBody(userId: userId), idempotent: true)
    }

    func blocks() async throws -> BlockedUsersResponse {
        try await request("/me/blocks", idempotent: true)
    }

    // MARK: - Comments (server §3.2, §3.5)

    /// One page of a thread. `cursor` is OPAQUE and passed back verbatim.
    func comments(subject: String, sort: CommentSort, cursor: String?, limit: Int = 20) async throws -> CommentsPage {
        var path = "/social/comments?subject=\(Self.queryValue(subject))&sort=\(sort.rawValue)"
            + "&limit=\(min(50, max(1, limit)))"
        if let cursor, !cursor.isEmpty { path += "&cursor=\(Self.queryValue(cursor))" }
        return try await request(path, idempotent: true)
    }

    /// Replay-safe: the body carries the client's uuid, which the server upserts on (201 new, 200 a
    /// replay of the same comment), so a retry can never double-post.
    func postComment(_ body: CommentBody) async throws -> CommentResponse {
        try await request("/social/comments", method: "POST", body: body, idempotent: true)
    }

    func deleteComment(id: String) async throws {
        let _: NoContent = try await request("/social/comments/\(Self.segment(id))", method: "DELETE", idempotent: true)
    }

    func setCommentLike(id: String, on: Bool) async throws {
        let _: NoContent = try await request("/social/comments/\(Self.segment(id))/like",
                                             method: on ? "PUT" : "DELETE", idempotent: true)
    }

    /// Unique per reporter: a repeat is a 204 that changes nothing.
    func reportComment(id: String, reason: ReportReason, note: String?) async throws {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let _: NoContent = try await request("/social/comments/\(Self.segment(id))/report", method: "POST",
                                             body: ReportBody(reason: reason.rawValue,
                                                              note: (trimmed?.isEmpty ?? true) ? nil : trimmed),
                                             idempotent: true)
    }

    func episodeRoom(mediaId: Int, episode: Int) async throws -> EpisodeRoom {
        try await request("/social/episodes/\(mediaId)/\(episode)", idempotent: true)
    }

    // MARK: - Identity and rules (server §3.2, §4.3)

    func socialProfile() async throws -> SocialProfile {
        try await request("/me/profile", idempotent: true)
    }

    func saveSocialProfile(handle: String, displayName: String) async throws -> SocialProfile {
        try await request("/me/profile", method: "PUT",
                          body: ProfileBody(handle: handle, displayName: displayName), idempotent: true)
    }

    func handleAvailability(_ handle: String) async throws -> HandleAvailability {
        try await request("/me/profile/handle?handle=\(Self.queryValue(handle))", idempotent: true)
    }

    /// An upsert: repeating it re-stamps the time and lands on the same row.
    func acceptTerms(version: String) async throws -> SocialProfile {
        try await request("/me/terms", method: "POST", body: TermsBody(version: version), idempotent: true)
    }

    // MARK: - Activity (server §5.2)

    func notifications(limit: Int = 50, cursor: String?) async throws -> NotificationsPage {
        var path = "/me/notifications?limit=\(min(200, max(1, limit)))"
        if let cursor, !cursor.isEmpty { path += "&cursor=\(Self.queryValue(cursor))" }
        return try await request(path, idempotent: true)
    }

    /// `ids: nil` marks everything read.
    func markNotificationsRead(ids: [String]?) async throws {
        let _: IgnoredResponse = try await request("/me/notifications/read", method: "POST",
                                                   body: NotificationsReadBody(ids: ids), idempotent: true)
    }

    // MARK: - Account (server §7.3)

    /// The account's data as the server exports it: raw JSON bytes, shared as a file. Works while
    /// the account is suspended (server D12).
    func accountExport() async throws -> Data {
        try await accountExportFile().data
    }

    /// `accountExport()` with the file name the server suggests
    /// (`Content-Disposition: attachment; filename="previously-export-<YYYY-MM-DD>.json"`).
    func accountExportFile() async throws -> (data: Data, suggestedFilename: String?) {
        let (data, response) = try await requestData("/me/export", idempotent: true)
        let name = response.value(forHTTPHeaderField: "Content-Disposition") != nil ? response.suggestedFilename : nil
        return (data, name)
    }

    // MARK: - Discover genres (server §10.2)

    /// `source: nil` is All.
    func discoverGenres(source: MediaSource?) async throws -> DiscoverGenresResponse {
        try await request("/discover/genres" + (source.map { "?source=\($0.rawValue)" } ?? ""), idempotent: true)
    }

    func discoverGenre(key: String, source: MediaSource?, cursor: String?, limit: Int = 24) async throws -> DiscoverGenrePage {
        var path = "/discover/genres/\(Self.segment(key))?limit=\(min(50, max(1, limit)))"
        if let source { path += "&source=\(source.rawValue)" }
        if let cursor, !cursor.isEmpty { path += "&cursor=\(Self.queryValue(cursor))" }
        return try await request(path, idempotent: true)
    }

    // MARK: - Encoding

    /// Characters safe inside ONE path segment: `.urlPathAllowed` without the `/` that would split it.
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()

    /// An opaque id as one path segment (a PostId's `:` is legal there, and encoded anyway for safety).
    private static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? id
    }

    /// A query VALUE, strictly escaped (`&`, `=`, `+`, `?`, `#` would corrupt the query).
    private static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .strictQueryValueAllowed) ?? ""
    }

    // MARK: - Core request machinery

    /// Decoded shape of `/search`. Mirrors the server's `FranchiseListResponse`; every honesty
    /// field is optional so an older server still decodes.
    private struct SearchEnvelope: Decodable {
        let franchises: [FranchiseSummary]
        let correctedQuery: String?
        let originalQuery: String?
        let sources: [String: String]?
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        auth: Bool = true,
        idempotent: Bool
    ) async throws -> Response {
        try await send(path: path, method: method, body: nil, auth: auth, idempotent: idempotent)
    }

    private func request<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body,
        auth: Bool = true,
        idempotent: Bool
    ) async throws -> Response {
        let data: Data
        do { data = try encoder.encode(body) }
        catch { throw APIError.decoding(error) }
        return try await send(path: path, method: method, body: data, auth: auth, idempotent: idempotent)
    }

    // Failure diagnostics land in the unified log (`log stream --predicate 'subsystem ==
    // "com.cognipin.previously"'`) so "the app says unreachable" is attributable to a concrete cause —
    // and so single-flight refresh and retry are verifiable without a UI.
    private static let log = Logger(subsystem: "com.cognipin.previously", category: "api")

    /// A request decoded as `Response`: `sendRaw`'s state machine, then the body. An empty 2xx is a
    /// `NoContent` (or an `IgnoredResponse`) for the callers that expect no body.
    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: Data?,
        auth: Bool,
        idempotent: Bool
    ) async throws -> Response {
        let (data, _) = try await sendRaw(path: path, method: method, body: body, auth: auth, idempotent: idempotent)

        // A 204 (or any empty success) for a caller that expects no body — or ignores the one it gets.
        if data.isEmpty {
            if let empty = NoContent() as? Response { return empty }
            if let ignored = IgnoredResponse() as? Response { return ignored }
        }
        do {
            #if DEBUG
            let data = DemoLibrary.rewriteIfNeeded(path: path, data: data)
            #endif
            return try decoder.decode(Response.self, from: data)
        } catch {
            APIClient.log.error("\(method) \(path): decoding failed: \(error)")
            throw APIError.decoding(error)
        }
    }

    /// The raw-bytes variant of `send` (the account export): the same state machine, the body
    /// undecoded, and the response for its headers.
    private func requestData(_ path: String, idempotent: Bool) async throws -> (Data, HTTPURLResponse) {
        try await sendRaw(path: path, method: "GET", body: nil, auth: true, idempotent: idempotent)
    }

    /// The whole transport state machine, behind `send` and `requestData`: every attempt, retry and
    /// classification, ending in a 2xx body (and its response, for the headers) or a thrown
    /// `APIError`. Decoding is the caller's.
    ///
    /// Exactly one RESPONSE path throws `.unauthorized` — a 401 that survived a forced refresh,
    /// on a request that CARRIED a credential and came back with a non-HTML body. An HTML body
    /// outranks the status: a 401 from nginx `auth_basic`, a Cloudflare Access challenge or a
    /// captive portal is `.infrastructure(401, "html")` with the session kept, because "any status
    /// + HTML" is infrastructure. The only other `.unauthorized` site is the pre-flight guard
    /// below, and it fires only when there is no SESSION: a token we merely failed to FETCH
    /// (offline, expired JWT, unreachable issuer) is `.transport` and keeps the session.
    /// **403 is on neither.**
    ///
    /// The whole logical request — every attempt plus every backoff sleep — is bounded by one
    /// wall-clock budget, and each attempt's own timeout is clamped to what is left of it. A
    /// request that will fail, fails inside ~16.6 s however many attempts it made.
    private func sendRaw(
        path: String,
        method: String,
        body: Data?,
        auth: Bool,
        idempotent: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.invalidURL }

        let deadline = Date().addingTimeInterval(RetryPolicy.budget)
        var attempt = 0            // retries consumed
        var refreshed = false      // the one forced token refresh this request is allowed
        var forcedToken: String?   // set by that refresh, so the retry does not re-read the cache

        while true {
            // Checked per attempt, so a retry already in its backoff stops too.
            if halted { throw CancellationError() }
            var req = URLRequest(url: url)
            req.httpMethod = method
            // Spend from the shared budget, never restart it: a retry after a 15 s timeout gets
            // only the seconds that are left, so attempts cannot stack up behind a skeleton.
            req.timeoutInterval = min(APIClient.requestTimeout,
                                      max(RetryPolicy.minAttempt, deadline.timeIntervalSinceNow))
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            var sentToken: String?
            if auth {
                let resolved: String?
                if let forcedToken { resolved = forcedToken } else { resolved = await tokenProvider.currentToken() }
                guard let token = resolved else {
                    // No token, for one of two very different reasons — and only one of them ends
                    // a session. Either there is no identity at all (signed out), or there IS one
                    // and we could not mint a token right now: a cold launch in airplane mode,
                    // where Clerk's ~60 s JWT has expired and nothing can renew it. Signing a user
                    // out for being offline is the same failure class as the 2026-08-22 regression.
                    if await tokenProvider.hasSession() {
                        APIClient.log.error("\(method) \(path): token unavailable while signed in — transport, session kept")
                        throw APIError.transport(URLError(.notConnectedToInternet))
                    }
                    APIClient.log.error("\(method) \(path): no session — unauthorized")
                    throw APIError.unauthorized
                }
                sentToken = token
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                // A request cancelled by the next keystroke is superseded, never retried.
                if (error as? URLError)?.code == .cancelled { throw APIError.transport(error) }
                let delay = RetryPolicy.delay(attempt: attempt + 1)
                if idempotent, RetryPolicy.canRetry(attempt: attempt, delay: delay, deadline: deadline) {
                    attempt += 1
                    APIClient.log.error("retry scheduled \(method, privacy: .public) \(path, privacy: .public) attempt=\(attempt) delay=\(delay, format: .fixed(precision: 2)) status=0")
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                APIClient.log.error("\(method) \(url.absoluteString): transport error: \(error)")
                throw APIError.transport(error)
            }

            guard let http = response as? HTTPURLResponse else {
                let e = APIError.infrastructure(-1, "no-http-response")
                APIClient.log.error("\(method) \(path): \(e.diagnostic, privacy: .public)")
                throw e
            }
            let status = http.statusCode
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

            // 1 — 401: refresh ONCE, then retry immediately. The retry does not consume the
            // backoff budget: a stale token is not a flaky network. This is the ONLY branch in the
            // client that ends a session, so it is guarded on the two facts that make a 401 mean
            // "your credential is dead":
            //   * `auth` — we actually SENT a credential. A 401 on an unauthenticated probe
            //     (`health()`) is the server's business, never a reason to sign anyone out.
            //   * not HTML — a real expired session from Fastify is `401 {"error":"invalid token"}`
            //     in `application/json`. An HTML 401 is nginx `auth_basic`, a Cloudflare Access
            //     challenge, or a captive portal; it falls through to branch 4 and becomes
            //     `.infrastructure(401, "html")` with the session KEPT.
            if status == 401, auth, !isHTML(data: data, contentType: contentType) {
                if !refreshed {
                    refreshed = true
                    let outcome = await refresher.token(from: tokenProvider)
                    switch outcome {
                    case let .token(fresh) where fresh != sentToken:
                        forcedToken = fresh
                        continue
                    case let .failed(err):
                        // We never learned whether the credentials are dead — we only learned that
                        // the issuer is unreachable. That is a network fact, not a session fact.
                        APIClient.log.error("\(method) \(path): auth.refresh unreachable — transport, session kept")
                        throw APIError.transport(err)
                    case .token, .notRefreshable:
                        // The issuer answered, and the answer was final: the same token back, or
                        // an issuer with nothing to renew (`dev:`, or no Clerk session).
                        break
                    }
                }
                APIClient.log.error("unauthorized after refresh")
                throw APIError.unauthorized
            }

            // 2 — 403 is INFRASTRUCTURE, never a sign-out. A Cloudflare WAF challenge says nothing
            // about the user's session; signing them out on it is the 2026-08-22 regression.
            // The one app-level 403 is the server's own JSON `{ error: 'account_suspended' }` (server
            // D12; every other app refusal is 409/410/422, D13): `.suspended`, still NOT a sign-out.
            if status == 403 {
                if contentType.contains("json"),
                   let refusal = try? JSONDecoder().decode(SocialError.self, from: data),
                   refusal.code == .accountSuspended {
                    APIClient.log.error("\(method) \(path): \(APIError.suspended.diagnostic, privacy: .public)")
                    if let onSuspended { await onSuspended() }
                    throw APIError.suspended
                }
                let e = APIError.infrastructure(403, contentType.isEmpty ? "forbidden" : contentType)
                APIClient.log.error("\(method) \(path): \(e.diagnostic, privacy: .public)")
                throw e
            }

            // 3 — 429 and 5xx are worth one or two more attempts. This runs BEFORE the HTML test
            // because the ordinary production 502/503 arrives with an HTML error page from nginx or
            // Cloudflare; classifying on the body first would spend the retry budget on nothing.
            if status == 429 || (500...504).contains(status) {
                // A 429's wait, UNCLAMPED: the header, else the body's `retryAfter` (server §3.4).
                var requested: TimeInterval?
                if status == 429 {
                    requested = RetryPolicy.retryAfterRaw(http.value(forHTTPHeaderField: "Retry-After"))
                    if requested == nil, let seconds = (try? JSONDecoder().decode(SocialError.self, from: data))?.retryAfter {
                        requested = TimeInterval(seconds)
                    }
                }
                // A wait longer than any retry could fit is not retried (iD15): say so at once.
                if status == 429, let requested, requested > RetryPolicy.maxRetryAfter {
                    let e = APIError.rateLimited(retryAfter: requested)
                    APIClient.log.error("\(method) \(path): \(e.diagnostic, privacy: .public) — not retried")
                    throw e
                }
                let delay = requested ?? RetryPolicy.delay(attempt: attempt + 1)
                if idempotent, RetryPolicy.canRetry(attempt: attempt, delay: delay, deadline: deadline) {
                    attempt += 1
                    APIClient.log.error("retry scheduled \(method, privacy: .public) \(path, privacy: .public) attempt=\(attempt) delay=\(delay, format: .fixed(precision: 2)) status=\(status)")
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                if status == 429 { throw APIError.rateLimited(retryAfter: requested) }
                // An exhausted 5xx falls through: if its body is HTML it is infrastructure (below),
                // otherwise it is a server error we can report.
            }

            // 4 — an HTML body at ANY status (captive portal, WAF interstitial, a 200 sign-in page,
            // a CDN's 503 page) is an infrastructure failure, not a decode failure.
            if isHTML(data: data, contentType: contentType) {
                let e = APIError.infrastructure(status, "html")
                APIClient.log.error("\(method) \(path): \(e.diagnostic, privacy: .public) contentType=\(contentType.isEmpty ? "sniffed" : contentType, privacy: .public)")
                throw e
            }

            guard (200..<300).contains(status) else {
                let e = APIError.http(status, String(data: data, encoding: .utf8) ?? "")
                APIClient.log.error("\(method) \(path): \(e.diagnostic, privacy: .public)")
                throw e
            }

            return (data, http)
        }
    }

    /// HTML by declared type, or by the first non-whitespace byte. Cheap, and it catches the
    /// proxies that serve an interstitial as `text/plain`.
    private func isHTML(data: Data, contentType: String) -> Bool {
        if contentType.contains("text/html") { return true }
        guard let first = data.first(where: { !($0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09) }) else {
            return false
        }
        return first == UInt8(ascii: "<")
    }
}
