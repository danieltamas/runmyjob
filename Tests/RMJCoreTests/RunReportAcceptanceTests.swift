import Foundation
import Testing
import RMJCore

struct RunReportAcceptanceTests {
    @Test func classifierRecognizesEveryRuleAndPrecedence() {
        let cases: [(String, LogLine.Kind)] = [
            ("$ cargo fail", .command), ("$ warning passed", .command),
            ("error", .error), ("ERRORS", .error), ("fail", .error),
            ("Failed", .error), ("failure", .error), ("FATAL", .error),
            ("panic", .error), ("Exception", .error), ("error: bad", .error),
            ("FAILUREsuffix", .error), ("E: diagnostic", .error),
            ("\u{2718} test", .error), ("\u{2717} test", .error),
            ("warning error passed", .error), ("PASS error", .error),
            ("warn", .warning), ("WARNING", .warning), ("Warnings", .warning),
            ("deprecated", .warning), ("skip", .warning), ("SKIPPED", .warning),
            ("warning passed", .warning), ("PASS warning", .warning),
            ("PASSanything", .success), ("ok test", .success),
            ("\u{2714} test", .success), ("\u{2713} test", .success),
            ("PASSED", .success), ("Success", .success), ("succeeded", .success),
            ("", .plain), ("ordinary output", .plain)
        ]
        for (line, expected) in cases {
            #expect(LogClassifier.kind(of: line) == expected, "Input: \(line)")
        }
    }

    @Test func classifierZeroCountsDoNotHideRealFailures() {
        let cases: [(String, LogLine.Kind)] = [
            ("0 failed", .plain), ("0 errors", .plain), ("0 error", .plain),
            ("0 failures", .plain), ("0 FAILED, 0 ERRORS", .plain),
            ("5 passed, 0 failed", .success), ("0 passed, 8 failed", .error),
            ("0 errors, 1 failure", .error), ("0 failed; fatal", .error),
            ("0 errors; warning", .warning), ("10 failed", .error),
            ("100 errors", .error), ("0 failed, error: broken", .error)
        ]
        for (line, expected) in cases {
            #expect(LogClassifier.kind(of: line) == expected, "Input: \(line)")
        }
    }

    @Test func classifierUsesWholeWordsAndCaseSensitivePrefixes() {
        for line in ["terror", "failover", "failuresome", "warningly", "skipper",
                     "deprecatedThing", "successful", "bypassed", "pass", "passThing",
                     "OK test", "okay", "ok", "e: diagnostic", "failSuffix", " $ test"] {
            #expect(LogClassifier.kind(of: line) == .plain, "Input: \(line)")
        }
        #expect(LogClassifier.kind(of: "[error]: broken") == .error)
        #expect(LogClassifier.kind(of: "(warning)") == .warning)
        #expect(LogClassifier.kind(of: "test passed.") == .success)
    }

    @Test func missingLogReturnsNil() throws {
        let f = try ReportLogFixture()
        defer { f.remove() }
        #expect(LogDocument.load(jobID: "absent", home: f.home) == nil)
    }

    @Test func candidateOrderAndLiveFlagFollowTheSelectedFile() throws {
        let f = try ReportLogFixture()
        defer { f.remove() }
        let names = ["job.log", "job.mac.log", "job.log.part", "job.mac.log.part"]
        for name in names { try f.write(name, name) }
        for name in names {
            let document = try #require(LogDocument.load(jobID: "job", home: f.home))
            #expect(document.lines.map(\.text) == [name])
            #expect(document.isLive == name.hasSuffix(".part"))
            #expect(document.byteCount == Int64(name.utf8.count))
            #expect(!document.truncated)
            try FileManager.default.removeItem(at: f.logs.appendingPathComponent(name))
        }
    }

    @Test func logSanitizesEscapesPreservesInteriorEmptyLinesAndCountsKinds() throws {
        let f = try ReportLogFixture()
        defer { f.remove() }
        let text = "\u{1B}[31mred\u{1B}[0m\u{07}\n\n$ cargo fail\nerror: broken\nWARNING: old\n5 passed, 0 failed\n"
        try f.write("job.log", text)
        let document = try #require(LogDocument.load(jobID: "job", home: f.home))
        #expect(document.lines.map(\.text) == ["red", "", "$ cargo fail", "error: broken", "WARNING: old", "5 passed, 0 failed"])
        #expect(document.lines.map(\.kind) == [.plain, .plain, .command, .error, .warning, .success])
        #expect(document.lines.map(\.number) == [1, 2, 3, 4, 5, 6])
        #expect(document.errorCount == 1)
        #expect(document.warningCount == 1)
        #expect(document.byteCount == Int64(text.utf8.count))
        #expect(!document.truncated)
    }

