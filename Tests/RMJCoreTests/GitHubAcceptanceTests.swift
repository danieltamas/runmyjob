import Testing
import Foundation
import RMJCore

final class U5Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_793_088_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

struct U5Fixture: Sendable {
    let directory: URL
    let ledger: Ledger
    let clock = U5Clock()
    let api = U5API()
    let repo = "acme/atlas"
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-u5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ledger = Ledger(database: try Database(url: directory.appendingPathComponent("ledger.sqlite")))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func poller(rules: Rules = .shipped, token: @escaping @Sendable (String) -> String? = { _ in nil }) -> GitHubPoller {
        GitHubPoller(api: api, ledger: ledger, rules: rules, orgToken: token, now: { clock.now() })
    }
    func run(_ id: Int64 = 1, status: String = "completed", attempt: Int = 1, age: TimeInterval = 60) -> GHRun {
        GHRun(id: id, name: "CI", status: status, runAttempt: attempt, createdAt: clock.now().addingTimeInterval(-age))
    }
    func job(_ id: Int64 = 10, run: Int64 = 1, status: String = "completed", conclusion: String? = "success", attempt: Int = 1) -> GHJob {
        GHJob(id: id, runId: run, runAttempt: attempt, name: "check", status: status, conclusion: conclusion,
              createdAt: clock.now().addingTimeInterval(-60), labels: ["self-hosted", "linux", "atlas"])
    }
    func row(_ id: Int64 = 10, attempt: Int = 1) async throws -> JobRecord {
        try #require(try await ledger.job(GitHubMapping.ledgerID(jobID: id, attempt: attempt)))
    }
    func info(_ id: Int64 = 10, attempt: Int = 1) async throws -> GitHubJobInfo {
        try #require(GitHubJobInfo.decode(try await row(id, attempt: attempt).github))
    }
}

// All network-shaped responses stay in memory. No process is launched by this fake.
actor U5API: GitHubAPI {
    struct Call: Sendable {
        let path: String
        let query: [String: String]
        let etag: String?
        let token: String?
    }
    private var calls: [Call] = []
    private var runs: [String: [GHRun]] = [:]
    private var jobs: [String: [GHJob]] = [:]
    private var runners: [String: [RunnerRegistration]] = [:]
    private var owners: [String: [String]] = [:]
    private var tags: [String: String] = [:]
    private var reset: Date?
    private var pageCap = 100
    func recorded() -> [Call] { calls }
    func clear() { calls = [] }
    func limit(_ until: Date?) { reset = until }
    func cap(_ size: Int) { pageCap = size }
    func tag(_ repo: String, _ value: String?) { tags[repo] = value }
    func set(_ repo: String, runs values: [GHRun], jobs valuesJobs: [GHJob]) {
        runs[repo] = values
        for run in values {
            jobs["/repos/\(repo)/actions/runs/\(run.id)/attempts/\(run.runAttempt)/jobs"] = valuesJobs.filter {
                $0.runId == run.id && $0.runAttempt == run.runAttempt
            }
        }
    }
    func register(_ path: String, _ values: [RunnerRegistration]) { runners[path] = values }
    func owner(_ scope: String, _ name: String, repos: [String]) { owners["/\(scope)/\(name)/repos"] = repos }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    private func page<T>(_ values: [T], _ query: [String: String]) -> (ArraySlice<T>, Bool) {
        let size = min(Int(query["per_page"] ?? "100") ?? 100, pageCap)
        let start = min(values.count, max(0, ((Int(query["page"] ?? "1") ?? 1) - 1) * size))
        let end = min(values.count, start + size)
        return (values[start..<end], end < values.count)
    }
    func get(_ path: String, query: [String: String], etag: String?, token: String?) async throws -> GitHubResponse {
        calls.append(Call(path: path, query: query, etag: etag, token: token))
        if let reset { return GitHubResponse(status: 403, rateLimitRemaining: 0, rateLimitReset: reset) }
        if let values = owners[path] {
            let (part, next) = page(values, query)
            return GitHubResponse(status: 200, body: try encode(part.map { ["full_name": $0] }), hasNextPage: next)
        }
        if let values = runners[path] {
            struct Label: Encodable { let name: String }
            struct Runner: Encodable { let name: String; let status: String; let busy: Bool; let labels: [Label] }
            let body = values.map { Runner(name: $0.name, status: $0.online ? "online" : "offline", busy: $0.busy, labels: $0.labels.map { Label(name: $0) }) }
            return GitHubResponse(status: 200, body: try encode(["runners": body]))
        }
        if let values = jobs[path] {
            let (part, next) = page(values, query)
            return GitHubResponse(status: 200, body: try encode(["jobs": Array(part)]), hasNextPage: next)
        }
        for (repo, values) in runs {
            let base = "/repos/\(repo)/actions/runs"
            if path == base {
                if let tag = tags[repo], etag == tag { return GitHubResponse(status: 304, etag: tag) }
                let floor = query["created"].flatMap { ISO8601DateFormatter().date(from: String($0.dropFirst(2))) }
                let filtered = values.filter { floor == nil || ($0.createdAt ?? .distantPast) >= floor! }
                let (part, next) = page(filtered, query)
                return GitHubResponse(status: 200, body: try encode(["workflow_runs": Array(part)]), etag: tags[repo], hasNextPage: next)
            }
            if let run = values.first(where: { path == base + "/\($0.id)" }) {
                return GitHubResponse(status: 200, body: try encode(run))
            }
        }
        return GitHubResponse(status: 404)
    }
}

