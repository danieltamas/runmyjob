import Testing
import Foundation
import RMJCore

struct PanelAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 1_792_938_600)

    private func job(_ state: JobState = .running, id: String = "rx", age: Double = 262) -> JobRecord {
        JobRecord(id: id, repo: "acme/orbit", command: "cargo test", location: "box-a",
                  destination: "box-a", state: state, queuedAt: now.addingTimeInterval(-age))
    }

    private func info(_ changes: [String: Any] = [:]) throws -> GitHubJobInfo {
        var json: [String: Any] = ["repo": "acme/atlas", "name": "test", "runId": 1001, "jobId": 2002,
            "runAttempt": 1, "status": "in_progress", "labels": ["self-hosted", "linux", "atlas"],
            "currentStep": "cargo test", "currentStepNumber": 3, "stepsDone": 2, "stepsTotal": 7,
            "waitingOnDependency": false]
        json.merge(changes) { _, new in new }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubJobInfo.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func has(_ row: JobRowPresentation, _ text: String, _ tone: JobRowPresentation.Tone? = nil) -> Bool {
        row.meta.contains { $0.text == text && (tone == nil || $0.tone == tone) }
    }

    @Test func runningRowsCarryIdentityTimingAndGitHubStep() throws {
        var rx = job()
        rx.branch = "feat/router"; rx.worktree = "router"; rx.commit = "a1b2c3d4abcd"; rx.dirty = true
        rx.startedAt = now.addingTimeInterval(-250)
        let row = JobRowPresentation(rx, now: now, lastOutputAt: now.addingTimeInterval(-3))
        #expect(row.title == "acme/orbit")
        #expect(row.branch == "feat/router" && row.worktree == "router")
        #expect(row.commit == "a1b2c3d" && row.dirty)
        #expect(row.location.text == "box-a")
        #expect(row.stateChip.text == "running" && row.stateChip.tone == .running)
        #expect(has(row, "4m 10s", .running) && has(row, "last output 3s ago"))
        #expect(row.actions.isEmpty)
        let stale = JobRowPresentation(rx, now: now, lastOutputAt: now.addingTimeInterval(-61))
        #expect(stale.meta.contains { $0.text.hasPrefix("last output") && $0.tone == .warn })
        rx.github = try info().json
        let gh = JobRowPresentation(rx, now: now)
        #expect(gh.worktree == nil && gh.agent == .github && gh.location.text == "github")
        #expect(has(gh, "step 3/7 cargo test"))
    }

    @Test func syncingAndQueueReasonsRemainDistinct() throws {
        var rx = job(.syncing)
        rx.syncStartedAt = now.addingTimeInterval(-12)
        #expect(has(JobRowPresentation(rx, now: now), "syncing 12s", .running))
        rx.state = .queued
        #expect(has(JobRowPresentation(rx, now: now, waitingFor: "rx-42"), "waiting for rx-42"))
        #expect(has(JobRowPresentation(rx, now: now), "probing box-a"))
        #expect(JobRowPresentation(rx, now: now).stateChip.tone == .warn)
        rx.queuedAt = now.addingTimeInterval(-60)
        #expect(JobRowPresentation(rx, now: now).stateChip.tone == .unknown)
        rx.queuedAt = now.addingTimeInterval(-180)
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-15))
        var observation: [String: Any] = ["labels": ["self-hosted", "linux", "atlas"],
            "matches": [["name": "bf459794a71f", "state": "offline idle"]], "observedAt": stamp,
            "suspectedCause": "stale registration", "summary": "0 online, 1 offline idle (bf459794a71f)"]
        rx.github = try info(["observation": observation]).json
        let queued = JobRowPresentation(rx, now: now)
        #expect(has(queued, "waiting 3 min"))
        #expect(has(queued, "self-hosted, linux, atlas"))
        #expect(has(queued, "0 online, 1 offline idle, observed 15s ago"))
        #expect(!queued.meta.contains { $0.text.contains("(bf459794a71f)") })
        #expect(has(queued, "stale registration bf45...", .warn))
        observation["suspectedCause"] = "unknown"
        rx.github = try info(["observation": observation]).json
        #expect(has(JobRowPresentation(rx, now: now), "cause unknown"))
        rx.github = try info(["observation": observation, "waitingOnDependency": true]).json
        let dependency = JobRowPresentation(rx, now: now)
        #expect(dependency.meta.contains { $0.text.hasPrefix("waiting on ") })
        #expect(!dependency.meta.contains { $0.text.contains("observed") || $0.text.contains("cause") })
    }

    @Test func settledRowsKeepOutcomeSeparateFromLocalFallback() throws {
        var rx = job(.done)
        rx.boxStartedAt = now.addingTimeInterval(-400); rx.boxEndedAt = now.addingTimeInterval(-25)
        var row = JobRowPresentation(rx, now: now)
        #expect(has(row, "6m 15s, box", .ok) && row.meta.count == 1 && row.actions.isEmpty)
        rx.warmth = "warm"
        #expect(has(JobRowPresentation(rx, now: now), "warm"))
        rx.state = .failed; rx.exitCode = 101
        row = JobRowPresentation(rx, now: now)
        #expect(has(row, "failed, exit 101") && has(row, "6m 15s, box"))
        #expect(row.actions == [.log, .rerun])
        rx.location = "local"; rx.fallbackReason = "tailnet down"; rx.environment = "mac"
        row = JobRowPresentation(rx, now: now)
        #expect(row.stateChip.text == "failed" && row.stateChip.tone == .crit)
        #expect(row.location.tone == .local && row.locationKind == .local)
        #expect(has(row, "local: tailnet down") && has(row, "environment: mac"))
        rx.state = .lost
        row = JobRowPresentation(rx, now: now)
        #expect(row.stateChip.text == "lost" && row.stateChip.tone == .crit)
        #expect(has(row, "lost: destination unreachable") && row.actions == [.log, .rerun])
        rx.state = .cancelled
        row = JobRowPresentation(rx, now: now)
        #expect(row.actions == [.log, .rerun] && row.stateChip.tone == .unknown)
        rx.state = .skipped; rx.github = try info(["conclusion": "neutral"]).json
        #expect(has(JobRowPresentation(rx, now: now), "neutral"))
    }

    @Test func sectionsUseUTCDaysAndNewestQueuedTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var records = [job(.running, id: "run", age: 30), job(.syncing, id: "sync", age: 10), job(.queued, id: "q")]
        for (id, age) in [("today-old", 3600.0), ("today-new", 600.0), ("yesterday", 86400.0), ("earlier", 259200.0)] {
            var record = job(.done, id: id, age: age)
            record.endedAt = record.queuedAt.addingTimeInterval(1)
            records.append(record)
        }
        let groups = records.reversed().panelRows(now: now, calendar: calendar)
        #expect(groups.map { $0.0 } == [.running, .queued, .today, .yesterday, .earlier])
        #expect(groups[0].1.map(\.id) == ["sync", "run"])
        #expect(groups[2].1.map(\.id) == ["today-new", "today-old"])
        #expect([JobRecord]().panelRows(now: now, calendar: calendar).isEmpty)
        #expect([records[0]].panelRows(now: now, calendar: calendar).count == 1)
    }

    @Test func detailUsesMeasuredSegmentsProvenanceAndSafeURLs() throws {
        var rx = job(.done, age: 100)
        rx.syncStartedAt = now.addingTimeInterval(-90); rx.syncEndedAt = now.addingTimeInterval(-80)
        rx.startedAt = now.addingTimeInterval(-80); rx.endedAt = now
        rx.boxStartedAt = now.addingTimeInterval(-79); rx.boxEndedAt = now.addingTimeInterval(-1)
        let detail = JobRowPresentation(rx, now: now).detail
        #expect(detail.timeline.map(\.label) == ["queued", "sync", "run"])
        #expect(detail.timeline.map(\.seconds) == [10, 10, 78])
        #expect(detail.timestamps.contains { $0.hasPrefix("queued ") && $0.hasSuffix("(mac)") })
        #expect(detail.timestamps.contains { $0.hasPrefix("box start ") && $0.hasSuffix("(box)") })
        #expect(!detail.canCancel && !detail.isGitHub && detail.url == nil)
        #expect(JobRowPresentation(job(), now: now).detail.timeline.isEmpty)
        for state in JobState.allCases {
            let row = JobRowPresentation(job(state), now: now)
            #expect(row.detail.canCancel == [.queued, .syncing, .running].contains(state))
        }
        for url in ["https://github.com/acme/atlas/actions/runs/1", "http://example.test", "javascript:alert(1)"] {
            rx.state = .running; rx.github = try info(["htmlUrl": url]).json
            let gh = JobRowPresentation(rx, now: now).detail
            #expect(gh.isGitHub && !gh.canCancel)
            #expect(gh.url?.absoluteString == (url.hasPrefix("https:") ? url : nil))
        }
    }

    @Test func iconTailnetAndFooterPriorities() throws {
        for standing in [TailnetState.Standing.stopped, .needsLogin, .noClient, .unknown("test")] {
            #expect(MenuBarIconState.resolve(tailnet: standing, running: 3, unseenFailure: true) == .tailnetDown)
        }
        #expect(MenuBarIconState.resolve(tailnet: .running, running: 3, unseenFailure: true) == .failed)
        #expect(MenuBarIconState.resolve(tailnet: .running, running: 3, unseenFailure: false) == .running(3))
        #expect(MenuBarIconState.running(3).countLabel == "3")
        #expect(MenuBarIconState.running(12).countLabel == "9+")
        #expect(MenuBarIconState.resolve(tailnet: .running, running: 0, unseenFailure: false) == .idle)
        let up = TailnetChip(DemoShots.tailnet(), now: now)
        #expect(up.text == "tailnet up" && up.tone == .ok)
        for standing in [TailnetState.Standing.stopped, .needsLogin] {
            #expect(TailnetChip(DemoShots.tailnet(standing: standing), now: now).text == "tailnet down")
        }
        #expect(TailnetChip(DemoShots.tailnet(standing: .noClient), now: now).text == "no client")
        for expiring in [true, false] {
            var peer: [String: Any] = ["ID": "fake", "Online": true, "Relay": "fra"]
            if expiring { peer["KeyExpiry"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 86400)) }
            let data = try JSONSerialization.data(withJSONObject: ["BackendState": "Running", "Self": ["Online": true], "Peer": ["fake": peer]])
            let chip = TailnetChip(TailnetState.parse(data, readAt: now), now: now)
            #expect(chip.text == (expiring ? "key expires in 3 d" : "relayed"))
            #expect(chip.tone == .warn)
        }
        for budget in [499, 500, 501] {
            let footer = PanelFooter(githubPolledAt: now.addingTimeInterval(-12), boxesPolledAt: now.addingTimeInterval(-30), rateRemaining: budget, now: now)
            #expect(footer.polls == ["GitHub 12s", "boxes 30s"])
            #expect(footer.rateBudget == (budget < 500 ? "rate budget 499" : nil))
        }
    }

    @Test func formattingPreservesCommandEnds() {
        #expect(PanelFormat.duration(12) == "12s")
        #expect(PanelFormat.duration(375) == "6m 15s")
        #expect(PanelFormat.duration(3720) == "1h 2m")
        #expect(PanelFormat.wait(180) == "3 min")
        let command = "cargo test " + String(repeating: "x", count: 43) + " --no-fail-fast!"
        #expect(command.count == 70)
        let short = PanelFormat.middleTruncated(command, limit: 40)
        #expect(short.count <= 40 && short.hasPrefix("cargo test") && short.hasSuffix("--no-fail-fast!"))
        #expect(PanelFormat.middleTruncated("cargo test", limit: 40) == "cargo test")
    }

    @Test func destinationCapacityStalenessAndActions() throws {
        let snapshot = DemoShots.snapshot()
        var online = try #require(snapshot.destinations.first)
        let card = DestinationCardPresentation(online, now: now)
        #expect(card.state.text == "online" && card.state.tone == .ok)
        #expect(card.roles == ["rx", "runners"])
        #expect(card.capacity.contains { $0.label == "rx slots" && $0.value == "1 of 3" })
        // 12 GiB rx limit plus 2.4 and 0.4 GiB runner use, rounded for display.
        #expect(card.capacity.contains { $0.label == "memory budget" && $0.value == "15 GB of 36 GB" })
        #expect(card.capacity.allSatisfy { $0.stale == nil })
        #expect(card.runners.contains { $0.state == "busy" && $0.detail.contains("job gh-2002") })
        for runner in card.runners {
            #expect(runner.detail.contains("version \(runner.version)"))
            #expect(runner.detail.contains("latest 2.340.0, served until 2026-11-20"))
        }
        // Set one runner to the latest version to distinguish current from behind.
        online.latestRunner = (card.runners[0].version, "2026-11-20")
        let current = DestinationCardPresentation(online, now: now)
        #expect(!current.runners[0].detail.contains("latest"))
        #expect(current.runners[1].detail.contains("latest"))
        let offline = try #require(snapshot.cards.last)
        #expect(offline.state.text.hasPrefix("offline") && offline.state.tone == .unknown)
        #expect(!offline.capacity.isEmpty)
        #expect(offline.capacity.allSatisfy { $0.stale?.range(of: #"^as of [0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil })
        for action in offline.actions {
            #expect(action.available == (action.action != .rebuild))
            if action.action == .rebuild { #expect(action.reason == "peer offline since 14:43") }
        }
        #expect(Set(offline.actions.map { $0.action.rawValue }) == ["Prune", "Cached logs", "Rebuild"])
        online.availability = .rejected("not a tailnet address")
        #expect(DestinationCardPresentation(online, now: now).state.tone == .crit)
    }

    @Test func routingOrderTenantDenyLabelsAndNewestExplain() throws {
        let snapshot = DemoShots.snapshot()
        let state = try #require(snapshot.rulesState)
        let rules = try #require(state.rules)
        var older = job(id: "older", age: 100)
        older.repo = "acme/old"
        let newer = job(id: "newer", age: 10)
        var jobs = [older, newer]
        for (repo, labels) in [("acme/atlas", ["self-hosted", "linux"]), ("nobody/none", ["self-hosted"]), ("cloud/only", ["ubuntu-latest"])] {
            var gh = job(.queued, id: repo)
            gh.command = "ci / test"; gh.github = try info(["repo": repo, "labels": labels]).json
            jobs.append(gh); jobs.append(gh)
        }
        let view = RoutingPresentation(state: state, jobs: jobs)
        #expect(view.rules.map(\.name) == rules.rules.map(\.name))
        for (line, rule) in zip(view.rules, rules.rules) {
            #expect(line.chain.map(\.name) == rule.to)
            #expect(line.chain.allSatisfy { $0.isLocal == ($0.name == "local") })
            #expect(line.environment == (rule.image ?? rule.profile))
        }
        #expect(view.denyText.contains("acme -> ai-eu-1") && view.denyText.contains("globex -> globex-s1"))
        #expect(view.labels.count == 3)
        #expect(view.labels.first { $0.repo == "acme/atlas" }?.served == ["ai-eu-1"])
        #expect(view.labels.first { $0.repo == "nobody/none" }?.mismatch == true)
        #expect(view.labels.first { $0.repo == "cloud/only" }?.served == ["github-hosted"])
        #expect(view.explainRepo == newer.repo && view.explainCommand == newer.command && view.explainSource == "from job newer")
        let invalid = RoutingPresentation(state: .invalid(path: "/fake/rules.json", message: "bad JSON"), jobs: jobs)
        #expect(invalid.problem?.message == "bad JSON" && invalid.problem?.path == "/fake/rules.json")
        #expect(invalid.rules.isEmpty && invalid.labels.isEmpty)
    }

    @Test func logTailReadsOnlyTemporaryHomeAndSanitizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = RMJHome(environment: ["RMJ_HOME": directory.path])
        let logs = directory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let text = (1...100).map { "\u{1B}[31mline \($0)\u{1B}[0m\u{200B}" }.joined(separator: "\n") + "\n"
        let final = logs.appendingPathComponent("fake.log")
        let part = logs.appendingPathComponent("fake.log.part")
        try Data(text.utf8).write(to: final)
        #expect(LogTail.read(jobID: "fake", home: home) == .lines((61...100).map { "line \($0)" }))
        try FileManager.default.moveItem(at: final, to: part)
        #expect(LogTail.read(jobID: "fake", home: home) == .lines((61...100).map { "line \($0)" }))
        try FileManager.default.removeItem(at: part)
        #expect(LogTail.read(jobID: "fake", home: home) == .note("pending"))
    }
}
