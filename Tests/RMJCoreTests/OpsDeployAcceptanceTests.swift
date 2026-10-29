import Testing
import Foundation
import RMJCore
import CryptoKit

// Shared U6 fakes never launch a process or contact a host.
final class FakeShell: OpsShell, @unchecked Sendable {
    struct Call: Sendable {
        let script: String
        let input: Data?
        let directory: URL?
        let remote: String?
    }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var inspections = 0
    let answer: @Sendable (String, Int) -> ProcessOutput
    init(answer: @escaping @Sendable (String, Int) -> ProcessOutput = { _, _ in u6Output() }) {
        self.answer = answer
    }
    var calls: [Call] { lock.withLock { recorded } }
    func run(_ script: String, input: Data?, timeout: Duration) async throws -> ProcessOutput {
        let count = lock.withLock {
            recorded.append(Call(script: script, input: input, directory: nil, remote: nil))
            if script.contains("docker inspect -f") { inspections += 1 }
            return inspections
        }
        return answer(script, count)
    }
    func sync(directory: URL, to remote: String) async throws {
        lock.withLock { recorded.append(Call(script: "sync", input: nil, directory: directory, remote: remote)) }
    }
}

final class U6Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

func u6Output(_ text: String = "", status: Int32 = 0, stderr: String = "") -> ProcessOutput {
    ProcessOutput(status: status, stdout: Data(text.utf8), stderr: stderr)
}

struct U6Fixture: Sendable {
    let directory: URL
    let database: Database
    var ledger: Ledger { Ledger(database: database) }
    var logs: URL { directory.appendingPathComponent("logs") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-u6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("logs"), withIntermediateDirectories: true)
        database = try Database(url: directory.appendingPathComponent("ledger.sqlite"))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func job(_ id: String, github: Bool = false) -> JobRecord {
        var row = JobRecord(id: id, repo: "acme/atlas", command: "test", location: "ai-eu-1",
                            destination: "ai-eu-1", state: .running, queuedAt: u6Now)
        row.agent = "claude-code"
        if github {
            row.github = """
            {"repo":"acme/atlas","name":"check","runId":1,"jobId":77,"runAttempt":1,
            "status":"in_progress","runnerName":"abc123abc123-1790000000","labels":[],
            "stepsDone":0,"stepsTotal":0,"waitingOnDependency":false}
            """
        }
        return row
    }
}

let u6Now = Date(timeIntervalSince1970: 1_793_102_400)
private let u6Stack = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Support/runner-stack")
private let u6Tokens = ["acme/ledger": "github_pat_fixture123", "org:Acme": "github_pat_fixture123"]
private let u6Env = "GH_PAT_ACME=github_pat_fixture123\n"
private let u6Targets = u6Tokens.keys.sorted()
private var u6Compose: RunnerCompose {
    RunnerCompose(base: try! String(contentsOf: u6Stack.appendingPathComponent("docker-compose.yml"), encoding: .utf8),
                  targets: u6Targets, host: "fixture-box")
}
private let u6Containers = "runner-z\tz123\tgh-runner:2.338.2\texited\tExited (0)\nrunner-a\ta123\tgh-runner:2.338.2\trunning\tUp 2 hours\n"

private func u6SHA(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func u6RegularFiles(under directory: URL) throws -> [URL] {
    let walker = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    var files: [URL] = []
    for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        files.append(url)
    }
    return files
}

private func u6Hashes() throws -> [String: String] {
    let walker = try #require(FileManager.default.enumerator(at: u6Stack, includingPropertiesForKeys: [.isRegularFileKey]))
    var hashes: [String: String] = [:]
    for case let url as URL in walker {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true, url.lastPathComponent != ".env" {
            hashes[String(url.path.dropFirst(u6Stack.path.count + 1))] = u6SHA(try Data(contentsOf: url))
        }
    }
    #expect(!hashes.isEmpty)
    return hashes
}

private func u6DeployShell(changed: String? = nil, envMatches: Bool = true,
                           composeStatus: Int32 = 0, echo: String = "") throws -> FakeShell {
    var hashes = try u6Hashes()
    if let changed { hashes[changed] = "different" }
    let lines = hashes.sorted { $0.key < $1.key }.map { "\($0.value)  \($0.key)" }.joined(separator: "\n")
    return FakeShell { script, _ in
        if script.contains("docker ps -a") { return u6Output(u6Containers) }
        if script.contains("sha256sum"), script.contains("| cut ") {
            if script.contains("/.rmj-services'") { return u6Output(u6SHA(Data(u6Compose.manifest.utf8))) }
            if script.contains("/docker-compose.rmj.yml'") { return u6Output(u6SHA(Data((u6Compose.generated ?? "").utf8))) }
            return u6Output(envMatches ? u6SHA(Data(u6Env.utf8)) : "")
        }
        if script.contains("sha256sum") { return u6Output(lines) }
        if script.contains("docker compose") { return u6Output(echo, status: composeStatus, stderr: echo) }
        return u6Output()
    }
}

