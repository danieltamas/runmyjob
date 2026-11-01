import Foundation
import Testing
@testable import RMJCore

// Shared U16 stream fixtures and controllable dependencies, kept here for the 500-line limit.
let probeFrame: String = {
    let sections = [("clock", "1793102400000000000"), ("docker", "27.3.1"),
        ("rsync", "rsync version 3.2.7 protocol version 31"), ("images", "swift:6"),
        ("containers", "rx-build 1.0% 1MiB / 2GiB"), ("nproc", "24"), ("mem", "26624"),
        ("memtotal", "36864"), ("disk", "1030000 300000"), ("diskhealth", "ro 0\nsmart passed"),
        ("osname", "Linux"), ("load", "6.4"), ("boot", "boot-first"), ("uptime", "129600"),
        ("virt", "none"), ("cpustat", "cpu 1 2 3 4 5 6 7 8"), ("swap", "2048 512"),
        ("net", "12 34"), ("psi", "cpu 0.1\nmemory 0.2"), ("hwmon", "temp 42000\nfan 1200"),
        ("tools", ""), ("clockend", "1793102400000000000")]
    return sections.map { "@@\($0.0) rc=0\n\($0.1)\n" }.joined() + "@@end\n"
}()

func frameKeeping(_ names: Set<String>) -> String {
    probeFrame.components(separatedBy: "@@").dropFirst().filter { section in
        names.contains(String(section.prefix { $0 != " " && $0 != "\n" }))
    }.map { "@@" + $0 }.joined() + "@@end\n"
}
func lightFrame() -> String { frameKeeping(Set(DestinationProbe.lightSections)) }
func frameAt(_ at: Date, frame: String = lightFrame()) -> String {
    frame.replacingOccurrences(of: "1793102400000000000", with: String(Int64(at.timeIntervalSince1970 * 1e9)))
}

