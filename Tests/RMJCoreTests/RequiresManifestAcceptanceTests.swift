import Foundation
import Testing
import RMJCore

// Records transport requests without starting a process or contacting a box.
private actor ManifestSetupShell: OpsShell {
    private(set) var scripts: [String] = []
    private(set) var syncs = 0
    let output: String

    init(output: String = "docker-ok\nrsync-ok") { self.output = output }

    func run(_ script: String, input: Data?, timeout: Duration) async throws -> ProcessOutput {
        scripts.append(script)
        #expect(input == nil)
        #expect(script.contains("docker info"), "No later setup command should run")
        #expect(script.contains("rsync --version"))
        return ProcessOutput(status: 0, stdout: Data(output.utf8), stderr: "")
    }

    func sync(directory: URL, to remote: String) async throws {
        syncs += 1
        Issue.record("No sync should run for these setup fixtures")
    }
}

private func manifestData(_ requires: [String]? = nil, enabled: Bool = true,
                          unknownKey: Bool = false) throws -> Data {
    var destination: [String: Any] = [
        "enabled": enabled, "peer_id": "fixture-peer", "ssh_alias": "fixture",
        "tenant": "fixture", "roles": [], "home": "/home/fixture",
        "max_jobs": 2, "memory_budget": "4g"
    ]
    if let requires { destination["requires"] = requires }
    if unknownKey { destination["unexpected_manifest_key"] = true }
    return try JSONSerialization.data(withJSONObject: [
        "destinations": ["fixture-box": destination],
        "tenants": ["fixture": ["owners": ["fixture"]]], "rules": []
    ])
}

private func manifestConfig() throws -> DestinationConfig {
    // Decode the baseline without validation; mutations below model in-code callers.
    let rules = try JSONDecoder().decode(Rules.self, from: manifestData())
    return try #require(rules.destinations["fixture-box"])
}

private func manifestSetup(_ shell: ManifestSetupShell, config: DestinationConfig) -> DestinationSetup {
    DestinationSetup(shell: shell, name: "fixture-box", config: config,
                     stack: nil, images: nil, neededImages: ["rx-missing"], tokens: [:],
                     registrationWait: .zero, settle: { _ in })
}

private func expectManifestError(_ names: [String], enabled: Bool) throws {
    do {
        _ = try RulesValidation.parse(manifestData(names, enabled: enabled))
        Issue.record("Invalid requires manifest was accepted: \(names)")
    } catch let error as RulesError {
        #expect(error.message.hasPrefix("destination fixture-box: requires"))
    } catch {
        Issue.record("Expected RulesError, got \(error)")
    }
}

struct RequiresManifestAcceptanceTests {
    @Test func validProgramNamesParseAndRoundTrip() throws {
        let names = ["zsh", "bun", "python3.12", "g++", "A_0-+.", String(repeating: "a", count: 64)]
        for enabled in [true, false] {
            let rules = try RulesValidation.parse(manifestData(names, enabled: enabled))
            #expect(rules.destinations["fixture-box"]?.requires == names)
            let encoded = try JSONEncoder().encode(rules)
            let root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let destinations = try #require(root["destinations"] as? [String: [String: Any]])
            #expect(destinations["fixture-box"]?["requires"] as? [String] == names)
            #expect(try RulesValidation.parse(encoded) == rules)
        }
    }

    @Test func absentAndEmptyManifestsParse() throws {
        let absent = try RulesValidation.parse(manifestData())
        let empty = try RulesValidation.parse(manifestData([]))
        #expect(absent.destinations["fixture-box"]?.requires == nil)
        #expect(empty.destinations["fixture-box"]?.requires == [])
    }

    @Test(arguments: ["", "a b", "zsh;rm", "$(x)", "../zsh", "-zsh",
                      String(repeating: "a", count: 65), "a/b", "zsh\n"])
    func invalidProgramNamesAreRejectedEvenWhenDisabled(_ name: String) throws {
        for enabled in [true, false] {
            try expectManifestError(["bun", name], enabled: enabled)
        }
    }

    @Test func duplicateProgramsAreRejectedEvenWhenDisabled() throws {
        for enabled in [true, false] {
            try expectManifestError(["zsh", "bun", "zsh"], enabled: enabled)
        }
    }

