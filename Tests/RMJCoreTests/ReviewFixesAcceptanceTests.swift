import Foundation
import Testing
@testable import RMJCore

private actor ReviewFixProbe: ProbeProvider {
    private(set) var calls = 0
    func latest(for destination: String) async -> DestinationProbeResult? { nil }
    func probe(_ target: DestinationTarget, tailnet: TailnetState) async -> DestinationProbeResult {
        calls += 1
        return .without(.unreachable("unexpected probe"), at: Date())
    }
}

struct ReviewFixesAcceptanceTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-review-fixes-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: [
        "pnpm -r test", "npm --prefix web test", "npm --prefix=web run lint",
        "pnpm --filter app run typecheck", "yarn --cwd web test", "bun --silent test"
    ])
    func packageManagerOptionsStillRecognizeChecks(command: String) {
        #expect(CommandGuard.kind(of: command) == .check)
    }

    @Test(arguments: [
        "npm -g install test", "npm install test", "pnpm add test", "npm --prefix web run build"
    ])
    func packageNamesAndBuildScriptsAreNotChecks(command: String) {
        #expect(CommandGuard.kind(of: command) == nil)
    }

    @Test(arguments: [false, true])
    func hashedHostKeyIsPreservedAndChangedKeyIsRejected(changed: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("known_hosts")
        let alias = "review-box"
        // Use real key blobs so ssh-keygen validates and hashes the entry itself.
        let runner = ProcessRunner()
        var keys = [HostKey]()
        for name in ["key-a", "key-b"] {
            let path = root.appendingPathComponent(name)
            let generated = try await runner.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path.path], timeout: .seconds(10))
            try #require(generated.status == 0)
            let fields = try String(contentsOf: path.appendingPathExtension("pub"), encoding: .utf8).split(separator: " ")
            try #require(fields.count >= 2)
            keys.append(HostKey(type: String(fields[0]), base64: String(fields[1])))
        }
        try Data("\(alias) \(keys[0].type) \(keys[0].base64)\n".utf8).write(to: file)
        let hashed = try await runner.run("/usr/bin/ssh-keygen", ["-H", "-f", file.path], timeout: .seconds(10))
        try #require(hashed.status == 0)
        let before = try Data(contentsOf: file)
        let text = String(decoding: before, as: UTF8.self)
        try #require(text.hasPrefix("|1|"))
        try #require(!text.contains(alias))
        try #require(keys[0].type == keys[1].type && keys[0] != keys[1])
        let trust = HostKeyTrust(knownHosts: file)
        if changed {
            #expect(throws: HostKeyTrust.Failure.changed) { try trust.trust(keys[1], alias: alias) }
        } else {
            try trust.trust(keys[0], alias: alias)
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test(arguments: ["acme", "ACME", "AcMe"])
    func newTenantCannotClaimExistingOwner(owner: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = RMJHome(environment: ["RMJ_HOME": root.path])
        try home.prepare()
        let store = RulesStore(home: home)
        let rules = Rules(tenants: ["existing": TenantConfig(owners: [owner], repos: nil, shared: nil)])
        try JSONEncoder().encode(rules).write(to: store.url)
        try #require(store.load().rules != nil)
        let before = try Data(contentsOf: store.url)
        var draft = DestinationDraft(name: "new-box", peerID: "n-ai-acme-1", sshAlias: "ai-eu-1",
                                     tenant: "new-company", roles: ["runners"], home: "/home/fixture",
                                     maxJobs: 2, memoryBudget: "24g")
        draft.runnerTargets = ["org:Acme"]
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tailnet/running.json")
        let tailnet = TailnetState.parse(try Data(contentsOf: fixture), readAt: Date())
        let probes = ReviewFixProbe()
        let report = await DestinationOnboarding(probes: probes, store: store).run(draft, tailnet: tailnet)
        #expect(report.steps.contains { $0.name == "tenant" && !$0.ok })
        #expect(report.failedStep?.name == "tenant")
        #expect(!report.written)
        #expect(try Data(contentsOf: store.url) == before)
        #expect(await probes.calls == 0)
    }

    @Test(arguments: ["org:acme", "org:Acme", "acme/app", "AcMe/app"])
    func ambiguousRunnerOwnerIsDeniedOnEveryDestination(target: String) {
        var rules = Rules(tenants: [
            "first": TenantConfig(owners: ["acme"], repos: nil, shared: nil),
            "second": TenantConfig(owners: ["ACME"], repos: nil, shared: nil),
            "unrelated": TenantConfig(owners: ["other"], repos: nil, shared: nil),
            "shared": TenantConfig(owners: nil, repos: nil, shared: true)
        ])
        for tenant in ["first", "second", "unrelated", "shared"] {
            let destination = DestinationConfig(enabled: true, peerID: "fixture-\(tenant)", sshAlias: "box-\(tenant)",
                                                tenant: tenant, roles: ["runners"], home: "/home/fixture", maxJobs: 2,
                                                memoryBudget: "32g", runnerTargets: [target])
            rules.destinations[tenant] = destination
        }
        for (name, destination) in rules.destinations {
            #expect(RunnerScalingLoop.tenantDenied(target: target, destination: destination, rules: rules),
                    "Ambiguous owner must be denied even on \(name)")
        }
    }
}
