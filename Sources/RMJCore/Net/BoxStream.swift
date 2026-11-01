import Foundation

/// Runs a script on a box and hands over what it prints while it runs. A spy stands in for it in tests.
public protocol StreamTransport: Sendable {
    /// Returns the exit status when the session ends; throws when the task is cancelled (which also ends the session).
    func stream(address: String, alias: String, script: String, output: @escaping @Sendable (Data) -> Void) async throws -> Int32
}

/// One ssh session over the same connection options as every other ssh call (host key checked, no forwarding). Nothing of stdout
/// is kept: a session lasts days.
public struct SSHStreamTransport: StreamTransport {
    public init() {}

    public func stream(address: String, alias: String, script: String, output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        let arguments = try SSH.arguments(address: address, alias: alias, command: ["sh", "-c", SSH.quote(script)])
        return try await ProcessRunner().run("/usr/bin/ssh", arguments, timeout: .seconds(365 * 86_400), collectStdout: false, output: output).status
    }
}

/// One box, one long-lived session: the box prints a frame every few seconds and this reads them as they come, so a box that
/// stops answering turns unreachable on its own, without a probe having to fail. The address is resolved from the tailnet again
/// before every connect and the session is dropped as soon as the tailnet no longer shows the box online.
public actor BoxStream {
    public struct Timing: Sendable, Equatable {
        public var frameInterval: Int
        public var heavyEvery: Int
        public var rareEvery: Int
        /// No complete frame for this long while the session is up: the box is not answering.
        public var silence: Duration
        public var backoff: [Duration]
        public var jitter: Double

        /// The same timing at another frame interval: docker is still read every minute and the rare tools every five, and
        /// silence is three frames (never under 30 s).
        func paced(_ interval: Int) -> Timing {
            var copy = self
            copy.frameInterval = interval
            copy.heavyEvery = max(1, 60 / interval)
            copy.rareEvery = max(1, 300 / interval)
            copy.silence = .seconds(max(30, 3 * interval))
            return copy
        }

        public static let standard = Timing(frameInterval: 10, heavyEvery: 6, rareEvery: 30, silence: .seconds(30),
                                            backoff: [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(60)], jitter: 0.2)
    }

    /// How a session ended.
    private enum Ending { case ended(Int32), failed(String), silent, left(Availability), moved, repaced, cancelled }

    /// The most the supervisor sleeps: how often the tailnet and the silence are looked at.
    private static let watchPeriod: Duration = .seconds(1)
    /// Bytes read from the session and not yet parsed; more than this at a watch beat is a flood (a frame is under 3 KB).
    private static let backlogLimit = 1 << 20

    /// What the transport has handed over minus what the actor has taken.
    private final class Backlog: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var bytes: Int { lock.withLock { count } }
        func add(_ delta: Int) { lock.withLock { count += delta } }
    }

    /// A result that says what the previous one did is not announced again before this long.
    private static let repeatAfter: TimeInterval = 60

    private let target: DestinationTarget
    private let transport: StreamTransport
    private let tailnet: @Sendable () async -> TailnetState
    private let clock: @Sendable () -> Date
    private var timing: Timing
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onResult: @Sendable (DestinationProbeResult) -> Void
    /// Told of every published result, with none of `onResult`'s repeat suppression.
    private let onFrame: (@Sendable (DestinationProbeResult) -> Void)?

    /// The newest thing known about the box, a reading or the reason there is none.
    public private(set) var latest: DestinationProbeResult?
    private var lastGood: DestinationProbeResult?
    private var announced: (result: DestinationProbeResult, at: Date)?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var repaceSignal: AsyncStream<Void>.Continuation?
    /// Counts the pace changes; a session remembers the count it started with.
    private var pace = 0
    private var sessionPace = 0
    private var address = ""
    private var lastFrameAt = Date.distantPast
    private var gotFrame = false
    private var assembler = FrameAssembler()
    private var cache = SectionCache()
    /// Set when the session ended only to change its pace: the next one keeps the sections the box already sent.
    private var carryCache = false

    public init(target: DestinationTarget, transport: StreamTransport, tailnet: @escaping @Sendable () async -> TailnetState,
                clock: @escaping @Sendable () -> Date = Date.init, timing: Timing = .standard,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                onResult: @escaping @Sendable (DestinationProbeResult) -> Void, onFrame: (@Sendable (DestinationProbeResult) -> Void)? = nil) {
        self.target = target
        self.transport = transport
        self.tailnet = tailnet
        self.clock = clock
        self.timing = timing
        self.sleep = sleep
        self.onResult = onResult
        self.onFrame = onFrame
    }

    public func start() {
        guard task == nil, !stopped else { return }
        task = Task { await supervise() }
    }

    /// Reports every `seconds`; a running session is replaced at once, on the same connection and without a backoff.
    public func setFrameInterval(_ seconds: Int) {
        guard seconds > 0, seconds != timing.frameInterval else { return }
        timing = timing.paced(seconds)
        pace += 1
        repaceSignal?.yield()
    }

    /// Ends the session and any pending reconnect; nothing is published afterwards.
    public func stop() async {
        stopped = true
        let running = task
        task = nil
        running?.cancel()
        await running?.value
    }

    private func supervise() async {
        var attempt = 0
        while !stopped, !Task.isCancelled {
            var tailnetDown = false
            let availability = DestinationResolver.resolve(target, in: await tailnet())
            if case .online(let address) = availability {
                let ending = await session(address: address)
                if stopped || Task.isCancelled { return }
                if gotFrame { attempt = 0 }
                switch ending {
                case .ended(let status): publishDown(.unreachable("ssh exit \(status): \(Self.reason(status))"))
                case .failed(let message): publishDown(.unreachable("ssh failed: \(UntrustedText.clean(message))"))
                case .silent: publishDown(.unreachable("no frames for \(Int(Self.seconds(timing.silence))) s"))
                case .left(let now): publishDown(now); tailnetDown = true
                case .moved, .repaced, .cancelled: break
                }
                // A pace change that landed while the session was ending asks for the new session at once, as one that ended it would.
                // A new pace is the same box on the same address: what it reported stays until it is replaced or ages out.
                if case .repaced = ending { carryCache = true }
                switch ending { case .moved, .repaced: continue; default: if sessionPace != pace { continue } }
            } else {
                publishDown(availability)
                tailnetDown = true
            }
            guard await pause(attempt, endingWhenOnline: tailnetDown) else { return }
            attempt += 1
        }
    }

    /// The backoff before the next connect. While the tailnet is what is down, it ends the moment the tailnet shows the box online:
    /// a box is not made to wait out a minute of backoff after the network came back. False when stopped.
    private func pause(_ attempt: Int, endingWhenOnline: Bool) async -> Bool {
        let wait = delay(attempt), sleep = sleep, tailnet = tailnet, target = target, period = Self.watchPeriod
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { do { try await sleep(wait); return true } catch { return false } }
            if endingWhenOnline {
                group.addTask {
                    while !Task.isCancelled {
                        do { try await sleep(period) } catch { return false }
                        if DestinationResolver.resolve(target, in: await tailnet()).isAvailable { return true }
                    }
                    return false
                }
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first && !Task.isCancelled
        }
    }

    private func session(address: String) async -> Ending {
        self.address = address
        assembler = FrameAssembler()
        if !carryCache { cache = SectionCache() }
        carryCache = false
        gotFrame = false
        lastFrameAt = clock()
        let script = DestinationProbe.streamScript(requires: target.requires, images: target.images, interval: timing.frameInterval,
                                                   heavyEvery: timing.heavyEvery, rareEvery: timing.rareEvery)
        // Chunks reach the actor in the order they were read. A box that prints faster than they are parsed ends the session.
        let (chunks, feed) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let backlog = Backlog()
        let consumer = Task { for await data in chunks { backlog.add(-data.count); receive(data) } }
        let (repace, signal) = AsyncStream<Void>.makeStream()
        repaceSignal = signal
        sessionPace = pace
        let transport = transport, alias = target.alias
        let ending = await withTaskGroup(of: Ending.self) { group -> Ending in
            group.addTask {
                do { return .ended(try await transport.stream(address: address, alias: alias, script: script, output: { backlog.add($0.count); feed.yield($0) })) }
                catch is CancellationError { return .cancelled }
                catch { return .failed(error.localizedDescription) }
            }
            group.addTask { await self.watch(address: address, backlog: backlog) }
            group.addTask { for await _ in repace { return .repaced }; return .cancelled }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
        signal.finish()
        repaceSignal = nil
        feed.finish()
        await consumer.value
        return ending
    }

    /// The only timer of a box: once a period it asks whether the tailnet still shows the box at this address and whether the box
    /// is still talking.
    private func watch(address: String, backlog: Backlog) async -> Ending {
        while !stopped, !Task.isCancelled {
            do { try await sleep(Self.watchPeriod) } catch { return .cancelled }
            if stopped { return .cancelled }
            if backlog.bytes > Self.backlogLimit { return .failed("output faster than it is read") }
            let availability = DestinationResolver.resolve(target, in: await tailnet())
            guard case .online(let current) = availability else { return .left(availability) }
            if current != address { return .moved }
            if clock().timeIntervalSince(lastFrameAt) >= Self.seconds(timing.silence) { return .silent }
        }
        return .cancelled
    }

    private func receive(_ data: Data) {
        guard !stopped else { return }
        for frame in assembler.feed(data) {
            let now = clock()
            guard let result = cache.merge(frame: frame, address: address, at: now, timing: timing,
                                           requires: target.requires, images: target.images) else { continue }
            lastFrameAt = now
            gotFrame = true
            lastGood = result
            publish(result)
        }
    }

    private func publishDown(_ availability: Availability) {
        publish(lastGood?.unreachable(availability) ?? .without(availability, at: clock()))
    }

    private func publish(_ result: DestinationProbeResult) {
        guard !stopped else { return }
        latest = result
        onFrame?(result)
        let now = clock()
        if let announced, result.sameReadings(as: announced.result), now.timeIntervalSince(announced.at) < Self.repeatAfter { return }
        announced = (result, now)
        onResult(result)
    }

    private func delay(_ attempt: Int) -> Duration {
        let base = timing.backoff.isEmpty ? .seconds(60) : timing.backoff[min(attempt, timing.backoff.count - 1)]
        return .milliseconds(Int((Self.seconds(base) * Double.random(in: (1 - timing.jitter)...(1 + timing.jitter)) * 1000).rounded()))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func reason(_ status: Int32) -> String {
        switch status {
        case 255: "connection lost"
        case 0: "session ended"
        default: "remote shell failed"
        }
    }
}

/// One stream per enabled destination, kept in step with the rules.
public actor BoxStreams {
    private let transport: StreamTransport
    private let tailnet: @Sendable () async -> TailnetState
    private let clock: @Sendable () -> Date
    private let timing: BoxStream.Timing
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onResult: (@Sendable (String, DestinationProbeResult) -> Void)?
    private let onFrame: (@Sendable (String, DestinationProbeResult) -> Void)?
    private var interval: Int?
    private var streams: [String: (target: DestinationTarget, stream: BoxStream)] = [:]

    public init(transport: StreamTransport = SSHStreamTransport(), tailnet: @escaping @Sendable () async -> TailnetState,
                clock: @escaping @Sendable () -> Date = Date.init, timing: BoxStream.Timing = .standard,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                onResult: (@Sendable (String, DestinationProbeResult) -> Void)? = nil,
                onFrame: (@Sendable (String, DestinationProbeResult) -> Void)? = nil) {
        self.transport = transport
        self.tailnet = tailnet
        self.clock = clock
        self.timing = timing
        self.sleep = sleep
        self.onResult = onResult
        self.onFrame = onFrame
    }

    /// Every stream reports every `seconds`, those started later too.
    public func setFrameInterval(_ seconds: Int) async {
        interval = seconds
        for entry in streams.values { await entry.stream.setFrameInterval(seconds) }
    }

    /// Starts the streams of new destinations, restarts one whose target changed, stops those no longer listed.
    public func ensure(destinations: [String: DestinationTarget]) async {
        // The table changes before the first await, so a second call never sees half of this one; a stream stopped
        // before its start runs does not start.
        var stopping = [BoxStream](), starting = [BoxStream]()
        for (name, entry) in streams where destinations[name] != entry.target {
            streams[name] = nil
            stopping.append(entry.stream)
        }
        for (name, target) in destinations where streams[name] == nil {
            let report = onResult, frame = onFrame
            let stream = BoxStream(target: target, transport: transport, tailnet: tailnet, clock: clock, timing: interval.map(timing.paced) ?? timing,
                                   sleep: sleep, onResult: { report?(name, $0) }, onFrame: { frame?(name, $0) })
            streams[name] = (target, stream)
            starting.append(stream)
        }
        for stream in stopping { await stream.stop() }
        for stream in starting { await stream.start() }
    }

    public func latest() async -> [String: DestinationProbeResult] {
        var all = [String: DestinationProbeResult]()
        for (name, entry) in streams { if let result = await entry.stream.latest { all[name] = result } }
        return all
    }

    public func stopAll() async {
        let running = streams
        streams = [:]
        for entry in running.values { await entry.stream.stop() }
    }
}
