import Foundation

/// The log-streaming service of one process (the CLI running a job, or the app): the enabled sinks, a drainer per
/// sink, and the status file. `make` answers nil when no sink is on, so with nothing configured nothing runs.
public final class LogStreamer: @unchecked Sendable {
    private static let drainEvery: Duration = .seconds(1)
    private static let statusEvery: TimeInterval = 5
    /// How long a finished run waits for the spool to empty before it leaves the rest to the next drain.
    public static let endFlush: Duration = .seconds(3)

    public let home: RMJHome
    public let sinks: [LogSinkConfig]
    private let spoolRoot: URL
    private let statusStore: LogSinkStatusStore
    private let drainers: [String: LogSinkDrainer]
    private let host: String
    /// The sinks' own credentials and the runner PATs: never allowed into a line sent anywhere.
    let sinkSecrets: [String]
    private let lock = NSLock()
    private let startRevision: Double
    private var lastStatusWrite: [String: Date] = [:]

    public init?(home: RMJHome, sinks: [LogSinkConfig], transport: LogSinkTransport = URLSessionLogTransport(),
                 secret: @Sendable (LogSinkConfig) -> String? = LogStreamer.keychainSecret, host: String = LogStreamer.hostName) {
        let active = sinks.filter(\.enabled)
        guard !active.isEmpty else { return nil }
        self.home = home
        startRevision = LogSinkStore.revision(home: home)
        self.sinks = active
        self.host = host
        spoolRoot = home.url.appendingPathComponent("spool", isDirectory: true)
        statusStore = LogSinkStatusStore(home: home)
        var made: [String: LogSinkDrainer] = [:]
        let targets = Set((RulesStore(home: home).load().rules?.destinations.values.flatMap { $0.runnerTargets ?? [] }) ?? [])
        sinkSecrets = (active.compactMap { secret($0) } + targets.compactMap { try? Keychain().read(account: "rmj.pat.\($0)") }).filter { !$0.isEmpty }
        for sink in active {
            let spool = LogSpool(directory: LogShipper.spoolDirectory(root: spoolRoot, sinkID: sink.id))
            made[sink.id] = LogSinkDrainer(sink: sink, secret: secret(sink), spool: spool, transport: transport, host: host)
        }
        drainers = made
    }

    /// The streamer for what `config.json` lists, or nil when no sink is enabled.
    public static func make(home: RMJHome) -> LogStreamer? {
        LogStreamer(home: home, sinks: LogSinkStore.load(home: home).sinks)
    }

    public static let keychainSecret: @Sendable (LogSinkConfig) -> String? = { sink in
        try? Keychain().read(account: sink.keychainAccount)
    }

    public static var hostName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    /// The sinks as they are now: a sink switched off, removed or edited since this streamer started is out until the
    /// next process, so a long run never keeps an authorization the owner has taken back.
    var liveSinks: [LogSinkConfig] {
        guard LogSinkStore.revision(home: home) != startRevision else { return sinks }
        let current = LogSinkStore.load(home: home).sinks.filter(\.enabled)
        return sinks.filter { current.contains($0) }
    }

    func shipper(secrets: [String]) -> LogShipper {
        LogShipper(sinks: liveSinks, spoolRoot: spoolRoot, secrets: secrets + sinkSecrets)
    }

    /// A run's stream, or nil when no enabled sink takes this tenant.
    public func begin(job: String, repo: String, tenant: String?, branch: String?, agent: String?, destination: String, secrets: [String]) -> LogStream? {
        guard sinks.contains(where: { $0.accepts(tenant: tenant) }) else { return nil }
        let assembler = LogLineAssembler(job: job, repo: repo, tenant: tenant, branch: branch, agent: agent, destination: destination)
        return LogStream(streamer: self, secrets: secrets, assembler: assembler)
    }

    /// Writes entries to the spools and records what the limits dropped.
    func write(_ entries: [LogEntry], with shipper: LogShipper) {
        let result: (lines: [String: Int], dropped: [String: Int])
        do { result = try shipper.write(entries) } catch {
            for sink in sinks { try? statusStore.modify(id: sink.id) { $0.lastError = "spool write failed: \(error.localizedDescription)"; $0.lastErrorAt = Date() } }
            return
        }
        for (id, dropped) in result.dropped where dropped > 0 { try? statusStore.modify(id: id) { $0.dropped += dropped } }
    }

