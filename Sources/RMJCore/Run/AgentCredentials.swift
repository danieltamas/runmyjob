import Foundation

/// Where the Mac's Claude login comes from.
public protocol CredentialSource: Sendable {
    /// The raw JSON of the Claude Code login: `{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt" (ms), ...}}`.
    func load() async throws -> Data
}

/// Claude Code keeps its login in the login Keychain; `security` is the one program that reads it without an app of our own.
public struct KeychainCredentials: CredentialSource {
    public init() {}

    public func load() async throws -> Data {
        let output = try await ProcessRunner().run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
                                                   timeout: .seconds(30))
        guard output.status == 0, !output.stdout.isEmpty else { throw AgentCredentials.Failure.unreadable }
        return output.stdout
    }
}

/// Codex keeps its login in a file; the box gets a copy without the refresh token.
public struct CodexAuthFile: CredentialSource {
    public init() {}

    public func load() async throws -> Data {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw AgentCredentials.Failure.unreadable }
        return data
    }
}

public enum AgentCredentials {
    public enum Failure: Error, LocalizedError, Equatable {
        case unreadable
        case expiresSoon

        public var errorDescription: String? {
            switch self {
            case .unreadable: "the Claude login on this Mac cannot be read"
            case .expiresSoon: "claude login expires soon"
            }
        }
    }

    /// What goes to the box: the login without its refresh token, which stays on the Mac so the box can neither renew the
    /// login nor invalidate this Mac's copy. A token with less than `minimumLifetime` left would die mid-run.
    public static func stage(raw: Data, now: Date, minimumLifetime: TimeInterval) throws -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              var login = root["claudeAiOauth"] as? [String: Any],
              let token = login["accessToken"] as? String, !token.isEmpty,
              let expires = (login["expiresAt"] as? NSNumber)?.doubleValue else { throw Failure.unreadable }
        guard expires / 1000 - now.timeIntervalSince1970 >= minimumLifetime else { throw Failure.expiresSoon }
        login["refreshToken"] = nil
        login["refreshTokenExpiresAt"] = nil
        root = ["claudeAiOauth": login]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// The staged login for `harness`, and the strings in it that must never show in output.
    static func stage(raw: Data, harness: AgentHarness, now: Date, minimumLifetime: TimeInterval) throws -> (login: Data, expires: Date, secrets: [String]) {
        switch harness {
        case .claude:
            let login = try stage(raw: raw, now: now, minimumLifetime: minimumLifetime)
            let oauth = (try JSONSerialization.jsonObject(with: login) as? [String: Any])?["claudeAiOauth"] as? [String: Any]
            let expires = Date(timeIntervalSince1970: ((oauth?["expiresAt"] as? NSNumber)?.doubleValue ?? 0) / 1000)
            return (login, expires, [oauth?["accessToken"] as? String].compactMap { $0 })
        case .codex:
            guard var root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  var tokens = root["tokens"] as? [String: Any],
                  let access = tokens["access_token"] as? String, !access.isEmpty,
                  let expires = jwtExpiry(access) else { throw Failure.unreadable }
            guard expires.timeIntervalSince(now) >= minimumLifetime else { throw Failure.expiresSoon }
            let secrets = ["access_token", "id_token"].compactMap { tokens[$0] as? String }.filter { !$0.isEmpty }
            // Codex does not read a login without the field; an empty value parses and cannot refresh anything.
            tokens["refresh_token"] = ""
            root["tokens"] = tokens
            // A long-lived API key in the same file is not the short-lived login this run is allowed to carry.
            if root["OPENAI_API_KEY"] != nil { root["OPENAI_API_KEY"] = NSNull() }
            return (try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), expires, secrets)
        }
    }

    /// The `exp` claim of a JWT, without verifying it: only used to decide whether the copy would outlive the task.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
