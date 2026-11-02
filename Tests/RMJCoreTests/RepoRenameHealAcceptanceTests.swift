import Foundation
import Testing
@testable import RMJCore

// Mirrors the poller tests' in-memory API; every request retains its authentication contract.
private actor RenameAPI: GitHubAPI {
    struct Call: Sendable {
        let path: String
        let query: [String: String]
        let etag: String?
        let token: String?
    }
    enum Failure: Error { case offline }
    private var responses: [String: GitHubResponse]
    private let failures: Set<String>
    private var calls: [Call] = []

    init(_ names: [String: String] = [:], statuses: [String: Int] = [:], failures: Set<String> = [], missingIDs: Set<String> = []) {
        var responses: [String: GitHubResponse] = [:]
        for (old, new) in names {
            var body: [String: Any] = ["full_name": new]
            if !missingIDs.contains(old) { body["id"] = old.lowercased() == "danieltamas/rule-only" ? 102 : 101 }
            responses[old.lowercased()] = GitHubResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
        }
        for (repo, status) in statuses { responses[repo.lowercased()] = GitHubResponse(status: status) }
        self.responses = responses
        self.failures = failures
    }

    func recorded() -> [Call] { calls }
    func rename(_ old: String, to new: String) throws {
        responses[old.lowercased()] = GitHubResponse(status: 200, body: try JSONSerialization.data(withJSONObject: ["full_name": new, "id": 101]))
        calls = []
    }
    func get(_ path: String, query: [String: String], etag: String?, token: String?) async throws -> GitHubResponse {
        calls.append(Call(path: path, query: query, etag: etag, token: token))
        let repo = String(path.dropFirst("/repos/".count)).lowercased()
        if failures.contains(repo) { throw Failure.offline }
        return responses[repo] ?? GitHubResponse(status: 404)
    }
}

private final class RenameTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var writes: [[String]] = []
    init(_ values: [String: String] = [:]) { self.values = values }
    func read(_ target: String) -> String? { lock.withLock { values[target] } }
    func write(_ target: String, _ token: String) {
        lock.withLock { values[target] = token; writes.append([target, token]) }
    }
    func recorded() -> [[String]] { lock.withLock { writes } }
}

struct RepoRenameHealAcceptanceTests {
    private static let old = "danieltamas/lexito.ro"
    private static let new = "danieltamas/kazu"

