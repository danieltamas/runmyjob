import Foundation

/// Which client reaches a destination right now: the rules say where it is, the tailnet says whether.
public struct BoxDirectory: Sendable {
    public let rules: RulesState
    public let tailnet: TailnetState
    public let factory: BoxFactory

    public init(rules: RulesState, tailnet: TailnetState, factory: BoxFactory) {
        self.rules = rules
        self.tailnet = tailnet
        self.factory = factory
    }

    public func client(for destination: String) -> BoxClient? {
        guard let config = rules.rules?.destinations[destination] else { return nil }
        let target = DestinationTarget(alias: config.sshAlias, peerID: config.peerID)
        guard case .online(let address) = DestinationResolver.resolve(target, in: tailnet) else { return nil }
        return factory.client(destination: destination, address: address, config: config)
    }
}

/// Settles what the Mac lost track of from what the box recorded. Runs on every `rmj` invocation, at
/// launch, on wake and every 60 seconds; settling is idempotent because the ledger only moves forward.
public struct Reconciler: Sendable {
    public static let probeAttempts = 3
    /// A queued or syncing row this old without a launch record belongs to a client that died.
    public static let abandonedAfter: TimeInterval = 300

    private let ledger: Ledger
    private let archive: LogArchive
    private let boxes: BoxDirectory
    private let secrets: [String]
    private let now: @Sendable () -> Date
    private let retryDelay: Duration

    public init(ledger: Ledger, archive: LogArchive, boxes: BoxDirectory, secrets: [String] = [],
                retryDelay: Duration = .seconds(2), now: @escaping @Sendable () -> Date = { Date() }) {
        self.ledger = ledger
        self.archive = archive
        self.boxes = boxes
        self.secrets = secrets
        self.retryDelay = retryDelay
        self.now = now
    }

    /// Looks at every unsettled box job. Returns the ids that changed state.
    @discardableResult
    public func reconcile() async -> [String] {
        var changed = [String]()
        let open = (try? await ledger.jobs(in: [.queued, .syncing, .running, .lost])) ?? []
        // GitHub rows are GitHub's to settle: a box being unreachable never changes their state.
        for job in open where job.location != "local" && job.location != "github-hosted" && job.github == nil {
            guard let destination = job.destination else { continue }
            if await reconcile(job, destination: destination) { changed.append(job.id) }
        }
        _ = try? await LogPull(ledger: ledger, archive: archive).reconcile(source: BoxLogSource(boxes: boxes, ledger: ledger), secrets: secrets, now: now())
        // What was pulled from a run that never finished is a partial log.
        for job in (try? await ledger.jobs(in: [.lost])) ?? [] where (try? await archive.entry(jobID: job.id))?.status == .available {
            try? await archive.markTruncated(jobID: job.id)
        }
        return changed
    }

    private func reconcile(_ job: JobRecord, destination: String) async -> Bool {
        let record = await read(job.id, destination: destination)
        guard let record else {
            guard job.state != .lost else { return false }
            return await mark(job, .lost, "destination unreachable")
        }
        if let result = record.result { return await Self.settle(job, record: record, result: result, ledger: ledger, archive: archive, now: now()) }
        switch record.launch {
        case .startFailed(let reason)?:
            return await mark(job, .failed, "container start failed: \(reason)", exit: 125)
        case .started(_, let bootID)?:
            // A lost row cannot move back to running; it settles when the box records the outcome.
            if record.containerPresent { return false }
            let rebooted = !record.bootID.isEmpty && record.bootID != bootID
            let reason = rebooted ? "destination rebooted" : "container vanished"
            let moved = await mark(job, .lost, reason)
            await markPartial(job.id)
            return moved
        case nil:
            guard !record.containerPresent, record.waiterAlive != true, now().timeIntervalSince(job.queuedAt) > Self.abandonedAfter,
                  [.queued, .syncing, .lost].contains(job.state) else { return false }
            return await mark(job, .failed, "client stopped before the command started")
        }
    }

    /// Three failed reads in a row is "unreachable"; one good read ends it.
    private func read(_ id: String, destination: String) async -> BoxRecord? {
        for attempt in 0..<Self.probeAttempts {
            if attempt > 0 { try? await Task.sleep(for: retryDelay) }
            if let client = boxes.client(for: destination), let record = try? await client.record(ulid: id) { return record }
        }
        return nil
    }

    private func mark(_ job: JobRecord, _ state: JobState, _ detail: String, exit: Int? = nil) async -> Bool {
        var patch = JobPatch()
        if state.isSettled { patch.endedAt = now() }
        patch.exitCode = exit
        return (try? await ledger.advance(job.id, to: state, at: now(), detail: detail, patch: patch)) ?? false
    }

    /// The partial log of a run that did not finish is pulled and marked truncated.
    private func markPartial(_ id: String) async {
        try? await archive.markPending(jobID: id, reason: "partial log of a lost run", now: now())
    }

    /// Records the outcome the box wrote. Shared with the engine, which settles live runs the same way.
    static func settle(_ job: JobRecord, record: BoxRecord, result: BoxRecord.Result, ledger: Ledger, archive: LogArchive,
                       now: Date, macElapsedMS: Int? = nil, clockOffsetMS: Int? = nil) async -> Bool {
        let state: JobState = result.cancelled ? .cancelled : result.code == 0 ? .done : .failed
        var patch = JobPatch()
        patch.exitCode = result.code
        patch.endedAt = record.meta?.finished.map { _ in now } ?? now
        patch.boxStartedAt = record.meta?.started
        patch.boxEndedAt = record.meta?.finished
        patch.boxExit = record.meta?.exit
        patch.macElapsedMS = macElapsedMS
        patch.clockOffsetMS = clockOffsetMS
        var detail: String?
        if case .startFailed(let reason)? = record.launch { detail = "container start failed: \(reason)" }
        let moved = (try? await ledger.advance(job.id, to: state, at: now, detail: detail, patch: patch)) ?? false
        // A row settled earlier (by `lost`) still gains the box's own times.
        try? await ledger.fill(job.id, patch: patch)
        // A partial log pulled while the run was lost is replaced by the whole one.
        let entry = try? await archive.entry(jobID: job.id)
        if entry?.status != .available || entry?.truncated == true {
            try? await archive.markPending(jobID: job.id, reason: "not pulled yet", replacing: true, now: now)
        }
        return moved
    }
}

/// Pulls a log from the box that ran the job.
struct BoxLogSource: LogSource {
    let boxes: BoxDirectory
    let ledger: Ledger

    func pull(jobID: String, into writer: LogWriter) async throws {
        guard let job = try await ledger.job(jobID), let destination = job.destination, let client = boxes.client(for: destination) else {
            throw BoxFailure("destination offline")
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let consumer = Task { for await chunk in stream { await writer.write(chunk) } }
        defer { continuation.finish() }
        do { try await client.pullLog(ulid: jobID) { continuation.yield($0) } } catch { continuation.finish(); await consumer.value; throw error }
        continuation.finish()
        await consumer.value
    }
}
