import Testing
import Foundation
import RMJCore

struct RunSupportAcceptanceTests {
    @Test func sanitizerStripsEscapesControlsAndInvisibleUnicodeAcrossEveryChunkBoundary() {
        let raw = Data("a\u{1B}[31mred\u{1B}[0m\u{1B}]0;title\u{07}b\u{01}\u{7F}\u{200B}\u{FEFF}\u{00A0}\n\tcaf\u{00E9}\u{0219}".utf8)
        let expected = Data("aredb\n\tcaf\u{00E9}\u{0219}".utf8)
        var whole = LogSanitizer()
        #expect(whole.clean(raw) == expected)
        for split in 0...raw.count {
            var stream = LogSanitizer()
            var output = stream.clean(Data(raw.prefix(split)))
            output.append(stream.clean(Data(raw.dropFirst(split))))
            #expect(output == expected, "split at byte \(split)")
        }
        var bytewise = LogSanitizer()
        var output = Data()
        for byte in raw { output.append(bytewise.clean(Data([byte]))) }
        #expect(output == expected)
    }

    @Test func ulidsAreSortableUniqueCrockfordAndSafeDockerNames() {
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let ids = (0..<100).map { ULID.make(now: runNow.addingTimeInterval(Double($0))) }
        #expect(ids.allSatisfy { $0.count == 26 && Set($0).isSubset(of: alphabet) })
        #expect(zip(ids, ids.dropFirst()).allSatisfy { $0.0 < $0.1 })
        #expect(ULID.make(now: runNow) != ULID.make(now: runNow))
        for repo in ["acme/ledger", nil] as [String?] {
            let name = ULID.containerName(repo: repo, ulid: ids[0])
            #expect(name.hasPrefix("rx-") && name.count <= 40)
            #expect(name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
        }
    }

