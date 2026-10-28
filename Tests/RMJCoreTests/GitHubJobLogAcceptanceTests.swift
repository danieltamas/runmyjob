import Foundation
import Testing
import RMJCore

private struct GitHubLogFixture {
    let home: RMJHome
    let ledger: Ledger
    let archive: LogArchive
    let id = "gh-77-1"

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-github-log-\(UUID())")
        home = RMJHome(environment: ["RMJ_HOME": root.path])
        try home.prepare()
        let database = try Database(url: root.appendingPathComponent("rmj.sqlite"))
        ledger = Ledger(database: database)
        archive = LogArchive(database: database, directory: root.appendingPathComponent("logs"))
    }

    func remove() { try? FileManager.default.removeItem(at: home.url) }
    func log(_ jobID: String) -> URL { archive.directory.appendingPathComponent("\(jobID).log") }

    func insert(state: JobState = .done, github: Bool = true) async throws -> String {
        let jobID = github ? id : "local-77"
        var row = JobRecord(id: jobID, repo: "acme/ledger", command: "CI", location: "box-a",
                            destination: "box-a", state: state,
                            queuedAt: Date(timeIntervalSince1970: 1_793_145_600))
        if github {
            let run = GHRun(id: 9, name: "CI", status: state == .running ? "in_progress" : "completed", runAttempt: 1)
            let job = GHJob(id: 77, runId: 9, runAttempt: 1, name: "check",
                            status: state == .running ? "in_progress" : "completed",
                            conclusion: state == .running ? nil : "success", labels: ["self-hosted"])
            row.github = GitHubMapping.info(repo: "acme/ledger", run: run, job: job,
                                            observation: nil, parent: nil).json
            _ = try #require(GitHubJobInfo.decode(row.github))
        }
        try await ledger.insert(row)
        return jobID
    }
}

private actor GitHubLogFetchCalls {
    private var count = 0
    func record() { count += 1 }
    func total() -> Int { count }
}

private struct GitHubLogFetchFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct GitHubJobLogAcceptanceTests {
    @Test("A finished GitHub log uses the repo job id and org token and becomes available")
    func archivesFinishedLog() async throws {
        let f = try GitHubLogFixture()
        defer { f.remove() }
        let id = try await f.insert()
        let calls = GitHubLogFetchCalls()
        let bytes = Data("check started\ncheck passed\n".utf8)
        let problem = await GitHubJobLog.archive(ledgerID: id, ledger: f.ledger, archive: f.archive,
                                                secrets: [], token: { org in
            #expect(org == "acme")
            return org == "acme" ? "acme-org-token" : nil
        }, fetch: { repo, jobID, token in
            await calls.record()
            #expect(repo == "acme/ledger")
            #expect(jobID == 77)
            #expect(token == "acme-org-token")
            return bytes
        })
        #expect(problem == nil)
        #expect(await calls.total() == 1)
        #expect(try Data(contentsOf: f.log(id)) == bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.log(id).path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        let entry = try #require(try await f.archive.entry(jobID: id, side: "local"))
        #expect(entry.status == .available)
        #expect(entry.path == f.log(id).path)
        #expect(entry.bytes == bytes.count)
    }

    @Test("Fetched log bytes are scrubbed of supplied secrets before archiving")
    func redactsSecret() async throws {
        let f = try GitHubLogFixture()
        defer { f.remove() }
        let id = try await f.insert()
        let secret = "acme-private-credential-12345"
        let problem = await GitHubJobLog.archive(ledgerID: id, ledger: f.ledger, archive: f.archive,
                                                secrets: [secret], fetch: { _, _, _ in
            Data("before \(secret) after\n".utf8)
        })
        #expect(problem == nil)
        let text = try String(contentsOf: f.log(id), encoding: .utf8)
        #expect(text.contains(secret) == false)
        #expect(text.contains("before "))
        #expect(text.contains(" after"))
        #expect(try await f.archive.entry(jobID: id, side: "local")?.status == .available)
    }

    @Test("A running GitHub job is refused without fetching or writing a final log")
    func refusesRunningJob() async throws {
        let f = try GitHubLogFixture()
        defer { f.remove() }
        let id = try await f.insert(state: .running)
        let calls = GitHubLogFetchCalls()
        let problem = await GitHubJobLog.archive(ledgerID: id, ledger: f.ledger, archive: f.archive,
                                                secrets: [], fetch: { _, _, _ in
            await calls.record()
            return Data("unexpected log".utf8)
        })
        #expect(problem != nil)
        #expect(await calls.total() == 0)
        #expect(FileManager.default.fileExists(atPath: f.log(id).path) == false)
    }

    @Test("A fetch failure returns a clean scrubbed reason and leaves the archive pending")
    func fetchFailureStaysPending() async throws {
        let f = try GitHubLogFixture()
        defer { f.remove() }
        let id = try await f.insert()
        let secret = "acme-private-credential-12345"
        let calls = GitHubLogFetchCalls()
        let problem = await GitHubJobLog.archive(ledgerID: id, ledger: f.ledger, archive: f.archive,
                                                secrets: [secret], fetch: { _, _, _ in
            await calls.record()
            throw GitHubLogFetchFailure(message: "fetch denied \u{1B}[31m\(secret)\u{1B}[0m\u{200B}")
        })
        let reason = try #require(problem)
        #expect(reason.contains("fetch denied"))
        for unsafe in [secret, "\u{1B}", "[31m", "[0m", "\u{200B}"] {
            #expect(reason.contains(unsafe) == false)
        }
        #expect(await calls.total() == 1)
        let entry = try #require(try await f.archive.entry(jobID: id, side: "local"))
        #expect(entry.status == .pending)
        #expect(entry.reason == reason)
        #expect(entry.path == nil)
        #expect(FileManager.default.fileExists(atPath: f.log(id).path) == false)
    }

    @Test("A non-GitHub row is refused without fetching")
    func refusesNonGitHubJob() async throws {
        let f = try GitHubLogFixture()
        defer { f.remove() }
        let id = try await f.insert(github: false)
        let calls = GitHubLogFetchCalls()
        let problem = await GitHubJobLog.archive(ledgerID: id, ledger: f.ledger, archive: f.archive,
                                                secrets: [], fetch: { _, _, _ in
            await calls.record()
            return Data("unexpected log".utf8)
        })
        #expect(problem != nil)
        #expect(await calls.total() == 0)
        #expect(FileManager.default.fileExists(atPath: f.log(id).path) == false)
    }

    @Test("An unknown job id returns a problem")
    func refusesUnknownJob() async throws {
        let f = try GitHubLogFixture()
        defer { f.remove() }
        let calls = GitHubLogFetchCalls()
        let problem = await GitHubJobLog.archive(ledgerID: "gh-999-1", ledger: f.ledger, archive: f.archive,
                                                secrets: [], fetch: { _, _, _ in
            await calls.record()
            return Data("unexpected log".utf8)
        })
        #expect(problem != nil)
        #expect(await calls.total() == 0)
        #expect(FileManager.default.fileExists(atPath: f.log("gh-999-1").path) == false)
    }
}
