import Foundation

public struct LogEntry: Sendable, Equatable {
    public enum Status: String, Sendable { case pending, available, unavailable }

    public let jobID: String
    public let side: String
    public let path: String?
    public let bytes: Int
    public let truncated: Bool
    public let status: Status
    public let reason: String?
}

/// The Mac-side copy of every run's log: `~/.rmj/logs/<job-id>.log`. A log is written to a `.part`
/// file and renamed when complete, so a running log is never taken for the final one.
public struct LogArchive: Sendable {
    public static let perLogCap = 50 * 1024 * 1024
    public static let quota = 2 * 1024 * 1024 * 1024
    static let truncationMarker = "\n[rmj: log truncated at 50 MB]\n"

    public enum Failure: Error, Equatable { case invalidJobID }

    public let database: Database
    public let directory: URL
    let logCap: Int
    let quotaBytes: Int
    private let secrets: [String]

    public init(database: Database, directory: URL, logCap: Int = perLogCap, quotaBytes: Int = quota, secrets: [String] = []) {
        self.database = database
        self.directory = directory
        self.logCap = logCap
        self.quotaBytes = quotaBytes
        self.secrets = secrets
    }

    /// Opens a writer; the stream goes through the redactor before the first byte reaches the disk.
    public func writer(jobID: String, side: String = "box", secrets: [String], now: Date = Date()) throws -> LogWriter {
        let final = try path(jobID: jobID, side: side)
        try prepareDirectory()
        let part = final.appendingPathExtension("part")
        // A leftover (or planted) file is replaced, never reopened with its old mode.
        unlink(part.path)
        let descriptor = open(part.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DatabaseError(code: errno, message: "cannot open the log file") }
        return LogWriter(archive: self, jobID: jobID, side: side, final: final, part: part,
                         handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                         redactor: SecretRedactor(secrets: self.secrets + secrets), cap: logCap)
    }

    /// The log directory is a real directory of this user, mode 0700: a symlink in its place is refused.
    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw DatabaseError(code: errno, message: "cannot create the log directory") }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw DatabaseError(code: ENOTDIR, message: "the log directory is not a private directory")
        }
        guard chmod(directory.path, 0o700) == 0 else { throw DatabaseError(code: errno, message: "cannot restrict the log directory") }
    }

    /// A log that has to be pulled; stays `pending` until a pull succeeds.
    public func markPending(jobID: String, side: String = "box", reason: String? = nil, replacing: Bool = false, now: Date = Date()) async throws {
        _ = try path(jobID: jobID, side: side)
        try await record(jobID: jobID, side: side, path: nil, bytes: 0, truncated: false, status: .pending, reason: reason, now: now, replacing: replacing)
    }

    public func markUnavailable(jobID: String, side: String = "box", reason: String, now: Date = Date()) async throws {
        _ = try path(jobID: jobID, side: side)
        try await record(jobID: jobID, side: side, path: nil, bytes: 0, truncated: false, status: .unavailable, reason: reason, now: now)
    }

    public func entry(jobID: String, side: String = "box") async throws -> LogEntry? {
        try await database.query("SELECT * FROM log_archive WHERE job_id = ? AND side = ?", [.text(jobID), .text(side)]).first.flatMap(Self.entry)
    }

    public func pending() async throws -> [LogEntry] {
        try await database.query("SELECT * FROM log_archive WHERE status = 'pending' ORDER BY updated_at").compactMap(Self.entry)
    }

    /// A completed log is replaced only by another completed log (`replacing`), never by a late
    /// pending or unavailable note, which would discard its file reference.
    /// A log pulled from a run that did not finish (the box rebooted) is a partial one.
    public func markTruncated(jobID: String, side: String = "box") async throws {
        try await database.execute("UPDATE log_archive SET truncated = 1 WHERE job_id = ? AND side = ?", [.text(jobID), .text(side)])
    }

    func record(jobID: String, side: String, path: String?, bytes: Int, truncated: Bool, status: LogEntry.Status,
                reason: String?, now: Date, replacing: Bool = false) async throws {
        let guardClause = replacing || status == .available ? "" : " WHERE log_archive.status != 'available'"
        try await database.execute("""
            INSERT INTO log_archive (job_id, side, path, bytes, truncated, status, reason, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (job_id, side) DO UPDATE SET path = excluded.path, bytes = excluded.bytes, truncated = excluded.truncated,
                status = excluded.status, reason = excluded.reason, updated_at = excluded.updated_at\(guardClause)
            """, [.text(jobID), .text(side), .optional(path), .int(Int64(bytes)), .int(truncated ? 1 : 0),
                  .text(status.rawValue), .optional(reason.map { SecretRedactor.scrub($0, secrets: secrets) }), .int(Ledger.ms(now))])
    }

    /// Oldest completed logs go first until the archive fits its quota.
    func enforceQuota(now: Date) async throws {
        // Oldest by the job's completion, not by when its log was fetched.
        let rows = try await database.query("""
            SELECT log_archive.* FROM log_archive JOIN job ON job.id = log_archive.job_id
            WHERE log_archive.status = 'available' AND job.state IN ('done', 'failed', 'cancelled', 'skipped') ORDER BY COALESCE(job.ended_at, job.queued_at), log_archive.updated_at
            """)
        var entries = rows.compactMap(Self.entry)
        // Every available log counts toward the quota; only a settled job's log may be evicted.
        var total = Int(try await database.query("SELECT COALESCE(SUM(bytes), 0) AS total FROM log_archive WHERE status = 'available'").first?["total"]?.intValue ?? 0)
        while total > quotaBytes, !entries.isEmpty {
            let oldest = entries.removeFirst()
            // A file that cannot be removed still counts against the quota and keeps its row.
            guard Self.remove(oldest.path) else { continue }
            try await record(jobID: oldest.jobID, side: oldest.side, path: nil, bytes: 0, truncated: false,
                             status: .unavailable, reason: "pruned: quota", now: now, replacing: true)
            total -= oldest.bytes
        }
    }

    /// True when the file is gone afterwards (also when it was already).
    static func remove(_ path: String?) -> Bool {
        guard let path else { return true }
        do { try FileManager.default.removeItem(atPath: path) } catch { return (error as NSError).code == NSFileNoSuchFileError }
        return true
    }

    /// Job ids are ULIDs; anything that could name another path is refused.
    func path(jobID: String, side: String) throws -> URL {
        func plain(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) } }
        guard plain(jobID), plain(side) else { throw Failure.invalidJobID }
        return directory.appendingPathComponent(side == "box" || side == "local" ? "\(jobID).log" : "\(jobID).\(side).log")
    }

    static func entry(_ row: Row) -> LogEntry? {
        guard let jobID = row["job_id"]?.textValue, let side = row["side"]?.textValue,
              let status = row["status"]?.textValue.flatMap(LogEntry.Status.init) else { return nil }
        return LogEntry(jobID: jobID, side: side, path: row["path"]?.textValue, bytes: Int(row["bytes"]?.intValue ?? 0),
                        truncated: row["truncated"]?.intValue == 1, status: status, reason: row["reason"]?.textValue)
    }
}

