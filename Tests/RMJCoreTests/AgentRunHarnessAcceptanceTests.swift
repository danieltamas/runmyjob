import Foundation
import Testing
@testable import RMJCore

let codexID = "CODEX-ID-SECRET-1234"
let codexRefresh = "CODEX-REFRESH-SECRET-9876"

func codexAccess(lifetime: TimeInterval = 7200) throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: ["exp": runNow.addingTimeInterval(lifetime).timeIntervalSince1970])
        .base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJub25lIn0." + payload + ".fixture-signature"
}

func codexCredentialJSON(lifetime: TimeInterval = 7200) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
        "tokens": ["id_token": codexID, "access_token": try codexAccess(lifetime: lifetime),
                   "refresh_token": codexRefresh, "account_id": "acceptance-account"],
        "last_refresh": "2026-10-30T00:00:00Z"])
}

struct AgentRunHarnessAcceptanceTests {
    @Test func profileNetworkIsReplacedWithoutReorderingOtherOptions() async throws {
        for harness in [AgentHarness.claude, .codex] {
            let f = try await AgentEngineFixture.reviewFix(harness: harness, profileNetwork: "some-other")
            defer { f.git.home.remove() }
            let result = await f.engine.run(f.request(requireBox: true, harness: harness))
            #expect(result.exitCode == 0)
            let job = try #require(await f.box.goJobs.first)
            let home = try #require(Rules.shipped.destinations["ai-eu-1"]).home
            let expected = ["--cpus", "2", "--memory", "4g", "--cap-drop", "ALL",
                "--security-opt", "no-new-privileges", "--pids-limit", "4096",
                "-v", job.directory + ":/work", "-w", "/work", "--user", "@box",
                "-e", "KEEP=ordered", "-v", "keep-volume:/kept",
                "-v", "\(home)/rx/.prelude/agent-\(harness.program).sh:/prelude.sh:ro"]
            #expect(Array(job.options.prefix(expected.count)) == expected)
            let networkIndices = job.options.indices.filter {
                ["--network", "--net"].contains(job.options[$0]) ||
                job.options[$0].hasPrefix("--network=") || job.options[$0].hasPrefix("--net=")
            }
            #expect(networkIndices.count == 1)
            let index = try #require(networkIndices.first)
            #expect(Array(job.options[index..<min(index + 2, job.options.count)]) == ["--network", "rmj-agents"])
            #expect(!job.options.contains("some-other"))
        }
    }

    @Test func queuedCredentialsAreRecheckedBeforeStagingOrLaunch() async throws {
        for harness in [AgentHarness.claude, .codex] {
            for requireBox in [false, true] {
                let clock = ReviewClock()
                let f = try await AgentEngineFixture.reviewFix(harness: harness, lifetime: 700,
                    now: clock.now, afterSync: { clock.advance(200) })
                defer { f.git.home.remove() }
                var request = f.request(requireBox: requireBox, harness: harness)
                request.agentTask = AgentTask(harness: harness, prompt: "change the code", timeoutSeconds: 600,
                    requireBox: requireBox)
                let result = await f.engine.run(request)
                let row = try #require(try await f.git.home.ledger.job(result.jobID))
                #expect(clock.now() == runNow.addingTimeInterval(200))
                #expect(await f.box.calls.contains("begin"))
                #expect(await f.box.calls.contains("sync"))
                #expect(await f.box.staged.isEmpty)
                #expect(await f.box.goJobs.isEmpty)
                #expect(row.fallbackReason == harness.program + " login expires soon")
                #expect(result.exitCode == (requireBox ? 3 : 0))
                #expect(row.state == (requireBox ? .failed : .done))
                #expect(FileManager.default.fileExists(atPath: f.local.path) == !requireBox)
            }
        }
    }

