import Foundation

/// `guard_enabled` in `config.json`: whether `rmj guard` blocks or advises at all. On unless the file says `false`;
/// a missing, unreadable or malformed file leaves the guard on.
public enum GuardSettings {
    static let key = "guard_enabled"

    public static func enabled(home: RMJHome) -> Bool { ConfigFile.flag(ConfigFile.read(home), key, fallback: true) }

    public static func set(_ enabled: Bool, home: RMJHome) throws { try ConfigFile.merge([key: enabled], home: home) }
}

/// What the guard told an agent, kept in `~/.rmj/logs/guard.log` so a block is never invisible: one tab-separated line
/// per block or advice (UTC time, verdict, repo, directory, command). The newest 1000 lines are kept.
public struct GuardLog: Sendable {
    public struct Entry: Sendable, Equatable {
        public let at: Date
        /// `block` or `advise`.
        public let verdict: String
        public let repo: String
        public let directory: String
        public let command: String

        public init(at: Date, verdict: String, repo: String, directory: String, command: String) {
            self.at = at
            self.verdict = verdict
            self.repo = repo
            self.directory = directory
            self.command = command
        }
    }

    private static let keep = 1000, trimAbove = 1200, commandLimit = 400, readWindow = 256 * 1024
    /// A line is never shorter than this, so a smaller file cannot hold more than `trimAbove` lines.
    private static let shortestLine = 30

    let file: URL

    public init(home: RMJHome) { file = home.url.appendingPathComponent("logs/guard.log") }

    /// Never throws: a log that cannot be written must not change what the guard does, nor wait for anything.
    public func append(verdict: String, repo: String, directory: String, command: String, at: Date = Date()) {
        var sanitizer = LogSanitizer()
        let escaped = String(decoding: sanitizer.clean(Data(command.utf8)), as: UTF8.self)
        let line = [Self.stamp(at), verdict, Self.field(repo, 120), Self.field(directory, 400), Self.field(escaped, Self.commandLimit)]
            .joined(separator: "\t") + "\n"
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Appends and the trim's rename must not interleave: a line written to the replaced file would be lost.
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        defer { if lock >= 0 { close(lock) } }
        if lock >= 0 { for _ in 0..<20 where flock(lock, LOCK_EX | LOCK_NB) != 0 { usleep(10_000) } }
        // O_NONBLOCK: a FIFO put in this place must not hold the agent; only a regular file of this user is written.
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { return }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { close(descriptor); return }
        _ = fchmod(descriptor, 0o600)
        let written = line.utf8.withContiguousStorageIfAvailable { write(descriptor, $0.baseAddress, $0.count) } ?? -1
        close(descriptor)
        if written > 0, Int(info.st_size) + written > Self.trimAbove * Self.shortestLine { trim() }
    }

    /// The newest entries first. Only the end of the file is read, a line that cannot be read is skipped, and what is
    /// read is cleaned again: the file is data, whoever wrote it.
    public func recent(limit: Int) -> [Entry] {
        guard limit > 0 else { return [] }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [] }
        let window = min(Int(info.st_size), Self.readWindow)
        var bytes = [UInt8](repeating: 0, count: window)
        guard window > 0, pread(descriptor, &bytes, window, off_t(Int(info.st_size) - window)) == window else { return [] }
        var entries: [Entry] = []
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n").reversed() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5, ["block", "advise"].contains(fields[1]), let at = Self.date(String(fields[0])) else { continue }
            entries.append(Entry(at: at, verdict: String(fields[1]), repo: Self.field(String(fields[2]), 120),
                                 directory: Self.field(String(fields[3]), 400), command: Self.field(String(fields[4]), Self.commandLimit)))
            if entries.count == limit { break }
        }
        return entries
    }

    private func trim() {
        guard let data = FileManager.default.contents(atPath: file.path) else { return }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > Self.trimAbove else { return }
        let kept = Data((lines.suffix(Self.keep).joined(separator: "\n") + "\n").utf8)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".guard.log.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: kept, attributes: [.posixPermissions: 0o600]) else { return }
        _ = rename(temporary.path, file.path)
    }

    /// One line of text: tabs and newlines become spaces, invisible characters go, the length is capped in scalars.
    private static func field(_ text: String, _ limit: Int) -> String {
        UntrustedText.clean(String(String.UnicodeScalarView(text.unicodeScalars.map { $0 == "\t" || $0 == "\n" ? " " : $0 })), limit: limit)
    }

    private static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
}
