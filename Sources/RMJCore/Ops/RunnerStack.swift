import CryptoKit
import Foundation

public struct RunnerContainer: Sendable, Equatable {
    public let name: String
    /// The short container id; a runner registers as `<id>-<epoch>`.
    public let id: String
    public let image: String
    public let state: String
    public let status: String

    /// `gh-runner:2.338.2` -> `2.338.2`.
    public var version: String? { image.split(separator: ":").dropFirst().first.map(String.init) }
    public var isRunning: Bool { state == "running" }

    /// A runner registers as `<container id>-<epoch>`: the id, a dash, digits and nothing else.
    public func isRegistered(as registration: String) -> Bool {
        guard registration.hasPrefix(id + "-") else { return false }
        let suffix = registration.dropFirst(id.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isASCII) && suffix.allSatisfy(\.isNumber)
    }

    public static func list(shell: OpsShell) async throws -> [RunnerContainer] {
        let output = try await shell.run("docker ps -a --filter name=runner- --format '{{.Names}}\t{{.ID}}\t{{.Image}}\t{{.State}}\t{{.Status}}'", input: nil, timeout: .seconds(30))
        guard output.status == 0 else { throw RunnerStackDeployer.Failure.remote("docker ps exited \(output.status)") }
        return parse(String(decoding: output.stdout, as: UTF8.self)).sorted { $0.name < $1.name }
    }

    static func parse(_ output: String) -> [RunnerContainer] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { return nil }
            return RunnerContainer(name: GitHubText.clean(fields[0]), id: GitHubText.clean(fields[1]), image: GitHubText.clean(fields[2]),
                                   state: GitHubText.clean(fields[3]), status: GitHubText.clean(fields[4]))
        }
    }
}

public struct DeployReport: Sendable, Equatable {
    /// Files of the vendored stack that differ on the destination (or are missing there).
    public var changedFiles: [String]
    public var envChanged: Bool
    /// The generated compose file for targets the bundled stack has no service for differs on the destination.
    public var composeChanged = false
    public var runners: [RunnerContainer]
    public var performed: [String] = []
    /// Nothing to do: a deploy changes nothing.
    public var isNoOp: Bool { changedFiles.isEmpty && !envChanged && !composeChanged }
}