    @Test func codexAPIKeyIsNullAndAbsentFromEveryStagedByte() async throws {
        let key = "OPENAI-API-KEY-MUST-NOT-STAGE-2468"
        var raw = try #require(try JSONSerialization.jsonObject(with: codexCredentialJSON()) as? [String: Any])
        raw["OPENAI_API_KEY"] = key
        let f = try await AgentEngineFixture.reviewFix(harness: .codex,
            raw: JSONSerialization.data(withJSONObject: raw))
        defer { f.git.home.remove() }
        let result = await f.engine.run(f.request(requireBox: true, harness: .codex))
        #expect(result.exitCode == 0)
        let staged = await f.box.staged
        #expect(!staged.isEmpty)
        for (_, _, bytes) in staged {
            #expect(bytes.range(of: Data(key.utf8)) == nil)
            let login = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(login["OPENAI_API_KEY"] is NSNull)
        }
    }

    @Test func harnessAndCommandContracts() throws {
        for harness in [AgentHarness.claude, .codex] {
            #expect(harness.program == (harness == .claude ? "claude" : "codex"))
            #expect(harness.image == (harness == .claude ? "rx-claude" : "rx-codex"))
            #expect(try AgentRunCommand.parse(["--harness", harness.program, "--", "p"]).harness == harness)
        }
        #expect(try AgentRunCommand.parse(["--", "p"]).harness == .claude)
        for args in [["--harness", "unknown", "--", "p"], ["--harness"],
                     ["--harness", "codex", "--allow", "Read", "--", "p"],
                     ["--allow", "Read", "--harness", "codex", "--", "p"],
                     ["--harness", "codex", "--allow", "", "--", "p"]] {
            #expect(throws: AgentRunCommand.Failure.usage) { try AgentRunCommand.parse(args) }
        }
        for unattended in [false, true] {
            let task = AgentTask(harness: .codex, prompt: "literal $(whoami)", unattended: unattended, timeoutSeconds: 90)
            #expect(task.argv(onBox: false) == ["codex", "exec", "literal $(whoami)"])
            #expect(task.argv(onBox: true) == ["timeout", "--signal=TERM", "--kill-after=30", "90", "codex", "exec",
                "--skip-git-repo-check", "--ephemeral", "--dangerously-bypass-approvals-and-sandbox", "literal $(whoami)"])
        }
    }

    @Test func credentialsPreserveLoginExceptRefreshAndUseJWTExpiry() throws {
        let raw = try codexCredentialJSON(lifetime: 600)
        let staged = try AgentCredentials.stage(raw: raw, harness: .codex, now: runNow, minimumLifetime: 600)
        var expected = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var tokens = try #require(expected["tokens"] as? [String: Any])
        tokens["refresh_token"] = ""; expected["tokens"] = tokens
        let actual = try #require(try JSONSerialization.jsonObject(with: staged.login) as? [String: Any])
        #expect(NSDictionary(dictionary: actual) == NSDictionary(dictionary: expected))
        #expect(Set(staged.secrets) == Set([try codexAccess(lifetime: 600), codexID]))
        #expect(throws: AgentCredentials.Failure.expiresSoon) {
            try AgentCredentials.stage(raw: codexCredentialJSON(lifetime: 599), harness: .codex, now: runNow, minimumLifetime: 600)
        }
        for raw in [Data("bad JSON".utf8), Data("{}".utf8),
                    Data(#"{"tokens":{"access_token":"bad.jwt.token"}}"#.utf8),
                    Data(#"{"tokens":{"access_token":"a.e30.c"}}"#.utf8)] {
            #expect(throws: AgentCredentials.Failure.unreadable) {
                try AgentCredentials.stage(raw: raw, harness: .codex, now: runNow, minimumLifetime: 600)
            }
        }
        let claude = try AgentCredentials.stage(raw: agentCredentialJSON(), harness: .claude, now: runNow, minimumLifetime: 600)
        #expect(claude.secrets == [agentAccess])
    }

    @Test func destinationDecodesOptionalSlots() throws {
        let encoder = JSONEncoder()
        let baseline = try #require(Rules.shipped.destinations["ai-eu-1"])
        var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(baseline)) as? [String: Any])
        json.removeValue(forKey: "agent_slots")
        #expect(try JSONDecoder().decode(DestinationConfig.self, from: JSONSerialization.data(withJSONObject: json)).agentSlots == nil)
        json["agent_slots"] = 3
        #expect(try JSONDecoder().decode(DestinationConfig.self, from: JSONSerialization.data(withJSONObject: json)).agentSlots == 3)
    }

    @Test func codexEngineStagesSafelyAndRedactsEchoedTokens() async throws {
        let f = try await AgentEngineFixture.make(harness: .codex); defer { f.git.home.remove() }
        let tokens = [try codexAccess(), codexID, codexRefresh]
        await f.box.echo(Data((tokens.prefix(2).joined(separator: " ") + "\n").utf8))
        let result = await f.engine.run(f.request(requireBox: true, harness: .codex))
        #expect(result.exitCode == 0 && result.state == .done)
        let staged = try #require(await f.box.staged.first)
        let login = try #require(try JSONSerialization.jsonObject(with: staged.2) as? [String: Any])
        let stagedTokens = try #require(login["tokens"] as? [String: Any])
        #expect(stagedTokens["refresh_token"] as? String == "")
        #expect(stagedTokens["access_token"] as? String == tokens[0])
        #expect(stagedTokens["id_token"] as? String == codexID)
        let job = try #require(await f.box.goJobs.first)
        #expect(job.image == "rx-codex")
        #expect(job.argv == f.request(harness: .codex).agentTask?.argv(onBox: true))
        #expect(job.prelude?.content.contains("mv /run/rmj/credentials.json \"$HOME/.codex/auth.json\"") == true)
        let row = try #require(try await f.git.home.ledger.job(result.jobID))
        let events = try await f.git.home.ledger.events(result.jobID)
        let surfaces = [job.argv.joined(separator: " "), job.options.joined(separator: " "), job.prelude?.content ?? "",
            job.prelude?.path ?? "", String(reflecting: row), String(reflecting: events), f.git.home.output.text,
            f.git.home.notices.text, try await f.git.home.log(result.jobID)]
        #expect(f.git.home.output.text.contains("[redacted]"))
        #expect(try await f.git.home.log(result.jobID).contains("[redacted]"))
        for token in tokens {
            for surface in surfaces { #expect(!surface.contains(token)) }
            let files = try #require(FileManager.default.enumerator(at: f.git.home.root, includingPropertiesForKeys: [.isRegularFileKey]))
            while let url = files.nextObject() as? URL {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    #expect(try Data(contentsOf: url).range(of: Data(token.utf8)) == nil)
                }
            }
        }
    }

    @Test func agentNetworkSlotsAndEgressOrder() async throws {
        for harness in [AgentHarness.claude, .codex] {
            for (slots, expected) in [(nil, 2), (3, 3), (0, 1), (17, 16)] as [(Int?, Int)] {
                let f = try await AgentEngineFixture.make(harness: harness, slots: slots); defer { f.git.home.remove() }
                let result = await f.engine.run(f.request(requireBox: true, harness: harness))
                #expect(result.exitCode == 0)
                let job = try #require(await f.box.goJobs.first)
                let home = try #require(Rules.shipped.destinations["ai-eu-1"]).home
                #expect(job.locks.first == "slots:\(expected):\(home)/rx/.agent-slot")
                for pair in [["--network", "rmj-agents"], ["-e", "HTTPS_PROXY=http://rmj-egress:3128"],
                             ["-e", "HTTP_PROXY=http://rmj-egress:3128"]] {
                    #expect(job.options.indices.contains { i in i + 1 < job.options.count && Array(job.options[i...i + 1]) == pair })
                }
                let egress = try #require(await f.box.egress.first)
                #expect(egress.0 == harness.image)
                #expect(egress.1 == (harness == .claude ? ["api.anthropic.com"] : ["api.openai.com", "chatgpt.com", "auth.openai.com"]))
                let calls = await f.box.calls
                #expect(try #require(calls.firstIndex(of: "ensureEgress")) < #require(calls.firstIndex(of: "stageSecret")))
            }
        }
    }

    @Test func egressFailureAndExpiringCodexNeverStageOrLaunch() async throws {
        for harness in [AgentHarness.claude, .codex] {
            for requireBox in [false, true] {
                for expires in [false, true] where !expires || harness == .codex {
                    let f = try await AgentEngineFixture.make(lifetime: expires ? 599 : 7200, harness: harness)
                    defer { f.git.home.remove() }
                    if !expires { await f.box.failEgress() }
                    let result = await f.engine.run(f.request(requireBox: requireBox, harness: harness))
                    let row = try #require(try await f.git.home.ledger.job(result.jobID))
                    #expect(result.exitCode == (requireBox ? 3 : 0))
                    #expect(row.state == (requireBox ? .failed : .done))
                    #expect(row.exitCode == (requireBox ? 3 : 0))
                    if expires { #expect(row.fallbackReason == "codex login expires soon") }
                    else { #expect(row.fallbackReason?.isEmpty == false) }
                    #expect(FileManager.default.fileExists(atPath: f.local.path) == !requireBox)
                    #expect(await f.box.staged.isEmpty)
                    #expect(await f.box.goJobs.isEmpty)
                }
            }
        }
    }
}

// The engine clock advances only after the real fixture's lock and sync boundaries.
private final class ReviewClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = runNow
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }; instant = instant.addingTimeInterval(seconds)
    }
}

