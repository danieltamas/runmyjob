import Foundation

public struct LogLine: Sendable, Equatable {
    public enum Kind: String, Sendable { case command, error, warning, success, plain }

    /// 1-based within the kept lines.
    public let number: Int
    public let text: String
    public let kind: Kind
}

/// What a log line means, from its words: the sanitizer strips terminal colors, so the screen colors by meaning.
public enum LogClassifier {
    /// A word on its own: not part of an identifier (`Failure.failed(`, `--no-fail`, `error_count`).
    private static func words(_ list: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "(?<![\\w.\\-])(\(list))(?![\\w(\\-]|\\.\\w)", options: .caseInsensitive)
    }

    private static let errorWords = words("error|errors|fail|failed|failure|fatal|panic|exception")
    /// A compiler's source excerpt (`40 | throw Failure.failed(x)`) quotes code, it does not report anything.
    private static let excerpt = try! NSRegularExpression(pattern: "(^|\\s)\\d+ \\| ")
    private static let zeroCount = words("0 (failed|errors?|failures)")
    private static let warningWords = words("warn|warning|warnings|deprecated|skip|skipped")
    private static let successWords = words("passed|success|succeeded")

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func kind(of line: String) -> LogLine.Kind {
        if line.hasPrefix("$ ") { return .command }
        if matches(excerpt, line) { return .plain }
        let counted = zeroCount.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        if line.hasPrefix("FAIL") || line.hasPrefix("E:") || line.contains("\u{2718}") || line.contains("\u{2717}") || matches(errorWords, counted) { return .error }
        if matches(warningWords, line) { return .warning }
        if line.hasPrefix("PASS") || line.hasPrefix("ok ") || line.contains("\u{2714}") || line.contains("\u{2713}") || matches(successWords, line) { return .success }
        return .plain
    }
}

/// A job's log as the report screen shows it: sanitized, classified, and bounded.
public struct LogDocument: Sendable, Equatable {
    public let lines: [LogLine]
    /// Read from a `.part` file: the job still writes it.
    public let isLive: Bool
    /// Earlier output was cut, by the byte window or by `maxLines`.
    public let truncated: Bool
    public let byteCount: Int64
    public var errorCount: Int { lines.filter { $0.kind == .error }.count }
    public var warningCount: Int { lines.filter { $0.kind == .warning }.count }

    public init(lines: [LogLine], isLive: Bool, truncated: Bool, byteCount: Int64) {
        self.lines = lines
        self.isLive = isLive
        self.truncated = truncated
        self.byteCount = byteCount
    }

    /// The lines of a text, numbered and classified as a loaded log is.
    public init(text: String, isLive: Bool = false) {
        let texts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        self.init(lines: texts.enumerated().map { LogLine(number: $0.offset + 1, text: $0.element, kind: LogClassifier.kind(of: $0.element)) },
                  isLive: isLive, truncated: false, byteCount: Int64(text.utf8.count))
    }

    static let window: UInt64 = 2 * 1024 * 1024

    /// nil when the job has no log file on this Mac.
    public static func load(jobID: String, home: RMJHome, maxLines: Int = 5000) -> LogDocument? {
        for url in LogTail.candidates(jobID: jobID, home: home) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let cut = size > window
            try? handle.seek(toOffset: cut ? size - window : 0)
            var sanitizer = LogSanitizer()
            let clean = String(decoding: sanitizer.clean((try? handle.readToEnd()) ?? Data()), as: UTF8.self)
            var texts = clean.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if clean.hasSuffix("\n") { texts.removeLast() }
            // The window usually starts inside a line.
            if cut, !texts.isEmpty { texts.removeFirst() }
            let over = texts.count > maxLines
            let kept = texts.suffix(maxLines)
            let lines = kept.enumerated().map { LogLine(number: $0.offset + 1, text: $0.element, kind: LogClassifier.kind(of: $0.element)) }
            return LogDocument(lines: lines, isLive: url.lastPathComponent.hasSuffix(".part"), truncated: cut || over, byteCount: Int64(size))
        }
        return nil
    }
}