private func u6Deployer(_ shell: FakeShell, tokens: [String: String] = u6Tokens,
                        notice: @escaping @Sendable (String) -> Void = { _ in }) -> RunnerStackDeployer {
    RunnerStackDeployer(shell: shell, stack: u6Stack, home: "/home/fixture", tokens: tokens, requiredTargets: tokens.keys.sorted(), host: "fixture-box", notice: notice)
}

struct OpsDeployAcceptanceTests {
    @Test func dryRunIsReadOnlyAndReportsExactChangesAndRunnerFields() async throws {
        let shell = try u6DeployShell()
        let report = try await u6Deployer(shell).report()
        #expect(report.isNoOp && report.changedFiles.isEmpty && !report.envChanged)
        #expect(report.performed.isEmpty)
        #expect(report.runners.map(\.name) == ["runner-a", "runner-z"])
        #expect(report.runners.map(\.id) == ["a123", "z123"])
        #expect(report.runners.map(\.image) == ["gh-runner:2.338.2", "gh-runner:2.338.2"])
        #expect(report.runners.map(\.state) == ["running", "exited"])
        #expect(report.runners.map(\.status) == ["Up 2 hours", "Exited (0)"])
        #expect(report.runners.map(\.version) == ["2.338.2", "2.338.2"])
        #expect(shell.calls.allSatisfy { $0.directory == nil && $0.input == nil && !$0.script.contains("cat >") && !$0.script.contains("mv ") && !$0.script.contains("docker compose") })
        let empty = try u6DeployShell(envMatches: false)
        #expect(try await u6Deployer(empty, tokens: [:]).report().envChanged == false)
        #expect(!empty.calls.contains { $0.script.contains("/.env'") })
        let name = try #require(try u6Hashes().keys.sorted().first)
        let changed = try u6DeployShell(changed: name)
        #expect(try await u6Deployer(changed).report().changedFiles == [name])
        #expect(changed.calls.allSatisfy { $0.directory == nil && $0.input == nil && !$0.script.contains("docker compose") })
    }

