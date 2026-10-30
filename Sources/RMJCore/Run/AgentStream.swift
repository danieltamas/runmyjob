import Foundation

/// Turns the line-delimited events Claude Code prints with `--output-format stream-json` into the readable lines a person
/// follows: what the agent says and which tool it calls. Anything that is not an event passes through unchanged.
public final class AgentStream: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let emit: @Sendable (Data) -> Void

    public init(emit: @escaping @Sendable (Data) -> Void) { self.emit = emit }

    public func add(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            write(Self.render(Data(line)))
        }
    }

    /// The unterminated tail, when the box output ends without a newline.
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return }
        write(Self.render(pending)); pending = Data()
    }

    private func write(_ text: String) {
        guard !text.isEmpty else { return }
        emit(Data((text + "\n").utf8))
    }

    static func render(_ line: Data) -> String {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = event["type"] as? String else {
            return String(decoding: line, as: UTF8.self)
        }
        let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        switch type {
        case "system":
            guard event["subtype"] as? String == "init", let model = event["model"] as? String else { return "" }
            return "agent started (\(model))"
        case "assistant":
            return content.compactMap { part -> String? in
                switch part["type"] as? String {
                case "text": return (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                case "tool_use": return "> " + describe(tool: part["name"] as? String ?? "tool", input: part["input"] as? [String: Any] ?? [:])
                default: return nil
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        case "user":
            return content.compactMap { part -> String? in
                guard part["type"] as? String == "tool_result", part["is_error"] as? Bool == true else { return nil }
                return "  tool failed: " + shorten(flatten(part["content"]))
            }.joined(separator: "\n")
        case "result":
            guard event["is_error"] as? Bool == true else { return "" }
            return "agent failed: " + shorten((event["result"] as? String) ?? (event["subtype"] as? String) ?? "unknown error")
        default:
            return ""
        }
    }

    private static func describe(tool: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "pattern", "url", "description"] {
            if let value = input[key] as? String { return "\(tool): \(shorten(value))" }
        }
        return tool
    }

    private static func flatten(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
    }

    private static func shorten(_ text: String) -> String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.count > 200 ? String(first.prefix(200)) + "..." : first
    }
}
