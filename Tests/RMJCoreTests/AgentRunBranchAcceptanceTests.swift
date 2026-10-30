import Foundation
import Testing
@testable import RMJCore

// Uses RunFixture's real temporary home and ProcessRunner, as the TreeSync tests do.
struct AgentBranchAcceptanceTests {
    @Test func changedResultMakesReviewBranchWithoutChangingDirtyCheckout() async throws {
        let f = try await AgentGitFixture.make(); defer { f.home.remove() }
        let before = try await f.state()
        let base = try await AgentBranch.snapshot(worktree: f.repo)
        let result = try await f.materialize(base)
        try f.write(result, "tracked.txt", "agent edit\n")
        try f.write(result, "new.txt", "new file\n")
        try FileManager.default.removeItem(at: result.appendingPathComponent("deleted.txt"))
        let outcome = try await AgentBranch.record(worktree: f.repo, base: base, result: result,
                                                   jobID: "acceptance-change", message: "agent result")
        guard case .created(let branch, let commit) = outcome else {
            Issue.record("changed tree must create a branch"); return
        }
        #expect(branch == "rmj/agent/acceptance-change")
        #expect(try await f.git(["rev-parse", branch]) == commit)
        #expect(try await f.git(["rev-parse", commit + "^"]) == before.head)
        #expect(try await f.git(["show", commit + ":tracked.txt"]) == "agent edit")
        #expect(try await f.git(["show", commit + ":dirty.txt"]) == "uncommitted before snapshot")
        #expect(try await f.git(["show", commit + ":untracked.txt"]) == "untracked before snapshot")
        #expect(try await f.git(["show", commit + ":new.txt"]) == "new file")
        let expected = ["dirty.txt", "new.txt", "tracked.txt", "untracked.txt"]
        #expect(try await f.git(["ls-tree", "-r", "--name-only", commit]).split(separator: "\n").map(String.init) == expected)
        // Independent result repository supplies the expected tree, not the implementation's snapshot.
        _ = try await f.gitAt(result, ["init"])
        _ = try await f.gitAt(result, ["add", "--all"])
        let expectedTree = try await f.gitAt(result, ["write-tree"])
        #expect(try await f.git(["rev-parse", commit + "^{tree}"]) == expectedTree)
        #expect(try await f.state() == before)
        #expect(try await f.git(["for-each-ref", "--format=%(refname)", "refs/heads"]) ==
            (before.branches + ["refs/heads/" + branch]).sorted().joined(separator: "\n"))
    }

    @Test func unchangedResultCreatesNoRefAndLeavesIndexBytesUntouched() async throws {
        let f = try await AgentGitFixture.make(); defer { f.home.remove() }
        let before = try await f.state()
        let base = try await AgentBranch.snapshot(worktree: f.repo)
        let result = try await f.materialize(base)
        let outcome = try await AgentBranch.record(worktree: f.repo, base: base, result: result,
                                                   jobID: "unchanged", message: "no change")
        guard case .unchanged = outcome else { Issue.record("unchanged tree created a commit"); return }
        #expect(try await f.state() == before)
        #expect(try await f.git(["for-each-ref", "--format=%(refname)", "refs/heads"]) == before.branches.joined(separator: "\n"))
    }

    @Test func hostileResultCannotImportMetadataEscapeLinksOrOversizedFiles() async throws {
        let f = try await AgentGitFixture.make(); defer { f.home.remove() }
        let before = try await f.state()
        let base = try await AgentBranch.snapshot(worktree: f.repo)
        let result = try await f.materialize(base)
        let outside = f.home.root.appendingPathComponent("outside")
        try Data("outside sentinel".utf8).write(to: outside)
        let outsideBefore = try Data(contentsOf: outside)
        let marker = f.home.root.appendingPathComponent("hook-executed")
        try f.write(result, ".git/hooks/post-commit", "#!/bin/sh\ntouch '" + marker.path + "'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: result.appendingPathComponent(".git/hooks/post-commit").path)
        try FileManager.default.createSymbolicLink(atPath: result.appendingPathComponent("passwd-link").path,
                                                  withDestinationPath: "/etc/passwd")
        try FileManager.default.createSymbolicLink(atPath: result.appendingPathComponent("relative-link").path,
                                                  withDestinationPath: "../outside")
        try Data(repeating: 65, count: 30 * 1024 * 1024).write(to: result.appendingPathComponent("large.bin"))
        try f.write(result, "a\nb", "newline filename content")
        try f.write(result, ".gitmodules", "[submodule \"untrusted\"]\npath = nowhere\nurl = /etc\n")
        let outcome = try await AgentBranch.record(worktree: f.repo, base: base, result: result,
                                                   jobID: "hostile", message: "hostile result")
        guard case .created(_, let commit) = outcome else { Issue.record("safe content must be imported"); return }
        let listing = try await f.rawGit(["ls-tree", "-rz", commit])
        let entries = listing.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        for entry in entries {
            let path = try #require(entry.split(separator: "\t", maxSplits: 1).last).description
            #expect(!path.split(separator: "/").contains(".git"))
            #expect(!entry.hasPrefix("120000 "))
            #expect(!["large.bin", "passwd-link", "relative-link"].contains(path))
        }
        #expect(try await f.git(["show", commit + ":a\nb"]) == "newline filename content")
        #expect(try await f.git(["show", commit + ":.gitmodules"]).contains("submodule"))
        #expect(try Data(contentsOf: outside) == outsideBefore)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try await f.state() == before)
    }

    @Test func trackedFilesExcludedFromSyncRemainInResultBranch() async throws {
        let f = try await AgentGitFixture.make(); defer { f.home.remove() }
        try f.write(f.repo, "target/tracked.txt", "tracked but excluded")
        _ = try await f.git(["add", "-f", "target/tracked.txt"])
        _ = try await f.git(["-c", "user.name=Acceptance", "-c", "user.email=acceptance@example.invalid", "commit", "-m", "excluded tracked file"])
        let before = try await f.state()
        let base = try await AgentBranch.snapshot(worktree: f.repo)
        let result = try await f.materialize(base)
        // A result returned by TreeSync never includes target, even when HEAD tracks it.
        let target = result.appendingPathComponent("target")
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try f.write(result, "new.txt", "agent change")
        let outcome = try await AgentBranch.record(worktree: f.repo, base: base, result: result,
                                                   jobID: "excluded", message: "preserve excluded tracked content")
        guard case .created(_, let commit) = outcome else { Issue.record("expected changed branch"); return }
        #expect(try await f.git(["show", commit + ":target/tracked.txt"]) == "tracked but excluded")
        #expect(try await f.state() == before)
    }

    @Test func snapshotMatchesTreeSyncExclusionsIncludingIgnoredAndUnsafeLinks() async throws {
        let f = try await AgentGitFixture.make(); defer { f.home.remove() }
        try f.write(f.repo, ".gitignore", "ignored/\n")
        try f.write(f.repo, "ignored/secret", "do not copy")
        try f.write(f.repo, "target/output", "build output")
        try f.write(f.repo, "node_modules/pkg/index.js", "dependency")
        let before = try await f.state()
        let base = try await AgentBranch.snapshot(worktree: f.repo)
        let mirror = f.home.root.appendingPathComponent("sync-mirror")
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        try await TreeSync.run(worktree: f.repo, destination: mirror.path + "/", shell: nil)
        _ = try await f.gitAt(mirror, ["init"])
        _ = try await f.gitAt(mirror, ["add", "--all"])
        #expect(try await f.gitAt(mirror, ["write-tree"]) == base)
        #expect(try await f.state() == before)
    }
}

