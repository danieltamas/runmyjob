import Testing
import Foundation
import RMJCore

let runNow = Date(timeIntervalSince1970: 1_793_102_400)

final class RunCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func add(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
    func notice(_ text: String) { add(Data((text + "\n").utf8)) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}

actor RunBox: BoxClient {
    var calls: [String] = []
    var jobs: [BoxJob] = []
    var failure: String?
    var launch: BoxLaunch = .started(container: "container", bootID: "boot")
    var answer = BoxRecord(containerPresent: false, bootID: "boot", launch: .started(container: "container", bootID: "boot"),
                           result: .init(code: 0))
    var chunks = [Data("\u{1B}[31mbox output\u{1B}[0m\n".utf8)]
    var log = "full box log\n"
    var holder: String?
    var recordFailures = false
    var cancelRecords: [BoxRecord] = []
    func configure(failure: String? = nil, launch: BoxLaunch? = nil, answer: BoxRecord? = nil,
                   holder: String? = nil, recordFailures: Bool = false) {
        self.failure = failure
        if let launch { self.launch = launch }
        if let answer { self.answer = answer }
        self.holder = holder
        self.recordFailures = recordFailures
    }
    func setCancelRecords(_ records: [BoxRecord]) { cancelRecords = records }
    private func step(_ name: String) throws {
        calls.append(name)
        if failure == name { throw BoxFailure("test transport failure") }
    }
    func prepare(_ job: BoxJob) async throws { jobs.append(job); try step("prepare") }
    func begin(_ job: BoxJob, waiting: @escaping @Sendable (String) -> Void) async throws {
        try step("begin")
        if let holder { waiting(holder); try await Task.sleep(for: .milliseconds(20)) }
        calls.append("begin returned")
    }
    func sync(_ job: BoxJob) async throws { try step("sync") }
    func go(_ job: BoxJob) async throws -> BoxLaunch { try step("go"); return launch }
    func tail(_ job: BoxJob, output: @escaping @Sendable (Data) -> Void) async throws {
        for chunk in chunks { output(chunk) }
        try step("tail")
    }
    func record(ulid: String) async throws -> BoxRecord {
        calls.append("record")
        if recordFailures { throw BoxFailure("offline") }
        if !cancelRecords.isEmpty { return cancelRecords.removeFirst() }
        return answer
    }
    func pullLog(ulid: String, output: @escaping @Sendable (Data) -> Void) async throws {
        try step("pullLog"); output(Data(log.utf8))
    }
    func cancel(ulid: String) async throws { try step("cancel:" + ulid) }
}

struct RunFactory: BoxFactory {
    let box: RunBox
    func client(destination: String, address: String, config: DestinationConfig) -> BoxClient { box }
}

private struct RunTransport: RemoteTransport {
    func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput {
        ProcessOutput(status: 0, stdout: Data("""
        @@docker rc=0
        27.3.1
        @@rsync rc=0
        rsync version 3.2.7
        @@images rc=0
        rx-rust:latest
        @@containers rc=0
        @@nproc rc=0
        24
        @@mem rc=0
        40000
        @@load rc=0
        0.5
        @@boot rc=0
        boot
        @@uptime rc=0
        3600
        @@clock rc=0
        1793102400000000000
        @@end
        """.utf8), stderr: "")
    }
}

actor RunProbes: ProbeProvider {
    let sample: DestinationProbeResult
    private(set) var calls = 0
    init(_ sample: DestinationProbeResult) { self.sample = sample }
    func latest(for destination: String) async -> DestinationProbeResult? { sample }
    func probe(_ target: DestinationTarget, tailnet: TailnetState) async -> DestinationProbeResult { calls += 1; return sample }
}

struct RunFixture: Sendable {
    let root: URL
    let database: Database
    let ledger: Ledger
    let archive: LogArchive
    let boxes: BoxDirectory
    let probes: RunProbes
    let router: Router
    let box: RunBox
    let output = RunCapture()
    let notices = RunCapture()
    static func make(stopped: Bool = false, profile: String? = nil) async throws -> RunFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-u4-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try Database(url: root.appendingPathComponent("ledger.sqlite"))
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tailnet/" + (stopped ? "stopped" : "running") + ".json").path
        let tailnet = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: runNow)
        let runningPath = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("running.json").path
        let running = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": runningPath], now: runNow)
        let sample = await DestinationProbe(transport: RunTransport()).probe(
            DestinationTarget(alias: "ai-eu-1", peerID: "n-ai-acme-1"), tailnet: running, now: runNow)
        let probes = RunProbes(sample)
        var rules = try JSONDecoder().decode(Rules.self, from: Data(Rules.shippedJSON
            .replacingOccurrences(of: "nAcmeBox0001CNTRL", with: "n-ai-acme-1").utf8))
        rules.rules = [try JSONDecoder().decode(Rule.self, from: Data("""
        {"name":"acceptance","match":{"command":["true","false","echo","sh","cargo"]},
         "to":["ai-eu-1"],"image":"rx-rust"}
        """.utf8))]
        if let profile { rules.rules[0].profile = profile }
        try writeLedgerProfile(home: RMJHome(environment: ["RMJ_HOME": root.path]))
        let state = RulesState.valid(rules, fingerprint: "u4")
        let box = RunBox()
        return RunFixture(root: root, database: database, ledger: Ledger(database: database),
                          archive: LogArchive(database: database, directory: root.appendingPathComponent("logs")),
                          boxes: BoxDirectory(rules: state, tailnet: tailnet, factory: RunFactory(box: box)), probes: probes,
                          router: Router(rules: state, tailnet: tailnet, probes: probes, fileExists: { _ in true }, now: { runNow }), box: box)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func engine(secrets: [String] = []) -> RunEngine {
        RunEngine(ledger: ledger, archive: archive, router: router, boxes: boxes, probes: probes, secrets: secrets,
                  output: output.add, notice: notices.notice, profiles: ProfileStore(home: RMJHome(environment: ["RMJ_HOME": root.path])), now: { runNow })
    }
    func request(_ command: [String] = ["true"], shell: Bool = false) -> RunRequest {
        RunRequest(command: command, shell: shell, identity: RepoIdentity(slug: "acme/axon", worktree: root.path, dirty: true),
                   branch: "acceptance", commit: "abc1234", agent: AgentContext(agent: "codex", session: "session-u4"))
    }
    func insert(_ state: JobState = .running, age: TimeInterval = 0) async throws -> String {
        let id = ULID.make()
        try await ledger.insert(JobRecord(id: id, repo: "acme/axon", command: "true", location: "ai-eu-1",
                                         destination: "ai-eu-1", state: state, queuedAt: runNow.addingTimeInterval(-age)))
        return id
    }
    func reconcile() async {
        await Reconciler(ledger: ledger, archive: archive, boxes: boxes, retryDelay: .milliseconds(1), now: { runNow }).reconcile()
    }
    func log(_ id: String, side: String = "box") async throws -> String {
        let entry = try #require(try await archive.entry(jobID: id, side: side))
        #expect(entry.status == .available)
        return try String(contentsOfFile: #require(entry.path), encoding: .utf8)
    }
}

struct RunAcceptanceTests {
    @Test func stoppedTailnetRunsFalseLocallyAndArchivesLog() async throws {
        let f = try await RunFixture.make(stopped: true); defer { f.remove() }
        let result = await f.engine().run(f.request(["false"]))
        let row = try #require(try await f.ledger.job(result.jobID))
        #expect(result.exitCode == 1 && result.state == .failed)
        #expect(row.location == "local" && row.destination == nil)
        #expect(row.fallbackReason == "tailnet down" && row.environment == "mac")
        #expect(await f.box.calls.isEmpty)
        _ = try await f.log(result.jobID, side: "mac")
    }

    @Test func localSuccessRecordsLifecycleAndRequestContext() async throws {
        let f = try await RunFixture.make(stopped: true); defer { f.remove() }
        let result = await f.engine().run(f.request(["echo", "hi"]))
        let row = try #require(try await f.ledger.job(result.jobID))
        #expect(result.exitCode == 0 && row.state == .done && row.exitCode == 0)
        #expect(f.output.text == "hi\n")
        #expect(row.macElapsedMS.map { $0 >= 0 } == true)
        #expect(row.startedAt != nil && row.endedAt != nil)
        #expect(row.tenant == "personal" && row.worktree == f.root.path)
        #expect(row.agent == "codex" && row.session == "session-u4")
        #expect(try await f.ledger.events(result.jobID).map(\.state) == [.queued, .running, .done])
    }

    @Test func failedStartsSyncAndBeginFallBackWithExactReasons() async throws {
        for stage in ["start-failed", "go", "sync", "begin"] {
            let f = try await RunFixture.make(); defer { f.remove() }
            await f.box.configure(failure: stage == "start-failed" ? nil : stage,
                                  launch: stage == "start-failed" ? .startFailed("boom") : nil,
                                  answer: BoxRecord(containerPresent: false, bootID: "boot"))
            let result = await f.engine().run(f.request(["true"]))
            let row = try #require(try await f.ledger.job(result.jobID))
            #expect(result.exitCode == 0 && row.state == .done)
            #expect(row.location == "local" && row.environment == "mac" && row.destination == nil)
            #expect(row.fallbackReason == (stage == "sync" ? "sync failed" : stage == "begin" ? "destination unreachable" : "container start failed"))
            #expect(await f.box.calls.contains("cancel:" + result.jobID))
        }
    }

    @Test func startedExit125NeverExecutesLocallyAndAmbiguousLaunchIsLost() async throws {
        for ambiguous in [false, true] {
            let f = try await RunFixture.make(); defer { f.remove() }
            let marker = f.root.appendingPathComponent("must-not-exist")
            await f.box.configure(failure: ambiguous ? "go" : nil,
                                  answer: BoxRecord(containerPresent: ambiguous, bootID: "boot",
                                                    launch: ambiguous ? nil : .started(container: "c", bootID: "boot"),
                                                    result: ambiguous ? nil : .init(code: 125)))
            let result = await f.engine().run(f.request(["sh", "-c", "touch must-not-exist"]))
            let row = try #require(try await f.ledger.job(result.jobID))
            #expect(row.location == "ai-eu-1" && row.fallbackReason == nil)
            #expect(row.state == (ambiguous ? .lost : .failed))
            if !ambiguous { #expect(result.exitCode == 125 && row.exitCode == 125) }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func argvIsLiteralLocallyAndShellIsExplicit() async throws {
        let f = try await RunFixture.make(stopped: true); defer { f.remove() }
        _ = await f.engine().run(f.request(["echo", "$(whoami)", "a b"]))
        #expect(f.output.text == "$(whoami) a b\n")
        let shell = try await RunFixture.make(stopped: true); defer { shell.remove() }
        _ = await shell.engine().run(shell.request(["echo $(whoami)"], shell: true))
        let who = try await ProcessRunner().run("/usr/bin/whoami", [], timeout: .seconds(5))
        #expect(shell.output.text == String(decoding: who.stdout, as: UTF8.self))
    }

    @Test func boxArgvNamesAndResourceOptionsArePreserved() async throws {
        for shell in [false, true] {
            let f = try await RunFixture.make(); defer { f.remove() }
            let command = shell ? ["echo $(whoami)"] : ["echo", "$(whoami)", "a b"]
            let result = await f.engine().run(f.request(command, shell: shell))
            let job = try #require(await f.box.jobs.first)
            #expect(job.argv == (shell ? ["bash", "-c", command[0]] : command))
            #expect(job.ulid == result.jobID && job.ulid.count == 26)
            #expect(job.name.hasPrefix("rx-") && job.name.hasSuffix(result.jobID.suffix(8).lowercased()))
            #expect(job.options.contains("--cpus") && job.options.contains("--memory"))
            let mount = try #require(job.options.firstIndex(of: "-v"))
            #expect(job.options.indices.contains(mount + 1))
            #expect(job.options.contains(job.directory + ":/work"))
            #expect(await f.box.calls == ["prepare", "begin", "begin returned", "sync", "go", "tail", "record"])
        }
    }

    @Test func waitingNoticeAndQueuedEventPrecedeSync() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        let holder = "01HOLDERID0000000000000000"
        await f.box.configure(holder: holder)
        let result = await f.engine().run(f.request())
        #expect(f.notices.text.contains("waiting for " + holder))
        let events = try await f.ledger.events(result.jobID)
        let waiting = try #require(events.firstIndex { $0.detail == "waiting for " + holder })
        let syncing = try #require(events.firstIndex { $0.state == .syncing })
        #expect(events[waiting].state == .queued && waiting < syncing)
        let calls = await f.box.calls
        let returned = try #require(calls.firstIndex(of: "begin returned"))
        let sync = try #require(calls.firstIndex(of: "sync"))
        #expect(returned < sync)
    }

    @Test func secretsAreRedactedBeforeArchiveAndLedgerStorage() async throws {
        let f = try await RunFixture.make(stopped: true); defer { f.remove() }
        let secret = "ghp_" + String(repeating: "A", count: 36)
        let result = await f.engine(secrets: [secret]).run(f.request(["echo", secret]))
        let log = try await f.log(result.jobID, side: "mac")
        #expect(!log.contains(secret) && !log.isEmpty)
        let row = try #require(try await f.ledger.job(result.jobID))
        #expect(!String(describing: row).contains(secret))
        #expect(!String(describing: try await f.ledger.events(result.jobID)).contains(secret))
        for url in try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("ledger.sqlite") {
            #expect(try Data(contentsOf: url).range(of: Data(secret.utf8)) == nil)
        }
    }
}