struct GitHubAcceptanceTests {
    @Test func queueObservationUsesAllLabelsAndCleansNames() {
        let labels = ["self-hosted", "linux", "atlas"]
        let now = Date(timeIntervalSince1970: 100)
        let stale = RunnerRegistration(name: "runner-stale", labels: labels, online: false, busy: false)
        let observed = QueueAnalysis.observe(labels: labels, registrations: [stale], now: now)
        #expect(observed.summary == "0 online, 1 offline idle (runner-stale)")
        #expect(observed.suspectedCause == "stale registration")
        #expect(observed.matches.map(\.name) == ["runner-stale"])
        #expect(observed.matches.map(\.state) == ["offline idle"])
        #expect(observed.observedAt == now)
        var idle = stale; idle.online = true
        #expect(QueueAnalysis.observe(labels: labels, registrations: [stale, idle], now: now).suspectedCause == "unknown")
        idle.busy = true
        #expect(QueueAnalysis.observe(labels: labels, registrations: [idle], now: now).suspectedCause == "all busy")
        idle.labels = ["self-hosted", "linux"]
        let missing = QueueAnalysis.observe(labels: labels, registrations: [idle], now: now)
        #expect(missing.matches.isEmpty)
        #expect(missing.suspectedCause == "none online")
        idle.labels = labels; idle.name = "runner\u{1B}[31m-\u{200B}clean"
        #expect(QueueAnalysis.observe(labels: labels, registrations: [idle], now: now).matches.first?.name == "runner-clean")
    }

    @Test func stateMappingPreservesSkippedAndTimeout() {
        let cases: [(String, String?, JobState)] = [("completed", "skipped", .skipped), ("completed", "timed_out", .failed),
            ("completed", "success", .done), ("completed", "failure", .failed), ("completed", "cancelled", .cancelled),
            ("in_progress", nil, .running), ("queued", nil, .queued), ("waiting", nil, .queued)]
        for (status, conclusion, expected) in cases { #expect(GitHubMapping.state(status: status, conclusion: conclusion) == expected) }
    }

    @Test func rerunPassesExactArgvAndRejectsUnfinishedOrForeignRows() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        for (id, state, conclusion) in [(Int64(10), JobState.failed, "failure"), (11, .done, "success"), (12, .cancelled, "cancelled"), (13, .queued, ""), (14, .running, "")] {
            var row = JobRecord(id: "gh-\(id)-1", repo: f.repo, command: "CI", location: "self-hosted", state: state, queuedAt: f.clock.now())
            row.github = GitHubMapping.info(repo: f.repo, run: f.run(), job: f.job(id, status: state.isSettled ? "completed" : "queued", conclusion: conclusion), observation: nil, parent: nil).json
            try await f.ledger.insert(row)
        }
        let base = ["gh", "run", "rerun", "1", "-R", f.repo]
        #expect(try await GitHubRerun.argv(ledger: f.ledger, jobID: "gh-10-1") == base + ["--failed"])
        for id in [11, 12] { #expect(try await GitHubRerun.argv(ledger: f.ledger, jobID: "gh-\(id)-1") == base) }
        for id in [13, 14] {
            await #expect(throws: GitHubRerun.Failure.notFinished) { try await GitHubRerun.argv(ledger: f.ledger, jobID: "gh-\(id)-1") }
        }
        await #expect(throws: GitHubRerun.Failure.unknownJob) { try await GitHubRerun.argv(ledger: f.ledger, jobID: "unknown") }
        try await f.ledger.insert(JobRecord(id: "rx", repo: f.repo, command: "true", location: "local", state: .done, queuedAt: f.clock.now()))
        await #expect(throws: GitHubRerun.Failure.notGitHub) { try await GitHubRerun.argv(ledger: f.ledger, jobID: "rx") }
        actor Capture { var calls: [[String]] = []; func add(_ argv: [String]) { calls.append(argv) } }
        let capture = Capture()
        try await GitHubRerun.rerun(ledger: f.ledger, jobID: "gh-10-1") { await capture.add($0) }
        #expect(await capture.calls == [base + ["--failed"]])
        // Shell metacharacters must remain a single inert argv element.
        let hostileRepo = "owner/repo;$(touch never)"
        var hostile = JobRecord(id: "hostile", repo: hostileRepo, command: "CI", location: "local", state: .done, queuedAt: f.clock.now())
        hostile.github = GitHubMapping.info(repo: hostileRepo, run: f.run(), job: f.job(), observation: nil, parent: nil).json
        try await f.ledger.insert(hostile)
        try await GitHubRerun.rerun(ledger: f.ledger, jobID: "hostile") { argv in
            #expect(argv == ["gh", "run", "rerun", "1", "-R", hostileRepo])
        }
    }

    @Test func routingHelpersUseRegisteredLabelsAndShippedTargets() throws {
        let labels = ["self-hosted", "linux", "atlas"]
        let registrations = ["z", "a", "a"].map { RunnerRegistration(name: $0, labels: labels, online: false, busy: false, destination: $0) }
        #expect(GitHubRouting.servedBy(labels: labels, registrations: registrations) == ["a", "z"])
        #expect(GitHubRouting.servedBy(labels: labels + ["missing"], registrations: registrations).isEmpty)
        #expect(GitHubRouting.isMismatch(labels: ["self-hosted", "linux", "nobody"], registrations: registrations))
        #expect(!GitHubRouting.isMismatch(labels: ["ubuntu-latest"], registrations: registrations))
        let rules = try JSONDecoder().decode(Rules.self, from: Data(Rules.shippedJSON.utf8))
        #expect(GitHubRouting.destinations(forRepo: "ACME/ATLAS", rules: rules) == ["ai-eu-1"])
        #expect(GitHubRouting.destinations(forRepo: "aCmE/anything", rules: rules) == ["ai-eu-1"])
    }
}
