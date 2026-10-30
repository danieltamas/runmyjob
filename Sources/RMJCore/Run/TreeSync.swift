import Foundation

/// Mirrors a checkout to a directory: what git sees is what the box sees. Tracked files (even ones a
/// .gitignore pattern would hide) and untracked edits go; ignored build output, `.git` and `node_modules`
/// do not, and a symlink pointing outside the checkout is never followed.
public enum TreeSync {
    public enum Failure: Error, LocalizedError, Equatable {
        case rsyncFailed(Int32, String)
        case noRsync
        case gitFailed

        public var errorDescription: String? {
            switch self {
            case .rsyncFailed(let status, let message): "rsync exit \(status): \(message)"
            case .noRsync: "rsync is not installed on this Mac"
            case .gitFailed: "git could not list the ignored files, so nothing was sent"
            }
        }
    }

    static let fixedExcludes = ["/.git", "/.worktrees", "/.claude/worktrees", "/target", "node_modules", "/graphify-out",
                                "/brag-output", ".DS_Store", "/.rmj", "/.rmj-worktree"]
    /// The box's own files in the synced directory: never deleted by the mirror.
    static let protected = ["/.rmj-worktree", "/.rmj"]

    /// Homebrew's rsync first: the system one is openrsync and lacks options the box side relies on.
    public static func rsyncPath() -> String? {
        ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"].first(where: FileManager.default.isExecutableFile)
    }

    /// `destination` is `alias:/dir/` over ssh (with `shell`) or a local directory (tests).
    public static func run(worktree: URL, destination: String, shell: String?, runner: ProcessRunner = ProcessRunner()) async throws {
        guard let rsync = rsyncPath() else { throw Failure.noRsync }
        let ignored = try await runner.run("/usr/bin/git", ["-C", worktree.path, "ls-files", "-z", "-o", "-i", "--exclude-standard", "--directory"],
                                           timeout: .seconds(60))
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: list) }
        // Without the list, ignored files (an .env, credentials) would be sent: no list, no sync.
        guard ignored.status == 0, ignored.stdout.count < ProcessRunner.collectedLimit else { throw Failure.gitFailed }
        guard FileManager.default.createFile(atPath: list.path, contents: exclusions(from: ignored.stdout),
                                             attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        // openrsync (the system rsync on recent macOS) ignores protect rules, so with --delete-excluded it would delete the
        // box's own files; without it, excluded names are simply left alone on the box.
        let version = try? await runner.run(rsync, ["--version"], timeout: .seconds(10))
        let honorsProtect = !(version.map { String(decoding: $0.stdout, as: UTF8.self).contains("openrsync") } ?? true)
        var arguments = ["-az", "--delete", "--safe-links", "--from0"]
        if honorsProtect { arguments += ["--delete-excluded"] + protected.flatMap { ["--filter", "P \($0)"] } }
        arguments += ["--exclude-from=\(list.path)"] + fixedExcludes.flatMap { ["--exclude", $0] }
        if let shell { arguments += ["-e", shell] }
        arguments += [worktree.path + "/", destination]
        let output = try await runner.run(rsync, arguments, timeout: .seconds(1800))
        guard output.status == 0 else {
            throw Failure.rsyncFailed(output.status, UntrustedText.clean(output.stderr.split(separator: "\n").first.map(String.init) ?? "", limit: 200))
        }
    }

    /// Anchored, glob characters escaped, so a file named `[x]*` excludes only itself.
    static func exclusions(from listing: Data) -> Data {
        var lines = Data()
        for entry in listing.split(separator: 0) {
            var escaped = Data("/".utf8)
            for byte in entry {
                if "\\*?[".utf8.contains(byte) { escaped.append(UInt8(ascii: "\\")) }
                escaped.append(byte)
            }
            lines.append(escaped)
            lines.append(0)
        }
        return lines
    }
}