public actor LogWriter {
    private let archive: LogArchive
    private let jobID: String
    private let side: String
    private let final: URL
    private let part: URL
    private let handle: FileHandle
    private var redactor: SecretRedactor
    private let cap: Int
    private var written = 0
    private var truncated = false
    private var failure: String?

    init(archive: LogArchive, jobID: String, side: String, final: URL, part: URL, handle: FileHandle, redactor: SecretRedactor, cap: Int) {
        self.archive = archive
        self.jobID = jobID
        self.side = side
        self.final = final
        self.part = part
        self.handle = handle
        self.redactor = redactor
        self.cap = cap
    }

    public func write(_ chunk: Data) {
        append(redactor.process(chunk))
    }

    /// Completes the log (`complete`) or abandons a partial one. Returns the stored entry.
    @discardableResult
    public func finish(complete: Bool, now: Date = Date()) async throws -> LogEntry? {
        if complete { append(redactor.flush()) }
        // Contents reach the disk before the final name does, and a failed flush is a failed log.
        do {
            try handle.synchronize()
            try handle.close()
        } catch where failure == nil {
            failure = "write failed: \(error.localizedDescription)"
        } catch {}
        if let failure {
            try? FileManager.default.removeItem(at: part)
            try await archive.markUnavailable(jobID: jobID, side: side, reason: failure, now: now)
        } else if complete {
            // rename(2) replaces atomically: the old log stays until the new one is in place.
            guard rename(part.path, final.path) == 0 else {
                throw DatabaseError(code: errno, message: "cannot publish the log")
            }
            try await archive.record(jobID: jobID, side: side, path: final.path, bytes: written, truncated: truncated,
                                     status: .available, reason: nil, now: now)
            try await archive.enforceQuota(now: now)
        } else {
            try? FileManager.default.removeItem(at: part)
        }
        return try await archive.entry(jobID: jobID, side: side)
    }

    private func append(_ data: Data) {
        guard failure == nil, !truncated, !data.isEmpty else { return }
        let room = cap - written
        let slice = data.count <= room ? data : data.prefix(max(0, room))
        do {
            try handle.write(contentsOf: slice)
            written += slice.count
            if data.count > room {
                let marker = Data(LogArchive.truncationMarker.utf8)
                try handle.write(contentsOf: marker)
                written += marker.count
                truncated = true
            }
        } catch {
            failure = Self.isDiskFull(error) ? "disk full" : "write failed: \(error.localizedDescription)"
        }
    }

    private static func isDiskFull(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return true }
        return (nsError.userInfo[NSUnderlyingErrorKey] as? Error).map(isDiskFull) ?? false
    }
}
