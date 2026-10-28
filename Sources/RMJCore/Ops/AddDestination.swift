import Foundation

public struct DestinationDraft: Sendable, Equatable {
    public var name: String
    public var peerID: String
    public var sshAlias: String
    public var tenant: String
    public var roles: [String]
    public var home: String
    public var maxJobs: Int
    public var memoryBudget: String
    /// GitHub owners or repos the runners serve; with them the destination is written whole in one save.
    public var runnerTargets: [String] = []

    public init(name: String, peerID: String, sshAlias: String, tenant: String, roles: [String], home: String, maxJobs: Int, memoryBudget: String) {
        self.name = name
        self.peerID = peerID
        self.sshAlias = sshAlias
        self.tenant = tenant
        self.roles = roles
        self.home = home
        self.maxJobs = maxJobs
        self.memoryBudget = memoryBudget
    }
}

public struct OnboardingStep: Sendable, Equatable {
    public let name: String
    public let ok: Bool
    public let detail: String
    /// What to do about it when it failed.
    public let hint: String?
}

public struct OnboardingReport: Sendable, Equatable {
    public var steps: [OnboardingStep]
    /// True when every check passed and the destination is in the rules file.
    public var written: Bool
    public var failedStep: OnboardingStep? { steps.first { !$0.ok } }
}

/// Settings > Destinations > Add: each check reports with a fix hint; the rules file is written only when all pass.
/// Nothing is installed on the destination.
public struct DestinationOnboarding: Sendable {
    private let probes: ProbeProvider
    private let store: RulesStore

    public init(probes: ProbeProvider, store: RulesStore) {
        self.probes = probes
        self.store = store
    }

    /// An rx role needs a memory default: the budget split over `max_jobs`, at most 12g, at least 1g.
    private static func defaults(_ draft: DestinationDraft) -> DestinationConfig.Defaults {
        let budget = Int(draft.memoryBudget.dropLast()) ?? 8
        return DestinationConfig.Defaults(cpus: nil, memory: "\(min(12, max(1, budget / max(1, draft.maxJobs))))g")
    }

    public func run(_ draft: DestinationDraft, tailnet: TailnetState) async -> OnboardingReport {
        var report = OnboardingReport(steps: [], written: false)
        func add(_ name: String, _ ok: Bool, _ detail: String, hint: String? = nil) -> Bool {
            report.steps.append(OnboardingStep(name: name, ok: ok, detail: detail, hint: ok ? nil : hint))
            return ok
        }
        guard case .valid(var rules, let fingerprint) = store.load() else {
            _ = add("rules", false, "the rules file is invalid", hint: "Fix ~/.rmj/rules.json first")
            return report
        }
        guard !draft.name.isEmpty, rules.destinations[draft.name] == nil else {
            _ = add("name", false, "\"\(draft.name)\" is empty or already a destination", hint: "Pick another name")
            return report
        }
        let target = DestinationTarget(alias: draft.sshAlias, peerID: draft.peerID)
        let availability = DestinationResolver.resolve(target, in: tailnet)
        switch availability {
        case .online: _ = add("reachability", true, "peer is online on the tailnet")
        case .offline(let why):
            _ = add("reachability", false, "peer offline: \(why)", hint: "Start the machine or Tailscale on it, then retry")
            return report
        case .unreachable(let why):
            _ = add("reachability", false, "peer unreachable: \(why)", hint: "Check the tailnet and the peer's address")
            return report
        case .rejected(let why):
            _ = add("reachability", false, "peer rejected: \(why)", hint: "Pick a peer that is on this tailnet")
            return report
        }
        let probe = await probes.probe(target, tailnet: tailnet)
        var sshDetail = "ssh answered"
        if case .unreachable(let why) = probe.availability { sshDetail = why }
        guard add("ssh", probe.availability.isAvailable, sshDetail,
                  hint: "Make sure `ssh \(draft.sshAlias)` works from this Mac without a prompt") else { return report }
        guard add("docker", probe.docker.value != nil, probe.docker.value.map { "docker \($0)" } ?? "docker is missing",
                  hint: "Install docker on the destination; RMJ installs nothing") else { return report }
        guard add("rsync", probe.rsync.value != nil, probe.rsync.value.map { "rsync \($0)" } ?? "rsync is missing",
                  hint: "Install rsync on the destination; RMJ installs nothing") else { return report }
        rules.destinations[draft.name] = DestinationConfig(
            enabled: true, peerID: draft.peerID, sshAlias: draft.sshAlias, tenant: draft.tenant, roles: draft.roles,
            home: draft.home, maxJobs: draft.maxJobs, memoryBudget: draft.memoryBudget, rxDefaults: draft.roles.contains("rx") ? Self.defaults(draft) : nil, runnerStack: draft.roles.contains("runners") ? "\(draft.home)/infra/gh-runners" : nil,
            runnerTargets: draft.roles.contains("runners") ? draft.runnerTargets : nil)
        do {
            try store.save(rules, expected: fingerprint)
            report.written = add("rules", true, "destination added to the rules file")
        } catch {
            _ = add("rules", false, "\(error)", hint: "Check the destination fields and retry")
        }
        return report
    }
}
