import Foundation

/// The cleaner's trail in the ledger: one row per run, one per item, kept 90 days.
extension Ledger {
    public static let cleanRunDays = 90

    func record(_ run: CleanRun) async throws {
        try await database.transaction { database in
            try database.execute("INSERT INTO clean_run (id, started_at, finished_at, apply, freed_bytes, problem) VALUES (?, ?, ?, ?, ?, ?)",
                                 [.text(run.id), .int(Self.ms(run.startedAt)), .int(Self.ms(run.finishedAt)), .int(run.apply ? 1 : 0),
                                  .int(Int64(run.freedBytes)), .optional(run.problem)])
            for item in run.items {
                try database.execute("INSERT INTO clean_item (run_id, path, kind, action, reason, bytes, at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                     [.text(run.id), .text(item.path), .text(item.kind.rawValue), .text(item.action.rawValue),
                                      .text(item.reason), .int(Int64(item.bytes)), .int(Self.ms(run.finishedAt))])
            }
        }
    }

    public func cleanItems(run id: String) async throws -> [CleanItem] {
        try await database.query("SELECT path, kind, action, reason, bytes FROM clean_item WHERE run_id = ? ORDER BY rowid", [.text(id)]).compactMap { row in
            guard let path = row["path"]?.textValue, let kind = row["kind"]?.textValue.flatMap(CleanTarget.Kind.init),
                  let action = row["action"]?.textValue.flatMap(CleanAction.init) else { return nil }
            return CleanItem(path: path, kind: kind, action: action, reason: row["reason"]?.textValue ?? "", bytes: Int(row["bytes"]?.intValue ?? 0))
        }
    }

    /// The newest runs first, each with its items.
    public func cleanRuns(limit: Int) async throws -> [CleanRun] {
        try await cleanRuns(where: "1 = 1", [], limit: limit)
    }

    public func cleanRun(id: String) async throws -> CleanRun? {
        try await cleanRuns(where: "id = ?", [.text(id)], limit: 1).first
    }

    private func cleanRuns(where condition: String, _ values: [SQLValue], limit: Int) async throws -> [CleanRun] {
        var runs = [CleanRun]()
        for row in try await database.query("SELECT id, started_at, finished_at, apply, problem FROM clean_run WHERE \(condition) ORDER BY started_at DESC, id DESC LIMIT ?",
                                            values + [.int(Int64(limit))]) {
            guard let id = row["id"]?.textValue, let started = row["started_at"]?.intValue, let finished = row["finished_at"]?.intValue else { continue }
            runs.append(CleanRun(id: id, startedAt: Self.date(started), finishedAt: Self.date(finished), apply: row["apply"]?.intValue == 1,
                                 items: try await cleanItems(run: id), problem: row["problem"]?.textValue))
        }
        return runs
    }

    func pruneCleanRuns(now: Date) async throws {
        let cutoff = Self.ms(now.addingTimeInterval(-Double(Self.cleanRunDays) * 86_400))
        try await database.transaction { database in
            try database.execute("DELETE FROM clean_item WHERE run_id IN (SELECT id FROM clean_run WHERE started_at < ?)", [.int(cutoff)])
            try database.execute("DELETE FROM clean_run WHERE started_at < ?", [.int(cutoff)])
        }
    }
}
