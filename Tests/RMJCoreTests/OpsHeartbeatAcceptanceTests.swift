import Testing
import Foundation
import RMJCore

private func u6Tailnet(_ name: String = "running") throws -> TailnetState {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/tailnet/\(name).json")
    return TailnetState.parse(try Data(contentsOf: url), readAt: u6Now)
}

private struct U6ProbeTransport: RemoteTransport {
    let missing: String?
    func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput {
        u6Output("""
        @@docker rc=\(missing == "docker" ? 127 : 0)
        \(missing == "docker" ? "not found" : "27.3.1")
        @@rsync rc=\(missing == "rsync" ? 127 : 0)
        \(missing == "rsync" ? "not found" : "rsync version 3.2.7")
        @@images rc=0
        rx-rust:latest
        @@containers rc=0
        @@nproc rc=0
        24
        @@mem rc=0
        40000
        @@load rc=0
        0.5
        @@boot rc=0
        fixture-boot
        @@uptime rc=0
        3600
        @@clock rc=0
        1793102400000000000
        @@end
        """)
    }
}

private actor U6ProbeSpy: ProbeProvider {
    let result: DestinationProbeResult
    private(set) var targets: [DestinationTarget] = []
    init(result: DestinationProbeResult) { self.result = result }
    func latest(for destination: String) async -> DestinationProbeResult? { result }
    func probe(_ target: DestinationTarget, tailnet: TailnetState) async -> DestinationProbeResult {
        targets.append(target)
        return result
    }
}

private func u6Spy(missing: String? = nil) async throws -> U6ProbeSpy {
    let sample = await DestinationProbe(transport: U6ProbeTransport(missing: missing)).probe(
        DestinationTarget(alias: "ai-eu-1", peerID: "n-ai-acme-1"), tailnet: try u6Tailnet(), now: u6Now)
    return U6ProbeSpy(result: sample)
}

private func u6Draft(_ name: String = "new-fixture") -> DestinationDraft {
    DestinationDraft(name: name, peerID: "n-ai-acme-1", sshAlias: "ai-eu-1", tenant: "acme",
                     roles: ["rx", "runners"], home: "/home/fixture", maxJobs: 2, memoryBudget: "24g")
}

private func u6Store(_ f: U6Fixture) throws -> RulesStore {
    let home = RMJHome(environment: ["RMJ_HOME": f.directory.path])
    try home.prepare()
    try writeLedgerProfile(home: home)
    return RulesStore(home: home)
}

private func u6Failures(_ heartbeat: Heartbeat, _ count: Int) async throws {
    for _ in 0..<count { try await heartbeat.record(destination: "ai-eu-1", reachable: false) }
}

struct OpsHeartbeatAcceptanceTests {
    @Test func heartbeatMarksOnlyRxLostOnThirdFailureAndNotifiesOncePerOutage() async throws {
        let f = try U6Fixture(); defer { f.remove() }
        try await f.ledger.insert(f.job("rx-first"))
        try await f.ledger.insert(f.job("gh-77-1", github: true))
        let notifications = U6Messages()
        let heartbeat = Heartbeat(ledger: f.ledger, notify: { notifications.append($0) }, now: { u6Now })
        try await u6Failures(heartbeat, 2)
        #expect(try await f.ledger.job("rx-first")?.state == .running)
        #expect(try await f.ledger.job("gh-77-1")?.state == .running)
        #expect(notifications.values.isEmpty)
        try await u6Failures(heartbeat, 1)
        #expect(try await f.ledger.job("rx-first")?.state == .lost)
        let event = try #require(try await f.ledger.events("rx-first").last)
        #expect(event.detail == "destination unreachable" && event.at == u6Now)
        #expect(notifications.values.count == 1)
        try await u6Failures(heartbeat, 4)
        #expect(notifications.values.count == 1)
        #expect(try await f.ledger.job("gh-77-1")?.state == .running)
        try await heartbeat.record(destination: "ai-eu-1", reachable: true)
        try await f.ledger.insert(f.job("rx-second"))
        try await u6Failures(heartbeat, 2)
        #expect(try await f.ledger.job("rx-second")?.state == .running)
        #expect(notifications.values.count == 1)
        try await u6Failures(heartbeat, 1)
        #expect(try await f.ledger.job("rx-second")?.state == .lost)
        #expect(notifications.values.count == 2)
        #expect(try await f.ledger.job("gh-77-1")?.state == .running)
    }

    @Test func heartbeatSuccessAndWakeResetConsecutiveFailureCount() async throws {
        for wake in [false, true] {
            let f = try U6Fixture(); defer { f.remove() }
            try await f.ledger.insert(f.job("rx"))
            let notifications = U6Messages()
            let heartbeat = Heartbeat(ledger: f.ledger, notify: { notifications.append($0) }, now: { u6Now })
            try await u6Failures(heartbeat, 2)
            if wake { await heartbeat.wake() }
            else { try await heartbeat.record(destination: "ai-eu-1", reachable: true) }
            try await u6Failures(heartbeat, 1)
            #expect(try await f.ledger.job("rx")?.state == .running)
            #expect(notifications.values.isEmpty)
            try await u6Failures(heartbeat, 1)
            #expect(try await f.ledger.job("rx")?.state == .running)
            #expect(notifications.values.isEmpty)
            try await u6Failures(heartbeat, 1)
            #expect(try await f.ledger.job("rx")?.state == .lost)
            #expect(notifications.values.count == 1)
        }
    }

