import CryptoKit
import Foundation

/// A box's ssh host key as the box offers it, with the fingerprint `ssh` shows.
public struct HostKey: Sendable, Equatable {
    public let type: String
    public let base64: String

    public var fingerprint: String {
        guard let raw = Data(base64Encoded: base64) else { return "unreadable key" }
        return "SHA256:" + Data(SHA256.hash(data: raw)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// First contact with a destination: RMJ connects with `StrictHostKeyChecking=yes` and `HostKeyAlias=<alias>`, so the key must
/// already be in known_hosts under the alias. The owner confirms the fingerprint once; a key that differs from a stored one is
/// never replaced.
public struct HostKeyTrust: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case invalid
        case noKey(String)
        case changed

        public var description: String {
            switch self {
            case .invalid: "the alias or address is not valid"
            case .noKey(let why): "the box offered no host key: \(why)"
            case .changed: "known_hosts holds a different key for this alias: a changed key is never accepted here"
            }
        }
    }

    private let knownHosts: URL
    private let keyscan: String

    public init(knownHosts: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts"),
                keyscan: String = "/usr/bin/ssh-keyscan") {
        self.knownHosts = knownHosts
        self.keyscan = keyscan
    }

    /// True when the failure text of an ssh run says the key is not known (as opposed to changed or unreachable).
    public static func isUnknownKey(_ detail: String) -> Bool {
        detail.contains("No ED25519 host key is known") || detail.contains("No ECDSA host key is known")
            || detail.contains("No RSA host key is known") || (detail.contains("Host key verification failed") && !detail.contains("CHANGED"))
    }

    /// The key the box offers at its tailnet `address`; ed25519 first.
    public func scan(address: String) async throws -> HostKey {
        guard TailnetAddress.isTailnet(address) else { throw Failure.invalid }
        let output = try await ProcessRunner().run(keyscan, ["-T", "5", "-t", "ed25519,ecdsa,rsa", address], timeout: .seconds(15))
        let keys = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").compactMap { line -> HostKey? in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: " ")
            guard fields.count >= 3, Data(base64Encoded: String(fields[2])) != nil else { return nil }
            return HostKey(type: String(fields[1]), base64: String(fields[2]))
        }
        guard let key = keys.first(where: { $0.type == "ssh-ed25519" }) ?? keys.first else {
            throw Failure.noKey(output.stderr.split(separator: "\n").first.map(String.init) ?? "no answer")
        }
        return key
    }

    /// A box the owner already connects to with plain `ssh` has its key in known_hosts under its own name (often the MagicDNS name),
    /// not under RMJ's alias. When that stored key is the one the box offers now, it is stored for the alias with no question asked.
    /// Returns false when no stored entry matches, so the owner is asked.
    public func adoptKnown(_ key: HostKey, alias: String, address: String) async -> Bool {
        var names = [alias, address]
        if let config = try? await ProcessRunner().run("/usr/bin/ssh", ["-G", alias], timeout: .seconds(10)), config.status == 0 {
            let host = String(decoding: config.stdout, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("hostname ") }
            if let host { names.append(String(host.dropFirst("hostname ".count))) }
        }
        for name in names where !name.isEmpty && !name.hasPrefix("-") {
            guard let found = try? await ProcessRunner().run("/usr/bin/ssh-keygen", ["-F", name, "-f", knownHosts.path], timeout: .seconds(10)),
                  found.status == 0 else { continue }
            for line in String(decoding: found.stdout, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
                let fields = line.split(separator: " ")
                if fields.count >= 3, fields[1] == Substring(key.type), fields[2] == Substring(key.base64) { return (try? trust(key, alias: alias)) != nil }
            }
        }
        return false
    }

    private enum Stored { case same, different, absent }

    private func hashedState(of key: HostKey, alias: String) -> Stored {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-F", alias, "-f", knownHosts.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .absent }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .absent }
        var state = Stored.absent
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: " ")
            guard fields.count >= 3, fields[1] == Substring(key.type) else { continue }
            if fields[2] == Substring(key.base64) { return .same }
            state = .different
        }
        return state
    }

    /// Stores `key` for `alias`. Already stored (same key) is a success; a different stored key is `changed`.
    public func trust(_ key: HostKey, alias: String) throws {
        guard !alias.isEmpty, !alias.hasPrefix("-"), alias.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              Data(base64Encoded: key.base64) != nil, key.type.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-@.".contains($0)) }) else { throw Failure.invalid }
        let existing = (try? String(contentsOf: knownHosts, encoding: .utf8)) ?? ""
        for line in existing.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 3, fields[0].split(separator: ",").contains(Substring(alias)), fields[1] == Substring(key.type) else { continue }
            if fields[2] == Substring(key.base64) { return }
            throw Failure.changed
        }
        // Hashed entries (`|1|...`) hide the name; ssh-keygen -F finds them, so a stored key for this alias is never shadowed by an appended one.
        if existing.contains("|1|") {
            switch hashedState(of: key, alias: alias) {
            case .same: return
            case .different: throw Failure.changed
            case .absent: break
            }
        }
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entry = Data((existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n").utf8) + Data("\(alias) \(key.type) \(key.base64)\n".utf8)
        if !FileManager.default.fileExists(atPath: knownHosts.path) { FileManager.default.createFile(atPath: knownHosts.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: knownHosts)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: entry)
    }
}
