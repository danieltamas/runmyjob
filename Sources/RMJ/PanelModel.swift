import RMJCore
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case jobs = "Jobs", destinations = "Destinations", routing = "Routing"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .jobs: "bolt.horizontal"
        case .destinations: "server.rack"
        case .routing: "arrow.triangle.branch"
        }
    }
}

/// What the panel shows and the loop that keeps it current. Views read `snapshot`; nothing else touches the ledger.
@MainActor
final class PanelModel: ObservableObject {
    @Published var snapshot: PanelSnapshot
    @Published var tab: PanelTab = .jobs
    @Published var settingsPane: SettingsPane = .general
    /// Set by the panel's root view: `openSettings` exists only in the environment of a view.
    var showSettingsWindow: (() -> Void)?
    /// Rows the owner opened, by job id: the state lives here so a tab switch does not close them.
    @Published var expanded: Set<String> = []
    /// Job rows open on their own `@State`; this only lets a row remember it was open when the list is rebuilt. Not published:
    /// opening one row must not redraw the others.
    var openJobs: Set<String> = []
    /// The log tail of each opened row, read when it opens.
    @Published var tails: [String: LogTail.Result] = [:]
    /// One line shown in the footer for a few seconds: what an action did or why it did not.
    @Published var notice: String?
    /// Set by the panel view: a failure counts as seen only while the Jobs tab is actually on screen.
    var panelVisible = false
    private var githubPolledAt: Date?
    private var boxesPolledAt: Date?
    private var probing = false
    private var orphansSettledAt: Date?
    private let background = AppBackground()
    private var backgroundLoop: Task<Void, Never>?
    /// A route to explain, set by `Explain route` on a row.
    @Published var explain: (repo: String, command: String)?
    private var loop: Task<Void, Never>?
    private var tailnet = TailnetMonitor()
    /// The last good reading from each box, kept so a card can say how old it is.
    private var probes: [String: DestinationProbeResult] = [:]
    /// The rule open in the Routing tab: an index, -1 for a new one. The floating button and the tab share it.
    @Published var editingRule: Int?
    /// What the last release check found; the header shows an arrow when it is `.available`.
    @Published var updateStatus: UpdateStatus = .unknown
    let alerts = AlertCenter()
    let moreApps = MoreAppsModel()

    /// The repos the rule editor offers: those of every job and history row and of the rules themselves.
    var knownRepos: [String] {
        var rules: Rules?
        if case .valid(let valid, _)? = snapshot.rulesState { rules = valid }
        return RepoChoices.known(jobs: snapshot.jobs + snapshot.history, rules: rules)
    }
    private var runners: [String: [RunnerContainer]] = [:]
    private var registrations: [String: [GitHubRunner]] = [:]
    private var probedAt: Date = .distantPast
    /// Failed and lost rows the Jobs tab has shown: a new one raises the menu bar badge again.
    private var seenFailures: Set<String> = []

    init(snapshot: PanelSnapshot) {
        self.snapshot = snapshot
        alerts.onUpdate = { [weak self] status in
            // A failed check changes nothing: an arrow already shown stays until a check says otherwise.
            if status != .unknown { self?.updateStatus = status }
        }
    }

    /// The live model: polls the ledger once a second while a job runs and every 5 s otherwise.
    static func live() -> PanelModel {
        let model = PanelModel(snapshot: PanelSnapshot(now: Date(), tailnet: TailnetState(standing: .unknown("not read yet"), magicDNSEnabled: false, peers: [], readAt: Date())))
        model.start()
        return model
    }

