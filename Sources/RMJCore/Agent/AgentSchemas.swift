import Foundation

/// The JSON Schema subset the tool descriptions advertise (docs/AGENT-API.md, Schemas).
enum ToolSchema {
    typealias Node = [String: Any]

    static var string: Node { ["type": "string"] }
    static var integer: Node { ["type": "integer"] }
    static var number: Node { ["type": "number"] }
    static var boolean: Node { ["type": "boolean"] }

    static func nullable(_ node: Node) -> Node { ["anyOf": [["type": "null"], node]] }
    static func array(_ items: Node) -> Node { ["type": "array", "items": items] }
    static func choice(_ values: [String]) -> Node { ["type": "string", "enum": values] }

    /// An object whose listed properties are all present, unless `optional` names some.
    static func object(_ properties: [String: Node], optional: Set<String> = []) -> Node {
        ["type": "object", "properties": properties, "required": properties.keys.filter { !optional.contains($0) }.sorted()]
    }

    /// The envelope every result carries, around the tool's own properties.
    static func result(_ properties: [String: Node]) -> Node {
        var all = properties
        all["source"] = string
        all["generated_at"] = string
        all["data_note"] = string
        all["truncated"] = boolean
        return object(all, optional: ["truncated"])
    }

    static var timestamp: Node { nullable(string) }
    static var state: Node { choice(JobState.allCases.map(\.rawValue)) }
    static var lines: Node { array(string) }

    static var job: Node { object([
        "id": string, "source": choice(["rx", "github"]), "tenant": string, "repo": string,
        "worktree": nullable(string), "branch": nullable(string), "commit": nullable(string), "dirty": nullable(boolean),
        "command": ["type": "object"],
        "agent": object(["kind": string, "session": nullable(string)]),
        "location": string, "fallback_reason": nullable(string), "environment": nullable(choice(["box", "mac"])),
        "rule": nullable(string), "state": state, "exit": nullable(integer),
        "times": object(["queued_at": timestamp, "sync_started_at": timestamp, "sync_ended_at": timestamp, "started_at": timestamp,
                         "ended_at": timestamp, "box_started_at": timestamp, "box_ended_at": timestamp,
                         "mac_elapsed_ms": nullable(integer), "clock_offset_ms": nullable(integer),
                         "duration_ms": nullable(integer), "duration_source": choice(["box", "mac", "unknown"])]),
        "github": nullable(object([
            "run_id": integer, "job_id": integer, "run_attempt": integer, "status": string, "conclusion": nullable(string),
            "html_url": nullable(string), "runner_name": nullable(string), "labels": lines, "current_step": nullable(string),
            "steps_done": nullable(integer), "steps_total": nullable(integer), "parent_attempt": nullable(string),
            "observation": nullable(object([
                "online_idle": integer, "online_busy": integer, "offline_idle": integer, "offline_busy": integer,
                "offline_idle_names": lines, "observed_at": timestamp, "suspected_cause": nullable(string), "dependency_wait": boolean,
            ])),
        ])),
        "warmth": choice(["warm", "cold", "unknown"]),
        "logs": object(["box": nullable(string), "local": nullable(string), "status": choice(["available", "pending", "unavailable"]),
                        "reason": nullable(string), "truncated": boolean]),
    ]) }

    static var failure: Node {
        var node = job
        var properties = node["properties"] as? [String: Node] ?? [:]
        properties["log_tail"] = nullable(lines)
        node["properties"] = properties
        node["required"] = properties.keys.sorted()
        return node
    }

    static var runner: Node { object([
        "target": nullable(string), "name": string, "version": nullable(string), "status": choice(["online", "offline"]),
        "busy": boolean, "readiness": string, "first_seen": timestamp, "last_seen": timestamp, "stale": boolean,
    ]) }

    static var destination: Node { object([
        "name": string, "tenant": string, "roles": lines,
        "state": object(["kind": choice(["online", "relayed", "offline", "unreachable", "rejected", "rebooted", "tailnet-down"]),
                         "reason": nullable(string), "since": timestamp]),
        "capacity": object(["slots_used": integer, "slots_max": integer, "memory_used_gb": nullable(number),
                            "memory_budget_gb": nullable(number), "cpus": nullable(integer), "load1": nullable(number),
                            "free_gb": nullable(number)]),
        "containers": array(object(["name": string, "kind": choice(["rx", "runner"]), "job_id": nullable(string),
                                    "cpu_pct": nullable(number), "mem_mb": nullable(number)])),
        "runners": array(runner),
        "images": array(object(["name": string, "age_days": integer])),
        "probed_at": timestamp, "stale": boolean,
    ]) }

    static var event: Node { object(["at": timestamp, "state": state, "detail": nullable(string)]) }
}
