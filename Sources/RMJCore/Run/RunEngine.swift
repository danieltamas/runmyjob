import Foundation

public struct RunRequest: Sendable {
    public var command: [String]
    /// `--shell`: the command is one string run by `bash -c`; otherwise argv reaches the program untouched.
    public var shell: Bool
    public var identity: RepoIdentity
    public var branch: String?
    public var commit: String?
    /// `--to`: a destination the user asked for.
    public var destination: String?
    public var forceLocal: Bool
    public var agent: AgentContext
    /// Where in the checkout the command was given, relative to its root; the command runs there.
    public var subdirectory: String

    public init(command: [String], shell: Bool = false, identity: RepoIdentity, branch: String? = nil, commit: String? = nil,
                destination: String? = nil, forceLocal: Bool = false, agent: AgentContext = AgentContext(agent: "terminal"), subdirectory: String = "") {
        self.subdirectory = subdirectory
        self.command = command
        self.shell = shell
        self.identity = identity
        self.branch = branch
        self.commit = commit
        self.destination = destination
        self.forceLocal = forceLocal
        self.agent = agent
    }
}

extension RunRequest {
    /// The subdirectory with anything that could leave the checkout dropped.
    var safeSubdirectory: String {
        subdirectory.split(separator: "/").filter { $0 != "." && $0 != ".." && !$0.isEmpty }.joined(separator: "/")
    }
}

public struct RunResult: Sendable, Equatable {
    public let jobID: String
    public let exitCode: Int32
    /// Where the row stands when `run` returns: `running` means the job continues on the box without this client.
    public let state: JobState
}

public enum CancelOutcome: Sendable, Equatable {
    case cancelled, notFound, alreadySettled, unreachable
}

/// Runs one command: allocates the id, routes, writes the ledger row first, then syncs and runs on the
/// destination or on the Mac, streaming the output as it arrives.
public struct RunEngine: Sendable {
    private let ledger: Ledger
    private let archive: LogArchive
    private let router: Router
    private let boxes: BoxDirectory
    private let probes: ProbeProvider
    private let secrets: [String]
    private let output: @Sendable (Data) -> Void
    private let notice: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private let profiles: ProfileStore
    private let streamer: LogStreamer?
    private let boxLoadInterval: Duration

    /// `output` gets the job's output, already cleaned of terminal escapes; `notice` gets rmj's own messages.
    public init(ledger: Ledger, archive: LogArchive, router: Router, boxes: BoxDirectory, probes: ProbeProvider, secrets: [String] = [],
                output: @escaping @Sendable (Data) -> Void, notice: @escaping @Sendable (String) -> Void,
                profiles: ProfileStore = ProfileStore(home: RMJHome()), streamer: LogStreamer? = nil, boxLoadInterval: Duration = .seconds(10), now: @escaping @Sendable () -> Date = { Date() }) {
        self.profiles = profiles
        self.streamer = streamer
        self.boxLoadInterval = boxLoadInterval
        self.ledger = ledger
        self.archive = archive
        self.router = router
        self.boxes = boxes
        self.probes = probes
        self.secrets = secrets
        self.output = output
        self.notice = notice
        self.now = now
    }

    private enum BoxOutcome { case finished(RunResult), fallback(String) }

    public func run(_ request: RunRequest) async -> RunResult {
        let began = ContinuousClock.now
        let queuedAt = now()
        let id = ULID.make(now: queuedAt)
        let routed = request.shell ? request.command.joined(separator: " ").split(separator: " ").map(String.init) : request.command
        let decision = await router.route(RouteRequest(command: routed, identity: request.identity, forceLocal: request.forceLocal,
                                                       destination: request.destination)).sanitized()
        var destination: String?
        if case .destination(let name, _) = decision.location { destination = name }
        var job = JobRecord(id: id, repo: request.identity.slug ?? URL(fileURLWithPath: request.identity.worktree).lastPathComponent,
                            command: SecretRedactor.scrub(request.display, secrets: secrets), location: decision.locationName, destination: destination,
                            fallbackReason: decision.fallbackReason, environment: destination == nil ? "mac" : "box", rule: decision.rule,
                            state: .queued, queuedAt: queuedAt)
        job.tenant = decision.tenant
        job.worktree = request.identity.worktree
        job.branch = request.branch
        job.commit = request.commit
        job.dirty = request.identity.dirty
        job.agent = request.agent.agent
        job.session = request.agent.session
        do { try await ledger.insert(job) } catch {
            notice("rmj: the ledger is unavailable (\(UntrustedText.clean(error.localizedDescription))); running on this Mac without a record")
            let code = await runUntracked(request)
            return RunResult(jobID: id, exitCode: code, state: code == 0 ? .done : .failed)
        }
        if let advisory = decision.advisory { notice("rmj: \(advisory)") }
        if case .destination(let name, let address) = decision.location, let config = boxes.rules.rules?.destinations[name] {
            switch await runOnBox(job, request, decision: decision, destination: name, address: address, config: config, began: began) {
            case .finished(let result): return result
            case .fallback(let reason):
                // A row someone else settled meanwhile (a cancel) is not run on the Mac behind their back.
                guard (try? await ledger.relocate(id, toLocalBecause: reason, at: now())) == true else {
                    let state = (try? await ledger.job(id))?.state ?? .failed
                    return RunResult(jobID: id, exitCode: 1, state: state)
                }
                notice("rmj: running on this Mac: \(reason)")
            }
        }
        return await runLocal(id, request, began: began)
    }

