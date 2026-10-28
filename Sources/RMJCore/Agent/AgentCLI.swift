import Foundation

/// The read-only verbs of `rmj`: `jobs` with flags, `job`, `log`, `failures`, `destinations`, `runners`, `--json`
/// for the shapes of the MCP tools (docs/AGENT-API.md, CLI). There is no access switch here: a shell can run `rmj`.
public enum AgentCLI {
    public static let verbs: Set<String> = ["job", "log", "failures", "destinations", "runners"]

    public static func run(verb: String, arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        let home = RMJHome(environment: environment)
        let server: MCPServer
        do {
            try home.prepare()
            let database = try Database(url: home.url.appendingPathComponent("rmj.sqlite"))
            server = MCPServer(home: home, ledger: Ledger(database: database),
                               archive: LogArchive(database: database, directory: home.url.appendingPathComponent("logs")),
                               tailnet: { await TailnetState.read(environment: environment) })
        } catch { return fail("cannot open \(UntrustedText.clean(home.url.path)): \(UntrustedText.clean(error.localizedDescription))") }
        var json = false
        var options = [String: Any]()
        var positional = [String]()
        var rest = arguments[...]
        while let word = rest.popFirst() {
            guard word.hasPrefix("--") else { positional.append(word); continue }
            if word == "--json" { json = true; continue }
            guard let key = flags[word], let value = rest.popFirst() else { return fail("unknown or incomplete option \(UntrustedText.clean(word, limit: 40))", code: 2) }
            options[key.name] = key.integer ? (Int(value) as Any? ?? value) : value
        }
        if ["job", "log"].contains(verb) {
            guard let id = positional.first else { return fail("usage: rmj \(verb) <job id>", code: 2) }
            options["id"] = id
        }
        do {
            let body = try await server.data(verb, options)
            json ? printJSON(verb, body) : printText(verb, body)
            return 0
        } catch let error as BadArguments { return fail(error.message, code: 2)
        } catch let error as ToolFailure { return fail(error.message)
        } catch { return fail(UntrustedText.clean(error.localizedDescription)) }
    }

    private static let flags: [String: (name: String, integer: Bool)] = [
        "--state": ("state", false), "--repo": ("repo", false), "--destination": ("destination", false), "--source": ("source", false),
        "--since": ("since", false), "--limit": ("limit", true), "--tail": ("tail", true), "--target": ("target", false),
    ]

    private static func printJSON(_ tool: String, _ body: [String: Any]) {
        let key = tool == "failures" ? "jobs" : tool
        if tool != "job", tool != "log", let rows = body[key] as? [[String: Any]] {
            rows.forEach { print(MCPServer.encode($0)) }
        } else {
            print(MCPServer.encode(body))
        }
    }

    private static func printText(_ tool: String, _ body: [String: Any]) {
        switch tool {
        case "log":
            (body["lines"] as? [String] ?? []).forEach { print($0) }
            if let status = body["status"] as? String, status != "available" {
                FileHandle.standardError.write(Data("rmj: log \(status)\((body["reason"] as? String).map { ": " + $0 } ?? "")\n".utf8))
            }
        case "jobs", "failures":
            for job in body["jobs"] as? [[String: Any]] ?? [] {
                print(summary(job))
                (job["log_tail"] as? [String])?.forEach { print("    | \($0)") }
            }
        case "job":
            if let job = body["job"] as? [String: Any] { print(summary(job)) }
            for event in body["events"] as? [[String: Any]] ?? [] {
                print("    \(event["at"] ?? "")  \(event["state"] ?? "")  \(event["detail"] as? String ?? "")")
            }
        case "destinations":
            for card in body["destinations"] as? [[String: Any]] ?? [] {
                let state = (card["state"] as? [String: Any])?["kind"] as? String ?? "unknown"
                let capacity = card["capacity"] as? [String: Any]
                print("\(card["name"] ?? "")  \(card["tenant"] ?? "")  \(state)  \(capacity?["slots_used"] ?? 0)/\(capacity?["slots_max"] ?? 0) jobs")
            }
        default:
            for runner in body["runners"] as? [[String: Any]] ?? [] {
                print("\(runner["target"] as? String ?? "-")  \(runner["name"] ?? "")  \(runner["status"] ?? "")\((runner["busy"] as? Bool) == true ? " busy" : "")")
            }
        }
    }

    private static func summary(_ job: [String: Any]) -> String {
        let times = job["times"] as? [String: Any]
        let duration = (times?["duration_ms"] as? Int).map { "\($0) ms (\(times?["duration_source"] ?? "unknown"))" } ?? "unknown"
        let command = job["command"] as? [String: Any]
        let what = (command?["argv"] as? [String])?.joined(separator: " ") ?? (command?["workflow"] as? String ?? "")
        var line = "\(job["id"] ?? "")  \(job["state"] ?? "")  \(job["location"] ?? "")  \(String(what.prefix(60)))  \(duration)"
        if let reason = job["fallback_reason"] as? String { line += "  [\(reason)]" }
        return line
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data("rmj: \(message)\n".utf8))
        return code
    }
}