    @Test func deploySyncsThenAtomicallyWritesStdinEnvBeforeBuildAndUp() async throws {
        let name = try #require(try u6Hashes().keys.sorted().first)
        let shell = try u6DeployShell(changed: name, envMatches: false)
        let report = try await u6Deployer(shell).deploy()
        let calls = shell.calls
        let sync = try #require(calls.firstIndex { $0.directory != nil })
        #expect(calls.filter { $0.directory != nil }.count == 1)
        #expect(calls[sync].directory == u6Stack)
        #expect(calls[sync].remote == "/home/fixture/infra/gh-runners")
        let write = try #require(calls.firstIndex { $0.input != nil })
        #expect(calls[write].input == Data(u6Env.utf8))
        for fragment in ["umask 077", "mktemp", "$d/.env.", "cat >", "chmod 600", "mv", "/home/fixture/infra/gh-runners"] {
            #expect(calls[write].script.contains(fragment))
        }
        let generated = try #require(calls.first { $0.input == Data((u6Compose.generated ?? "").utf8) })
        #expect(generated.script.contains("docker-compose.rmj.yml"))
        let build = try #require(calls.firstIndex { $0.script.contains("docker compose build") })
        #expect(calls[build].script.contains("COMPOSE_FILE=docker-compose.yml:docker-compose.rmj.yml"))
        #expect(calls[build].script.contains("'runner-ledger' 'runner-acme'"))
        let up = try #require(calls.firstIndex { $0.script.contains("docker compose up -d") })
        #expect(sync < write && write < build && build < up)
        #expect(report.performed == ["synced 1 files", "wrote .env", "wrote docker-compose.rmj.yml", "docker compose build", "docker compose up -d"])
        for token in u6Tokens.values { #expect(calls.allSatisfy { !$0.script.contains(token) }) }
        let unchanged = try u6DeployShell()
        #expect(try await u6Deployer(unchanged).deploy().performed.isEmpty)
        #expect(unchanged.calls.allSatisfy { $0.directory == nil && $0.input == nil && !$0.script.contains("docker compose") })
        #expect(RunnerTarget.environmentName("acme/x") == "GH_PAT_ACME")
        #expect(RunnerTarget.environmentName("org:Acme") == "GH_PAT_ACME")
    }

    @Test func deployRedactsEchoedSecretsRejectsBadTokensAndNeverPersistsPATs() async throws {
        let f = try U6Fixture(); defer { f.remove() }
        try await f.ledger.insert(f.job("rx-safe"))
        let archive = LogArchive(database: f.database, directory: f.logs)
        let writer = try archive.writer(jobID: "rx-safe", secrets: [])
        await writer.write(Data("safe log\n".utf8))
        let notices = U6Messages()
        let (stream, continuation) = AsyncStream<String>.makeStream()
        defer { continuation.finish() }
        let persist = Task {
            for await message in stream {
                await writer.write(Data(message.utf8))
                try await f.ledger.advance("rx-safe", to: .running, at: u6Now, detail: message)
            }
        }
        let echo = u6Tokens.values.sorted().joined(separator: "\n")
        for status in [Int32(0), Int32(1)] {
            let shell = try u6DeployShell(envMatches: false, composeStatus: status, echo: echo)
            do {
                _ = try await u6Deployer(shell, notice: { notices.append($0); continuation.yield($0) }).deploy()
                #expect(status == 0)
            } catch let error as RunnerStackDeployer.Failure {
                guard case .remote = error else { Issue.record("Expected remote failure"); continue }
                #expect(status == 1)
                for token in u6Tokens.values { #expect(!error.description.contains(token)) }
            }
        }
        continuation.finish()
        try await persist.value
        try await writer.finish(complete: true, now: u6Now)
        #expect(!notices.values.isEmpty)
        for token in u6Tokens.values { #expect(notices.values.allSatisfy { !$0.contains(token) }) }
        for bad in ["ghp_bad\nINJECT", "ghp_bad=value", "ghp_bad value"] {
            do {
                _ = try await u6Deployer(try u6DeployShell(), tokens: ["acme/x": bad]).deploy()
                Issue.record("Bad token accepted")
            } catch let error as RunnerStackDeployer.Failure {
                #expect(error == .badToken("acme/x"))
            }
        }
        await #expect(throws: RunnerStackDeployer.Failure.conflictingTokens("GH_PAT_ACME")) {
            _ = try await u6Deployer(try u6DeployShell(), tokens: ["acme/x": "ghp_one", "acme/y": "ghp_two"]).deploy()
        }
        // Scan SQLite, WAL, SHM and every local log, including bytes not yet checkpointed.
        for url in try u6RegularFiles(under: f.directory) {
            let bytes = try Data(contentsOf: url)
            for token in u6Tokens.values { #expect(bytes.range(of: Data(token.utf8)) == nil) }
        }
    }

    @Test func imagesFilterRepositoriesAndBuildOnlyValidatedNamesViaStdin() async throws {
        let shell = FakeShell { script, _ in
            if script.contains("docker images") {
                return u6Output("rx-rust\tlatest\t2026-10-25\t2 days ago\ngh-runner\t2.338.2\t2026-10-26\t1 day ago\nubuntu\tlatest\ttoday\t1 hour ago\nrx-node\tdev\ttoday\t1 hour ago\ngh-runner-other\tx\ttoday\tnow\n")
            }
            return u6Output()
        }
        let images = try await RunnerImages.list(shell: shell)
        #expect(images.map(\.repository) == ["rx-rust", "gh-runner", "rx-node"])
        #expect(images.map(\.tag) == ["latest", "2.338.2", "dev"])
        #expect(images[0].created == "2026-10-25" && images[0].age == "2 days ago")
        let dockerfile = Data("FROM fixture\n".utf8)
        try await RunnerImages.build(name: "rust", dockerfile: dockerfile, shell: shell)
        let hash = SHA256.hash(data: dockerfile).map { String(format: "%02x", $0) }.joined()
        #expect(shell.calls.last?.script == "docker build --label rmj.dockerfile=\(hash) -t rx-rust -")
        #expect(shell.calls.last?.input == dockerfile)
        let count = shell.calls.count
        for bad in ["bad name", "bad/name"] {
            await #expect(throws: RunnerStackDeployer.Failure.self) {
                try await RunnerImages.build(name: bad, dockerfile: dockerfile, shell: shell)
            }
        }
        #expect(shell.calls.count == count)
    }
}
