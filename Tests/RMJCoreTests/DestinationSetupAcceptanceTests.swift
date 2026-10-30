import Testing
import Foundation
import RMJCore
import CryptoKit

private let setupCompose = """
services:
  runner-fixture:
    environment:
      RUNNER_SCOPE: repo
      RUNNER_TARGET: fixture/repo
  runner-one:
    environment:
      RUNNER_SCOPE: repo
      RUNNER_TARGET: fixture/one
  runner-two:
    environment:
      RUNNER_SCOPE: repo
      RUNNER_TARGET: other/two
"""

// All commands are recorded data. No process or network transport is created.
private actor SetupShell: OpsShell {
    private(set) var scripts: [String] = []
    private(set) var inputs: [Data] = []
    private(set) var syncs = 0
    var prerequisites: String
    var images: String
    var current: Bool
    var envCurrent: Bool
    var servicesCurrent: Bool
    let services = Data("runner-fixture\n".utf8)
    let containers = "runner-one\tabc123abc123\tgh-runner:1\trunning\tUp 1 hour\n"
        + "runner-two\tdef456def456\tgh-runner:1\trunning\tUp 1 hour\n"
        + "runner-stopped\t999999999999\tgh-runner:1\texited\tExited\n"
    // SHA-256 of the fixture files and of GH_PAT_FIXTURE=fixture_token\n.
    let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let composeHash = SHA256.hash(data: Data(setupCompose.utf8)).map { String(format: "%02x", $0) }.joined()
    let envHash = "b3b532516506eb4c0a48e44461b19471457fced4814bad4810cceac14cbc4ed3"

    init(prerequisites: String = "docker-ok\nrsync-ok", images: String = "", current: Bool = false) {
        self.prerequisites = prerequisites
        self.images = images
        self.current = current
        self.envCurrent = current
        self.servicesCurrent = current
    }

    func run(_ script: String, input: Data?, timeout: Duration) async throws -> ProcessOutput {
        scripts.append(script)
        if let input { inputs.append(input) }
        let text: String
        if script.contains("docker info") { text = prerequisites }
        else if script.contains("docker images") { text = images }
        else if script.contains("docker image inspect") { text = "" }
        else if script.contains("docker run") { text = "" }
        else if script.contains("docker ps -a") { text = containers }
        else if script.contains("sha256sum"), script.contains("| cut ") {
            if script.contains("/infra/gh-runners/.rmj-services'") {
                text = servicesCurrent ? SHA256.hash(data: services).map { String(format: "%02x", $0) }.joined() : "__absent__"
            } else {
                #expect(script.contains("/infra/gh-runners/.env'"))
                text = envCurrent ? envHash : "__absent__"
            }
        } else if script.contains("sha256sum") {
            text = current ? "\(composeHash)  docker-compose.yml\n\(emptyHash)  entrypoint.sh\n" : "__nodir__"
        } else if script.contains("cat >") {
            if script.contains("$d/.rmj-services.XXXXXX") {
                #expect(script.contains("mv \"$t\" \"$d/.rmj-services\""))
                #expect(input == services)
                servicesCurrent = true
            } else {
                #expect(script.contains("$d/.env.XXXXXX"))
                #expect(script.contains("\"$d/.env\""))
                #expect(input == Data("GH_PAT_FIXTURE=fixture_token\n".utf8))
                envCurrent = true
            }
            text = ""
        } else if script.contains("docker compose") || script.hasPrefix("docker build --label rmj.dockerfile=") {
            text = ""
        } else {
            Issue.record("Unexpected fake command: \(script)")
            text = ""
        }
        return ProcessOutput(status: 0, stdout: Data(text.utf8), stderr: "")
    }

    func sync(directory: URL, to remote: String) async throws {
        #expect(remote == "/home/fixture/infra/gh-runners")
        syncs += 1
        current = true
    }
}

private struct SetupFiles {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func write(_ path: String, text: String = "") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func stack() throws -> URL {
        try write("runner-stack/docker-compose.yml", text: setupCompose)
        try write("runner-stack/entrypoint.sh")
        return root.appendingPathComponent("runner-stack")
    }
}

