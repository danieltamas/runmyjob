import Foundation

/// Where probes come from: the freshest known one for a destination, and a live one on demand.
public protocol ProbeProvider: Sendable {
    func latest(for destination: String) async -> DestinationProbeResult?
    func probe(_ target: DestinationTarget, tailnet: TailnetState) async -> DestinationProbeResult
}

public struct RouteRequest: Sendable {
    public var command: [String]
    public var identity: RepoIdentity
    /// `RX_LOCAL=1`.
    public var forceLocal: Bool
    /// `--to <destination>`: skips the rules, never the tenant deny.
    public var destination: String?

    public init(command: [String], identity: RepoIdentity, forceLocal: Bool = false, destination: String? = nil) {
        self.command = command
        self.identity = identity
        self.forceLocal = forceLocal
        self.destination = destination
    }
}

public struct RouteDecision: Sendable, Equatable, Codable {
    public enum Location: Sendable, Equatable, Codable {
        case destination(name: String, address: String)
        case local
    }

    public var location: Location
    /// Why the job runs here and not where the rules wanted it; nil when it went where the chain's first link said.
    public var fallbackReason: String?
    public var rule: String?
    public var tenant: String
    public var advisory: String?
    /// The inputs and every step, one line each: what `rmj route` prints.
    public var explanation: [String]

    /// Every free-text field cleaned of escapes and invisible characters, for printing or handing to an agent.
    public func sanitized() -> RouteDecision {
        var copy = self
        copy.fallbackReason = fallbackReason.map { UntrustedText.clean($0, limit: 400) }
        copy.tenant = UntrustedText.clean(tenant, limit: 64)
        copy.rule = rule.map { UntrustedText.clean($0, limit: 400) }
        copy.advisory = advisory.map { UntrustedText.clean($0, limit: 400) }
        copy.explanation = explanation.map { UntrustedText.clean($0, limit: 400) }
        if case .destination(let name, let address) = location {
            copy.location = .destination(name: UntrustedText.clean(name), address: UntrustedText.clean(address))
        }
        return copy
    }

    public var locationName: String {
        if case .destination(let name, _) = location { name } else { "local" }
    }
}

public struct Router: Sendable {
    public static let probeMaxAge: TimeInterval = 60

    private let rules: RulesState
    private let tailnet: TailnetState
    private let probes: ProbeProvider
    private let fileExists: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date

    public init(rules: RulesState, tailnet: TailnetState, probes: ProbeProvider,
                fileExists: @escaping @Sendable (String) -> Bool, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rules = rules
        self.tailnet = tailnet
        self.probes = probes
        self.fileExists = fileExists
        self.now = now
    }

    public func route(_ request: RouteRequest) async -> RouteDecision {
        var log = ["repo: \(request.identity.slug ?? "unknown") worktree \(request.identity.worktree)\(request.identity.dirty ? " (dirty)" : "")"]
        let words = CommandWords(argv: request.command)
        log.append("command: \(words.display)")
        log.append("tailnet: \(Self.describe(tailnet, at: now()))")
        func local(_ reason: String, tenant: String = "unclassified", rule: String? = nil, advisory: String? = nil) -> RouteDecision {
            log.append("result: local (\(reason))")
            return RouteDecision(location: .local, fallbackReason: reason, rule: rule, tenant: tenant, advisory: advisory, explanation: log)
        }
        if request.forceLocal { return local("forced") }
        guard case .valid(let config, _) = rules else { return local(rules.invalidReason ?? "rules invalid") }
        let resolution = Tenancy.resolve(request.identity, in: config.tenants)
        log.append("tenant: \(resolution.tenant) (\(resolution.how))")
        if resolution.tenant == Tenancy.unclassified { return local("unclassified repo") }
        let tenant = resolution.tenant

        let chain: [String]
        var matched: Rule?
        if let forced = request.destination {
            chain = [forced]
            log.append("--to \(forced): rules skipped, the tenant deny still applies")
        } else {
            matched = config.rules.first { rule in
                let (hit, why) = matches(rule, request: request, words: words, tenant: tenant)
                let checked = rule.match.has.map { ", checked \($0): \(fileExists("\(request.identity.worktree)/\($0)") ? "present" : "absent")" } ?? ""
                log.append("rule \"\(rule.name)\": \(hit ? "matches" : "no (\(why))")\(checked)")
                return hit
            }
            guard let matched else { return local("no rule", tenant: tenant) }
            // `local` ends the chain wherever it is written; what follows it is never tried.
            chain = Array(matched.to.prefix(while: { $0 != "local" }))
            if chain.isEmpty { return localByRule(matched, tenant: tenant, log: &log) }
        }

        var skipped = [String]()
        for name in chain {
            switch await attempt(name, config: config, tenant: tenant, rule: matched, log: &log) {
            case .success(let address):
                log.append("result: \(name) at \(address)")
                return RouteDecision(location: .destination(name: name, address: address), fallbackReason: nil,
                                     rule: matched?.name, tenant: tenant, advisory: matched?.advisory, explanation: log)
            case .failure(let skip):
                skipped.append(skip.reason)
                log.append("skipped \(name): \(skip.reason)")
            }
        }
        return local(skipped.first ?? "no destination", tenant: tenant, rule: matched?.name, advisory: matched?.advisory)
    }

    private func localByRule(_ rule: Rule, tenant: String, log: inout [String]) -> RouteDecision {
        log.append("result: local (rule \"\(rule.name)\")")
        return RouteDecision(location: .local, fallbackReason: nil, rule: rule.name, tenant: tenant, advisory: rule.advisory, explanation: log)
    }

