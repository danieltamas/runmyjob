import Testing
import Foundation
import RMJCore

private struct LiveRunFixture: Sendable {
    let root: URL
    let worktree: URL
    let ledger: Ledger
    let archive: LogArchive
    let boxes: BoxDirectory
    let engine: RunEngine
    let alias: String
    let home: String
    let address: String
    let client: SSHBoxClient

    static func make(slow: Bool = false) async throws -> LiveRunFixture {
        let tailnet = await TailnetState.read(environment: [:])
        #expect(tailnet.standing == .running)
        let alias = try #require(ProcessInfo.processInfo.environment["RMJ_LIVE_DESTINATION"])
        let configured = try #require(RulesStore(home: RMJHome()).load().rules)
        let config = try #require(configured.destinations[alias])
        var rules = Rules.shipped
        rules.destinations = [alias: config]
        rules.rules = [rules.rules[1]]
        rules.rules[0].to = [alias]
        rules.rules[0].match.tenant = nil
        let resolved = DestinationResolver.resolve(DestinationTarget(alias: config.sshAlias, peerID: config.peerID), in: tailnet)
        guard case .online(let address) = resolved else { throw BoxFailure(alias + " must be reachable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-live-" + UUID().uuidString)
        let worktree = root.appendingPathComponent("crate")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("[package]\nname = \"rmj_acceptance\"\nversion = \"0.1.0\"\nedition = \"2021\"\n".utf8)
            .write(to: worktree.appendingPathComponent("Cargo.toml"))
        try Data("pub fn acceptance() -> u32 { 42 }\n".utf8).write(to: worktree.appendingPathComponent("src/lib.rs"))
        if slow {
            try Data("fn main() { println!(\"cargo:warning=rmj live slow build\"); std::thread::sleep(std::time::Duration::from_secs(20)); }\n".utf8)
                .write(to: worktree.appendingPathComponent("build.rs"))
        }
        for args in [["init"], ["remote", "add", "origin", "git@github.com:acme/axon.git"]] {
            let result = try await ProcessRunner().run("/usr/bin/git", ["-C", worktree.path] + args, timeout: .seconds(10))
            guard result.status == 0 else { throw BoxFailure("git fixture failed: " + result.stderr) }
        }
        let database = try Database(url: root.appendingPathComponent("ledger.sqlite"))
        let ledger = Ledger(database: database)
        let archive = LogArchive(database: database, directory: root.appendingPathComponent("logs"))
        let state = RulesState.valid(rules, fingerprint: "live-shipped")
        let boxes = BoxDirectory(rules: state, tailnet: tailnet, factory: SSHBoxFactory())
        let probes = LiveProbeProvider()
        let router = Router(rules: state, tailnet: tailnet, probes: probes,
                            fileExists: { FileManager.default.fileExists(atPath: $0) })
        let engine = RunEngine(ledger: ledger, archive: archive, router: router, boxes: boxes, probes: probes,
                               output: { _ in }, notice: { _ in })
        return LiveRunFixture(root: root, worktree: worktree, ledger: ledger, archive: archive, boxes: boxes, engine: engine,
                              alias: alias, home: config.home, address: address, client: SSHBoxClient(address: address, alias: alias, home: config.home))
    }

    var request: RunRequest {
        RunRequest(command: ["cargo", "check"], identity: RepoIdentity(slug: "acme/axon", worktree: worktree.path))
    }
    func ssh(_ words: [String]) async throws -> ProcessOutput {
        let args = try SSH.arguments(address: address, alias: alias, command: words.map(SSH.quote))
        return try await ProcessRunner().run("/usr/bin/ssh", args, timeout: .seconds(15))
    }
    func containers(_ id: String) async throws -> String {
        let response = try await ssh(["docker", "ps", "-aq", "--filter", "label=rmj.job=" + id])
        #expect(response.status == 0)
        return String(decoding: response.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func runningID() async throws -> String {
        for _ in 0..<240 {
            if let row = try await ledger.jobs(in: [.running]).first { return row.id }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw BoxFailure("live run did not reach running within 60 seconds")
    }
    func assertDone(_ id: String) async throws {
        let row = try #require(try await ledger.job(id))
        #expect(row.state == .done && row.exitCode == 0 && row.location == alias)
        #expect(row.boxStartedAt != nil && row.boxEndedAt != nil)
        #expect(row.syncStartedAt != nil && row.syncEndedAt != nil)
        if case .box = row.duration {} else { Issue.record("missing box duration") }
        let entry = try #require(try await archive.entry(jobID: id))
        #expect(entry.status == .available && !entry.truncated)
        let text = try String(contentsOfFile: #require(entry.path), encoding: .utf8)
        #expect(text.contains("Finished") || text.contains("Checking"))
        #expect(try await containers(id).isEmpty)
    }
    func cleanup(ids: [String] = [], directory: String? = nil, lock: String? = nil) async {
        for id in ids { try? await client.cancel(ulid: id) }
        var paths = [String]()
        if let directory { paths.append(directory) }
        if let lock { paths.append(lock) }
        if !paths.isEmpty { _ = try? await ssh(["rm", "-rf", "--"] + paths) }
        try? FileManager.default.removeItem(at: root)
    }
}

private actor LiveBeginState {
    var returned = false
    func finish() { returned = true }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RMJ_LIVE"] == "1" &&
    !(ProcessInfo.processInfo.environment["RMJ_LIVE_DESTINATION"] ?? "").isEmpty))
struct LiveRunTests {
    @Test func liveCargoCheckHasBoxTimesCompleteLogAndNoContainer() async throws {
        let f = try await LiveRunFixture.make()
        let result = await f.engine.run(f.request)
        do {
            #expect(result.exitCode == 0 && result.state == .done)
            try await f.assertDone(result.jobID)
        } catch { await f.cleanup(ids: [result.jobID]); throw error }
        await f.cleanup(ids: [result.jobID])
    }

    @Test func liveClientTaskDeathLeavesContainerToFinishAndReconcile() async throws {
        let f = try await LiveRunFixture.make(slow: true)
        let task = Task { await f.engine.run(f.request) }
        var id: String?
        do {
            let jobID = try await f.runningID(); id = jobID
            try await Task.sleep(for: .seconds(8))
            task.cancel()
            let detached = await task.value
            #expect(detached.jobID == jobID && detached.state == .running)
            #expect(try await f.ledger.job(jobID)?.state == .running)
            #expect(try await f.archive.entry(jobID: jobID)?.status == .pending)
            var completed = false
            for _ in 0..<160 {
                if try await f.client.record(ulid: jobID).result != nil { completed = true; break }
                try await Task.sleep(for: .milliseconds(250))
            }
            #expect(completed)
            await Reconciler(ledger: f.ledger, archive: f.archive, boxes: f.boxes).reconcile()
            try await f.assertDone(jobID)
            let entry = try #require(try await f.archive.entry(jobID: jobID))
            let text = try String(contentsOfFile: #require(entry.path), encoding: .utf8)
            #expect(text.contains("rmj live slow build") && text.contains("Finished"))
        } catch {
            task.cancel(); await f.cleanup(ids: id.map { [$0] } ?? []); _ = await task.value; throw error
        }
        await f.cleanup(ids: id.map { [$0] } ?? [])
    }

    @Test func liveCancelRemovesContainerWithinTenSeconds() async throws {
        let f = try await LiveRunFixture.make(slow: true)
        let task = Task { await f.engine.run(f.request) }
        var id: String?
        do {
            let jobID = try await f.runningID(); id = jobID
            try await Task.sleep(for: .seconds(8))
            let began = ContinuousClock.now
            #expect(await f.engine.cancel(jobID) == .cancelled)
            #expect(try await f.containers(jobID).isEmpty)
            #expect(began.duration(to: .now) <= .seconds(10))
            #expect(try await f.ledger.job(jobID)?.state == .cancelled)
            _ = await task.value
        } catch {
            task.cancel(); await f.cleanup(ids: id.map { [$0] } ?? []); _ = await task.value; throw error
        }
        await f.cleanup(ids: id.map { [$0] } ?? [])
    }

    @Test func liveBoxLockWaitsForHolderUntilCancelled() async throws {
        let f = try await LiveRunFixture.make()
        let random = UUID().uuidString.lowercased()
        let directory = f.home + "/rx/rmj-live/" + random
        let lock = f.home + "/rx/.rmj-live-" + random + ".lock"
        let first = ULID.make(), second = ULID.make()
        func job(_ id: String) -> BoxJob {
            BoxJob(ulid: id, name: ULID.containerName(repo: nil, ulid: id), worktree: f.worktree.path,
                   directory: directory, argv: ["true"], options: [], image: "rx-rust", locks: [lock])
        }
        let notices = RunCapture(), state = LiveBeginState()
        var waiter: Task<Void, Error>?
        do {
            try await f.client.prepare(job(first))
            try await f.client.begin(job(first), waiting: { _ in Issue.record("first job unexpectedly waited") })
            try await f.client.prepare(job(second))
            let secondTask = Task {
                try await f.client.begin(job(second), waiting: notices.notice)
                await state.finish()
            }
            waiter = secondTask
            for _ in 0..<80 {
                if notices.text.contains(first) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(notices.text.split(separator: "\n").contains(Substring(first)))
            #expect(await state.returned == false)
            try await f.client.cancel(ulid: first)
            for _ in 0..<100 {
                if await state.returned { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(await state.returned)
            // Cancel also releases the second waiter before awaiting on failure.
            try await f.client.cancel(ulid: second)
            try await secondTask.value
        } catch {
            waiter?.cancel()
            await f.cleanup(ids: [first, second], directory: directory, lock: lock)
            if let waiter { _ = try? await waiter.value }
            throw error
        }
        await f.cleanup(ids: [first, second], directory: directory, lock: lock)
    }
}
