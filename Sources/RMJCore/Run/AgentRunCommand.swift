import Foundation

/// `rmj agent run [--to dest] [--timeout 30m] [--unattended] [--allow "Tool,Tool"] [--require-box] -- "<prompt>"`.
public enum AgentRunCommand {
    public enum Failure: Error, Equatable { case usage }

    public struct Options: Equatable, Sendable {
        public var harness = AgentHarness.claude
        public var destination: String?
        public var timeoutSeconds = 3600
        public var unattended = false
        public var allowedTools = [String]()
        public var requireBox = false
        public var model: String?
        public var session: AgentTask.Session?
        public var appendSystemPrompt: String?
        public var attachments = [String]()
        public var json = false
        public var prompt = ""
    }

    static let usage = "usage: rmj agent run [--harness claude|codex] [--to destination] [--model name] [--session-id uuid | --resume uuid] [--append-system-prompt-file path] [--attach dir]... [--json] [--timeout 30m] [--unattended] [--allow \"Tool,Tool\"] [--require-box] -- \"<prompt>\""

    static let maxSystemPromptBytes = 65536
    static let maxAttachments = 4
    /// What the container keeps for itself: an attachment can never shadow the checkout, the login's tmpfs or the system.
    private static let reservedRoots: Set<String> = ["work", "tmp", "run", "proc", "sys", "dev", "etc", "usr", "bin", "sbin", "lib", "opt", "root", "home"]

    /// The file's text, or nil: a regular, readable, UTF-8 file of 1 to 64 KiB (never read past one byte over the limit).
    static func systemPrompt(at path: String) -> String? {
        guard (try? URL(fileURLWithPath: path).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxSystemPromptBytes + 1), (1...maxSystemPromptBytes).contains(data.count) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The directory's standardized path when it can be mounted at that same path in a container, else nil.
    static func attachmentPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || "._/+@=-".unicodeScalars.contains($0) }),
              !path.split(separator: "/").contains("..") else { return nil }
        let standard = URL(fileURLWithPath: path).standardized.path
        guard let first = standard.split(separator: "/").first, !reservedRoots.contains(String(first)) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standard, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return standard
    }

    /// At most 64 KiB of UTF-8, cut between characters.
    static func bounded(_ text: String) -> String {
        guard text.utf8.count > maxSystemPromptBytes else { return text }
        var used = 0, end = text.unicodeScalars.startIndex
        for index in text.unicodeScalars.indices {
            used += String(text.unicodeScalars[index]).utf8.count
            if used > maxSystemPromptBytes { break }
            end = text.unicodeScalars.index(after: index)
        }
        return String(text.unicodeScalars[..<end])
    }

    /// The last line of `--json`: one object whose `final` is the agent's last message, cleaned and kept under 64 KiB.
    public static func jsonLine(job: String, location: String, branch: String?, exit: Int32, final: String?) -> String {
        var sanitizer = LogSanitizer()
        let cleaned = final.map { String(decoding: sanitizer.clean(Data($0.utf8)), as: UTF8.self) }
        let object: [String: Any] = ["branch": branch as Any? ?? NSNull(), "exit": Int(exit), "final": cleaned.map(bounded) as Any? ?? NSNull(),
                                     "job": job, "location": location]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A model name is one word of letters, digits and `. _ : [ ] -`, so it can never be taken for an option or a shell word.
    static func isModelName(_ text: String) -> Bool {
        func alphanumeric(_ scalar: Unicode.Scalar) -> Bool { ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) }
        guard let first = text.unicodeScalars.first, alphanumeric(first), text.utf8.count <= 64 else { return false }
        return text.unicodeScalars.allSatisfy { alphanumeric($0) || "._:[]-".unicodeScalars.contains($0) }
    }

    public static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var rest = arguments[...]
        var allowGiven = false
        while let argument = rest.popFirst() {
            switch argument {
            case "--": options.prompt = rest.joined(separator: " "); rest = []
            case "--to": options.destination = rest.popFirst()
            case "--harness":
                guard let harness = rest.popFirst().flatMap(AgentHarness.init(rawValue:)) else { throw Failure.usage }
                options.harness = harness
            case "--timeout":
                guard let seconds = rest.popFirst().flatMap(duration) else { throw Failure.usage }
                options.timeoutSeconds = seconds
            case "--model":
                guard let name = rest.popFirst(), isModelName(name) else { throw Failure.usage }
                options.model = name
            case "--session-id", "--resume":
                // One conversation per run, and a UUID: it names a file on the box.
                guard options.session == nil, let text = rest.popFirst(), let id = UUID(uuidString: text) else { throw Failure.usage }
                options.session = AgentTask.Session(id: id.uuidString.lowercased(), resume: argument == "--resume")
            case "--append-system-prompt-file":
                guard options.appendSystemPrompt == nil, let path = rest.popFirst(), let text = systemPrompt(at: path) else { throw Failure.usage }
                options.appendSystemPrompt = text
            case "--attach":
                guard options.attachments.count < maxAttachments, let path = rest.popFirst().flatMap(attachmentPath) else { throw Failure.usage }
                options.attachments.append(path)
            case "--json": options.json = true
            case "--unattended": options.unattended = true
            case "--require-box": options.requireBox = true
            case "--allow":
                guard let list = rest.popFirst() else { throw Failure.usage }
                allowGiven = true
                options.allowedTools += tools(in: list)
            default: throw Failure.usage
            }
        }
        // Codex has no per-tool allowlist to pass on.
        guard options.harness == .claude || !allowGiven else { throw Failure.usage }
        guard options.harness == .claude || options.session == nil else { throw Failure.usage }
        guard options.harness == .claude || options.appendSystemPrompt == nil else { throw Failure.usage }
        guard !options.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.usage }
        return options
    }

    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        guard let options = try? parse(arguments) else { return RunCommand.fail(usage, code: 2) }
        let task = AgentTask(harness: options.harness, prompt: options.prompt, unattended: options.unattended, allowedTools: options.allowedTools,
                             timeoutSeconds: options.timeoutSeconds, requireBox: options.requireBox, model: options.model, session: options.session,
                             systemPrompt: options.appendSystemPrompt, attachments: options.attachments)
        return await RunCommand.dispatch(command: task.argv(onBox: false), shell: false, destination: options.destination,
                                         agentTask: task, json: options.json, environment: environment)
    }

    /// `90`, `90s`, `30m`, `2h`: seconds, at least one.
    static func duration(_ text: String) -> Int? {
        let units: [Character: Int] = ["s": 1, "m": 60, "h": 3600]
        let scale = text.last.flatMap { units[$0] }
        guard let number = Int(scale == nil ? text : String(text.dropLast())), number > 0 else { return nil }
        let (seconds, overflow) = number.multipliedReportingOverflow(by: scale ?? 1)
        return overflow ? nil : seconds
    }

    /// Splits at commas outside parentheses, so `Bash(git log:*),Read` is two tools.
    static func tools(in list: String) -> [String] {
        var tools = [String](), current = "", depth = 0
        for character in list {
            if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) }
            if character == ",", depth == 0 { tools.append(current); current = "" } else { current.append(character) }
        }
        tools.append(current)
        return tools.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