    private func matches(_ rule: Rule, request: RouteRequest, words: CommandWords, tenant: String) -> (Bool, String) {
        let match = rule.match
        let slug = request.identity.slug ?? ""
        if let tenants = match.tenant, !tenants.contains(tenant) { return (false, "tenant \(tenant)") }
        if let owners = match.owner, !owners.contains(where: { Glob.matches($0.lowercased(), request.identity.owner ?? "") }) { return (false, "owner") }
        if let repos = match.repo, !repos.contains(where: { Glob.matches($0.lowercased(), slug) }) { return (false, "repo") }
        if let paths = match.path, !paths.contains(where: { Glob.matches($0, request.identity.worktree) }) { return (false, "path") }
        if let commands = match.command, !commands.contains(where: words.matches) { return (false, "command \(words.display)") }
        if let file = match.has {
            let present = fileExists("\(request.identity.worktree)/\(file)")
            if !present { return (false, "no \(file) in the checkout") }
        }
        return (true, "")
    }

    private func attempt(_ name: String, config: Rules, tenant: String, rule: Rule?, log: inout [String]) async -> Result<String, Skip> {
        guard let destination = config.destinations[name] else { return .failure(Skip("unknown destination \(name)")) }
        if Tenancy.denies(repoTenant: tenant, destinationTenant: destination.tenant, tenants: config.tenants) {
            return .failure(Skip("denied: tenant \(tenant) on \(destination.tenant) destination"))
        }
        guard destination.enabled else { return .failure(Skip("\(name) is disabled")) }
        let target = DestinationTarget(alias: destination.sshAlias, peerID: destination.peerID)
        let availability = DestinationResolver.resolve(target, in: tailnet)
        guard case .online = availability else { return .failure(Skip(Self.reason(name, availability, tailnet))) }
        var probe = await probes.latest(for: name)
        // A probe dated in the future is as untrustworthy as an old one.
        // ...and only for the address the peer resolves to now.
        if let known = probe, known.availability == availability, (-5...Self.probeMaxAge).contains(now().timeIntervalSince(known.probedAt)) {
            log.append("probe of \(name): \(Int(now().timeIntervalSince(known.probedAt))) s old")
        } else {
            log.append("probe of \(name): \(probe == nil ? "none" : "older than \(Int(Self.probeMaxAge)) s"), probing once")
            probe = await probes.probe(target, tailnet: tailnet)
        }
        guard let result = probe else { return .failure(Skip("\(name) unreachable (no probe)")) }
        guard case .online(let address) = result.availability else { return .failure(Skip(Self.reason(name, result.availability, tailnet))) }
        guard result.dockerReady else { return .failure(Skip("\(name) docker not ready")) }
        guard result.rsyncReady else { return .failure(Skip("\(name) rsync not ready")) }
        if let reason = capacity(name, destination, result, rule: rule) { return .failure(Skip(reason)) }
        if let image = rule?.image {
            guard let images = result.images.value else { return .failure(Skip("\(name) images unknown")) }
            if !images.contains(where: { $0 == image || $0 == "\(image):latest" }) { return .failure(Skip("\(name) lacks image \(image)")) }
        }
        return .success(address)
    }

    private func capacity(_ name: String, _ destination: DestinationConfig, _ probe: DestinationProbeResult, rule: Rule?) -> String? {
        guard let containers = probe.containers.value else { return "\(name) capacity unknown (containers unreadable)" }
        let rx = containers.filter { !$0.name.hasPrefix("runner-") }.count
        if rx >= destination.maxJobs { return "\(name) at max_jobs (\(rx)/\(destination.maxJobs))" }
        guard let budget = MemorySize.parse(destination.memoryBudget) else { return "\(name) memory budget unreadable" }
        guard let wanted = (rule?.memory ?? destination.rxDefaults?.memory).flatMap(MemorySize.parse)?.bytes else {
            return "\(name) memory for the job unknown"
        }
        // rx containers count at their limit (the right-hand side of docker stats' usage column); runner
        // containers at what they use now, since their caps alone (32 g on ai-eu-1) exceed the budget.
        var committed = Int64(0)
        for container in containers {
            let parts = container.memory.split(separator: "/", omittingEmptySubsequences: false)
            let sides = parts.map { MemorySize.parse(String($0).trimmingCharacters(in: .whitespaces)) }
            let counted = parts.count == 2 ? (container.name.hasPrefix("runner-") ? sides.first : sides.last) : nil
            guard let size = counted ?? nil else { return "\(name) capacity unknown (memory of \(UntrustedText.clean(container.name)))" }
            committed += size.bytes
        }
        if committed + wanted > budget.bytes { return "\(name) over memory budget" }
        return nil
    }

    struct Skip: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    static func reason(_ name: String, _ availability: Availability, _ tailnet: TailnetState) -> String {
        switch availability {
        case .online: "\(name) online"
        case .offline(let why): why.hasPrefix("tailnet down") ? "tailnet down" : "\(name) offline (\(why))"
        case .unreachable(let why): "\(name) unreachable (\(why))"
        case .rejected(let why): "\(name) rejected (\(why))"
        }
    }

    static func describe(_ state: TailnetState, at now: Date) -> String {
        let standing: String = switch state.standing {
        case .running: "running"
        case .stopped: "stopped"
        case .needsLogin: "needs login"
        case .noClient: "no client"
        case .unknown(let why): "unknown (\(why))"
        }
        return "\(standing), read \(max(0, Int(now.timeIntervalSince(state.readAt)))) s ago"
    }
}
