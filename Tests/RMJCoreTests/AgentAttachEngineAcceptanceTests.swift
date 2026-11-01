import Foundation
import Testing
@testable import RMJCore

private actor AttachBox: BoxClient {
    let wrapped: AgentBoxFake
    let failSend: Bool
    let changeTree: Bool
    var calls: [String] = []
    var sent: [(ulid: String, index: Int, path: String)] = []
    init(_ wrapped: AgentBoxFake, failSend: Bool = false, changeTree: Bool = false) {
        self.wrapped = wrapped; self.failSend = failSend; self.changeTree = changeTree
    }
    func prepare(_ job: BoxJob) async throws { calls.append("prepare"); try await wrapped.prepare(job) }
    func begin(_ job: BoxJob, waiting: @escaping @Sendable (String) -> Void) async throws {
        calls.append("begin"); try await wrapped.begin(job, waiting: waiting)
    }
    func sync(_ job: BoxJob) async throws { calls.append("sync"); try await wrapped.sync(job) }
    func sendAttachment(ulid: String, index: Int, from: String) async throws -> String {
        calls.append("sendAttachment:\(index)"); sent.append((ulid, index, from))
        if failSend { throw BoxFailure("fixture transfer refused") }
        return "/home/box/rx/.attach/\(ulid)/\(index)"
    }
    func go(_ job: BoxJob) async throws -> BoxLaunch { calls.append("go"); return try await wrapped.go(job) }
    func tail(_ job: BoxJob, output: @escaping @Sendable (Data) -> Void) async throws {
        calls.append("tail"); try await wrapped.tail(job, output: output)
    }
    func record(ulid: String) async throws -> BoxRecord { calls.append("record"); return try await wrapped.record(ulid: ulid) }
    func pullLog(ulid: String, output: @escaping @Sendable (Data) -> Void) async throws {
        calls.append("pullLog"); try await wrapped.pullLog(ulid: ulid, output: output)
    }
    func cancel(ulid: String) async throws { calls.append("cancel"); try await wrapped.cancel(ulid: ulid) }
    func ensureEgress(image: String, hosts: [String]) async throws {
        calls.append("ensureEgress"); try await wrapped.ensureEgress(image: image, hosts: hosts)
    }
    func stageSecret(ulid: String, name: String, content: Data) async throws -> String {
        calls.append("stageSecret"); return try await wrapped.stageSecret(ulid: ulid, name: name, content: content)
    }
    func discardSecret(ulid: String) async {
        calls.append("discardSecret:" + ulid); await wrapped.discardSecret(ulid: ulid)
    }
    func pullTree(_ job: BoxJob, into local: URL) async throws {
        calls.append("pullTree"); try await wrapped.pullTree(job, into: local)
        if changeTree { try Data("agent change\n".utf8).write(to: local.appendingPathComponent("tracked.txt")) }
    }
}

private struct AttachFactory: BoxFactory {
    let box: AttachBox
    func client(destination: String, address: String, config: DestinationConfig) -> BoxClient { box }
}

