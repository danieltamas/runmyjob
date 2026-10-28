import Testing
import Foundation
import RMJCore

private func editingRule() throws -> Rule {
    try JSONDecoder().decode(Rule.self, from: Data("""
    {
      "name": "editor fixture",
      "match": {
        "owner": ["build-owner", "acme"],
        "repo": ["acme/axon", "acme/atlas"],
        "tenant": ["personal", "acme"],
        "path": ["/work/one", "/work/two"],
        "command": ["cargo test", "just"], "has": "Cargo.toml"
      },
      "to": ["ai-eu-1", "local"],
      "image": "rx-rust", "profile": "ledger", "advisory": "Keep this advice",
      "volumes": ["cache:/cache", "target:/work/target"],
      "cold_marker": {"acme/axon": "Compiling fixture"},
      "memory": "2g", "cpus": 2
    }
    """.utf8))
}

private func editingRules(_ store: RulesStore) throws -> Rules {
    guard case .valid(let rules, _) = store.load() else {
        Issue.record("Expected a valid rules file")
        throw CocoaError(.fileReadCorruptFile)
    }
    return rules
}

private func withEditingHome(_ body: (RMJHome, RulesStore, Rules) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rmj-rule-editing-\(UUID().uuidString)")
    let home = RMJHome(environment: ["RMJ_HOME": directory.path])
    defer { try? FileManager.default.removeItem(at: directory) }
    try home.prepare()
    try writeLedgerProfile(home: home)
    let store = RulesStore(home: home)
    guard case .valid(_, let fingerprint) = store.load() else {
        Issue.record("Expected a fresh temporary home")
        throw CocoaError(.fileReadCorruptFile)
    }
    try store.save(Rules.shipped, expected: fingerprint)
    let original = try editingRules(store)
    #expect(original == Rules.shipped)
    try body(home, store, original)
}

private func expectEditingFailure(_ action: () throws -> Void, containing text: String? = nil) {
    do {
        try action()
        Issue.record("Expected RuleEditing.Failure")
    } catch let failure as RuleEditing.Failure {
        #expect(!failure.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let text { #expect(failure.description.contains(text)) }
    } catch {
        Issue.record("Expected RuleEditing.Failure, got \(error)")
    }
}

struct RuleEditingAcceptanceTests {
    @Test func draftRoundTripsVisibleAndHiddenFieldsFromBase() throws {
        let base = try editingRule()
        let draft = RuleDraft(base)
        #expect(try draft.rule(base: base) == base)

        var edited = draft
        edited.name = "renamed in editor"
        edited.image = "rx-node"
        let result = try edited.rule(base: base)
        #expect(result.name == "renamed in editor")
        #expect(result.image == "rx-node")
        #expect(result.match == base.match)
        #expect(result.to == base.to)
        #expect(result.profile == base.profile)
        #expect(result.advisory == base.advisory)
        #expect(result.volumes == base.volumes)
        #expect(result.coldMarker == base.coldMarker)
        #expect(result.memory == base.memory)
        #expect(result.cpus == base.cpus)
    }

    @Test func commaSeparatedFieldsTrimAndDropEmptyParts() throws {
        var draft = RuleDraft()
        draft.name = "trimmed lists"
        draft.owner = " alice, , bob ,, "
        draft.repo = " alice/one, ,bob/two, "
        draft.tenant = " personal, , acme, "
        draft.path = " /work/one, , /work/two, "
        draft.command = " cargo test, , just, "
        draft.to = " ai-eu-1, , local,, "
        let rule = try draft.rule(base: nil)
        #expect(rule.match.owner == ["alice", "bob"])
        #expect(rule.match.repo == ["alice/one", "bob/two"])
        #expect(rule.match.tenant == ["personal", "acme"])
        #expect(rule.match.path == ["/work/one", "/work/two"])
        #expect(rule.match.command == ["cargo test", "just"])
        #expect(rule.to == ["ai-eu-1", "local"])
    }

