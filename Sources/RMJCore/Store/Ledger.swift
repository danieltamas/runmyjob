import Foundation

/// The job ledger: one row per job, an event per state change, every change one transaction.
public struct Ledger: Sendable {
    public let database: Database
    /// Known secret values (the Keychain PATs): scrubbed from every free-text field before it is stored.
    private let secrets: [String]

    public init(database: Database, secrets: [String] = []) {
        self.database = database
        self.secrets = secrets
    }

    private func scrub(_ text: String) -> String { SecretRedactor.scrub(text, secrets: secrets) }
    private func scrub(_ text: String?) -> String? { text.map(scrub) }

    public func insert(_ job: JobRecord) async throws {
        try await database.transaction { database in
            try database.execute("""
                INSERT INTO job (id, repo, command, location, destination, fallback_reason, environment, rule, warmth, state, exit_code,
                    queued_at, sync_started_at, sync_ended_at, started_at, ended_at, box_started_at, box_ended_at, box_exit,
                    mac_elapsed_ms, clock_offset_ms, github, tenant, worktree, branch, commit_sha, dirty, agent, session)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(job.id), .text(scrub(job.repo)), .text(scrub(job.command)), .text(scrub(job.location)),
                      .optional(scrub(job.destination)), .optional(scrub(job.fallbackReason)), .text(scrub(job.environment)),
                      .optional(scrub(job.rule)), .text(scrub(job.warmth)), .text(job.state.rawValue),
                      .optional(job.exitCode.map(Int64.init)), .int(Self.ms(job.queuedAt)), .optional(Self.ms(job.syncStartedAt)),
                      .optional(Self.ms(job.syncEndedAt)), .optional(Self.ms(job.startedAt)), .optional(Self.ms(job.endedAt)),
                      .optional(Self.ms(job.boxStartedAt)), .optional(Self.ms(job.boxEndedAt)), .optional(job.boxExit.map(Int64.init)),
                      .optional(job.macElapsedMS.map(Int64.init)), .optional(job.clockOffsetMS.map(Int64.init)), .optional(scrub(job.github)),
                      .optional(scrub(job.tenant)), .optional(scrub(job.worktree)), .optional(scrub(job.branch)), .optional(scrub(job.commit)),
                      .int(job.dirty ? 1 : 0), .optional(scrub(job.agent)), .optional(scrub(job.session))])
            try database.execute("INSERT INTO job_event (job_id, at, state, detail) VALUES (?, ?, ?, NULL)",
                                 [.text(job.id), .int(Self.ms(job.endedAt ?? job.queuedAt)), .text(job.state.rawValue)])
        }
    }

    /// Moves the job to `state` when that is forward of where it is; the event is recorded either way
    /// so the history keeps what was reported, ordered by the event's own time. The precondition is in
    /// the UPDATE, so two processes racing cannot both win. Returns whether the row moved.
    @discardableResult
    public func advance(_ id: String, to state: JobState, at: Date, detail: String? = nil, patch: JobPatch = JobPatch()) async throws -> Bool {
        let columns = Self.columns(patch, scrub: scrub)
        let set = columns.filter { $0.1 != .null }
        let assignments = (["state = ?"] + set.map { "\($0.0) = ?" }).joined(separator: ", ")
        let detail = scrub(detail)
        let allowed = JobState.below(state).map(\.rawValue)
        let marks = allowed.map { _ in "?" }.joined(separator: ", ")
        let arguments = [.text(state.rawValue)] + set.map(\.1) + [.text(id)] + allowed.map(SQLValue.text)
        return try await database.transaction { database in
            let moved = try database.execute("UPDATE job SET \(assignments) WHERE id = ? AND state IN (\(marks))", arguments) == 1
            try database.execute("INSERT INTO job_event (job_id, at, state, detail) VALUES (?, ?, ?, ?)",
                                 [.text(id), .int(Self.ms(at)), .text(state.rawValue), .optional(detail)])
            return moved
        }
    }

    /// Reconcile adds what a settled row lacked (the box's own times and exit): only empty columns are
    /// filled, so a value already recorded is never rewritten and the state never moves.
    public func fill(_ id: String, patch: JobPatch) async throws {
        let set = Self.columns(patch, scrub: scrub).filter { $0.1 != .null }
        guard !set.isEmpty else { return }
        try await database.execute("UPDATE job SET \(set.map { "\($0.0) = COALESCE(\($0.0), ?)" }.joined(separator: ", ")) WHERE id = ?",
                                   set.map(\.1) + [.text(id)])
    }

    /// The GitHub side of a row changes while the job runs (step, runner, observation); the newest poll wins.
    /// A destination, once the runner is known, replaces the `self-hosted` placeholder location.
    public func setGitHub(_ id: String, _ json: String?, destination: String? = nil) async throws {
        try await database.execute("""
            UPDATE job SET github = ?, destination = COALESCE(?, destination),
                location = CASE WHEN ? IS NOT NULL AND location IN ('self-hosted', 'github-hosted') THEN ? ELSE location END WHERE id = ?
            """, [.optional(scrub(json)), .optional(scrub(destination)), .optional(scrub(destination)), .optional(scrub(destination)), .text(id)])
    }

    /// A job that could not start where it was routed runs on the Mac instead: only a job that has not
    /// started running moves, and the reason is recorded.
    @discardableResult
    public func relocate(_ id: String, toLocalBecause reason: String, at: Date) async throws -> Bool {
        let reason = scrub(reason)
        return try await database.transaction { database in
            let moved = try database.execute("UPDATE job SET location = 'local', destination = NULL, fallback_reason = ?, environment = 'mac' "
                                             + "WHERE id = ? AND state IN ('queued', 'syncing', 'lost')", [.text(reason), .text(id)]) == 1
            if moved {
                try database.execute("INSERT INTO job_event (job_id, at, state, detail) VALUES (?, ?, 'queued', ?)",
                                     [.text(id), .int(Self.ms(at)), .text("running locally: " + reason)])
            }
            return moved
        }
    }

    public func job(_ id: String) async throws -> JobRecord? {
        try await database.query("SELECT * FROM job WHERE id = ?", [.text(id)]).first.flatMap(Self.record)
    }

    public func jobs(in states: [JobState]? = nil) async throws -> [JobRecord] {
        let marks = (states ?? JobState.allCases).map { _ in "?" }.joined(separator: ", ")
        let rows = try await database.query("SELECT * FROM job WHERE state IN (\(marks)) ORDER BY queued_at DESC, id",
                                            (states ?? JobState.allCases).map { .text($0.rawValue) })
        return rows.compactMap(Self.record)
    }

    /// Jobs a reconcile must look at: the Mac lost track of them and they are never expired.
    public func needingReconcile() async throws -> [JobRecord] { try await jobs(in: [.lost]) }

    public struct Event: Sendable, Equatable {
        public let at: Date
        public let state: JobState
        public let detail: String?
    }

    /// By the event's own timestamp, then by arrival.
    public func events(_ id: String) async throws -> [Event] {
        try await database.query("SELECT at, state, detail FROM job_event WHERE job_id = ? ORDER BY at, seq", [.text(id)]).compactMap { row in
            guard let at = row["at"]?.intValue, let state = row["state"]?.textValue.flatMap(JobState.init) else { return nil }
            return Event(at: Self.date(at), state: state, detail: row["detail"]?.textValue)
        }
    }

    private static func columns(_ patch: JobPatch, scrub: (String?) -> String?) -> [(String, SQLValue)] {
        [
            ("exit_code", .optional(patch.exitCode.map(Int64.init))), ("sync_started_at", .optional(Self.ms(patch.syncStartedAt))),
            ("sync_ended_at", .optional(Self.ms(patch.syncEndedAt))), ("started_at", .optional(Self.ms(patch.startedAt))),
            ("ended_at", .optional(Self.ms(patch.endedAt))), ("box_started_at", .optional(Self.ms(patch.boxStartedAt))),
            ("box_ended_at", .optional(Self.ms(patch.boxEndedAt))), ("box_exit", .optional(patch.boxExit.map(Int64.init))),
            ("mac_elapsed_ms", .optional(patch.macElapsedMS.map(Int64.init))), ("clock_offset_ms", .optional(patch.clockOffsetMS.map(Int64.init))),
            ("github", .optional(scrub(patch.github))),
        ]
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func ms(_ date: Date?) -> Int64? { date.map(ms) }
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}

extension Ledger {
    static func record(_ row: Row) -> JobRecord? {
        guard let id = row["id"]?.textValue, let repo = row["repo"]?.textValue, let command = row["command"]?.textValue,
              let location = row["location"]?.textValue, let environment = row["environment"]?.textValue,
              let state = row["state"]?.textValue.flatMap(JobState.init), let queued = row["queued_at"]?.intValue else { return nil }
        func date(_ key: String) -> Date? { row[key]?.intValue.map(Self.date) }
        func int(_ key: String) -> Int? { row[key]?.intValue.map(Int.init) }
        var job = JobRecord(id: id, repo: repo, command: command, location: location, destination: row["destination"]?.textValue,
                            fallbackReason: row["fallback_reason"]?.textValue, environment: environment, rule: row["rule"]?.textValue,
                            warmth: row["warmth"]?.textValue ?? "unknown", state: state, queuedAt: Self.date(queued))
        job.exitCode = int("exit_code")
        job.syncStartedAt = date("sync_started_at")
        job.syncEndedAt = date("sync_ended_at")
        job.startedAt = date("started_at")
        job.endedAt = date("ended_at")
        job.boxStartedAt = date("box_started_at")
        job.boxEndedAt = date("box_ended_at")
        job.boxExit = int("box_exit")
        job.macElapsedMS = int("mac_elapsed_ms")
        job.clockOffsetMS = int("clock_offset_ms")
        job.github = row["github"]?.textValue
        job.tenant = row["tenant"]?.textValue
        job.worktree = row["worktree"]?.textValue
        job.branch = row["branch"]?.textValue
        job.commit = row["commit_sha"]?.textValue
        job.dirty = row["dirty"]?.intValue == 1
        job.agent = row["agent"]?.textValue
        job.session = row["session"]?.textValue
        return job
    }
}
