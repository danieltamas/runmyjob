import Foundation
import Testing
@testable import RMJCore

let agentAccess = "ACCESS-TOKEN-1234"
let agentRefresh = "REFRESH-SECRET-9876"

func agentCredentialJSON(lifetime: TimeInterval = 7200) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
        "accessToken": agentAccess, "refreshToken": agentRefresh,
        "expiresAt": runNow.addingTimeInterval(lifetime).timeIntervalSince1970 * 1000,
        "refreshTokenExpiresAt": runNow.addingTimeInterval(86400).timeIntervalSince1970 * 1000,
        "scopes": ["user:inference", "user:profile"]
    ]])
}

actor AgentCredentialsFake: CredentialSource {
    let raw: Data
    let trace: AgentBoxFake
    init(raw: Data, trace: AgentBoxFake) { self.raw = raw; self.trace = trace }
    func load() async throws -> Data { await trace.mark("credentials"); return raw }
}

// Wraps the existing U4 fake rather than duplicating its launch/record/log behaviour.
actor AgentBoxFake: BoxClient {
    let wrapped = RunBox()
    var calls: [String] = []
    var staged: [(String, String, Data)] = []
    var goJobs: [BoxJob] = []
    var pulled: [BoxJob] = []
    func mark(_ name: String) { calls.append(name) }
    func configure(code: Int = 0, startFailure: Bool = false, pending: Bool = false) async {
        await wrapped.configure(failure: pending ? "tail" : nil,
            launch: startFailure ? .startFailed("cannot start") : .started(container: "c", bootID: "boot"),
            answer: BoxRecord(containerPresent: pending, bootID: "boot", launch: .started(container: "c", bootID: "boot"),
                              result: pending ? nil : .init(code: code)))
    }
    func prepare(_ job: BoxJob) async throws { mark("prepare"); try await wrapped.prepare(job) }
    func begin(_ job: BoxJob, waiting: @escaping @Sendable (String) -> Void) async throws {
        mark("begin"); try await wrapped.begin(job, waiting: waiting)
    }
    func sync(_ job: BoxJob) async throws { mark("sync"); try await wrapped.sync(job) }
    func go(_ job: BoxJob) async throws -> BoxLaunch {
        mark("go"); goJobs.append(job); return try await wrapped.go(job)
    }
    func tail(_ job: BoxJob, output: @escaping @Sendable (Data) -> Void) async throws {
        try await wrapped.tail(job, output: output)
    }
    func record(ulid: String) async throws -> BoxRecord { try await wrapped.record(ulid: ulid) }
    func pullLog(ulid: String, output: @escaping @Sendable (Data) -> Void) async throws {
        mark("pullLog"); try await wrapped.pullLog(ulid: ulid, output: output)
    }
    func cancel(ulid: String) async throws {
        mark("cancel"); try await wrapped.cancel(ulid: ulid)
        await wrapped.configure(answer: BoxRecord(containerPresent: false, bootID: "boot",
            launch: .started(container: "c", bootID: "boot"), result: .init(code: 137, cancelled: true)))
    }
    func stageSecret(ulid: String, name: String, content: Data) async throws -> String {
        mark("stageSecret"); staged.append((ulid, name, content)); return "/dev/shm/rmj-" + ulid
    }
    func discardSecret(ulid: String) async { mark("discardSecret:" + ulid) }
    func pullTree(_ job: BoxJob, into local: URL) async throws {
        mark("pullTree"); pulled.append(job)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try await TreeSync.run(worktree: URL(fileURLWithPath: job.worktree), destination: local.path + "/", shell: nil)
    }
}

struct AgentBoxFactory: BoxFactory {
    let box: AgentBoxFake
    func client(destination: String, address: String, config: DestinationConfig) -> BoxClient { box }
}