func normalized(_ text: String) -> String { text.trimmingCharacters(in: .newlines) }
func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
func settle() async { for _ in 0..<200 { await Task.yield() } }
func eventually(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<10_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Expected asynchronous state was not reached", sourceLocation: sourceLocation)
}
func tailnet(standing: TailnetState.Standing = .running, online: Bool = true,
                     address: String = "100.64.0.10") -> TailnetState {
    TailnetState(standing: standing, magicDNSEnabled: false, peers: [
        TailnetPeer(id: "peer", dnsName: "box.ts.net", hostName: "box", os: "linux", addresses: [address],
                    online: online, lastSeen: nil, keyExpiry: nil, relay: nil)
    ], readAt: Date(timeIntervalSince1970: 1_793_102_400))
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    let lock = NSLock()
    var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func set(_ value: Value) { lock.withLock { storage = value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}
final class StreamClock: Sendable {
    let storage = LockedValue(Date(timeIntervalSince1970: 1_793_102_400))
    var now: Date { storage.value }
    func advance(_ seconds: TimeInterval) { storage.update { $0.addTimeInterval(seconds) } }
}
final class StreamResults: Sendable {
    let storage = LockedValue<[DestinationProbeResult]>([])
    var values: [DestinationProbeResult] { storage.value }
    func append(_ result: DestinationProbeResult) { storage.update { $0.append(result) } }
}

struct StreamHarness: Sendable {
    let target = DestinationTarget(alias: "box", peerID: "peer")
    let transport: ScriptedStream
    let clock = StreamClock()
    let results = StreamResults()
    let sleeper = StreamSleeper()
    let network: LockedValue<TailnetState>
    init(sessions: [ScriptedStream.Session], state: TailnetState = tailnet()) {
        transport = ScriptedStream(sessions)
        network = LockedValue(state)
    }
    func makeStream() -> BoxStream {
        BoxStream(target: target, transport: transport, tailnet: { network.value }, clock: { clock.now },
                  timing: .standard, sleep: { try await sleeper.sleep($0) }, onResult: { results.append($0) })
    }
}

actor ScriptedStream: StreamTransport {
    enum End: Sendable, Equatable { case hang, status(Int32), failure }
    struct Session: Sendable {
        var chunks: [String] = []
        var end: End = .hang
    }
    struct Call: Sendable { let address: String; let alias: String; let script: String }
    enum Failure: Error { case disconnected }
    var sessions: [Session]
    var output: (@Sendable (Data) -> Void)?
    private(set) var calls: [Call] = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var cancelled = 0
    init(_ sessions: [Session]) { self.sessions = sessions }
    func emit(_ text: String) { output?(Data(text.utf8)) }
    func stream(address: String, alias: String, script: String,
                output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        calls.append(Call(address: address, alias: alias, script: script))
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        self.output = output
        let session = sessions.isEmpty ? Session() : sessions.removeFirst()
        for chunk in session.chunks { output(Data(chunk.utf8)) }
        switch session.end {
        case .status(let code): return code
        case .failure: throw Failure.disconnected
        case .hang:
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            for await _ in stream {}
            cancelled += 1
            throw CancellationError()
        }
    }
}

actor StreamSleeper {
    struct Waiter { let duration: Duration; let continuation: AsyncStream<Void>.Continuation }
    var waiters: [Waiter] = []
    private(set) var requested: [Duration] = []
    var hasCheck: Bool { waiters.contains { seconds($0.duration) < 1.6 || seconds($0.duration) > 72 } }
    // Standard backoffs are <=72 s; supervision checks are expected to be <=1 s.
    // See handoff: the spec must distinguish check sleeps from reconnect sleeps.
    var backoffs: [Duration] { requested.filter { seconds($0) >= 1.6 && seconds($0) <= 72 } }
    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        waiters.append(Waiter(duration: duration, continuation: continuation))
        for await _ in stream {}
        try Task.checkCancellation()
    }
    func releaseAll() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.continuation.finish() }
    }
    func releaseChecks() {
        let checks = waiters.filter { seconds($0.duration) < 1.6 || seconds($0.duration) > 72 }
        waiters.removeAll { seconds($0.duration) < 1.6 || seconds($0.duration) > 72 }
        for waiter in checks { waiter.continuation.finish() }
    }
}
struct OfflineCardAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 1_793_102_400)

    @Test func offlineAndUnreachableCardsKeepDatedReadingsInUnknownTone() throws {
        let good = lastGood()
        for availability in [Availability.offline("peer offline"), .unreachable("no frames for 30 s")] {
            let retained = good.unreachable(availability)
            #expect(retained.probedAt == good.probedAt)
            #expect(retained.docker == good.docker && retained.rsync == good.rsync)
            #expect(retained.images == good.images && retained.containers == good.containers)
            #expect(retained.sensors == good.sensors)
            #expect(retained.memoryFreeMB == good.memoryFreeMB && retained.cores == good.cores)
            let display = DestinationCardPresentation(try input(retained, availability: availability), now: now)
            #expect(display.state.tone == .unknown)
            #expect(!display.capacity.isEmpty && !display.sensors.isEmpty && !display.runners.isEmpty)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let marker = "as of \(formatter.string(from: good.probedAt))"
            #expect(display.capacity.allSatisfy { $0.tone == .unknown && $0.stale == marker })
            #expect(display.sensors.allSatisfy { $0.tone == .unknown && $0.stale == marker })
            #expect(display.sensorDetails.allSatisfy { $0.tone == .unknown && $0.stale == marker })
            #expect(display.runners.allSatisfy { $0.tone == .unknown && $0.state == "unknown, box offline" })
            #expect(display.capacity.first { $0.label == "rx slots" }?.value == "1 of 3")
            #expect(display.sensors.first { $0.id == "health" }?.value == "OK")
            #expect(display.lastProbe != "never probed")
            #expect(display.lastProbe != "probed just now")
        }
    }

    @Test func onlineCardKeepsCurrentCapacitySensorAndGreenRunnerPresentation() throws {
        let good = lastGood()
        let input = try input(good, availability: .online(address: "100.64.0.10"))
        let display = DestinationCardPresentation(input, now: now)
        #expect(display.state.text == "online" && display.state.tone == .ok)
        #expect(display.capacity.first { $0.label == "rx slots" }?.value == "1 of 3")
        #expect(display.capacity.first { $0.label == "rx slots" }?.tone == .plain)
        #expect(display.sensors.first { $0.id == "health" }?.tone == .ok)
        #expect(display.runners.count == 1)
        #expect(display.runners.first?.state == "online" && display.runners.first?.tone == .ok)
        #expect(display.capacity.first { $0.label == "cpu" }?.value == "24 cores")
        #expect(display.capacity.first { $0.label == "load" }?.value == "6.4")
        #expect(display.sensors.first { $0.id == "temp" }?.value == "42 C")
        #expect(display.sensors.first { $0.id == "temp" }?.tone == .plain)
        let fresh = DestinationCardPresentation(input, now: good.probedAt)
        #expect(fresh.capacity.allSatisfy { $0.stale == nil })
        #expect(fresh.sensors.allSatisfy { $0.stale == nil })
        #expect(fresh.runners.first?.tone == .ok)
    }

    private func input(_ probe: DestinationProbeResult, availability: Availability) throws -> DestinationCardInput {
        let demo = try #require(DemoShots.snapshot().destinations.first)
        var config = demo.config
        config.maxJobs = 3
        let runner = RunnerContainer(name: "runner-one", id: "runner-id", image: "gh-runner:2.330.0",
                                     state: "running", status: "Up 6 hours")
        return DestinationCardInput(name: "box", config: config, availability: availability, probe: probe,
            runners: [.init(container: runner, cpu: "1%", memory: "100MiB / 1GiB")], pollInterval: 10, history: [probe])
    }

    private func lastGood() -> DestinationProbeResult {
        let at = now.addingTimeInterval(-90)
        var result = DestinationProbeResult(availability: .online(address: "100.64.0.10"),
            docker: .ok("27.3.1", at: at), rsync: .ok("3.2.7", at: at), images: .ok(["swift:6"], at: at),
            containers: .ok([ContainerSample(name: "rx-build", cpu: "1%", memory: "1MiB / 2GiB")], at: at),
            cores: 24, memoryFreeMB: 26624, memoryTotalMB: 36864, diskTotalMB: 1030000, diskFreeMB: 300000,
            osName: "Linux", load: 6.4, bootID: "boot-first", uptime: 129600, clockOffsetMS: 0, probedAt: at)
        result.sensors = SensorSnapshot(kind: .bareMetal, swapTotalMB: 2048, swapUsedMB: 512,
            hottestC: 42, fansRPM: [1200], diskHealth: DiskHealth(readOnly: false, inodePercent: 42,
                                                               ioErrors: 0, smartPassed: true))
        return result
    }
}