struct AgentGitFixture {
    let home: RunFixture
    let repo: URL
    struct State: Equatable {
        let files: [String: Data]
        let index: Data
        let headFile: Data
        let head: String
        let status: Data
        let branches: [String]
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.files == rhs.files && lhs.index == rhs.index && lhs.headFile == rhs.headFile &&
                lhs.head == rhs.head && lhs.status == rhs.status
        }
    }
    static func make() async throws -> Self {
        let home = try await RunFixture.make()
        let repo = home.root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let f = Self(home: home, repo: repo)
        _ = try await f.git(["init"])
        for name in ["tracked.txt", "deleted.txt", "dirty.txt"] { try f.write(repo, name, "original\n") }
        _ = try await f.git(["add", "--all"])
        _ = try await f.git(["-c", "user.name=Acceptance", "-c", "user.email=acceptance@example.invalid", "commit", "-m", "baseline"])
        try f.write(repo, "dirty.txt", "uncommitted before snapshot\n")
        try f.write(repo, "untracked.txt", "untracked before snapshot\n")
        return f
    }
    func write(_ root: URL, _ path: String, _ value: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file)
    }
    func rawGit(_ args: [String]) async throws -> Data { try await rawGitAt(repo, args) }
    func rawGitAt(_ root: URL, _ args: [String]) async throws -> Data {
        let output = try await ProcessRunner().run("/usr/bin/git", ["--no-optional-locks", "-C", root.path] + args, timeout: .seconds(10))
        #expect(output.status == 0, "git \(args): \(output.stderr)")
        guard output.status == 0 else { throw BoxFailure("git fixture failed") }
        return output.stdout
    }
    func git(_ args: [String]) async throws -> String { try await gitAt(repo, args) }
    func gitAt(_ root: URL, _ args: [String]) async throws -> String {
        String(decoding: try await rawGitAt(root, args), as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func materialize(_ tree: String) async throws -> URL {
        let result = home.root.appendingPathComponent("result-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let paths = try await rawGit(["ls-tree", "-rz", "--name-only", tree]).split(separator: 0)
        for bytes in paths {
            let path = String(decoding: bytes, as: UTF8.self)
            let content = try await rawGit(["show", tree + ":" + path])
            let file = result.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file)
        }
        return result
    }
    func state() async throws -> State {
        // Capture status before index bytes, with optional locks disabled to avoid refreshing the index.
        let status = try await rawGit(["status", "--porcelain"])
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: repo.path)!
        while let relative = enumerator.nextObject() as? String {
            if relative.split(separator: "/").contains(".git") { enumerator.skipDescendants(); continue }
            let url = repo.appendingPathComponent(relative)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files[relative] = try Data(contentsOf: url) }
        }
        return State(files: files, index: try Data(contentsOf: repo.appendingPathComponent(".git/index")),
                     headFile: try Data(contentsOf: repo.appendingPathComponent(".git/HEAD")),
                     head: try await git(["rev-parse", "HEAD"]), status: status,
                     branches: try await git(["for-each-ref", "--format=%(refname)", "refs/heads"]).split(separator: "\n").map(String.init))
    }
}
