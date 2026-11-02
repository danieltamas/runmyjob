import Foundation
import Testing
@testable import RMJCore

private actor GuardsRenameAPI: GitHubAPI {
    private var target: String
    private var id: Int
    init(target: String, id: Int = 101) { self.target = target; self.id = id }
    func rename(to target: String, id: Int = 101) { self.target = target; self.id = id }
    func get(_ path: String, query: [String: String], etag: String?, token: String?) async throws -> GitHubResponse {
        guard path.lowercased() == "/repos/owner/old" else { return GitHubResponse(status: 404) }
        return GitHubResponse(status: 200, body: try JSONSerialization.data(withJSONObject: ["full_name": target, "id": id]))
    }
}

private final class GuardsRenameTokens: @unchecked Sendable {
    enum Failure: Error { case writeDenied }
    private let lock = NSLock()
    private var writes: [[String]] = []
    private let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func read(_ target: String) -> String? { target == "owner/old" ? "old-pat" : nil }
    func write(_ target: String, _ token: String) throws {
        lock.withLock { writes.append([target, token]) }
        if fails { throw Failure.writeDenied }
    }
    func recorded() -> [[String]] { lock.withLock { writes } }
}

struct RepoRenameGuardsAcceptanceTests {
    private static let old = "owner/old"
    private static let new = "owner/new"

    private func fixture() throws -> Rules {
        var rules = Rules.shipped
        let box = try #require(rules.destinations["ai-eu-1"])
        rules.destinations = ["z-box": box, "a-box": box, "untouched": box]
        for name in rules.destinations.keys {
            rules.destinations[name]?.peerID = "peer-\(name)"
            rules.destinations[name]?.tenant = "acme"
            rules.destinations[name]?.runnerTargets = name == "untouched" ? ["org:owner"] : [Self.old]
            rules.destinations[name]?.runnerLabels = nil
        }
        rules.tenants = ["acme": TenantConfig(owners: ["owner"], repos: [Self.old])]
        rules.rules = []
        return rules
    }

    private func home(_ rules: Rules) throws -> RMJHome {
        let data = try JSONEncoder().encode(rules)
        _ = try RulesValidation.parse(data)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-rename-guards-\(UUID().uuidString)")
        let home = RMJHome(environment: ["RMJ_HOME": root.path])
        try home.prepare()
        try data.write(to: RulesStore(home: home).url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: RulesStore(home: home).url.path)
        return home
    }

    private func extras(_ home: RMJHome, bytes: Data) throws -> URL {
        let directory = home.url.appendingPathComponent("runner-extras/a-box")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("docker-compose.extra.yml")
        try bytes.write(to: file)
        return file
    }

    private func pending(_ home: RMJHome) -> URL { home.url.appendingPathComponent("pending_repairs.json") }
    private func healer(_ home: RMJHome, target: String = Self.new, tokens: GuardsRenameTokens = GuardsRenameTokens()) -> RepoRenameHealer {
        RepoRenameHealer(home: home, api: GuardsRenameAPI(target: target), readToken: { tokens.read($0) }, writeToken: { try tokens.write($0, $1) })
    }

    private func afterRecording(_ home: RMJHome, target: String = Self.new, id: Int = 101, tokens: GuardsRenameTokens = GuardsRenameTokens()) async throws -> RepoRenameHealer.Result {
        let api = GuardsRenameAPI(target: Self.old)
        let healer = RepoRenameHealer(home: home, api: api, readToken: { tokens.read($0) }, writeToken: { try tokens.write($0, $1) })
        let before = try Data(contentsOf: RulesStore(home: home).url)
        #expect(await healer.run() == RepoRenameHealer.Result())
        #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
        await api.rename(to: target, id: id)
        return await healer.run()
    }

    @Test func anotherTenantHoldingNewNameRefusesWithoutWrites() async throws {
        var rules = try fixture()
        rules.tenants["globex"] = TenantConfig(repos: [Self.new])
        let home = try home(rules)
        defer { try? FileManager.default.removeItem(at: home.url) }
        let before = try Data(contentsOf: RulesStore(home: home).url)
        let tokens = GuardsRenameTokens()
        let result = try await afterRecording(home, tokens: tokens)
        #expect(result.healed.isEmpty)
        #expect(result.destinations.isEmpty)
        #expect(result.refused.count == 1)
        let refusal = try #require(result.refused.first)
        #expect(refusal.old == Self.old)
        #expect(refusal.new == Self.new)
        #expect(refusal.reason.contains("globex"))
        #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
        #expect(tokens.recorded().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pending(home).path))
    }

