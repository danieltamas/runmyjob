import Foundation

/// Turns a run's output into entries for the sinks that may have it.
public struct LogLineAssembler: Sendable {
    private let job: String, repo: String, tenant: String?, branch: String?, agent: String?, destination: String
    private var sanitizer = LogSanitizer()
    private var carry = Data()
    private var number = 1

    public init(job: String, repo: String, tenant: String?, branch: String?, agent: String?, destination: String) {
        self.job = job; self.repo = repo; self.tenant = tenant; self.branch = branch; self.agent = agent; self.destination = destination
    }

    public mutating func add(_ chunk: Data, now: Date) -> [LogEntry] {
        // Only the new bytes are searched for a newline, so a very long line costs one pass, not one per chunk.
        var rest = sanitizer.clean(chunk)[...]
        var entries: [LogEntry] = []
        while let newline = rest.firstIndex(of: 10) {
            carry.append(rest[..<newline])
            entries.append(entry(carry, now: now))
            carry = Data()
            rest = rest[rest.index(after: newline)...]
        }
        carry.append(rest)
        // Output with no newline is cut into lines of the clip size instead of growing without bound.
        while carry.count > LogSinkFormat.maxLineBytes {
            entries.append(entry(carry.prefix(LogSinkFormat.maxLineBytes), now: now))
            carry = Data(carry.dropFirst(LogSinkFormat.maxLineBytes))
        }
        return entries
    }

    /// The unfinished last line, when the output ended without a newline.
    public mutating func flush(now: Date) -> [LogEntry] {
        guard !carry.isEmpty else { return [] }
        defer { carry = Data() }
        return [entry(carry, now: now)]
    }

    /// The closing entry that says how the run ended.
    public mutating func finish(state: String, exitCode: Int?, seconds: TimeInterval?, avgCPU: Double?, avgMemoryBytes: Int64?, now: Date) -> LogEntry {
        var text = "run finished: \(state)"
        if let exitCode { text += ", exit \(exitCode)" }
        if let seconds { text += ", \(PanelFormat.duration(seconds))" }
        if let avgCPU { text += ", avg cpu \(Int(avgCPU.rounded()))%" }
        if let avgMemoryBytes { text += ", avg mem \(ByteCountFormatter.string(fromByteCount: avgMemoryBytes, countStyle: .memory))" }
        return make(text, level: state == "failed" || state == "lost" ? .error : .info, now: now)
    }

    private mutating func entry(_ raw: Data, now: Date) -> LogEntry {
        var bytes = raw
        if bytes.last == 13 { bytes.removeLast() }
        let line = String(decoding: bytes, as: UTF8.self)
        let level: LogEntry.Level
        // A line's meaning shows at its start; a megabyte of text is not scanned for it.
        switch LogClassifier.kind(of: String(line.prefix(2048))) {
        case .error: level = .error
        case .warning: level = .warn
        default: level = .info
        }
        return make(line, level: level, now: now)
    }

    private mutating func make(_ line: String, level: LogEntry.Level, now: Date) -> LogEntry {
        defer { number += 1 }
        return LogEntry(time: now, line: line, level: level, job: job, n: number, repo: repo, tenant: tenant, branch: branch, agent: agent, destination: destination)
    }
}

/// Writes entries to the spool of every enabled sink whose scope includes them. It touches the disk only; the
/// sending is the drainer's job, so a slow or dead sink never holds a run back.
public struct LogShipper: Sendable {
    private let sinks: [LogSinkConfig]
    private let spoolRoot: URL
    private let secrets: [String]
    private let now: @Sendable () -> Date

    public init(sinks: [LogSinkConfig], spoolRoot: URL, secrets: [String] = [], now: @escaping @Sendable () -> Date = { Date() }) {
        self.sinks = sinks; self.spoolRoot = spoolRoot; self.now = now
        // Output is cut into lines before redaction, so each line of a multi-line secret is redacted on its own too.
        let parts = secrets.flatMap { $0.contains("\n") ? [$0] + $0.split(whereSeparator: \.isNewline).map(String.init).filter { $0.count >= 6 } : [$0] }
        self.secrets = Set(parts.filter { !$0.isEmpty }).sorted { $0.count > $1.count }
    }

    public static func spoolDirectory(root: URL, sinkID: String) -> URL { root.appendingPathComponent(sinkID, isDirectory: true) }

    /// Lines written per sink id.
    @discardableResult
    public func ship(_ entries: [LogEntry]) throws -> [String: Int] { try write(entries).lines }

    /// Like `ship`, and also how many older files each sink's limits dropped to make room.
    func write(_ entries: [LogEntry]) throws -> (lines: [String: Int], dropped: [String: Int]) {
        var written: [String: Int] = [:]
        var dropped: [String: Int] = [:]
        var failure: Error?
        for sink in sinks where sink.enabled {
            let accepted = entries.filter { sink.accepts(tenant: $0.tenant) }.map(redacted)
            guard !accepted.isEmpty else { continue }
            let spool = LogSpool(directory: Self.spoolDirectory(root: spoolRoot, sinkID: sink.id))
            let size = LogSinkFormat.maxBatch(sink.kind)
            do {
                for start in stride(from: 0, to: accepted.count, by: size) {
                    dropped[sink.id, default: 0] += try spool.append(Array(accepted[start..<min(start + size, accepted.count)]), now: now())
                }
                written[sink.id] = accepted.count
            } catch {
                failure = error // one sink's full disk or bad path must not starve the others
            }
        }
        if written.isEmpty, let failure { throw failure }
        return (written, dropped)
    }

    private func redacted(_ entry: LogEntry) -> LogEntry {
        guard !secrets.isEmpty else { return entry }
        var copy = entry
        let replacement = String(decoding: SecretRedactor.replacement, as: UTF8.self)
        for secret in secrets { copy.line = copy.line.replacingOccurrences(of: secret, with: replacement) }
        return copy
    }
}
