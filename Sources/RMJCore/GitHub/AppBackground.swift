import Foundation

/// What the menu bar app does without the CLI: polls GitHub for the watched repos (15 s with queued or running jobs,
/// 120 s otherwise) and reconciles detached rx jobs with their boxes, writing to the same ledger the CLI uses.
public actor AppBackground {
    public private(set) var githubPolledAt: Date?
    public private(set) var boxesPolledAt: Date?
    public private(set) var footerNote: String?

    private let home: RMJHome
    private let environment: [String: String]

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
        while !Task.isCancelled {
            let store = RulesStore(home: home)
            if case .valid(let rules, _) = store.load() {
                if let existing = poller {
                    await existing.update(rules: rules)
                } else {
                    poller = GitHubPoller(api: GHCLI(), ledger: context.ledger, rules: rules, orgToken: GitHubCommand.orgTokens(rules: rules, home: home))
                }
                if let poller {
                    if Date().timeIntervalSince(reposAt) > 60 { repos = (try? await poller.watchedRepos()) ?? repos; reposAt = Date() }
                    for name in repos where due[name, default: .distantPast] <= Date() {
                        guard let result = try? await poller.poll(repo: name) else { due[name] = Date().addingTimeInterval(GitHubPoller.idleInterval); continue }
                        githubPolledAt = Date()
                        due[name] = Date().addingTimeInterval(result.rateLimited ? GitHubPoller.idleInterval : (try? await poller.interval(for: name)) ?? GitHubPoller.idleInterval)
                    }
                    footerNote = await poller.rateLimitedUntil() != nil ? await poller.footer() : nil
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
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
