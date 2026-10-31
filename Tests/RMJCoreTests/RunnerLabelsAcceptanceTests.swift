import Testing
import Foundation
import CryptoKit
import RMJCore

private let labelsTarget = "danieltamas/lexito.ro"
private let labelsStack = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Support/runner-stack")

private func labelsBase() throws -> String {
    try String(contentsOf: labelsStack.appendingPathComponent("docker-compose.yml"), encoding: .utf8)
}

private func labelsSHA(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func labelsRules(_ labels: [String: [String]]? = nil) throws -> Data {
    var root = try #require(JSONSerialization.jsonObject(with: Data(Rules.shippedJSON.utf8)) as? [String: Any])
    var destinations = try #require(root["destinations"] as? [String: [String: Any]])
    var tenants = try #require(root["tenants"] as? [String: [String: Any]])
    var owners = tenants["acme"]?["owners"] as? [String] ?? []
    owners.append("danieltamas")
    tenants["acme"]?["owners"] = owners
    destinations["ai-eu-1"]?["runner_targets"] = [labelsTarget, "org:Acme"]
    destinations["ai-eu-1"]?.removeValue(forKey: "runner_labels")
    if let labels { destinations["ai-eu-1"]?["runner_labels"] = labels }
    root["destinations"] = destinations
    root["tenants"] = tenants
    return try JSONSerialization.data(withJSONObject: root)
}

private func labelsExpectError(_ labels: [String: [String]], offending: String) throws {
    let data = try labelsRules(labels)
    do {
        _ = try RulesValidation.parse(data)
        Issue.record("Invalid runner_labels accepted: \(offending)")
    } catch let error as RulesError {
        #expect(error.description.contains("runner_labels"))
        if offending.isEmpty {
            #expect(error.description.contains("\"\""))
        } else {
            #expect(error.description.contains(offending))
        }
    } catch {
        Issue.record("Expected RulesError, got \(error)")
    }
}

struct RunnerLabelsAcceptanceTests {
    @Test func extrasFollowDerivedLabelInOrderAndKeysIgnoreCase() throws {
        let base = try labelsBase()
        for key in [labelsTarget, "DANIELTAMAS/LEXITO.RO"] {
            let compose = RunnerCompose(base: base, targets: [labelsTarget], host: "fixture-box",
                labels: [key: ["lexito", "Deploy_2.v1"]])
            let yaml = try #require(compose.generated)
            #expect(compose.services == ["runner-lexito-ro"])
            #expect(yaml.components(separatedBy: "\n").filter { $0.contains("RUNNER_LABELS:") }
                == ["      RUNNER_LABELS: lexito-ro,lexito,Deploy_2.v1"])
        }
    }

    @Test func absentUnrelatedAndEmptyEntriesPreserveOriginalBytes() throws {
        let base = try labelsBase()
        let original = RunnerCompose(base: base, targets: [labelsTarget], host: "fixture-box")
        let yaml = try #require(original.generated)
        #expect(yaml.components(separatedBy: "\n").filter { $0.contains("RUNNER_LABELS:") }
            == ["      RUNNER_LABELS: lexito-ro"])
        let variants: [[String: [String]]] = [[:], [labelsTarget: []], ["other/repo": ["other"]]]
        for labels in variants {
            let compose = RunnerCompose(base: base, targets: [labelsTarget], host: "fixture-box", labels: labels)
            #expect(compose.generated == original.generated)
            #expect(compose.services == original.services)
            #expect(compose.manifest == original.manifest)
        }
    }

    @Test func duplicatesAreDroppedWithoutReorderingRemainingExtras() throws {
        let compose = RunnerCompose(base: try labelsBase(), targets: [labelsTarget], host: "fixture-box",
            labels: [labelsTarget: ["lexito-ro", "lexito", "lexito", "build", "lexito-ro", "build", "last"]])
        let yaml = try #require(compose.generated)
        #expect(yaml.components(separatedBy: "\n").filter { $0.contains("RUNNER_LABELS:") }
            == ["      RUNNER_LABELS: lexito-ro,lexito,build,last"])
    }

    @Test func invalidLabelsNeverReachYAMLAndLengthBoundaryIsAccepted() throws {
        let maximum = "a" + String(repeating: "z", count: 63)
        let invalid = ["", "-bad", ".bad", "_bad", "bad label", "bad,label", "bad/label",
                       "bad:label", "bad\nINJECTED: yes", "bad\rlabel", "bad\tlabel",
                       "bad\u{00E9}", String(repeating: "x", count: 65)]
        let base = try labelsBase()
        let expected = try #require(RunnerCompose(base: base, targets: [labelsTarget], host: "fixture-box",
            labels: [labelsTarget: ["safe", maximum, "Z_1.-"]]).generated)
        for bad in invalid {
            let actual = RunnerCompose(base: base, targets: [labelsTarget], host: "fixture-box",
                labels: [labelsTarget: ["safe", bad, maximum, "Z_1.-"]])
            #expect(actual.generated == expected)
        }
        #expect(expected.components(separatedBy: "\n").filter { $0.contains("RUNNER_LABELS:") }
            == ["      RUNNER_LABELS: lexito-ro,safe,\(maximum),Z_1.-"])
    }

    @Test func destinationCodableUsesSnakeCaseAndPreservesAbsentNil() throws {
        let mapping = [labelsTarget: ["lexito", "Deploy_2.v1"], "ORG:ACME": []]
        let rules = try JSONDecoder().decode(Rules.self, from: labelsRules(mapping))
        let destination = try #require(rules.destinations["ai-eu-1"])
        #expect(destination.runnerLabels == mapping)
        let encoded = try JSONEncoder().encode(destination)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["runner_labels"] as? [String: [String]] == mapping)
        #expect(object["runnerLabels"] == nil)
        #expect(try JSONDecoder().decode(DestinationConfig.self, from: encoded).runnerLabels == mapping)

        let absent = try JSONDecoder().decode(Rules.self, from: labelsRules())
        let absentDestination = try #require(absent.destinations["ai-eu-1"])
        #expect(absentDestination.runnerLabels == nil)
        let roundTrip = try JSONDecoder().decode(DestinationConfig.self, from: JSONEncoder().encode(absentDestination))
        #expect(roundTrip.runnerLabels == nil)
    }

    @Test func validationRejectsUnknownTargetAndEveryInvalidLabel() throws {
        try labelsExpectError(["danieltamas/unknown": ["lexito"]], offending: "danieltamas/unknown")
        try labelsExpectError(["other/lexito.ro": ["lexito"]], offending: "other/lexito.ro")
        for bad in ["-bad", ".bad", "_bad", "bad label", "bad,label", "bad/label", "bad:label",
                    "bad\u{00E9}", String(repeating: "x", count: 65)] {
            try labelsExpectError([labelsTarget: ["valid", bad]], offending: bad)
        }
        // Empty labels must also fail, even though an empty offending value has no visible text.
        try labelsExpectError([labelsTarget: [""]], offending: "")
    }

    @Test func validRulesAcceptMixedCaseKeysEmptyListsAndBoundaryLabels() throws {
        let mapping = ["DANIELTAMAS/LEXITO.RO": ["lexito", "A", "Build_2.v1-test", String(repeating: "a", count: 64)],
                       "ORG:ACME": []]
        let rules = try RulesValidation.parse(labelsRules(mapping))
        #expect(rules.destinations["ai-eu-1"]?.runnerLabels == mapping)
        #expect(try RulesValidation.parse(labelsRules()).destinations["ai-eu-1"]?.runnerLabels == nil)
    }

    @Test func labelOnlyChangeReportsDriftAndDeployWritesComposeWithoutSyncing() async throws {
        let base = try labelsBase()
        let targets = [labelsTarget, "danieltamas/unchanged"]
        let oldLabels = [labelsTarget: ["old-label"]]
        let newLabels = [labelsTarget: ["lexito"]]
        let old = RunnerCompose(base: base, targets: targets, host: "fixture-box", labels: oldLabels)
        let new = RunnerCompose(base: base, targets: targets, host: "fixture-box", labels: newLabels)
        let oldYAML = try #require(old.generated)
        let newYAML = try #require(new.generated)
        #expect(oldYAML != newYAML)
        #expect(old.manifest == new.manifest)
        let stack = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-labels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stack) }
        try Data(base.utf8).write(to: stack.appendingPathComponent("docker-compose.yml"))
        try Data().write(to: stack.appendingPathComponent("entrypoint.sh"))
        let files = "\(labelsSHA(Data(base.utf8)))  docker-compose.yml\n"
            + "\(labelsSHA(Data()))  entrypoint.sh\n"
        let env = Data("GH_PAT_DANIELTAMAS=fixture_token\n".utf8)
        let credentialsHash = labelsSHA(Data((labelsSHA(env) + "\n").utf8))
        for current in [false, true] {
            let remoteHash = labelsSHA(Data((current ? newYAML : oldYAML).utf8))
            let servicesHash = labelsSHA(Data(old.manifest.utf8))
            let shell = FakeShell { script, _ in
                if script.contains("/.env'") { return u6Output("__absent__") }
                if script.contains("/.rmj-credentials'") { return u6Output(credentialsHash) }
                if script.contains("sha256sum"), script.contains("| cut ") {
                    if script.contains("/docker-compose.rmj.yml'") { return u6Output(remoteHash) }
                    if script.contains("/.rmj-services'") { return u6Output(servicesHash) }
                    Issue.record("Unexpected remote hash: \(script)")
                    return u6Output("__absent__")
                }
                if script.contains("sha256sum") { return u6Output(files) }
                if script.contains("cat >") || script.contains("docker compose") || script.contains("docker ps -a") {
                    return u6Output()
                }
                Issue.record("Unexpected fake command: \(script)")
                return u6Output()
            }
            let tokens = Dictionary(uniqueKeysWithValues: targets.map { ($0, "fixture_token") })
            let deployer = RunnerStackDeployer(shell: shell, stack: stack, home: "/home/fixture",
                tokens: tokens, requiredTargets: targets, host: "fixture-box", labels: newLabels)
            let report = try await deployer.report()
            #expect(report.composeChanged == !current)
            #expect(report.isNoOp == current)
            #expect(report.changedFiles.isEmpty && !report.credentialsChanged)
            #expect(shell.calls.allSatisfy { $0.input == nil && $0.directory == nil })
            let deployed = try await deployer.deploy()
            #expect(deployed.composeChanged == !current)
            #expect(shell.calls.allSatisfy { $0.directory == nil })
            let writes = shell.calls.filter { $0.script.contains("cat >") }
            let commands = shell.calls.filter { $0.script.contains("docker compose") }
            if current {
                #expect(writes.isEmpty && commands.isEmpty && deployed.performed.isEmpty)
            } else {
                let composeWrites = writes.filter { $0.script.contains("docker-compose.rmj.yml") }
                #expect(composeWrites.count == 1)
                let write = try #require(composeWrites.first)
                #expect(write.script.contains("docker-compose.rmj.yml"))
                #expect(write.input == Data(newYAML.utf8))
                let up = try #require(commands.first { $0.script.contains("docker compose up -d") })
                #expect(up.script.contains("COMPOSE_FILE=docker-compose.yml:docker-compose.rmj.yml"))
                #expect(!up.script.contains("--force-recreate"))
                #expect(up.input == env)
                #expect(!commands.contains { $0.script.contains("docker compose down") || $0.script.contains("docker compose rm ") })
            }
        }
    }
}
