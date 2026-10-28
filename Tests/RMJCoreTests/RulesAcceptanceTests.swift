import Testing
import Foundation
import CryptoKit
import RMJCore

private func rulesData(_ rules: Rules) throws -> Data {
    try JSONEncoder().encode(rules)
}

private func rulesWithUnknownKey(_ level: String) throws -> Data {
    var root = try #require(JSONSerialization.jsonObject(with: Data(Rules.shippedJSON.utf8)) as? [String: Any])
    switch level {
    case "root": root["unexpected_root"] = true
    case "destination":
        var destinations = try #require(root["destinations"] as? [String: [String: Any]])
        destinations["ai-eu-1"]?["unexpected_destination"] = true
        root["destinations"] = destinations
    default:
        var rules = try #require(root["rules"] as? [[String: Any]])
        var match = try #require(rules[0]["match"] as? [String: Any])
        match["unexpected_match"] = true
        rules[0]["match"] = match
        root["rules"] = rules
    }
    return try JSONSerialization.data(withJSONObject: root)
}

private func expectRulesError(_ data: Data, containing text: String) {
    do {
        _ = try RulesValidation.parse(data)
        Issue.record("Invalid rules were accepted: \(text)")
    } catch let error as RulesError {
        #expect(error.description.contains(text))
    } catch {
        Issue.record("Expected RulesError, got \(error)")
    }
}

private func temporaryRulesHome() throws -> RMJHome {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-rules-\(UUID().uuidString)").path
    let home = RMJHome(environment: ["RMJ_HOME": path])
    try home.prepare()
    try writeLedgerProfile(home: home)
    return home
}

private func rulesFingerprint(_ state: RulesState) throws -> String {
    guard case .valid(_, let fingerprint) = state else {
        Issue.record("Expected valid rules state")
        throw CocoaError(.fileReadCorruptFile)
    }
    return fingerprint
}

private struct InvalidRulesTransport: RemoteTransport {
    func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput {
        throw ProcessRunner.Failure.timedOut
    }
}

private actor InvalidRulesProbeSpy: ProbeProvider {
    private(set) var calls = 0
    func latest(for destination: String) async -> DestinationProbeResult? { nil }
    func probe(_ target: DestinationTarget, tailnet: TailnetState) async -> DestinationProbeResult {
        calls += 1
        return await DestinationProbe(transport: InvalidRulesTransport()).probe(target, tailnet: tailnet)
    }
}

struct RulesAcceptanceTests {
    @Test func starterRulesAreValidAndEmpty() throws {
        let rules = try RulesValidation.parse(Data(Rules.starterJSON.utf8))
        #expect(rules == Rules.starter)
        #expect(rules.destinations.isEmpty)
        #expect(rules.tenants.isEmpty)
        #expect(rules.rules.isEmpty)
    }

    @Test func undeclaredRuleTenantsAreRejected() throws {
        for tenant in ["acme", "globex", "personal", "acme"] {
            let json = """
            { "destinations": {}, "tenants": {}, "rules": [
              { "name": "local", "match": { "tenant": ["\(tenant)"] }, "to": ["local"] }
            ] }
            """
            expectRulesError(Data(json.utf8), containing: "unknown tenant \"\(tenant)\"")
        }
    }

    @Test func declaredCustomTenantIsAccepted() throws {
        let json = """
        { "destinations": {}, "tenants": { "acme": { "owners": ["acme"] } }, "rules": [
          { "name": "local", "match": { "tenant": ["acme"] }, "to": ["local"] }
        ] }
        """
        let rules = try RulesValidation.parse(Data(json.utf8))
        #expect(rules.tenants["acme"]?.owners == ["acme"])
        #expect(rules.rules.first?.match.tenant == ["acme"])
    }

    @Test func shippedRulesDecodeValidateAndKeepS1DisabledWithoutPeerID() throws {
        let decoded = try JSONDecoder().decode(Rules.self, from: Data(Rules.shippedJSON.utf8))
        let validated = try RulesValidation.parse(Data(Rules.shippedJSON.utf8))
        #expect(decoded == Rules.shipped)
        #expect(validated == Rules.shipped)
        let s1 = try #require(validated.destinations["s1"])
        #expect(!s1.enabled)
        #expect(s1.peerID.isEmpty)
    }

    @Test func unknownKeysAtRootDestinationAndMatchThrowNamedRulesErrors() throws {
        for level in ["root", "destination", "match"] {
            expectRulesError(try rulesWithUnknownKey(level), containing: "unexpected_\(level)")
        }
    }

    @Test func unknownDestinationThrowsRulesError() throws {
        var rules = Rules.shipped
        rules.rules[0].to = ["missing-destination"]
        expectRulesError(try rulesData(rules), containing: "missing-destination")
    }

    @Test func duplicateRuleNamesThrowRulesError() throws {
        var rules = Rules.shipped
        rules.rules[1].name = rules.rules[0].name
        expectRulesError(try rulesData(rules), containing: "duplicate rule name")
    }

