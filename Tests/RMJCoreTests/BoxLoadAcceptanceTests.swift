import Foundation
import Testing
@testable import RMJCore

struct BoxLoadAcceptanceTests {
    @Test func parsesSingleContainer() throws {
        let load = try #require(BoxLoad.parse("236.40% 1.352GiB / 31.3GiB"))
        #expect(abs(load.cpuPercent - 236.4) < 0.0001)
        #expect(abs(Double(load.memoryBytes) - 1.352 * 1_073_741_824) <= 1)
    }

    @Test func sumsContainers() {
        #expect(BoxLoad.parse("100.00% 1GiB / 4GiB\n25.50% 512MiB / 4GiB") ==
                JobLoad(cpuPercent: 125.5, memoryBytes: 1_610_612_736))
    }

    @Test func convertsBinaryAndDecimalMemoryUnits() {
        let cases: [(String, Int64)] = [
            ("2B", 2), ("2KiB", 2_048), ("2MiB", 2_097_152),
            ("2GiB", 2_147_483_648), ("2TiB", 2_199_023_255_552),
            ("2kB", 2_000), ("2MB", 2_000_000), ("2GB", 2_000_000_000)
        ]
        for (memory, bytes) in cases {
            #expect(BoxLoad.parse("1% \(memory) / 4TiB") == JobLoad(cpuPercent: 1, memoryBytes: bytes))
        }
    }

    @Test func rejectsEveryUnreadableLine() {
        for text in ["garbage", "--", "10%", "10% -- / 1GiB", "NaN% 1GiB / 2GiB",
                     "-1% 1GiB / 2GiB", "1% -1GiB / 2GiB", "1% NaNGiB / 2GiB"] {
            #expect(BoxLoad.parse(text) == nil, "Input: \(text)")
            #expect(BoxLoad.parse("1% 1MiB / 2GiB\n" + text) == nil)
        }
    }

    @Test func emptyInputIsUnknown() {
        #expect(BoxLoad.parse("") == nil)
        #expect(BoxLoad.parse("  \n") == nil)
    }

    @Test func zeroLoadIsAReading() {
        #expect(BoxLoad.parse("0.00% 0B / 0B") == JobLoad(cpuPercent: 0, memoryBytes: 0))
    }

    @Test func boxRunStoresMeanOfActualReadingsAndReportShowsResources() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        let box = LoadBox(readings: [JobLoad(cpuPercent: 100, memoryBytes: 1_000_000_000),
                                     JobLoad(cpuPercent: 200, memoryBytes: 3_000_000_000)], minimumLoadCalls: 3)
        let result = await engine(f, box: box).run(f.request())
        let row = try #require(try await f.ledger.job(result.jobID))
        #expect(row.location == "ai-eu-1" && row.state == .done)
        let samples = await box.returned
        #expect(samples.count == 2)
        #expect(await box.calls > samples.count)
        #expect(await box.ids.allSatisfy { $0 == result.jobID })
        let cpu = try #require(row.avgCPU)
        let memory = try #require(row.avgMemoryBytes)
        let meanCPU = samples.map(\.cpuPercent).reduce(0, +) / Double(samples.count)
        let meanMemory = samples.map(\.memoryBytes).reduce(0, +) / Int64(samples.count)
        #expect(cpu >= 100 && cpu <= 200)
        #expect(memory >= 1_000_000_000 && memory <= 3_000_000_000)
        #expect(abs(cpu - meanCPU) < 0.0001)
        #expect(memory == meanMemory)
        let report = RunReport(row, now: runNow)
        let resources = try #require(report.sections.first { $0.title == "Resources" })
        #expect(resources.facts.first { $0.label == "Avg CPU" }?.value == String(format: "%.0f%%", cpu))
        #expect(resources.facts.first { $0.label == "Avg memory" }?.value ==
                ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory))
    }

    @Test func nilSamplesLeaveResourceAveragesUnknown() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        let box = LoadBox(readings: [], minimumLoadCalls: 2)
        let result = await engine(f, box: box).run(f.request())
        let row = try #require(try await f.ledger.job(result.jobID))
        #expect(row.location == "ai-eu-1" && row.state == .done)
        #expect(await box.calls > 0)
        #expect(row.avgCPU == nil && row.avgMemoryBytes == nil)
    }

    @Test func runEndingBeforeFirstIntervalLeavesAveragesUnknown() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        let box = LoadBox(readings: [JobLoad(cpuPercent: 100, memoryBytes: 1)], delay: .zero)
        let result = await engine(f, box: box, interval: .seconds(10)).run(f.request())
        let row = try #require(try await f.ledger.job(result.jobID))
        #expect(row.location == "ai-eu-1" && row.state == .done)
        #expect(await box.calls == 0)
        #expect(row.avgCPU == nil && row.avgMemoryBytes == nil)
    }

    @Test func settleWritesLoadAndNilResettlementPreservesIt() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        let id = try await f.insert()
        let job = try #require(try await f.ledger.job(id))
        let record = BoxRecord(containerPresent: false, bootID: "boot", result: .init(code: 0))
        let load = JobLoad(cpuPercent: 150, memoryBytes: 2_000_000_000)
        _ = await Reconciler.settle(job, record: record, result: .init(code: 0), ledger: f.ledger,
                                    archive: f.archive, now: runNow, load: load)
        let settled = try #require(try await f.ledger.job(id))
        #expect(settled.avgCPU == load.cpuPercent && settled.avgMemoryBytes == load.memoryBytes)
        _ = await Reconciler.settle(settled, record: record, result: .init(code: 0), ledger: f.ledger,
                                    archive: f.archive, now: runNow, load: nil)
        let again = try #require(try await f.ledger.job(id))
        #expect(again.avgCPU == load.cpuPercent && again.avgMemoryBytes == load.memoryBytes)
    }

    private func engine(_ f: RunFixture, box: LoadBox, interval: Duration = .milliseconds(100)) -> RunEngine {
        let boxes = BoxDirectory(rules: f.boxes.rules, tailnet: f.boxes.tailnet, factory: LoadFactory(box: box))
        return RunEngine(ledger: f.ledger, archive: f.archive, router: f.router, boxes: boxes, probes: f.probes,
                         output: f.output.add, notice: f.notices.notice,
                         profiles: ProfileStore(home: RMJHome(environment: ["RMJ_HOME": f.root.path])),
                         boxLoadInterval: interval)
    }
}

