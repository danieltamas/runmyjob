import Foundation

/// Removes stale build scratch and idle agent worktrees from the configured targets. A dry run changes nothing;
/// every item, removed or not, lands in the ledger and in `clean.log`.
public struct Cleaner: Sendable {
    enum Verdict {
        case skip(String)
        /// `remover` returns nil when the removal worked, otherwise why it did not.
        case remove(bytes: Int, reason: String, remover: @Sendable () async -> String?)
    }

    let ledger: Ledger
    let config: CleanConfig
    let logDirectory: URL
    let now: @Sendable () -> Date
    let inUse: (@Sendable (String) async -> Bool)?

    public init(ledger: Ledger, config: CleanConfig, logDirectory: URL, now: @escaping @Sendable () -> Date = { Date() },
                inUse: (@Sendable (String) async -> Bool)? = nil) {
        self.ledger = ledger
        self.config = config
        self.logDirectory = logDirectory
        self.now = now
        self.inUse = inUse
    }

    private static func rounded(_ date: Date) -> Date { Ledger.date(Ledger.ms(date)) }

    /// `source` says who asked, for the `start` line of `clean.log`: `cli` or `schedule`.
    public func run(apply: Bool, source: String = "cli") async -> CleanRun {
        // Without a condition `execute` always returns a run.
        await execute(apply: apply, source: source, onlyIf: nil) ?? CleanRun(id: "", startedAt: now(), finishedAt: now(), apply: apply)
    }

    /// `onlyIf` is asked once the lock is held; false returns nil and leaves no trace.
    func execute(apply: Bool, source: String, onlyIf: (@Sendable () async -> Bool)?) async -> CleanRun? {
        let started = Self.rounded(now())
        var run = CleanRun(id: ULID.make(now: started), startedAt: started, finishedAt: started, apply: apply)
        let log = CleanLog(directory: logDirectory)
        let busy = BusyProbe(inUse)
        var traceFailure: String?
        // One cleaner at a time: the pending marker and the log are single files.
        let lock: Int32
        do { lock = try log.acquire() } catch {
            run.problem = "another rmj clean is running or \(CleanLog.lockName) is not usable: \(error.localizedDescription)"
            return run
        }
        defer { close(lock) }
        if let onlyIf, !(await onlyIf()) { return nil }
        // Writing the first line proves the log works before anything is removed.
        do {
            try log.recoverPending(at: started)
            try log.append([run.id, "start", apply ? "apply" : "dry-run", source], at: started)
        } catch { traceFailure = "clean.log is not writable" }

        func settle(_ path: String, _ kind: CleanTarget.Kind, _ verdict: Verdict) async {
            let item: CleanItem
            var pendingMarked = false
            switch verdict {
            case .skip(let reason):
                item = CleanItem(path: path, kind: kind, action: .skipped, reason: reason, bytes: 0)
            case .remove(let bytes, let reason, _) where !apply:
                item = CleanItem(path: path, kind: kind, action: .wouldRemove, reason: reason, bytes: bytes)
            case .remove(let bytes, _, _) where traceFailure != nil:
                item = CleanItem(path: path, kind: kind, action: .failed, reason: "not removed: \(traceFailure ?? "")", bytes: bytes)
            case .remove(let bytes, let reason, let remover):
                do {
                    try log.markPending(run: run.id, path: path)
                    pendingMarked = true
                    let failure = await remover()
                    item = CleanItem(path: path, kind: kind, action: failure == nil ? .removed : .failed, reason: failure ?? reason, bytes: bytes)
                } catch {
                    traceFailure = "clean.pending is not writable"
                    item = CleanItem(path: path, kind: kind, action: .failed, reason: "not removed: \(traceFailure ?? "")", bytes: bytes)
                }
            }
            run.items.append(item)
            do {
                try log.append([run.id, item.action.rawValue, item.kind.rawValue, String(item.bytes), item.path, item.reason], at: now())
                // The marker goes only once the outcome is on disk; a failed append leaves it for the next run to report.
                if pendingMarked { log.clearPending() }
            } catch { traceFailure = "clean.log is not writable" }
        }

        var seen = Set<String>()
        for target in config.targets {
            switch target.kind {
            case .scratch:
                let found = Self.matches(of: target.path)
                if let problem = found.problem { await settle(target.path, .scratch, .skip(problem)) }
                for path in found.paths where seen.insert(path).inserted {
                    await settle(path, .scratch, await scratchVerdict(path, hours: target.afterHours, busy: busy))
                }
            case .worktrees:
                let repo = await WorktreeRepo.load(target.path)
                guard let candidates = repo.candidates else { await settle(target.path, .worktrees, .skip("cannot list .worktrees")); continue }
                for path in candidates where seen.insert(path).inserted {
                    await settle(path, .worktrees, await repo.verdict(for: path, olderThan: target.afterHours, now: now(), busy: busy))
                }
            }
        }

        run.finishedAt = Self.rounded(now())
        if let traceFailure { run.problem = traceFailure }
        do { try await ledger.record(run) } catch { run.problem = "the ledger could not record this run: \(error)" }
        try? log.append([run.id, "summary", apply ? "apply" : "dry-run", String(run.freedBytes), "\(run.items.count) items", run.problem ?? "ok"], at: run.finishedAt)
        return run
    }

    private func scratchVerdict(_ path: String, hours: Int, busy: BusyProbe) async -> Verdict {
        switch TreeMeasure.kind(of: path) {
        case nil: return .skip("vanished")
        case mode_t(S_IFLNK)?: return .skip("symlink")
        case mode_t(S_IFDIR)?: break
        default: return .skip("not a directory")
        }
        if await busy.isBusy(path) { return .skip("in use") }
        let identity = TreeMeasure.identity(of: path)
        let tree = TreeMeasure(path: path)
        // A tree that cannot be read in full cannot be shown idle.
        if tree.unreadable { return .skip("unreadable") }
        let idle = now().timeIntervalSince(tree.newest)
        if idle < Double(hours) * 3600 { return .skip("recent: modified \(Int(idle / 3600)) h ago") }
        return .remove(bytes: tree.bytes, reason: "idle \(Int(idle / 3600)) h") {
            // The directory that was measured is the one that goes: a swapped path is left alone.
            guard identity != nil, TreeMeasure.identity(of: path) == identity else { return "changed while cleaning" }
            do { try FileManager.default.removeItem(atPath: path); return nil }
            catch { return "removal failed: \(UntrustedText.clean(error.localizedDescription, limit: 120))" }
        }
    }

    /// The directories a scratch path names: a literal, or the entries of its parent matching the last component.
    /// `problem` is set when the parent exists but cannot be listed: that is a skipped item, not a clean target.
    static func matches(of pattern: String) -> (paths: [String], problem: String?) {
        let url = URL(fileURLWithPath: pattern)
        let name = url.lastPathComponent
        guard name.contains(where: { "*?[".contains($0) }) else { return (TreeMeasure.kind(of: pattern) == nil ? [] : [pattern], nil) }
        let parent = url.deletingLastPathComponent().path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else {
            return ([], TreeMeasure.kind(of: parent) == nil ? nil : "cannot list the parent directory")
        }
        return (names.sorted().filter { fnmatch(name, $0, 0) == 0 }.map { parent + "/" + $0 }, nil)
    }
}
