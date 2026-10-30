import Foundation
import Testing
@testable import RMJCore

struct AgentRunStreamAcceptanceTests {
    @Test func resultErrorsRenderAndSuccessfulResultsStaySilent() {
        for isError in [false, true] {
            let capture = RunCapture()
            let stream = AgentStream(emit: capture.add)
            stream.add(Data(("{\"type\":\"result\",\"is_error\":\(isError),\"result\":\"login rejected\"}\n").utf8))
            stream.flush()
            #expect(capture.text == (isError ? "agent failed: login rejected\n" : ""))
        }
    }

    @Test func eventsRenderReadableLinesAndSuppressProtocolNoise() {
        let capture = RunCapture()
        let stream = AgentStream(emit: capture.add)
        let events = [
            #"{"type":"system","subtype":"init","model":"fixture-model"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Readable answer"},{"type":"tool_use","name":"Bash","input":{"command":"pwd","file_path":"ignored"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"denied\nprivate detail"},{"type":"tool_result","is_error":false,"content":"success hidden"}]}}"#,
            #"{"type":"result","result":"summary hidden"}"#,
            #"{"type":"system","subtype":"other"}"#,
            #"{"type":"unknown","text":"hidden"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":""}]}}"#
        ]
        stream.add(Data((events.joined(separator: "\n") + "\n").utf8))
        stream.flush()
        #expect(capture.text == "agent started (fixture-model)\nReadable answer\n> Bash: pwd\n  tool failed: denied\n")
    }

    @Test func everyByteBoundaryPreservesEventsAndFlushEmitsTailOnce() {
        let event = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"#
        let bytes = Data((event + "\nplain output\n{\"missing_type\":true}\nunterminated").utf8)
        for split in 0...bytes.count {
            let capture = RunCapture()
            let stream = AgentStream(emit: capture.add)
            stream.add(Data(bytes.prefix(split)))
            stream.add(Data(bytes.dropFirst(split)))
            #expect(capture.text == "Hello\nplain output\n{\"missing_type\":true}\n")
            stream.flush()
            stream.flush()
            #expect(capture.text == "Hello\nplain output\n{\"missing_type\":true}\nunterminated\n")
        }
        let capture = RunCapture()
        let stream = AgentStream(emit: capture.add)
        stream.add(Data(event.utf8))
        #expect(capture.text.isEmpty)
        stream.flush()
        #expect(capture.text == "Hello\n")
    }

    @Test func toolDetailsUseFirstPresentKeyAndBoundLongValues() throws {
        let keys = ["command", "file_path", "path", "pattern", "url", "description"]
        for index in keys.indices {
            let input = Dictionary(uniqueKeysWithValues: keys[index...].map { ($0, $0 + " value") })
            let capture = RunCapture()
            let stream = AgentStream(emit: capture.add)
            stream.add(try toolEvent(input))
            #expect(capture.text == "> Tool: " + keys[index] + " value\n")
        }
        for count in [200, 201] {
            let capture = RunCapture()
            let stream = AgentStream(emit: capture.add)
            stream.add(try toolEvent(["command": String(repeating: "x", count: count)]))
            #expect(capture.text == "> Tool: " + String(repeating: "x", count: 200) + (count == 201 ? "..." : "") + "\n")
        }
    }

    @Test func claudeEngineArchivesReadableOutputAndReleasesAfterPull() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        let raw = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Engine readable answer"}]}}"#
        await f.box.wrapped.clearStreamFixtureOutput()
        await f.box.echo(Data((raw + "\n").utf8))
        let result = await f.engine.run(f.request(requireBox: true))
        #expect(result.state == .done && result.exitCode == 0)
        let archived = try await f.git.home.log(result.jobID)
        for text in [f.git.home.output.text, archived] {
            #expect(text == "Engine readable answer\n")
            #expect(!text.contains(raw) && !text.contains("\"type\""))
        }
        try await expectReleasedAfterPull(f, id: result.jobID)
    }

    @Test func codexEnginePreservesPrintedBytesAndReleasesAfterPull() async throws {
        let f = try await AgentEngineFixture.make(harness: .codex); defer { f.git.home.remove() }
        let printed = #"{"type":"assistant","message":{"content":[{"type":"text","text":"keep JSON"}]}}"# + "\nplain codex output\n"
        await f.box.wrapped.clearStreamFixtureOutput()
        await f.box.echo(Data(printed.utf8))
        let result = await f.engine.run(f.request(requireBox: true, harness: .codex))
        #expect(result.state == .done && result.exitCode == 0)
        let expected = Data(printed.utf8)
        #expect(Data(f.git.home.output.text.utf8) == expected)
        let archived = try await f.git.home.log(result.jobID)
        #expect(Data(archived.utf8) == expected)
        try await expectReleasedAfterPull(f, id: result.jobID)
    }

    @Test func failedImportStillReleasesAfterPullAttempt() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        let engine = try await failingImportEngine(f)
        let result = await engine.run(f.request(requireBox: true))
        #expect(result.state == .failed && result.exitCode == 4)
        #expect(f.git.home.notices.text.contains("result could not be imported"))
        try await expectReleasedAfterPull(f, id: result.jobID)
    }
}

