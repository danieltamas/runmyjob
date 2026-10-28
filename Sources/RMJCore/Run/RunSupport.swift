import Foundation

/// A sortable 26-character job id (48-bit millisecond time, 80 random bits, Crockford base32),
/// allocated before anything is dispatched and used in every remote name and record.
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func make(now: Date = Date()) -> String {
        var time = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        var characters = [Character](repeating: "0", count: 26)
        for index in stride(from: 9, through: 0, by: -1) {
            characters[index] = alphabet[Int(time & 31)]
            time >>= 5
        }
        for index in 10..<26 { characters[index] = alphabet[Int.random(in: 0..<32)] }
        return String(characters)
    }

    /// `rx-<repo>-<last 8 of the id>`: readable in `docker ps`, unique per job.
    public static func containerName(repo: String?, ulid: String) -> String {
        let name = (repo ?? "job").split(separator: "/").last.map(String.init) ?? "job"
        let safe = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }.prefix(24))
        return "rx-\(safe)-\(ulid.suffix(8).lowercased())"
    }
}

/// Which agent asked for the command, from the environment its harness sets.
public struct AgentContext: Sendable, Equatable {
    public var agent: String
    public var session: String?

    public init(agent: String, session: String? = nil) {
        self.agent = agent
        self.session = session
    }

    public static func detect(environment: [String: String]) -> AgentContext {
        func value(_ keys: [String]) -> String? {
            keys.compactMap { environment[$0] }.first { !$0.isEmpty }.map { UntrustedText.clean($0, limit: 80) }
        }
        func has(prefix: String) -> Bool { environment.keys.contains { $0.hasPrefix(prefix) } }
        if environment["CLAUDE_CODE"] != nil || environment["CLAUDECODE"] != nil || has(prefix: "CLAUDE_CODE_") {
            return AgentContext(agent: "claude-code", session: value(["CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID"]))
        }
        if has(prefix: "CODEX_") { return AgentContext(agent: "codex", session: value(["CODEX_SESSION_ID", "CODEX_THREAD_ID"])) }
        if has(prefix: "OPENCODE_") { return AgentContext(agent: "opencode", session: value(["OPENCODE_SESSION_ID"])) }
        if has(prefix: "HERMES_") { return AgentContext(agent: "hermes", session: value(["HERMES_SESSION_ID"])) }
        return AgentContext(agent: "terminal")
    }
}

/// Branch and short commit of a checkout, for the ledger row.
public enum GitFacts {
    public static func read(in directory: URL, runner: ProcessRunner = ProcessRunner()) async -> (branch: String?, commit: String?) {
        func git(_ arguments: [String]) async -> String? {
            guard let output = try? await runner.run("/usr/bin/git", ["-C", directory.path] + arguments, timeout: .seconds(10)),
                  output.status == 0 else { return nil }
            let text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : UntrustedText.clean(text, limit: 120)
        }
        return (await git(["rev-parse", "--abbrev-ref", "HEAD"]), await git(["rev-parse", "--short", "HEAD"]))
    }
}

/// Makes job output safe to show or hand to an agent: terminal escapes, control characters and
/// invisible Unicode are dropped; newlines and tabs stay. Chunk boundaries may fall inside an escape
/// sequence or a multi-byte character, so the unfinished tail is carried to the next call.
public struct LogSanitizer: Sendable {
    private enum Mode { case text, escape, csi, string, stringEscape }
    private var mode = Mode.text
    private var pending = Data()

    public init() {}

    public mutating func clean(_ chunk: Data) -> Data {
        pending.append(chunk)
        var bytes = pending
        // Hold back an incomplete UTF-8 tail.
        var tail = 0
        if let last = bytes.indices.last {
            var index = last, back = 0
            while index >= bytes.startIndex, back < 4, bytes[index] & 0xC0 == 0x80 { index -= 1; back += 1 }
            if index >= bytes.startIndex, bytes[index] >= 0xC0 {
                let needed = bytes[index] >= 0xF0 ? 4 : bytes[index] >= 0xE0 ? 3 : 2
                if back + 1 < needed { tail = back + 1 }
            }
        }
        pending = Data(bytes.suffix(tail))
        bytes = Data(bytes.dropLast(tail))
        var out = String.UnicodeScalarView()
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch mode {
            case .text:
                if scalar == "\u{1B}" { mode = .escape }
                else if scalar == "\u{9B}" { mode = .csi }
                else if scalar == "\n" || scalar == "\t" { out.append(scalar) }
                else if scalar == "\r" { continue }
                else if !Self.keeps(scalar) { continue }
                else { out.append(scalar) }
            case .escape:
                switch scalar {
                case "[": mode = .csi
                case "]", "P", "^", "_", "X": mode = .string
                default: mode = .text
                }
            case .csi:
                if (0x40...0x7E).contains(scalar.value) { mode = .text }
            case .string:
                if scalar == "\u{07}" { mode = .text } else if scalar == "\u{1B}" { mode = .stringEscape }
            case .stringEscape:
                mode = scalar == "\\" ? .text : .string
            }
        }
        return Data(String(out).utf8)
    }

    private static func keeps(_ scalar: Unicode.Scalar) -> Bool {
        UntrustedText.clean(String(scalar), limit: 1).unicodeScalars.count == 1
    }
}

extension RunRequest {
    /// The command as the ledger shows it: words with spaces or metacharacters are quoted.
    var display: String {
        if shell { return command.joined(separator: " ") }
        return command.map { word in
            !word.isEmpty && word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-/=:,+@%".contains($0)) } ? word : SSH.quote(word)
        }.joined(separator: " ")
    }
}