private func setupConfig(roles: [String] = [], targets: [String] = []) throws -> DestinationConfig {
    let json: [String: Any] = ["enabled": true, "peer_id": "configured", "ssh_alias": "fixture",
        "tenant": "fixture", "roles": roles, "home": "/home/fixture", "max_jobs": 2,
        "memory_budget": "4g", "runner_targets": targets]
    return try JSONDecoder().decode(DestinationConfig.self, from: JSONSerialization.data(withJSONObject: json))
}

private func setup(_ shell: SetupShell, roles: [String] = [], stack: URL? = nil, images: URL? = nil,
                   needed: [String] = [], tokens: [String: String] = [:], targets: [String] = [],
                   registrations: (@Sendable () async throws -> [GitHubRunner])? = nil) throws -> DestinationSetup {
    DestinationSetup(shell: shell, name: "fixture-box", config: try setupConfig(roles: roles, targets: targets),
                     stack: stack, images: images, neededImages: needed, tokens: tokens,
                     registrations: registrations, registrationWait: .zero, settle: { _ in })
}

private func setupOnline() -> [GitHubRunner] {
    [GitHubRunner(id: 1, name: "abc123abc123-1790000000", online: true, busy: false, labels: []),
     GitHubRunner(id: 2, name: "def456def456-1790000001", online: true, busy: false, labels: [])]
}

struct DestinationSetupAcceptanceTests {
    @Test func missingPrerequisitesStopBeforeImagesAndDeploy() async throws {
        for (output, name) in [("rsync-ok", "docker"), ("docker-ok", "rsync")] {
            let shell = SetupShell(prerequisites: output)
            let report = await (try setup(shell, roles: ["rx", "runners"], needed: ["rx-rust"])).run()
            #expect(report.steps.count == 1)
            let step = try #require(report.steps.first)
            #expect(step.name == name && step.outcome == .failed)
            #expect(step.hint?.isEmpty == false)
            #expect(!report.isReady && !report.changed)
            #expect(await shell.scripts.count == 1)
            #expect(await shell.inputs.isEmpty)
            #expect(await shell.syncs == 0)
        }
    }

    @Test func presentPrerequisitesAreUnchanged() async throws {
        let report = await (try setup(SetupShell())).run()
        #expect(report.steps.map(\.name) == ["prerequisites"])
        #expect(report.steps.first?.outcome == .unchanged)
        #expect(report.isReady && !report.changed)
    }

