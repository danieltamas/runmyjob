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

    public func cards(rules: Rules, tailnet: TailnetState, jobs: [JobRecord], probes: [String: DestinationProbeResult], histories: [String: [DestinationProbeResult]] = [:],
                      runners: [String: [RunnerContainer]], registrations: [String: [GitHubRunner]] = [:], profiles: ProfileStore? = nil,
                      now: Date) -> [DestinationCardInput] {
        rules.destinations.keys.sorted().compactMap { name in
            guard let config = rules.destinations[name], config.enabled else { return nil }
            let availability = DestinationResolver.resolve(DestinationTarget(alias: config.sshAlias, peerID: config.peerID), in: tailnet)
            let live = jobs.filter { $0.destination == name && $0.github == nil && ($0.state == .running || $0.state == .syncing) }
            let images = Self.relevantImages(probes[name]?.images.value ?? [], routed: rules.images(for: name) + Self.profileImages(rules, destination: name, profiles: profiles))
            return DestinationCardInput(name: name, config: config, availability: availability, probe: probes[name],
                                        runners: (runners[name] ?? []).map { Self.runner($0, registered: registrations[name]) }, rxJobs: live,
                                        images: images.shown, otherImages: images.other, history: histories[name] ?? [])
        }
    }

    /// The images the profiles of rules routed to `destination` run (a rule with a profile has no `image` of its own).
    static func profileImages(_ rules: Rules, destination: String, profiles: ProfileStore?) -> [String] {
        guard let profiles else { return [] }
        return rules.rules.filter { $0.to.contains(destination) }.compactMap(\.profile).compactMap(profiles.image)
    }

    /// What a box card lists of `docker image ls`: the shipped `rx-*` images, the images rules send here and the runner
    /// stack's. A rule image with a tag matches that tag only; without one, any tag of the repository.
    static func relevantImages(_ all: [String], routed: [String]) -> (shown: [String], other: Int) {
        func split(_ image: String) -> (repository: String, tag: String?) {
            guard let colon = image.lastIndex(of: ":"), !image[colon...].contains("/") else { return (image, nil) }
            return (String(image[..<colon]), String(image[image.index(after: colon)...]))
        }
        let rules = routed.map(split)
        let shown = all.filter { image in
            let (repository, tag) = split(image)
            if repository.hasPrefix("rx-") || repository == "gh-runner" || repository.hasPrefix("gh-runner-")
                || repository == "ghcr.io/actions/actions-runner" { return true }
            return rules.contains { $0.repository == repository && ($0.tag == nil || $0.tag == tag) }
        }
        return (shown, all.count - shown.count)
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
