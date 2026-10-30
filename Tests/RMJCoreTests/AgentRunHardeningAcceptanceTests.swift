import Foundation
import Testing
@testable import RMJCore

struct AgentRunHardeningAcceptanceTests {
    @Test func repositoryAndResultAttributesNeverExecuteCleanFilters() async throws {
        let f = try await AgentGitFixture.make(); defer { f.home.remove() }
        let marker = f.home.root.appendingPathComponent("filter-ran")
        let script = f.home.root.appendingPathComponent("evil-clean")
        try Data(("#!/bin/sh\ntouch '" + marker.path + "'\nprintf 'FILTERED\\n'\ncat >/dev/null\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = try await f.git(["config", "filter.evil.clean", "'" + script.path + "'"])
        try f.write(f.repo, ".gitattributes", "* filter=evil\n")
        let original = Data([0, 1, 13, 10, 255, 65, 10])
        try original.write(to: f.repo.appendingPathComponent("payload.bin"))
        let base = try await AgentBranch.snapshot(worktree: f.repo)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try await f.rawGit(["show", base + ":payload.bin"]) == original)
        let result = try await f.materialize(base)
        try f.write(result, ".gitattributes", "* filter=evil\n*.bin filter=evil\n")
        let changed = Data([255, 0, 66, 13, 10, 67, 13, 10])
        try changed.write(to: result.appendingPathComponent("payload.bin"))
        let outcome = try await AgentBranch.record(worktree: f.repo, base: base, result: result,
                                                   jobID: "hardening-filters", message: "filter safety")
        let commit = try createdCommit(outcome)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let paths = try await f.rawGit(["ls-tree", "-rz", "--name-only", commit]).split(separator: 0)
        for bytes in paths {
            let path = String(decoding: bytes, as: UTF8.self)
            #expect(try await f.rawGit(["show", commit + ":" + path]) == Data(contentsOf: result.appendingPathComponent(path)))
        }
    }

    @Test func trackedIgnoredFileSurvivesWithOriginalBlobAndOnlyAgentChange() async throws {
        let f = try await AgentGitFixture.make(); defer { f.home.remove() }
        try f.write(f.repo, "hidden.txt", "tracked but ignored\n")
        _ = try await f.git(["add", "--all"])
        try await commitFixture(f, message: "track hidden file")
        try f.write(f.repo, ".gitignore", "hidden.txt\n")
        _ = try await f.git(["add", ".gitignore"])
        try await commitFixture(f, message: "ignore tracked file")
        let head = try await f.git(["rev-parse", "HEAD"])
        let blob = try await f.git(["rev-parse", head + ":hidden.txt"])
        let base = try await AgentBranch.snapshot(worktree: f.repo)
        #expect(try await f.git(["rev-parse", base + ":hidden.txt"]) == blob)
        let result = try await f.materialize(base)
        #expect(try Data(contentsOf: result.appendingPathComponent("hidden.txt")) == Data("tracked but ignored\n".utf8))
        try f.write(result, "hidden.txt", "agent edited tracked ignored file\n")
        try f.write(result, "tracked.txt", "real agent change\n")
        let outcome = try await AgentBranch.record(worktree: f.repo, base: base, result: result,
                                                   jobID: "hardening-ignore", message: "preserve ignored file")
        let commit = try createdCommit(outcome)
        #expect(try await f.rawGit(["show", commit + ":hidden.txt"]) == Data("agent edited tracked ignored file\n".utf8))
        #expect(try await f.git(["rev-parse", commit + ":hidden.txt"]) != blob)
        #expect(try await f.git(["diff-tree", "--no-commit-id", "--name-only", "-r", head, commit]) == "hidden.txt\ntracked.txt")
        #expect(try Data(contentsOf: f.repo.appendingPathComponent("hidden.txt")) == Data("tracked but ignored\n".utf8))

        let unchangedResult = try await f.materialize(base)
        #expect(try Data(contentsOf: unchangedResult.appendingPathComponent("hidden.txt")) == Data("tracked but ignored\n".utf8))
        let unchanged = try await AgentBranch.record(worktree: f.repo, base: base, result: unchangedResult,
            jobID: "hardening-ignore-unchanged", message: "unchanged tracked ignored file")
        #expect(unchanged == .unchanged)
        #expect(try await f.git(["diff-tree", "--no-commit-id", "--name-only", "-r", head, base]).isEmpty)
    }

    @Test func explicitParentWinsOverMovedHeadAndDefaultUsesCurrentHead() async throws {
        let f = try await AgentGitFixture.make(); defer { f.home.remove() }
        let oldHead = try await f.git(["rev-parse", "HEAD"])
        let base = try await AgentBranch.snapshot(worktree: f.repo)
        let result = try await f.materialize(base)
        try f.write(result, "tracked.txt", "agent edit\n")
        try f.write(f.repo, "later.txt", "new HEAD\n")
        _ = try await f.git(["add", "later.txt"])
        try await commitFixture(f, message: "move HEAD after snapshot")
        let newHead = try await f.git(["rev-parse", "HEAD"])
        #expect(newHead != oldHead)
        let explicit = try await AgentBranch.record(worktree: f.repo, base: base, result: result,
            jobID: "hardening-explicit-parent", message: "explicit parent", parent: oldHead)
        let implicit = try await AgentBranch.record(worktree: f.repo, base: base, result: result,
            jobID: "hardening-default-parent", message: "default parent")
        #expect(try await f.git(["rev-parse", createdCommit(explicit) + "^"]) == oldHead)
        #expect(try await f.git(["rev-parse", createdCommit(implicit) + "^"]) == newHead)
    }

    @Test func echoedStagedTokenIsMaskedInOutputAndArchiveAndTmpIsTmpfs() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        let box = HardeningBox(wrapped: f.box, mode: .echo)
        let engine = try await hardeningEngine(f, box: box)
        let result = await engine.run(f.request(requireBox: true))
        #expect(result.exitCode == 0 && result.state == .done)
        #expect(await f.box.staged.count == 1)
        for surface in [f.git.home.output.text, try await f.git.home.log(result.jobID)] {
            #expect(surface.contains("echo [redacted] end"))
            #expect(!surface.contains("ACCESS-TOKEN-1234"))
        }
        let job = try #require(await f.box.goJobs.first)
        let tmpfs = job.options.indices.contains { index in
            job.options[index] == "--tmpfs" && index + 1 < job.options.count &&
                (job.options[index + 1] == "/tmp" || job.options[index + 1].hasPrefix("/tmp:"))
        }
        #expect(tmpfs)
    }

