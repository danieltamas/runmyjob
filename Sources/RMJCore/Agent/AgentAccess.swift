import Foundation

/// The switch behind `rmj mcp`: `agent_access` in `config.json`. Off unless the file says `true`;
/// a missing, unreadable or malformed file is off.
public enum AgentAccess {
    static let key = "agent_access"

    public static func isEnabled(home: RMJHome) -> Bool { ConfigFile.flag(ConfigFile.read(home), key, fallback: false) }

    public static func set(_ enabled: Bool, home: RMJHome) throws { try ConfigFile.merge([key: enabled], home: home) }
}
