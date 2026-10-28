import Foundation

extension MCPServer {
    func run(_ name: String, _ arguments: [String: Any]) async throws -> ToolOutput {
        switch name {
        case "destinations": _ = try ToolArguments(arguments, allowed: []); return try await destinations()
        case "tailnet": _ = try ToolArguments(arguments, allowed: []); return await tailnetResult()
        case "jobs": return try await jobs(ToolArguments(arguments, allowed: ["state", "repo", "destination", "source", "since", "limit", "cursor"]))
        case "job": return try await job(ToolArguments(arguments, allowed: ["id"]))
        case "failures": return try await failures(ToolArguments(arguments, allowed: ["since", "repo", "limit"]))
        case "log": return try await log(ToolArguments(arguments, allowed: ["id", "tail"]))
        case "route": return try await route(ToolArguments(arguments, allowed: ["repo", "command", "path"]))
        default: return try await runners(ToolArguments(arguments, allowed: ["target"]))
        }
    }

    // MARK: jobs

    private func logEntries() async throws -> [String: LogEntry] {
        let rows = try await archive.database.query("SELECT * FROM log_archive WHERE side = 'box'")
        return Dictionary(rows.compactMap(LogArchive.entry).map { ($0.jobID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func activity(_ job: JobRecord) -> Date { job.endedAt ?? job.startedAt ?? job.queuedAt }

    private func jobs(_ a: ToolArguments) async throws -> ToolOutput {
        let state = try a.choice("state", JobState.allCases.map(\.rawValue)), repo = try a.string("repo")?.lowercased()
        let destination = try a.string("destination"), source = try a.choice("source", ["rx", "github"])
        let since = try a.window("since"), limit = try a.integer("limit", in: 1...200) ?? 50
        let resume = try a.string("cursor").map(Self.parse)
        let cutoff = since.map { now().addingTimeInterval(-$0) }
        let rows = try await ledger.jobs().filter { job in
            (state == nil || job.state.rawValue == state) && (repo == nil || job.repo.lowercased() == repo)
                && (destination == nil || job.destination == destination)
                && (source == nil || (job.github != nil) == (source == "github"))
                && (cutoff == nil || activity(job) >= cutoff!)
                && (resume.map { Self.follows(job, $0) } ?? true)
        }
        let page = Array(rows.prefix(limit)), more = rows.count > limit
        let logs = try await logEntries()
        let built = page.map { AgentJob.json($0, log: logs[$0.id]) }
        let start: Any = a.values["cursor"] ?? NSNull()
        return .list(total: page.count) { count in
            let next: Any = count > 0 && (more || count < page.count) ? Self.cursor(page[count - 1]) : (count < page.count || more ? start : NSNull())
            return ["jobs": Array(built.prefix(count)), "next_cursor": next]
        }
    }

    /// Where a page ended: the queue time in milliseconds and the id, the ledger's own order.
    private static func cursor(_ job: JobRecord) -> String { "\(Ledger.ms(job.queuedAt)).\(job.id)" }

    private static func parse(_ cursor: String) throws -> (Int64, String) {
        let parts = cursor.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let ms = Int64(parts[0]), !parts[1].isEmpty else { throw BadArguments(message: "cursor is not one this server issued") }
        return (ms, parts[1])
    }

    private static func follows(_ job: JobRecord, _ position: (Int64, String)) -> Bool {
        let ms = Ledger.ms(job.queuedAt)
        return ms < position.0 || (ms == position.0 && job.id > position.1)
    }

    private func job(_ a: ToolArguments) async throws -> ToolOutput {
        let id = try a.ulid("id")
        guard let record = try await ledger.job(id) else { throw ToolFailure(message: "No job with that id.") }
        let entry = try await archive.entry(jobID: id)
        let events = try await ledger.events(id).map { event -> [String: Any] in
            ["at": AgentJob.stamp(event.at), "state": event.state.rawValue, "detail": AgentJob.text(event.detail)]
        }
        let row = AgentJob.json(record, log: entry)
        return .list(total: events.count) { ["job": row, "events": Array(events.prefix($0))] }
    }

    private func failures(_ a: ToolArguments) async throws -> ToolOutput {
        let since = try a.window("since") ?? 86_400, repo = try a.string("repo")?.lowercased()
        let limit = try a.integer("limit", in: 1...200) ?? 50
        let cutoff = now().addingTimeInterval(-since)
        let rows = try await ledger.jobs(in: [.failed, .lost]).filter { activity($0) >= cutoff && (repo == nil || $0.repo.lowercased() == repo) }
        let logs = try await logEntries()
        let built = rows.prefix(limit).map { job -> [String: Any] in
            var row = AgentJob.json(job, log: logs[job.id])
            let tail = logs[job.id].flatMap { $0.status == .available ? AgentLog.file(for: $0, in: archive) : nil }
                .flatMap { AgentLog.tail(of: $0, lines: 40) }
            row["log_tail"] = tail?.lines ?? NSNull()
            return row
        }
        return .list(total: built.count) { ["jobs": Array(built.prefix($0))] }
    }

    private func log(_ a: ToolArguments) async throws -> ToolOutput {
        let id = try a.ulid("id"), count = try a.integer("tail", in: 1...5000) ?? 200
        guard try await ledger.job(id) != nil else { throw ToolFailure(message: "No job with that id.") }
        // Only what the archive holds: a pending or missing log is reported, never fetched.
        guard let entry = try await archive.entry(jobID: id) else {
            return .fixed(["id": id, "status": "pending", "reason": "not archived yet", "lines": [String](), "truncated": false])
        }
        guard entry.status == .available else {
            return .fixed(["id": id, "status": entry.status.rawValue, "reason": AgentJob.text(entry.reason), "lines": [String](), "truncated": entry.truncated])
        }
        guard let file = AgentLog.file(for: entry, in: archive), let tail = AgentLog.tail(of: file, lines: count) else {
            throw ToolFailure(message: "The archived log cannot be read.")
        }
        return .list(total: tail.lines.count) { kept in
            ["id": id, "status": "available", "reason": NSNull(), "lines": Array(tail.lines.suffix(kept)),
             "truncated": entry.truncated || tail.truncated || kept < tail.lines.count]
        }
    }

    // MARK: fleet

    private func tailnetResult() async -> ToolOutput {
        let state = await tailnet()
        let backend: String, label: String
        switch state.standing {
        case .running: (backend, label) = ("Running", "running")
        case .stopped: (backend, label) = ("Stopped", "stopped")
        case .needsLogin: (backend, label) = ("NeedsLogin", "needs login")
        case .noClient: (backend, label) = ("NoClient", "no client")
        case .unknown(let why): (backend, label) = ("Unknown", "unknown (\(UntrustedText.clean(why)))")
        }
        let peers = state.peers.map { peer -> [String: Any] in
            let name = peer.dnsName.isEmpty ? peer.hostName : peer.dnsName
            return ["id": UntrustedText.clean(peer.id, limit: 100), "name": UntrustedText.clean(name.hasSuffix(".") ? String(name.dropLast()) : name),
                    "online": peer.online, "relayed": peer.relay != nil, "key_expiry": AgentJob.stamp(peer.keyExpiry)]
        }
        return .list(total: peers.count) { ["state": label, "backend_state": backend, "self_online": state.standing == .running,
                                              "peers": Array(peers.prefix($0))] }
    }

    private func registrations() async throws -> [[String: Any]] {
        let rows = try await ledger.database.query("SELECT * FROM runner_registration ORDER BY destination, runner")
        return rows.compactMap { row in
            guard let destination = row["destination"]?.textValue, let name = row["runner"]?.textValue,
                  let first = row["first_seen"]?.intValue, let last = row["last_seen"]?.intValue else { return nil }
            let seen = Date(timeIntervalSince1970: Double(last) / 1000)
            return ["target": UntrustedText.clean(destination, limit: 100), "name": UntrustedText.clean(name),
                    "version": NSNull(), "status": row["status"]?.textValue == "online" ? "online" : "offline",
                    "busy": row["busy"]?.intValue == 1, "readiness": "registered",
                    "first_seen": AgentJob.stamp(Date(timeIntervalSince1970: Double(first) / 1000)), "last_seen": AgentJob.stamp(seen),
                    "stale": now().timeIntervalSince(seen) > 600]
        }
    }

    private func runners(_ a: ToolArguments) async throws -> ToolOutput {
        let target = try a.string("target")
        let all = try await registrations().filter { target == nil || $0["target"] as? String == target }
        return .list(total: all.count) { ["runners": Array(all.prefix($0))] }
    }

    private func destinations() async throws -> ToolOutput {
        guard let rules = RulesStore(home: home).load().rules else { return .fixed(["destinations": [[String: Any]]()]) }
        let state = await tailnet()
        let live = try await ledger.jobs(in: [.running, .syncing]).filter { $0.github == nil }
        let registered = try await registrations()
        let cards = rules.destinations.keys.sorted().map { name -> [String: Any] in
            let config = rules.destinations[name]!
            let availability = DestinationResolver.resolve(DestinationTarget(alias: config.sshAlias, peerID: config.peerID), in: state)
            let mine = live.filter { $0.destination == name }
            let relayed = state.peers.first { $0.id == config.peerID }?.relay != nil
            let (kind, reason): (String, Any) = switch availability {
            case .online: (relayed ? "relayed" : "online", NSNull())
            case .offline(let why): (why.hasPrefix("tailnet down") ? "tailnet-down" : "offline", AgentJob.text(why))
            case .unreachable(let why): ("unreachable", AgentJob.text(why))
            case .rejected(let why): ("rejected", AgentJob.text(why))
            }
            let budget: Any = MemorySize.parse(config.memoryBudget).map { Double($0.bytes) / 1_073_741_824 } ?? NSNull()
            return [
                "name": UntrustedText.clean(name, limit: 100), "tenant": AgentJob.text(config.tenant, limit: 64), "roles": config.roles.map { UntrustedText.clean($0, limit: 64) },
                "state": ["kind": kind, "reason": reason, "since": AgentJob.stamp(state.readAt)] as [String: Any],
                "capacity": ["slots_used": mine.count, "slots_max": config.maxJobs, "memory_used_gb": NSNull(), "memory_budget_gb": budget,
                             "cpus": NSNull(), "load1": NSNull(), "free_gb": NSNull()] as [String: Any],
                "containers": mine.map { ["name": "rx-\($0.id)", "kind": "rx", "job_id": $0.id, "cpu_pct": NSNull(), "mem_mb": NSNull()] as [String: Any] },
                "runners": registered.filter { $0["target"] as? String == name },
                "images": [[String: Any]](), "probed_at": NSNull(), "stale": true,
            ]
        }
        return .list(total: cards.count) { ["destinations": Array(cards.prefix($0))] }
    }

    // MARK: route

    private func route(_ a: ToolArguments) async throws -> ToolOutput {
        let repo = try a.required("repo").lowercased(), command = try a.words("command"), path = try a.string("path")
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let plain = { (part: Substring) in !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } }
        guard parts.count == 2, parts.allSatisfy(plain) else { throw BadArguments(message: "repo must look like owner/name") }
        var identity = RepoIdentity(slug: repo, worktree: "", dirty: false)
        if let path {
            let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            // Git is not run here: a checkout's own config can name a program for `git status` to execute.
            guard let root = Self.checkoutRoot(directory) else { throw BadArguments(message: "path must be an existing git checkout") }
            identity = RepoIdentity(slug: repo, worktree: root, dirty: false)
        }
        let rules = RulesStore(home: home).load(), state = await tailnet()
        let router = Router(rules: rules, tailnet: state, probes: NoProbes(now: now), fileExists: { FileManager.default.fileExists(atPath: $0) }, now: now)
        let decision = await router.route(RouteRequest(command: command, identity: identity)).sanitized()
        let inputs: [String: Any] = [
            "repo": repo, "tenant": decision.tenant, "command": command.map { UntrustedText.clean($0, limit: 16_384) },
            "path": AgentJob.text(path), "worktree": AgentJob.text(identity.worktree.isEmpty ? nil : identity.worktree),
            "dirty": identity.dirty, "tailnet": UntrustedText.clean(Router.describe(state, at: now())), "probes": "none: live probes are not taken over MCP",
        ]
        return .fixed(["inputs": inputs, "chain": Self.chain(decision.explanation), "rule": AgentJob.text(decision.rule),
                       "result": decision.locationName, "fallback_reason": AgentJob.text(decision.fallbackReason)])
    }

    /// The directory holding `.git`, at or above `directory`.
    private static func checkoutRoot(_ directory: URL) -> String? {
        var current = directory.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        while true {
            if FileManager.default.fileExists(atPath: current + "/.git") { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    /// The destinations the router tried, read back from its explanation.
    private static func chain(_ explanation: [String]) -> [[String: Any]] {
        explanation.compactMap { line in
            if line.hasPrefix("skipped "), let colon = line.firstIndex(of: ":") {
                let destination = line[line.index(line.startIndex, offsetBy: 8)..<colon]
                return ["destination": String(destination), "verdict": "skipped", "reason": String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)]
            }
            if line.hasPrefix("result: "), let range = line.range(of: " at ") {
                return ["destination": String(line[line.index(line.startIndex, offsetBy: 8)..<range.lowerBound]), "verdict": "chosen", "reason": NSNull()]
            }
            return nil
        }
    }
}

/// Probes for `route` over MCP: none is cached and none is taken, so no tool can open ssh.
private struct NoProbes: ProbeProvider {
    let now: @Sendable () -> Date
    func latest(for destination: String) async -> DestinationProbeResult? { nil }
    func probe(_ target: DestinationTarget, tailnet: TailnetState) async -> DestinationProbeResult {
        .without(.unreachable("live probes are not taken over MCP"), at: now())
    }
}
