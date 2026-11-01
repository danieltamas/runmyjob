import Foundation
import Testing
@testable import RMJCore

struct CleanFixture {
    let root: URL
    let home: RMJHome
    let ledger: Ledger
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    var logs: URL { home.url.appendingPathComponent("logs") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-clean-\(UUID().uuidString)")
        home = RMJHome(environment: ["RMJ_HOME": root.appendingPathComponent("home").path])
        try home.prepare()
        ledger = Ledger(database: try Database(url: home.url.appendingPathComponent("rmj.sqlite")))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func old(_ url: URL, days: Double = 5) throws {
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86400)], ofItemAtPath: url.path)
    }
    func payload(_ directory: URL, bytes: Int = 37) throws {
        let file = directory.appendingPathComponent("payload")
        try Data(repeating: 65, count: bytes).write(to: file)
        try old(file); try old(directory)
    }
    func config(_ targets: [CleanTarget]) throws -> CleanConfig {
        try JSONDecoder().decode(CleanConfig.self, from: JSONEncoder().encode(["targets": targets]))
    }
    func scratch(_ pattern: String = "scratch-*", hours: Int = 48) -> CleanTarget {
        CleanTarget(kind: .scratch, path: root.appendingPathComponent(pattern).path, afterHours: hours)
    }
    func run(_ targets: [CleanTarget], apply: Bool = true,
             now: Date? = nil, inUse: @escaping @Sendable (String) async -> Bool = { _ in false }) async throws -> CleanRun {
        let date = now ?? self.now
        return await Cleaner(ledger: ledger, config: try config(targets), logDirectory: logs,
                             now: { date }, inUse: inUse).run(apply: apply)
    }
    func writeConfig(_ json: String) throws {
        let file = home.url.appendingPathComponent("clean.json")
        try Data(json.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func writeTargets(_ targets: [CleanTarget]) throws {
        try JSONEncoder().encode(try config(targets)).write(to: home.url.appendingPathComponent("clean.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                             ofItemAtPath: home.url.appendingPathComponent("clean.json").path)
    }
    func encoded(_ config: CleanConfig) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(config)
    }
    func trace(_ run: CleanRun) async throws {
        #expect(try await ledger.cleanItems(run: run.id) == run.items)
        #expect(try await ledger.cleanRuns(limit: 100).contains(run))
        let lines = try String(contentsOf: logs.appendingPathComponent("clean.log"), encoding: .utf8).split(separator: "\n")
        for item in run.items {
            let matching = lines.filter { $0.contains(run.id) && $0.contains(UntrustedText.clean(item.path)) }
            #expect(matching.count == 1)
            let line = try #require(matching.first)
            #expect(line.contains(item.action.rawValue) && line.contains(item.kind.rawValue))
            #expect(line.split(whereSeparator: { $0 == " " || $0 == "\t" }).contains(Substring(String(item.bytes))))
        }
    }
}

struct CleanAcceptanceTests {
    @Test func absentConfigUsesTheDocumentedDefaults() throws {
        let f = try CleanFixture(); defer { f.remove() }
        let loaded = CleanConfig.load(home: f.home)
        #expect(loaded.problem == nil)
        #expect(try f.encoded(loaded.config) == f.encoded(CleanConfig.defaults))
        let target = try #require(loaded.config.targets.first)
        #expect(loaded.config.targets.count == 1 && target.kind == .scratch && target.afterHours == 72)
        #expect((target.path as NSString).expandingTildeInPath ==
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/rmj-*").path)
    }

    @Test(arguments: ["{", "[]", "{}", #"{"targets":"bad"}"#,
        #"{"targets":[{}]}"#,
        #"{"targets":[{"kind":"scratch","path":42}]}"#,
        #"{"targets":[{"kind":"scratch","path":""}]}"#,
        #"{"targets":[{"kind":"scratch","path":"/private/tmp/a","after_hours":"old"}]}"#,
        #"{"targets":[{"kind":"unknown","path":"/private/tmp/a-*"}]}"#,
        #"{"targets":[{"kind":"scratch","path":"relative/*"}]}"#,
        #"{"targets":[{"kind":"scratch","path":"/"}]}"#,
        #"{"targets":[{"kind":"scratch","path":"/one/two"}]}"#,
        #"{"targets":[{"kind":"scratch","path":"/private/*/a"}]}"#,
        #"{"targets":[{"kind":"scratch","path":"/private/tmp/a","after_hours":0}]}"#,
        #"{"targets":[{"kind":"scratch","path":"/private/tmp/a","after_hours":8761}]}"#])
    func invalidConfigRejectsTheWholeFile(json: String) throws {
        let f = try CleanFixture(); defer { f.remove() }
        try f.writeConfig(json)
        let loaded = CleanConfig.load(home: f.home)
        #expect(loaded.problem?.isEmpty == false)
        #expect(try f.encoded(loaded.config) == f.encoded(CleanConfig.defaults))
    }

    @Test func validConfigExpandsTildeAndDefaultsHours() throws {
        let f = try CleanFixture(); defer { f.remove() }
        try f.writeConfig(#"{"targets":[{"kind":"scratch","path":"~/.cache/rmj-*"}]}"#)
        let loaded = CleanConfig.load(home: f.home)
        #expect(loaded.problem == nil)
        let target = try #require(loaded.config.targets.first)
        #expect(target.afterHours == 48)
        #expect(target.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/rmj-*").path)
    }

    @Test(arguments: [1, 8760])
    func validHourEndpointsAndLiteralPathsAreAccepted(hours: Int) throws {
        let f = try CleanFixture(); defer { f.remove() }
        try f.writeTargets([f.scratch("literal", hours: hours)])
        let loaded = CleanConfig.load(home: f.home)
        #expect(loaded.problem == nil)
        #expect(loaded.config.targets.first?.afterHours == hours)
        #expect(loaded.config.targets.first?.path == f.root.appendingPathComponent("literal").path)
    }

    @Test func invalidTargetDiscardsEarlierValidTargets() throws {
        let f = try CleanFixture(); defer { f.remove() }
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.scratch()))
        let data = try JSONSerialization.data(withJSONObject: ["targets": [valid, ["kind": "unknown", "path": "/one/two/three"]]])
        try f.writeConfig(String(decoding: data, as: UTF8.self))
        let loaded = CleanConfig.load(home: f.home)
        #expect(loaded.problem?.isEmpty == false)
        #expect(try f.encoded(loaded.config) == f.encoded(CleanConfig.defaults))
    }

    @Test func dryRunThenApplyCountsBytesAndPersistsTrace() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-old"); try f.payload(candidate)
        let dry = try await f.run([f.scratch()], apply: false)
        #expect(dry.items.count == 1 && dry.items.first?.action == .wouldRemove)
        #expect(f.exists(candidate) && dry.freedBytes == 0)
        try await f.trace(dry)
        let applied = try await f.run([f.scratch()])
        #expect(applied.items.count == 1 && applied.items.first?.action == .removed)
        #expect(applied.items.first?.bytes == 37 && applied.freedBytes == 37)
        #expect(!f.exists(candidate))
        #expect(applied.apply && !dry.apply && applied.problem == nil)
        #expect(applied.startedAt == f.now && applied.finishedAt >= applied.startedAt)
        #expect(applied.id.range(of: "^[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil)
        try await f.trace(applied)
    }

    @Test func deepRecentFileInUseFileAndSymlinkAreSkipped() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let recent = try f.directory("scratch-recent"), deep = try f.directory("scratch-recent/a/b")
        try f.payload(deep); try f.old(recent); try f.old(deep.deletingLastPathComponent())
        try FileManager.default.setAttributes([.modificationDate: f.now], ofItemAtPath: deep.appendingPathComponent("payload").path)
        let busy = try f.directory("scratch-busy"); try f.payload(busy)
        let outside = try f.directory("outside/scratch-old"); try f.payload(outside)
        let link = f.root.appendingPathComponent("scratch-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let file = f.root.appendingPathComponent("scratch-file"); try Data("file".utf8).write(to: file)
        let busyPath = busy.path
        let run = try await f.run([f.scratch()], inUse: { $0 == busyPath })
        #expect(run.items.count == 4 && run.items.allSatisfy { $0.action == .skipped })
        #expect(run.items.first { $0.path == recent.path }?.reason.contains("recent") == true)
        #expect(run.items.first { $0.path == busy.path }?.reason.contains("in use") == true)
        #expect(!run.items.contains { $0.path == outside.path })
        for path in [recent, busy, outside, link, file] { #expect(f.exists(path)) }
        try await f.trace(run)
    }

    @Test func literalLastComponentAndOverlappingTargetsVisitOnceWithoutFollowingLinks() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-one"), outside = try f.directory("outside")
        try f.payload(candidate); try f.payload(outside, bytes: 1_000_000)
        try FileManager.default.createSymbolicLink(at: candidate.appendingPathComponent("escape"), withDestinationURL: outside)
        try f.old(candidate)
        let run = try await f.run([f.scratch("scratch-one"), f.scratch()])
        #expect(run.items.count == 1 && run.items.first?.action == .removed)
        let item = try #require(run.items.first)
        #expect(item.bytes >= 37 && item.bytes < 10_000 && run.freedBytes == item.bytes)
        #expect(f.exists(outside.appendingPathComponent("payload")) && !f.exists(candidate))
        try await f.trace(run)
    }

    @Test func controlCharactersInPathsCannotInjectLogLines() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-\u{1b}[31mred\u{1b}[0m\u{200b}-name")
        try f.payload(candidate)
        let run = try await f.run([f.scratch()])
        #expect(run.items.first?.action == .removed && !f.exists(candidate))
        try await f.trace(run)
        let log = try String(contentsOf: f.logs.appendingPathComponent("clean.log"), encoding: .utf8)
        #expect(!log.contains("\u{1b}") && !log.contains("\u{200b}"))
    }

    @Test func failedRemovalIsLoggedAndPreservesTheCandidate() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-locked"); try f.payload(candidate)
        _ = try await cleanProcess("/usr/bin/chflags", ["uchg", candidate.path])
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: candidate.path) }
        let run = try await f.run([f.scratch()])
        #expect(run.items.count == 1 && run.items.first?.action == .failed)
        #expect(f.exists(candidate) && run.freedBytes == 0)
        try await f.trace(run)
    }

    @Test func unreadableCandidateFailsClosed() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-unreadable"); try f.payload(candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: candidate.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path) }
        let run = try await f.run([f.scratch()])
        #expect(run.items.count == 1)
        #expect(run.items.first?.action == .failed || run.items.first?.action == .skipped)
        #expect(run.items.first?.reason.isEmpty == false && f.exists(candidate))
    }

    @Test func retentionRemovesOnlyRunsOlderThanNinetyDaysAndTheirItems() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let candidate = try f.directory("scratch-retention"); try f.payload(candidate)
        let expired = try await f.run([f.scratch()], apply: false, now: f.now.addingTimeInterval(-91 * 86400))
        let boundary = try await f.run([f.scratch()], apply: false, now: f.now.addingTimeInterval(-90 * 86400))
        let recent = try await f.run([f.scratch()], apply: false)
        let archive = LogArchive(database: f.ledger.database, directory: f.logs)
        try await Retention(ledger: f.ledger, archive: archive).prune(now: f.now)
        let runs = try await f.ledger.cleanRuns(limit: 20)
        #expect(Set(runs.map(\.id)) == Set([boundary.id, recent.id]))
        #expect(try await f.ledger.cleanItems(run: expired.id).isEmpty)
        #expect(try await f.ledger.cleanItems(run: boundary.id) == boundary.items)
        #expect(try await f.ledger.cleanItems(run: recent.id) == recent.items)
        #expect(f.exists(candidate))
    }
}

@discardableResult
func cleanProcess(_ executable: String, _ arguments: [String], in directory: URL? = nil) async throws -> ProcessOutput {
    let result = try await ProcessRunner().run(executable, arguments, in: directory,
        environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                      "GIT_TERMINAL_PROMPT": "0"], timeout: .seconds(60))
    #expect(result.status == 0, "\(executable) \(arguments): \(result.stderr)")
    return result
}
