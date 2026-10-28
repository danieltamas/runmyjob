import Foundation

/// `config.json` in the home: small switches the app and the CLI share. Every writer keeps the keys it does not own.
enum ConfigFile {
    static func url(_ home: RMJHome) -> URL { home.url.appendingPathComponent("config.json") }

    /// The file's object; nil when it is missing or not a JSON object.
    static func read(_ home: RMJHome) -> [String: Any]? {
        FileManager.default.contents(atPath: url(home).path).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// Sets `changes`, mode 0600. A file that exists but cannot be read as an object is left alone and the call throws.
    static func merge(_ changes: [String: Any], home: RMJHome) throws {
        let file = url(home)
        try home.prepare()
        // The app and the CLI both write this file: the read-merge-write holds a lock so neither loses the other's keys.
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var isDirectory: ObjCBool = false
        var object = [String: Any]()
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue, let existing = read(home) else { throw CocoaError(.fileReadCorruptFile) }
            object = existing
        }
        object.merge(changes) { _, new in new }
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// A switch stored as the JSON literal true or false; anything else (the number 1 included) is `fallback`.
    static func flag(_ object: [String: Any]?, _ key: String, fallback: Bool) -> Bool {
        guard let value = object?[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return fallback }
        return value.boolValue
    }
}
