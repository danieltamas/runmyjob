import Foundation

/// What a sink has done so far, for the Settings pane, `rmj sinks` and the header glyph.
public struct LogSinkStatus: Codable, Sendable, Equatable {
    public var id: String
    public var sent: Int
    public var rejected: Int
    public var dropped: Int
    public var waitingFiles: Int
    public var waitingLines: Int
    public var oldestWaiting: Date?
    public var lastOK: Date?
    public var lastError: String?
    public var lastErrorAt: Date?
    public var authFailed: Bool

    public init(id: String, sent: Int = 0, rejected: Int = 0, dropped: Int = 0, waitingFiles: Int = 0, waitingLines: Int = 0,
                oldestWaiting: Date? = nil, lastOK: Date? = nil, lastError: String? = nil, lastErrorAt: Date? = nil, authFailed: Bool = false) {
        self.id = id; self.sent = sent; self.rejected = rejected; self.dropped = dropped
        self.waitingFiles = waitingFiles; self.waitingLines = waitingLines; self.oldestWaiting = oldestWaiting
        self.lastOK = lastOK; self.lastError = lastError; self.lastErrorAt = lastErrorAt; self.authFailed = authFailed
    }
}

/// `log-sinks.json` in the home: one entry per sink, rewritten whole under a lock because the app and the CLI both write it.
public struct LogSinkStatusStore: Sendable {
    private let home: RMJHome

    public init(home: RMJHome) { self.home = home }

    private var file: URL { home.url.appendingPathComponent("log-sinks.json") }

    public func read() -> [LogSinkStatus] {
        guard let data = FileManager.default.contents(atPath: file.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LogSinkStatus].self, from: data)) ?? []
    }

    public func update(_ status: LogSinkStatus) throws {
        try change { list in
            if let index = list.firstIndex(where: { $0.id == status.id }) { list[index] = status } else { list.append(status) }
        }
    }

    /// Edits one sink's entry (a new one when it has none) under the lock, so the app and the CLI never overwrite each other's counters.
    public func modify(id: String, _ edit: (inout LogSinkStatus) -> Void) throws {
        try change { list in
            let index = list.firstIndex { $0.id == id } ?? { list.append(LogSinkStatus(id: id)); return list.count - 1 }()
            edit(&list[index])
        }
    }

    public func remove(id: String) throws { try change { $0.removeAll { $0.id == id } } }

    private func change(_ edit: (inout [LogSinkStatus]) -> Void) throws {
        try home.prepare()
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var list = read()
        edit(&list)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// The header glyph: absent with no sink on, teal while healthy, amber after a recent failure or an old backlog.
public enum LogStreamIndicator: Sendable, Equatable {
    case off, healthy, failing

    private static let window: TimeInterval = 300

    public static func state(sinks: [LogSinkConfig], status: [LogSinkStatus], now: Date) -> LogStreamIndicator {
        let active = sinks.filter(\.enabled)
        guard !active.isEmpty else { return .off }
        let failing = active.contains { sink in
            guard let s = status.first(where: { $0.id == sink.id }) else { return false }
            if s.authFailed { return true }
            if let at = s.lastErrorAt, now.timeIntervalSince(at) <= window, at > (s.lastOK ?? .distantPast) { return true }
            if let oldest = s.oldestWaiting, now.timeIntervalSince(oldest) > window { return true }
            return false
        }
        return failing ? .failing : .healthy
    }
}
