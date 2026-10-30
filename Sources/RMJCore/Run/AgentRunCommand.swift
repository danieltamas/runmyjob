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
        public var prompt = ""
    }

    static let usage = "usage: rmj agent run [--harness claude|codex] [--to destination] [--timeout 30m] [--unattended] [--allow \"Tool,Tool\"] [--require-box] -- \"<prompt>\""

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
        guard !options.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.usage }
        return options
    }

    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        guard let options = try? parse(arguments) else { return RunCommand.fail(usage, code: 2) }
        let task = AgentTask(harness: options.harness, prompt: options.prompt, unattended: options.unattended, allowedTools: options.allowedTools,
                             timeoutSeconds: options.timeoutSeconds, requireBox: options.requireBox)
        return await RunCommand.dispatch(command: task.argv(onBox: false), shell: false, destination: options.destination,
                                         agentTask: task, environment: environment)
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