    @Test func unknownDestinationKeysRemainRejected() throws {
        do {
            _ = try RulesValidation.parse(manifestData(["zsh"], unknownKey: true))
            Issue.record("Unknown destination key was accepted")
        } catch let error as RulesError {
            #expect(error.message.contains("unknown key"))
            #expect(error.message.contains("unexpected_manifest_key"))
        } catch {
            Issue.record("Expected RulesError, got \(error)")
        }
    }

    @Test func presentProgramsKeepPrerequisitesUnchangedWithExactDetail() async throws {
        for names in [nil, [], ["zsh", "bun"]] as [[String]?] {
            var config = try manifestConfig()
            config.requires = names
            let shell = ManifestSetupShell()
            let report = await manifestSetup(shell, config: config).run()
            #expect(report.steps.count == 1)
            let step = try #require(report.steps.first)
            #expect(step.name == "prerequisites")
            #expect(step.outcome == .unchanged)
            #expect(step.detail == "docker and rsync present")
            #expect(step.hint == nil)
            #expect(report.isReady && !report.changed)
            #expect(await shell.scripts.count == 1)
        }
    }

    @Test func hostMissingProgramOutputDoesNotStopSetup() async throws {
        var config = try manifestConfig()
        config.requires = ["zsh", "bun"]
        let shell = ManifestSetupShell(output: "docker-ok\nrsync-ok\nmissing:zsh\nmissing:bun")
        let report = await manifestSetup(shell, config: config).run()
        #expect(report.steps.count == 1)
        #expect(report.steps.first?.name == "prerequisites")
        #expect(report.steps.first?.detail == "docker and rsync present")
        #expect(report.isReady && !report.changed)
    }

    @Test func dockerAndRsyncFailuresTakePrecedenceOverMissingPrograms() async throws {
        for (output, name, detail, hint) in [
            ("rsync-ok\nmissing:zsh", "docker", "docker is not usable for this user",
             "Install docker and add the ssh user to the docker group"),
            ("docker-ok\nmissing:zsh", "rsync", "rsync is missing", "Install rsync on the box")
        ] {
            var config = try manifestConfig()
            config.requires = ["zsh"]
            let shell = ManifestSetupShell(output: output)
            let report = await manifestSetup(shell, config: config).run()
            #expect(report.steps.count == 1)
            let step = try #require(report.steps.first)
            #expect(step.name == name && step.outcome == .failed)
            #expect(step.detail == detail && step.hint == hint)
            #expect(!report.isReady)
            #expect(await shell.scripts.count == 1)
        }
    }

    @Test func requiredProgramsNeverEnterThePrerequisitesScript() async throws {
        var config = try manifestConfig()
        config.requires = ["zsh", "bun", "python3.12", "g++"]
        let shell = ManifestSetupShell()
        _ = await manifestSetup(shell, config: config).run()
        let scripts = await shell.scripts
        #expect(scripts.count == 1)
        let script = try #require(scripts.first)
        #expect(!script.contains("command -v"))
        for name in config.requires ?? [] { #expect(!script.contains(name)) }
    }

    @Test func nilAndEmptyManifestsPreserveTheOriginalScriptByteForByte() async throws {
        let baseline = ManifestSetupShell()
        _ = await manifestSetup(baseline, config: try manifestConfig()).run()
        let scripts = await baseline.scripts
        #expect(scripts == ["docker info >/dev/null 2>&1 && echo docker-ok; rsync --version >/dev/null 2>&1 && echo rsync-ok"])
        for names in [nil, []] as [[String]?] {
            var config = try manifestConfig()
            config.requires = names
            let shell = ManifestSetupShell()
            _ = await manifestSetup(shell, config: config).run()
            #expect(await shell.scripts == scripts)
        }
    }

    @Test(arguments: ["", "a b", "zsh;rm", "$(x)", "../zsh", "-zsh", String(repeating: "a", count: 65)])
    func invalidInCodeManifestMakesNoShellCall(_ entry: String) async throws {
        var config = try manifestConfig()
        config.requires = ["bun", entry]
        config.roles = ["rx", "runners"]
        let shell = ManifestSetupShell()
        let report = await manifestSetup(shell, config: config).run()
        #expect(report.steps.count == 1)
        let step = try #require(report.steps.first)
        #expect(step.name == "tools" && step.outcome == .failed)
        #expect(step.detail == "requires entry \"\(entry)\" is not a program name")
        #expect(step.hint == "Fix requires in rules.json")
        #expect(!report.isReady && !report.changed)
        #expect(await shell.scripts.isEmpty)
        #expect(await shell.syncs == 0)
    }
}