    @Test func traversalInStagedDirectoryIsRejectedBeforeGo() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        let box = HardeningBox(wrapped: f.box, mode: .traversal)
        let engine = try await hardeningEngine(f, box: box)
        let result = await engine.run(f.request(requireBox: true))
        #expect(result.exitCode == 3 && result.state == .failed)
        #expect(await f.box.staged.count == 1)
        #expect(await f.box.goJobs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.local.path))
        let prepared = await AgentSession.prepare(try #require(f.request().agentTask),
            source: AgentCredentialsFake(raw: try agentCredentialJSON(), trace: f.box), now: runNow)
        guard case .success(let session) = prepared else { Issue.record("valid credentials rejected"); return }
        let job = BoxJob(ulid: "traversal", name: "test", worktree: f.git.repo.path,
                         directory: "/work", argv: [], options: [], image: "rx-claude")
        do {
            _ = try await session.stage(job, client: box)
            Issue.record("stage accepted a credentials path containing ..")
        } catch is BoxFailure {
            // The untrusted directory must be rejected by stage itself.
        }
    }

    @Test func successfulHarnessWithFailedImportReturnsFourAndExplainsFailure() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        await f.box.configure(code: 0)
        let box = HardeningBox(wrapped: f.box, mode: .pullFailure)
        let engine = try await hardeningEngine(f, box: box)
        let result = await engine.run(f.request(requireBox: true))
        #expect(await f.box.goJobs.count == 1)
        #expect(await box.pullAttempts == 1)
        #expect(result.exitCode == 4 && result.state == .failed)
        #expect(f.git.home.notices.text.contains("result could not be imported"))
        #expect(!FileManager.default.fileExists(atPath: f.local.path))
    }

    @Test func unavailableLedgerWithRequiredBoxNeverExecutesLocalCommand() async throws {
        let f = try await AgentEngineFixture.make(); defer { f.git.home.remove() }
        let blocker = f.git.home.root.appendingPathComponent("not-a-directory")
        try Data("regular file".utf8).write(to: blocker)
        let request = f.request(requireBox: true)
        let code = await RunCommand.dispatch(command: request.command, shell: false, destination: nil,
            agentTask: request.agentTask, environment: ["RMJ_HOME": blocker.appendingPathComponent("home").path])
        #expect(code == 3)
        #expect(!FileManager.default.fileExists(atPath: f.local.path))
    }

    @Test func timeoutMultiplicationOverflowIsUsageFailure() {
        #expect(throws: AgentRunCommand.Failure.usage) {
            try AgentRunCommand.parse(["--timeout", "9223372036854775807h", "--", "task"])
        }
    }
}