/// Deploys `Support/runner-stack` to `<home>/infra/gh-runners` and keeps its `.env` in step with the Keychain PATs.
public struct RunnerStackDeployer: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badToken(String), conflictingTokens(String), missingToken(String), remote(String), badStack(String), busy([String])
        public var description: String {
            switch self {
            case .badToken(let target): "the PAT for \(target) is not a plain token"
            case .conflictingTokens(let name): "two targets share \(name) with different PATs"
            case .missingToken(let name): "no PAT for \(name)"
            case .remote(let message): message
            case .badStack(let why): "the vendored runner stack is unusable: \(why)"
            case .busy(let names): "runners are busy: \(names.joined(separator: ", ")); drain them first"
            }
        }
    }

    static let manifestName = ".rmj-services"
    private let shell: OpsShell
    private let stack: URL
    private let directory: String
    private let tokens: [String: String]
    private let notice: @Sendable (String) -> Void
    private let requiredTargets: [String]
    private let host: String
    private let registrations: (@Sendable () async throws -> [GitHubRunner])?

    /// `tokens` maps a runner target (`owner/name`, `org:Name`) to its PAT. `requiredTargets` are the destination's
    /// runner targets: a deploy rewrites `.env` whole, so it refuses unless every one has a PAT. With `registrations`,
    /// a deploy that would change anything refuses while a runner of the stack is busy.
    public init(shell: OpsShell, stack: URL, home: String, tokens: [String: String], requiredTargets: [String] = [], host: String = "fleet",
                registrations: (@Sendable () async throws -> [GitHubRunner])? = nil, notice: @escaping @Sendable (String) -> Void = { _ in }) {
        self.requiredTargets = requiredTargets
        self.host = host
        self.registrations = registrations
        self.shell = shell
        self.stack = stack
        self.directory = "\(home)/infra/gh-runners"
        self.tokens = tokens
        self.notice = notice
    }

    /// The deploy as it stands: read-only.
    public func report() async throws -> DeployReport {
        let changed = try await changedFiles()
        // Without PATs there is nothing to compare: the remote .env is left alone, not reported as changed.
        var envChanged = false
        if !tokens.isEmpty { envChanged = try await remoteHash("\(directory)/.env") != Self.hash(Data(try envContent().utf8)) }
        var composeChanged = false
        let desired = compose()
        if !requiredTargets.isEmpty {
            composeChanged = try await remoteHash("\(directory)/\(Self.manifestName)") != Self.hash(Data(desired.manifest.utf8))
        }
        if let generated = desired.generated, !composeChanged {
            composeChanged = try await remoteHash("\(directory)/\(RunnerCompose.fileName)") != Self.hash(Data(generated.utf8))
        }
        return DeployReport(changedFiles: changed, envChanged: envChanged, composeChanged: composeChanged, runners: try await runners())
    }

    /// The services of the destination's runner targets: the bundled ones plus the generated ones.
    private func compose() -> RunnerCompose {
        let base = (try? String(contentsOf: stack.appendingPathComponent("docker-compose.yml"), encoding: .utf8)) ?? ""
        return RunnerCompose(base: base, targets: requiredTargets, host: host)
    }

    public func deploy() async throws -> DeployReport {
        var report = try await report()
        guard !report.isNoOp else { return report }
        if let missing = requiredTargets.first(where: { tokens[$0] == nil }) { throw Failure.missingToken(missing) }
        if let registrations {
            let busy = try await registrations().filter(\.busy)
            let held = report.runners.filter { container in container.isRunning && busy.contains { container.isRegistered(as: $0.name) } }.map(\.name)
            if !held.isEmpty { throw Failure.busy(held) }
        }
        if !report.changedFiles.isEmpty {
            try await shell.sync(directory: stack, to: directory)
            report.performed.append("synced \(report.changedFiles.count) files")
        }
        if report.envChanged {
            try await writeFile(".env", Data(try envContent().utf8))
            report.performed.append("wrote .env")
        }
        let compose = compose()
        // The sync deletes what the stack directory does not hold, so the generated file is written again after one.
        if let generated = compose.generated, report.composeChanged || !report.changedFiles.isEmpty {
            try await writeFile(RunnerCompose.fileName, Data(generated.utf8))
            report.performed.append("wrote \(RunnerCompose.fileName)")
        }
        if !requiredTargets.isEmpty { try await writeFile(Self.manifestName, Data(compose.manifest.utf8)) }
        // Only the services of this destination's targets start; the bundled file may hold others.
        let services = compose.services.isEmpty ? "" : " " + compose.services.map(SSH.quote).joined(separator: " ")
        let files = compose.generated == nil ? "" : "COMPOSE_FILE=docker-compose.yml:\(RunnerCompose.fileName) "
        for step in ["docker compose build", "docker compose up -d"] {
            let flags = step.hasSuffix("up -d") ? " --remove-orphans" : ""
            let command = "cd \(SSH.quote(directory)) && \(files)\(step)\(flags)\(services) 2>&1"
            try check(try await shell.run(command, input: nil, timeout: .seconds(1800)), step)
            report.performed.append(step)
        }
        if !compose.unused.isEmpty {
            let stale = compose.unused.map(SSH.quote).joined(separator: " ")
            try check(try await shell.run("cd \(SSH.quote(directory)) && \(files)docker compose rm -sf \(stale) 2>&1", input: nil, timeout: .seconds(300)), "docker compose rm")
            report.performed.append("docker compose rm")
        }
        report.runners = try await runners()
        return report
    }

    private func writeFile(_ name: String, _ content: Data) async throws {
        let script = "umask 077; d=\(SSH.quote(directory)); mkdir -p \"$d\" && t=$(mktemp \"$d/\(name).XXXXXX\") && cat > \"$t\" && chmod 600 \"$t\" && mv \"$t\" \"$d/\(name)\""
        try check(try await shell.run(script, input: content, timeout: .seconds(30)), "writing \(name)")
    }

    public func runners() async throws -> [RunnerContainer] { try await RunnerContainer.list(shell: shell) }

    // MARK: Pieces

    /// `NAME=value` lines, one per PAT variable, sorted; a value that is not a plain token is refused (no newline injection).
    func envContent() throws -> String {
        var values = [String: String]()
        for (target, token) in tokens.sorted(by: { $0.key < $1.key }) {
            guard let name = RunnerTarget.environmentName(target) else { throw Failure.badToken(target) }
            guard !token.isEmpty, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) else { throw Failure.badToken(target) }
            if let existing = values[name], existing != token { throw Failure.conflictingTokens(name) }
            values[name] = token
        }
        return values.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)\n" }.joined()
    }

    private func changedFiles() async throws -> [String] {
        let local = try localHashes()
        let names = local.keys.sorted().map(SSH.quote).joined(separator: " ")
        // A missing directory or file is a difference; any other failure is an error, never a reason to deploy.
        let output = try await shell.run("if [ -d \(SSH.quote(directory)) ]; then cd \(SSH.quote(directory)) && sha256sum \(names) 2>&1; else echo __nodir__; fi",
                                         input: nil, timeout: .seconds(30))
        // 0, or 1 for missing files (checked below); anything else is a failed command, not a difference.
        guard output.status == 0 || output.status == 1 else { throw Failure.remote("checksum read exited \(output.status)") }
        var remote = [String: String]()
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
            if line == "__nodir__" || line.hasSuffix("No such file or directory") { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, !line.hasPrefix("sha256sum:") else { throw Failure.remote("unexpected checksum output") }
            remote[parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " *"))] = parts[0]
        }
        return local.keys.sorted().filter { remote[$0] != local[$0] }
    }

    private func localHashes() throws -> [String: String] {
        var hashes = [String: String]()
        let base = stack.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: stack, includingPropertiesForKeys: [.isRegularFileKey]) else { return hashes }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, url.lastPathComponent != ".env" else { continue }
            hashes[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = Self.hash(try Data(contentsOf: url))
        }
        // Without the compose file and the entrypoint this is not the stack: an empty manifest must not read as "nothing to do".
        for required in ["docker-compose.yml", "entrypoint.sh"] where hashes[required] == nil { throw Failure.badStack("\(required) is missing") }
        return hashes
    }

    /// nil only when the file is confirmed absent; an unreadable file is an error.
    private func remoteHash(_ path: String) async throws -> String? {
        let quoted = SSH.quote(path)
        let output = try await shell.run("if [ -e \(quoted) ]; then h=$(sha256sum \(quoted) | cut -d' ' -f1); [ -n \"$h\" ] || exit 7; echo \"$h\"; else echo __absent__; fi", input: nil, timeout: .seconds(30))
        let text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0 else { throw Failure.remote("cannot read the checksum of \(path)") }
        return text.isEmpty || text == "__absent__" ? nil : text
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A failing step reports its output with every PAT value removed: streamed output never carries a credential.
    private func check(_ output: ProcessOutput, _ step: String) throws {
        let text = SecretRedactor.scrub(String(decoding: output.stdout, as: UTF8.self) + output.stderr, secrets: Array(tokens.values))
        // Escape sequences go, newlines stay.
        var sanitizer = LogSanitizer()
        if !text.isEmpty { notice(String(decoding: sanitizer.clean(Data(text.utf8)), as: UTF8.self)) }
        guard output.status == 0 else { throw Failure.remote("\(step) exited \(output.status)") }
    }
}
