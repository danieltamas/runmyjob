import Foundation
import Testing
@testable import RMJCore

private struct TenantStyleFixture {
    let home: RMJHome
    var store: RulesStore { RulesStore(home: home) }

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-tenant-style-\(UUID().uuidString)")
        home = RMJHome(environment: ["RMJ_HOME": root.path])
        try home.prepare()
        try writeLedgerProfile(home: home)
        try write(Self.object())
    }

    func remove() { try? FileManager.default.removeItem(at: home.url) }

    // The existing temp-home helpers are file-private; use their same RMJ_HOME setup.
    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
    }

    func loaded() throws -> Rules {
        guard case .valid(let rules, _) = store.load() else {
            Issue.record("Expected valid tenant rules: \(store.load())")
            throw CocoaError(.fileReadCorruptFile)
        }
        return rules
    }

    static func object(style: [String: Any]? = nil, order: [String]? = nil,
                       chain: [String] = ["box3", "box1", "box2"]) throws -> [String: Any] {
        var base = try #require(JSONSerialization.jsonObject(with: Data(Rules.shippedJSON.utf8)) as? [String: Any])
        let shipped = try #require(base["destinations"] as? [String: [String: Any]])
        var destinations = [String: [String: Any]]()
        for name in ["box1", "box2", "box3", "other1"] {
            var box = try #require(shipped["ai-eu-1"])
            box["peer_id"] = "tenant-\(name)"
            box["ssh_alias"] = "ai-eu-1"
            box["tenant"] = name == "other1" ? "personal" : "acme"
            box.removeValue(forKey: "runner_targets")
            destinations[name] = box
        }
        var acme: [String: Any] = ["repos": ["acme/ledger"]]
        if let style { acme["style"] = style }
        if let order { acme["order"] = order }
        base["destinations"] = destinations
        base["tenants"] = ["acme": acme, "personal": ["shared": true, "repos": ["person/tool"]],
                           "globex": ["owners": ["globex"], "repos": ["globex/portal*"]]]
        base["rules"] = [["name": "tenant priority", "match": [:], "to": chain]]
        return base
    }

    func route(probes: RunProbes, offline: Set<String> = [], slug: String = "acme/ledger") async throws -> RouteDecision {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tailnet/running.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let peers = try #require(object["Peer"] as? [String: [String: Any]])
        let template = try #require(peers["nodekey:ai-acme"])
        var copies = [String: [String: Any]]()
        for name in ["box1", "box2", "box3", "other1"] {
            var peer = template
            peer["ID"] = "tenant-\(name)"
            peer["Online"] = !offline.contains(name)
            copies[name] = peer
        }
        object["Peer"] = copies
        let state = TailnetState.parse(try JSONSerialization.data(withJSONObject: object), readAt: runNow)
        return await Router(rules: store.load(), tailnet: state, probes: probes,
                            fileExists: { _ in true }, now: { runNow }).route(
            RouteRequest(command: ["cargo", "test"], identity: RepoIdentity(slug: slug, worktree: home.url.path)))
    }
}

private func tenantEditFailure(_ action: () throws -> Void) {
    do {
        try action()
        Issue.record("Expected TenantEditing.Failure")
    } catch is TenantEditing.Failure {
    } catch {
        Issue.record("Expected TenantEditing.Failure, got \(error)")
    }
}