private extension AgentEngineFixture {
    static func reviewFix(harness: AgentHarness, lifetime: TimeInterval = 7200,
                         profileNetwork: String? = nil, raw: Data? = nil,
                         now: @escaping @Sendable () -> Date = { runNow },
                         afterSync: @escaping @Sendable () -> Void = {}) async throws -> Self {
        let base = try await make(harness: harness)
        let home = base.git.home
        var rules = Rules.shipped
        rules.destinations["ai-eu-1"]?.peerID = "n-ai-acme-1"
        rules.rules = [try JSONDecoder().decode(Rule.self, from: Data("""
        {"name":"review fixes","match":{"command":["\(harness.program)"]},"to":["ai-eu-1"],
         "image":"\(harness.image)","cpus":2,"memory":"4g"}
        """.utf8))]
        if let profileNetwork {
            rules.rules[0].profile = "review"
            let directory = home.root.appendingPathComponent("profiles")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["image": harness.image, "network": profileNetwork,
                "env": ["KEEP": "ordered"], "volumes": ["keep-volume:/kept"]])
                .write(to: directory.appendingPathComponent("review.json"))
        }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tailnet/running.json").path
        let tailnet = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: runNow)
        let sample = await DestinationProbe(transport: ReviewProbeTransport()).probe(
            DestinationTarget(alias: "ai-eu-1", peerID: "n-ai-acme-1"), tailnet: tailnet, now: runNow)
        let probes = RunProbes(sample)
        let state = RulesState.valid(rules, fingerprint: "review-fixes")
        let credential = try raw ?? (harness == .codex ? codexCredentialJSON(lifetime: lifetime) : agentCredentialJSON(lifetime: lifetime))
        let engine = RunEngine(ledger: home.ledger, archive: home.archive,
            router: Router(rules: state, tailnet: tailnet, probes: probes, fileExists: { _ in true }, now: { runNow }),
            boxes: BoxDirectory(rules: state, tailnet: tailnet,
                factory: StreamFailureFactory(box: base.box, afterSync: afterSync, failImport: false)),
            probes: probes, output: home.output.add, notice: home.notices.notice,
            profiles: ProfileStore(home: RMJHome(environment: ["RMJ_HOME": home.root.path])), now: now,
            credentials: AgentCredentialsFake(raw: credential, trace: base.box))
        return Self(git: base.git, box: base.box, engine: engine, local: base.local)
    }
}

private struct ReviewProbeTransport: RemoteTransport {
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
