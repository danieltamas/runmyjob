import Testing
import Foundation
@testable import RMJCore

struct RunLoadAcceptanceTests {
    @Test func versionOneUpgradeAddsAveragesAndPreservesExistingJob() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        // Recreate the original job table, independently of the current migration list.
        try await f.database.transaction { database in
            try database.execute("DROP TABLE job")
            try database.execute("""
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
                """)
            try database.execute("CREATE INDEX job_state ON job (state, ended_at)")
            try database.execute("UPDATE schema_version SET version = 1")
        }
        let expected = f.job("legacy", state: .done)
        try await f.ledger.insert(expected)
        let before = try await f.database.query("PRAGMA table_info(job)")
        #expect(!before.contains { $0["name"]?.textValue == "avg_cpu" })
        #expect(!before.contains { $0["name"]?.textValue == "avg_memory_bytes" })

        let reopened = try Database(url: f.directory.appendingPathComponent("ledger.sqlite"))
        let version = try await reopened.query("SELECT version FROM schema_version")
        #expect(version.count == 1)
        #expect(version.first?["version"]?.intValue == 2)
        let columns = try await reopened.query("PRAGMA table_info(job)")
        #expect(columns.first { $0["name"]?.textValue == "avg_cpu" }?["type"]?.textValue == "REAL")
        #expect(columns.first { $0["name"]?.textValue == "avg_memory_bytes" }?["type"]?.textValue == "INTEGER")
        let ledger = Ledger(database: reopened)
        #expect(try await ledger.job(expected.id) == expected)
        #expect(try await ledger.events(expected.id).count == 1)
    }

    @Test func averagesRoundTripThroughAdvanceAndFillWithoutOverwriting() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        for id in ["advance", "fill", "unset", "partial"] {
            try await f.ledger.insert(f.job(id))
        }
        var measured = JobPatch()
        measured.avgCPU = 117.75
        measured.avgMemoryBytes = 5_368_709_120
        #expect(try await f.ledger.advance("advance", to: .done, at: Date(), patch: measured))
        try await f.ledger.fill("fill", patch: measured)
        var cpuOnly = JobPatch()
        cpuOnly.avgCPU = 0
        try await f.ledger.fill("partial", patch: cpuOnly)
        try await f.ledger.fill("partial", patch: measured)
        var replacement = JobPatch()
        replacement.avgCPU = 999
        replacement.avgMemoryBytes = 1
        for id in ["advance", "fill"] {
            try await f.ledger.fill(id, patch: replacement)
        }
        let reader = Ledger(database: try Database(url: f.directory.appendingPathComponent("ledger.sqlite")))
        let jobs = try await reader.jobs()
        #expect(jobs.count == 4)
        for id in ["advance", "fill", "unset", "partial"] {
            let job = try #require(try await reader.job(id))
            #expect(jobs.first { $0.id == id } == job)
            #expect(job.avgCPU == (id == "unset" ? nil : id == "partial" ? 0 : 117.75))
            #expect(job.avgMemoryBytes == (id == "unset" ? nil : 5_368_709_120))
        }
    }

    @Test func finishedPresentationAppendsCompleteAveragesAfterDurationAndWarmth() throws {
        let f = try U2Fixture()
        defer { f.remove() }
        for state in [JobState.done, .failed] {
            var job = f.job("presentation", state: state)
            job.macElapsedMS = 12_000
            job.avgCPU = 117.75
            job.avgMemoryBytes = 536_870_912
            let parts = JobRowPresentation(job, now: job.queuedAt).meta.map(\.text)
            let duration = try #require(parts.firstIndex(of: "12s, mac"))
            let cpu = try #require(parts.firstIndex(of: "avg cpu 118%"))
            let memory = try #require(parts.firstIndex(of: "avg mem " + ByteCountFormatter.string(
                fromByteCount: 536_870_912, countStyle: .memory)))
            #expect(duration < cpu)
            #expect(cpu < memory)
            if state == .done {
                let warmth = try #require(parts.firstIndex(of: "warm"))
                #expect(duration < warmth)
                #expect(warmth < cpu)
            }
            let incomplete: [(Double?, Int64?)] = [(nil, nil), (118, nil), (nil, 536_870_912)]
            for averages in incomplete {
                job.avgCPU = averages.0
                job.avgMemoryBytes = averages.1
                #expect(!JobRowPresentation(job, now: job.queuedAt).meta.contains { $0.text.hasPrefix("avg ") })
            }
        }
    }

    @Test func detailMomentsJoinsQueuedStartedEndedAndBoxTimestamps() throws {
        let f = try U2Fixture()
        defer { f.remove() }
        var job = f.job("moments", state: .done)
        let queued = JobRowPresentation(job, now: job.queuedAt).detail
        #expect(queued.timestamps.count == 1)
        #expect(queued.moments.hasPrefix("queued "))
        #expect(queued.moments == queued.timestamps.joined(separator: "\n"))
        job.startedAt = job.queuedAt.addingTimeInterval(1)
        job.endedAt = job.queuedAt.addingTimeInterval(10)
        job.boxStartedAt = job.queuedAt.addingTimeInterval(2)
        job.boxEndedAt = job.queuedAt.addingTimeInterval(9)
        let detail = JobRowPresentation(job, now: job.queuedAt).detail
        #expect(detail.timestamps.count == 5)
        #expect(detail.moments == detail.timestamps.joined(separator: "\n"))
        let lines = detail.moments.components(separatedBy: "\n")
        for (line, prefix) in zip(lines, ["queued ", "started ", "ended ", "box start ", "box end "]) {
            #expect(line.hasPrefix(prefix))
            #expect(line.hasSuffix(prefix.hasPrefix("box") ? "(box)" : "(mac)"))
        }
    }

    @Test func loadRecorderSamplesARealChildAndImmediateStopIsAllowed() async throws {
        let immediate = LoadRecorder()
        await immediate.start(every: .milliseconds(100))
        _ = await immediate.stop()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["8"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let recorder = LoadRecorder()
        await recorder.start(every: .milliseconds(100))
        try await Task.sleep(for: .seconds(5))
        let load = try #require(await recorder.stop())
        #expect(load.memoryBytes > 0)
    }
}
