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
    @Published var tab: PanelTab = .jobs { didSet { wantFrames() } }
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
    @Published var panelVisible = false {
        didSet { pace.set("panel", onScreen: panelVisible); wantFrames(); if panelVisible { startReading() } }
    }
    /// The panel just opened on readings older than the next frame: the cards show placeholders until a box reports or a few seconds pass.
    @Published var reading = false
    private var readingSince: Date?
    private var readingTimeout: Task<Void, Never>?

    private func startReading() {
        // The readings, not the snapshot, are what ages: a box reports every 10 s while the panel is closed.
        guard probes.values.contains(where: { $0.availability.isAvailable && Date().timeIntervalSince($0.probedAt) > 3 }) else { return }
        readingSince = Date()
        reading = true
        readingTimeout?.cancel()
        readingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.reading = false
            self?.readingSince = nil
        }
    }
    private func wantFrames() { bell.setFramesWanted(panelVisible && tab == .destinations) }
    /// Set by the Destinations settings pane while it shows box readings.
    var destinationsPaneShowing = false {
        didSet { pace.set("settings", onScreen: destinationsPaneShowing) }
    }
    private var githubPolledAt: Date?
    private var boxesPolledAt: Date?
    private var probing = false
    private var orphansSettledAt: Date?
    private let background = AppBackground()
    private var backgroundLoop: Task<Void, Never>?
    /// A route to explain, set by `Explain route` on a row.
    @Published var explain: (repo: String, command: String)?
    private var loop: Task<Void, Never>?
    private let tailnet: TailnetMonitor
    /// One ssh session per box, read by the loop; stopped with the model.
    private let streams: BoxStreams
    private let pace: LivePace
    private let bell: FrameBell
    /// The targets the streams were last set to, to tell a destination that changed from one that stayed.
    private var streamed: [String: DestinationTarget] = [:]
    private var wakeObserver: NSObjectProtocol?
    /// The last good reading from each box, kept so a card can say how old it is.
    private var probes: [String: DestinationProbeResult] = [:]
    /// The last probes per box, for the sensor rates and sparklines.
    private var histories: [String: [DestinationProbeResult]] = [:]
    /// The rule open in the Routing tab: an index, -1 for a new one. The floating button and the tab share it.
    @Published var editingRule: Int?
    /// The header glyph for log streaming, and what its tooltip says; both come from the sinks' status file.
    @Published var streamIndicator: LogStreamIndicator = .off
    @Published var streamHelp = ""
    /// What the last release check found; the header shows an arrow when it is `.available`.
    @Published var updateStatus: UpdateStatus = .unknown
    @Published var updateState: UpdateState = .idle
    /// The footer's "Star on GitHub": shown only while GitHub said the repository is not starred yet.
    @Published var starOffer = false
    @Published var starring = false
    private let repoStar = RepoStar(home: RMJHome())

    func refreshStarOffer() {
        guard repoStar.shouldOffer() else { return }
        Task { [repoStar] in
            let standing = await repoStar.refresh()
            starOffer = standing == .notStarred
        }
    }

    func starRepo() {
        guard !starring else { return }
        starring = true
        Task { [repoStar] in
            let starred = await repoStar.star()
            starring = false
            if starred { starOffer = false; say("Starred. Thank you.") } else { say("Could not star it: is gh logged in?") }
        }
    }

    /// Installs the release the About pane offers, in place, like the curl installer does.
    func installUpdate() {
        guard case .available(let release) = updateStatus, updateState == .idle || isFailed(updateState) else { return }
        updateState = .updating(release.version)
        do {
            try UpdateInstaller.start(version: release.version) { [weak self] reason in
                Task { @MainActor in self?.updateState = .failed(reason) }
            }
        } catch { updateState = .failed((error as? UpdateError)?.reason ?? "\(error)") }
    }

    private func isFailed(_ state: UpdateState) -> Bool { if case .failed = state { true } else { false } }
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
        let monitor = TailnetMonitor()
        tailnet = monitor
        let bell = FrameBell()
        self.bell = bell
        let boxes = BoxStreams(tailnet: { await monitor.current(maxAge: 15) }, onFrame: { _, _ in bell.ringForFrame() })
        streams = boxes
        pace = LivePace(streams: boxes, bell: bell)
        let alerts = alerts
        Task { [background] in await background.setAnnouncer { title, body in Task { @MainActor in alerts.announce(title: title, body: body) } } }
        alerts.onUpdate = { [weak self] status in
            // A failed check changes nothing: an arrow already shown stays until a check says otherwise.
            if status != .unknown { self?.updateStatus = status }
        }
    }

    /// The live model: polls the ledger once a second while a job runs and every 5 s otherwise.
    static func live() -> PanelModel {
        let model = PanelModel(snapshot: PanelSnapshot(now: Date(), tailnet: TailnetState(standing: .unknown("not read yet"), magicDNSEnabled: false, peers: [], readAt: Date())))
        model.start()
        model.refreshStarOffer()
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
            guard let fresh = try? await loader.snapshot(tailnet: state, probes: probes, histories: histories, runners: runners, registrations: registrations) else { return }
            update(fresh, force: true)
        }
    }

    private func start() {
        guard loop == nil, let loader = try? PanelLoader() else { return }
        let monitor = tailnet
        // Frames queued in a session from before the sleep would pass for current: every session starts again on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let streams = self?.streams else { return }
            Task { await streams.stopAll() }
        }
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
                if let snapshot = try? await loader.snapshot(tailnet: state, probes: self?.probes ?? [:], histories: self?.histories ?? [:], runners: self?.runners ?? [:], registrations: self?.registrations ?? [:]) {
                    self?.update(snapshot)
                }
                if let background = self?.background {
                    self?.githubPolledAt = await background.githubPolledAt
                    self?.boxesPolledAt = await background.boxesPolledAt
                }
                self?.refreshStream()
                let busy = self?.snapshot.runningCount ?? 0 > 0
                // Closed and idle: the menu bar icon is all that shows, so a longer beat costs nothing visible.
                let hiddenIdle = !busy && !(self?.panelVisible ?? true)
                await self?.pace.wait(busy ? 1 : hiddenIdle ? 15 : 5)
            }
        }
    }

    private func refreshStream() {
        let home = RMJHome()
        let sinks = LogSinkStore.load(home: home).sinks.filter(\.enabled)
        let status = LogSinkStatusStore(home: home).read()
        let state = LogStreamIndicator.state(sinks: sinks, status: status, now: Date())
        let help = sinks.isEmpty ? "" : "Streaming logs to " + sinks.map { sink in
            let waiting = status.first { $0.id == sink.id }?.waitingLines ?? 0
            return waiting > 0 ? "\(sink.name) (\(waiting) waiting)" : sink.name
        }.joined(separator: ", ")
        if state != streamIndicator { streamIndicator = state }
        if help != streamHelp { streamHelp = help }
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

    /// What Settings reads: the tailnet from the shared monitor (a read at most 10 s old) and the box streams' newest readings.
    func boxReadings() async -> (TailnetState, [String: DestinationProbeResult]) {
        (await tailnet.current(maxAge: 10), probes)
    }

    /// The sparklines get one sample per this long, whatever the stream's frame rate.
    private static let historyStep: TimeInterval = 30

    private func readBoxes(loader: PanelLoader, tailnet state: TailnetState) async {
        guard let rules = loader.rules() else { return }
        var targets = [String: DestinationTarget]()
        for (name, config) in rules.destinations where config.enabled {
            targets[name] = DestinationTarget(alias: config.sshAlias, peerID: config.peerID, requires: config.requires ?? [], images: rules.images(for: name))
        }
        // Each box streams its own readings; reading them here costs nothing and runs on every beat.
        await streams.ensure(destinations: targets)
        // A destination that was removed or points at another box starts from nothing: readings are never carried across.
        for (name, target) in streamed where targets[name] != target {
            probes[name] = nil
            histories[name] = nil
            runners[name] = nil
            registrations[name] = nil
        }
        streamed = targets
        let latest = await streams.latest()
        probes = probes.filter { latest[$0.key] != nil }
        for (name, result) in latest {
            probes[name] = result
            // A box that is not answering has no new counters to compare.
            if result.availability.isAvailable, (histories[name]?.last).map({ result.probedAt.timeIntervalSince($0.probedAt) >= Self.historyStep }) ?? true {
                histories[name] = Array(((histories[name] ?? []) + [result]).suffix(SensorChips.historyLimit))
            }
        }
        let wanted = tab == .destinations || snapshot.runningCount > 0
        guard Date().timeIntervalSince(probedAt) >= (wanted ? 30 : Self.backgroundProbeInterval) else { return }
        probedAt = Date()
        for (name, config) in rules.destinations where config.enabled {
            guard let target = targets[name], case .online(let address) = DestinationResolver.resolve(target, in: state) else { continue }
            if config.roles.contains("runners"), let list = try? await RunnerContainer.list(shell: SSHOpsShell(address: address, alias: config.sshAlias)) {
                runners[name] = list
                // GitHub's own view of whether those containers are registered and online; a failed read leaves the container as is.
                let targets = config.runnerTargets ?? []
                let ask = DestinationSetup.registrations(api: GHCLI(), targets: targets, tokens: DestinationOps.tokens(targets, home: RMJHome()))
                registrations[name] = try? await ask?()
            }
        }
    }

    /// What the menu bar shows and the jobs' states: while the panel is closed, the snapshot is published only when this changes.
    private var publishedSignature = ""
    private var publishedAt = Date.distantPast

    private func update(_ fresh: PanelSnapshot, force: Bool = false) {
        // Closed, a running job would otherwise relayout the hidden panel every second for nothing.
        let signature = "\(fresh.icon)|\(fresh.longestRunning.map(PanelFormat.duration) ?? "")|" + fresh.jobs.map { "\($0.id)\($0.state)" }.joined(separator: ",")
        let hidden = !panelVisible && !destinationsPaneShowing
        if hidden, !force, signature == publishedSignature, Date().timeIntervalSince(publishedAt) < 15 {
            alerts.handle(fresh)
            return
        }
        publishedSignature = signature
        publishedAt = Date()
        var next = fresh
        if case .valid(let rules, _)? = fresh.rulesState { TenantPalette.shared.update(rules) }
        next.githubPolledAt = githubPolledAt
        // The newest frame any box sent: it ages while the boxes are quiet.
        next.boxesPolledAt = probes.values.map(\.probedAt).max() ?? boxesPolledAt
        let failures = Set(fresh.jobs.filter { $0.state == .failed || $0.state == .lost }.map(\.id))
        if tab == .jobs, panelVisible { seenFailures.formUnion(failures) }
        next.unseenFailure = !failures.isSubset(of: seenFailures)
        snapshot = next
        // Every box that answers has reported since the opening: the placeholders end.
        if let since = readingSince, probes.values.filter({ $0.availability.isAvailable }).allSatisfy({ $0.probedAt > since }) {
            reading = false
            readingSince = nil
            readingTimeout?.cancel()
        }
        alerts.handle(fresh)
    }

    private func markSeen() {
        // Publishing the snapshot redraws the whole tab: do it only when something changes.
        guard snapshot.unseenFailure || !seenFailures.isSuperset(of: snapshot.jobs.filter { $0.state == .failed || $0.state == .lost }.map(\.id)) else { return }
        seenFailures.formUnion(snapshot.jobs.filter { $0.state == .failed || $0.state == .lost }.map(\.id))
        snapshot.unseenFailure = false
    }

    deinit {
        let streams = streams
        Task { await streams.stopAll() }
        loop?.cancel()
        backgroundLoop?.cancel()
    }
}