    @Test func maxLinesKeepsLastLinesAndRenumbersThem() throws {
        let f = try ReportLogFixture()
        defer { f.remove() }
        for ending in ["", "\n"] {
            try f.write("job.log", "error\nwarning\nthird\nfourth" + ending)
            let document = try #require(LogDocument.load(jobID: "job", home: f.home, maxLines: 2))
            #expect(document.lines.map(\.text) == ["third", "fourth"])
            #expect(document.lines.map(\.number) == [1, 2])
            #expect(document.truncated)
            #expect(document.errorCount == 0)
            #expect(document.warningCount == 0)
            let all = try #require(LogDocument.load(jobID: "job", home: f.home, maxLines: 4))
            #expect(all.lines.count == 4)
            #expect(!all.truncated)
        }
    }

    @Test func twoMiBWindowDropsPartialFirstLineAndKeepsFileLastLine() throws {
        let f = try ReportLogFixture()
        defer { f.remove() }
        // 3072 lines of 1025 bytes: over 3 MiB, with the window starting inside a line.
        let texts = (0..<3072).map { index in
            String(format: "%06d", index) + ":" + String(repeating: "a", count: 1017)
        }
        let text = texts.joined(separator: "\n") + "\n"
        try f.write("job.log", text)
        let document = try #require(LogDocument.load(jobID: "job", home: f.home, maxLines: 5000))
        let windowStart = text.utf8.count - 2 * 1024 * 1024
        let firstCompleteIndex = windowStart / 1025 + 1
        #expect(document.truncated)
        #expect(document.byteCount == Int64(text.utf8.count))
        #expect(document.lines.map(\.text) == Array(texts[firstCompleteIndex...]))
        #expect(document.lines.first?.text == texts[firstCompleteIndex])
        #expect(document.lines.last?.text == texts.last)
        #expect(document.lines.map(\.number) == Array(1...document.lines.count))
    }