    /// One pass over every enabled sink's spool. The status file is rewritten at most every few seconds unless `force`.
    public func drainAll(now: Date = Date(), force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for sink in liveSinks {
                guard let drainer = drainers[sink.id] else { continue }
                group.addTask { await self.drain(sink, drainer, now: now, force: force) }
            }
        }
    }

    /// The end of a run: drain until empty or the end flush runs out, whichever is first.
    public func drainUntilEmptyOrTimeout() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.drainWhilePending() }
            group.addTask { try? await Task.sleep(for: Self.endFlush) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Keeps draining while a run lasts.
    func drainLoop() async {
        while !Task.isCancelled {
            await drainAll()
            try? await Task.sleep(for: Self.drainEvery)
        }
    }

    public func resume(sinkID: String) async { await drainers[sinkID]?.resume() }

    private func drainWhilePending() async {
        while !Task.isCancelled {
            await drainAll()
            let waiting = liveSinks.contains { LogSpool(directory: LogShipper.spoolDirectory(root: spoolRoot, sinkID: $0.id)).pending().files > 0 }
            guard waiting else { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func drain(_ sink: LogSinkConfig, _ drainer: LogSinkDrainer, now: Date, force: Bool) async {
        let outcome = await drainer.drain(now: now)
        let pending = LogSpool(directory: LogShipper.spoolDirectory(root: spoolRoot, sinkID: sink.id)).pending()
        let due = lock.withLock { () -> Bool in
            let last = lastStatusWrite[sink.id] ?? .distantPast
            guard force || outcome.lastError != nil || outcome.files > 0 || now.timeIntervalSince(last) >= Self.statusEvery else { return false }
            lastStatusWrite[sink.id] = now
            return true
        }
        guard due else { return }
        try? statusStore.modify(id: sink.id) { status in
            status.sent += outcome.lines
            status.rejected += outcome.rejected
            status.waitingFiles = pending.files
            status.waitingLines = pending.lines
            status.oldestWaiting = pending.oldest
            if case .authFailed = outcome.health { status.authFailed = true } else { status.authFailed = false }
            if let error = outcome.lastError {
                status.lastError = error
                status.lastErrorAt = now
            } else if outcome.health == .ok, pending.files == 0 || outcome.files > 0 {
                status.lastOK = now
            }
        }
    }
}

/// One run's output on its way to the sinks: lines become entries, entries wait at most a second (or 500 lines)
/// before they are written to the spools, and a background task drains the spools while the run lasts.
public final class LogStream: @unchecked Sendable {
    private let streamer: LogStreamer
    private let secrets: [String]
    private let lock = NSLock()
    private var assembler: LogLineAssembler
    private var buffer: [LogEntry] = []
    private var finished = false
    private var ticker: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?

    init(streamer: LogStreamer, secrets: [String], assembler: LogLineAssembler) {
        self.streamer = streamer
        self.secrets = secrets
        self.assembler = assembler
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.flush()
            }
        }
        drainTask = Task { [streamer] in await streamer.drainLoop() }
    }

    /// Already cleaned and redacted output, as the screen gets it.
    public func add(_ chunk: Data, now: Date = Date()) {
        let full = lock.withLock { () -> Bool in
            guard !finished else { return false }
            buffer += assembler.add(chunk, now: now)
            return buffer.count >= LogSinkFormat.maxBatch(.loki)
        }
        if full { flush() }
    }

    /// The run ended: the last partial line, a closing entry, then a short wait for the spools to empty.
    public func finish(state: String, exitCode: Int?, seconds: TimeInterval?, avgCPU: Double?, avgMemoryBytes: Int64?, now: Date = Date()) async {
        let wasFinished = lock.withLock { () -> Bool in
            defer { finished = true }
            guard !finished else { return true }
            buffer += assembler.flush(now: now)
            buffer.append(assembler.finish(state: state, exitCode: exitCode, seconds: seconds, avgCPU: avgCPU, avgMemoryBytes: avgMemoryBytes, now: now))
            return false
        }
        guard !wasFinished else { return }
        await end()
    }

    /// The run's end is unknown (contact lost): what was seen is shipped, with no closing entry.
    public func abandon(now: Date = Date()) async {
        let wasFinished = lock.withLock { () -> Bool in
            defer { finished = true }
            guard !finished else { return true }
            buffer += assembler.flush(now: now)
            return false
        }
        guard !wasFinished else { return }
        await end()
    }

    private func end() async {
        ticker?.cancel()
        drainTask?.cancel()
        flush()
        await streamer.drainUntilEmptyOrTimeout()
    }

    deinit {
        ticker?.cancel()
        drainTask?.cancel()
    }

    /// One flush at a time, so a later batch never reaches the spool before an earlier one.
    private let flushLock = NSLock()

    private func flush() {
        flushLock.lock()
        defer { flushLock.unlock() }
        let entries = lock.withLock { () -> [LogEntry] in
            defer { buffer = [] }
            return buffer
        }
        if !entries.isEmpty { streamer.write(entries, with: streamer.shipper(secrets: secrets)) }
    }
}