    @Test func imagesReuseBuildFailAndIgnoreUnmanagedImages() async throws {
        let files = try SetupFiles(); defer { files.remove() }
        for image in ["node", "python", "go"] {
            try files.write("images/\(image)/Dockerfile", text: "FROM scratch\n")
        }
        let shell = SetupShell(images: "rx-rust\tlatest\t2026-10-01\t1 day ago\n")
        let report = await (try setup(shell, roles: ["rx"], images: files.root.appendingPathComponent("images"),
                                     needed: ["rx-rust", "rx-node", "rx-python", "rx-go", "rx-missing", "ubuntu", "gh-runner"])).run()
        #expect(report.steps.first { $0.name == "rx-rust" }?.outcome == .unchanged)
        #expect(report.steps.first { $0.name == "rx-node" }?.outcome == .changed)
        #expect(report.steps.first { $0.name == "rx-python" }?.outcome == .changed)
        #expect(report.steps.first { $0.name == "rx-go" }?.outcome == .changed)
        #expect(report.steps.first { $0.name == "rx-missing" }?.outcome == .failed)
        #expect(Set(report.steps.map(\.name)) == ["prerequisites", "rx-rust", "rx-node", "rx-python", "rx-go", "rx-missing",
            "tools in rx-rust", "tools in rx-node", "tools in rx-python", "tools in rx-go"])
        let builds = await shell.scripts.filter { $0.hasPrefix("docker build") }
        let hash = SHA256.hash(data: Data("FROM scratch\n".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(builds == ["rx-go", "rx-node", "rx-python"].map {
            "docker build --label rmj.dockerfile=\(hash) -t \($0) -"
        })
        #expect(await shell.inputs == Array(repeating: Data("FROM scratch\n".utf8), count: 3))
        #expect(!report.isReady && report.changed)
    }

    @Test func rolesWithoutRxNeverInspectOrBuildImages() async throws {
        let shell = SetupShell()
        let report = await (try setup(shell, needed: ["rx-missing"])).run()
        #expect(report.steps.map(\.name) == ["prerequisites"])
        #expect(await shell.scripts.count == 1)
    }

    @Test func missingRunnerTokenNamesTargetAndNeverWrites() async throws {
        let files = try SetupFiles(); defer { files.remove() }
        let shell = SetupShell()
        let report = await (try setup(shell, roles: ["runners"], stack: files.stack(),
                                     tokens: ["fixture/one": "fixture_token"], targets: ["fixture/one", "other/two"])).run()
        let step = try #require(report.steps.first { $0.name == "runner stack" })
        #expect(step.outcome == .failed && step.detail.contains("other/two"))
        #expect(await shell.inputs.isEmpty)
        #expect(await shell.syncs == 0)
        #expect(await shell.scripts.count == 1)
        #expect(!report.steps.contains { $0.name == "registration" })
    }

    @Test func runnerStackChangesOnceThenIsIdempotentAndRegistrationSkips() async throws {
        let files = try SetupFiles(); defer { files.remove() }
        let shell = SetupShell()
        let subject = try setup(shell, roles: ["runners"], stack: files.stack(),
                                tokens: ["fixture/repo": "fixture_token"], targets: ["fixture/repo"])
        let first = await subject.run()
        #expect(first.steps.first { $0.name == "runner stack" }?.outcome == .changed)
        #expect(first.isReady && first.changed)
        #expect(first.steps.first { $0.name == "registration" }?.outcome == .skipped)
        let second = await subject.run()
        #expect(second.steps.first { $0.name == "runner stack" }?.outcome == .unchanged)
        #expect(second.isReady && !second.changed)
        #expect(await shell.syncs == 1)
        #expect(await shell.inputs == [Data("GH_PAT_FIXTURE=fixture_token\n".utf8), Data("runner-fixture\n".utf8)])
        #expect(await shell.scripts.filter { $0.contains("docker compose up") }.count == 1)
    }

    @Test func registrationRequiresEveryRunningContainerOnline() async throws {
        let files = try SetupFiles(); defer { files.remove() }
        let stack = try files.stack()
        for complete in [true, false] {
            let shell = SetupShell(current: true)
            let report = await (try setup(shell, roles: ["runners"], stack: stack,
                tokens: ["fixture/repo": "fixture_token"], targets: ["fixture/repo"], registrations: {
                    if complete { return setupOnline() }
                    var runners = setupOnline()
                    runners[1].online = false
                    return runners
                })).run()
            let step = try #require(report.steps.first { $0.name == "registration" })
            if complete {
                #expect(step.outcome == .changed && step.detail == "2 runners online")
                #expect(report.isReady && report.changed)
            } else {
                #expect(step.outcome == .failed && step.detail.contains("def456def456"))
                #expect(!step.detail.contains("999999999999"))
                #expect(!report.isReady && !report.changed)
            }
            #expect(await shell.inputs.isEmpty)
            #expect(await shell.syncs == 0)
        }
    }

    @Test func throwingRegistrationExplainsPATPermission() async throws {
        let files = try SetupFiles(); defer { files.remove() }
        let report = await (try setup(SetupShell(current: true), roles: ["runners"], stack: files.stack(),
            tokens: ["fixture/repo": "fixture_token"], targets: ["fixture/repo"], registrations: {
                throw NSError(domain: "fixture-github", code: 403)
            })).run()
        let step = try #require(report.steps.first { $0.name == "registration" })
        #expect(step.outcome == .failed)
        #expect(step.hint?.contains("PAT") == true && step.hint?.contains("permission") == true)
        #expect(!report.isReady)
    }

    @Test func reportFlagsDependExactlyOnStepOutcomes() {
        let outcomes: [DestinationSetup.Step.Outcome] = [.unchanged, .changed, .failed, .skipped]
        for mask in 0..<16 {
            let selected = outcomes.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let report = DestinationSetup.Report(steps: selected.map {
                DestinationSetup.Step(name: "fixture", outcome: $0, detail: "", hint: nil)
            })
            #expect(report.isReady == !selected.contains(.failed))
            #expect(report.changed == selected.contains(.changed))
        }
    }

    @Test func inventorySortsAndShowsProbeFactsOnlyWhenProbed() throws {
        let fixture = """
        {"BackendState":"Running","Self":{"Online":true},"Peer":{
          "1":{"ID":"configured","HostName":"z-configured","OS":"linux","Online":false},
          "2":{"ID":"mac","HostName":"a-online","OS":"macOS","Online":true},
          "3":{"ID":"linux","HostName":"b-online","OS":"linux","Online":true},
          "4":{"ID":"offline","HostName":"a-offline","OS":"linux","Online":false}
        }}
        """
        let tailnet = TailnetState.parse(Data(fixture.utf8), readAt: DemoShots.now)
        let rules = Rules(destinations: ["fixture-box": try setupConfig()])
        let probe = try #require(DemoShots.snapshot().destinations.first?.probe)
        let inventory = BoxInventory(tailnet: tailnet, rules: rules, probes: ["fixture-box": probe], now: DemoShots.now)
        #expect(inventory.rows.map(\.host) == ["z-configured", "a-online", "b-online", "a-offline"])
        let configured = try #require(inventory.rows.first)
        #expect(configured.destination == "fixture-box")
        #expect(configured.osName == "Ubuntu 24.04 LTS")
        #expect(configured.memory == "31.3 GB RAM, 10.9 GB available")
        #expect(configured.disk == "469 GB disk, 207 GB free")
        #expect(configured.probedText?.isEmpty == false)
        for row in inventory.rows {
            #expect(row.canBeDestination == (row.os == "linux"))
            if row.destination == nil {
                #expect(row.osName == nil && row.memory == nil && row.disk == nil && row.probedText == nil)
            }
        }
        let unprobed = BoxInventory(tailnet: tailnet, rules: rules, probes: [:], now: DemoShots.now)
        #expect(unprobed.rows.allSatisfy { $0.osName == nil && $0.memory == nil && $0.disk == nil && $0.probedText == nil })
    }

    @Test func rulesImagesAreSortedDistinctAndMatchAnyDestinationInTo() throws {
        let json = """
        {"destinations":{},"tenants":{},"rules":[
          {"name":"z","match":{},"to":["other","box"],"image":"rx-z"},
          {"name":"a","match":{},"to":["box"],"image":"rx-a"},
          {"name":"duplicate","match":{},"to":["box"],"image":"rx-z"},
          {"name":"excluded","match":{},"to":["other"],"image":"rx-b"},
          {"name":"no image","match":{},"to":["box"]},
          {"name":"plain","match":{},"to":["box"],"image":"ubuntu"}
        ]}
        """
        let rules = try JSONDecoder().decode(Rules.self, from: Data(json.utf8))
        #expect(rules.images(for: "box") == ["rx-a", "rx-z", "ubuntu"])
        #expect(rules.images(for: "absent").isEmpty)
    }

    @Test func supportFilesHonorsEnvironmentAndFallsThroughMissingOverride() throws {
        let files = try SetupFiles(); defer { files.remove() }
        let stack = try files.stack()
        #expect(SupportFiles.locate("runner-stack", environment: ["RMJ_SUPPORT": files.root.path]) == stack)
        let missing = files.root.appendingPathComponent("missing")
        let fallback = SupportFiles.locate("runner-stack", environment: ["RMJ_SUPPORT": missing.path])
        if let fallback {
            #expect(FileManager.default.fileExists(atPath: fallback.path))
            #expect(fallback != missing.appendingPathComponent("runner-stack"))
        }
    }
}