    @Test func emptyPeerIDIsAcceptedOnlyWhenDestinationDisabled() throws {
        var rules = Rules.shipped
        rules.destinations["s1"]?.enabled = false
        rules.destinations["s1"]?.peerID = ""
        #expect(try RulesValidation.parse(rulesData(rules)) == rules)
        rules.destinations["s1"]?.enabled = true
        expectRulesError(try rulesData(rules), containing: "peer_id")
    }

    @Test func ruleMemoryAboveDestinationBudgetThrowsRulesError() throws {
        var rules = Rules.shipped
        rules.rules[1].memory = "37g"
        expectRulesError(try rulesData(rules), containing: "above the budget")
    }

    @Test func invalidJSONThrowsRulesError() {
        expectRulesError(Data("{broken".utf8), containing: "JSON")
    }

    @Test func invalidRulesFileMakesEveryRequestLocalWithPathAndMessage() async throws {
        let home = try temporaryRulesHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let store = RulesStore(home: home)
        var unknownDestination = Rules.shipped
        unknownDestination.rules[1].to = ["absent-box"]
        for data in [try rulesWithUnknownKey("root"), try rulesData(unknownDestination)] {
            try data.write(to: store.url)
            let loaded = store.load()
            guard case .invalid(let path, let message) = loaded else {
                Issue.record("RulesStore must expose an invalid file")
                continue
            }
            #expect(path == store.url.path)
            #expect(!message.isEmpty)
            #expect(message.contains("unexpected_root") || message.contains("absent-box"))
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Fixtures/tailnet/running.json").path
            let state = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": fixture])
            let spy = InvalidRulesProbeSpy()
            let router = Router(rules: loaded, tailnet: state, probes: spy, fileExists: { _ in true })
            for (slug, command, destination) in [
                ("acme/axon", ["cargo", "test"], nil),
                ("acme/atlas", ["true"], "ai-eu-1"),
                ("globex/portal-x", ["cargo", "build"], nil)
            ] as [(String, [String], String?)] {
                let request = RouteRequest(command: command, identity: RepoIdentity(slug: slug, worktree: home.url.path),
                                           destination: destination)
                let decision = await router.route(request)
                #expect(decision.location == .local)
                #expect(decision.fallbackReason == "rules invalid: \(path) \(message)")
            }
            #expect(await spy.calls == 0)
        }
    }

    @Test func absentRulesFileLoadsStarterRulesWithoutCreatingFile() throws {
        let home = try temporaryRulesHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let store = RulesStore(home: home)
        #expect(store.load().rules == Rules.starter)
        let expected = SHA256.hash(data: Data(Rules.starterJSON.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(try rulesFingerprint(store.load()) == expected)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func savePublishesCompleteRulesAtomicallyWithPrivatePermissions() throws {
        let home = try temporaryRulesHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let store = RulesStore(home: home)
        let expected = try rulesFingerprint(store.load())
        try store.save(Rules.shipped, expected: expected)
        var edited = Rules.shipped
        edited.rules[0].advisory = "Saved acceptance edit"
        let before = try rulesFingerprint(store.load())
        // An open reader retains the old inode across an atomic replacement.
        let reader = try FileHandle(forReadingFrom: store.url)
        defer { try? reader.close() }
        let oldBytes = try Data(contentsOf: store.url)
        try store.save(edited, expected: before)
        #expect(try reader.readToEnd() == oldBytes)
        #expect(try RulesValidation.parse(Data(contentsOf: store.url)) == edited)
        #expect(store.load().rules == edited)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.url.path).sorted() == ["profiles", "rules.json"])
    }

    @Test func externalChangeRefusesSaveAndPreservesExactDiskBytes() throws {
        let home = try temporaryRulesHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let store = RulesStore(home: home)
        try store.save(Rules.shipped, expected: rulesFingerprint(store.load()))
        let stale = try rulesFingerprint(store.load())
        let external = Data((Rules.shippedJSON + "\n\n").utf8)
        try external.write(to: store.url)
        var edited = Rules.shipped
        edited.rules[0].advisory = "This must not be written"
        do {
            try store.save(edited, expected: stale)
            Issue.record("An external edit must reject the save")
        } catch RulesStore.Failure.changedExternally(let current) {
            #expect(Data(current.utf8) == external)
        } catch {
            Issue.record("Expected changedExternally, got \(error)")
        }
        #expect(try Data(contentsOf: store.url) == external)
    }

    @Test func invalidSavePreservesPreviousFileByteForByte() throws {
        let home = try temporaryRulesHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let store = RulesStore(home: home)
        try store.save(Rules.shipped, expected: rulesFingerprint(store.load()))
        let original = try Data(contentsOf: store.url)
        let expected = try rulesFingerprint(store.load())
        var invalid = Rules.shipped
        invalid.rules[1].memory = "37g"
        do {
            try store.save(invalid, expected: expected)
            Issue.record("Invalid rules must reject the save")
        } catch RulesStore.Failure.invalid(let message) {
            #expect(message.contains("above the budget"))
        } catch {
            Issue.record("Expected invalid, got \(error)")
        }
        #expect(try Data(contentsOf: store.url) == original)
        #expect(store.load().rules == Rules.shipped)
    }
}
