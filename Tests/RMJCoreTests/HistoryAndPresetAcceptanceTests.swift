import Testing
import Foundation
import RMJCore

private struct HistoryPresetFixture {
    let home: RMJHome
    let ledger: Ledger
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmj-history-presets-\(UUID().uuidString)")
        home = RMJHome(environment: ["RMJ_HOME": directory.path])
        try home.prepare()
        try writeLedgerProfile(home: home)
        ledger = Ledger(database: try Database(url: home.url.appendingPathComponent("rmj.sqlite")))
    }

    func remove() { try? FileManager.default.removeItem(at: home.url) }

    func insert(_ id: String, daysAgo: Double, state: JobState = .done) async throws {
        let at = now.addingTimeInterval(-daysAgo * 86_400)
        var job = JobRecord(id: id, repo: "owner/repo", command: "cargo test", location: "local",
                            environment: "mac", state: state, queuedAt: at.addingTimeInterval(-60))
        job.startedAt = at.addingTimeInterval(-30)
        if state.isSettled { job.endedAt = at }
        try await ledger.insert(job)
    }

    func snapshot() async throws -> PanelSnapshot {
        let tailnet = TailnetState.parse(Data(#"{"BackendState":"Stopped"}"#.utf8), readAt: now)
        return try await PanelLoader(home: home).snapshot(tailnet: tailnet, now: now)
    }
}

struct HistoryAndPresetAcceptanceTests {
    @Test func historySeparatesRecentExpiredAndUnsettledJobsAndGroupsEarlier() async throws {
        let fixture = try HistoryPresetFixture()
        defer { fixture.remove() }
        // Deliberately insert out of chronological order.
        try await fixture.insert("day-29", daysAgo: 29, state: .failed)
        try await fixture.insert("day-1", daysAgo: 1)
        try await fixture.insert("day-31", daysAgo: 31)
        try await fixture.insert("day-5", daysAgo: 5)
        for state in [JobState.running, .queued, .syncing, .lost] {
            try await fixture.insert(state.rawValue, daysAgo: 5, state: state)
        }

        let snapshot = try await fixture.snapshot()
        #expect(snapshot.history.map(\.id) == ["day-5", "day-29"])
        #expect(snapshot.jobs.contains { $0.id == "day-1" })
        #expect(snapshot.jobs.contains { $0.id == "running" })
        #expect(!snapshot.jobs.contains { ["day-5", "day-29", "day-31"].contains($0.id) })
        let sections = snapshot.historyRows
        #expect(sections.map { $0.0 } == [.earlier])
        #expect(sections.flatMap { $0.1 }.map(\.id) == ["day-5", "day-29"])
        #expect(sections.flatMap { $0.1 }.allSatisfy { $0.section == .earlier })
    }

    @Test func historyKeepsExactlyTheNewest200SettledJobs() async throws {
        let fixture = try HistoryPresetFixture()
        defer { fixture.remove() }
        // Increasing index means increasing age; reverse insertion defeats arrival-order sorting.
        for index in (0..<205).reversed() {
            try await fixture.insert("history-\(index)", daysAgo: 3 + Double(index) / 100)
        }
        try await fixture.insert("recent", daysAgo: 1)
        try await fixture.insert("expired", daysAgo: 31)
        try await fixture.insert("running", daysAgo: 3, state: .running)

        let snapshot = try await fixture.snapshot()
        #expect(snapshot.history.count == 200)
        #expect(snapshot.history.map(\.id) == (0..<200).map { "history-\($0)" })
    }

    @Test func presetsExposeToolchainsAndMatchRegardlessOfOrderAndSpacing() {
        #expect(RulePreset.rust.commands.contains("cargo"))
        for command in ["npm", "pnpm", "yarn", "bun"] {
            #expect(RulePreset.node.commands.contains(command))
        }
        #expect(RulePreset.anything.commands.isEmpty)
        for preset in RulePreset.allCases {
            let reordered = preset.commands.reversed().map { "  \($0)  " }.joined(separator: " , ")
            #expect(RulePreset.matching(command: reordered) == preset)
        }
        #expect(RulePreset.matching(command: "custom-build, custom-test") == nil)
        var draft = RuleDraft()
        draft.command = "custom-build"
        draft.apply(.swift)
        #expect(draft.command == RulePreset.swift.commands.joined(separator: ", "))
    }

    @Test func suggestedNamesDescribePresetAndFirstRemoteDestination() {
        var draft = RuleDraft()
        draft.apply(.rust)
        draft.to = "ai-eu-1, local"
        #expect(draft.suggestedName == "Rust builds on ai-eu-1")
        draft.apply(.anything)
        draft.to = "local"
        #expect(draft.suggestedName == "Builds locally")
        draft.command = "custom-build"
        draft.to = "ai-eu-1, local"
        #expect(draft.suggestedName == "Matching builds on ai-eu-1")
    }

    @Test func presetDraftAppendsAndRoundTripsCommandsAndDestinations() throws {
        let fixture = try HistoryPresetFixture()
        defer { fixture.remove() }
        let store = RulesStore(home: fixture.home)
        let fingerprint = try #require(RuleEditing.fingerprint(home: fixture.home))
        let rules = try RulesValidation.parse(Data(Rules.shippedJSON.utf8))
        #expect(rules.destinations["ai-eu-1"] != nil)
        try store.save(rules, expected: fingerprint)

        for preset in RulePreset.allCases {
            var draft = RuleDraft()
            draft.apply(preset)
            draft.to = "ai-eu-1, local"
            draft.name = "Acceptance \(preset.rawValue)"
            let expected = try #require(RuleEditing.fingerprint(home: fixture.home))
            try RuleEditing.apply(.append(try draft.rule(base: nil)), home: fixture.home, expected: expected)
            let loaded = try #require(store.load().rules)
            let saved = try #require(loaded.rules.last)
            #expect(saved.name == draft.name)
            #expect((saved.match.command ?? []) == preset.commands)
            #expect(saved.to == ["ai-eu-1", "local"])
        }
        #expect(try #require(store.load().rules).rules.count == rules.rules.count + RulePreset.allCases.count)
    }
}
