import CryptoKit
import Foundation

/// The rules in force: the file read, or the reason it cannot be used (every job then routes locally).
public enum RulesState: Sendable, Equatable {
    case valid(Rules, fingerprint: String)
    case invalid(path: String, message: String)

    public var rules: Rules? { if case .valid(let rules, _) = self { rules } else { nil } }
    public var invalidReason: String? {
        if case .invalid(let path, let message) = self { "rules invalid: \(path) \(message)" } else { nil }
    }
}

public struct RulesStore: Sendable {
    public enum Failure: Error, Equatable {
        /// The file changed since it was read; the caller shows the difference and asks again.
        case changedExternally(current: String)
        case invalid(String)
    }

    public let url: URL
    private let profileExists: @Sendable (String) -> Bool

    public init(home: RMJHome, profileExists: (@Sendable (String) -> Bool)? = nil) {
        url = home.url.appendingPathComponent("rules.json")
        let profiles = ProfileStore(home: home)
        self.profileExists = profileExists ?? { profiles.exists($0) }
    }

    /// An absent file means the starter rules; an unreadable or invalid one means `.invalid`.
    public func load() -> RulesState {
        var info = stat()
        // Only a file that is really absent means "no rules yet"; any other failure to look is not.
        if lstat(url.path, &info) != 0, errno != ENOENT { return .invalid(path: url.path, message: "cannot look at the file (errno \(errno))") }
        guard lstat(url.path, &info) == 0 else {
            return .valid(Rules.starter, fingerprint: Self.fingerprint(Data(Rules.starterJSON.utf8)))
        }
        // A link, another user's file or a group/world-writable one could redirect company jobs.
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            return .invalid(path: url.path, message: "the file must be a regular file of this user, not writable by others")
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return .invalid(path: url.path, message: "cannot read the file")
        }
        do { return .valid(try RulesValidation.parse(data, profileExists: profileExists), fingerprint: Self.fingerprint(data)) } catch {
            return .invalid(path: url.path, message: UntrustedText.clean(String(describing: error), limit: 300))
        }
    }

    /// Validates, writes a temp file and renames it. `expected` is the fingerprint the edit was based
    /// on: if the file is not that any more, an external edit happened and nothing is written. The
    /// last valid file is never replaced by an invalid one.
    public func save(_ rules: Rules, expected: String) throws {
        do { try RulesValidation.validate(rules, profileExists: profileExists) } catch { throw Failure.invalid(String(describing: error)) }
        let current = FileManager.default.contents(atPath: url.path)
        let currentFingerprint = current.map(Self.fingerprint) ?? Self.fingerprint(Data(Rules.starterJSON.utf8))
        guard currentFingerprint == expected else {
            throw Failure.changedExternally(current: current.map { String(decoding: $0, as: UTF8.self) } ?? Rules.starterJSON)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temp = url.deletingLastPathComponent().appendingPathComponent(".rules.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: try encoder.encode(rules), attributes: [.posixPermissions: 0o600]) else {
            throw Failure.invalid("cannot write the temporary file")
        }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw Failure.invalid("cannot replace the rules file")
        }
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