    @Test func agentContextDetectsHarnessAndSessionOrTerminal() {
        let cases: [([String: String], AgentContext)] = [
            (["CLAUDE_CODE_SESSION_ID": "abc", "CLAUDECODE": "1"], .init(agent: "claude-code", session: "abc")),
            (["CODEX_THREAD_ID": "thread"], .init(agent: "codex", session: "thread")),
            (["OPENCODE_SESSION_ID": "open"], .init(agent: "opencode", session: "open")),
            (["HERMES_SESSION_ID": "hermes-session"], .init(agent: "hermes", session: "hermes-session")),
            ([:], .init(agent: "terminal"))
        ]
        for (environment, expected) in cases { #expect(AgentContext.detect(environment: environment) == expected) }
    }

    @Test func boxRecordAndLaunchParseRealScriptLinesAndNanosecondTimes() throws {
        let record = try #require(BoxRecord.parse("""
        garbage line
        container present B
        launch started C B
        rc 0
        meta started=2026-10-27T10:00:00.123456789Z finished=2026-10-27T10:00:02.623456789Z exit=0
        more garbage
        """))
        #expect(record.containerPresent && record.bootID == "B")
        #expect(record.launch == .started(container: "C", bootID: "B"))
        #expect(record.result == .init(code: 0))
        let meta = try #require(record.meta)
        let start = try #require(meta.started), finish = try #require(meta.finished)
        #expect(abs(finish.timeIntervalSince(start) - 2.5) < 0.001)
        #expect(meta.exit == 0)
        let failed = try #require(BoxRecord.parse("container absent B\nlaunch start-failed no such image\nrc 125 start-failed\n"))
        #expect(!failed.containerPresent && failed.bootID == "B")
        #expect(failed.launch == .startFailed("no such image"))
        #expect(failed.result == .init(code: 125))
        #expect(BoxRecord.parse("container absent B\nrc 137 cancelled\n")?.result == .init(code: 137, cancelled: true))
        #expect(BoxRecord.parse("garbage\nrc 0\n") == nil)
        #expect(BoxLaunch.parse("started C B") == .started(container: "C", bootID: "B"))
        #expect(BoxLaunch.parse("start-failed no such image") == .startFailed("no such image"))
        #expect(BoxLaunch.parse("garbage") == nil)
    }

    @Test func treeSyncMirrorsGitVisibleFilesAndPreservesBoxOwnedFiles() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        let source = f.root.appendingPathComponent("checkout"), destination = f.root.appendingPathComponent("mirror")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        func write(_ base: URL, _ name: String, _ content: String) throws {
            let url = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        func git(_ args: [String]) async throws {
            let result = try await ProcessRunner().run("/usr/bin/git", ["-C", source.path] + args, timeout: .seconds(10))
            #expect(result.status == 0, "git \(args): \(result.stderr)")
        }
        try await git(["init"])
        try write(source, ".gitignore", "dist/\nbuild/\nnode_modules/\ntarget/\n\\[x\\]\\*.txt\n")
        try write(source, "tracked.txt", "tracked")
        try write(source, "deleted.txt", "delete me")
        try write(source, "dist/keep.js", "tracked despite ignore")
        try await git(["add", ".gitignore", "tracked.txt", "deleted.txt"])
        try await git(["add", "-f", "dist/keep.js"])
        try await git(["-c", "user.name=Acceptance", "-c", "user.email=acceptance@example.invalid", "commit", "-m", "fixture"])
        let facts = await GitFacts.read(in: source)
        #expect(facts.branch != nil && facts.commit != nil)
        try write(source, "untracked.txt", "untracked")
        try write(source, "dist/drop.js", "ignored")
        try write(source, "build/output", "ignored")
        try write(source, "node_modules/pkg/index.js", "ignored")
        try write(source, "target/debug/app", "ignored")
        try write(source, ".DS_Store", "ignored")
        try write(source, "[x]*.txt", "ignored literal glob")
        try write(source, "x.txt", "included sibling")
        let outside = f.root.appendingPathComponent("outside-secret")
        try Data("outside-secret-content".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("outside-link"), withDestinationURL: outside)
        try write(destination, ".rmj-worktree", "box identity")
        try write(destination, ".rmj/exec", "box executable")
        try await TreeSync.run(worktree: source, destination: destination.path + "/", shell: nil)
        for (name, content) in [("tracked.txt", "tracked"), ("dist/keep.js", "tracked despite ignore"),
                                ("untracked.txt", "untracked"), ("x.txt", "included sibling")] {
            #expect(try String(contentsOf: destination.appendingPathComponent(name), encoding: .utf8) == content)
        }
        for name in [".git", "dist/drop.js", "build", "node_modules", "target", ".DS_Store", "[x]*.txt", "outside-link"] {
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path), "excluded \(name)")
        }
        try FileManager.default.removeItem(at: source.appendingPathComponent("deleted.txt"))
        try await TreeSync.run(worktree: source, destination: destination.path + "/", shell: nil)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("deleted.txt").path))
        #expect(try String(contentsOf: destination.appendingPathComponent(".rmj-worktree"), encoding: .utf8) == "box identity")
        #expect(try String(contentsOf: destination.appendingPathComponent(".rmj/exec"), encoding: .utf8) == "box executable")
    }

    @Test func ledgerRoundTripsAllRunContextFields() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        var row = JobRecord(id: ULID.make(), repo: "acme/axon", command: "true", location: "local", queuedAt: runNow)
        row.tenant = "personal"; row.worktree = f.root.path; row.branch = "feature/u4"; row.commit = "abcdef0"
        row.dirty = true; row.agent = "codex"; row.session = "thread-u4"
        try await f.ledger.insert(row)
        #expect(try await f.ledger.job(row.id) == row)
    }

    @Test func relocateMovesOnlyQueuedAndSyncingRows() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        for state in [JobState.queued, .syncing, .running] {
            let id = try await f.insert(state)
            let before = try await f.ledger.job(id)
            let moved = try await f.ledger.relocate(id, toLocalBecause: "sync failed", at: runNow)
            let after = try #require(try await f.ledger.job(id))
            if state == .running { #expect(!moved && after == before) }
            else {
                #expect(moved && after.state == state && after.location == "local")
                #expect(after.destination == nil && after.environment == "mac" && after.fallbackReason == "sync failed")
            }
        }
    }
}
