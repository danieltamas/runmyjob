import Foundation

/// What `tools/list` says about the eight tools.
enum MCPTools {
    static let names: Set<String> = ["destinations", "tailnet", "jobs", "job", "failures", "log", "route", "runners"]

    private static func input(_ properties: [String: ToolSchema.Node] = [:], required: [String] = []) -> ToolSchema.Node {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static var since: ToolSchema.Node { ["type": "string", "pattern": "^[0-9]+[hd]$", "description": "24h, 7d: at most 30d"] }
    private static var limit: ToolSchema.Node { ["type": "integer", "minimum": 1, "maximum": 200] }
    private static var jobID: ToolSchema.Node { ["type": "string", "description": "A job id (ULID)"] }

    static var descriptions: [[String: Any]] { [
        ["name": "destinations",
         "description": "Every configured destination: tenant, roles, whether the tailnet reaches it, the rx jobs it runs now. Live box readings are not taken over MCP.",
         "inputSchema": input(),
         "outputSchema": ToolSchema.result(["destinations": ToolSchema.array(ToolSchema.destination)])],
        ["name": "tailnet",
         "description": "The tailnet as this Mac sees it: backend state and every peer.",
         "inputSchema": input(),
         "outputSchema": ToolSchema.result([
            "state": ToolSchema.string, "backend_state": ToolSchema.string, "self_online": ToolSchema.boolean,
            "peers": ToolSchema.array(ToolSchema.object(["id": ToolSchema.string, "name": ToolSchema.string, "online": ToolSchema.boolean,
                                                 "relayed": ToolSchema.boolean, "key_expiry": ToolSchema.timestamp])),
         ])],
        ["name": "jobs",
         "description": "Jobs from the ledger, newest first, with the exact timings, filtered and paged by cursor.",
         "inputSchema": input(["state": ["type": "string", "enum": JobState.allCases.map(\.rawValue)], "repo": ["type": "string"],
                               "destination": ["type": "string"], "source": ["type": "string", "enum": ["rx", "github"]],
                               "since": since, "limit": limit, "cursor": ["type": "string"]]),
         "outputSchema": ToolSchema.result(["jobs": ToolSchema.array(ToolSchema.job), "next_cursor": ToolSchema.nullable(ToolSchema.string)])],
        ["name": "job",
         "description": "One job with its state events.",
         "inputSchema": input(["id": jobID], required: ["id"]),
         "outputSchema": ToolSchema.result(["job": ToolSchema.job, "events": ToolSchema.array(ToolSchema.event)])],
        ["name": "failures",
         "description": "Failed and lost jobs of the last 24 hours (or `since`), each with the last 40 lines of its archived log.",
         "inputSchema": input(["since": since, "repo": ["type": "string"], "limit": limit]),
         "outputSchema": ToolSchema.result(["jobs": ToolSchema.array(ToolSchema.failure)])],
        ["name": "log",
         "description": "The end of a job's archived log, from this Mac's archive. A log that is pending or unavailable returns no lines and is never fetched from the box.",
         "inputSchema": input(["id": jobID, "tail": ["type": "integer", "minimum": 1, "maximum": 5000]], required: ["id"]),
         "outputSchema": ToolSchema.result(["id": ToolSchema.string, "status": ToolSchema.choice(["available", "pending", "unavailable"]),
                                        "reason": ToolSchema.nullable(ToolSchema.string), "lines": ToolSchema.lines])],
        ["name": "route",
         "description": "Explains where RMJ would run a command and why. Runs nothing and changes nothing; live box probes are not taken, so a destination that needs one shows as skipped.",
         "inputSchema": input(["repo": ["type": "string", "description": "owner/name"], "command": ["type": "array", "items": ["type": "string"]],
                               "path": ["type": "string", "description": "An existing git checkout"]], required: ["repo", "command"]),
         "outputSchema": ToolSchema.result([
            "inputs": ["type": "object"],
            "chain": ToolSchema.array(ToolSchema.object(["destination": ToolSchema.string, "verdict": ToolSchema.choice(["chosen", "skipped"]),
                                                 "reason": ToolSchema.nullable(ToolSchema.string)])),
            "rule": ToolSchema.nullable(ToolSchema.string), "result": ToolSchema.string, "fallback_reason": ToolSchema.nullable(ToolSchema.string),
         ])],
        ["name": "runners",
         "description": "The self-hosted GitHub runner registrations RMJ has recorded, optionally for one destination.",
         "inputSchema": input(["target": ["type": "string"]]),
         "outputSchema": ToolSchema.result(["runners": ToolSchema.array(ToolSchema.runner)])],
    ]}
}