    // MARK: box

    private func runOnBox(_ job: JobRecord, _ request: RunRequest, decision: RouteDecision, destination: String, address: String,
                          config: DestinationConfig, began: ContinuousClock.Instant) async -> BoxOutcome {
        let id = job.id
        let directory = DockerPlan.directory(home: config.home, repo: request.identity.slug, worktree: request.identity.worktree)
        let rule = boxes.rules.rules?.rules.first { $0.name == decision.rule }
        let plan: DockerPlan
        do { plan = try DockerPlan.make(rule: rule, config: config, repo: request.identity.slug, directory: directory,
                                                    subdirectory: request.safeSubdirectory, profiles: profiles) } catch {
            return .fallback("no container for this rule")
        }
        let boxJob = BoxJob(ulid: id, name: ULID.containerName(repo: request.identity.slug, ulid: id), worktree: request.identity.worktree,
                            directory: directory, argv: request.shell ? ["bash", "-c", request.command.joined(separator: " ")] : request.command,
                            options: plan.options, image: plan.image, locks: plan.locks, prelude: plan.prelude)
        let client = boxes.factory.client(destination: destination, address: address, config: config)
        var stage = "destination unreachable"
        var goSent = false
        do {
            try await client.prepare(boxJob)
            try await client.begin(boxJob) { holder in
                notice("rmj: waiting for \(holder)")
                Task { _ = try? await ledger.advance(id, to: .queued, at: now(), detail: "waiting for \(holder)") }
            }
            try await ensureNotCancelled(id)
            try await advance(id, .syncing) { $0.syncStartedAt = now() }
            stage = "sync failed"
            try await client.sync(boxJob)
            var done = JobPatch()
            done.syncEndedAt = now()
            try await ledger.fill(id, patch: done)
            try await ensureNotCancelled(id)
            goSent = true
            let launch = try await client.go(boxJob)
            if case .startFailed(let reason) = launch {
                try? await client.cancel(ulid: id)
                notice("rmj: container start failed: \(UntrustedText.clean(reason))")
                return .fallback("container start failed")
            }
        } catch {
            if error is CancelledBeforeStart {
                try? await client.cancel(ulid: id)
                return .finished(RunResult(jobID: id, exitCode: 130, state: .cancelled))
            }
            if !goSent {
                // A cancel that reached the waiter ends the run; it must not start on the Mac instead.
                if let record = try? await client.record(ulid: id), record.result?.cancelled == true {
                    var patch = JobPatch()
                    patch.endedAt = now()
                    _ = try? await ledger.advance(id, to: .cancelled, at: now(), detail: "cancelled before it started", patch: patch)
                    return .finished(RunResult(jobID: id, exitCode: 130, state: .cancelled))
                }
                try? await client.cancel(ulid: id)
                notice("rmj: \(stage): \(UntrustedText.clean(error.localizedDescription))")
                return .fallback(stage)
            }
            // The launch record decides: no record and no container means nothing started, so the Mac may run it.
            let record = try? await client.record(ulid: id)
            if record?.result?.cancelled == true && record?.launch == nil {
                var patch = JobPatch()
                patch.endedAt = now()
                _ = try? await ledger.advance(id, to: .cancelled, at: now(), detail: "cancelled before it started", patch: patch)
                return .finished(RunResult(jobID: id, exitCode: 130, state: .cancelled))
            }
            if let record, record.launch == nil, !record.containerPresent {
                try? await client.cancel(ulid: id)
                // docker may still be creating the container: the Mac runs it only once the waiter has gone.
                guard await waiterGone(client, id) else {
                    _ = try? await ledger.advance(id, to: .lost, at: now(), detail: "the launch could not be confirmed")
                    return .finished(RunResult(jobID: id, exitCode: 1, state: .lost))
                }
                return .fallback("container start failed")
            }
            if case .startFailed? = record?.launch {
                try? await client.cancel(ulid: id)
                return .fallback("container start failed")
            }
            if case .started? = record?.launch {} else {
                _ = try? await ledger.advance(id, to: .lost, at: now(), detail: "lost contact before the launch was confirmed")
                return .finished(RunResult(jobID: id, exitCode: 1, state: .lost))
            }
        }
        return .finished(await follow(id, boxJob, client: client, destination: destination, began: began))
    }