private struct AgentRunTransport: RemoteTransport {
    func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput {
        ProcessOutput(status: 0, stdout: Data("""
        @@docker rc=0
        27.3.1
        @@rsync rc=0
        rsync version 3.2.7
        @@images rc=0
        rx-rust:latest
        rx-claude:latest
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

struct AgentEngineFixture {
    let git: AgentGitFixture
    let box: AgentBoxFake
    let engine: RunEngine
    let local: URL
    static func make(noRule: Bool = false, stopped: Bool = false, lifetime: TimeInterval = 7200) async throws -> Self {
        let git = try await AgentGitFixture.make()
        let f = git.home
        let box = AgentBoxFake()
        var rules = Rules.shipped
        rules.destinations["ai-eu-1"]?.peerID = "n-ai-acme-1"
        rules.rules = noRule ? [] : [try JSONDecoder().decode(Rule.self, from: Data("""
        {"name":"agent acceptance","match":{"command":["claude"]},"to":["ai-eu-1"],
         "image":"rx-claude","cpus":2,"memory":"4g"}
        """.utf8))]
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tailnet/" + (stopped ? "stopped" : "running") + ".json").path
        let tailnet = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: runNow)
        let runningPath = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("running.json").path
        let running = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": runningPath], now: runNow)
        let sample = await DestinationProbe(transport: AgentRunTransport()).probe(
            DestinationTarget(alias: "ai-eu-1", peerID: "n-ai-acme-1"), tailnet: running, now: runNow)
        let probes = RunProbes(sample)
        let state = RulesState.valid(rules, fingerprint: "u14")
        let engine = RunEngine(ledger: f.ledger, archive: f.archive,
            router: Router(rules: state, tailnet: tailnet, probes: probes, fileExists: { _ in true }, now: { runNow }),
            boxes: BoxDirectory(rules: state, tailnet: tailnet, factory: AgentBoxFactory(box: box)), probes: probes,
            output: f.output.add, notice: f.notices.notice,
            profiles: ProfileStore(home: RMJHome(environment: ["RMJ_HOME": f.root.path])),
            now: { runNow }, credentials: AgentCredentialsFake(raw: try agentCredentialJSON(lifetime: lifetime), trace: box))
        let local = f.root.appendingPathComponent("local-ran")
        let stub = f.root.appendingPathComponent("claude")
        try Data(("#!/bin/sh\nprintf '%s\\n' \"$@\" > '" + local.path + "'\n").utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return Self(git: git, box: box, engine: engine, local: local)
    }
    func request(requireBox: Bool = false, repo: String = "acme/axon") -> RunRequest {
        let task = AgentTask(prompt: "change the code", unattended: true, allowedTools: ["Read", "Edit"],
                             timeoutSeconds: 90, requireBox: requireBox)
        return RunRequest(command: [git.home.root.appendingPathComponent("claude").path] + task.argv(onBox: false).dropFirst(), identity: RepoIdentity(slug: repo, worktree: git.repo.path, dirty: true),
                          agentTask: task)
    }
}

struct AgentRunEngineAcceptanceTests {
    @Test func missingRuleAndStoppedTailnetFailClosedWhenBoxRequired() async throws {
        for stopped in [false, true] {
            let f = try await AgentEngineFixture.make(noRule: !stopped, stopped: stopped)
            defer { f.git.home.remove() }
            let result = await f.engine.run(f.request(requireBox: true))
            let row = try #require(try await f.git.home.ledger.job(result.jobID))
            #expect(result.exitCode == 3 && result.state == .failed && row.state == .failed)
            #expect(row.exitCode == 3 && row.fallbackReason?.isEmpty == false)
            #expect(await f.box.goJobs.isEmpty)
            #expect(await f.box.staged.isEmpty)
            #expect(f.git.home.output.text.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: f.local.path))
        }
    }

    @Test func missingRuleAndTailnetFallbackExecuteRequestLocalArgv() async throws {
        for stopped in [false, true] {
            let f = try await AgentEngineFixture.make(noRule: !stopped, stopped: stopped)
            defer { f.git.home.remove() }
            let request = f.request()
            let result = await f.engine.run(request)
            let row = try #require(try await f.git.home.ledger.job(result.jobID))
            #expect(result.exitCode == 0 && row.location == "local")
            #expect(row.fallbackReason?.isEmpty == false)
            if stopped { #expect(row.fallbackReason == "tailnet down") }
            #expect(try String(contentsOf: f.local, encoding: .utf8) == request.agentTask!.argv(onBox: false).dropFirst().joined(separator: "\n") + "\n")
            #expect(await f.box.goJobs.isEmpty)
            #expect(await f.box.staged.isEmpty)
        }
    }

    @Test func stageBeforeGoAndNeverLeakTokensAcrossPublicSurfaces() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        let result = await f.engine.run(f.request(requireBox: true))
        #expect(result.state == .done && result.exitCode == 0)
        let calls = await f.box.calls
        #expect(try #require(calls.firstIndex(of: "credentials")) < #require(calls.firstIndex(of: "begin")))
        #expect(try #require(calls.firstIndex(of: "stageSecret")) < #require(calls.firstIndex(of: "go")))
        #expect(calls.contains("discardSecret:" + result.jobID))
        let staged = try #require(await f.box.staged.first)
        #expect(staged.0 == result.jobID)
        let json = try #require(try JSONSerialization.jsonObject(with: staged.2) as? [String: Any])
        let oauth = try #require(json["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == agentAccess)
        #expect(oauth["refreshToken"] == nil && oauth["refreshTokenExpiresAt"] == nil)
        #expect(!String(decoding: staged.2, as: UTF8.self).contains(agentRefresh))
        let job = try #require(await f.box.goJobs.first)
        #expect(job.argv == f.request().agentTask?.argv(onBox: true))
        #expect(await f.box.pulled.count == 1)
        let row = try #require(try await f.git.home.ledger.job(result.jobID))
        let events = try await f.git.home.ledger.events(result.jobID)
        let surfaces = [job.argv.joined(separator: " "), job.options.joined(separator: " "),
                        job.prelude?.content ?? "", job.prelude?.path ?? "", String(reflecting: row),
                        String(reflecting: events), f.git.home.output.text, f.git.home.notices.text,
                        try await f.git.home.log(result.jobID)]
        for token in [agentAccess, agentRefresh] {
            for surface in surfaces { #expect(!surface.contains(token)) }
            let urls = FileManager.default.enumerator(at: f.git.home.root, includingPropertiesForKeys: [.isRegularFileKey])!
            while let url = urls.nextObject() as? URL {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    #expect(try Data(contentsOf: url).range(of: Data(token.utf8)) == nil)
                }
            }
        }
    }

    @Test func discardAfterFailedRunStartFailureAndCancel() async throws {
        for mode in ["failed", "start", "cancel"] {
            let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
            await f.box.configure(code: 7, startFailure: mode == "start", pending: mode == "cancel")
            let result = await f.engine.run(f.request(requireBox: true))
            if mode == "cancel" {
                #expect(result.state == .running)
                #expect(await f.engine.cancel(result.jobID) == .cancelled)
                let calls = await f.box.calls
                #expect(try #require(calls.firstIndex(of: "cancel")) < #require(calls.lastIndex(of: "discardSecret:" + result.jobID)))
            } else { #expect(result.state == .failed) }
            let calls = await f.box.calls
            #expect(calls.contains("discardSecret:" + result.jobID))
            #expect(try #require(calls.firstIndex(of: "go")) < #require(calls.lastIndex(of: "discardSecret:" + result.jobID)))
            if mode == "failed" { #expect(result.exitCode == 7) }
        }
    }

    @Test func expiringLoginFallsBackWithoutStaging() async throws {
        for requireBox in [false, true] {
            let f = try await AgentEngineFixture.make(lifetime: 599); defer { f.git.home.remove() }
            let request = f.request(requireBox: requireBox)
            let result = await f.engine.run(request)
            let row = try #require(try await f.git.home.ledger.job(result.jobID))
            #expect(row.fallbackReason == "claude login expires soon")
            #expect(result.exitCode == (requireBox ? 3 : 0))
            #expect(row.exitCode == (requireBox ? 3 : 0))
            #expect(result.state == (requireBox ? .failed : .done))
            #expect(row.state == (requireBox ? .failed : .done))
            #expect(FileManager.default.fileExists(atPath: f.local.path) == !requireBox)
            #expect(await f.box.staged.isEmpty)
            #expect(await f.box.goJobs.isEmpty)
        }
    }

    @Test func companyTenantCannotReachOtherCompanyBoxEvenWhenExplicit() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        var request = f.request(requireBox: true, repo: "globex/portal")
        request.destination = "ai-eu-1"
        let result = await f.engine.run(request)
        let row = try #require(try await f.git.home.ledger.job(result.jobID))
        #expect(result.exitCode == 3 && row.state == .failed)
        #expect(row.destination == nil && row.fallbackReason?.isEmpty == false)
        #expect(await f.box.staged.isEmpty)
            #expect(await f.box.goJobs.isEmpty)
    }

    @Test func credentialsStripRefreshFieldsKeepAccessExpiryAndScopes() throws {
        let raw = try agentCredentialJSON()
        let staged = try AgentCredentials.stage(raw: raw, now: runNow, minimumLifetime: 600)
        let original = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let originalOAuth = try #require(original["claudeAiOauth"] as? [String: Any])
        let output = try #require(try JSONSerialization.jsonObject(with: staged) as? [String: Any])
        let oauth = try #require(output["claudeAiOauth"] as? [String: Any])
        for key in ["accessToken", "expiresAt", "scopes"] {
            #expect(NSDictionary(dictionary: [key: try #require(oauth[key])]) ==
                    NSDictionary(dictionary: [key: try #require(originalOAuth[key])]))
        }
        #expect(oauth["refreshToken"] == nil && oauth["refreshTokenExpiresAt"] == nil)
        #expect(throws: AgentCredentials.Failure.expiresSoon) {
            try AgentCredentials.stage(raw: agentCredentialJSON(lifetime: 599), now: runNow, minimumLifetime: 600)
        }
        for raw in [Data("not JSON".utf8), Data("{}".utf8), Data("{\"claudeAiOauth\":{}}".utf8)] {
            #expect(throws: AgentCredentials.Failure.unreadable) {
                try AgentCredentials.stage(raw: raw, now: runNow, minimumLifetime: 600)
            }
        }
        _ = try AgentCredentials.stage(raw: agentCredentialJSON(lifetime: 600), now: runNow, minimumLifetime: 600)
    }
}
