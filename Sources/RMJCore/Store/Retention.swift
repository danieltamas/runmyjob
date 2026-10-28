import Foundation

/// Settled jobs and their files expire 30 days after completion. Rows that are queued, syncing,
/// running or lost, or whose log is still pending, are never expired. Files go first and the row
/// last, so a crash leaves a row that points at a missing file, never a file without a row.
public struct Retention: Sendable {
    public static let jobDays = 30
    public static let sampleDays = 7

    public let ledger: Ledger
    public let archive: LogArchive

    public init(ledger: Ledger, archive: LogArchive) {
        self.ledger = ledger
        self.archive = archive
    }

    @discardableResult
    public func prune(now: Date = Date()) async throws -> [String] {
        let database = ledger.database
        let cutoff = Ledger.ms(now.addingTimeInterval(-Double(Self.jobDays) * 86_400))
        let settled = JobState.allCases.filter(\.isSettled).map { SQLValue.text($0.rawValue) }
        let marks = settled.map { _ in "?" }.joined(separator: ", ")
        let expired = try await database.query("""
            SELECT id FROM job WHERE state IN (\(marks)) AND COALESCE(ended_at, (SELECT MAX(at) FROM job_event WHERE job_id = job.id), queued_at) < ?
            AND NOT EXISTS (SELECT 1 FROM log_archive WHERE log_archive.job_id = job.id AND status = 'pending')
            """, settled + [.int(cutoff)]).compactMap { $0["id"]?.textValue }
        for id in expired {
            let logs = try await database.query("SELECT path FROM log_archive WHERE job_id = ?", [.text(id)])
            // A file that cannot be removed keeps its job; the next pass tries again.
            guard logs.allSatisfy({ LogArchive.remove($0["path"]?.textValue) }) else { continue }
            // Including a finished file whose record a crash never wrote.
            // An unreadable directory keeps the job: the next pass looks again.
            guard let present = Self.files(in: archive.directory) else { continue }
            let named = present.filter { $0.lastPathComponent.hasPrefix("\(id).") }
            guard named.allSatisfy({ LogArchive.remove($0.path) }) else { continue }
            // A crash from here on leaves a row that says the file is gone, never one that promises it.
            try await database.execute("UPDATE log_archive SET status = 'unavailable', reason = 'pruned', path = NULL WHERE job_id = ? AND status != 'pending'", [.text(id)])
            try await database.transaction { database in
                // Another process may have queued a pull since the candidates were chosen.
                guard try database.query("SELECT 1 FROM log_archive WHERE job_id = ? AND status = 'pending'", [.text(id)]).isEmpty else { return }
                try database.execute("DELETE FROM log_archive WHERE job_id = ?", [.text(id)])
                try database.execute("DELETE FROM job_event WHERE job_id = ?", [.text(id)])
                try database.execute("DELETE FROM job WHERE id = ?", [.text(id)])
            }
        }
        let sampleCutoff = Ledger.ms(now.addingTimeInterval(-Double(Self.sampleDays) * 86_400))
        try await database.execute("DELETE FROM destination_sample WHERE at < ?", [.int(sampleCutoff)])
        try await sweepOrphans(now: now)
        return expired
    }

    /// Files with no row: a crash between a rename and its record, or a writer that died. A finished log
    /// of a known job is recovered; a stale part file or an unknown file goes.
    func sweepOrphans(now: Date) async throws {
        let known = Set(try await ledger.database.query("SELECT path FROM log_archive WHERE path IS NOT NULL").compactMap { $0["path"]?.textValue.map { URL(fileURLWithPath: $0).lastPathComponent } })
        for row in try await ledger.database.query("SELECT job_id, side, path FROM log_archive WHERE status = 'available' AND path IS NOT NULL") {
            if let path = row["path"]?.textValue, !FileManager.default.fileExists(atPath: path), let id = row["job_id"]?.textValue,
               let side = row["side"]?.textValue {
                try await archive.record(jobID: id, side: side, path: nil, bytes: 0, truncated: false, status: .unavailable,
                                         reason: "pruned: file missing", now: now, replacing: true)
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where !known.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let age = now.timeIntervalSince(modified)
            if file.pathExtension == "part" {
                // A running job's log is kept however quiet it is; only a settled or unknown job's leftover goes.
                let owner = try await ledger.job(file.deletingPathExtension().deletingPathExtension().lastPathComponent)
                if age > 86_400, owner?.state.isSettled ?? true { try? FileManager.default.removeItem(at: file) }
                continue
            }
            // A finished log whose record was never written is recovered when its job exists.
            let id = file.deletingPathExtension().lastPathComponent
            if try await ledger.job(id) != nil, !id.contains("."),
               let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int {
                try await archive.record(jobID: id, side: "box", path: file.path, bytes: size, truncated: Self.endsWithMarker(file),
                                         status: .available, reason: nil, now: now)
            } else if age > 3600 {
                try? FileManager.default.removeItem(at: file)
            }
        }
        try await archive.enforceQuota(now: now)
    }

    private static func endsWithMarker(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 128 ? size - 128 : 0)
        let tail = (try? handle.readToEnd()) ?? Data()
        return String(decoding: tail, as: UTF8.self).hasSuffix(LogArchive.truncationMarker)
    }

    /// nil when the directory exists but cannot be listed; empty when it does not exist yet.
    private static func files(in directory: URL) -> [URL]? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
}
