import Foundation
import CryptoKit
import Testing
import RMJCore

private actor ImageSetupShell: OpsShell {
    private(set) var scripts: [String] = []
    private(set) var inputs: [Data] = []
    let present: [String]
    let label: String
    let missing: [String]

    init(present: [String] = [], label: String = "", missing: [String] = []) {
        self.present = present; self.label = label; self.missing = missing
    }

    func run(_ script: String, input: Data?, timeout: Duration) async throws -> ProcessOutput {
        scripts.append(script)
        if let input { inputs.append(input) }
        let text: String
        if script.contains("docker info") { text = "docker-ok\nrsync-ok" }
        else if script.contains("docker images") {
            text = present.map { "\($0)\tlatest\ttoday\tnow" }.joined(separator: "\n")
        } else if script.contains("docker image inspect") && !script.contains("docker run") {
            #expect(script.contains("rmj.dockerfile"))
            // Replay the stdout of the requested Docker format or its labelled batch wrapper.
            text = script.contains("printf")
                ? present.map { "\($0) \(label)" }.joined(separator: "\n") : label
        } else if script.contains("docker run") {
            let image = (present + ["rx-rust", "rx-private"]).first { script.contains($0) } ?? "rx-rust"
            text = missing.map { "missing:\(image):\($0)" }.joined(separator: "\n")
        } else if script.hasPrefix("docker build") { text = "" }
        else { Issue.record("Unexpected setup command: \(script)"); text = "" }
        return ProcessOutput(status: 0, stdout: Data(text.utf8), stderr: "")
    }

    func sync(directory: URL, to remote: String) async throws { Issue.record("No runner sync expected") }
}

