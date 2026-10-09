import Foundation

// Reads build-time configuration from Info.plist (populated from xcconfig / project.yml).
enum AppConfig {
    /// Backend base URL. Defaults to the local dev server if the plist value is missing/blank.
    static var apiBaseURL: URL {
        #if PREVIOUSLY_QA
        if let url = QARuntime.baseURL { return url }
        #endif
        let raw = (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url = URL(string: raw), !raw.isEmpty, url.scheme != nil {
            return url
        }
        return URL(string: "http://localhost:8787")!
    }

    /// Clerk publishable key. Treated as "unconfigured" if blank or still the placeholder.
    static var clerkPublishableKey: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw
    }

    /// True when a real Clerk key has been provided. When false, the app offers a dev-bypass
    /// sign-in that authenticates against the local backend's `DEV_AUTH_BYPASS` mode.
    static var isClerkConfigured: Bool {
        let key = clerkPublishableKey
        return key.hasPrefix("pk_") && !key.contains("REPLACE_ME")
    }

    // MARK: - Legal and support (App Store guideline 5.1.1)
    //
    // Read from the build settings, never hard-coded into copy: a placeholder URL baked into a
    // shipped string is a broken Privacy Policy link, which is itself a rejection. Each accessor
    // returns `nil` when its build setting is absent or still the placeholder, and the Profile
    // screen omits the row rather than drawing one that goes nowhere.

    /// Privacy Policy URL (`PrivacyPolicyURL` in Info.plist).
    static var privacyURL: URL? { configuredURL("PrivacyPolicyURL") }

    /// Terms of Use URL (`TermsURL` in Info.plist).
    static var termsURL: URL? { configuredURL("TermsURL") }

    /// Support contact address (`SupportEmail` in Info.plist), as a `mailto:` URL.
    static var supportEmail: String? {
        guard let raw = configuredString("SupportEmail"), raw.contains("@") else { return nil }
        return raw
    }

    static var supportURL: URL? {
        guard let supportEmail else { return nil }
        return URL(string: "mailto:\(supportEmail)")
    }

    private static func configuredString(_ key: String) -> String? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, !raw.contains("REPLACE_ME") else { return nil }
        return raw
    }

    private static func configuredURL(_ key: String) -> URL? {
        guard let raw = configuredString(key), let url = URL(string: raw), url.scheme != nil else {
            return nil
        }
        return url
    }

    /// True when `apiBaseURL` points at a machine on this desk: loopback, a Bonjour `.local`
    /// name, or an RFC-1918 address.
    ///
    /// This is the boundary the `dev:` bearer must never cross. The server refuses dev tokens in
    /// production, but a client that would still SEND one toward a production host is a second
    /// mistake waiting to happen — so the token is withheld here too, and the developer sign-in
    /// affordance is hidden against a non-local base URL even in a Debug build.
    static var isLocalBackend: Bool {
        guard let host = apiBaseURL.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasSuffix(".local") { return true }
        return isPrivateIPv4(host)
    }

    /// RFC-1918 by ADDRESS, not by string prefix. `10.example.com` and `192.168.evil.tld` are
    /// ordinary internet hostnames that anyone can register; a `hasPrefix` test would classify them
    /// as local and release a `dev:` bearer toward them.
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true            // 10.0.0.0/8
        case (192, 168): return true         // 192.168.0.0/16
        case (172, 16...31): return true     // 172.16.0.0/12
        default: return false
        }
    }
}
