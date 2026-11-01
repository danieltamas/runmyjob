import Darwin
import Foundation
import Testing
@testable import RMJCore

struct CleanScheduleAcceptanceTests {
    private func writeConfig(_ f: CleanFixture, schedule: String? = nil) throws {
        let extra = schedule.map { ",\"schedule\":\($0)" } ?? ""
        try f.writeConfig("""
        {"targets":[{"kind":"scratch","path":"\(f.scratch().path)","after_hours":48}]\(extra)}
        """)
    }

    private func scheduler(_ f: CleanFixture, at date: Date? = nil) -> CleanScheduler {
        let instant = date ?? f.now
        return CleanScheduler(ledger: f.ledger, home: f.home, now: { instant }, inUse: { _ in false })
    }

    private func expectStart(_ run: CleanRun, in f: CleanFixture, source: String) throws {
        let text = try String(contentsOf: f.logs.appendingPathComponent("clean.log"), encoding: .utf8)
        let starts = text.split(separator: "\n").filter {
            let fields = $0.split(separator: "\t", omittingEmptySubsequences: false)
            return fields.count >= 3 && fields[1] == Substring(run.id) && fields[2] == "start"
        }
        #expect(starts.count == 1)
        let start = try #require(starts.first)
        #expect(start.split(separator: "\t", omittingEmptySubsequences: false).last == Substring(source))
        #expect(start.hasSuffix("\t" + source))
    }

    @Test func absentScheduleIsNilInDefaultsAndTargetConfig() throws {
        let f = try CleanFixture(); defer { f.remove() }
        let absent = CleanConfig.load(home: f.home)
        #expect(absent.problem == nil && absent.config.schedule == nil)
        #expect(CleanConfig(targets: [f.scratch()]).schedule == nil)
        try writeConfig(f)
        let loaded = CleanConfig.load(home: f.home)
        #expect(loaded.problem == nil && loaded.config.schedule == nil)
        #expect(loaded.config.targets == [f.scratch()])
    }

    @Test(arguments: [1, 168])
    func scheduleHourEndpointsAreAcceptedAndApplyDefaultsFalse(hours: Int) throws {
        let f = try CleanFixture(); defer { f.remove() }
        try writeConfig(f, schedule: "{\"every_hours\":\(hours)}")
        let loaded = CleanConfig.load(home: f.home)
        #expect(loaded.problem == nil)
        let schedule = try #require(loaded.config.schedule)
        #expect(schedule == CleanSchedule(everyHours: hours, apply: false))
        #expect(!schedule.apply)
        #expect(loaded.config.targets == [f.scratch()])
        let roundTrip = try JSONDecoder().decode(CleanConfig.self, from: JSONEncoder().encode(loaded.config))
        #expect(roundTrip.schedule == schedule)
        let configured = CleanConfig(targets: [f.scratch()], schedule: schedule)
        #expect(configured.schedule == schedule)
    }

