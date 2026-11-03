import Foundation
import Testing
@testable import RMJCore

private actor CapacityProbes: ProbeProvider {
    let samples: [DestinationProbeResult]
    private var index = 0
    init(_ samples: [DestinationProbeResult]) { self.samples = samples }
    func latest(for destination: String) async -> DestinationProbeResult? {
        let sample = samples[min(index, samples.count - 1)]
        index += 1
        return sample
    }
    func probe(_ target: DestinationTarget, tailnet: TailnetState) async -> DestinationProbeResult {
        await latest(for: target.alias)!
    }
}

private struct CapacityFixture {
    let run: RunFixture
    let router: Router
    let probes: CapacityProbes
    let reason: String

    static func make(memory: Bool = false, frees: Bool = false, offline: Bool = false) async throws -> Self {
        let run = try await RunFixture.make()
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tailnet/running.json").path
        let tailnet = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: runNow)
        var rules = try JSONDecoder().decode(Rules.self, from: Data(Rules.shippedJSON
            .replacingOccurrences(of: "nAcmeBox0001CNTRL", with: "n-ai-acme-1").utf8))
        rules.rules = [try JSONDecoder().decode(Rule.self, from: Data("""
        {"name":"acceptance","match":{"command":["sh","echo"]},"to":["ai-eu-1"],"image":"rx-rust","memory":"2g"}
        """.utf8))]
        rules.destinations["ai-eu-1"]?.maxJobs = 1
        rules.destinations["ai-eu-1"]?.memoryBudget = "4g"
        func sample(_ full: Bool) -> DestinationProbeResult {
            let containers = full ? [ContainerSample(name: memory ? "runner-busy" : "rx-busy", cpu: "0%",
                                                     memory: "4GiB / 4GiB")] : []
            return DestinationProbeResult(availability: offline ? .offline("test box offline") : .online(address: "100.64.0.10"),
                docker: .ok("27.3.1", at: runNow), rsync: .ok("3.2.7", at: runNow),
                images: .ok(["rx-rust:latest"], at: runNow), containers: .ok(containers, at: runNow),
                cores: 24, memoryFreeMB: 40000, memoryTotalMB: nil, diskTotalMB: nil, diskFreeMB: nil,
                osName: nil, load: 0.5, bootID: "boot", uptime: 3600, clockOffsetMS: 0, probedAt: runNow)
        }
        let probes = CapacityProbes(frees ? [sample(true), sample(false)] : [sample(true)])
        let router = Router(rules: .valid(rules, fingerprint: "capacity"), tailnet: tailnet, probes: probes,
                            fileExists: { _ in true }, now: { runNow })
        return Self(run: run, router: router, probes: probes,
                    reason: memory ? "ai-eu-1 over memory budget" : "ai-eu-1 at max_jobs (1/1)")
    }

    func engine(poll: Duration = .milliseconds(50)) -> RunEngine {
        RunEngine(ledger: run.ledger, archive: run.archive, router: router, boxes: run.boxes, probes: probes,
                  output: run.output.add, notice: run.notices.notice,
                  profiles: ProfileStore(home: RMJHome(environment: ["RMJ_HOME": run.root.path])),
                  boxLoadInterval: poll, now: { runNow })
    }
}

struct CapacityWaitAcceptanceTests {
    @Test(arguments: [false, true]) func fullThenFreeRunsOnBox(memory: Bool) async throws {
        let f = try await CapacityFixture.make(memory: memory, frees: true)
        defer { f.run.remove() }
        let started = ContinuousClock.now
        let result = await f.engine().run(f.run.request(["sh", "-c", "touch must-not-run-on-mac"]))
        let row = try #require(try await f.run.ledger.job(result.jobID))
        #expect(started.duration(to: .now) >= .milliseconds(50))
        #expect(result.exitCode == 0 && result.state == .done)
        #expect(row.location == "ai-eu-1" && row.environment == "box" && row.fallbackReason == nil)
        #expect(await f.run.box.jobs.count == 1)
        #expect(!FileManager.default.fileExists(atPath: f.run.root.appendingPathComponent("must-not-run-on-mac").path))
        #expect(f.run.notices.text == "rmj: waiting for room on the box: \(f.reason)\n")
    }

    @Test func offlineFallsBackWithoutWaiting() async throws {
        let f = try await CapacityFixture.make(offline: true)
        defer { f.run.remove() }
        let started = ContinuousClock.now
        let result = await f.engine(poll: .seconds(30)).run(f.run.request(["echo", "local offline"]))
        let row = try #require(try await f.run.ledger.job(result.jobID))
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(result.exitCode == 0 && row.location == "local" && row.environment == "mac")
        #expect(row.fallbackReason == "ai-eu-1 offline (test box offline)")
        #expect(f.run.output.text == "local offline\n")
        #expect(f.run.notices.text.isEmpty)
        #expect(await f.run.box.jobs.isEmpty)
    }

    @Test func forceLocalDoesNotWaitForFullBox() async throws {
        let f = try await CapacityFixture.make()
        defer { f.run.remove() }
        var request = f.run.request(["echo", "forced local"])
        request.forceLocal = true
        let started = ContinuousClock.now
        let result = await f.engine(poll: .seconds(30)).run(request)
        let row = try #require(try await f.run.ledger.job(result.jobID))
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(result.exitCode == 0 && row.location == "local" && row.environment == "mac")
        #expect(row.fallbackReason == "forced")
        #expect(f.run.output.text == "forced local\n")
        #expect(f.run.notices.text.isEmpty)
        #expect(await f.run.box.jobs.isEmpty)
    }

    @Test(arguments: [false, true]) func capacityLimitReturnsLastDecision(memory: Bool) async throws {
        let f = try await CapacityFixture.make(memory: memory)
        defer { f.run.remove() }
        let request = RouteRequest(command: ["echo", "capacity"], identity: f.run.request().identity)
        let expected = await f.router.route(request).sanitized()
        let started = ContinuousClock.now
        let decision = await CapacityWait.route(request, router: f.router, poll: .milliseconds(50),
                                               limit: .milliseconds(300), notice: f.run.notices.notice)
        let elapsed = started.duration(to: .now)
        #expect(elapsed >= .milliseconds(300) && elapsed < .seconds(5))
        #expect(decision == expected)
        #expect(decision.location == .local && decision.fallbackReason == f.reason)
        #expect(f.run.notices.text == "rmj: waiting for room on the box: \(f.reason)\n")
    }
}