private struct AttachRunTransport: RemoteTransport {
    func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput {
        ProcessOutput(status: 0, stdout: Data("""
        @@docker rc=0
        27.3.1
        @@rsync rc=0
        rsync version 3.2.7
        @@images rc=0
        rx-rust:latest
        rx-claude:latest
        rx-codex:latest
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

private func attachEngine(_ f: AgentEngineFixture, box: AttachBox) async throws -> RunEngine {
    let home = f.git.home
    var rules = Rules.shipped
    rules.destinations["ai-eu-1"]?.peerID = "n-ai-acme-1"
    rules.rules = [try JSONDecoder().decode(Rule.self, from: Data("""
    {"name":"attachment acceptance","match":{"command":["claude"]},"to":["ai-eu-1"],"image":"rx-claude"}
    """.utf8))]
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/tailnet/running.json").path
    let tailnet = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: runNow)
    let sample = await DestinationProbe(transport: AttachRunTransport()).probe(
        DestinationTarget(alias: "ai-eu-1", peerID: "n-ai-acme-1"), tailnet: tailnet, now: runNow)
    let probes = RunProbes(sample)
    let state = RulesState.valid(rules, fingerprint: "u20-attachments")
    return RunEngine(ledger: home.ledger, archive: home.archive,
        router: Router(rules: state, tailnet: tailnet, probes: probes, fileExists: { _ in true }, now: { runNow }),
        boxes: BoxDirectory(rules: state, tailnet: tailnet, factory: AttachFactory(box: box)), probes: probes,
        output: home.output.add, notice: home.notices.notice,
        profiles: ProfileStore(home: RMJHome(environment: ["RMJ_HOME": home.root.path])), now: { runNow },
        credentials: AgentCredentialsFake(raw: try agentCredentialJSON(), trace: f.box))
}

private func attachRequest(_ f: AgentEngineFixture, paths: [String], requireBox: Bool = false) -> RunRequest {
    var request = f.request(requireBox: requireBox)
    request.agentTask?.attachments = paths
    return request
}

struct AgentAttachEngineAcceptanceTests {
    @Test func jsonCommandPrintsResultAsLastLineAfterLocalOutput() async throws {
        let root = try attachTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        var rules = Rules.shipped; rules.rules = []
        try JSONEncoder().encode(rules).write(to: home.appendingPathComponent("rules.json"))
        let claude = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\nprintf '  local answer  \\n'\nexit 7\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let tailnet = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tailnet/stopped.json").path
        let result = try await ProcessRunner().run(try attachCLI(), ["agent", "run", "--json", "--attach", bin.path, "--", "p"],
            in: root, environment: ["RMJ_HOME": home.path, "RMJ_TAILSCALE_FIXTURE": tailnet,
                                   "PATH": bin.path + ":/usr/bin:/bin"], timeout: .seconds(30))
        #expect(result.status == 7)
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
        #expect(lines.dropLast().joined(separator: "\n").contains("local answer"))
        let last = try #require(lines.last)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        #expect(Set(object.keys) == Set(["branch", "exit", "final", "job", "location"]))
        #expect(object["exit"] as? Int == 7 && object["final"] as? String == "local answer")
        #expect(object["location"] as? String == "local" && object["branch"] is NSNull)
        let job = try #require(object["job"] as? String)
        #expect(job.range(of: "^[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil)
    }

    @Test func jsonUsageErrorPrintsNoJSONAndCreatesNoJob() async throws {
        let root = try attachTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("unused-home")
        let result = try await ProcessRunner().run(try attachCLI(), ["agent", "run", "--json", "--attach", "relative", "--", "p"],
            environment: ["RMJ_HOME": home.path], timeout: .seconds(30))
        #expect(result.status == 2 && result.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("rmj.sqlite").path))
    }

    @Test func engineSendsEachAttachmentAfterSyncBeforeGoAndReturnsFinalBranchLocation() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        let root = try attachTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("evidence\n".utf8).write(to: root.appendingPathComponent("pr-evidence.md"))
        let box = AttachBox(f.box, changeTree: true), engine = try await attachEngine(f, box: box)
        // The existing fake emits one harmless plain-output chunk as well as this stream fixture.
        await f.box.echo(Data((#"{"type":"result","result":"\u001b[31mfinal answer\u001b[0m"}"# + "\n").utf8))
        let paths = [root.path, second.path]
        let result = await engine.run(attachRequest(f, paths: paths, requireBox: true))
        #expect(result.exitCode == 0 && result.state == .done)
        #expect(result.location == "ai-eu-1" && result.final == "final answer")
        #expect(result.branch == "rmj/agent/" + result.jobID)
        #expect(try await f.git.git(["show", "rmj/agent/" + result.jobID + ":tracked.txt"]) == "agent change")
        let calls = await box.calls, sent = await box.sent
        #expect(sent.count == 2)
        #expect(sent.map(\.ulid) == [result.jobID, result.jobID])
        #expect(sent.map(\.index) == [0, 1] && sent.map(\.path) == paths)
        let sync = try #require(calls.firstIndex(of: "sync")), go = try #require(calls.firstIndex(of: "go"))
        for index in 0..<2 {
            let send = try #require(calls.firstIndex(of: "sendAttachment:\(index)"))
            #expect(sync < send && send < go)
        }
        let job = try #require(await f.box.goJobs.first)
        for index in paths.indices {
            let mount = "/home/box/rx/.attach/\(result.jobID)/\(index):\(paths[index]):ro"
            let i = try #require(job.options.firstIndex(of: mount))
            #expect(i > 0 && job.options[i - 1] == "-v")
        }
        #expect(calls.contains("discardSecret:" + result.jobID))
    }

    @Test(arguments: [false, true])
    func failedAttachmentSendFallsBackOrFailsWhenBoxRequired(requireBox: Bool) async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        let root = try attachTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let box = AttachBox(f.box, failSend: true), engine = try await attachEngine(f, box: box)
        let result = await engine.run(attachRequest(f, paths: [root.path], requireBox: requireBox))
        let row = try #require(try await f.git.home.ledger.job(result.jobID))
        #expect(row.fallbackReason == "attachment could not be sent")
        #expect(result.exitCode == (requireBox ? 3 : 0))
        #expect(result.state == (requireBox ? .failed : .done) && result.location == (requireBox ? "ai-eu-1" : "local"))
        #expect(result.branch == nil)
        #expect(FileManager.default.fileExists(atPath: f.local.path) == !requireBox)
        let calls = await box.calls
        #expect(calls.contains("sync") && calls.contains("sendAttachment:0") && !calls.contains("go"))
        #expect(calls.contains("discardSecret:" + result.jobID))
    }

    @Test func localRunDoesNotSendAttachmentsAndReturnsTrimmedCleanBoundedStdout() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        let root = try attachTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let box = AttachBox(f.box), engine = try await attachEngine(f, box: box)
        let text = " \n\u{1b}[31m" + String(repeating: "x", count: 65537) + "\u{1b}[0m \n"
        let output = root.appendingPathComponent("stdout"); try Data(text.utf8).write(to: output)
        var request = attachRequest(f, paths: [root.path])
        request.forceLocal = true
        request.command = ["/bin/cat", output.path]
        let result = await engine.run(request)
        #expect(result.exitCode == 0 && result.location == "local" && result.branch == nil)
        #expect(result.final == String(repeating: "x", count: 65536))
        #expect(await box.sent.isEmpty)
        #expect(await box.calls.isEmpty)
    }

    @Test func aggregateAttachmentSizeOverFiftyMiBFallsBackBeforeAnySend() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        let root = try attachTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var paths: [String] = []
        for index in 0..<2 {
            let dir = root.appendingPathComponent("part\(index)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("payload")
            #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(25 * 1024 * 1024 + 1)); try handle.close()
            paths.append(dir.path)
        }
        let box = AttachBox(f.box), engine = try await attachEngine(f, box: box)
        let result = await engine.run(attachRequest(f, paths: paths))
        let row = try #require(try await f.git.home.ledger.job(result.jobID))
        #expect(row.fallbackReason == "attachment too large")
        #expect(result.exitCode == 0 && result.location == "local" && result.branch == nil)
        #expect(FileManager.default.fileExists(atPath: f.local.path))
        #expect(await box.sent.isEmpty)
        #expect(await f.box.staged.isEmpty)
        #expect(await f.box.goJobs.isEmpty)
    }

    @Test func exactlyFiftyMiBAttachmentCanBeSent() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        let root = try attachTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(50 * 1024 * 1024)); try handle.close()
        let box = AttachBox(f.box), engine = try await attachEngine(f, box: box)
        let result = await engine.run(attachRequest(f, paths: [root.path], requireBox: true))
        #expect(result.exitCode == 0 && result.location == "ai-eu-1")
        #expect(await box.sent.count == 1)
        #expect(result.branch == nil && result.final == nil)
    }

    @Test func boxClientDefaultAttachmentTransferThrows() async throws {
        // AgentBoxFake deliberately has no override: old conformers must compile and refuse transfer.
        let client: any BoxClient = AgentBoxFake()
        await #expect(throws: (any Error).self) {
            _ = try await client.sendAttachment(ulid: "01ATTACH0000000000000000000", index: 0, from: "/Users/a")
        }
    }
}

private final class AttachBundleMarker: NSObject {}

private func attachCLI() throws -> String {
    // Xcode's runner can live outside the build directory; search test bundles first.
    let bundles = [Bundle(for: AttachBundleMarker.self)] + Bundle.allBundles
    let starts = bundles.filter { $0.bundleURL.pathExtension == "xctest" }.map(\.bundleURL)
        + [URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()]
    for start in starts {
        var directory = start
        while true {
            let candidate = directory.appendingPathComponent("RMJCLI").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
    }
    Issue.record("Build RMJCLI beside the SwiftPM test product before running command acceptance tests")
    throw BoxFailure("RMJCLI test product missing")
}