private extension RunBox {
    func clearStreamFixtureOutput() { chunks = [] }
}

private func toolEvent(_ input: [String: String]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: [
        "type": "assistant", "message": ["content": [["type": "tool_use", "name": "Tool", "input": input]]]
    ] as [String: Any])
    data.append(10)
    return data
}

private func expectReleasedAfterPull(_ f: AgentEngineFixture, id: String) async throws {
    let calls = await f.box.calls
    let pull = try #require(calls.firstIndex(of: "pullTree"))
    let releases = calls.indices.filter { calls[$0] == "discardSecret:" + id }
    #expect(!releases.isEmpty)
    #expect(releases.allSatisfy { $0 > pull })
}

private func failingImportEngine(_ f: AgentEngineFixture) async throws -> RunEngine {
    let home = f.git.home
    var rules = Rules.shipped
    rules.destinations["ai-eu-1"]?.peerID = "n-ai-acme-1"
    rules.rules = [try JSONDecoder().decode(Rule.self, from: Data("""
    {"name":"stream import failure","match":{"command":["claude"]},"to":["ai-eu-1"],"image":"rx-rust"}
    """.utf8))]
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/tailnet/running.json").path
    let tailnet = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: runNow)
    let state = RulesState.valid(rules, fingerprint: "stream-import-failure")
    return RunEngine(ledger: home.ledger, archive: home.archive,
        router: Router(rules: state, tailnet: tailnet, probes: home.probes, fileExists: { _ in true }, now: { runNow }),
        boxes: BoxDirectory(rules: state, tailnet: tailnet, factory: StreamFailureFactory(box: f.box)), probes: home.probes,
        output: home.output.add, notice: home.notices.notice,
        profiles: ProfileStore(home: RMJHome(environment: ["RMJ_HOME": home.root.path])), now: { runNow },
        credentials: AgentCredentialsFake(raw: try agentCredentialJSON(), trace: f.box))
}

struct StreamFailureFactory: BoxFactory {
    let box: AgentBoxFake
    var afterSync: @Sendable () -> Void = {}
    var failImport = true
    func client(destination: String, address: String, config: DestinationConfig) -> BoxClient {
        StreamFailureBox(wrapped: box, afterSync: afterSync, failImport: failImport)
    }
}

private struct StreamFailureBox: BoxClient {
    let wrapped: AgentBoxFake
    let afterSync: @Sendable () -> Void
    let failImport: Bool
    func prepare(_ job: BoxJob) async throws { try await wrapped.prepare(job) }
    func begin(_ job: BoxJob, waiting: @escaping @Sendable (String) -> Void) async throws { try await wrapped.begin(job, waiting: waiting) }
    func sync(_ job: BoxJob) async throws { try await wrapped.sync(job); afterSync() }
    func go(_ job: BoxJob) async throws -> BoxLaunch { try await wrapped.go(job) }
    func tail(_ job: BoxJob, output: @escaping @Sendable (Data) -> Void) async throws { try await wrapped.tail(job, output: output) }
    func record(ulid: String) async throws -> BoxRecord { try await wrapped.record(ulid: ulid) }
    func pullLog(ulid: String, output: @escaping @Sendable (Data) -> Void) async throws { try await wrapped.pullLog(ulid: ulid, output: output) }
    func cancel(ulid: String) async throws { try await wrapped.cancel(ulid: ulid) }
    func ensureEgress(image: String, hosts: [String]) async throws { try await wrapped.ensureEgress(image: image, hosts: hosts) }
    func stageSecret(ulid: String, name: String, content: Data) async throws -> String {
        try await wrapped.stageSecret(ulid: ulid, name: name, content: content)
    }
    func discardSecret(ulid: String) async { await wrapped.discardSecret(ulid: ulid) }
    func pullTree(_ job: BoxJob, into local: URL) async throws {
        if failImport {
            await wrapped.mark("pullTree")
            throw BoxFailure("fixture result transfer failed")
        }
        try await wrapped.pullTree(job, into: local)
    }
}
