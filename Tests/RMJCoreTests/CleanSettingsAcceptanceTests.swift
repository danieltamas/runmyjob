import Foundation
import Testing
@testable import RMJCore

struct CleanSettingsAcceptanceTests {
    @Test func validationAcceptsDefaults() {
        #expect(CleanConfig.defaults.validate() == nil)
    }

    @Test(arguments: [1, 168])
    func validationAcceptsScheduledTargets(everyHours: Int) throws {
        let f = try CleanFixture(); defer { f.remove() }
        let config = CleanConfig(targets: [f.scratch()],
                                 schedule: CleanSchedule(everyHours: everyHours, apply: true))
        #expect(config.validate() == nil)
    }

    @Test(arguments: ["relative/path", "/", "/one/two", "/private/*/scratch",
                      "/private/tmp/../scratch"])
    func validationRejectsUnsafePaths(path: String) {
        let config = CleanConfig(targets: [CleanTarget(kind: .scratch, path: path)])
        #expect(config.validate()?.isEmpty == false)
    }

    @Test(arguments: [0, 8761])
    func validationRejectsIdleHours(hours: Int) throws {
        let f = try CleanFixture(); defer { f.remove() }
        let target = CleanTarget(kind: .scratch, path: f.scratch().path, afterHours: hours)
        #expect(CleanConfig(targets: [target]).validate()?.isEmpty == false)
    }

    @Test(arguments: [1, 8760])
    func validationAcceptsIdleHourBoundaries(hours: Int) throws {
        let f = try CleanFixture(); defer { f.remove() }
        #expect(CleanConfig(targets: [f.scratch(hours: hours)]).validate() == nil)
    }

    @Test(arguments: [0, 169])
    func validationRejectsScheduleHours(hours: Int) throws {
        let f = try CleanFixture(); defer { f.remove() }
        let config = CleanConfig(targets: [f.scratch()], schedule: CleanSchedule(everyHours: hours))
        let problem = try #require(config.validate())
        #expect(!problem.isEmpty && problem.contains("schedule"))
    }

    @Test(arguments: ["*", "??", "*?"])
    func validationRejectsWildcardOnlyScratchNames(pattern: String) throws {
        let f = try CleanFixture(); defer { f.remove() }
        let config = CleanConfig(targets: [f.scratch(pattern)])
        #expect(config.validate()?.isEmpty == false)
        try f.writeConfig(String(decoding: JSONEncoder().encode(config), as: UTF8.self))
        #expect(CleanConfigStore(home: f.home).load().problem?.isEmpty == false)
        #expect(CleanConfig.load(home: f.home).problem?.isEmpty == false)
    }

    @Test(arguments: ["a*", "*-x", "literal"])
    func validationAcceptsLiteralScratchNames(pattern: String) throws {
        let f = try CleanFixture(); defer { f.remove() }
        #expect(CleanConfig(targets: [f.scratch(pattern)]).validate() == nil)
    }

    @Test(arguments: ["repo*", "repo?", "repo[ab]"])
    func validationRejectsWorktreeWildcards(pattern: String) throws {
        let f = try CleanFixture(); defer { f.remove() }
        let target = CleanTarget(kind: .worktrees, path: f.root.appendingPathComponent(pattern).path)
        #expect(CleanConfig(targets: [target]).validate()?.isEmpty == false)
    }

    @Test func validationAcceptsLiteralWorktreeRepository() throws {
        let f = try CleanFixture(); defer { f.remove() }
        let target = CleanTarget(kind: .worktrees, path: f.root.appendingPathComponent("repo").path)
        #expect(CleanConfig(targets: [target]).validate() == nil)
    }

    @Test func validationNamesTheSecondTargetAndReturnsItsFirstProblem() throws {
        let f = try CleanFixture(); defer { f.remove() }
        let config = CleanConfig(targets: [f.scratch(), CleanTarget(kind: .scratch, path: "relative")],
                                 schedule: CleanSchedule(everyHours: 0))
        let problem = try #require(config.validate())
        #expect(!problem.isEmpty && problem.contains("target 2"))
    }

