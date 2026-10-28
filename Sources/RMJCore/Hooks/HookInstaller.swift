import Foundation

/// Which coding agents RMJ is wired into, and how. Claude Code has a pre-command hook that RMJ owns one entry of;
/// the others are covered by `cargo` and `just` shims that route test commands through `rmj run` (PLAN.md D2: Codex's
/// hooks need the user's own trust approval, so RMJ never edits them).
public struct HookInstaller: Sendable {
    public enum Harness: String, CaseIterable, Sendable {
        case claudeCode = "claude-code", codex, openCode = "opencode", hermes

        public var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .openCode: "OpenCode"
            case .hermes: "Hermes"
            }
        }

        /// Its configuration directory under the home directory; absent means the agent is not on this Mac.
        var directory: String {
            switch self {
            case .claudeCode: ".claude"
            case .codex: ".codex"
            case .openCode: ".config/opencode"
            case .hermes: ".hermes"
            }
        }
    }

    public enum State: Equatable, Sendable {
        case installed
        case notInstalled
        case notPresent
        /// No pre-command hook is used: the shims cover `cargo` and `just`, not `scripts/check.sh`.
        case shimsOnly(installed: Bool)
    }

    public struct Status: Equatable, Sendable {
        public let harness: Harness
        public let state: State
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notPresent(Harness)
        case unreadable(String)

        public var description: String {
            switch self {
            case .notPresent(let harness): "\(harness.title) is not on this Mac"
            case .unreadable(let path): "\(path) is not a JSON object, left untouched"
            }
        }
    }

    public static let shimmed = ["cargo", "just"]
    /// The marker that makes an entry RMJ's: the command ends with it.
    static let marker = " guard --hook"

    let home: URL
    let rmj: String
    public let shimDirectory: URL

    public init(home: URL, rmj: String, shimDirectory: URL) {
        self.home = home
        self.rmj = rmj
        self.shimDirectory = shimDirectory
    }

    public func status() -> [Status] { Harness.allCases.map { Status(harness: $0, state: state(of: $0)) } }

    public func state(of harness: Harness) -> State {
        guard present(harness) else { return .notPresent }
        if harness == .claudeCode { return ownEntry(in: settings(), remove: false).found ? .installed : .notInstalled }
        return .shimsOnly(installed: shimsInstalled)
    }

    /// Wires one harness (or every one on this Mac). Idempotent: a second call changes nothing.
    @discardableResult
    public func install(_ harness: Harness? = nil) throws -> [Status] {
        for target in try targets(harness) {
            if target == .claudeCode { try installClaude() } else { try installShims() }
        }
        return status()
    }

    /// Takes RMJ's entry or shims out and leaves everything else as it was.
    @discardableResult
    public func remove(_ harness: Harness? = nil) throws -> [Status] {
        for target in try targets(harness) {
            if target == .claudeCode { try removeClaude() } else { removeShims() }
        }
        return status()
    }

    private func targets(_ harness: Harness?) throws -> [Harness] {
        if let harness {
            guard present(harness) else { throw Failure.notPresent(harness) }
            return [harness]
        }
        return Harness.allCases.filter(present)
    }

    private func present(_ harness: Harness) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: home.appendingPathComponent(harness.directory).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Claude Code

    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    private func settings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Whether `object` holds RMJ's entry, and `object` without it.
    private func ownEntry(in object: [String: Any], remove: Bool) -> (found: Bool, result: [String: Any]) {
        var result = object
        guard var hooks = object["hooks"] as? [String: Any], var pre = hooks["PreToolUse"] as? [[String: Any]] else { return (false, object) }
        var found = false
        pre = pre.compactMap { entry in
            guard var inner = entry["hooks"] as? [[String: Any]] else { return entry }
            let before = inner.count
            inner.removeAll { ($0["command"] as? String)?.hasSuffix(Self.marker) == true }
            guard inner.count != before else { return entry }
            found = true
            guard remove else { return entry }
            if inner.isEmpty { return nil }
            var kept = entry
            kept["hooks"] = inner
            return kept
        }
        guard remove, found else { return (found, object) }
        if pre.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = pre }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return (found, result)
    }

    private func installClaude() throws {
        var object = try readSettings()
        guard !ownEntry(in: object, remove: false).found else { return }
        // Any other shape under these keys is the user's; replacing it would drop their hooks.
        var hooks = [String: Any]()
        if let existing = object["hooks"] { guard let typed = existing as? [String: Any] else { throw Failure.unreadable(settingsURL.path) }; hooks = typed }
        var pre = [[String: Any]]()
        if let existing = hooks["PreToolUse"] { guard let typed = existing as? [[String: Any]] else { throw Failure.unreadable(settingsURL.path) }; pre = typed }
        pre.append(["matcher": "Bash", "hooks": [["type": "command", "command": Self.shellWord(rmj) + Self.marker]]])
        hooks["PreToolUse"] = pre
        object["hooks"] = hooks
        try write(object)
    }

    private func removeClaude() throws {
        let object = try readSettings()
        let (found, result) = ownEntry(in: object, remove: true)
        if found { try write(result) }
    }

    /// The settings file as an object; a file that exists but is not one is never rewritten.
    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: settingsURL) else { throw Failure.unreadable(settingsURL.path) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unreadable(settingsURL.path) }
        return object
    }

    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: shims

    private var shimsInstalled: Bool {
        Self.shimmed.allSatisfy { FileManager.default.isExecutableFile(atPath: shimDirectory.appendingPathComponent($0).path) }
    }

    private func installShims() throws {
        try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in Self.shimmed {
            let url = shimDirectory.appendingPathComponent(name)
            try Self.shim(name, rmj: rmj).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func removeShims() {
        for name in Self.shimmed { try? FileManager.default.removeItem(at: shimDirectory.appendingPathComponent(name)) }
    }

    /// `path` as one shell word: bare when it is plain, single-quoted otherwise.
    static func shellWord(_ path: String) -> String {
        path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+@:".contains($0)) }
            ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A stand-in for `name` earlier on PATH: a command the guard would send through RMJ goes to `rmj run`, anything
    /// else runs the real binary, found by PATH minus this directory. `RMJ_IN_SHIM` stops `rmj run`'s own local
    /// fallback from coming back here.
    static func shim(_ name: String, rmj: String) -> String {
        let quoted = "'" + rmj.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        # RMJ shim for \(name): test and check commands go through rmj run, everything else runs the real \(name).
        here=$(cd "$(dirname "$0")" && pwd)
        rest=""; old=$IFS; IFS=:
        for d in $PATH; do [ "$(cd "$d" 2>/dev/null && pwd)" = "$here" ] || rest="${rest:+$rest:}$d"; done
        IFS=$old
        real=$(PATH="$rest" command -v \(name)) || { echo "rmj shim: no real \(name) on PATH" >&2; exit 127; }
        if [ -z "${RMJ_IN_SHIM:-}" ] && ! \(quoted) guard --quiet --command "\(name) $*" --cwd "$PWD" >/dev/null 2>&1; then
          RMJ_IN_SHIM=1 PATH="$rest" exec \(quoted) run -- "\(name)" "$@"
        fi
        exec "$real" "$@"
        """ + "\n"
    }
}
