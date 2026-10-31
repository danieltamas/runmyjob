import Foundation

/// Decides what an agent's shell command should do about RMJ: builds and test suites at command position in a
/// classified repo go through `rmj run`; everything else passes. A port of the fleet's remote-build guard.
/// Routing assistance only: the tenant boundary is enforced by the router, not here.
public enum CommandGuard {
    public enum Kind: Equatable, Sendable { case check, build }

    public enum RepoClass: Equatable, Sendable {
        /// Not inside a git repository, or one with no remote to name it.
        case notRepo
        /// A repository no tenant of the rules claims.
        case unclassified(repo: String)
        case classified(repo: String)
    }

    public enum Verdict: Equatable, Sendable {
        case allow
        /// The command may run; the text is one line for the agent.
        case advise(String)
        /// The command must go through `rmj run`; the text says how.
        case block(String)
    }

    /// The kind of build command at command position in `command`, or nil when there is none, when it is
    /// already under `rmj run` or `rx`, or when `RX_LOCAL=1` asks for this Mac.
    public static func kind(of command: String) -> Kind? {
        let blank = blanked(command)
        let text = Self.routed.stringByReplacingMatches(in: blank, range: NSRange(location: 0, length: blank.utf16.count), withTemplate: ";")
        if matches(Self.check, text) { return .check }
        if matches(Self.build, text) { return .build }
        return nil
    }

