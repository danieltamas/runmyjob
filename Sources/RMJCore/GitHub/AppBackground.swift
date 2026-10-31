import Foundation

/// What the menu bar app does without the CLI: polls GitHub for the watched repos (15 s with queued or running jobs,
/// 120 s otherwise) and reconciles detached rx jobs with their boxes, writing to the same ledger the CLI uses.
public actor AppBackground {
    public private(set) var githubPolledAt: Date?
    public private(set) var boxesPolledAt: Date?
    public private(set) var footerNote: String?
    /// The autoscaler's last action, for the footer.
    public private(set) var scalingNote: String?
    private var scalingRunning = false

    private let home: RMJHome
    private let environment: [String: String]
    /// The sinks' drainers, rebuilt when the sink list or a secret changes; nil with every sink off.
    private var streamer: LogStreamer?
    private var streamerSignature = ""

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        home = RMJHome(environment: environment)
    }

    /// Runs until the task is cancelled. A failure in one round is skipped; the next round tries again.
    public func run() async {
        guard let context = try? await RunCommand.open(environment: environment) else { return }
        var poller: GitHubPoller?
        var due = [String: Date]()
        var repos: [String] = []
        var reposAt = Date.distantPast
        var reconciledAt = Date.distantPast
        var archivedAt = Date.distantPast
        var tokens: (@Sendable (String) -> String?)?
        let scaling = RunnerScalingLoop(home: home, environment: environment)
        while !Task.isCancelled {
            refreshStreamer()
            let store = RulesStore(home: home)
            if case .valid(let rules, _) = store.load() {
                if let existing = poller {
                    await existing.update(rules: rules)
                } else {
                    let read = GitHubCommand.orgTokens(rules: rules, home: home)
                    tokens = read
                    poller = GitHubPoller(api: GHCLI(), ledger: context.ledger, rules: rules, orgToken: read)
                }
                if let poller {
                    if Date().timeIntervalSince(reposAt) > 60 { repos = (try? await poller.watchedRepos()) ?? repos; reposAt = Date() }
                    for name in repos where due[name, default: .distantPast] <= Date() {
                        guard let result = try? await poller.poll(repo: name) else { due[name] = Date().addingTimeInterval(GitHubPoller.idleInterval); continue }
                        githubPolledAt = Date()
                        due[name] = Date().addingTimeInterval(result.rateLimited ? GitHubPoller.idleInterval : (try? await poller.interval(for: name)) ?? GitHubPoller.idleInterval)
                    }
                    if Date().timeIntervalSince(archivedAt) >= 60 {
                        archivedAt = Date()
                        await archiveFailedLogs(ledger: context.ledger, archive: context.archive, tokens: tokens ?? { _ in nil })
                    }
                    footerNote = await poller.rateLimitedUntil() != nil ? await poller.footer() : nil
                }
                // Off the loop: a stalled ssh to a box must not hold up polling, reconciling or log draining.
                if !scalingRunning {
                    scalingRunning = true
                    let ledger = context.ledger
                    let environment = environment
                    Task {
                        await scaling.tick(rules: rules, ledger: ledger, tailnet: { await TailnetState.read(environment: environment) })
                        self.scalingNote = await scaling.note
                        self.scalingRunning = false
                    }
                }
                let live = ((try? await context.ledger.jobs()) ?? []).contains { !$0.state.isSettled && $0.github == nil }
                if Date().timeIntervalSince(reconciledAt) >= (live ? 20 : 120) {
                    reconciledAt = Date()
                    let tailnet = await TailnetState.read(environment: environment)
                    let boxes = BoxDirectory(rules: store.load(), tailnet: tailnet, factory: SSHBoxFactory())
                    await Reconciler(ledger: context.ledger, archive: context.archive, boxes: boxes).reconcile()
                    boxesPolledAt = Date()
                }
            }
            await streamer?.drainAll()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// The sinks' drainers follow the config: rebuilt when the list or a secret changed, gone when every sink is off.
    private func refreshStreamer() {
        let sinks = LogSinkStore.load(home: home).sinks
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let signature = "\(LogSinkStore.revision(home: home))|" + String(decoding: (try? encoder.encode(sinks)) ?? Data(), as: UTF8.self)
        guard signature != streamerSignature else { return }
        streamerSignature = signature
        streamer = LogStreamer(home: home, sinks: sinks)
    }

    /// A failed GitHub job's log is archived once, as soon as it is seen; a fetch that failed leaves a pending entry and is not retried here.
    private func archiveFailedLogs(ledger: Ledger, archive: LogArchive, tokens: @escaping @Sendable (String) -> String?) async {
        let failed = ((try? await ledger.jobs()) ?? []).filter { $0.github != nil && $0.state == .failed }.prefix(50)
        var fetched = 0
        for job in failed where fetched < 3 {
            if (try? await archive.entry(jobID: job.id, side: "local")) != nil { continue }
            fetched += 1
            let problem = await GitHubJobLog.archive(ledgerID: job.id, ledger: ledger, archive: archive, secrets: [], token: tokens)
            if problem == nil, let document = LogDocument.load(jobID: job.id, home: home) { streamer?.shipArchived(job, document: document) }
        }
    }
}
