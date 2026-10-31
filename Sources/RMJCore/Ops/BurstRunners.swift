import Foundation

public struct BurstContainer: Sendable, Equatable {
    public var name: String
    public var id: String
    public var target: String
    public var ageSeconds: Double
    public var running: Bool
}

/// Burst runners on one destination: one-shot containers of the runner image, registered with the same labels as the
/// target's static runner. The PAT reaches `docker run` only as ssh stdin, exported for that process alone, like a deploy.
public struct BurstRunners: Sendable {
    private let shell: OpsShell
    private let directory: String
    private let host: String
    private let version: String
    private let labels: [String: [String]]
    /// target (lowercased) -> the service name of its static runner, which gives the derived label.
    private let services: [String: String]

    public init(shell: OpsShell, home: String, host: String, version: String, labels: [String: [String]] = [:], services: [String: String] = [:]) {
        self.services = services
        self.shell = shell
        self.directory = "\(home)/infra/gh-runners"
        self.host = String(host.map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) ? $0 : "-" })
        self.version = version
        self.labels = Dictionary(labels.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// Container names this type creates and may remove.
    static func isBurstName(_ name: String) -> Bool {
        guard name.hasPrefix("burst-"), name.count > 13, let suffix = name.split(separator: "-").last, suffix.count == 6 else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") } && suffix.allSatisfy(\.isHexDigit)
    }

    public func list() async throws -> [BurstContainer] {
        let script = #"""
        tab=$(printf '\t'); ids=$(docker ps -aq --filter label=rmj.burst) || exit 1; echo "now=$(date +%s)"; for c in $ids; do \
        row=$(docker inspect -f "{{.Name}}${tab}{{.Id}}${tab}{{index .Config.Labels \"rmj.burst\"}}${tab}{{.State.StartedAt}}${tab}{{.State.Status}}" "$c") || exit 1; \
        echo "$row" | while IFS="$tab" read -r n i t s st; do printf '%s\t%s\t%s\t%s\t%s\n' "${n#/}" "$i" "$t" "$(date -d "$s" +%s 2>/dev/null || echo 0)" "$st"; done; done
        """#
        let output = try await shell.run(script, input: nil, timeout: .seconds(30))
        guard output.status == 0 else { throw RunnerStackDeployer.Failure.remote("docker ps exited \(output.status)") }
        var now: Double?
        var found = [(String, String, String, Double, String)]()
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("now=") { now = Double(line.dropFirst(4)); continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, Self.isBurstName(fields[0]), let started = Double(fields[3]) else { continue }
            found.append((fields[0], fields[1], fields[2], started, fields[4]))
        }
        guard let now else { return [] }
        return found.map { BurstContainer(name: $0.0, id: $0.1, target: GitHubText.clean($0.2), ageSeconds: max(0, now - $0.3), running: $0.4 == "running") }
    }

    /// Starts one burst runner for `target`; returns its container name.
    public func start(target: String, token: String) async throws -> String {
        guard RunnerTarget.path(target) != nil else { throw RunnerStackDeployer.Failure.badToken(target) }
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) else {
            throw RunnerStackDeployer.Failure.badToken(target)
        }
        let org = target.hasPrefix("org:")
        let slug = Self.slug(target)
        let name = "burst-\(slug)-" + String(format: "%06x", Int.random(in: 0..<0x1_000_000))
        let service = services[target.lowercased()] ?? RunnerCompose.serviceName(target, taken: [])
        let runnerLabels = RunnerCompose.runnerLabels(service: service, extras: labels[target.lowercased()] ?? [])
        let options = [
            "--name", name, "--label", "rmj.burst=\(target)", "--network", "\(directory.split(separator: "/").last ?? "gh-runners")_ci",
            "--cpus", "4", "--memory", "8g", "--pids-limit", "2048", "--security-opt", "no-new-privileges:true",
            "-e", "RUNNER_SCOPE=\(org ? "org" : "repo")", "-e", "RUNNER_TARGET=\(org ? String(target.dropFirst(4)) : target)",
            "-e", "RUNNER_LABELS_BASE=self-hosted,linux,x64,\(host)", "-e", "RUNNER_LABELS=\(runnerLabels)", "-e", "GH_PAT",
        ].map(SSH.quote).joined(separator: " ")
        let script = "cd \(SSH.quote(directory)) && while IFS='=' read -r name value; do export \"$name=$value\"; done && docker run -d --rm \(options) gh-runner:\(SSH.quote(version)) 2>&1"
        let output = try await shell.run(script, input: Data("GH_PAT=\(token)\n".utf8), timeout: .seconds(120))
        guard output.status == 0 else { throw RunnerStackDeployer.Failure.remote(Self.firstLine(output, hiding: token)) }
        return name
    }

    /// The lowercase target with every run of other characters as one `-`, so two owners' same-named repos get distinct names.
    private static func slug(_ target: String) -> String {
        var result = ""
        for character in target.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber { result.append(character) } else if result.last != "-" { result.append("-") }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public func stop(container: String) async throws {
        guard Self.isBurstName(container) else { throw RunnerStackDeployer.Failure.remote("not a burst runner: \(GitHubText.clean(container))") }
        let output = try await shell.run("docker rm -f \(SSH.quote(container))", input: nil, timeout: .seconds(60))
        guard output.status == 0 else { throw RunnerStackDeployer.Failure.remote(Self.firstLine(output, hiding: "")) }
    }

    private static func firstLine(_ output: ProcessOutput, hiding secret: String) -> String {
        var text = (String(decoding: output.stdout, as: UTF8.self) + output.stderr).split(separator: "\n").first.map(String.init) ?? "docker exited \(output.status)"
        if !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "***") }
        return UntrustedText.clean(text, limit: 200)
    }
}
