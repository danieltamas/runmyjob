import Foundation

/// Migrations run inside the opener's `BEGIN IMMEDIATE`, which is the lock row's job: a second
/// process opening at the same time waits for the first to finish and then finds the version current.
enum Schema {
    static var version: Int { steps.count }

    /// One list per schema version, applied in order; a later version only adds to what the earlier ones made.
    static let steps: [[String]] = [first, [
        "ALTER TABLE job ADD COLUMN avg_cpu REAL",
        "ALTER TABLE job ADD COLUMN avg_memory_bytes INTEGER",
    ]]

    private static let first = [
        """
        CREATE TABLE job (
            id TEXT PRIMARY KEY,
            repo TEXT NOT NULL, command TEXT NOT NULL,
            location TEXT NOT NULL, destination TEXT, fallback_reason TEXT,
            environment TEXT NOT NULL, rule TEXT, warmth TEXT NOT NULL DEFAULT 'unknown',
            state TEXT NOT NULL, exit_code INTEGER,
            queued_at INTEGER NOT NULL, sync_started_at INTEGER, sync_ended_at INTEGER,
            started_at INTEGER, ended_at INTEGER,
            box_started_at INTEGER, box_ended_at INTEGER, box_exit INTEGER,
            mac_elapsed_ms INTEGER, clock_offset_ms INTEGER,
            github TEXT,
            tenant TEXT, worktree TEXT, branch TEXT, commit_sha TEXT, dirty INTEGER NOT NULL DEFAULT 0,
            agent TEXT, session TEXT
        )
        """,
        "CREATE INDEX job_state ON job (state, ended_at)",
        """
        CREATE TABLE job_event (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id TEXT NOT NULL REFERENCES job (id), at INTEGER NOT NULL,
            state TEXT NOT NULL, detail TEXT
        )
        """,
        "CREATE INDEX job_event_job ON job_event (job_id, at, seq)",
        """
        CREATE TABLE destination_sample (
            destination TEXT NOT NULL, at INTEGER NOT NULL, payload TEXT NOT NULL
        )
        """,
        "CREATE INDEX destination_sample_at ON destination_sample (destination, at)",
        """
        CREATE TABLE runner_registration (
            destination TEXT NOT NULL, runner TEXT NOT NULL,
            first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,
            status TEXT NOT NULL, busy INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (destination, runner)
        )
        """,
        """
        CREATE TABLE log_archive (
            job_id TEXT NOT NULL REFERENCES job (id), side TEXT NOT NULL,
            path TEXT, bytes INTEGER NOT NULL DEFAULT 0, truncated INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL, reason TEXT, updated_at INTEGER NOT NULL,
            PRIMARY KEY (job_id, side)
        )
        """,
    ]

    static func apply(_ run: (String) throws -> (rows: [Row], changes: Int)) throws {
        _ = try run("CREATE TABLE IF NOT EXISTS schema_version (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL)")
        let current = try run("SELECT version FROM schema_version").rows.first?["version"]?.intValue ?? 0
        guard current <= version else { throw DatabaseError(code: 1, message: "ledger is from a newer RMJ (schema \(current))") }
        guard current < version else { return }
        for statement in steps.dropFirst(Int(current)).joined() { _ = try run(statement) }
        _ = try run("INSERT OR REPLACE INTO schema_version (id, version) VALUES (1, \(version))")
    }
}