    /// Streams the log until the run ends, then records the outcome the box wrote. A dropped connection leaves
    /// the job running on the box; reconcile settles it later.
    private func follow(_ id: String, _ boxJob: BoxJob, client: BoxClient, destination: String, began: ContinuousClock.Instant) async -> RunResult {
        _ = try? await advance(id, .running) { $0.startedAt = now() }
        try? await archive.markPending(jobID: id, reason: "running", now: now())
        let stream = await openStream(id)
        let pump = OutputPump(writer: try? archive.writer(jobID: id, side: "box", secrets: secrets), output: output, secrets: secrets, logStream: stream)
        var streamed = true
        let recorder = LoadRecorder(sample: { await client.load(ulid: id) })
        await recorder.start(first: boxLoadInterval, every: boxLoadInterval)
        do { try await client.tail(boxJob, output: pump.add) } catch { streamed = false }
        let load = await recorder.stop()
        await pump.close()
        let asked = now()
        guard let record = try? await client.record(ulid: id), let result = record.result else {
            await pump.abandon()
            await stream?.abandon()
            notice("rmj: lost contact with the box; the job continues there. See: rmj jobs")
            return RunResult(jobID: id, exitCode: 1, state: .running)
        }
        if streamed { await pump.complete() } else { await pump.abandon() }
        let elapsed = began.duration(to: .now)
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        // Box minus Mac, taken at the middle of the round trip.
        let midpoint = asked.addingTimeInterval(now().timeIntervalSince(asked) / 2)
        let measured = record.boxNow.map { Int(($0.timeIntervalSince(midpoint) * 1000).rounded()) }
        var offset = measured
        if offset == nil { offset = await probes.latest(for: destination)?.clockOffsetMS }
        if let job = try? await ledger.job(id) {
            _ = await Reconciler.settle(job, record: record, result: result, ledger: ledger, archive: archive, now: now(),
                                        macElapsedMS: ms, clockOffsetMS: offset, load: load)
        }
        let state: JobState = result.cancelled ? .cancelled : result.code == 0 ? .done : .failed
        let settled = try? await ledger.job(id)
        await stream?.finish(state: state.rawValue, exitCode: result.code, seconds: Double(ms) / 1000, avgCPU: settled?.avgCPU,
                             avgMemoryBytes: settled?.avgMemoryBytes)
        return RunResult(jobID: id, exitCode: Int32(clamping: result.code), state: state)
    }

    /// The job's log stream, when a sink is on for its tenant.
    private func openStream(_ id: String) async -> LogStream? {
        guard let streamer, let job = try? await ledger.job(id) else { return nil }
        return streamer.begin(job: id, repo: job.repo, tenant: job.tenant, branch: job.branch, agent: job.agent,
                              destination: job.destination ?? "local", secrets: secrets)
    }

    // MARK: local

    private func runLocal(_ id: String, _ request: RunRequest, began: ContinuousClock.Instant) async -> RunResult {
        LocalClient.record(id, in: archive.directory)
        defer { LocalClient.clear(id, in: archive.directory) }
        _ = try? await advance(id, .running) { $0.startedAt = now() }
        let stream = await openStream(id)
        let pump = OutputPump(writer: try? archive.writer(jobID: id, side: "mac", secrets: secrets), output: output, secrets: secrets, logStream: stream)
        var status: Int32 = 127
        let recorder = LoadRecorder()
        await recorder.start()
        do {
            status = try await execute(request, output: pump.add)
        } catch {
            notice("rmj: cannot start the command: \(UntrustedText.clean(error.localizedDescription))")
        }
        let average = await recorder.stop()
        await pump.close()
        await pump.complete()
        let elapsed = began.duration(to: .now)
        var patch = JobPatch()
        patch.exitCode = Int(status)
        patch.endedAt = now()
        patch.macElapsedMS = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        patch.avgCPU = average?.cpuPercent
        patch.avgMemoryBytes = average?.memoryBytes
        let state: JobState = status == 0 ? .done : .failed
        _ = try? await ledger.advance(id, to: state, at: now(), patch: patch)
        await stream?.finish(state: state.rawValue, exitCode: Int(status), seconds: Double(patch.macElapsedMS ?? 0) / 1000,
                             avgCPU: average?.cpuPercent, avgMemoryBytes: average?.memoryBytes)
        return RunResult(jobID: id, exitCode: status, state: state)
    }

