import Testing
import Foundation
import RMJCore

struct U2Fixture: Sendable {
    let directory: URL
    let database: Database
    var ledger: Ledger { Ledger(database: database) }
    var logs: URL { directory.appendingPathComponent("logs") }
    var archive: LogArchive { LogArchive(database: database, directory: logs, logCap: 4096) }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-u2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try Database(url: directory.appendingPathComponent("ledger.sqlite"))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func job(_ id: String, state: JobState = .queued, at: Date = Date(timeIntervalSince1970: 1000)) -> JobRecord {
        JobRecord(id: id, repo: "owner/repo", command: "test --all", location: "local",
                  destination: "fixture-box", fallbackReason: "fixture fallback", environment: "mac",
                  rule: "fixture-rule", warmth: "warm", state: state, queuedAt: at)
    }
}

struct LedgerAcceptanceTests {
    @Test func concurrentAdvancesNeverRegressAndEventsUseEventTime() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        let other = Ledger(database: try Database(url: f.directory.appendingPathComponent("ledger.sqlite")))
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = t0.addingTimeInterval(1)
        let t2 = t0.addingTimeInterval(2)
        // Exercise both arrival orders explicitly, as well as an unconstrained race.
        for order in 0..<3 {
            let id = "race-\(order)"
            try await f.ledger.insert(f.job(id, at: t0))
            try await withThrowingTaskGroup(of: Void.self) { group in
                if order == 2 {
                    group.addTask { _ = try await f.ledger.advance(id, to: .running, at: t1) }
                    group.addTask { _ = try await other.advance(id, to: .done, at: t2) }
                    try await group.waitForAll()
                } else {
                    group.addTask { _ = try await f.ledger.advance(id, to: order == 0 ? .running : .done, at: order == 0 ? t1 : t2) }
                    try await group.waitForAll()
                    group.addTask { _ = try await other.advance(id, to: order == 0 ? .done : .running, at: order == 0 ? t2 : t1) }
                    try await group.waitForAll()
                }
            }
            #expect(try await other.job(id)?.state == .done)
            #expect(try await f.ledger.advance(id, to: .running, at: t1, detail: "late") == false)
            #expect(try await f.ledger.job(id)?.state == .done)
            let events = try await other.events(id)
            #expect(events.map(\.at) == [t0, t1, t1, t2])
            #expect(events.map(\.state) == [.queued, .running, .running, .done])
            #expect(events.filter { $0.detail == "late" }.count == 1)
        }
    }

    @Test func wholeStateMachineAndPatchesOnlyMoveForward() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        let t = Date(timeIntervalSince1970: 2000)
        try await f.ledger.insert(f.job("forward"))
        for state in [JobState.syncing, .running, .done] {
            #expect(try await f.ledger.advance("forward", to: state, at: t))
        }
        var poison = JobPatch()
        poison.exitCode = 91
        poison.endedAt = t
        poison.boxStartedAt = t
        poison.boxEndedAt = t
        poison.startedAt = t
        poison.syncStartedAt = t
        poison.syncEndedAt = t
        poison.boxExit = 92
        poison.macElapsedMS = 93
        poison.clockOffsetMS = 94
        poison.github = "ignored"
        let before = try await f.ledger.job("forward")
        #expect(try await f.ledger.advance("forward", to: .failed, at: t, patch: poison) == false)
        #expect(try await f.ledger.job("forward") == before)
        try await f.ledger.insert(f.job("reconcile", state: .running))
        #expect(try await f.ledger.advance("reconcile", to: .lost, at: t))
        #expect(try await f.ledger.advance("reconcile", to: .done, at: t, patch: poison))
        #expect(try await f.ledger.job("reconcile")?.exitCode == 91)
        #expect(try await f.ledger.job("reconcile")?.boxStartedAt == t)
        try await f.ledger.insert(f.job("failed", state: .failed))
        let failed = try await f.ledger.job("failed")
        #expect(try await f.ledger.advance("failed", to: .lost, at: t, patch: poison) == false)
        #expect(try await f.ledger.job("failed") == failed)
        // Every state rejects itself and all predecessors; settled outcomes cannot replace each other.
        let rank: [JobState: Int] = [.queued: 0, .syncing: 1, .running: 2, .lost: 3,
                                     .done: 4, .failed: 4, .cancelled: 4, .skipped: 4]
        for from in JobState.allCases {
            for to in JobState.allCases {
                let id = "\(from.rawValue)-\(to.rawValue)"
                try await f.ledger.insert(f.job(id, state: from))
                let moves = rank[to]! > rank[from]!
                #expect(try await f.ledger.advance(id, to: to, at: t, patch: poison) == moves)
                let row = try #require(try await f.ledger.job(id))
                #expect(row.state == (moves ? to : from))
                #expect(row.exitCode == (moves ? 91 : nil))
                #expect(row.endedAt == (moves ? t : nil))
            }
        }
    }

    @Test func simultaneousOpenMigratesOnceAndNewerSchemaThrows() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        let url = f.directory.appendingPathComponent("simultaneous.sqlite")
        let databases = try await withThrowingTaskGroup(of: Database.self) { group in
            for _ in 0..<2 { group.addTask { try Database(url: url) } }
            var result: [Database] = []
            for try await database in group { result.append(database) }
            return result
        }
        for database in databases {
            let rows = try await database.query("SELECT version FROM schema_version")
            #expect(rows.count == 1)
            #expect(rows.first?["version"]?.intValue == 2)
        }
        try await databases[0].execute("UPDATE schema_version SET version = 99")
        #expect(throws: DatabaseError.self) { _ = try Database(url: url) }
    }

    @Test func durationUsesBoxThenMacThenUnknown() throws {
        let f = try U2Fixture()
        defer { f.remove() }
        var job = f.job("duration")
        #expect(job.duration == .unknown)
        job.macElapsedMS = -1
        #expect(job.duration == .unknown)
        job.macElapsedMS = 765
        job.boxStartedAt = Date(timeIntervalSince1970: 10)
        job.boxEndedAt = Date(timeIntervalSince1970: 12.345)
        #expect(job.duration == .box(milliseconds: 2345))
        job.boxEndedAt = Date(timeIntervalSince1970: 9)
        #expect(job.duration == .mac(milliseconds: 765))
        job.macElapsedMS = nil
        #expect(job.duration == .unknown)
    }

    @Test func retentionPrunesOnlyExpiredSettledJobsWithoutPendingLogs() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cases: [(String, JobState, Int)] = [("old", .done, 31), ("recent", .done, 29),
            ("lost", .lost, 40), ("queued", .queued, 40), ("running", .running, 40), ("pending", .failed, 31)]
        for (id, state, days) in cases {
            let at = now.addingTimeInterval(-Double(days) * 86400)
            try await f.ledger.insert(f.job(id, at: at))
            if state != .queued {
                var patch = JobPatch()
                patch.endedAt = at
                try await f.ledger.advance(id, to: state, at: at, patch: patch)
            }
            if id == "pending" {
                try await f.archive.markPending(jobID: id, now: at)
            } else {
                let writer = try f.archive.writer(jobID: id, secrets: [])
                await writer.write(Data(id.utf8))
                try await writer.finish(complete: true, now: at)
            }
        }
        for days in [8, 6] {
            let at = Int64(now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 * 1000)
            try await f.database.execute("INSERT INTO destination_sample (destination, at, payload) VALUES (?, ?, ?)",
                                         [.text("box"), .int(at), .text("sample-\(days)")])
        }
        let removed = try await Retention(ledger: f.ledger, archive: f.archive).prune(now: now)
        #expect(removed == ["old"])
        #expect(try await f.ledger.job("old") == nil)
        #expect(try await f.ledger.events("old").isEmpty)
        #expect(try await f.database.query("SELECT * FROM log_archive WHERE job_id = 'old'").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.logs.appendingPathComponent("old.log").path))
        for id in ["recent", "lost", "queued", "running", "pending"] {
            #expect(try await f.ledger.job(id) != nil)
        }
        #expect(FileManager.default.fileExists(atPath: f.logs.appendingPathComponent("recent.log").path))
        #expect(try await f.archive.entry(jobID: "pending")?.status == .pending)
        #expect(try await f.ledger.needingReconcile().map(\.id) == ["lost"])
        let samples = try await f.database.query("SELECT payload FROM destination_sample")
        #expect(samples.count == 1)
        #expect(samples.first?["payload"]?.textValue == "sample-6")
    }

    @Test func duplicateInsertThrowsAndEveryJobFieldRoundTrips() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        var expected = f.job("roundtrip", at: Date(timeIntervalSince1970: 1000.123))
        try await f.ledger.insert(expected)
        await #expect(throws: DatabaseError.self) { try await f.ledger.insert(expected) }
        var patch = JobPatch()
        patch.exitCode = 7
        patch.syncStartedAt = Date(timeIntervalSince1970: 1001.123)
        patch.syncEndedAt = Date(timeIntervalSince1970: 1002.234)
        patch.startedAt = Date(timeIntervalSince1970: 1003.345)
        patch.endedAt = Date(timeIntervalSince1970: 1004.456)
        patch.boxStartedAt = Date(timeIntervalSince1970: 1005.567)
        patch.boxEndedAt = Date(timeIntervalSince1970: 1006.678)
        patch.boxExit = 8
        patch.macElapsedMS = 1111
        patch.clockOffsetMS = -222
        patch.github = "{\"run_id\":123}"
        #expect(try await f.ledger.advance(expected.id, to: .failed, at: patch.endedAt!, patch: patch))
        expected.state = .failed
        expected.exitCode = patch.exitCode
        expected.syncStartedAt = patch.syncStartedAt
        expected.syncEndedAt = patch.syncEndedAt
        expected.startedAt = patch.startedAt
        expected.endedAt = patch.endedAt
        expected.boxStartedAt = patch.boxStartedAt
        expected.boxEndedAt = patch.boxEndedAt
        expected.boxExit = patch.boxExit
        expected.macElapsedMS = patch.macElapsedMS
        expected.clockOffsetMS = patch.clockOffsetMS
        expected.github = patch.github
        #expect(try await f.ledger.job(expected.id) == expected)
    }
}
