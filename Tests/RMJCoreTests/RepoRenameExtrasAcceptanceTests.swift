import Foundation
import Testing
@testable import RMJCore

private actor ExtrasRenameAPI: GitHubAPI {
    private var target: String
    init(target: String) { self.target = target }
    func rename(to target: String) { self.target = target }

    func get(_ path: String, query: [String: String], etag: String?, token: String?) async throws -> GitHubResponse {
        guard path.lowercased() == "/repos/danieltamas/lexito.ro" else {
            return GitHubResponse(status: 404)
        }
        return GitHubResponse(status: 200, body: try JSONSerialization.data(withJSONObject: ["full_name": target, "id": 101]))
    }
}

struct RepoRenameExtrasAcceptanceTests {
    private static let old = "danieltamas/lexito.ro"
    private static let new = "danieltamas/kazu"

    private func home() throws -> RMJHome {
        var rules = Rules.shipped
        let box = try #require(rules.destinations["ai-eu-1"])
        rules.destinations = ["changed": box, "untouched": box]
        for name in rules.destinations.keys {
            rules.destinations[name]?.peerID = "peer-\(name)"
            rules.destinations[name]?.tenant = "acme"
            rules.destinations[name]?.runnerTargets = name == "changed" ? [Self.old] : ["org:danieltamas"]
            rules.destinations[name]?.runnerLabels = nil
        }
        rules.tenants = ["acme": TenantConfig(owners: ["danieltamas"], repos: [Self.old])]
        rules.rules = []
        let data = try JSONEncoder().encode(rules)
        _ = try RulesValidation.parse(data)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-rename-extras-\(UUID().uuidString)")
        let home = RMJHome(environment: ["RMJ_HOME": root.path])
        try home.prepare()
        try data.write(to: RulesStore(home: home).url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: RulesStore(home: home).url.path)
        return home
    }

    private func extras(_ home: RMJHome, destination: String, bytes: Data) throws -> URL {
        let directory = home.url.appendingPathComponent("runner-extras/\(destination)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("docker-compose.extra.yml")
        try bytes.write(to: file)
        return file
    }

    private func healer(_ home: RMJHome, target: String = Self.new) -> RepoRenameHealer {
        RepoRenameHealer(home: home, api: ExtrasRenameAPI(target: target), readToken: { _ in nil }, writeToken: { _, _ in })
    }

    private func healAfterRecording(_ home: RMJHome) async throws -> RepoRenameHealer.Result {
        let api = ExtrasRenameAPI(target: Self.old)
        let healer = RepoRenameHealer(home: home, api: api, readToken: { _ in nil }, writeToken: { _, _ in })
        let before = try Data(contentsOf: RulesStore(home: home).url)
        #expect(await healer.run() == RepoRenameHealer.Result())
        #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
        await api.rename(to: Self.new)
        return await healer.run()
    }

    @Test func changedDestinationRenamesOnlyExactRunnerServiceLine() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let before = "# runner-lexito-ro: keep comment\nservices:\n  runner-lexito-ro:\n    image: custom:latest  # keep spaces  \n    environment:\n      LABEL: runner-lexito-ro\n\n  pg-lexito:\n    image: postgres:16\n  runner-lexito-ro-extra:\n    image: helper:latest\n# final comment without newline"
        let expected = "# runner-lexito-ro: keep comment\nservices:\n  runner-kazu:\n    image: custom:latest  # keep spaces  \n    environment:\n      LABEL: runner-lexito-ro\n\n  pg-lexito:\n    image: postgres:16\n  runner-lexito-ro-extra:\n    image: helper:latest\n# final comment without newline"
        let file = try extras(home, destination: "changed", bytes: Data(before.utf8))

        let result = try await healAfterRecording(home)

        #expect(result.healed == [.init(old: Self.old, new: Self.new)])
        #expect(result.refused.isEmpty)
        #expect(result.destinations == ["changed"])
        let rules = try #require(RulesStore(home: home).load().rules)
        #expect(rules.destinations["changed"]?.runnerTargets == [Self.new])
        #expect(try Data(contentsOf: file) == Data(expected.utf8))
    }

    @Test func unchangedDestinationKeepsExtrasByteIdenticalDuringHeal() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let before = Data("# unrelated destination\nservices:\n  runner-lexito-ro:\n    image: custom:latest  \n\n".utf8)
        let file = try extras(home, destination: "untouched", bytes: before)

        let result = try await healAfterRecording(home)

        #expect(result.healed == [.init(old: Self.old, new: Self.new)])
        #expect(result.refused.isEmpty)
        #expect(result.destinations == ["changed"])
        let rules = try #require(RulesStore(home: home).load().rules)
        #expect(rules.destinations["changed"]?.runnerTargets == [Self.new])
        #expect(rules.destinations["untouched"]?.runnerTargets == ["org:danieltamas"])
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func ownerTransferRefusalKeepsExtrasByteIdentical() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let before = Data("# transfer must not rewrite this\nservices:\n  runner-lexito-ro:\n    image: custom:latest  \n".utf8)
        let file = try extras(home, destination: "changed", bytes: before)

        let result = await healer(home, target: "someoneelse/kazu").run()

        #expect(result.healed.isEmpty)
        #expect(result.destinations.isEmpty)
        #expect(result.refused.count == 1)
        let refusal = try #require(result.refused.first)
        #expect(refusal.old == Self.old)
        #expect(refusal.new == "someoneelse/kazu")
        #expect(refusal.reason.contains("someoneelse"))
        let rules = try #require(RulesStore(home: home).load().rules)
        #expect(rules.destinations["changed"]?.runnerTargets == [Self.old])
        #expect(try Data(contentsOf: file) == before)
    }
}
