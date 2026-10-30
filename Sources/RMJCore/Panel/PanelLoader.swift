import Foundation

/// Builds the live `PanelSnapshot` from `~/.rmj`. Read-only: the panel never writes the ledger.
public struct PanelLoader: Sendable {
    /// The Jobs tab shows today and yesterday; History (U8) holds the rest.
    public static let window: TimeInterval = 2 * 86_400
    /// Logs are kept this long, so history is too.
    public static let historyWindow: TimeInterval = 30 * 86_400
    static let historyLimit = 200

    public let home: RMJHome
    private let ledger: Ledger
    private let archive: LogArchive

    public init(home: RMJHome = RMJHome()) throws {
        self.home = home
        try home.prepare()
        let database = try Database(url: home.url.appendingPathComponent("rmj.sqlite"))
        ledger = Ledger(database: database)
        archive = LogArchive(database: database, directory: home.url.appendingPathComponent("logs"))
    }

    /// Settles local rows whose `rmj run` client is gone. The one write the panel makes; it reads no box.
    public func settleOrphans() async { await Reconciler.settleLocal(ledger: ledger, archive: archive) }

    public func snapshot(tailnet: TailnetState, now: Date = Date(), unseenFailure: Bool = false,
                         probes: [String: DestinationProbeResult] = [:], histories: [String: [DestinationProbeResult]] = [:], runners: [String: [RunnerContainer]] = [:],
                         registrations: [String: [GitHubRunner]] = [:]) async throws -> PanelSnapshot {
        let cutoff = now.addingTimeInterval(-Self.window)
        let all = try await ledger.jobs()
        let jobs = all.filter { !$0.state.isSettled && $0.state != .lost || ($0.endedAt ?? $0.startedAt ?? $0.queuedAt) >= cutoff }
        let shown = Set(jobs.map(\.id))
        let historyCutoff = now.addingTimeInterval(-Self.historyWindow)
        let history = all.filter { $0.state.isSettled && !shown.contains($0.id) && ($0.endedAt ?? $0.startedAt ?? $0.queuedAt) >= historyCutoff }
            .sorted { $0.queuedAt > $1.queuedAt }.prefix(Self.historyLimit)
        var lastOutput: [String: Date] = [:]
        for job in jobs where job.state == .running && job.github == nil {
            let parts = LogTail.candidates(jobID: job.id, home: home).filter { $0.lastPathComponent.hasSuffix(".part") }.map(\.path)
            let modified = parts.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
            if let modified { lastOutput[job.id] = modified }
        }
        let state = RulesStore(home: home).load()
        let cards = state.rules.map { DestinationLoader().cards(rules: $0, tailnet: tailnet, jobs: jobs, probes: probes, histories: histories, runners: runners, registrations: registrations,
                                                                     profiles: ProfileStore(home: home), now: now) } ?? []
        var snapshot = PanelSnapshot(now: now, tailnet: tailnet, jobs: jobs, destinations: cards, rulesState: state, lastOutput: lastOutput, unseenFailure: unseenFailure)
        snapshot.history = Array(history)
        snapshot.load = await LocalLoad.sample(jobs: jobs.filter { $0.state == .running && $0.github == nil && $0.location == "local" }.map(\.id), logs: archive.directory)
        return snapshot
    }

    /// The rules in force; nil while there is no valid file.
    public func rules() -> Rules? { RulesStore(home: home).load().rules }
}

/// The log folder against its quota, and the pull queue (Settings > Retention).
public struct RetentionStatus: Sendable, Equatable {
    public let files: Int
    public let bytes: Int64
    public let pending: Int

    public static func read(home: RMJHome) async -> RetentionStatus {
        let logs = home.url.appendingPathComponent("logs")
        let urls = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = urls.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var pending = 0
        if let database = try? Database(url: home.url.appendingPathComponent("rmj.sqlite")) {
            pending = (try? await LogArchive(database: database, directory: logs).pending().count) ?? 0
        }
        return RetentionStatus(files: urls.count, bytes: bytes, pending: pending)
    }

    /// Expires what is past 30 days now; returns how many jobs went.
    public static func pruneNow(home: RMJHome) async throws -> Int {
        let database = try Database(url: home.url.appendingPathComponent("rmj.sqlite"))
        let retention = Retention(ledger: Ledger(database: database), archive: LogArchive(database: database, directory: home.url.appendingPathComponent("logs")))
        return try await retention.prune().count
    }
}
