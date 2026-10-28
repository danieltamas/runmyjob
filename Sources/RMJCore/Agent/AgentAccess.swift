import Foundation

/// The switch behind `rmj mcp`: `agent_access` in `config.json`. Off unless the file says `true`;
/// a missing, unreadable or malformed file is off.
public enum AgentAccess {
    static let key = "agent_access"

    public static func isEnabled(home: RMJHome) -> Bool {
        guard let data = FileManager.default.contents(atPath: file(home).path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        // Foundation reads the number 1 as true; only the JSON literal counts.
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }

    /// Changes only this key: the rest of the file is kept. A file that cannot be read as an object is left alone.
    public static func set(_ enabled: Bool, home: RMJHome) throws {
        let url = file(home)
        var isDirectory: ObjCBool = false
        var object = [String: Any]()
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue, let data = FileManager.default.contents(atPath: url.path),
                  let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            object = existing
        }
        object[key] = enabled
        try home.prepare()
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func file(_ home: RMJHome) -> URL { home.url.appendingPathComponent("config.json") }
}