private struct ImageSetupFiles {
    let root: URL
    let bytes = Data("FROM fixture\nRUN echo bash zsh git just cargo\n".utf8)
    var hash: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("rust"), withIntermediateDirectories: true)
        try bytes.write(to: root.appendingPathComponent("rust/Dockerfile"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func imageSetup(_ shell: ImageSetupShell, files: ImageSetupFiles, roles: [String] = ["rx"],
                        images: [String] = ["rx-rust"], requires: [String] = ["jq"]) throws -> DestinationSetup {
    let json: [String: Any] = ["enabled": true, "peer_id": "fixture", "ssh_alias": "fixture",
        "tenant": "fixture", "roles": roles, "home": "/home/fixture", "max_jobs": 2,
        "memory_budget": "4g", "requires": requires]
    let config = try JSONDecoder().decode(DestinationConfig.self, from: JSONSerialization.data(withJSONObject: json))
    return DestinationSetup(shell: shell, name: "fixture", config: config, stack: nil,
        images: files.root, neededImages: images, tokens: [:], registrationWait: .zero, settle: { _ in })
}

struct DestinationImagesAcceptanceTests {
    @Test func matchingFingerprintReusesImageAndChecksCatalogPlusRequiresOnce() async throws {
        let files = try ImageSetupFiles(); defer { files.remove() }
        let shell = ImageSetupShell(present: ["rx-rust"], label: files.hash)
        let report = await (try imageSetup(shell, files: files, requires: ["jq", "zsh"])).run()
        #expect(report.steps.map(\.name) == ["prerequisites", "rx-rust", "tools in rx-rust"])
        #expect(report.steps[1].outcome == .unchanged && report.steps[1].detail == "image present")
        let catalog = BuildEnvironments.tools(for: "rx-rust")
        let required = catalog + (catalog.contains("jq") ? [] : ["jq"])
        #expect(report.steps[2].outcome == .unchanged)
        #expect(report.steps[2].detail == required.joined(separator: ", ") + " present")
        #expect(report.isReady && !report.changed)
        let scripts = await shell.scripts
        #expect(scripts.contains { $0.contains("docker image inspect") && $0.contains("rmj.dockerfile") })
        #expect(!scripts.contains { $0.hasPrefix("docker build") })
        let checks = scripts.filter { $0.contains("docker run") }
        #expect(checks.count == 1)
        let check = try #require(checks.first)
        #expect(check.contains("docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges --entrypoint sh"))
        #expect(check.contains("rx-rust"))
        for program in required { #expect(check.contains(program)) }
        #expect(!scripts[0].contains("command -v") && !scripts[0].contains("jq"))
    }

    @Test func staleAndUnlabelledImagesRebuildWithShippedByteFingerprint() async throws {
        let files = try ImageSetupFiles(); defer { files.remove() }
        for label in ["", String(repeating: "0", count: 64)] {
            let shell = ImageSetupShell(present: ["rx-rust"], label: label)
            let report = await (try imageSetup(shell, files: files)).run()
            let image = try #require(report.steps.first { $0.name == "rx-rust" })
            #expect(image.outcome == .changed && image.detail == "rebuilt: its Dockerfile changed")
            #expect(await shell.scripts.contains("docker build --label rmj.dockerfile=\(files.hash) -t rx-rust -"))
            #expect(await shell.inputs == [files.bytes])
            #expect(report.isReady && report.changed)
        }
    }

    @Test func absentImageBuildsWithFingerprint() async throws {
        let files = try ImageSetupFiles(); defer { files.remove() }
        let shell = ImageSetupShell()
        let report = await (try imageSetup(shell, files: files)).run()
        #expect(report.steps[1].outcome == .changed && report.steps[1].detail == "built")
        #expect(await shell.scripts.contains("docker build --label rmj.dockerfile=\(files.hash) -t rx-rust -"))
        #expect(await shell.inputs == [files.bytes])
        #expect(report.isReady)
    }

    @Test func missingImageToolsFailReadinessWithDockerfileHintInRequiredOrder() async throws {
        let files = try ImageSetupFiles(); defer { files.remove() }
        let shell = ImageSetupShell(present: ["rx-rust"], label: files.hash, missing: ["jq", "zsh"])
        let report = await (try imageSetup(shell, files: files)).run()
        #expect(report.steps.map(\.name) == ["prerequisites", "rx-rust", "tools in rx-rust"])
        let step = try #require(report.steps.last)
        #expect(step.outcome == .failed)
        #expect(step.detail == "missing in rx-rust: zsh, jq")
        #expect(step.hint == "Add them to the Dockerfile of rx-rust (Support/box/images) and run Setup again; RMJ rebuilds an image whose Dockerfile changed")
        #expect(!report.isReady)
    }

    @Test func unshippedDockerfileIsOnlyAnErrorWhenImageAbsent() async throws {
        let files = try ImageSetupFiles(); defer { files.remove() }
        for present in [true, false] {
            let shell = ImageSetupShell(present: present ? ["rx-private"] : [])
            let report = await (try imageSetup(shell, files: files, images: ["rx-private"], requires: [])).run()
            let step = try #require(report.steps.first { $0.name == "rx-private" })
            #expect(step.outcome == (present ? .unchanged : .failed))
            #expect(step.detail == (present ? "image present" : "no Dockerfile for rx-private ships with RMJ"))
            #expect(await shell.inputs.isEmpty)
        }
    }

    @Test func imageStepsPrecedeAllToolStepsAndRunners() async throws {
        let files = try ImageSetupFiles(); defer { files.remove() }
        let shell = ImageSetupShell(present: ["rx-rust", "rx-private"], label: files.hash)
        let report = await (try imageSetup(shell, files: files, roles: ["rx", "runners"], images: ["rx-rust", "rx-private"])).run()
        #expect(report.steps.map(\.name) == ["prerequisites", "rx-private", "rx-rust",
            "tools in rx-private", "tools in rx-rust", "runner stack"])
        #expect(await shell.scripts.filter { $0.contains("docker run") }.count == 2)
    }

    @Test func destinationWithoutRxNeverChecksImagesOrTools() async throws {
        let files = try ImageSetupFiles(); defer { files.remove() }
        let shell = ImageSetupShell()
        let report = await (try imageSetup(shell, files: files, roles: [])).run()
        #expect(report.steps.map(\.name) == ["prerequisites"])
        #expect(report.steps[0].detail == "docker and rsync present")
        #expect(await shell.scripts.count == 1)
        #expect(report.isReady)
    }
}
