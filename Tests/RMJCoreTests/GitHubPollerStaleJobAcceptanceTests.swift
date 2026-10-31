import Testing
import Foundation
import RMJCore

struct GitHubPollerStaleJobAcceptanceTests {
    @Test(arguments: ["in_progress", "queued"])
    func completedRunWaitsForJobsToSettle(status: String) async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let poller = f.poller()
        let marker = "done:\(f.repo):1:1"
        var run = f.run(); run.conclusion = "success"
        var job = f.job(status: status, conclusion: nil)
        await f.api.set(f.repo, runs: [run], jobs: [job])

        _ = try await poller.poll(repo: f.repo)

        let first = try await f.row()
        #expect(first.state == (status == "in_progress" ? .running : .queued))
        #expect(first.endedAt == nil)
        #expect(try await f.ledger.database.query(
            "SELECT key FROM github_poll WHERE key = ?", [.text(marker)]).isEmpty)

        f.clock.advance(15)
        job.status = "completed"; job.conclusion = "success"; job.completedAt = f.clock.now()
        await f.api.set(f.repo, runs: [run], jobs: [job])
        await f.api.clear()

        _ = try await poller.poll(repo: f.repo)

        let settled = try await f.row()
        #expect(settled.id == first.id)
        #expect(settled.state == .done)
        #expect(settled.endedAt == job.completedAt)
        #expect(try await f.info().conclusion == "success")
        #expect(try await f.ledger.jobs().count == 1)
        #expect(try await f.ledger.database.query(
            "SELECT key FROM github_poll WHERE key = ?", [.text(marker)]).count == 1)
        let calls = await f.api.recorded()
        #expect(calls.contains { $0.path == "/repos/\(f.repo)/actions/runs/1/attempts/1/jobs" })
    }

    @Test func existingDoneMarkerDoesNotHideRunningLedgerRow() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        var run = f.run(); run.conclusion = "success"
        let running = f.job(status: "in_progress", conclusion: nil)
        var row = JobRecord(id: GitHubMapping.ledgerID(jobID: 10, attempt: 1), repo: f.repo,
                            command: "CI / check", location: "github-hosted", state: .running,
                            queuedAt: f.clock.now().addingTimeInterval(-20 * 3600))
        row.github = GitHubMapping.info(repo: f.repo, run: run, job: running, observation: nil, parent: nil).json
        try await f.ledger.insert(row)
        try await f.ledger.database.execute(
            "CREATE TABLE IF NOT EXISTS github_poll (key TEXT PRIMARY KEY, etag TEXT, at INTEGER NOT NULL)")
        let marker = "done:\(f.repo):1:1"
        try await f.ledger.database.execute(
            "INSERT INTO github_poll (key, etag, at) VALUES (?, NULL, ?)",
            [.text(marker), .int(Int64(f.clock.now().timeIntervalSince1970 * 1000))])
        #expect(try await f.row().state == .running)
        #expect(try await f.ledger.database.query(
            "SELECT key FROM github_poll WHERE key = ?", [.text(marker)]).count == 1)
        var completed = f.job(); completed.completedAt = f.clock.now()
        await f.api.set(f.repo, runs: [run], jobs: [completed])

        _ = try await f.poller().poll(repo: f.repo)

        let calls = await f.api.recorded()
        #expect(calls.contains { $0.path == "/repos/\(f.repo)/actions/runs/1/attempts/1/jobs" })
        let settled = try await f.row()
        #expect(settled.id == row.id)
        #expect(settled.state == .done)
        #expect(settled.endedAt == completed.completedAt)
        #expect(try await f.info().conclusion == "success")
        #expect(try await f.ledger.jobs().count == 1)
    }

    @Test func doneMarkerSkipsJobsWhenLedgerRowsAreSettled() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let poller = f.poller()
        await f.api.set(f.repo, runs: [f.run()], jobs: [f.job()])
        _ = try await poller.poll(repo: f.repo)
        let settled = try await f.row()
        #expect(settled.state == .done)
        #expect(try await f.ledger.database.query(
            "SELECT key FROM github_poll WHERE key = ?", [.text("done:\(f.repo):1:1")]).count == 1)
        await f.api.clear()

        _ = try await poller.poll(repo: f.repo)

        let calls = await f.api.recorded()
        // No ETag is configured: the run is listed again, exercising the done marker.
        #expect(calls.contains { $0.path == "/repos/\(f.repo)/actions/runs" })
        #expect(!calls.contains { $0.path.hasSuffix("/jobs") })
        #expect(try await f.row() == settled)
    }
}
