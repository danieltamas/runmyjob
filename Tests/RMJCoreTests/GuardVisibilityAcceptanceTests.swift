import Foundation
import Testing
import RMJCore

// U24's unspecified append shape: append(verdict:repo:directory:command:at:).
// It is synchronous and nonthrowing; recent(limit:) is synchronous and nonthrowing.
private struct GuardVisibilityFixture {
    let root: URL
    let home: RMJHome
    let repo: URL
    let environment: [String: String]

    var logURL: URL { home.url.appendingPathComponent("logs/guard.log") }
    var configURL: URL { home.url.appendingPathComponent("config.json") }
    var log: GuardLog { GuardLog(home: home) }

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RMJ-GuardVisibility-\(UUID())")
        self.root = root
        repo = root.appendingPathComponent("checkout")
        environment = ["HOME": root.appendingPathComponent("home").path,
                       "RMJ_HOME": root.appendingPathComponent("rmj").path,
                       "RMJ_TAILSCALE_FIXTURE": root.appendingPathComponent("tailnet.json").path]
        home = RMJHome(environment: environment)
        do {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
            try home.prepare()
            try Data(#"{"BackendState":"Stopped","Peer":{}}"#.utf8)
                .write(to: root.appendingPathComponent("tailnet.json"))
            // A real classified repo, but only a local rule: no network or destination probes.
            try Data(#"{"destinations":{},"tenants":{"acme":{"owners":["acme"]}},"rules":[{"name":"guard acceptance","match":{"repo":["acme/orbit"]},"to":["local"]}]}"#.utf8)
                .write(to: home.url.appendingPathComponent("rules.json"))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func prepareRepo() async throws {
        for args in [["init"], ["remote", "add", "origin", "https://github.com/acme/orbit.git"]] {
            let result = try await ProcessRunner().run("/usr/bin/git", ["-C", repo.path] + args, timeout: .seconds(10))
            try #require(result.status == 0, "git \(args): \(result.stderr)")
        }
    }

    func guardCommand(_ command: String = "cargo test", overrides: [String: String] = [:],
                      quiet: Bool = false) async -> Int32 {
        await HooksCommand.guardCommand(
            arguments: ["--command", command, "--cwd", repo.path] + (quiet ? ["--quiet"] : []),
            environment: environment.merging(overrides) { _, new in new },
            input: { Data() })
    }

    func lines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        return try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func append(_ command: String, at: Date) {
        log.append(verdict: "block", repo: "acme/orbit", directory: repo.path, command: command, at: at)
    }
}

struct GuardVisibilityAcceptanceTests {
    @Test func guardDefaultsOn() throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        #expect(GuardSettings.enabled(home: f.home))
    }

    @Test func guardSetFalsePersistsDisabled() throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try GuardSettings.set(false, home: f.home)
        #expect(!GuardSettings.enabled(home: RMJHome(environment: f.environment)))
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.configURL)) as? [String: Any])
        #expect(object["guard_enabled"] as? Bool == false)
    }

    @Test func guardMalformedConfigStaysOn() throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try Data("{ broken".utf8).write(to: f.configURL)
        #expect(GuardSettings.enabled(home: f.home))
    }

    @Test func guardUnreadableConfigStaysOn() throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        // A directory cannot be read as a config file, even when tests run as its owner.
        try FileManager.default.createDirectory(at: f.configURL, withIntermediateDirectories: true)
        #expect(GuardSettings.enabled(home: f.home))
    }

    @Test func guardEnvironmentOffBypassesBlockWithoutLogging() async throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try await f.prepareRepo()
        #expect(await f.guardCommand(overrides: ["RMJ_GUARD": "off"]) == 0)
        #expect(try f.lines().isEmpty)
        #expect(f.log.recent(limit: 10).isEmpty)
    }

    @Test func guardDisabledSettingBypassesBlockWithoutLogging() async throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try await f.prepareRepo()
        try Data(#"{"guard_enabled":false}"#.utf8).write(to: f.configURL)
        #expect(await f.guardCommand() == 0)
        #expect(try f.lines().isEmpty)
        #expect(f.log.recent(limit: 10).isEmpty)
    }

    @Test func guardEnvironmentZeroStillBlocks() async throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try await f.prepareRepo()
        #expect(await f.guardCommand(overrides: ["RMJ_GUARD": "0"]) == 2)
        #expect(f.log.recent(limit: 10).map(\.verdict) == ["block"])
    }

    @Test func guardEnvironmentCapitalizedOffStillBlocks() async throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try await f.prepareRepo()
        #expect(await f.guardCommand(overrides: ["RMJ_GUARD": "Off"]) == 2)
        #expect(f.log.recent(limit: 10).map(\.verdict) == ["block"])
    }

    @Test func guardBlockWritesOneCompleteLogLine() async throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try await f.prepareRepo()
        let before = Date()
        #expect(await f.guardCommand() == 2)
        let after = Date()
        let entries = f.log.recent(limit: 10)
        try #require(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.verdict == "block")
        #expect(entry.repo == "acme/orbit")
        #expect(entry.directory == f.repo.path)
        #expect(entry.command == "cargo test")
        #expect(entry.at >= before.addingTimeInterval(-1) && entry.at <= after)
        let line = try #require(f.lines().first)
        #expect(try f.lines().count == 1)
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        try #require(fields.count == 5)
        #expect(fields[0].hasSuffix("Z"))
        #expect(Array(fields.dropFirst()) == ["block", "acme/orbit", f.repo.path, "cargo test"])
    }

    @Test func guardAdviceWritesOneAdviceLine() async throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try await f.prepareRepo()
        #expect(await f.guardCommand("cargo build") == 0)
        #expect(try f.lines().count == 1)
        let entries = f.log.recent(limit: 10)
        #expect(entries.map(\.verdict) == ["advise"])
        #expect(entries.map(\.command) == ["cargo build"])
    }

    @Test func guardAllowWritesNoLine() async throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try await f.prepareRepo()
        #expect(await f.guardCommand("cargo fmt --all") == 0)
        #expect(try f.lines().isEmpty)
        #expect(f.log.recent(limit: 10).isEmpty)
    }

    @Test func guardQuietStillLogsBlocksAndAdvice() async throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try await f.prepareRepo()
        #expect(await f.guardCommand(quiet: true) == 2)
        #expect(await f.guardCommand("cargo build", quiet: true) == 0)
        #expect(try f.lines().count == 2)
        #expect(f.log.recent(limit: 10).map(\.verdict) == ["advise", "block"])
    }

    @Test func guardUnwritableLogPreservesBlockExitCode() async throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try await f.prepareRepo()
        try FileManager.default.createDirectory(at: f.logURL, withIntermediateDirectories: true)
        #expect(await f.guardCommand() == 2)
    }

    @Test func guardRecentIsNewestFirstSkipsDamageAndLimitsResults() throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        f.append("cargo test first", at: start)
        let handle = try FileHandle(forWritingTo: f.logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("damaged line\nnot-a-date\tblock\tacme/orbit\t/tmp\tcargo test\n".utf8))
        f.append("cargo test second", at: start.addingTimeInterval(1))
        f.append("cargo test third", at: start.addingTimeInterval(2))
        let all = f.log.recent(limit: 10)
        #expect(all.map(\.command) == ["cargo test third", "cargo test second", "cargo test first"])
        #expect(all.map(\.at) == [start.addingTimeInterval(2), start.addingTimeInterval(1), start])
        #expect(f.log.recent(limit: 2).map(\.command) == ["cargo test third", "cargo test second"])
        #expect(f.log.recent(limit: 0).isEmpty)
    }

    @Test func guardLogRetentionKeepsNewestThousandWithinTwelveHundredLines() throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 1...1300 { f.append("cargo test \(index)", at: start.addingTimeInterval(Double(index))) }
        let count = try f.lines().count
        #expect(count >= 1000 && count <= 1200)
        #expect(f.log.recent(limit: 1).first?.command == "cargo test 1300")
        #expect(f.log.recent(limit: 1000).map(\.command) == (301...1300).reversed().map { "cargo test \($0)" })
    }

    @Test func guardCommandControlsAreSanitizedAndCommandIsBounded() async throws {
        let f = try GuardVisibilityFixture(); defer { f.remove() }
        try await f.prepareRepo()
        let command = "cargo test\t--all\n\u{1B}[31mred\u{1B}[0m\u{07}\u{200B}\u{202E} " + String(repeating: "x", count: 500)
        #expect(await f.guardCommand(command) == 2)
        let lines = try f.lines()
        try #require(lines.count == 1)
        let fields = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
        try #require(fields.count == 5)
        let stored = String(fields[4])
        #expect(stored.hasPrefix("cargo test --all red"))
        #expect(stored.count <= 400)
        #expect(!stored.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet(charactersIn: "\u{200B}\u{202E}").contains($0) })
        #expect(f.log.recent(limit: 1).first?.command == stored)
    }
}
