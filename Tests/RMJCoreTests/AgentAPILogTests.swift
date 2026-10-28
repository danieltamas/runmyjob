import Foundation
import CoreFoundation
import Testing
import RMJCore

struct AgentAPILogTests {
    @Test func failuresAreWindowedFailedOrLostWithRedactedLastFortyLines() async throws {
        let f = try AgentFixture()
        defer { f.remove() }
        let rows = [f.job(1, state: .failed), f.job(2, state: .lost), f.job(3, state: .done),
                    f.job(4, state: .failed, age: 172800), f.job(5, state: .failed, repo: "acme/other")]
        for row in rows { try await f.ledger.insert(row) }
        let secret = "ghp_acceptanceSecretValue123456789"
        let lines = (1...60).map { "line \($0) \(secret)" }
        try await f.writeLog(rows[0].id, lines.joined(separator: "\n") + "\n", secrets: [secret])
        let failures = try await f.rows("failures")
        #expect(agentIDs(failures) == [rows[0].id, rows[1].id, rows[4].id])
        let failed = try #require(failures.first { $0["id"] as? String == rows[0].id })
        let tail = try #require(failed["log_tail"] as? [String])
        #expect(tail == (21...60).map { "line \($0) [redacted]" })
        #expect(!tail.joined().contains(secret))
        let lost = try #require(failures.first { $0["id"] as? String == rows[1].id })
        #expect(lost["log_tail"] is NSNull)
        #expect(agentIDs(try await f.rows("failures", ["repo": "acme/ledger"])) == [rows[0].id, rows[1].id])
        #expect(try await f.rows("failures", ["limit": 1]).count == 1)
        #expect(agentIDs(try await f.rows("failures", ["since": "7d"])) == [rows[0].id, rows[1].id, rows[3].id, rows[4].id])
    }

    @Test func archivedLogTailDefaultsBoundsAndSanitization() async throws {
        let f = try AgentFixture()
        defer { f.remove() }
        let job = f.job(1, state: .failed)
        try await f.ledger.insert(job)
        let lines = (1...5100).map { "line \($0)" }
        try await f.writeLog(job.id, lines.joined(separator: "\n") + "\n")
        for (args, count) in [(["id": job.id] as AgentJSON, 200), (["id": job.id, "tail": 3], 3), (["id": job.id, "tail": 5000], 5000)] {
            let body = try await f.data("log", args)
            #expect(body["status"] as? String == "available")
            #expect(body["id"] as? String == job.id)
            #expect(body["reason"] is NSNull)
            #expect(body["lines"] as? [String] == Array(lines.suffix(count)))
        }
        for tail in [0, 5001] { try agentError(try await f.call("log", ["id": job.id, "tail": tail])) }
        try agentError(try await f.call("log", ["id": "../outside"]))
        let dirty = "\u{1B}[31mred\u{1B}[0m \u{1B}]8;;https://example.invalid\u{07}link\u{1B}]8;;\u{07} a\u{200B}b\u{202E}c\u{FEFF}d"
        let long = String(repeating: "x", count: 4500)
        try await f.writeLog(job.id, dirty + "\n" + long + "\n")
        let body = try await f.data("log", ["id": job.id])
        let clean = try #require(body["lines"] as? [String])
        #expect(clean.count == 2)
        #expect(clean.first == "red link abcd")
        let cut = try #require(clean.last)
        #expect(cut != long)
        #expect(cut.hasPrefix(String(repeating: "x", count: 3900)))
        #expect(cut.contains("truncat") || cut.contains("cut"))
        #expect(cut.count <= 4100) // At most 4000 content characters plus a short marker.
        #expect(body["truncated"] as? Bool == true)
    }

    @Test func pendingAndUnavailableLogsRemainLocalAndReturnNoLines() async throws {
        let f = try AgentFixture()
        defer { f.remove() }
        for (n, status, reason) in [(1, "pending", "box offline"), (2, "unavailable", "archive expired")] {
            let job = f.job(n, state: .lost, destination: "offline-box")
            try await f.ledger.insert(job)
            if status == "pending" {
                try await f.archive.markPending(jobID: job.id, reason: reason, now: agentNow)
            } else {
                try await f.archive.markUnavailable(jobID: job.id, reason: reason, now: agentNow)
            }
            let before = try await f.archive.entry(jobID: job.id)
            let start = ContinuousClock.now
            // The declared MCPServer initializer has no box client to inject or call.
            let body = try await f.data("log", ["id": job.id])
            #expect(start.duration(to: .now) < .milliseconds(500))
            #expect(body["status"] as? String == status)
            #expect(body["reason"] as? String == reason)
            #expect(body["lines"] as? [String] == [])
            #expect(try await f.archive.entry(jobID: job.id) == before)
        }
    }

