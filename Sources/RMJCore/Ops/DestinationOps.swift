import Foundation

/// What the panel's Destinations cards read and do for one destination: the same operations as `rmj destination`.
public struct DestinationOps: Sendable {
    public struct Candidate: Sendable, Equatable {
        public let target: String
        public let runner: String
    }

    public let name: String
    public let config: DestinationConfig
    public let home: RMJHome

    public init(name: String, config: DestinationConfig, home: RMJHome) {
        self.name = name
        self.config = config
        self.home = home
    }

    /// PATs of the targets, from the Keychain (never prompting) or the one-time handoff.
    public static func tokens(_ targets: [String], home: RMJHome) -> [String: String] {
        var found = [String: String]()
        for target in targets {
            let account = "rmj.pat.\(target)"
            let handoff = account.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            if let token = (try? Keychain().read(account: account)) ?? (try? PatHandoff(home: home).take(account: handoff)) { found[target] = token }
        }
        return found
    }

    /// The registrations a prune would delete: nothing is changed. Reads GitHub, not the box.
    public func pruneCandidates(api: GitHubWriteAPI = GHCLI()) async throws -> [Candidate] {
        let pruner = RegistrationPruner(api: api)
        var found: [Candidate] = []
        for target in config.runnerTargets ?? [] {
            let token = Self.tokens([target], home: home)[target]
            found += try await pruner.candidates(target: target, destinationLabel: name, token: token).map { Candidate(target: target, runner: $0.name) }
        }
        return found
    }

    /// Rebuilds the runner images from the stack already on the box; running runners keep their image until recreated.
    public func rebuildImages(shell: OpsShell) async throws {
        let directory = SSH.quote("\(config.home)/infra/gh-runners")
        let output = try await shell.run("cd \(directory) && out=$(docker compose build 2>&1); rc=$?; printf '%s\n' \"$out\" | tail -n 5; exit $rc", input: nil, timeout: .seconds(1800))
        guard output.status == 0 else { throw RunnerStackDeployer.Failure.remote(UntrustedText.clean(String(decoding: output.stdout, as: UTF8.self), limit: 300)) }
    }

    public func prune(api: GitHubWriteAPI = GHCLI()) async throws -> RegistrationPruner.Result {
        let pruner = RegistrationPruner(api: api)
        var total = RegistrationPruner.Result()
        for target in config.runnerTargets ?? [] {
            let token = Self.tokens([target], home: home)[target]
            let result = try await pruner.prune(target: target, destinationLabel: name, token: token)
            total.deleted += result.deleted
            total.skipped += result.skipped
        }
        return total
    }
}

/// Builds the live cards: availability from the tailnet at once, the box's own readings from a probe when one is
/// allowed. A reading is kept from the last good probe and marked stale as it ages.
public struct DestinationLoader: Sendable {
    public init() {}

    public func cards(rules: Rules, tailnet: TailnetState, jobs: [JobRecord], probes: [String: DestinationProbeResult],
                      runners: [String: [RunnerContainer]], registrations: [String: [GitHubRunner]] = [:], now: Date) -> [DestinationCardInput] {
        rules.destinations.keys.sorted().compactMap { name in
            guard let config = rules.destinations[name], config.enabled else { return nil }
            let availability = DestinationResolver.resolve(DestinationTarget(alias: config.sshAlias, peerID: config.peerID), in: tailnet)
            let live = jobs.filter { $0.destination == name && $0.github == nil && ($0.state == .running || $0.state == .syncing) }
            return DestinationCardInput(name: name, config: config, availability: availability, probe: probes[name],
                                        runners: (runners[name] ?? []).map { Self.runner($0, registered: registrations[name]) }, rxJobs: live,
                                        images: probes[name]?.images.value ?? [])
        }
    }

    /// A container is registered when GitHub lists an online runner named `<container id>-<epoch>`. Without a registration
    /// reading (no PAT, GitHub unreachable) the container is taken as it is, not marked failed on a guess.
    static func runner(_ container: RunnerContainer, registered: [GitHubRunner]?) -> DestinationCardInput.Runner {
        guard let registered, container.isRunning else { return .init(container: container) }
        guard let match = registered.first(where: { $0.online && container.isRegistered(as: $0.name) }) else {
            return .init(container: container, readiness: "not registered")
        }
        return .init(container: container, busy: match.busy)
    }
}
