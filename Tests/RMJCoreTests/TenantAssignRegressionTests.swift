import Foundation
import Testing
@testable import RMJCore

/// Found in the U17 review: tagging a job must never move a repo across the company boundary.
struct TenantAssignRegressionTests {
    private func home(_ json: String) throws -> RMJHome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-assign-\(UUID().uuidString)")
        let home = RMJHome(environment: ["RMJ_HOME": root.path])
        try home.prepare()
        let store = RulesStore(home: home)
        try Data(json.utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        return home
    }

    private static let rules = """
    { "destinations": {}, "tenants": { "acme": { "repos": ["acme/a"] }, "globex": { "owners": ["globex"] },
      "personal": { "shared": true } }, "rules": [] }
    """

    @Test func patternsAreNotRepositoryNames() throws {
        let home = try home(Self.rules)
        defer { try? FileManager.default.removeItem(at: home.url) }
        let before = try Data(contentsOf: RulesStore(home: home).url)
        for repo in ["globex/*", "*/*", "globex/p[a-z]", "globex/portal?", "acme/a b"] {
            #expect(throws: TenantEditing.Failure.self) { try TenantEditing.apply(.assign(repo: repo, tenant: "acme"), home: home) }
        }
        #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
    }

    @Test func aRepoOfAnotherCompanysOwnerIsNotGivenAway() throws {
        let home = try home(Self.rules)
        defer { try? FileManager.default.removeItem(at: home.url) }
        let before = try Data(contentsOf: RulesStore(home: home).url)
        #expect(throws: TenantEditing.Failure.self) { try TenantEditing.apply(.assign(repo: "globex/portal", tenant: "acme"), home: home) }
        #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
        // A shared tenant is not a company: its repos may live anywhere.
        try TenantEditing.apply(.assign(repo: "globex/dotfiles", tenant: "personal"), home: home)
        guard case .valid(let rules, _) = RulesStore(home: home).load() else { Issue.record("rules invalid"); return }
        #expect(rules.tenants["personal"]?.repos == ["globex/dotfiles"])
    }
}

/// Found live: a Swift build showed "Run remote" although no rule sends Swift to a box.
struct TenantAssignableCommandTests {
    private static let rules: Rules = {
        let json = """
        { "destinations": { "b1": { "tenant": "acme", "ssh_alias": "b1", "enabled": true, "peer_id": "", "roles": ["rx"], "home": "/home/b", "max_jobs": 2, "memory_budget": "8g" } },
          "tenants": { "acme": { "owners": ["acme"] } },
          "rules": [ { "name": "node", "match": { "command": ["npm", "cargo build"] }, "to": ["b1"] },
                     { "name": "acme", "match": { "tenant": ["acme"] }, "to": ["b1"] } ] }
        """
        return try! JSONDecoder().decode(Rules.self, from: Data(json.utf8))
    }()

    @Test func onlyACommandSomeRuleRoutesIsOffered() {
        #expect(TenantEditing.assignable(Self.rules, command: "npm test") == ["acme"])
        #expect(TenantEditing.assignable(Self.rules, command: "cargo build --release") == ["acme"])
        #expect(TenantEditing.assignable(Self.rules, command: "swift test --filter Guard").isEmpty)
        // A tenant-wide rule routes any command, but never a program that exists only on macOS.
        #expect(TenantEditing.assignable(Self.rules, command: "/usr/bin/xcodebuild -scheme A").isEmpty)
        #expect(TenantEditing.assignable(Self.rules, command: "make").first == "acme")
        // The script that wraps a Mac repo's builds is a Mac job too.
        #expect(TenantEditing.assignable(Self.rules, command: "scripts/check.sh", repoCommands: ["swift test"]).isEmpty)
    }
}

/// Found live: a tenant could not be removed.
struct TenantRemovalTests {
    private func home(_ json: String) throws -> RMJHome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-remove-\(UUID().uuidString)")
        let home = RMJHome(environment: ["RMJ_HOME": root.path])
        try home.prepare()
        let store = RulesStore(home: home)
        try Data(json.utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        return home
    }

    private static let box = #""b1": { "tenant": "acme", "ssh_alias": "b1", "enabled": true, "peer_id": "p1", "roles": ["rx"], "home": "/home/b", "max_jobs": 2, "memory_budget": "8g", "rx_defaults": { "cpus": 2, "memory": "4g" } }"#

    @Test func aTenantWithoutBoxesOrRulesIsRemoved() throws {
        let home = try home(#"{ "destinations": { \#(Self.box) }, "tenants": { "acme": { "owners": ["acme"] }, "old": { "repos": ["x/y"] } }, "rules": [] }"#)
        defer { try? FileManager.default.removeItem(at: home.url) }
        try TenantEditing.apply(.remove("old"), home: home)
        guard case .valid(let rules, _) = RulesStore(home: home).load() else { Issue.record("rules invalid"); return }
        #expect(rules.tenants.keys.sorted() == ["acme"])
    }

    @Test func aTenantWithABoxOrARuleIsRefusedAndTheFileIsUntouched() throws {
        let home = try home(#"{ "destinations": { \#(Self.box) }, "tenants": { "acme": { "owners": ["acme"] }, "old": { "repos": ["x/y"] } }, "rules": [ { "name": "r", "match": { "tenant": ["old"] }, "to": ["b1"] } ] }"#)
        defer { try? FileManager.default.removeItem(at: home.url) }
        let before = try Data(contentsOf: RulesStore(home: home).url)
        #expect(throws: TenantEditing.Failure.self) { try TenantEditing.apply(.remove("acme"), home: home) }
        #expect(throws: TenantEditing.Failure.self) { try TenantEditing.apply(.remove("old"), home: home) }
        #expect(throws: TenantEditing.Failure.self) { try TenantEditing.apply(.remove("nope"), home: home) }
        #expect(try Data(contentsOf: RulesStore(home: home).url) == before)
    }
}