    @Test func archivePathOutsideDirectoryIsNeverReturned() async throws {
        let f = try AgentFixture()
        defer { f.remove() }
        let job = f.job(1)
        try await f.ledger.insert(job)
        try await f.writeLog(job.id, "inside\n")
        let outside = f.home.url.appendingPathComponent("outside-secret.log")
        try Data("OUTSIDE-ARCHIVE-SECRET".utf8).write(to: outside)
        // Corrupt persisted metadata, not the production archive writer.
        try await f.database.execute("UPDATE log_archive SET path = ? WHERE job_id = ?", [.text(outside.path), .text(job.id)])
        let response = try await f.call("log", ["id": job.id])
        if response["error"] != nil { try agentError(response) } else {
            #expect(try #require(response["result"] as? AgentJSON)["isError"] as? Bool == true)
        }
        #expect(!String(describing: response).contains("OUTSIDE-ARCHIVE-SECRET"))
    }

    @Test func oversizedResponseIsBoundedAndMarkedTruncated() async throws {
        let f = try AgentFixture()
        defer { f.remove() }
        let command = "echo " + String(repeating: "x", count: 16000)
        for n in 1...200 { try await f.ledger.insert(f.job(n, command: command)) }
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jobs","arguments":{"limit":200}}}"#
        let line = try #require(await f.server.handle(request))
        #expect(line.utf8.count <= 1_048_576)
        let response = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? AgentJSON)
        let result = try #require(response["result"] as? AgentJSON)
        let body = try #require(result["structuredContent"] as? AgentJSON)
        #expect(body["truncated"] as? Bool == true)
        #expect(try JSONSerialization.data(withJSONObject: response).count <= 1_048_576)
        let text = try #require((result["content"] as? [AgentJSON])?.first?["text"] as? String)
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? AgentJSON)
        #expect(decoded["truncated"] as? Bool == true)
    }

    @Test func routeExplainsTheCLIRouterDecisionWithoutRunningACommand() async throws {
        let f = try AgentFixture()
        defer { f.remove() }
        let rules = #"{"destinations":{},"tenants":{"acme":{"owners":["acme"]}},"rules":[{"name":"explain only","match":{"repo":["acme/ledger"]},"to":["local"]}]}"#
        let url = f.home.url.appendingPathComponent("rules.json")
        try Data(rules.utf8).write(to: url)
        let marker = f.home.url.appendingPathComponent("MUST-NOT-EXIST")
        let command = ["touch", marker.path]
        let body = try await f.data("route", ["repo": "acme/ledger", "command": command])
        let state = TailnetState(standing: .stopped, magicDNSEnabled: false, peers: [], readAt: agentNow)
        let router = Router(rules: RulesStore(home: f.home).load(), tailnet: state,
                            probes: AgentNoProbe(), fileExists: { _ in false }, now: { agentNow })
        // RouteCommand.run uses this same Router entry point; it has no pure CLI serializer.
        let decision = await router.route(RouteRequest(command: command,
            identity: RepoIdentity(slug: "acme/ledger", worktree: "", dirty: false))).sanitized()
        #expect(body["result"] as? String == decision.locationName)
        #expect(body["rule"] as? String == decision.rule)
        #expect(body["rule"] as? String == "explain only")
        #expect(body["fallback_reason"] is NSNull)
        #expect(body["inputs"] as? AgentJSON != nil)
        #expect(body["chain"] as? [AgentJSON] != nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try await f.ledger.jobs().isEmpty)
        #expect(try Data(contentsOf: url) == Data(rules.utf8))
    }

    @Test func tailnetReflectsInjectedStateAndPeer() async throws {
        let json = #"{"BackendState":"Running","Self":{"Online":true},"Peer":{"p":{"ID":"peer-fixture","HostName":"fixture-box","DNSName":"fixture-box.test.ts.net.","Online":true,"Relay":"fra","KeyExpiry":"2030-01-01T00:00:00Z"}}}"#
        let state = TailnetState.parse(Data(json.utf8), readAt: agentNow)
        let f = try AgentFixture(tailnet: state)
        defer { f.remove() }
        let body = try await f.data("tailnet")
        #expect(body["backend_state"] as? String == "Running")
        #expect(body["self_online"] as? Bool == true)
        #expect(body["state"] as? String != nil)
        let peers = try #require(body["peers"] as? [AgentJSON])
        #expect(peers.count == 1)
        #expect(peers.first?["id"] as? String == "peer-fixture")
        #expect((peers.first?["name"] as? String)?.contains("fixture-box") == true)
        #expect(peers.first?["online"] as? Bool == true)
        #expect(peers.first?["relayed"] as? Bool == true)
        #expect(peers.first?["key_expiry"] as? String != nil)
    }

    @Test func everyStructuredToolResultMatchesItsAdvertisedSchema() async throws {
        let f = try AgentFixture()
        defer { f.remove() }
        let row = f.job(1, state: .failed)
        try await f.ledger.insert(row)
        try await f.writeLog(row.id, "fixture log\n")
        let listed = try #require(try await f.rpc("tools/list")["result"] as? AgentJSON)
        let tools = try #require(listed["tools"] as? [AgentJSON])
        let arguments: [String: AgentJSON] = ["job": ["id": row.id], "log": ["id": row.id],
            "route": ["repo": "acme/ledger", "command": ["true"]]]
        for name in ["jobs", "job", "failures", "log", "tailnet", "destinations", "route", "runners"] {
            let tool = try #require(tools.first { $0["name"] as? String == name })
            let schema = try #require(tool["outputSchema"] as? AgentJSON)
            let body = try await f.data(name, arguments[name] ?? [:])
            #expect(agentSchemaMatches(body, schema), "Output schema mismatch for \(name)")
        }
        // The checker must reject invalid data rather than silently accepting every schema.
        #expect(!agentSchemaMatches([:], ["type": "object", "required": ["jobs"]]))
        #expect(!agentSchemaMatches("bad", ["type": "integer"]))
        #expect(!agentSchemaMatches(true, ["type": "number"]))
        #expect(agentSchemaMatches(NSNull(), ["anyOf": [["type": "null"], ["type": "string"]]]))
        #expect(!agentSchemaMatches("x", ["oneOf": [["type": "string"], ["type": "string"]]]))
    }
}