    @Test func heartbeatOutageWithoutRxJobsAffectsNewJobOnNextFailure() async throws {
        let f = try U6Fixture(); defer { f.remove() }
        try await f.ledger.insert(f.job("gh-77-1", github: true))
        var elsewhere = f.job("other-rx"); elsewhere.destination = "other-box"; elsewhere.location = "other-box"
        try await f.ledger.insert(elsewhere)
        let notifications = U6Messages()
        let heartbeat = Heartbeat(ledger: f.ledger, notify: { notifications.append($0) }, now: { u6Now })
        let before = try await f.ledger.jobs()
        try await u6Failures(heartbeat, 3)
        #expect(try await f.ledger.jobs() == before)
        #expect(notifications.values.isEmpty)
        try await f.ledger.insert(f.job("late-rx"))
        try await u6Failures(heartbeat, 1)
        #expect(try await f.ledger.job("late-rx")?.state == .lost)
        #expect(try await f.ledger.job("other-rx")?.state == .running)
        #expect(try await f.ledger.job("gh-77-1")?.state == .running)
        #expect(notifications.values.count == 1)
    }

    @Test func heartbeatLostJobReconcilesToDoneWithBoxTiming() async throws {
        // Reuse the existing all-fake BoxClient fixture without invoking RunEngine.
        let f = try await RunFixture.make(); defer { f.remove() }
        let id = try await f.insert()
        let heartbeat = Heartbeat(ledger: f.ledger, notify: { _ in }, now: { u6Now })
        try await u6Failures(heartbeat, 3)
        #expect(try await f.ledger.job(id)?.state == .lost)
        let start = runNow.addingTimeInterval(-4)
        await f.box.configure(answer: BoxRecord(containerPresent: false, bootID: "fixture-boot", result: .init(code: 0),
                                               meta: .init(started: start, finished: runNow, exit: 0)))
        await f.reconcile()
        let settled = try #require(try await f.ledger.job(id))
        #expect(settled.state == .done && settled.exitCode == 0)
        #expect(settled.boxStartedAt == start && settled.boxEndedAt == runNow && settled.boxExit == 0)
        #expect(settled.duration == .box(milliseconds: 4000))
    }

    @Test func onboardingOfflinePeerStopsBeforeProbeAndPreservesRulesBytes() async throws {
        for present in [false, true] {
            let f = try U6Fixture(); defer { f.remove() }
            let store = try u6Store(f)
            if present { try Data(Rules.shippedJSON.utf8).write(to: store.url) }
            let before = FileManager.default.contents(atPath: store.url.path)
            let spy = try await u6Spy()
            let report = await DestinationOnboarding(probes: spy, store: store).run(u6Draft(), tailnet: try u6Tailnet("peer-offline"))
            #expect(report.failedStep?.name == "reachability")
            #expect(report.failedStep?.detail.contains("offline") == true)
            #expect(!report.written)
            #expect(FileManager.default.contents(atPath: store.url.path) == before)
            #expect(await spy.targets.isEmpty)
        }
    }

    @Test func onboardingOnlinePeerWritesPeerIDAfterEveryCheckSucceeds() async throws {
        let f = try U6Fixture(); defer { f.remove() }
        let store = try u6Store(f)
        let spy = try await u6Spy()
        let draft = u6Draft()
        var rules = Rules.shipped
        rules.destinations.removeValue(forKey: "ai-eu-1")
        rules.rules = []
        try JSONEncoder().encode(rules).write(to: store.url)
        let report = await DestinationOnboarding(probes: spy, store: store).run(draft, tailnet: try u6Tailnet())
        #expect(report.written && report.failedStep == nil)
        #expect(!report.steps.isEmpty && report.steps.allSatisfy(\.ok))
        #expect(await spy.targets.count == 1)
        let config = try #require(store.load().rules?.destinations[draft.name])
        #expect(config.peerID == "n-ai-acme-1" && config.peerID != draft.sshAlias)
        #expect(config.sshAlias == draft.sshAlias && config.tenant == draft.tenant)
        #expect(config.home == draft.home && config.roles == draft.roles)
        #expect(config.maxJobs == draft.maxJobs && config.memoryBudget == draft.memoryBudget)
    }

    @Test func onboardingMissingToolsBadNamesAndInvalidRulesNeverWrite() async throws {
        for missing in ["docker", "rsync"] {
            let f = try U6Fixture(); defer { f.remove() }
            let store = try u6Store(f)
            try Data(Rules.shippedJSON.utf8).write(to: store.url)
            let before = try Data(contentsOf: store.url)
            let spy = try await u6Spy(missing: missing)
            let report = await DestinationOnboarding(probes: spy, store: store).run(u6Draft(), tailnet: try u6Tailnet())
            #expect(report.failedStep?.name == missing)
            #expect(report.failedStep?.hint?.isEmpty == false)
            #expect(!report.written)
            #expect(try Data(contentsOf: store.url) == before)
            #expect(await spy.targets.count == 1)
        }
        for name in ["", "ai-eu-1"] {
            let f = try U6Fixture(); defer { f.remove() }
            let store = try u6Store(f)
            try Data(Rules.shippedJSON.utf8).write(to: store.url)
            let before = try Data(contentsOf: store.url)
            let spy = try await u6Spy()
            let report = await DestinationOnboarding(probes: spy, store: store).run(u6Draft(name), tailnet: try u6Tailnet())
            #expect(report.failedStep?.name == "name" && !report.written)
            #expect(try Data(contentsOf: store.url) == before)
            #expect(await spy.targets.isEmpty)
        }
        let f = try U6Fixture(); defer { f.remove() }
        let store = try u6Store(f)
        let invalid = Data("{broken rules".utf8)
        try invalid.write(to: store.url)
        let spy = try await u6Spy()
        let report = await DestinationOnboarding(probes: spy, store: store).run(u6Draft(), tailnet: try u6Tailnet())
        #expect(report.failedStep?.name == "rules" && !report.written)
        #expect(try Data(contentsOf: store.url) == invalid)
        #expect(await spy.targets.isEmpty)
    }
}