    @Test(arguments: [
        #"{"every_hours":0,"apply":true}"#,
        #"{"every_hours":169,"apply":true}"#,
        #"{"every_hours":"24","apply":true}"#,
        #"{"apply":true}"#,
        #""daily""#,
        #"[]"#,
        #"{"every_hours":24,"apply":"true"}"#
    ])
    func invalidScheduleRejectsWholeFileAndSchedulerDoesNothing(json: String) async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        try writeConfig(f, schedule: json)
        let loaded = CleanConfig.load(home: f.home)
        #expect(loaded.problem?.isEmpty == false)
        #expect(try f.encoded(loaded.config) == f.encoded(CleanConfig.defaults))
        #expect(await scheduler(f).runIfDue() == nil)
        #expect(f.exists(candidate.appendingPathComponent("payload")))
        #expect(try await f.ledger.cleanRuns(limit: 100).isEmpty)
        #expect(!f.exists(f.logs.appendingPathComponent("clean.log")))
    }

    @Test(arguments: [false, true])
    func noScheduleDoesNothingWithAbsentOrPresentConfig(present: Bool) async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        if present { try writeConfig(f) }
        #expect(await scheduler(f).runIfDue() == nil)
        #expect(f.exists(candidate.appendingPathComponent("payload")))
        #expect(try await f.ledger.cleanRuns(limit: 100).isEmpty)
        #expect(!f.exists(f.logs.appendingPathComponent("clean.log")))
    }

    @Test func badTargetPreventsAnOtherwiseEnabledSchedule() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        try f.writeConfig("""
        {"targets":[{"kind":"scratch","path":"\(f.scratch().path)","after_hours":0}],
         "schedule":{"every_hours":24,"apply":true}}
        """)
        #expect(CleanConfig.load(home: f.home).problem != nil)
        #expect(await scheduler(f).runIfDue() == nil)
        #expect(f.exists(candidate))
        #expect(try await f.ledger.cleanRuns(limit: 100).isEmpty)
        #expect(!f.exists(f.logs.appendingPathComponent("clean.log")))
    }

    @Test(arguments: [false, true])
    func firstScheduledRunHonorsApplyAndRecordsTrace(apply: Bool) async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        try writeConfig(f, schedule: "{\"every_hours\":24,\"apply\":\(apply)}")
        let clock = scheduler(f)
        let result = await clock.runIfDue()
        let run = try #require(result)
        #expect(run.problem == nil && run.apply == apply)
        #expect(run.startedAt == f.now)
        #expect(run.items.count == 1)
        let item = try #require(run.items.first)
        #expect(item.path == candidate.path && item.kind == .scratch)
        #expect(item.action == (apply ? .removed : .wouldRemove))
        #expect(item.bytes == 37 && run.freedBytes == (apply ? 37 : 0))
        #expect(f.exists(candidate) == !apply)
        try await f.trace(run)
        try expectStart(run, in: f, source: "schedule")
        #expect(try await f.ledger.cleanRuns(limit: 100) == [run])
        let log = try Data(contentsOf: f.logs.appendingPathComponent("clean.log"))
        #expect(await clock.runIfDue() == nil)
        #expect(try await f.ledger.cleanRuns(limit: 100) == [run])
        #expect(try Data(contentsOf: f.logs.appendingPathComponent("clean.log")) == log)
    }

    @Test func omittedApplyProducesAScheduledDryRun() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        try writeConfig(f, schedule: #"{"every_hours":24}"#)
        let result = await scheduler(f).runIfDue()
        let run = try #require(result)
        #expect(run.problem == nil && !run.apply && run.freedBytes == 0)
        #expect(run.items.count == 1 && run.items.first?.action == .wouldRemove)
        #expect(f.exists(candidate.appendingPathComponent("payload")))
        try await f.trace(run)
        try expectStart(run, in: f, source: "schedule")
    }

    @Test(arguments: [false, true])
    func runOneSecondYoungerThanIntervalDefersEvenWhenDryRun(apply: Bool) async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        try writeConfig(f, schedule: #"{"every_hours":24,"apply":true}"#)
        let started = f.now.addingTimeInterval(-24 * 3600 + 1)
        let prior = CleanRun(id: ULID.make(now: started), startedAt: started, finishedAt: started, apply: apply)
        try await f.ledger.record(prior)
        #expect(await scheduler(f).runIfDue() == nil)
        #expect(f.exists(candidate.appendingPathComponent("payload")))
        #expect(try await f.ledger.cleanRuns(limit: 100) == [prior])
        #expect(!f.exists(f.logs.appendingPathComponent("clean.log")))
    }

    @Test(arguments: [false, true])
    func runExactlyIntervalOldIsDueByStartedAt(apply: Bool) async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        try writeConfig(f, schedule: #"{"every_hours":24,"apply":true}"#)
        let started = f.now.addingTimeInterval(-24 * 3600)
        // A recent finish must not postpone a run whose start is exactly at the boundary.
        let prior = CleanRun(id: ULID.make(now: started), startedAt: started, finishedAt: f.now, apply: apply)
        try await f.ledger.record(prior)
        let result = await scheduler(f).runIfDue()
        let run = try #require(result)
        #expect(run.problem == nil && run.apply && run.startedAt == f.now)
        #expect(run.items.count == 1 && run.items.first?.action == .removed)
        #expect(!f.exists(candidate))
        #expect(try await f.ledger.cleanRuns(limit: 100) == [run, prior])
        try await f.trace(run)
        try expectStart(run, in: f, source: "schedule")
    }

    @Test func newestStartedAtWinsOverInsertionOrderAndOlderAppliedRun() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        try writeConfig(f, schedule: #"{"every_hours":24,"apply":true}"#)
        let recent = f.now.addingTimeInterval(-3600)
        let old = f.now.addingTimeInterval(-48 * 3600)
        let newest = CleanRun(id: ULID.make(now: recent), startedAt: recent, finishedAt: recent, apply: false)
        let older = CleanRun(id: ULID.make(now: old), startedAt: old, finishedAt: old, apply: true)
        try await f.ledger.record(newest)
        try await f.ledger.record(older)
        #expect(await scheduler(f).runIfDue() == nil)
        #expect(f.exists(candidate))
        #expect(try await f.ledger.cleanRuns(limit: 100) == [newest, older])
        #expect(!f.exists(f.logs.appendingPathComponent("clean.log")))
    }

    @Test func cliRunDefaultsSourceToCliAndDefersSchedule() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        try writeConfig(f, schedule: #"{"every_hours":24,"apply":true}"#)
        let config = CleanConfig.load(home: f.home).config
        let date = f.now
        let run = await Cleaner(ledger: f.ledger, config: config, logDirectory: f.logs,
                                now: { date }, inUse: { _ in false }).run(apply: false)
        #expect(run.problem == nil && !run.apply)
        #expect(run.items.count == 1 && run.items.first?.action == .wouldRemove)
        try await f.trace(run)
        try expectStart(run, in: f, source: "cli")
        let log = try Data(contentsOf: f.logs.appendingPathComponent("clean.log"))
        #expect(await scheduler(f).runIfDue() == nil)
        #expect(f.exists(candidate))
        #expect(try await f.ledger.cleanRuns(limit: 100) == [run])
        #expect(try Data(contentsOf: f.logs.appendingPathComponent("clean.log")) == log)
    }

    @Test func heldLockReturnsProblemWithoutRecordingAndReleaseAllowsRetry() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        try writeConfig(f, schedule: #"{"every_hours":24,"apply":true}"#)
        try FileManager.default.createDirectory(at: f.logs, withIntermediateDirectories: true)
        let fd = open(f.logs.appendingPathComponent("clean.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        var closed = false
        defer { if !closed { close(fd) } }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let clock = scheduler(f)
        let blockedResult = await clock.runIfDue()
        let blocked = try #require(blockedResult)
        #expect(blocked.problem?.isEmpty == false)
        #expect(blocked.items.isEmpty && blocked.freedBytes == 0)
        #expect(f.exists(candidate.appendingPathComponent("payload")))
        #expect(try await f.ledger.cleanRuns(limit: 100).isEmpty)
        #expect(try await f.ledger.cleanItems(run: blocked.id).isEmpty)
        close(fd)
        closed = true
        let retriedResult = await clock.runIfDue()
        let retried = try #require(retriedResult)
        #expect(retried.problem == nil && retried.apply)
        #expect(retried.items.count == 1 && retried.items.first?.action == .removed)
        #expect(!f.exists(candidate))
        #expect(try await f.ledger.cleanRuns(limit: 100) == [retried])
        try await f.trace(retried)
        try expectStart(retried, in: f, source: "schedule")
    }
}