    @Test func extrasRenameTouchesOnlyServicesSection() async throws {
        let home = try home(fixture())
        defer { try? FileManager.default.removeItem(at: home.url) }
        let before = "# runner-old: keep\nservices:\n  runner-old:\n    image: custom:latest  \n    volumes:\n      - runner-old:/work\n\nvolumes:\n  runner-old:\n    external: true\n# final comment without newline"
        let expected = "# runner-old: keep\nservices:\n  runner-new:\n    image: custom:latest  \n    volumes:\n      - runner-old:/work\n\nvolumes:\n  runner-old:\n    external: true\n# final comment without newline"
        let file = try extras(home, bytes: Data(before.utf8))
        let result = try await afterRecording(home)
        #expect(result.healed == [.init(old: Self.old, new: Self.new)])
        #expect(result.refused.isEmpty)
        #expect(result.destinations == ["a-box", "z-box"])
        let rules = try #require(RulesStore(home: home).load().rules)
        #expect(rules.destinations["a-box"]?.runnerTargets == [Self.new])
        #expect(try Data(contentsOf: file) == Data(expected.utf8))
    }

    @Test func pendingRepairsContainExactlyChangedDestinationsAndTransferCreatesNone() async throws {
        let successHome = try home(fixture())
        defer { try? FileManager.default.removeItem(at: successHome.url) }
        let success = try await afterRecording(successHome)
        #expect(success.healed == [.init(old: Self.old, new: Self.new)])
        #expect(success.refused.isEmpty)
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: pending(successHome)))
        #expect(names == ["a-box", "z-box"])
        let refusedHome = try home(fixture())
        defer { try? FileManager.default.removeItem(at: refusedHome.url) }
        let refused = await healer(refusedHome, target: "someoneelse/new").run()
        #expect(refused.healed.isEmpty)
        #expect(refused.destinations.isEmpty)
        #expect(refused.refused.count == 1)
        #expect(refused.refused.first?.new == "someoneelse/new")
        #expect(refused.refused.first?.reason.contains("someoneelse") == true)
        #expect(!FileManager.default.fileExists(atPath: pending(refusedHome).path))
    }

    @Test func throwingTokenWriteRefusesAndPreservesRulesAndExtras() async throws {
        let home = try home(fixture())
        defer { try? FileManager.default.removeItem(at: home.url) }
        let beforeRules = try Data(contentsOf: RulesStore(home: home).url)
        let beforeExtras = Data("services:\n  runner-old:\n    image: custom:latest  \n".utf8)
        let file = try extras(home, bytes: beforeExtras)
        let tokens = GuardsRenameTokens(fails: true)
        let result = try await afterRecording(home, tokens: tokens)
        #expect(tokens.recorded() == [[Self.new, "old-pat"]])
        #expect(result.healed.isEmpty)
        #expect(result.destinations.isEmpty)
        #expect(result.refused.count == 1)
        let refusal = try #require(result.refused.first)
        #expect(refusal.old == Self.old)
        #expect(refusal.new == Self.new)
        #expect(try Data(contentsOf: RulesStore(home: home).url) == beforeRules)
        #expect(try Data(contentsOf: file) == beforeExtras)
        #expect(!FileManager.default.fileExists(atPath: pending(home).path))
    }

    private func expectUntouchedRefusal(_ home: RMJHome, target: String = Self.new, recorded: Bool, id: Int = 101, reason: String) async throws {
        let beforeRules = try Data(contentsOf: RulesStore(home: home).url)
        let beforeExtras = Data("services:\n  runner-old:\n    image: custom:latest  \n".utf8)
        let file = try extras(home, bytes: beforeExtras)
        let tokens = GuardsRenameTokens()
        let result: RepoRenameHealer.Result
        if recorded {
            result = try await afterRecording(home, target: target, id: id, tokens: tokens)
        } else {
            result = await healer(home, target: target, tokens: tokens).run()
        }
        #expect(result.healed.isEmpty)
        #expect(result.destinations.isEmpty)
        #expect(result.refused.count == 1)
        let refusal = try #require(result.refused.first)
        #expect(refusal.old == Self.old)
        #expect(refusal.new == target)
        #expect(refusal.reason.contains(reason))
        #expect(try Data(contentsOf: RulesStore(home: home).url) == beforeRules)
        #expect(try Data(contentsOf: file) == beforeExtras)
        #expect(tokens.recorded().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pending(home).path))
    }

    @Test func renameWithoutRecordedIDRefusesWithoutWrites() async throws {
        let home = try home(fixture())
        defer { try? FileManager.default.removeItem(at: home.url) }
        try await expectUntouchedRefusal(home, recorded: false, reason: "recorded")
    }

    @Test func renameWithDifferentRecordedIDRefusesWithoutWrites() async throws {
        let home = try home(fixture())
        defer { try? FileManager.default.removeItem(at: home.url) }
        try await expectUntouchedRefusal(home, recorded: true, id: 202, reason: "different repository")
    }

    @Test func anotherTenantHoldingPrefixPatternRefusesWithoutWrites() async throws {
        var rules = try fixture()
        rules.tenants["globex"] = TenantConfig(repos: ["owner/new*"])
        let home = try home(rules)
        defer { try? FileManager.default.removeItem(at: home.url) }
        try await expectUntouchedRefusal(home, target: "owner/new-app", recorded: true, reason: "globex")
    }
}