private struct LoadFactory: BoxFactory {
    let box: LoadBox
    func client(destination: String, address: String, config: DestinationConfig) -> BoxClient { box }
}

// Same transport boundary as RunBox; only tail duration and load readings differ.
private actor LoadBox: BoxClient {
    let readings: [JobLoad]
    let delay: Duration
    let minimumLoadCalls: Int
    private(set) var calls = 0
    private(set) var returned: [JobLoad] = []
    private(set) var ids: [String] = []

    init(readings: [JobLoad], delay: Duration = .milliseconds(550), minimumLoadCalls: Int = 0) {
        self.readings = readings
        self.delay = delay
        self.minimumLoadCalls = minimumLoadCalls
    }
    func prepare(_ job: BoxJob) async throws {}
    func begin(_ job: BoxJob, waiting: @escaping @Sendable (String) -> Void) async throws {}
    func sync(_ job: BoxJob) async throws {}
    func go(_ job: BoxJob) async throws -> BoxLaunch { .started(container: "container", bootID: "boot") }
    func tail(_ job: BoxJob, output: @escaping @Sendable (Data) -> Void) async throws {
        if minimumLoadCalls > 0 {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while calls < minimumLoadCalls {
                guard clock.now < deadline else { throw LoadWaitError.timedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
        } else {
            try await Task.sleep(for: delay)
        }
        output(Data("box output\n".utf8))
    }
    func load(ulid: String) async -> JobLoad? {
        ids.append(ulid)
        let index = calls
        calls += 1
        guard readings.indices.contains(index) else { return nil }
        let sample = readings[index]
        returned.append(sample)
        return sample
    }
    func record(ulid: String) async throws -> BoxRecord {
        BoxRecord(containerPresent: false, bootID: "boot", launch: .started(container: "container", bootID: "boot"),
                  result: .init(code: 0))
    }
    func pullLog(ulid: String, output: @escaping @Sendable (Data) -> Void) async throws {
        output(Data("box output\n".utf8))
    }
    func cancel(ulid: String) async throws {}

    private enum LoadWaitError: Error { case timedOut }
}