    private func runUntracked(_ request: RunRequest) async -> Int32 {
        let pump = OutputPump(writer: nil, output: output, secrets: secrets)
        let status = (try? await execute(request, output: pump.add)) ?? 127
        await pump.close()
        return status
    }

    private func execute(_ request: RunRequest, output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        let directory = URL(fileURLWithPath: request.identity.worktree).appendingPathComponent(request.safeSubdirectory)
        let result: ProcessOutput
        if request.shell {
            result = try await ProcessRunner().run("/bin/bash", ["-c", request.command.joined(separator: " ")], in: directory,
                                                   environment: ["PATH": Executables.searchPath], timeout: .seconds(14 * 86400), output: output)
        } else {
            result = try await ProcessRunner().run("/usr/bin/env", request.command, in: directory,
                                                   environment: ["PATH": Executables.searchPath], timeout: .seconds(14 * 86400), output: output)
        }
        return result.status
    }

    // MARK: cancel

    /// Removes the container by its label and waits up to 10 s for it to be gone, then records `cancelled`.
    public func cancel(_ id: String) async -> CancelOutcome {
        guard let job = try? await ledger.job(id) else { return .notFound }
        guard !job.state.isSettled else { return .alreadySettled }
        guard let destination = job.destination, let client = boxes.client(for: destination) else { return .unreachable }
        do { try await client.cancel(ulid: id) } catch { return .unreachable }
        var gone = false
        var last: BoxRecord?
        for _ in 0..<20 {
            if let record = try? await client.record(ulid: id), !record.containerPresent { gone = true; last = record; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // Only a container seen gone is a cancelled job; otherwise the row keeps saying what is true.
        guard gone else { return .unreachable }
        // The box's own exit and times are kept when it already wrote them.
        if let record = last, let result = record.result {
            let cancelled = BoxRecord.Result(code: result.code, cancelled: true)
            _ = await Reconciler.settle(job, record: record, result: cancelled, ledger: ledger, archive: archive, now: now())
            return .cancelled
        }
        var patch = JobPatch()
        patch.endedAt = now()
        _ = try? await ledger.advance(id, to: .cancelled, at: now(), detail: "cancelled", patch: patch)
        return .cancelled
    }

    private func waiterGone(_ client: BoxClient, _ id: String) async -> Bool {
        for _ in 0..<10 {
            if let record = try? await client.record(ulid: id), record.waiterAlive != true, record.launch == nil, !record.containerPresent { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private struct CancelledBeforeStart: Error {}

    /// `rmj cancel` from another process settles the row; this client must not start the command anyway.
    private func ensureNotCancelled(_ id: String) async throws {
        if try await ledger.job(id)?.state == .cancelled { throw CancelledBeforeStart() }
    }

    @discardableResult
    private func advance(_ id: String, _ state: JobState, patch: (inout JobPatch) -> Void = { _ in }) async throws -> Bool {
        var value = JobPatch()
        patch(&value)
        return try await ledger.advance(id, to: state, at: now(), patch: value)
    }
}

/// Carries a command's output, in order, to the screen (cleaned) and the log archive (as received).
final class OutputPump: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let consumer: Task<Void, Never>
    private let writer: LogWriter?

    init(writer: LogWriter?, output: @escaping @Sendable (Data) -> Void, secrets: [String], logStream: LogStream? = nil) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        self.writer = writer
        consumer = Task {
            var sanitizer = LogSanitizer()
            // The screen, and so an agent's context, gets the same redaction as the archive.
            var redactor = SecretRedactor(secrets: secrets)
            for await chunk in stream {
                await writer?.write(chunk)
                let shown = redactor.process(sanitizer.clean(chunk))
                if !shown.isEmpty { output(shown); logStream?.add(shown) }
            }
            let rest = redactor.flush()
            if !rest.isEmpty { output(rest); logStream?.add(rest) }
        }
    }

    func add(_ chunk: Data) { continuation.yield(chunk) }
    func close() async {
        continuation.finish()
        await consumer.value
    }
    func complete() async { _ = try? await writer?.finish(complete: true) }
    func abandon() async { _ = try? await writer?.finish(complete: false) }
}
