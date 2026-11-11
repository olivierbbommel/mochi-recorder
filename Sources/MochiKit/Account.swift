import Foundation
import Security

/// Your Mochi account: one email, signed in with a link sent to it (Supabase Auth, no
/// password). Every device (Mac, iPhone) holds its own session in its Keychain and can be signed
/// out on its own. The cloud functions only serve the owner's email (MOCHI_OWNER_EMAIL).
public actor Account {
    public static let shared = Account()

    /// Your Supabase project and its publishable key (MochiConfig). Nil in a local-only build.
    public static var project: URL? { MochiConfig.supabaseURL }
    public static var publishableKey: String? { MochiConfig.publishableKey }
    /// Where the emailed link sends the device back to (the app's URL scheme).
    public static let callback = "mochi://auth"

    public struct Session: Codable, Sendable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date
        public var email: String
    }

    public enum Problem: LocalizedError {
        case http(Int, String), notSignedIn, badLink, notConfigured
        public var errorDescription: String? {
            switch self {
            case .http(let code, let body): "Sign-in failed (\(code)): \(body.prefix(160))"
            case .notSignedIn: "Not signed in."
            case .badLink: "That sign-in link did not work. Ask for a new one."
            case .notConfigured: "This build has no Supabase project set. See the README, \"Sync and the Claude connector\"."
            }
        }
    }

    private var cached: Session?

    public init() {}

    /// The signed-in email, nil when signed out.
    public func email() -> String? { session()?.email }

    /// Emails a sign-in link to `email`. Opening it on this device signs it in.
    public func sendLink(to email: String) async throws {
        guard let project = Self.project, let key = Self.publishableKey else { throw Problem.notConfigured }
        var req = URLRequest(url: project.appendingPathComponent("auth/v1/otp"))
        req.url = URL(string: req.url!.absoluteString + "?redirect_to=" + Self.callback.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email.trimmingCharacters(in: .whitespaces).lowercased(),
                                                                   "create_user": false])
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Problem.http(status, String(decoding: data, as: UTF8.self)) }
    }

    /// The link from the email: mochi://auth#access_token=...&refresh_token=...&expires_in=...
    public func handle(_ url: URL) async throws {
        let fragment = url.fragment ?? url.query ?? ""
        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { values[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        guard let access = values["access_token"], let refresh = values["refresh_token"] else { throw Problem.badLink }
        let expires = Double(values["expires_in"] ?? "3600") ?? 3600
        let email = Self.email(fromJWT: access) ?? ""
        store(Session(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expires), email: email))
    }

    /// A valid access token, refreshed when it is about to expire. nil when signed out.
    public func accessToken() async -> String? {
        guard var s = session() else { return nil }
        if s.expiresAt.timeIntervalSinceNow > 120 { return s.accessToken }
        guard let project = Self.project, let key = Self.publishableKey else { return nil }
        var req = URLRequest(url: URL(string: project.absoluteString + "/auth/v1/token?grant_type=refresh_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": s.refreshToken])
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            return s.expiresAt > Date() ? s.accessToken : nil
        }
        s.accessToken = access
        s.refreshToken = refresh
        s.expiresAt = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600)
        store(s)
        return access
    }

    public func signOut() {
        cached = nil
        Self.keychainDelete()
    }

    // MARK: Storage

    private func session() -> Session? {
        if let cached { return cached }
        guard let data = Self.keychainRead(), let s = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
        cached = s
        return s
    }

    private func store(_ s: Session) {
        cached = s
        if let data = try? JSONEncoder().encode(s) { Self.keychainWrite(data) }
    }

    private static var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "mochi",
                                              kSecAttrAccount as String: "MOCHI_SESSION"] }

    private static func keychainRead() -> Data? {
        var q = base
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func keychainWrite(_ data: Data) {
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainDelete() { SecItemDelete(base as CFDictionary) }

    static func email(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

/// Calls the mochi-api function as the signed-in account (or, on a Mac set up before accounts,
/// with its sync key).
public enum MochiAPI {
    public static var endpoint: URL? { MochiConfig.function("mochi-api") }

    public static func call(_ body: [String: Any], legacyToken: String? = nil) async throws -> [String: Any] {
        guard let endpoint else { throw Account.Problem.notConfigured }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token = await Account.shared.accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        } else if let legacyToken {
            request.setValue(legacyToken, forHTTPHeaderField: "x-mochi-token")
        } else {
            throw Account.Problem.notSignedIn
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            throw NSError(domain: "Mochi", code: status, userInfo: [NSLocalizedDescriptionKey: json["error"] as? String ?? "HTTP \(status)"])
        }
        return json
    }
}
