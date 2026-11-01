import Foundation
import Testing
@testable import RMJCore

private struct CleanGitFixture {
    let files: CleanFixture
    let repo: URL
    var target: CleanTarget { CleanTarget(kind: .worktrees, path: repo.path, afterHours: 48) }

    static func make() async throws -> Self {
        let files = try CleanFixture()
        do {
            let origin = files.root.appendingPathComponent("origin.git")
            let repo = files.root.appendingPathComponent("clone")
            try await cleanProcess("/usr/bin/git", ["init", "--bare", origin.path])
            try await cleanProcess("/usr/bin/git", ["clone", origin.path, repo.path])
            let fixture = Self(files: files, repo: repo)
            try await fixture.git(["config", "user.name", "Acceptance"])
            try await fixture.git(["config", "user.email", "acceptance@example.invalid"])
            try await fixture.git(["checkout", "-b", "main"])
            try Data("tracked\n".utf8).write(to: repo.appendingPathComponent("tracked"))
            try await fixture.git(["add", "tracked"])
            try await fixture.git(["commit", "-m", "fixture"])
            try await fixture.git(["push", "-u", "origin", "main"])
            return fixture
        } catch { files.remove(); throw error }
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL? = nil) async throws -> String {
        let output = try await cleanProcess("/usr/bin/git", arguments, in: directory ?? repo)
        return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func worktree(_ name: String, detached: Bool = false) async throws -> URL {
        let path = repo.appendingPathComponent(".worktrees/" + name)
        try await git(detached ? ["worktree", "add", "--detach", path.path, "main"] :
                        ["worktree", "add", "-b", name, path.path, "main"])
        try await age(path)
        return path
    }
    func age(_ path: URL) async throws {
        // git-path resolves the linked worktree's private index and HEAD, not the main index.
        for name in ["HEAD", "index"] {
            let raw = try await git(["rev-parse", "--path-format=absolute", "--git-path", name], at: path)
            try files.old(URL(fileURLWithPath: raw))
        }
        try files.old(path)
    }
    func commit(_ path: URL) async throws {
        try Data("changed\n".utf8).write(to: path.appendingPathComponent("tracked"))
        try await git(["add", "tracked"], at: path)
        try await git(["commit", "-m", "unpublished fixture"], at: path)
        try await age(path)
    }
}

struct CleanWorktreeAcceptanceTests {
    @Test func cleanPushedOldWorktreeIsRemovedButItsBranchSurvives() async throws {
        let f = try await CleanGitFixture.make(); defer { f.files.remove() }
        let path = try await f.worktree("pushed")
        try await f.git(["push", "origin", "pushed"])
        try await f.age(path)
        let run = try await f.files.run([f.target])
        let item = try #require(run.items.first { $0.path == path.path })
        #expect(item.kind == .worktrees && item.action == .removed)
        #expect(!f.files.exists(path))
        #expect(try await f.git(["show-ref", "--verify", "refs/heads/pushed"]).contains("refs/heads/pushed"))
        #expect(try await f.git(["worktree", "list", "--porcelain"]).contains(path.path) == false)
        try await f.files.trace(run)
    }

    @Test(arguments: ["dirty", "untracked", "unpushed", "detached-unpushed", "recent index", "recent HEAD", "in use", "unregistered"])
    func unsafeWorktreesAreSkippedAndSurvive(scenario: String) async throws {
        let f = try await CleanGitFixture.make(); defer { f.files.remove() }
        let path: URL
        if scenario == "unregistered" {
            path = try f.files.directory("clone/.worktrees/fixture")
            try f.files.payload(path)
        } else {
            path = try await f.worktree("fixture", detached: scenario == "detached-unpushed")
            switch scenario {
            case "dirty": try Data("dirty\n".utf8).write(to: path.appendingPathComponent("tracked"))
            case "untracked": try Data("untracked\n".utf8).write(to: path.appendingPathComponent("untracked"))
            case "unpushed", "detached-unpushed": try await f.commit(path)
            case "recent index", "recent HEAD":
                let name = scenario == "recent index" ? "index" : "HEAD"
                let file = try await f.git(["rev-parse", "--path-format=absolute", "--git-path", name], at: path)
                try FileManager.default.setAttributes([.modificationDate: f.files.now], ofItemAtPath: file)
            default: break
            }
        }
        let busy = scenario == "in use", expectedPath = path.path
        let run = try await f.files.run([f.target], inUse: { busy && $0 == expectedPath })
        let item = try #require(run.items.first { $0.path == path.path })
        let reason: String
        switch scenario {
        case "untracked": reason = "dirty"
        case "unpushed", "detached-unpushed": reason = "unpushed commits"
        case "unregistered": reason = "not a registered worktree"
        case "recent index", "recent HEAD": reason = "recent"
        default: reason = scenario
        }
        #expect(item.action == .skipped && item.reason.contains(reason))
        #expect(f.files.exists(path))
        try await f.files.trace(run)
    }

    @Test func mainWorktreeIsNeverRemovedWhenItLivesUnderTheLinkedWorktreeRoot() async throws {
        let f = try await CleanGitFixture.make(); defer { f.files.remove() }
        let linked = try await f.worktree("linked")
        let moved = f.files.root.appendingPathComponent("linked")
        try await f.git(["worktree", "move", linked.path, moved.path])
        let container = moved.appendingPathComponent(".worktrees")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let main = container.appendingPathComponent("main")
        try FileManager.default.moveItem(at: f.repo, to: main)
        try await f.git(["worktree", "repair", moved.path], at: main)
        try await f.age(main)
        let target = CleanTarget(kind: .worktrees, path: moved.path, afterHours: 48)
        let run = try await f.files.run([target])
        let item = try #require(run.items.first { $0.path == main.path })
        #expect(item.action == .skipped && item.reason.contains("main"))
        #expect(f.files.exists(main) && f.files.exists(moved))
        try await f.files.trace(run)
    }

    @Test func invalidRepositoryFailsClosedAndPreservesDirectories() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let repo = try f.directory("not-a-repository"), path = try f.directory("not-a-repository/.worktrees/old")
        try f.payload(path)
        let run = try await f.run([CleanTarget(kind: .worktrees, path: repo.path, afterHours: 48)])
        #expect(!run.items.isEmpty)
        #expect(run.items.allSatisfy { ($0.action == .failed || $0.action == .skipped) && $0.reason.contains("git failed") })
        #expect(f.exists(repo) && f.exists(path) && run.freedBytes == 0)
        try await f.trace(run)
    }
}