    /// The directory the command acts in: a leading `cd <dir>` wins over the session's working directory.
    public static func directory(of command: String, cwd: String) -> String {
        let text = command
        guard let match = Self.changeDirectory.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 2), in: text) else { return cwd }
        var dir = String(text[range]).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        if dir.hasPrefix("~") { dir = NSHomeDirectory() + dir.dropFirst() }
        return dir.hasPrefix("/") ? dir : (cwd as NSString).appendingPathComponent(dir)
    }

    /// `rmj run -- <command>`, or `rmj run --shell -- '<command>'` when the command carries shell syntax.
    public static func runForm(for command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(Self.shellSyntax, trimmed) else { return "rmj run -- \(trimmed)" }
        return "rmj run --shell -- '" + trimmed.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The whole decision. `classify` names the repo of a directory; `destination` says where the router would run
    /// the command (a destination or "this Mac"), so a local fallback is recorded too, or nil when no rule names the repo.
    public static func verdict(command: String, cwd: String,
                               classify: (String) async -> RepoClass,
                               destination: (String, String) async -> String?) async -> Verdict {
        guard let kind = kind(of: command) else { return .allow }
        let dir = directory(of: command, cwd: cwd)
        switch await classify(dir) {
        case .notRepo:
            return .allow
        case .unclassified(let repo):
            return .advise("rmj: \(repo) has no tenant in your rules, so this runs on this Mac. Add the repo to a tenant to route it.")
        case .classified:
            // A repo that no rule names runs on this Mac whatever the guard says: nothing to route.
            guard let place = await destination(command, dir) else { return .allow }
            let form = UntrustedText.clean(runForm(for: command), limit: 400)
            let where_ = " (it would run on \(place))"
            switch kind {
            case .check:
                return .block("this suite goes through RMJ, not straight to this Mac\(where_). Run: \(form). "
                    + "RX_LOCAL=1 <command> runs it here if you must.")
            case .build:
                return .advise("rmj: a cargo build here is only needed for a binary that runs on this Mac; "
                    + "\(runForm(for: "cargo check")) proves it compiles on a box\(where_).")
            }
        }
    }

    // MARK: matching

    private static let anchor = #"(?:^\s*|[;&|`\n(]\s*|\$\(\s*)"#
    private static let environment = #"(?:[A-Za-z_][A-Za-z0-9_]*=[^\s;&|]*\s+)*"#

    private static func regex(_ body: String) -> NSRegularExpression { try! NSRegularExpression(pattern: anchor + environment + body) }
    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A segment that is already under `rmj run` or `rx`, or opted out with RX_LOCAL=1, up to the next separator:
    /// it is dropped, so a second command after `;` is still judged.
    private static let routed = regex(#"(?:RX_LOCAL=1|rx\s|rmj\s+run(?:\s|$))[^;&|\n]*"#)
    private static let check = regex(#"(?:cargo\s+(?:\+\S+\s+)?(?:test|check|clippy|nextest|bench|doc|deny)(?:[\s;&|)]|$)|cargo\s+fmt\s[^;&|]*--check|just\s+(?:check|test|lint|deny)(?:[\s;&|)]|$)|(?:npm|pnpm|yarn|bun)(?:\s+(?:-r|--recursive|--silent|-s|--if-present|--workspaces|-ws)|\s+(?:--prefix|--filter|-F|--workspace|-w|--cwd|-C|--dir)(?:=|\s+)\S+)*\s+(?:run\s+)?(?:test|lint|typecheck|check)(?::[\w:.-]+)?(?:[\s;&|)]|$)|(?:(?:bash|sh)\s+)?(?:\./)?scripts/check\.sh(?:[\s;&|)]|$))"#)
    private static let build = regex(#"cargo\s+(?:\+\S+\s+)?build(?:[\s;&|)]|$)"#)
    private static let changeDirectory = try! NSRegularExpression(pattern: #"(^\s*|[;&|\n]\s*)cd\s+("[^"]*"|'[^']*'|[^\s;&|]+)"#)
    private static let shellSyntax = try! NSRegularExpression(pattern: #"[;&|<>()$`\\\n"'*?{}]|^\s*[A-Za-z_][A-Za-z0-9_]*="#)

    /// The command with quoted strings and heredoc bodies blanked, so a build command named in a commit message,
    /// a PR body or a markdown backtick never looks like one at command position. The payload of `-c '...'` is kept
    /// at command position: that is a command. Escapes are honoured.
    static func blanked(_ command: String) -> String {
        let s = Array(command)
        let n = s.count
        var out = "", i = 0
        func text(_ from: Int, _ to: Int) -> String { from < to ? String(s[from..<min(to, n)]) : "" }
        while i < n {
            let c = s[i]
            if c == "\\" { out.append(c); if i + 1 < n { out.append(s[i + 1]) }; i += 2; continue }
            if c == "'" || c == "\"" {
                let keep = i >= 3 && text(i - 3, i) == "-c "
                var j = i + 1
                while j < n && s[j] != c { if c == "\"" && s[j] == "\\" { j += 1 }; j += 1 }
                out += keep ? ";" + text(i + 1, j) : String([c, c])
                i = j + 1
                continue
            }
            if c == "<", i + 1 < n, s[i + 1] == "<", let tag = heredocTag(s, at: i) {
                out += "<<" + tag.name
                i += tag.length
                guard let eol = s[i...].firstIndex(of: "\n") else { out += text(i, n); break }
                out += text(i, eol + 1)
                i = eol + 1
                // The body ends at a line that is the tag; `<<-` also accepts tabs before it.
                var lineStart = i
                var closed = false
                while lineStart < n {
                    let lineEnd = s[lineStart...].firstIndex(of: "\n") ?? n
                    var line = text(lineStart, lineEnd)
                    if tag.stripsTabs { line = String(line.drop { $0 == "\t" }) }
                    lineStart = min(lineEnd + 1, n)
                    if line == tag.name { closed = true; break }
                }
                i = lineStart
                if !closed { break }
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func heredocTag(_ s: [Character], at i: Int) -> (name: String, length: Int, stripsTabs: Bool)? {
        var j = i + 2
        let stripsTabs = j < s.count && s[j] == "-"
        if stripsTabs { j += 1 }
        while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
        if j < s.count, s[j] == "'" || s[j] == "\"" { j += 1 }
        let start = j
        guard j < s.count, s[j].isLetter && s[j].isASCII || s[j] == "_" else { return nil }
        while j < s.count, (s[j].isLetter || s[j].isNumber) && s[j].isASCII || s[j] == "_" { j += 1 }
        let name = String(s[start..<j])
        if j < s.count, s[j] == "'" || s[j] == "\"" { j += 1 }
        return (name, j - i, stripsTabs)
    }
}
