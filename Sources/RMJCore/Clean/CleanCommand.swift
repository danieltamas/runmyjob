import Foundation

/// `rmj clean [--apply] [--json]` and `rmj clean log [--run <id>] [--json]`.
public enum CleanCommand {
    static let usage = "usage: rmj clean [--apply] [--json] | rmj clean log [--run <id>] [--json]"

    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        var rest = arguments[...]
        let showLog = rest.first == "log"
        if showLog { rest = rest.dropFirst() }
        var apply = false, json = false, runID: String?
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": json = true
            case "--apply" where !showLog: apply = true
            case "--run" where showLog:
                guard let value = rest.popFirst() else { return RunCommand.fail("--run needs a run id\n\(usage)", code: 2) }
                runID = value
            default: return RunCommand.fail("unknown argument \(argument)\n\(usage)", code: 2)
            }
        }
        let home = RMJHome(environment: environment)
        let ledger: Ledger
        do {
            try home.prepare()
            ledger = Ledger(database: try Database(url: home.url.appendingPathComponent("rmj.sqlite")))
        } catch { return RunCommand.fail("cannot open the ledger: \(error.localizedDescription)") }
        if showLog { return await history(ledger, runID: runID, json: json) }

        let loaded = CleanConfig.load(home: home)
        if let problem = loaded.problem { return RunCommand.fail("clean.json rejected, nothing was cleaned: \(problem)", code: 2) }
        let result = await Cleaner(ledger: ledger, config: loaded.config, logDirectory: home.url.appendingPathComponent("logs")).run(apply: apply)
        print(json ? jsonText(result) : text(result))
        if let problem = result.problem { _ = RunCommand.fail(problem) }
        return result.problem != nil || result.items.contains { $0.action == .failed } ? 1 : 0
    }

    private static func history(_ ledger: Ledger, runID: String?, json: Bool) async -> Int32 {
        do {
            if let runID {
                guard let run = try await ledger.cleanRun(id: runID) else { return RunCommand.fail("no clean run \(UntrustedText.clean(runID, limit: 40))") }
                print(json ? jsonText(run) : text(run))
                return 0
            }
            let runs = try await ledger.cleanRuns(limit: 20)
            if json {
                print(string(["runs": runs.map { ["run": $0.id, "apply": $0.apply, "freed_bytes": $0.freedBytes, "items": $0.items.count,
                                                  "started_at": CleanLog.stamp($0.startedAt)] as [String: Any] }]))
            } else {
                for run in runs {
                    print("\(run.id)  \(CleanLog.stamp(run.startedAt))  \(run.apply ? "apply" : "dry-run")  \(run.items.count) items  \(size(run.freedBytes)) freed")
                }
            }
            return 0
        } catch { return RunCommand.fail("cannot read the clean history: \(error.localizedDescription)") }
    }

    private static func string(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    private static func jsonText(_ run: CleanRun) -> String {
        string(["run": run.id, "apply": run.apply, "freed_bytes": run.freedBytes,
                "items": run.items.map { ["path": UntrustedText.clean($0.path), "kind": $0.kind.rawValue, "action": $0.action.rawValue,
                                          "reason": UntrustedText.clean($0.reason), "bytes": $0.bytes] as [String: Any] }])
    }

    private static func text(_ run: CleanRun) -> String {
        var lines = run.items.map { "\($0.action.rawValue)  \(size($0.bytes))  \($0.kind.rawValue)  \(UntrustedText.clean($0.path))  (\(UntrustedText.clean($0.reason)))" }
        lines.append("\(run.apply ? "applied" : "dry run"): \(run.items.count) items, \(size(run.freedBytes)) freed, run \(run.id)")
        if !run.apply { lines.append("nothing was removed; rerun with --apply to remove the would_remove items") }
        return lines.joined(separator: "\n")
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
