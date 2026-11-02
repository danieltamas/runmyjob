import Foundation
import Testing
@testable import RMJCore

struct TenantUnassignAcceptanceTests {
    private func home(_ json: String) throws -> RMJHome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-unassign-\(UUID().uuidString)")
        let home = RMJHome(environment: ["RMJ_HOME": root.path])
        try home.prepare()
        let store = RulesStore(home: home)
        try Data(json.utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        return home
    }

    private static let rules = """
    { "destinations": {}, "tenants": { "acme": { "repos": ["Acme/A", "acme/b"] },
      "globex": { "repos": ["globex/c"] } }, "rules": [] }
    """

    @Test func removesTheRepoCaseInsensitivelyAndPersistsValidRules() throws {
        let home = try home(Self.rules)
        defer { try? FileManager.default.removeItem(at: home.url) }
        try TenantEditing.apply(.unassign(repo: "aCME/a", tenant: "acme"), home: home)
        guard case .valid(let rules, _) = RulesStore(home: home).load() else { Issue.record("rules invalid"); return }
        #expect(rules.tenants["acme"]?.repos == ["acme/b"])
        #expect(rules.tenants["globex"]?.repos == ["globex/c"])
    }

    @Test func removingTheLastRepoLeavesNilRepos() throws {
        let home = try home(Self.rules)
        defer { try? FileManager.default.removeItem(at: home.url) }
        try TenantEditing.apply(.unassign(repo: "globex/c", tenant: "globex"), home: home)
        guard case .valid(let rules, _) = RulesStore(home: home).load() else { Issue.record("rules invalid"); return }
        #expect(rules.tenants["globex"] != nil)
        #expect(rules.tenants["globex"]?.repos == nil)
    }

    @Test func anUnknownTenantThrowsFailure() throws {
        let home = try home(Self.rules)
        defer { try? FileManager.default.removeItem(at: home.url) }
        #expect(throws: TenantEditing.Failure.self) {
            try TenantEditing.apply(.unassign(repo: "acme/a", tenant: "missing"), home: home)
        }
    }

    @Test func aRunnerTargetBlocksUnassignAndLeavesTheFileUntouched() throws {
        let home = try home("""
        { "destinations": { "b1": { "tenant": "acme", "ssh_alias": "b1", "enabled": true,
          "peer_id": "p1", "roles": ["runners"], "home": "/home/b", "max_jobs": 2,
          "memory_budget": "8g", "runner_targets": ["acme/a"] } },
          "tenants": { "acme": { "repos": ["acme/a", "acme/b"] } }, "rules": [] }
        """)
        defer { try? FileManager.default.removeItem(at: home.url) }
        guard case .valid = RulesStore(home: home).load() else { Issue.record("fixture invalid"); return }
        let before = try Data(contentsOf: RulesStore(home: home).url)
        #expect(throws: TenantEditing.Failure.self) {
            try TenantEditing.apply(.unassign(repo: "acme/a", tenant: "acme"), home: home)
        }
        #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
    }

    @Test func movingARepoRequiresUnassignBeforeAssign() throws {
        let home = try home(Self.rules)
        defer { try? FileManager.default.removeItem(at: home.url) }
        let before = try Data(contentsOf: RulesStore(home: home).url)
        do {
            try TenantEditing.apply(.assign(repo: "acme/a", tenant: "globex"), home: home)
            Issue.record("assigning a repo that already belongs to another tenant succeeded")
        } catch let failure as TenantEditing.Failure {
            #expect(failure.description.contains("already belongs"))
        }
        #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
        try TenantEditing.apply(.unassign(repo: "acme/a", tenant: "acme"), home: home)
        try TenantEditing.apply(.assign(repo: "acme/a", tenant: "globex"), home: home)
        guard case .valid(let rules, _) = RulesStore(home: home).load() else { Issue.record("rules invalid"); return }
        #expect(rules.tenants["acme"]?.repos == ["acme/b"])
        #expect(rules.tenants["globex"]?.repos == ["globex/c", "acme/a"])
    }
}
