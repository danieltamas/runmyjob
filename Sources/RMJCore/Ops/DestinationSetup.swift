import Foundation

/// Where RMJ's own files for a box live: the runner stack and the rx image Dockerfiles. `RMJ_SUPPORT` moves them (a checkout sets it to its `Support/`; the current directory is never searched);
/// the app bundle carries them in Resources.
public enum SupportFiles {
    public static func locate(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                              bundle: Bundle = .main) -> URL? {
        var candidates: [URL] = []
        if let root = environment["RMJ_SUPPORT"] { candidates.append(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(name)) }
        if let resources = bundle.resourceURL { candidates.append(resources.appendingPathComponent(name)) }
        // The CLI sits in the app bundle's Resources next to the support files.
        if let executable = Bundle.main.executableURL { candidates.append(executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(name)) }
        // The installed CLI is a copy outside the bundle; the installed app is where its support files are.
        candidates.append(URL(fileURLWithPath: "/Applications/RMJ.app/Contents/Resources", isDirectory: true).appendingPathComponent(name))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Brings a box from "reachable with docker and rsync" to "ready": the rx images it needs, the runner stack with
/// its `.env` from the Keychain's PATs, and a check that every runner registered. Every step reads the box first and
/// changes only what differs, so running it again on a ready box changes nothing.
public struct DestinationSetup: Sendable {
    public struct Step: Sendable, Equatable {
        public enum Outcome: String, Sendable { case unchanged, changed, failed, skipped }
        public let name: String
        public let outcome: Outcome
        public let detail: String
        public let hint: String?

        public init(name: String, outcome: Outcome, detail: String, hint: String?) {
            self.name = name
            self.outcome = outcome
            self.detail = detail
            self.hint = hint
        }
    }

    public struct Report: Sendable, Equatable {
        public var steps: [Step]
        public init(steps: [Step] = []) { self.steps = steps }
        public var isReady: Bool { !steps.contains { $0.outcome == .failed } }
        public var changed: Bool { steps.contains { $0.outcome == .changed } }
    }

    private let shell: OpsShell
    private let name: String
    private let config: DestinationConfig
    private let stack: URL?
    private let images: URL?
    private let neededImages: [String]
    private let tokens: [String: String]
    private let registrations: (@Sendable () async throws -> [GitHubRunner])?
    private let notice: @Sendable (String) -> Void
    private let settle: @Sendable (Duration) async -> Void
    private let registrationWait: Duration

    /// `neededImages` are the `rx-*` images the rules route to this destination.
    public init(shell: OpsShell, name: String, config: DestinationConfig, stack: URL?, images: URL?, neededImages: [String],
                tokens: [String: String], registrations: (@Sendable () async throws -> [GitHubRunner])? = nil,
                registrationWait: Duration = .seconds(90), settle: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                notice: @escaping @Sendable (String) -> Void = { _ in }) {
        self.shell = shell
        self.name = name
        self.config = config
        self.stack = stack
        self.images = images
        self.neededImages = neededImages
        self.tokens = tokens
        self.registrations = registrations
        self.registrationWait = registrationWait
        self.settle = settle
        self.notice = notice
    }

    /// Every runner GitHub lists for any of the targets; nil when there is no target to ask about.
    public static func registrations(api: GitHubAPI, targets: [String], tokens: [String: String]) -> (@Sendable () async throws -> [GitHubRunner])? {
        guard !targets.isEmpty else { return nil }
        return { @Sendable in
            var all: [GitHubRunner] = []
            for target in targets { all += try await GitHubRunners.list(api: api, target: target, token: tokens[target]) }
            return all
        }
    }

    public func run() async -> Report {
        var report = Report()
        report.steps.append(await prerequisites())
        guard report.isReady else { return report }
        if config.roles.contains("rx") {
            let built = await imageSteps()
            report.steps += built
            if !built.contains(where: { $0.name == "images" && $0.outcome == .failed }) {
                report.steps += await toolSteps(skipping: Set(built.filter { $0.outcome == .failed }.map(\.name)))
            }
        }
        guard report.isReady else { return report }
        if config.roles.contains("runners") {
            let deploy = await deployStep()
            report.steps.append(deploy)
            if deploy.outcome != .failed { report.steps.append(await registrationStep()) }
        }
        return report
    }

    private func prerequisites() async -> Step {
        let required = config.requires ?? []
        if let bad = required.first(where: { !DestinationConfig.isProgramName($0) }) {
            return Step(name: "tools", outcome: .failed, detail: "requires entry \"\(bad)\" is not a program name", hint: "Fix requires in rules.json")
        }
        // Jobs run in containers: the box itself needs docker and rsync, nothing else of a job's toolchain.
        do {
            let output = try await shell.run("docker info >/dev/null 2>&1 && echo docker-ok; rsync --version >/dev/null 2>&1 && echo rsync-ok", input: nil, timeout: .seconds(30))
            let text = String(decoding: output.stdout, as: UTF8.self)
            guard text.contains("docker-ok") else { return Step(name: "docker", outcome: .failed, detail: "docker is not usable for this user", hint: "Install docker and add the ssh user to the docker group") }
            guard text.contains("rsync-ok") else { return Step(name: "rsync", outcome: .failed, detail: "rsync is missing", hint: "Install rsync on the box") }
            return Step(name: "prerequisites", outcome: .unchanged, detail: "docker and rsync present", hint: nil)
        } catch {
            return Step(name: "prerequisites", outcome: .failed, detail: "\(error)", hint: "Check ssh to the box")
        }
    }

    private func imageSteps() async -> [Step] {
        let present: Set<String>
        do { present = Set(try await RunnerImages.list(shell: shell).map(\.repository)) } catch {
            return [Step(name: "images", outcome: .failed, detail: "\(error)", hint: nil)]
        }
        let wanted = neededImages.sorted().filter { $0.hasPrefix("rx-") }
        let dockerfiles = Dictionary(uniqueKeysWithValues: wanted.compactMap { image in
            images.flatMap { try? Data(contentsOf: $0.appendingPathComponent("\(image.dropFirst(3))/Dockerfile")) }.map { (image, $0) }
        })
        let labels: [String: String]
        do { labels = try await RunnerImages.fingerprints(of: wanted.filter { present.contains($0) && dockerfiles[$0] != nil }, shell: shell) } catch {
            return [Step(name: "images", outcome: .failed, detail: "\(error)", hint: nil)]
        }
        var steps: [Step] = []
        for image in wanted {
            let short = String(image.dropFirst(3))
            let outdated = present.contains(image) && dockerfiles[image].map { labels[image] != RunnerImages.fingerprint($0) } == true
            if present.contains(image), !outdated {
                steps.append(Step(name: image, outcome: .unchanged, detail: "image present", hint: nil))
                continue
            }
            guard let data = dockerfiles[image] else {
                steps.append(Step(name: image, outcome: .failed, detail: "no Dockerfile for \(image) ships with RMJ", hint: "Build \(image) on the box by hand"))
                continue
            }
            notice("building \(image) on \(name)...")
            do {
                try await RunnerImages.build(name: short, dockerfile: data, shell: shell)
                steps.append(Step(name: image, outcome: .changed, detail: outdated ? "rebuilt: its Dockerfile changed" : "built", hint: nil))
            } catch {
                steps.append(Step(name: image, outcome: .failed, detail: "\(error)", hint: nil))
            }
        }
        return steps
    }

    /// Runs each image the rules use once and looks for the programs it must hold: the toolchain lives in the image, never on the box.
    private func toolSteps(skipping failed: Set<String>) async -> [Step] {
        var steps: [Step] = []
        for image in neededImages.sorted() where image.hasPrefix("rx-") && BuildEnvironments.isImageName(image) && !failed.contains(image) {
            let programs = BuildEnvironments.required(in: image, requires: config.requires ?? [])
            guard !programs.isEmpty else { continue }
            let name = "tools in \(image)"
            do {
                let output = try await shell.run(BuildEnvironments.checkCommand(image: image, programs: programs), input: nil, timeout: .seconds(120))
                guard output.status == 0 else {
                    steps.append(Step(name: name, outcome: .failed, detail: "the image would not start (exit \(output.status))", hint: "Run docker run --rm --entrypoint sh \(image) on the box to see why"))
                    continue
                }
                let lines = Set(String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").map(String.init))
                let missing = programs.filter { lines.contains("missing:\(image):\($0)") }
                steps.append(missing.isEmpty
                    ? Step(name: name, outcome: .unchanged, detail: "\(programs.joined(separator: ", ")) present", hint: nil)
                    : Step(name: name, outcome: .failed, detail: "missing in \(image): \(missing.joined(separator: ", "))",
                           hint: "Add them to the Dockerfile of \(image) (Support/box/images) and run Setup again; RMJ rebuilds an image whose Dockerfile changed"))
            } catch {
                steps.append(Step(name: name, outcome: .failed, detail: "\(error)", hint: "Check ssh to the box"))
            }
        }
        return steps
    }

    private func deployStep() async -> Step {
        guard let stack else { return Step(name: "runner stack", outcome: .failed, detail: "RMJ's runner stack files were not found", hint: "Reinstall RMJ") }
        let targets = config.runnerTargets ?? []
        guard !targets.isEmpty else { return Step(name: "runner stack", outcome: .failed, detail: "the destination has the runners role but no runner targets", hint: "Add runner_targets to the destination in rules.json") }
        if let missing = targets.first(where: { tokens[$0] == nil }) {
            return Step(name: "runner stack", outcome: .failed, detail: "no PAT for \(missing)", hint: "Store it in the Keychain: security add-generic-password -s ro.danieltamas.rmj -a rmj.pat.\(missing) -w")
        }
        let deployer = RunnerStackDeployer(shell: shell, stack: stack, home: config.home, tokens: tokens, requiredTargets: targets, host: name,
                                           registrations: registrations, notice: notice)
        do {
            let report = try await deployer.deploy()
            return report.performed.isEmpty
                ? Step(name: "runner stack", outcome: .unchanged, detail: "stack and .env are current", hint: nil)
                : Step(name: "runner stack", outcome: .changed, detail: report.performed.joined(separator: ", "), hint: nil)
        } catch let failure as RunnerStackDeployer.Failure {
            return Step(name: "runner stack", outcome: .failed, detail: failure.description, hint: nil)
        } catch {
            return Step(name: "runner stack", outcome: .failed, detail: "\(error)", hint: nil)
        }
    }

    /// Every runner container must show up online at GitHub; a PAT without the runner permission fails here, not later.
    private func registrationStep() async -> Step {
        guard let registrations else { return Step(name: "registration", outcome: .skipped, detail: "GitHub was not asked", hint: nil) }
        let expected = (try? await RunnerContainer.list(shell: shell))?.filter(\.isRunning) ?? []
        guard !expected.isEmpty else { return Step(name: "registration", outcome: .failed, detail: "no runner container is running", hint: "Look at docker compose logs on the box") }
        var waited = Duration.zero
        var missing = expected.map(\.id)
        while true {
            do {
                let online = try await registrations().filter(\.online).map(\.name)
                missing = expected.filter { container in !online.contains { container.isRegistered(as: $0) } }.map(\.id)
            } catch {
                return Step(name: "registration", outcome: .failed, detail: "\(error)", hint: "The PAT needs the self-hosted runners permission")
            }
            if missing.isEmpty { return Step(name: "registration", outcome: .changed, detail: "\(expected.count) runner\(expected.count == 1 ? "" : "s") online", hint: nil) }
            if waited >= registrationWait { break }
            await settle(.seconds(5))
            waited += .seconds(5)
        }
        return Step(name: "registration", outcome: .failed, detail: "not registered after \(registrationWait): \(missing.joined(separator: ", "))", hint: "Check the PAT's permission and docker compose logs")
    }
}