struct TenantStyleAcceptanceTests {
    @Test func legacyRulesRouteInWrittenOrderAndResolveStableDefaults() async throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        let run = try await RunFixture.make()
        defer { run.remove() }
        let rules = try fixture.loaded()
        #expect(rules.tenants["acme"]?.style == nil)
        #expect(rules.tenants["acme"]?.order == nil)
        let decision = try await fixture.route(probes: run.probes)
        #expect(decision.location == .destination(name: "box3", address: "100.64.0.10"))
        let empty = try JSONDecoder().decode(TenantStyle.self, from: Data("{}".utf8))
        let resolved = empty.resolved(for: "acme")
        #expect(resolved == empty.resolved(for: "acme"))
        let decodedAgain = try JSONDecoder().decode(TenantStyle.self, from: Data("{}".utf8))
        #expect(resolved == decodedAgain.resolved(for: "acme"))
        #expect(resolved.pattern == "none")
        #expect(resolved.width == 3)
        #expect(resolved.size == 10)
        #expect(resolved.angle == 45)
        #expect(resolved.scatter == 0)
        #expect(resolved.color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil)
        #expect(resolved.color == TenantStyle.defaultColor(for: "acme"))
        #expect(TenantStyle.defaultColor(for: "acme") != TenantStyle.defaultColor(for: "globex"))
    }

    @Test func invalidStyleFieldsFailLoadWithTenantAndField() throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        let cases: [(String, Any)] = [
            ("color", "red"), ("color", "#12345"), ("color", "#GGGGGG"), ("pattern", "plaid"),
            ("width", 0), ("width", 33), ("size", 3), ("size", 65),
            ("angle", -181), ("angle", 181), ("scatter", -0.1), ("scatter", 1.1), ("unknown_style_key", 1)
        ]
        for (field, value) in cases {
            try fixture.write(TenantStyleFixture.object(style: [field: value]))
            guard case .invalid(_, let message) = fixture.store.load() else {
                Issue.record("Accepted invalid acme style \(field): \(value)")
                continue
            }
            #expect(message.contains("acme"))
            #expect(message.contains(field))
        }
    }

    @Test func styleBoundariesAndAllPatternsLoad() throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        for pattern in ["none", "stripes", "dots"] {
            for upper in [false, true] {
                let style: [String: Any] = ["color": "#aB12Ef", "pattern": pattern,
                    "width": upper ? 32 : 1, "size": upper ? 64 : 4,
                    "angle": upper ? 180 : -180, "scatter": upper ? 1 : 0]
                try fixture.write(TenantStyleFixture.object(style: style))
                let loaded = try #require(try fixture.loaded().tenants["acme"]?.style)
                #expect(loaded.width == (upper ? 32 : 1))
                #expect(loaded.size == (upper ? 64 : 4))
                #expect(loaded.angle == (upper ? 180 : -180))
                #expect(loaded.scatter == (upper ? 1 : 0))
                #expect(loaded.pattern == pattern)
            }
        }
    }

    @Test func orderRejectsUnknownForeignAndDuplicateDestinations() throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        for order in [["missing"], ["other1"], ["box1", "box1"]] {
            try fixture.write(TenantStyleFixture.object(order: order))
            guard case .invalid = fixture.store.load() else {
                Issue.record("Accepted invalid order \(order)")
                continue
            }
        }
        try fixture.write(TenantStyleFixture.object(order: ["box2", "box1"]))
        #expect(try fixture.loaded().tenants["acme"]?.order == ["box2", "box1"])
    }

    @Test func routerTriesTenantPriorityAndExplainsAttemptsInOrder() async throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        let run = try await RunFixture.make()
        defer { run.remove() }
        try fixture.write(TenantStyleFixture.object(order: ["box1", "box2", "box3"]))
        let first = try await fixture.route(probes: run.probes)
        #expect(first.locationName == "box1")
        let second = try await fixture.route(probes: run.probes, offline: ["box1"])
        #expect(second.locationName == "box2")
        let third = try await fixture.route(probes: run.probes, offline: ["box1", "box2"])
        #expect(third.locationName == "box3")
        // Inspect attempt lines, not a printed chain that could conceal the actual traversal.
        let lines = third.explanation
        let one = try #require(lines.firstIndex { $0.contains("box1 offline") })
        let two = try #require(lines.firstIndex { $0.contains("box2 offline") })
        let three = try #require(lines.firstIndex { $0.contains("probe of box3") })
        #expect(one < two && two < three)
    }

    @Test func mixedTenantSlotsUnlistedOrderLocalTerminationAndDenySurvive() async throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        let run = try await RunFixture.make()
        defer { run.remove() }
        try fixture.write(TenantStyleFixture.object(order: ["box1", "box2", "box3"], chain: ["box3", "other1", "box1"]))
        var rules = try fixture.loaded()
        #expect(Tenancy.ordered(rules.rules[0].to, destinations: rules.destinations, tenants: rules.tenants)
                == ["box1", "other1", "box3"])
        let mixed = try await fixture.route(probes: run.probes, offline: ["box1"])
        #expect(mixed.locationName == "other1")
        try fixture.write(TenantStyleFixture.object(order: ["box2"], chain: ["box3", "box1", "box2"]))
        rules = try fixture.loaded()
        #expect(Tenancy.ordered(rules.rules[0].to, destinations: rules.destinations, tenants: rules.tenants)
                == ["box2", "box3", "box1"])
        let unlisted = try await fixture.route(probes: run.probes, offline: ["box2"])
        #expect(unlisted.locationName == "box3")
        try fixture.write(TenantStyleFixture.object(order: ["box1", "box2", "box3"], chain: ["box2", "local", "box3", "box1"]))
        let local = try await fixture.route(probes: run.probes, offline: ["box1"])
        #expect(local.location == .local)
        #expect(!local.explanation.contains { $0.contains("probe of box2") || $0.contains("probe of box3") })
        try fixture.write(TenantStyleFixture.object(order: ["box1", "box2", "box3"]))
        let denied = try await fixture.route(probes: run.probes, slug: "globex/portal")
        #expect(denied.location == .local)
        #expect(denied.explanation.joined(separator: "\n").contains("denied: tenant globex on acme destination"))
    }

    @Test func overviewSortsTenantsAndGroupsDestinationsWithResolvedStyle() throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        try fixture.write(TenantStyleFixture.object(style: ["color": "#123456", "pattern": "dots"], order: ["box3"]))
        var rules = try fixture.loaded()
        rules.destinations.removeValue(forKey: "box2")
        let summaries = TenantOverview.summaries(rules)
        #expect(summaries.map(\.name) == ["acme", "globex", "personal"])
        let acme = try #require(summaries.first { $0.name == "acme" })
        #expect(acme.isGroup)
        #expect(acme.destinations == ["box3", "box1"])
        #expect(acme.style == (try #require(rules.tenants["acme"]?.style)).resolved(for: "acme"))
        let empty = try #require(summaries.first { $0.name == "globex" })
        #expect(empty.destinations.isEmpty)
        #expect(!empty.isGroup)
        #expect(empty.owners == (rules.tenants["globex"]?.owners ?? []))
        #expect(empty.repos == (rules.tenants["globex"]?.repos ?? []))
        #expect(try #require(summaries.first { $0.name == "personal" }).shared == true)
    }

    @Test func styleAndOrderEditsRoundTripAndNilRemovesStyle() throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        let original = try fixture.loaded()
        let style = try JSONDecoder().decode(TenantStyle.self, from: Data(
            ##"{"color":"#2468AC","pattern":"stripes","width":5,"size":16,"angle":-30,"scatter":0.5}"##.utf8))
        try TenantEditing.apply(.style("acme", style), home: fixture.home)
        #expect(try fixture.loaded().tenants["acme"]?.style == style)
        try TenantEditing.apply(.order("acme", ["box3", "box1"]), home: fixture.home)
        let edited = try fixture.loaded()
        #expect(edited.tenants["acme"]?.order == ["box3", "box1"])
        #expect(edited.tenants["acme"]?.style == style)
        #expect(edited.destinations == original.destinations)
        #expect(edited.rules == original.rules)
        #expect(edited.tenants["personal"] == original.tenants["personal"])
        try TenantEditing.apply(.style("acme", nil), home: fixture.home)
        #expect(try fixture.loaded().tenants["acme"]?.style == nil)
        #expect(try fixture.loaded().tenants["acme"]?.order == ["box3", "box1"])
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.url)) as? [String: Any])
        let tenants = try #require(root["tenants"] as? [String: [String: Any]])
        #expect(tenants["acme"]?["style"] == nil)
    }

    @Test func invalidStyleAndStaleFingerprintLeaveFileByteIdentical() throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        let invalid = try JSONDecoder().decode(TenantStyle.self, from: Data(#"{"color":"nope"}"#.utf8))
        let before = try Data(contentsOf: fixture.store.url)
        tenantEditFailure { try TenantEditing.apply(.style("acme", invalid), home: fixture.home) }
        #expect(try Data(contentsOf: fixture.store.url) == before)
        guard case .valid(_, let stale) = fixture.store.load() else { throw CocoaError(.fileReadCorruptFile) }
        try TenantEditing.apply(.order("acme", ["box2"]), home: fixture.home)
        let external = try Data(contentsOf: fixture.store.url)
        tenantEditFailure { try TenantEditing.apply(.order("acme", ["box1"]), home: fixture.home, expected: stale) }
        #expect(try Data(contentsOf: fixture.store.url) == external)
    }

    @Test func assignNormalizesDeduplicatesAndChangesNextRoutingDecision() async throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        let run = try await RunFixture.make()
        defer { run.remove() }
        let before = try fixture.loaded()
        #expect(try await fixture.route(probes: run.probes, slug: "acme/notes").fallbackReason == "unclassified repo")
        try TenantEditing.apply(.assign(repo: "Acme/Notes", tenant: "acme"), home: fixture.home)
        try TenantEditing.apply(.assign(repo: "Acme/Notes", tenant: "acme"), home: fixture.home)
        let after = try fixture.loaded()
        #expect(after.tenants["acme"]?.repos == ["acme/ledger", "acme/notes"])
        #expect(Tenancy.resolve(RepoIdentity(slug: "acme/notes", worktree: fixture.home.url.path), in: after.tenants).tenant == "acme")
        let decision = try await fixture.route(probes: run.probes, slug: "acme/notes")
        #expect(decision.tenant == "acme")
        #expect(decision.fallbackReason != "unclassified repo")
        #expect(decision.locationName == "box3")
        #expect(after.tenants["personal"] == before.tenants["personal"])
        #expect(after.tenants["globex"] == before.tenants["globex"])
    }

    @Test func invalidAssignmentsPreserveEveryByte() throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.store.url)
        let cases = [("acme/notes", "missing"), ("notes", "acme"), ("a/b/c", "acme"),
                     ("/notes", "acme"), ("acme/", "acme"), ("person/tool", "acme"), ("globex/portal-one", "acme")]
        for (repo, tenant) in cases {
            tenantEditFailure { try TenantEditing.apply(.assign(repo: repo, tenant: tenant), home: fixture.home) }
            #expect(try Data(contentsOf: fixture.store.url) == before)
        }
    }

    @Test func assignableIncludesOnlyTenantsWithEnabledDestinationsSorted() throws {
        let fixture = try TenantStyleFixture()
        defer { fixture.remove() }
        var rules = try fixture.loaded()
        rules.destinations["box1"]?.enabled = false
        #expect(TenantEditing.assignable(rules) == ["acme", "personal"])
        rules.destinations["other1"]?.enabled = false
        #expect(TenantEditing.assignable(rules) == ["acme"])
        rules.destinations["box2"]?.enabled = false
        rules.destinations["box3"]?.enabled = false
        #expect(TenantEditing.assignable(rules).isEmpty)
    }

    @Test func canTagOnlyLocalNonGitHubUnclassifiedJobs() throws {
        var job = JobRecord(id: "tag-job", repo: "acme/notes", command: "cargo test",
                            location: "local", state: .done, queuedAt: runNow)
        job.tenant = "unclassified"
        let row = JobRowPresentation(job, now: runNow)
        #expect(row.canTag)
        #expect(row.title == "acme/notes")
        job.location = "box1"
        #expect(!JobRowPresentation(job, now: runNow).canTag)
        job.location = "local"
        job.tenant = "acme"
        #expect(!JobRowPresentation(job, now: runNow).canTag)
        job.tenant = "unclassified"
        job.github = #"{"repo":"acme/notes","name":"test","runId":1,"jobId":2,"runAttempt":1,"status":"completed","conclusion":"success","labels":[],"stepsDone":0,"stepsTotal":0,"waitingOnDependency":false}"#
        #expect(try #require(GitHubJobInfo.decode(job.github)).jobId == 2)
        #expect(!JobRowPresentation(job, now: runNow).canTag)
    }
}