private struct AgentNoProbe: ProbeProvider {
    func latest(for destination: String) async -> DestinationProbeResult? { nil }
    func probe(_ target: DestinationTarget, tailnet: TailnetState) async -> DestinationProbeResult {
        Issue.record("An explain-only local rule must not probe a destination")
        return await DestinationProbe().probe(target, tailnet: TailnetState(
            standing: .stopped, magicDNSEnabled: false, peers: [], readAt: agentNow))
    }
}

// Intentionally small JSON Schema subset used by the documented tool output schemas.
private func agentSchemaMatches(_ value: Any, _ schema: AgentJSON) -> Bool {
    if let branches = schema["anyOf"] as? [AgentJSON], !branches.contains(where: { agentSchemaMatches(value, $0) }) { return false }
    if let branches = schema["oneOf"] as? [AgentJSON], branches.filter({ agentSchemaMatches(value, $0) }).count != 1 { return false }
    if let choices = schema["enum"] as? [Any], !choices.contains(where: { NSArray(array: [$0]).isEqual(to: [value]) }) { return false }
    let types = (schema["type"] as? String).map { [$0] } ?? (schema["type"] as? [String]) ?? []
    if !types.isEmpty, !types.contains(where: { agentHasType(value, $0) }) { return false }
    if let object = value as? AgentJSON {
        if let required = schema["required"] as? [String], !required.allSatisfy({ object.keys.contains($0) }) { return false }
        if let properties = schema["properties"] as? [String: AgentJSON] {
            for (key, child) in properties {
                if let field = object[key], !agentSchemaMatches(field, child) { return false }
            }
        }
    }
    if let array = value as? [Any], let items = schema["items"] as? AgentJSON {
        if !array.allSatisfy({ agentSchemaMatches($0, items) }) { return false }
    }
    return true
}

private func agentHasType(_ value: Any, _ type: String) -> Bool {
    switch type {
    case "object": return value is AgentJSON
    case "array": return value is [Any]
    case "string": return value is String
    case "null": return value is NSNull
    case "boolean": return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    case "number", "integer":
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return type == "number" || (number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue)
    default: return false
    }
}