    @Test func clearingOptionalFieldsRemovesTheirEncodedKeys() throws {
        let base = try editingRule()
        var draft = RuleDraft(base)
        draft.owner = " , , "
        draft.repo = ""
        draft.tenant = ""
        draft.path = ""
        draft.command = ""
        draft.has = ""
        draft.image = ""
        draft.profile = ""
        draft.advisory = ""
        let rule = try draft.rule(base: base)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        let match = try #require(object["match"] as? [String: Any])
        #expect(match.isEmpty)
        for key in ["image", "profile", "advisory"] { #expect(object[key] == nil) }
        #expect(rule.volumes == base.volumes)
        #expect(rule.coldMarker == base.coldMarker)
        #expect(rule.memory == base.memory)
        #expect(rule.cpus == base.cpus)
        // `to` is required: clearing it produces an empty list for save validation.
        draft.to = " , "
        #expect(try draft.rule(base: base).to.isEmpty)
    }

    @Test func appendReplaceAndDeletePersistOnlyTheRequestedChange() throws {
        try withEditingHome { home, store, original in
            let added = try editingRule()
            var expected = original
            expected.rules.append(added)
            try RuleEditing.apply(.append(added), home: home)
            #expect(try editingRules(store) == expected)

            var replacement = original.rules[1]
            replacement.name = "replacement rule"
            replacement.advisory = "Edited advice"
            expected.rules[1] = replacement
            try RuleEditing.apply(.replace(1, replacement), home: home)
            #expect(try editingRules(store) == expected)

            expected.rules.remove(at: 1)
            try RuleEditing.apply(.delete(1), home: home)
            #expect(try editingRules(store) == expected)
        }
    }

    @Test func movesSwapNeighboursAndEndMovesAreNoOps() throws {
        try withEditingHome { home, store, original in
            var swapped = original
            swapped.rules = [original.rules[1], original.rules[0]] + Array(original.rules.dropFirst(2))
            try RuleEditing.apply(.move(0, by: 1), home: home)
            #expect(try editingRules(store) == swapped)
            try RuleEditing.apply(.move(1, by: -1), home: home)
            #expect(try editingRules(store) == original)

            let bytes = try Data(contentsOf: store.url)
            try RuleEditing.apply(.move(0, by: -1), home: home)
            #expect(try editingRules(store) == original)
            #expect(try Data(contentsOf: store.url) == bytes)
            try RuleEditing.apply(.move(original.rules.count - 1, by: 1), home: home)
            #expect(try editingRules(store) == original)
            #expect(try Data(contentsOf: store.url) == bytes)
        }
    }

    @Test func unknownDestinationEditFailsWithoutChangingDiskBytes() throws {
        try withEditingHome { home, store, original in
            let bytes = try Data(contentsOf: store.url)
            var invalid = original.rules[0]
            invalid.to = ["missing-editor-destination"]
            expectEditingFailure({ try RuleEditing.apply(.replace(0, invalid), home: home) },
                                 containing: "missing-editor-destination")
            #expect(try Data(contentsOf: store.url) == bytes)
            #expect(try editingRules(store) == original)
        }
    }

    @Test func invalidFileAfterLoadRefusesEditAndPreservesExternalBytes() throws {
        try withEditingHome { home, store, original in
            let external = Data("{invalid rules written after load".utf8)
            try external.write(to: store.url)
            expectEditingFailure({ try RuleEditing.apply(.delete(0), home: home) },
                                 containing: "the rules file is invalid")
            #expect(try Data(contentsOf: store.url) == external)
            guard case .invalid = store.load() else {
                Issue.record("The external invalid file must remain invalid")
                return
            }
            #expect(!original.rules.isEmpty)
        }
    }

    @Test func outOfRangeReplaceAndDeleteFailWithoutChangingDiskBytes() throws {
        try withEditingHome { home, store, original in
            let bytes = try Data(contentsOf: store.url)
            for index in [-1, original.rules.count, original.rules.count + 1] {
                for change in [RuleEditing.Change.replace(index, original.rules[0]), .delete(index)] {
                    expectEditingFailure { try RuleEditing.apply(change, home: home) }
                    #expect(try Data(contentsOf: store.url) == bytes)
                    #expect(try editingRules(store) == original)
                }
            }
        }
    }
}
