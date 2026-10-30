import Foundation

/// Turns what an agent left on the box into a branch, with git plumbing only: trees and commits are made in the
/// object store, so the worktree, its index, its HEAD and its checked-out branch are never written and nothing the
/// agent produced is applied, checked out or executed.
public enum AgentBranch {
    public enum Outcome: Sendable, Equatable {
        case unchanged
        case created(branch: String, commit: String)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case git(String)
        case invalidJobID
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .git(let message): "git failed: \(message)"
            case .invalidJobID: "the job id is not a valid branch name"
            case .tooLarge: "the agent's result is too large to import"
            }
        }
    }

    /// Files over this size, symlinks out of the tree and `.git` directories are not imported.
    static let fileLimit = 25 * 1024 * 1024
    static let totalLimit = 512 * 1024 * 1024

    /// The commit the result will be based on, when the checkout has one.
    public static func head(worktree: URL, runner: ProcessRunner = ProcessRunner()) async throws -> String? {
        try await Git(worktree: worktree, runner: runner).head()
    }

    /// The tree the sync sends: HEAD, plus uncommitted and untracked-but-not-ignored files, minus what the sync leaves out.
    public static func snapshot(worktree: URL, runner: ProcessRunner = ProcessRunner()) async throws -> String {
        let scratch = try await Scratch.make(worktree: worktree, runner: runner)
        defer { scratch.remove() }
        if let head = try await Git(worktree: worktree, runner: runner).head() { try await scratch.run(["read-tree", head], workTree: worktree) }
        try await scratch.run(["add", "-A"], workTree: worktree)
        let listed = paths(in: try await scratch.run(["ls-files", "-z"], workTree: worktree))
        try await scratch.run(["update-index", "--force-remove", "-z", "--stdin"], workTree: worktree,
                              input: nulSeparated(listed.filter(TreeSync.isExcluded)))
        return try await scratch.writeTree(workTree: worktree)
    }

    /// Imports `result` (a mirror of the box's directory) as a commit on `rmj/agent/<jobID>`, parented on `parent` (default HEAD).
    public static func record(worktree: URL, base: String, result: URL, jobID: String, message: String, parent: String? = nil, unborn: Bool = false,
                              runner: ProcessRunner = ProcessRunner()) async throws -> Outcome {
        guard jobID.range(of: "^[0-9A-Za-z][0-9A-Za-z_-]{0,63}$", options: .regularExpression) != nil else { throw Failure.invalidJobID }
        try removeUnimportable(in: result)
        let git = Git(worktree: worktree, runner: runner)
        let scratch = try await Scratch.make(worktree: worktree, runner: runner)
        defer { scratch.remove() }
        try await scratch.run(["read-tree", base], workTree: result)
        try await scratch.run(["add", "-A"], workTree: result)
        let tree = try await scratch.writeTree(workTree: result)
        if tree == base { return .unchanged }
        var parent = parent
        if parent == nil, !unborn { parent = try await git.head() }
        if let parent { try await keepWhatTheSyncLeftOut(scratch: scratch, parent: parent, worktree: worktree) }
        let finalTree = try await scratch.writeTree(workTree: result)
        var commitArguments = ["commit-tree", finalTree, "-m", UntrustedText.clean(message, limit: 200)]
        if let parent { commitArguments += ["-p", parent] }
        let commit = try await git.run(commitArguments, environment: try await git.identity()).trimmed
        let branch = "rmj/agent/\(jobID)"
        try await git.run(["update-ref", "refs/heads/\(branch)", commit, String(repeating: "0", count: commit.count)])
        return .created(branch: branch, commit: commit)
    }

    /// What the sync never sent (build output, vendored packages) stays as it is in the parent commit.
    private static func keepWhatTheSyncLeftOut(scratch: Scratch, parent: String, worktree: URL) async throws {
        let listed = try await scratch.run(["ls-tree", "-r", "-z", parent], workTree: worktree)
        // `ls-tree` prints "mode type sha<TAB>path"; `--index-info` wants "mode sha<TAB>path".
        var info = Data()
        for entry in listed.split(separator: 0) {
            let line = String(decoding: entry, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let fields = line[..<tab].split(separator: " ")
            let path = String(line[line.index(after: tab)...])
            guard fields.count == 3, TreeSync.isExcluded(path) else { continue }
            info.append(Data("\(fields[0]) \(fields[2])\t\(path)".utf8))
            info.append(0)
        }
        try await scratch.run(["update-index", "-z", "--index-info"], workTree: worktree, input: info)
    }

    /// Deletes from the mirror what must not reach the object store: any `.git`, symlinks that leave the mirror, big files.
    static func removeUnimportable(in root: URL) throws {
        let manager = FileManager.default
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey],
                                              options: [], errorHandler: nil) else { return }
        var total = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
            if url.lastPathComponent == ".git" {
                try manager.removeItem(at: url)
                if values.isDirectory == true { walker.skipDescendants() }
            } else if values.isSymbolicLink == true {
                let target = try manager.destinationOfSymbolicLink(atPath: url.path)
                let resolved = URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent()).standardizedFileURL.path
                if target.hasPrefix("/") || !(resolved == base || resolved.hasPrefix(base + "/")) { try manager.removeItem(at: url) }
            } else if values.isDirectory != true {
                let size = values.fileSize ?? 0
                if size > fileLimit { try manager.removeItem(at: url) } else { total += size }
            }
            if total > totalLimit { throw Failure.tooLarge }
        }
    }

    private static func paths(in listing: Data) -> [String] {
        listing.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func nulSeparated(_ paths: [String]) -> Data {
        var data = Data()
        for path in paths { data.append(Data(path.utf8)); data.append(0) }
        return data
    }

    /// The checkout's own repository, for the few steps that name its HEAD, its identity and its refs. Nothing here reads file content.
    private struct Git {
        let worktree: URL
        let runner: ProcessRunner

        @discardableResult
        func run(_ arguments: [String], environment: [String: String] = [:]) async throws -> Data {
            let output = try await runner.run("/usr/bin/git", ["-C", worktree.path, "-c", "commit.gpgsign=false"] + arguments,
                                              environment: environment, timeout: .seconds(300))
            guard output.status == 0 else { throw Failure.git(failure(output)) }
            return output.stdout
        }

        func head() async throws -> String? {
            let output = try await runner.run("/usr/bin/git", ["-C", worktree.path, "rev-parse", "--verify", "-q", "HEAD"], timeout: .seconds(30))
            return output.status == 0 ? output.stdout.trimmed : nil
        }

        /// The repository's own author, or a fixed one: the commit records who ran the agent, not the agent.
        func identity() async throws -> [String: String] {
            func config(_ key: String, fallback: String) async -> String {
                let output = try? await runner.run("/usr/bin/git", ["-C", worktree.path, "config", key], timeout: .seconds(10))
                let value = output.map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                return value.isEmpty ? fallback : value
            }
            let name = await config("user.name", fallback: "RMJ agent run"), email = await config("user.email", fallback: "rmj@localhost")
            return ["GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email]
        }
    }

    /// Where trees are built: an empty repository of its own that borrows only the checkout's object store. The checkout's
    /// config, attributes, filters and excludes are not read, so nothing the agent returned can select a program to run.
    private struct Scratch {
        let directory: URL
        let objects: String
        let runner: ProcessRunner

        var gitDir: URL { directory.appendingPathComponent("git") }
        var index: URL { directory.appendingPathComponent("index") }

        static func make(worktree: URL, runner: ProcessRunner) async throws -> Scratch {
            let found = try await runner.run("/usr/bin/git", ["-C", worktree.path, "rev-parse", "--path-format=absolute", "--git-path", "objects"],
                                             timeout: .seconds(30))
            guard found.status == 0 else { throw Failure.git(failure(found)) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-scratch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let scratch = Scratch(directory: directory, objects: found.stdout.trimmed, runner: runner)
            let created = try await runner.run("/usr/bin/git", ["init", "--bare", "-q", "--template=", scratch.gitDir.path],
                                               environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"], timeout: .seconds(30))
            guard created.status == 0 else { scratch.remove(); throw Failure.git(failure(created)) }
            return scratch
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        @discardableResult
        func run(_ arguments: [String], workTree: URL, input: Data? = nil) async throws -> Data {
            // Plain content: no filter, line-ending conversion, file monitor or user ignore file touches what the agent wrote.
            let flags = ["-c", "core.autocrlf=false", "-c", "core.safecrlf=false", "-c", "core.fsmonitor=false",
                         "-c", "core.attributesFile=/dev/null", "-c", "core.excludesFile=/dev/null"]
            let environment = ["GIT_DIR": gitDir.path, "GIT_WORK_TREE": workTree.path, "GIT_OBJECT_DIRECTORY": objects,
                               "GIT_INDEX_FILE": index.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_ATTR_NOSYSTEM": "1"]
            let output = try await runner.run("/usr/bin/git", flags + arguments, in: workTree, environment: environment, input: input,
                                              timeout: .seconds(300))
            guard output.status == 0 else { throw Failure.git(failure(output)) }
            return output.stdout
        }

        func writeTree(workTree: URL) async throws -> String { try await run(["write-tree"], workTree: workTree).trimmed }
    }

    private static func failure(_ output: ProcessOutput) -> String {
        UntrustedText.clean(output.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(output.status)", limit: 200)
    }
}

private extension Data {
    var trimmed: String { String(decoding: self, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}