    @Test(arguments: [false, true])
    func invalidSaveWritesNothing(existing: Bool) throws {
        let f = try CleanFixture(); defer { f.remove() }
        let store = CleanConfigStore(home: f.home)
        let file = f.home.url.appendingPathComponent("clean.json")
        if existing { try store.save(CleanConfig(targets: [f.scratch()])) }
        let before = existing ? try Data(contentsOf: file) : nil
        let names = try FileManager.default.contentsOfDirectory(atPath: f.home.url.path).sorted()
        let invalid = CleanConfig(targets: [CleanTarget(kind: .scratch, path: "relative")])
        #expect(throws: CleanConfigStore.Invalid.self) { try store.save(invalid) }
        if let before { #expect(try Data(contentsOf: file) == before) }
        else { #expect(!f.exists(file)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.home.url.path).sorted() == names)
    }

    @Test(arguments: [false, true])
    func validSaveIsPrivateAtomicAndRoundTripsSchedule(apply: Bool) throws {
        let f = try CleanFixture(); defer { f.remove() }
        let store = CleanConfigStore(home: f.home)
        let file = f.home.url.appendingPathComponent("clean.json")
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: f.home.url.path))
        let config = CleanConfig(targets: [f.scratch(hours: 72)],
                                 schedule: CleanSchedule(everyHours: 24, apply: apply))
        try store.save(config)
        // Repeat to exercise replacement as well as initial creation.
        try store.save(config)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: f.home.url.path))
        #expect(after == before.union(["clean.json"]))
        let loaded = store.load()
        #expect(loaded.problem == nil && loaded.config == config)
        let legacy = CleanConfig.load(home: f.home)
        #expect(legacy.problem == nil && legacy.config == config)
        let text = try String(contentsOf: file, encoding: .utf8)
        let scheduleKey = try #require(text.range(of: "\"schedule\""))
        let targetsKey = try #require(text.range(of: "\"targets\""))
        #expect(scheduleKey.lowerBound < targetsKey.lowerBound)
        let hoursKey = try #require(text.range(of: "\"after_hours\""))
        let kindKey = try #require(text.range(of: "\"kind\""))
        let pathKey = try #require(text.range(of: "\"path\""))
        #expect(hoursKey.lowerBound < kindKey.lowerBound && kindKey.lowerBound < pathKey.lowerBound)
    }

    @Test func savePreservesTildePathAsGiven() throws {
        let f = try CleanFixture(); defer { f.remove() }
        let config = CleanConfig(targets: [CleanTarget(kind: .scratch, path: "~/.cache/rmj-*")])
        try CleanConfigStore(home: f.home).save(config)
        let data = try Data(contentsOf: f.home.url.appendingPathComponent("clean.json"))
        #expect(try JSONDecoder().decode(CleanConfig.self, from: data) == config)
    }

    @Test func resetRemovesConfigAndIsSilentWhenAbsent() throws {
        let f = try CleanFixture(); defer { f.remove() }
        let store = CleanConfigStore(home: f.home)
        try store.save(CleanConfig(targets: [f.scratch()], schedule: CleanSchedule(everyHours: 6)))
        try store.reset()
        #expect(!f.exists(f.home.url.appendingPathComponent("clean.json")))
        try store.reset()
        let loaded = store.load()
        #expect(loaded.problem == nil && loaded.config == CleanConfig.defaults)
    }

    @Test(arguments: ["{", "[]", "{}", #"{"targets":"bad"}"#,
        #"{"targets":[{"kind":"unknown","path":"/private/tmp/a"}]}"#,
        #"{"targets":[{"kind":"scratch","path":42}]}"#,
        #"{"targets":[],"schedule":{"every_hours":"24"}}"#,
        #"{"targets":[],"schedule":{}}"#])
    func loadReportsHandWrittenInvalidFilesAndResetFixesThem(json: String) throws {
        let f = try CleanFixture(); defer { f.remove() }
        try f.writeConfig(json)
        let store = CleanConfigStore(home: f.home)
        let rejected = store.load()
        #expect(rejected.problem?.isEmpty == false && rejected.config == CleanConfig.defaults)
        try store.reset()
        let restored = store.load()
        #expect(restored.problem == nil && restored.config == CleanConfig.defaults)
    }

    @Test func serviceRejectsInvalidFileWithoutRemovingOrRecording() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        let config = CleanConfig(targets: [f.scratch(), CleanTarget(kind: .scratch, path: "relative")])
        try f.writeConfig(String(decoding: JSONEncoder().encode(config), as: UTF8.self))
        let date = f.now
        let service = CleanSettingsService(ledger: f.ledger, home: f.home, now: { date }, inUse: { _ in false })
        await #expect(throws: CleanConfigStore.Invalid.self) { try await service.run(apply: true) }
        #expect(f.exists(candidate) && f.exists(candidate.appendingPathComponent("payload")))
        #expect(try await f.ledger.cleanRuns(limit: 100).isEmpty)
    }

    @Test(arguments: [false, true])
    func serviceRunsWithUITraceAndRequestedApplyMode(apply: Bool) async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        // The button's mode wins over the schedule's mode.
        let config = CleanConfig(targets: [f.scratch()],
                                 schedule: CleanSchedule(everyHours: 168, apply: !apply))
        try f.writeConfig(String(decoding: JSONEncoder().encode(config), as: UTF8.self))
        let date = f.now
        let service = CleanSettingsService(ledger: f.ledger, home: f.home, now: { date }, inUse: { _ in false })
        let run = try await service.run(apply: apply)
        #expect(run.problem == nil && run.apply == apply)
        #expect(run.startedAt == date)
        #expect(f.exists(candidate) == !apply)
        #expect(run.items.count == 1)
        #expect(run.items.first?.action == (apply ? .removed : .wouldRemove))
        #expect(run.freedBytes == (apply ? 37 : 0))
        try await f.trace(run)
        let text = try String(contentsOf: f.logs.appendingPathComponent("clean.log"), encoding: .utf8)
        let lines: [Substring] = text.split(separator: "\n")
        let fields: [[Substring]] = lines.map {
            $0.split(separator: "\t", omittingEmptySubsequences: false)
        }
        var starts: [[Substring]] = []
        for row in fields {
            guard row.count >= 3 else { continue }
            if String(row[1]) == run.id && String(row[2]) == "start" {
                starts.append(row)
            }
        }
        #expect(starts.count == 1)
        #expect(starts.first?.last == "ui")
    }

    @Test func historyLimitsToNewestTwoRunsInDescendingOrder() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        try f.writeConfig(String(decoding: JSONEncoder().encode(CleanConfig(targets: [f.scratch()])), as: UTF8.self))
        var runs: [CleanRun] = []
        for offset in [0.0, 60.0, 120.0] {
            let date = f.now.addingTimeInterval(offset)
            let service = CleanSettingsService(ledger: f.ledger, home: f.home, now: { date }, inUse: { _ in false })
            runs.append(try await service.run(apply: false))
        }
        let date = f.now
        let service = CleanSettingsService(ledger: f.ledger, home: f.home, now: { date }, inUse: { _ in false })
        let history = try await service.history(limit: 2)
        #expect(history == [runs[2], runs[1]])
        #expect(try await f.ledger.cleanRuns(limit: 100).count == 3)
        #expect(f.exists(candidate))
    }
}
