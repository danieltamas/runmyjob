import Foundation

/// A repository's linked worktrees under `<repo>/.worktrees`, judged by what git says about them.
struct WorktreeRepo: Sendable {
    let path: String
    private(set) var registered = Set<String>()
    private(set) var main: String?
    private(set) var failure: String?

    static func load(_ path: String) async -> WorktreeRepo {
        var repo = WorktreeRepo(path: path)
        switch await Git.run(["worktree", "list", "--porcelain"], in: path) {
        case .failure(let message): repo.failure = message
        case .success(let text):
            let paths = text.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.map { TreeMeasure.canonical(String($0.dropFirst(9))) }
            repo.registered = Set(paths)
            repo.main = paths.first
        }
        return repo
    }

    /// nil when `.worktrees` exists and cannot be listed; empty when there is none.
    var candidates: [String]? {
        let directory = path + "/.worktrees"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return TreeMeasure.kind(of: directory) == nil ? [] : nil
        }
        return names.sorted().map { directory + "/" + $0 }
    }

    /// nil when the worktree may go; otherwise why it stays. Cheap checks first; `recent` before `dirty`
    /// because nothing here may rewrite the index it reads.
    func verdict(for candidate: String, olderThan hours: Int, now: Date, busy: BusyProbe) async -> Cleaner.Verdict {
        switch TreeMeasure.kind(of: candidate) {
        case nil: return .skip("vanished")
        case mode_t(S_IFLNK)?: return .skip("symlink")
        case mode_t(S_IFDIR)?: break
        default: return .skip("not a directory")
        }
        if let failure { return .skip(failure) }
        let real = TreeMeasure.canonical(candidate)
        guard registered.contains(real) else { return .skip("not a registered worktree") }
        if real == main { return .skip("main worktree") }
        if await busy.isBusy(candidate) { return .skip("in use") }
        for name in ["HEAD", "index"] {
            switch await Git.run(["rev-parse", "--path-format=absolute", "--git-path", name], in: candidate) {
            case .failure(let message): return .skip(message)
            case .success(let file):
                var info = stat()
                let location = file.trimmingCharacters(in: .whitespacesAndNewlines)
                // A fresh worktree may have no index yet; any other failure to read the times proves nothing.
                if stat(location, &info) != 0 {
                    if name == "index", errno == ENOENT { continue }
                    return .skip("cannot read \(name) times")
                }
                if now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) < Double(hours) * 3600 {
                    return .skip("recent: \(name) changed within \(hours) h")
                }
            }
        }
        switch await Git.run(["status", "--porcelain"], in: candidate) {
        case .failure(let message): return .skip(message)
        case .success(let text): if !text.isEmpty { return .skip("dirty") }
        }
        switch await Git.run(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: candidate) {
        case .failure(let message): return .skip(message)
        case .success(let text): if text.trimmingCharacters(in: .whitespacesAndNewlines) != "0" { return .skip("unpushed commits") }
        }
        let repo = path
        return .remove(bytes: TreeMeasure(path: candidate).bytes, reason: "clean, every commit on a remote, idle over \(hours) h") {
            if case .failure(let message) = await Git.run(["worktree", "remove", candidate], in: repo) { return message }
            return nil
        }
    }
}

enum Git {
    enum Result { case success(String), failure(String) }

    /// `GIT_OPTIONAL_LOCKS=0` keeps `status` from refreshing, and so touching, the index it is asked about.
    static func run(_ arguments: [String], in directory: String) async -> Result {
        do {
            let output = try await ProcessRunner().run("/usr/bin/git", arguments, in: URL(fileURLWithPath: directory),
                environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"], timeout: .seconds(120))
            guard output.status == 0 else {
                let detail = output.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(output.status)"
                return .failure("git failed: \(UntrustedText.clean(detail, limit: 120))")
            }
            return .success(String(decoding: output.stdout, as: UTF8.self))
        } catch {
            return .failure("git failed: \(UntrustedText.clean(error.localizedDescription, limit: 120))")
        }
    }
}