    @Test func finishedLocalReportContainsOrderedFactsAndResources() throws {
        var job = reportJob(.done)
        job.exitCode = 0
        job.startedAt = job.queuedAt.addingTimeInterval(3)
        job.endedAt = job.queuedAt.addingTimeInterval(78)
        job.tenant = "acme"
        job.worktree = "/tmp/project"
        job.branch = "main"
        job.commit = "abc123"
        job.dirty = true
        job.agent = "agent"
        job.session = "session"
        job.rule = "local-swift"
        job.avgCPU = 117.75
        job.avgMemoryBytes = 536_870_912
        let report = RunReport(job, now: job.queuedAt.addingTimeInterval(999))
        #expect(report.title == job.repo)
        #expect(report.command == job.command)
        #expect(report.stateText == "done")
        #expect(report.stateTone == .ok)
        #expect(report.sections.map(\.title) == ["Result", "Where", "Timing", "Resources"])
        try expectFacts(report, "Result", [("Status", "done"), ("Exit code", "0")])
        try expectFacts(report, "Where", [("Location", "local"), ("Environment", "mac"),
            ("Rule", "local-swift"), ("Tenant", "acme"), ("Repo", job.repo),
            ("Worktree", "/tmp/project"), ("Branch", "main"), ("Commit", "abc123 (dirty)"),
            ("Agent", "agent"), ("Session", "session")])
        try expectFacts(report, "Timing", [("Queued", timestamp(job.queuedAt)),
            ("Started", timestamp(try #require(job.startedAt))),
            ("Ended", timestamp(try #require(job.endedAt))), ("Queue wait", "3s"), ("Run", "1m 15s")])
        try expectFacts(report, "Resources", [("Avg CPU", "118%"), ("Avg memory",
            ByteCountFormatter.string(fromByteCount: 536_870_912, countStyle: .memory))])
        #expect(try fact(report, "Result", "Exit code").tone == .ok)
    }

    @Test func runningReportUsesElapsedAndOmitsUnavailablePairs() throws {
        var job = reportJob(.running)
        job.startedAt = job.queuedAt
        job.syncStartedAt = job.queuedAt
        job.boxStartedAt = job.queuedAt
        let report = RunReport(job, now: job.queuedAt.addingTimeInterval(125))
        #expect(report.stateTone == .running)
        try expectFacts(report, "Timing", [("Queued", timestamp(job.queuedAt)),
            ("Started", timestamp(job.queuedAt)), ("Elapsed", "2m 5s"),
            ("Box start", timestamp(job.queuedAt))])
        #expect(!report.sections.contains { $0.title == "Resources" })
    }

    @Test func failedBoxReportContainsFallbackExitCodesAndAllTimings() throws {
        var job = reportJob(.failed)
        job.destination = "ai-eu-1"
        job.environment = "box"
        job.fallbackReason = "sync failed"
        job.exitCode = 7
        job.boxExit = 9
        job.syncStartedAt = job.queuedAt.addingTimeInterval(1)
        job.syncEndedAt = job.queuedAt.addingTimeInterval(3)
        job.startedAt = job.queuedAt.addingTimeInterval(4)
        job.endedAt = job.queuedAt.addingTimeInterval(14)
        job.boxStartedAt = job.queuedAt.addingTimeInterval(5)
        job.boxEndedAt = job.queuedAt.addingTimeInterval(13)
        job.clockOffsetMS = -123
        job.commit = "clean-sha"
        let report = RunReport(job, now: job.queuedAt)
        #expect(report.stateTone == .crit)
        try expectFacts(report, "Result", [("Status", "failed"), ("Exit code", "7"), ("Box exit", "9")])
        for label in ["Status", "Exit code", "Box exit"] {
            #expect(try fact(report, "Result", label).tone == .crit)
        }
        try expectFacts(report, "Where", [("Location", "ai-eu-1"), ("Environment", "box"),
            ("Fallback", "sync failed"), ("Repo", job.repo), ("Commit", "clean-sha")])
        #expect(try fact(report, "Where", "Fallback").tone == .warn)
        try expectFacts(report, "Timing", [("Queued", timestamp(job.queuedAt)),
            ("Started", timestamp(try #require(job.startedAt))),
            ("Ended", timestamp(try #require(job.endedAt))), ("Queue wait", "4s"),
            ("Sync", "2s"), ("Run", "10s"), ("Box run", "8s"),
            ("Box start", timestamp(try #require(job.boxStartedAt))),
            ("Box end", timestamp(try #require(job.boxEndedAt))), ("Clock offset", "-123 ms")])
        job.boxExit = 0
        #expect(try fact(RunReport(job, now: job.queuedAt), "Result", "Box exit").tone == .ok)
    }

    @Test func minimalQueuedReportOmitsNilFactsAndEmptyResources() throws {
        let job = reportJob(.queued)
        let report = RunReport(job, now: job.queuedAt)
        #expect(report.stateText == "queued")
        #expect(report.stateTone == .unknown)
        // queuedAt is required, so even the minimal queued job has a Timing section.
        #expect(report.sections.map(\.title) == ["Result", "Where", "Timing"])
        try expectFacts(report, "Result", [("Status", "queued")])
        try expectFacts(report, "Where", [("Location", "local"), ("Environment", "mac"), ("Repo", job.repo)])
        try expectFacts(report, "Timing", [("Queued", timestamp(job.queuedAt))])
    }

    @Test func specifiedStatesHaveMatchingStatusTones() throws {
        let states: [(JobState, JobRowPresentation.Tone)] = [
            (.done, .ok), (.failed, .crit), (.lost, .crit), (.cancelled, .warn),
            (.running, .running), (.syncing, .running), (.queued, .unknown)
        ]
        for (state, tone) in states {
            let job = reportJob(state)
            let report = RunReport(job, now: job.queuedAt)
            #expect(report.stateText == state.rawValue)
            #expect(report.stateTone == tone)
            #expect(try fact(report, "Result", "Status").tone == tone)
        }
    }

    private func reportJob(_ state: JobState) -> JobRecord {
        JobRecord(id: "report", repo: "owner/repo", command: "swift test --filter A && echo complete",
                  location: "local", environment: "mac", state: state,
                  queuedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func fact(_ report: RunReport, _ section: String, _ label: String) throws -> RunReport.Fact {
        let section = try #require(report.sections.first { $0.title == section })
        return try #require(section.facts.first { $0.label == label })
    }

    private func expectFacts(_ report: RunReport, _ title: String, _ expected: [(String, String)]) throws {
        let section = try #require(report.sections.first { $0.title == title })
        #expect(section.facts.map(\.label) == expected.map { $0.0 })
        #expect(section.facts.map(\.value) == expected.map { $0.1 })
    }
}

private struct ReportLogFixture {
    let home: RMJHome
    var logs: URL { home.url.appendingPathComponent("logs") }

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-report-\(UUID().uuidString)")
        home = RMJHome(environment: ["RMJ_HOME": root.path])
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: logs.appendingPathComponent(name))
    }

    func remove() { try? FileManager.default.removeItem(at: home.url) }
}