private func createdCommit(_ outcome: AgentBranch.Outcome) throws -> String {
    guard case .created(_, let commit) = outcome else {
        Issue.record("changed result must create a commit")
        throw BoxFailure("expected result commit")
    }
    return commit
}

private func commitFixture(_ f: AgentGitFixture, message: String) async throws {
    _ = try await f.git(["-c", "user.name=Acceptance", "-c", "user.email=acceptance@example.invalid", "commit", "-m", message])
}

// Reuse the fixture's probe and captures; only replace the box's fault boundary.
// rx-rust is advertised by the shared RunFixture probe; no real image is launched.
private func hardeningEngine(_ f: AgentEngineFixture, box: HardeningBox) async throws -> RunEngine {
    let home = f.git.home
    var rules = Rules.shipped
    rules.destinations["ai-eu-1"]?.peerID = "n-ai-acme-1"
    rules.rules = [try JSONDecoder().decode(Rule.self, from: Data("""
    {"name":"hardening","match":{"command":["claude"]},"to":["ai-eu-1"],"image":"rx-rust"}
    """.utf8))]
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/tailnet/running.json").path
    let tailnet = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: runNow)
    let state = RulesState.valid(rules, fingerprint: "hardening")
    return RunEngine(ledger: home.ledger, archive: home.archive,
        router: Router(rules: state, tailnet: tailnet, probes: home.probes, fileExists: { _ in true }, now: { runNow }),
        boxes: BoxDirectory(rules: state, tailnet: tailnet, factory: HardeningFactory(box: box)), probes: home.probes,
        output: home.output.add, notice: home.notices.notice,
        profiles: ProfileStore(home: RMJHome(environment: ["RMJ_HOME": home.root.path])), now: { runNow },
        credentials: AgentCredentialsFake(raw: try agentCredentialJSON(), trace: f.box))
}

private struct HardeningFactory: BoxFactory {
    let box: HardeningBox
    func client(destination: String, address: String, config: DestinationConfig) -> BoxClient { box }
}

private actor HardeningBox: BoxClient {
    enum Mode: Sendable { case echo, traversal, pullFailure }
    let wrapped: AgentBoxFake
    let mode: Mode
    var token = ""
    private(set) var pullAttempts = 0
    init(wrapped: AgentBoxFake, mode: Mode) { self.wrapped = wrapped; self.mode = mode }
    func prepare(_ job: BoxJob) async throws { try await wrapped.prepare(job) }
    func begin(_ job: BoxJob, waiting: @escaping @Sendable (String) -> Void) async throws {
        try await wrapped.begin(job, waiting: waiting)
    }
    func sync(_ job: BoxJob) async throws { try await wrapped.sync(job) }
    func go(_ job: BoxJob) async throws -> BoxLaunch { try await wrapped.go(job) }
    func tail(_ job: BoxJob, output: @escaping @Sendable (Data) -> Void) async throws {
        if mode == .echo { output(Data(("echo " + token + " end\n").utf8)) }
        try await wrapped.tail(job, output: output)
    }
    func record(ulid: String) async throws -> BoxRecord { try await wrapped.record(ulid: ulid) }
    func pullLog(ulid: String, output: @escaping @Sendable (Data) -> Void) async throws {
        if mode == .echo { output(Data(("echo " + token + " end\n").utf8)) }
        try await wrapped.pullLog(ulid: ulid, output: output)
    }
    func cancel(ulid: String) async throws { try await wrapped.cancel(ulid: ulid) }
    func stageSecret(ulid: String, name: String, content: Data) async throws -> String {
        let directory = try await wrapped.stageSecret(ulid: ulid, name: name, content: content)
        let json = try #require(try JSONSerialization.jsonObject(with: content) as? [String: Any])
        let oauth = try #require(json["claudeAiOauth"] as? [String: Any])
        token = try #require(oauth["accessToken"] as? String)
        return mode == .traversal ? "/dev/shm/../etc/rmj-" + ulid : directory
    }
    func discardSecret(ulid: String) async { await wrapped.discardSecret(ulid: ulid) }
    func pullTree(_ job: BoxJob, into local: URL) async throws {
        pullAttempts += 1
        if mode == .pullFailure { throw BoxFailure("result transfer unavailable") }
        try await wrapped.pullTree(job, into: local)
    }
}
