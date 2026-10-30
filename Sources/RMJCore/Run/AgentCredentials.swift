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
}