    func openSettings(_ pane: SettingsPane) {
        settingsPane = pane
        showSettingsWindow?()
        NSApp.activate()
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id); return }
        expanded.insert(id)
    }

    func say(_ text: String) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.notice == text { self?.notice = nil }
        }
    }

    func select(_ tab: PanelTab) {
        self.tab = tab
        if tab == .jobs { markSeen() }
    }

    /// After a rule edit: the Routing tab shows the new file at once instead of at the next poll.
    func reloadRules() {
        Task { [weak self] in
            guard let self, let loader = try? PanelLoader() else { return }
            let state = await tailnet.current(maxAge: 10)
            guard let fresh = try? await loader.snapshot(tailnet: state, probes: probes, runners: runners, registrations: registrations) else { return }
            update(fresh)
        }
    }

    private func start() {
        guard loop == nil, let loader = try? PanelLoader() else { return }
        let monitor = tailnet
        backgroundLoop = Task { [background] in await background.run() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                // `tailscale status` is a child process: read it every 30 s while nothing runs, every 10 s while a job does.
                if Date().timeIntervalSince(self?.orphansSettledAt ?? .distantPast) >= 30 {
                    self?.orphansSettledAt = Date()
                    await loader.settleOrphans()
                }
                let state = await monitor.current(maxAge: (self?.snapshot.runningCount ?? 0) > 0 ? 10 : 30)
                self?.probeBoxesInBackground(loader: loader, tailnet: state)
                if let snapshot = try? await loader.snapshot(tailnet: state, probes: self?.probes ?? [:], runners: self?.runners ?? [:], registrations: self?.registrations ?? [:]) {
                    self?.update(snapshot)
                }
                if let background = self?.background {
                    self?.githubPolledAt = await background.githubPolledAt
                    self?.boxesPolledAt = await background.boxesPolledAt
                }
                let busy = self?.snapshot.runningCount ?? 0 > 0
                // Closed and idle: the menu bar icon is all that shows, so a longer beat costs nothing visible.
                let hiddenIdle = !busy && !(self?.panelVisible ?? true)
                try? await Task.sleep(for: .seconds(busy ? 1 : hiddenIdle ? 15 : 5))
            }
        }
    }

    /// Every 30 s while the Destinations tab is open or a job runs, else every 5 minutes, so disk and memory stay current.
    static let backgroundProbeInterval: TimeInterval = 300

    private func probeBoxesInBackground(loader: PanelLoader, tailnet state: TailnetState) {
        guard !probing else { return }
        probing = true
        Task { [weak self] in
            await self?.readBoxes(loader: loader, tailnet: state)
            self?.probing = false
        }
    }

    private func readBoxes(loader: PanelLoader, tailnet state: TailnetState) async {
        let wanted = tab == .destinations || snapshot.runningCount > 0
        guard Date().timeIntervalSince(probedAt) >= (wanted ? 30 : Self.backgroundProbeInterval), let rules = loader.rules() else { return }
        probedAt = Date()
        for (name, config) in rules.destinations where config.enabled {
            let target = DestinationTarget(alias: config.sshAlias, peerID: config.peerID)
            guard case .online(let address) = DestinationResolver.resolve(target, in: state) else { continue }
            probes[name] = await DestinationProbe().probe(target, tailnet: state)
            if config.roles.contains("runners"), let list = try? await RunnerContainer.list(shell: SSHOpsShell(address: address, alias: config.sshAlias)) {
                runners[name] = list
                // GitHub's own view of whether those containers are registered and online; a failed read leaves the container as is.
                let targets = config.runnerTargets ?? []
                let ask = DestinationSetup.registrations(api: GHCLI(), targets: targets, tokens: DestinationOps.tokens(targets, home: RMJHome()))
                registrations[name] = try? await ask?()
            }
        }
    }

    private func update(_ fresh: PanelSnapshot) {
        var next = fresh
        next.githubPolledAt = githubPolledAt
        next.boxesPolledAt = boxesPolledAt ?? (probedAt == .distantPast ? nil : probedAt)
        let failures = Set(fresh.jobs.filter { $0.state == .failed || $0.state == .lost }.map(\.id))
        if tab == .jobs, panelVisible { seenFailures.formUnion(failures) }
        next.unseenFailure = !failures.isSubset(of: seenFailures)
        snapshot = next
        alerts.handle(fresh)
    }

    private func markSeen() {
        seenFailures.formUnion(snapshot.jobs.filter { $0.state == .failed || $0.state == .lost }.map(\.id))
        snapshot.unseenFailure = false
    }

    deinit {
        loop?.cancel()
        backgroundLoop?.cancel()
    }
}
