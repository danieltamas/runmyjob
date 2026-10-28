import Foundation

/// Everything the panel shows at one instant. The live model builds one from the ledger and the pollers; DemoShots
/// builds one from synthetic data, so a render and the app draw through the same path.
public struct PanelSnapshot: Sendable {
    public var now: Date { didSet { memo = Memo() } }
    public var tailnet: TailnetState { didSet { memo = Memo() } }
    public var jobs: [JobRecord] { didSet { memo = Memo() } }
    public var destinations: [DestinationCardInput] { didSet { memo = Memo() } }
    public var rulesState: RulesState? { didSet { memo = Memo() } }
    /// When each running job last printed a line, from its log's modification time.
    public var lastOutput: [String: Date] { didSet { memo = Memo() } }
    public var waitingFor: [String: String] { didSet { memo = Memo() } }
    public var githubPolledAt: Date?
    public var boxesPolledAt: Date?
    public var rateRemaining: Int?
    /// A failure has landed that the Jobs tab has not shown yet.
    public var unseenFailure: Bool
    /// Settled jobs of the last 30 days that the Jobs tab no longer shows.
    public var history: [JobRecord] = [] { didSet { memo = Memo() } }

    /// The presentations below, built once per change of what they read: a body that asks for them again, as the
    /// panel does on every redraw, costs nothing.
    private var memo = Memo()

    private final class Memo: @unchecked Sendable {
        let lock = NSLock()
        var rows: [(JobRowPresentation.Section, [JobRowPresentation])]?
        var historyRows: [(JobRowPresentation.Section, [JobRowPresentation])]?
        var cards: [DestinationCardPresentation]?
        var routing: RoutingPresentation?
        var routingBuilt = false

        func routing(_ make: () -> RoutingPresentation?) -> RoutingPresentation? {
            lock.lock(); defer { lock.unlock() }
            if !routingBuilt { routing = make(); routingBuilt = true }
            return routing
        }

        func cached<T>(_ key: ReferenceWritableKeyPath<Memo, T?>, _ make: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            if let hit = self[keyPath: key] { return hit }
            let value = make()
            self[keyPath: key] = value
            return value
        }
    }

    public init(now: Date, tailnet: TailnetState, jobs: [JobRecord] = [], destinations: [DestinationCardInput] = [], rulesState: RulesState? = nil, lastOutput: [String: Date] = [:],
                waitingFor: [String: String] = [:], githubPolledAt: Date? = nil, boxesPolledAt: Date? = nil,
                rateRemaining: Int? = nil, unseenFailure: Bool = false) {
        self.now = now
        self.tailnet = tailnet
        self.jobs = jobs
        self.destinations = destinations
        self.rulesState = rulesState
        self.lastOutput = lastOutput
        self.waitingFor = waitingFor
        self.githubPolledAt = githubPolledAt
        self.boxesPolledAt = boxesPolledAt
        self.rateRemaining = rateRemaining
        self.unseenFailure = unseenFailure
    }

    public var runningCount: Int { jobs.filter { $0.state == .running || $0.state == .syncing }.count }
    /// How long the oldest running job has run.
    public var longestRunning: TimeInterval? {
        jobs.filter { $0.state == .running }.compactMap { $0.startedAt.map { now.timeIntervalSince($0) } }.max()
    }
    public var queuedCount: Int { jobs.filter { $0.state == .queued }.count }
    public var rows: [(JobRowPresentation.Section, [JobRowPresentation])] {
        memo.cached(\.rows) { jobs.panelRows(now: now, lastOutput: lastOutput, waitingFor: waitingFor) }
    }
    public var historyRows: [(JobRowPresentation.Section, [JobRowPresentation])] {
        memo.cached(\.historyRows) { history.panelRows(now: now, lastOutput: [:], waitingFor: [:]) }
    }
    public var cards: [DestinationCardPresentation] { memo.cached(\.cards) { destinations.map { DestinationCardPresentation($0, now: now) } } }
    public var routing: RoutingPresentation? { memo.routing { rulesState.map { RoutingPresentation(state: $0, jobs: jobs) } } }
    public var icon: MenuBarIconState { .resolve(tailnet: tailnet.standing, running: runningCount, unseenFailure: unseenFailure) }
    public var tailnetChip: TailnetChip { TailnetChip(tailnet, now: now) }
    public var footer: PanelFooter {
        PanelFooter(githubPolledAt: githubPolledAt, boxesPolledAt: boxesPolledAt, rateRemaining: rateRemaining, now: now)
    }
}
