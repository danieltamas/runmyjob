import Foundation

/// Gathers what the planner needs (queued jobs from the ledger, runners from GitHub, load from the boxes), runs one scaling
/// round and keeps a one-line note for the footer. Idle cost: nothing is contacted while no job is queued and no burst runs.
public actor RunnerScalingLoop {
    public private(set) var note: String?

    private let home: RMJHome
    private let environment: [String: String]
    private let api: GitHubAPI
    private var lastTick = Date.distantPast
    private var lastCleanup = Date.distantPast
    /// True until a round saw no burst runner anywhere: the first round after launch looks at the boxes once.
    private var mayHaveBursts = true
    private var probes: [String: (at: Date, result: DestinationProbeResult)] = [:]

    public init(home: RMJHome, environment: [String: String] = ProcessInfo.processInfo.environment, api: GitHubAPI = GHCLI()) {
        self.home = home
        self.environment = environment
        self.api = api
    }

    public func tick(rules: Rules, ledger: Ledger, tailnet readTailnet: @Sendable () async -> TailnetState, now: Date = Date()) async {
        guard now.timeIntervalSince(lastTick) >= 15 else { return }
        lastTick = now
        let jobs = await queuedJobs(ledger: ledger, now: now)
        guard !jobs.isEmpty || mayHaveBursts else { return }
        // Cleanup-only rounds (no queued job) can wait: a box that stays unreachable must not cost a GitHub call every 15 s.
        if jobs.isEmpty {
            guard now.timeIntervalSince(lastCleanup) >= 60 else { return }
            lastCleanup = now
        }
        let serving = rules.destinations.filter { $0.value.enabled && $0.value.roles.contains("runners") && !($0.value.runnerTargets ?? []).isEmpty }
        guard let composeText = Self.composeText(environment: environment) else { return }
        let version = RunnerCompose.imageVersion(composeText)
        guard version != "latest" else { return }
        let services = serving.mapValues { Self.services($0, composeText: composeText) }
        let targets = Set(serving.values.flatMap { $0.runnerTargets ?? [] })
        let tokens = DestinationOps.tokens(Array(targets), home: home)
        let demandJobs = Self.assign(jobs, serving: serving, services: services, rules: rules)
        var runners = [String: [GitHubRunner]]()
        for target in targets where !(demandJobs[target] ?? []).isEmpty || mayHaveBursts {
            if let list = try? await GitHubRunners.list(api: api, target: target, token: tokens[target]) { runners[target] = list }
        }
        // A target whose runners could not be listed gets no start: an unknown idle count must not start extra containers.
        let demand = demandJobs.compactMap { target, waits -> ScaleDemand? in
            guard let list = runners[target] else { return nil }
            return ScaleDemand(target: target, waitingSeconds: waits, idleRunners: list.filter { $0.online && !$0.busy }.count)
        }.sorted { $0.target < $1.target }
        let tailnet = await readTailnet()
        var boxes = [ScalingBox]()
        var unread = false
        for (name, destination) in serving.sorted(by: { $0.key < $1.key }) {
            guard case .online(let address) = DestinationResolver.resolve(DestinationTarget(alias: destination.sshAlias, peerID: destination.peerID), in: tailnet) else { unread = true; continue }
            let burstRunners = BurstRunners(shell: SSHOpsShell(address: address, alias: destination.sshAlias), home: destination.home, host: name,
                                            version: version, labels: destination.runnerLabels ?? [:], services: services[name] ?? [:])
            guard let listed = try? await burstRunners.list() else { unread = true; continue }
            let bursts = listed.filter(\.running).map { container in
                let registered = (runners[container.target] ?? []).first { $0.name.hasPrefix(String(container.id.prefix(12)) + "-") }
                // Registrations that could not be listed say nothing about the runner: a burst may be running a job, so it stays.
                return ScaleBurst(name: container.name, target: container.target, ageSeconds: container.ageSeconds,
                                  busy: runners[container.target] == nil ? true : registered?.busy)
            }
            guard var state = await state(name: name, destination: destination, bursts: bursts, tailnet: tailnet, now: now) else { unread = true; continue }
            // The probe counts rx, job and static runner containers; burst runners hold their memory too.
            state.memoryCommittedBytes += Int64(bursts.count) * RunnerScaler().runnerMemoryBytes
            state.targets = state.targets.filter { !Self.tenantDenied(target: $0, destination: destination, rules: rules) }
            boxes.append(ScalingBox(state: state, runners: burstRunners))
        }
        // One box that could not be read may still hold bursts: the cleanup rounds go on until every box has been seen empty.
        mayHaveBursts = unread || boxes.contains { !$0.state.bursts.isEmpty }
        let outcomes = await RunnerScaling().round(boxes: boxes, demand: demand, tokens: { tokens[$0] }, log: { self.append($0) })
        for failed in outcomes where !failed.succeeded { append("failed: \(failed.detail)") }
        if outcomes.contains(where: { $0.succeeded }) { mayHaveBursts = true }
        if let last = outcomes.last { note = last.succeeded ? "scaling: \(Self.describe(last.action))" : "scaling failed: \(last.detail)" } else if !mayHaveBursts { note = nil }
    }

    private func state(name: String, destination: DestinationConfig, bursts: [ScaleBurst], tailnet: TailnetState, now: Date) async -> ScaleBox? {
        let target = DestinationTarget(alias: destination.sshAlias, peerID: destination.peerID)
        let probe: DestinationProbeResult
        if let cached = probes[name], now.timeIntervalSince(cached.at) < 30 {
            probe = cached.result
        } else {
            probe = await DestinationProbe().probe(target, tailnet: tailnet, now: now)
            probes[name] = (now, probe)
        }
        guard probe.availability.isAvailable, let cores = probe.cores, let load = probe.load,
              let budget = MemorySize.parse(destination.memoryBudget), let containers = probe.containers.value else { return nil }
        return ScaleBox(name: name, targets: destination.runnerTargets ?? [], cpus: cores, load1: load, memoryBudgetBytes: budget.bytes,
                        memoryCommittedBytes: DestinationCardPresentation.committed(containers), online: true, bursts: bursts)
    }

    private struct Queued { var repo: String; var labels: [String]; var waited: Double }

    private func queuedJobs(ledger: Ledger, now: Date) async -> [Queued] {
        ((try? await ledger.jobs()) ?? []).compactMap { job in
            guard job.state == .queued, let info = GitHubJobInfo.decode(job.github) else { return nil }
            return Queued(repo: info.repo, labels: info.observation?.labels ?? [], waited: now.timeIntervalSince(job.queuedAt))
        }
    }

    /// target -> how long each queued job it can serve has waited. A repo target wins over its owner's org target; a job whose
    /// labels no runner of the target carries, or whose company the destination denies, is not counted (a burst could not take it).
    private static func assign(_ jobs: [Queued], serving: [String: DestinationConfig], services: [String: [String: String]], rules: Rules) -> [String: [Double]] {
        var result = [String: [Double]]()
        let all = Set(serving.values.flatMap { $0.runnerTargets ?? [] })
        for job in jobs {
            let owner = job.repo.split(separator: "/").first.map { String($0).lowercased() } ?? ""
            let repoTargets = all.filter { $0.lowercased() == job.repo.lowercased() }.sorted()
            let orgTargets = all.filter { $0.lowercased() == "org:\(owner)" }.sorted()
            let tenant = Tenancy.resolve(RepoIdentity(slug: job.repo, worktree: ""), in: rules.tenants).tenant
            for target in repoTargets + orgTargets where carries(target, labels: job.labels, serving: serving, services: services, jobTenant: tenant, rules: rules) {
                result[target, default: []].append(job.waited)
                break
            }
        }
        return result
    }

    private static func carries(_ target: String, labels: [String], serving: [String: DestinationConfig], services: [String: [String: String]],
                                jobTenant: String, rules: Rules) -> Bool {
        var carried: Set<String> = ["self-hosted", "linux", "x64"]
        var served = false
        let key = target.lowercased()
        for (name, destination) in serving where (destination.runnerTargets ?? []).contains(where: { $0.lowercased() == key }) {
            if Tenancy.denies(repoTenant: jobTenant, destinationTenant: destination.tenant, tenants: rules.tenants) { continue }
            served = true
            let service = services[name]?[key] ?? RunnerCompose.serviceName(target, taken: [])
            let extras = destination.runnerLabels?.first { $0.key.lowercased() == key }?.value ?? []
            carried.formUnion(RunnerCompose.runnerLabels(service: service, extras: extras).split(separator: ",").map { $0.lowercased() })
        }
        return served && Set(labels.map { $0.lowercased() }).isSubset(of: carried)
    }

    private static func composeText(environment: [String: String]) -> String? {
        guard let stack = SupportFiles.locate("runner-stack", environment: environment) else { return nil }
        return try? String(contentsOf: stack.appendingPathComponent("docker-compose.yml"), encoding: .utf8)
    }

    /// target (lowercased) -> the service the destination's static runner has for it, which names its label; the same
    /// derivation the deploy uses, so a burst runner carries the label the workflow was written for.
    private static func services(_ destination: DestinationConfig, composeText: String) -> [String: String] {
        let targets = (destination.runnerTargets ?? []).filter { RunnerTarget.path($0) != nil }
        let compose = RunnerCompose(base: composeText, targets: targets, host: "", labels: [:])
        return Dictionary(zip(targets.map { $0.lowercased() }, compose.services), uniquingKeysWith: { first, _ in first })
    }

    /// A repo or org target whose owner belongs to a company other than the destination's is never served from it.
    static func tenantDenied(target: String, destination: DestinationConfig, rules: Rules) -> Bool {
        let slug = target.hasPrefix("org:") ? String(target.dropFirst(4)) + "/-" : target
        let resolution = Tenancy.resolve(RepoIdentity(slug: slug, worktree: ""), in: rules.tenants)
        // Two tenants claiming one owner is a configuration the deny cannot be trusted with: fail closed.
        if resolution.how.hasPrefix("ambiguous") { return true }
        let tenant = resolution.tenant
        return Tenancy.denies(repoTenant: tenant, destinationTenant: destination.tenant, tenants: rules.tenants)
    }

    private static func describe(_ action: ScaleAction) -> String {
        switch action {
        case .start(let box, let target): "started a runner for \(target) on \(box)"
        case .stop(let box, _): "stopped an idle runner on \(box)"
        }
    }

    /// One line per action in `scaler.log`, mode 0600, cut to its last 200 KB when it grows past 400 KB.
    nonisolated private func append(_ line: String) {
        let url = home.url.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("scaler.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = Data("\(stamp) \(UntrustedText.clean(line, limit: 300))\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let existing = try? Data(contentsOf: url), existing.count > 400_000 { try? existing.suffix(200_000).write(to: url) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: entry)
    }
}
