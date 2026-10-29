import Foundation

/// A sink's queue on disk: whole batch files, written then renamed, deleted only once the sink has taken them.
public struct LogSpool: Sendable {
    public struct Batch: Sendable, Equatable {
        public let id: String
        public let entries: [LogEntry]
        public let bytes: Int64
        public let created: Date
    }

    public struct Pending: Sendable, Equatable {
        public var files: Int
        public var lines: Int
        public var bytes: Int64
        public var oldest: Date?

        public init(files: Int, lines: Int, bytes: Int64, oldest: Date?) {
            self.files = files; self.lines = lines; self.bytes = bytes; self.oldest = oldest
        }
    }

    private static let suffix = ".batch"
    private static let keptRejected = 50
    private static let staleTemporary: TimeInterval = 3600

    private let directory: URL
    /// False when the spool folder (or its parent) is a link or belongs to someone else: nothing is read from or written to it.
    private let trusted: Bool
    private let maxBytes: Int64
    private let maxAge: TimeInterval

    public init(directory: URL, maxBytes: Int64 = 256 * 1024 * 1024, maxAge: TimeInterval = 7 * 86400) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        trusted = Self.isOwnFolder(directory) && Self.isOwnFolder(directory.deletingLastPathComponent())
    }

    private static func isOwnFolder(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    }

    private var rejectedDirectory: URL { directory.appendingPathComponent("rejected", isDirectory: true) }

    // MARK: writing

    /// Returns how many older files the limits dropped to make room.
    @discardableResult
    public func append(_ entries: [LogEntry], now: Date = Date()) throws -> Int {
        guard !entries.isEmpty else { return 0 }
        guard trusted else { throw LogSinkError(message: "the spool folder is a link or not yours") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(10)
        }
        let name = String(format: "%015lld-%d-%08d", Int64(now.timeIntervalSince1970 * 1000), getpid(), Counter.next()) + Self.suffix
        let temporary = directory.appendingPathComponent(name + ".tmp")
        let final = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.moveItem(at: temporary, to: final)
        return enforceLimits(now: now)
    }

    // MARK: reading

    public func pending() -> Pending {
        var result = Pending(files: 0, lines: 0, bytes: 0, oldest: nil)
        for name in batchNames() {
            result.files += 1
            result.bytes += size(of: name)
            result.lines += lineCount(name)
            if result.oldest == nil { result.oldest = Self.created(name) }
        }
        return result
    }

    /// The oldest batch. A file that cannot be read as entries is set aside so it never blocks the queue.
    public func next() -> Batch? {
        var skipped = 0
        return next(quarantined: &skipped)
    }

    /// As `next()`, counting the files that were set aside on the way.
    public func next(quarantined: inout Int) -> Batch? {
        guard trusted else { return nil }
        for name in batchNames() {
            let file = directory.appendingPathComponent(name)
            if let data = FileManager.default.contents(atPath: file.path), let entries = Self.decode(data) {
                return Batch(id: name, entries: entries, bytes: Int64(data.count), created: Self.created(name) ?? Date(timeIntervalSince1970: 0))
            }
            reject(name)
            quarantined += 1
        }
        return nil
    }

    public func acknowledge(_ id: String) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id)) }

    public func reject(_ id: String) {
        let files = FileManager.default
        try? files.createDirectory(at: rejectedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = rejectedDirectory.appendingPathComponent(id)
        try? files.removeItem(at: target)
        // A batch that cannot be set aside stays on disk, renamed so it is never sent again, rather than being lost.
        let source = directory.appendingPathComponent(id)
        do { try files.moveItem(at: source, to: target) } catch { try? files.moveItem(at: source, to: source.appendingPathExtension("bad")) }
        let names = ((try? files.contentsOfDirectory(atPath: rejectedDirectory.path)) ?? []).filter { $0.hasSuffix(Self.suffix) }.sorted()
        for name in names.dropLast(Self.keptRejected) { try? files.removeItem(at: rejectedDirectory.appendingPathComponent(name)) }
    }

    public func rejectedCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: rejectedDirectory.path)) ?? []).filter { $0.hasSuffix(Self.suffix) }.count
    }

    // MARK: managing

    /// Drops the oldest files past the byte cap (the newest always stays) and files past the age limit, and sweeps
    /// abandoned temporaries. Returns the number of batch files dropped.
    @discardableResult
    public func enforceLimits(now: Date = Date()) -> Int {
        let files = FileManager.default
        var dropped = 0
        for name in (try? files.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".tmp") {
            let url = directory.appendingPathComponent(name)
            if let modified = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(modified) > Self.staleTemporary { try? files.removeItem(at: url) }
        }
        var names = batchNames()
        for name in names where Self.created(name).map({ now.timeIntervalSince($0) > maxAge }) ?? false {
            acknowledge(name); dropped += 1
            names.removeAll { $0 == name }
        }
        var total = names.reduce(Int64(0)) { $0 + size(of: $1) }
        while total > maxBytes, names.count > 1 {
            let oldest = names.removeFirst()
            total -= size(of: oldest)
            acknowledge(oldest); dropped += 1
        }
        return dropped
    }

    public func clear() throws {
        for name in batchNames() { acknowledge(name) }
        try? FileManager.default.removeItem(at: rejectedDirectory)
    }

    /// Runs `body` only if no one else drains this spool: a lock on `.lock`, released when `body` returns or throws.
    public func withDrainLock<T: Sendable>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T? {
        let descriptor = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }

    // MARK: files

    private func batchNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(Self.suffix) }.sorted()
    }

    private func size(of name: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func lineCount(_ name: String) -> Int {
        FileManager.default.contents(atPath: directory.appendingPathComponent(name).path)?.reduce(0) { $1 == 10 ? $0 + 1 : $0 } ?? 0
    }

    private static func created(_ name: String) -> Date? {
        name.split(separator: "-").first.flatMap { Int64($0) }.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    private static func decode(_ data: Data) -> [LogEntry]? {
        let decoder = JSONDecoder()
        let rows = data.split(separator: 10, omittingEmptySubsequences: true)
        let entries = rows.compactMap { try? decoder.decode(LogEntry.self, from: Data($0)) }
        return !entries.isEmpty && entries.count == rows.count ? entries : nil
    }

    private final class Counter: @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var value = 0
        static func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
}