    private func home(_ json: String) throws -> RMJHome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-rename-\(UUID().uuidString)")
        let home = RMJHome(environment: ["RMJ_HOME": root.path])
        try home.prepare()
        try Data(json.utf8).write(to: RulesStore(home: home).url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: RulesStore(home: home).url.path)
        return home
    }

    private func fixture() throws -> Rules {
        var rules = Rules.shipped
        let box = try #require(rules.destinations["ai-eu-1"])
        rules.destinations = ["z-box": box, "a-box": box, "untouched": box]
        for name in rules.destinations.keys {
            rules.destinations[name]?.peerID = "peer-\(name)"
            rules.destinations[name]?.tenant = "acme"
            rules.destinations[name]?.runnerTargets = name == "untouched" ? ["org:danieltamas"] : [Self.old, Self.new, "org:danieltamas"]
            rules.destinations[name]?.runnerLabels = name == "untouched" ? nil : [Self.old: ["lexito"]]
        }
        rules.tenants = ["acme": TenantConfig(owners: ["danieltamas"], repos: [Self.old, Self.new, "danieltamas/prefix*"])]
        rules.rules = try JSONDecoder().decode([Rule].self, from: Data("""
        [{"name":"rename","match":{"repo":["DANIELTAMAS/LEXITO.RO","danieltamas/kazu","danieltamas/rule-only"]},"to":["a-box"]}]
        """.utf8))
        return rules
    }

    private func home(_ rules: Rules) throws -> RMJHome {
        _ = try RulesValidation.parse(JSONEncoder().encode(rules))
        return try home(String(decoding: JSONEncoder().encode(rules), as: UTF8.self))
    }

    private func healer(_ home: RMJHome, _ api: RenameAPI, _ tokens: RenameTokens) -> RepoRenameHealer {
        RepoRenameHealer(home: home, api: api, readToken: { tokens.read($0) }, writeToken: { tokens.write($0, $1) })
    }

    private func expectEmpty(_ result: RepoRenameHealer.Result) {
        #expect(result.healed.isEmpty)
        #expect(result.refused.isEmpty)
        #expect(result.destinations.isEmpty)
    }

    private func recordIdentity(_ home: RMJHome, _ api: RenameAPI, _ tokens: RenameTokens) async throws {
        let before = try Data(contentsOf: RulesStore(home: home).url)
        expectEmpty(await healer(home, api, tokens).run())
        #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
        let ids = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: home.url.appendingPathComponent("repo_ids.json")))
        #expect(ids[Self.old] == 101)
        #expect(ids.keys.allSatisfy { $0 == $0.lowercased() })
    }

    @Test func sameOwnerRenameRewritesEveryPlaceAndReportsSortedDestinations() async throws {
        let home = try home(fixture())
        defer { try? FileManager.default.removeItem(at: home.url) }
        let api = RenameAPI([Self.old: Self.old, Self.new: Self.new, "danieltamas/rule-only": "danieltamas/rule-only"])
        try await recordIdentity(home, api, RenameTokens())
        let ids = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: home.url.appendingPathComponent("repo_ids.json")))
        #expect(ids == [Self.old: 101, Self.new: 101, "danieltamas/rule-only": 102])
        try await api.rename(Self.old, to: Self.new)
        let result = await healer(home, api, RenameTokens()).run()
        #expect(result.healed.count == 1)
        #expect(result.healed.first?.old.lowercased() == Self.old)
        #expect(result.healed.first?.new == Self.new)
        #expect(result.refused.isEmpty)
        #expect(result.destinations == ["a-box", "z-box"])
        let rules = try #require(RulesStore(home: home).load().rules)
        #expect(rules.tenants["acme"]?.repos == [Self.new, "danieltamas/prefix*"])
        for name in ["a-box", "z-box"] {
            #expect(rules.destinations[name]?.runnerTargets == [Self.new, "org:danieltamas"])
            #expect(rules.destinations[name]?.runnerLabels == [Self.new: ["lexito"]])
        }
        #expect(rules.destinations["untouched"]?.runnerTargets == ["org:danieltamas"])
        #expect(rules.rules.first?.match.repo == [Self.new, "danieltamas/rule-only"])
        let calls = await api.recorded()
        #expect(calls.count == 3)
        #expect(Set(calls.map { $0.path.lowercased() }) == Set([Self.old, Self.new, "danieltamas/rule-only"].map { "/repos/\($0)" }))
        #expect(calls.allSatisfy { $0.query.isEmpty && $0.etag == nil && $0.token == nil })
        let log = try String(contentsOf: home.url.appendingPathComponent("logs/renames.log"), encoding: .utf8)
        #expect(log.lowercased() == "\(Self.old) -> \(Self.new)\n")
    }

    @Test func tokenIsCopiedOnceOnlyWhenNewTargetHasNoToken() async throws {
        for existing in [false, true] {
            let home = try home(fixture())
            defer { try? FileManager.default.removeItem(at: home.url) }
            let tokens = RenameTokens(existing ? [Self.old: "old-pat", Self.new: "new-pat"] : [Self.old: "old-pat"])
            let api = RenameAPI([Self.old: Self.old])
            try await recordIdentity(home, api, tokens)
            try await api.rename(Self.old, to: Self.new)
            let result = await healer(home, api, tokens).run()
            #expect(result.healed.count == 1)
            #expect(tokens.recorded() == (existing ? [] : [[Self.new, "old-pat"]]))
            #expect(tokens.read(Self.old) == "old-pat")
            #expect(tokens.read(Self.new) == (existing ? "new-pat" : "old-pat"))
        }
    }

    @Test func transferAndInvalidHealedOwnershipAreRefusedWithoutWriting() async throws {
        // The same-owner case collides with another company's repo prefix claim.
        for target in ["someoneelse/lexito.ro", "danieltamas/globex-app"] {
            var rules = try fixture()
            rules.tenants["globex"] = TenantConfig(repos: ["danieltamas/globex*"])
            let home = try home(rules)
            defer { try? FileManager.default.removeItem(at: home.url) }
            let before = try Data(contentsOf: RulesStore(home: home).url)
            let tokens = RenameTokens([Self.old: "old-pat"])
            let api = RenameAPI([Self.old: Self.old])
            if !target.hasPrefix("someoneelse/") { try await recordIdentity(home, api, tokens) }
            try await api.rename(Self.old, to: target)
            let result = await healer(home, api, tokens).run()
            #expect(result.healed.isEmpty)
            #expect(result.destinations.isEmpty)
            #expect(result.refused.count == 1)
            let refusal = try #require(result.refused.first)
            #expect(refusal.old.lowercased() == Self.old)
            #expect(refusal.new == target)
            #expect(!refusal.reason.isEmpty)
            if target.hasPrefix("someoneelse/") { #expect(refusal.reason.contains("someoneelse")) }
            #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
            #expect(tokens.recorded().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: home.url.appendingPathComponent("logs/renames.log").path))
        }
    }

    @Test func non200ThrownErrorAndCaseOnlyDifferenceChangeNothing() async throws {
        let repos = ["danieltamas/missing", "danieltamas/forbidden", "danieltamas/server", "danieltamas/offline", Self.old, "danieltamas/no-id"]
        var rules = try fixture()
        rules.tenants["acme"]?.repos = repos
        let home = try home(rules)
        defer { try? FileManager.default.removeItem(at: home.url) }
        let before = try Data(contentsOf: RulesStore(home: home).url)
        let tokens = RenameTokens([Self.old: "old-pat"])
        let api = RenameAPI([Self.old: Self.old.uppercased(), repos[5]: "danieltamas/renamed"], statuses: [repos[0]: 404, repos[1]: 403, repos[2]: 503], failures: [repos[3]], missingIDs: [repos[5]])
        expectEmpty(await healer(home, api, tokens).run())
        let ids = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: home.url.appendingPathComponent("repo_ids.json")))
        #expect(ids == [Self.old: 101])
        #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
        #expect(tokens.recorded().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.url.appendingPathComponent("logs/renames.log").path))
        let calls = await api.recorded()
        #expect(Set(calls.map { $0.path.lowercased() }).isSuperset(of: repos.map { "/repos/\($0)" }))
    }

    @Test func secondRunIsANoop() async throws {
        let home = try home(fixture())
        defer { try? FileManager.default.removeItem(at: home.url) }
        let tokens = RenameTokens([Self.old: "old-pat"])
        let api = RenameAPI([Self.old: Self.old, Self.new: Self.new])
        try await recordIdentity(home, api, tokens)
        try await api.rename(Self.old, to: Self.new)
        let healer = healer(home, api, tokens)
        #expect(await healer.run().healed.count == 1)
        let ids = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: home.url.appendingPathComponent("repo_ids.json")))
        #expect(ids[Self.old] == nil)
        #expect(ids[Self.new] == 101)
        let before = try Data(contentsOf: RulesStore(home: home).url)
        let logURL = home.url.appendingPathComponent("logs/renames.log")
        let log = try Data(contentsOf: logURL)
        let count = await api.recorded().count
        expectEmpty(await healer.run())
        #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
        #expect(try Data(contentsOf: logURL) == log)
        #expect(tokens.recorded() == [[Self.new, "old-pat"]])
        let secondCalls = await api.recorded().dropFirst(count)
        #expect(!secondCalls.contains { $0.path.lowercased() == "/repos/\(Self.old)" })
    }

    @Test func invalidRulesFileIsANoop() async throws {
        for json in ["{broken", #"{"destinations":{},"tenants":{},"rules":[],"unknown":true}"#] {
            let home = try home(json)
            defer { try? FileManager.default.removeItem(at: home.url) }
            let before = try Data(contentsOf: RulesStore(home: home).url)
            let api = RenameAPI([Self.old: Self.new])
            let tokens = RenameTokens([Self.old: "old-pat"])
            expectEmpty(await healer(home, api, tokens).run())
            #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
            #expect(await api.recorded().isEmpty)
            #expect(tokens.recorded().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: home.url.appendingPathComponent("logs/renames.log").path))
        }
    }
}
