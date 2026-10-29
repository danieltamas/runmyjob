import Foundation

public struct RulesError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Parse errors, unknown keys, and references that lead nowhere all mean the file is invalid.
public enum RulesValidation {
    private static let schema: [String: Set<String>] = [
        "root": ["destinations", "tenants", "rules"],
        "destination": ["enabled", "peer_id", "ssh_alias", "tenant", "roles", "home", "max_jobs", "memory_budget",
                        "rx_defaults", "runner_stack", "runner_targets", "requires"],
        "rx_defaults": ["cpus", "memory"],
        "tenant": ["owners", "repos", "shared"],
        "rule": ["name", "match", "to", "advisory", "image", "profile", "volumes", "cold_marker", "memory", "cpus"],
        "match": ["owner", "repo", "tenant", "path", "command", "has"],
    ]

    public static func parse(_ data: Data, profileExists: (String) -> Bool = { _ in true }) throws -> Rules {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw RulesError(message: "not valid JSON: \(error.localizedDescription)") }
        try rejectDuplicateKeys(in: data)
        try checkKeys(object, "root", path: "")
        let rules: Rules
        do { rules = try JSONDecoder().decode(Rules.self, from: data) } catch {
            throw RulesError(message: "cannot read: \(describe(error))")
        }
        try validate(rules, profileExists: profileExists)
        return rules
    }

    static func validate(_ rules: Rules, profileExists: (String) -> Bool) throws {
        var names = Set<String>()
        for (name, destination) in rules.destinations.sorted(by: { $0.key < $1.key }) {
            var seen = Set<String>()
            for program in destination.requires ?? [] {
                guard DestinationConfig.isProgramName(program) else { throw RulesError(message: "destination \(name): requires \"\(program)\" is not a program name") }
                guard seen.insert(program).inserted else { throw RulesError(message: "destination \(name): requires lists \"\(program)\" twice") }
            }
            guard destination.maxJobs > 0 else { throw RulesError(message: "destination \(name): max_jobs must be positive") }
            guard MemorySize.parse(destination.memoryBudget) != nil else { throw RulesError(message: "destination \(name): memory_budget \"\(destination.memoryBudget)\" is not a size") }
            if let memory = destination.rxDefaults?.memory, (MemorySize.parse(memory)?.bytes ?? 0) <= 0 {
                throw RulesError(message: "destination \(name): rx_defaults.memory \"\(memory)\" is not a size")
            }
            guard destination.enabled else { continue }
            guard !destination.peerID.isEmpty else { throw RulesError(message: "destination \(name): peer_id is empty") }
            guard !destination.sshAlias.isEmpty else { throw RulesError(message: "destination \(name): ssh_alias is empty") }
            if destination.roles.contains("rx"), destination.rxDefaults?.memory == nil {
                throw RulesError(message: "destination \(name): rx_defaults.memory is required for the rx role")
            }
            // One node under two names could carry one company's jobs onto the other company's box.
            if let other = rules.destinations.first(where: { $0.key != name && $0.value.enabled && $0.value.peerID == destination.peerID }) {
                throw RulesError(message: "destinations \(name) and \(other.key) share the peer_id")
            }
        }
        let tenantNames = Set(rules.tenants.keys)
        for rule in rules.rules {
            guard names.insert(rule.name).inserted else { throw RulesError(message: "duplicate rule name \"\(rule.name)\"") }
            guard !rule.to.isEmpty else { throw RulesError(message: "rule \"\(rule.name)\": to is empty") }
            for target in rule.to where target != "local" && rules.destinations[target] == nil {
                throw RulesError(message: "rule \"\(rule.name)\" names unknown destination \"\(target)\"")
            }
            for tenant in rule.match.tenant ?? [] where !tenantNames.contains(tenant) {
                throw RulesError(message: "rule \"\(rule.name)\" matches unknown tenant \"\(tenant)\"")
            }
            for entry in rule.match.command ?? [] where entry.split(separator: " ").count > 2 || entry.isEmpty {
                throw RulesError(message: "rule \"\(rule.name)\": command \"\(entry)\" may name a program and one subcommand only")
            }
            if let profile = rule.profile, !profileExists(profile) {
                throw RulesError(message: "rule \"\(rule.name)\" names unknown profile \"\(profile)\"")
            }
            if let memory = rule.memory {
                guard let size = MemorySize.parse(memory), size.bytes > 0 else { throw RulesError(message: "rule \"\(rule.name)\": memory \"\(memory)\" is not a size") }
                for target in rule.to {
                    if let budget = rules.destinations[target].flatMap({ MemorySize.parse($0.memoryBudget) }), size > budget {
                        throw RulesError(message: "rule \"\(rule.name)\": memory \(memory) is above the budget of \(target)")
                    }
                }
            }
        }
        for name in tenantNames where name != name.lowercased() || name.isEmpty
            || !name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) {
            throw RulesError(message: "tenant \"\(name)\" must be lower case letters, digits, dot, dash or underscore")
        }
        for (name, destination) in rules.destinations where !tenantNames.contains(destination.tenant) {
            throw RulesError(message: "destination \(name) has unknown tenant \"\(destination.tenant)\"")
        }
        // Two companies never mix: a destination's runners may only serve its own tenant's owners and repos.
        for (name, destination) in rules.destinations {
            let tenant = rules.tenants[destination.tenant]
            for target in destination.runnerTargets ?? [] where !Self.tenant(tenant, owns: target, others: rules.tenants.filter { $0.key != destination.tenant }.map(\.value)) {
                throw RulesError(message: "destination \(name) serves runner target \"\(target)\", which tenant \"\(destination.tenant)\" does not own")
            }
        }
    }

    /// `org:Name` or `owner/name` against the tenant's owners (any case) and repos (a trailing `*` matches a prefix).
    static func tenant(_ tenant: TenantConfig?, owns target: String, others: [TenantConfig] = []) -> Bool {
        let owner = (target.hasPrefix("org:") ? String(target.dropFirst(4)) : String(target.split(separator: "/").first ?? "")).lowercased()
        if (tenant?.owners ?? []).contains(where: { $0.lowercased() == owner }) {
            // An owner is the tenant's unless another tenant claims this very repo.
            return target.hasPrefix("org:") || !others.contains { Self.matches($0, repo: target) }
        }
        guard !target.hasPrefix("org:") else { return false }
        return tenant.map { matches($0, repo: target) } ?? false
    }

    static func matches(_ tenant: TenantConfig, repo target: String) -> Bool {
        (tenant.repos ?? []).contains { pattern in
            pattern.hasSuffix("*") ? target.lowercased().hasPrefix(pattern.dropLast().lowercased()) : pattern.lowercased() == target.lowercased()
        }
    }

    private static func checkKeys(_ node: Any, _ kind: String, path: String) throws {
        guard let object = node as? [String: Any] else {
            throw RulesError(message: "\(path.isEmpty ? "the file" : path) must be an object")
        }
        let allowed = schema[kind] ?? []
        for key in object.keys.sorted() where !allowed.contains(key) {
            throw RulesError(message: "unknown key \"\(path.isEmpty ? key : "\(path).\(key)")\"")
        }
        func each(_ key: String, _ child: String) throws {
            guard let value = object[key] as? [String: Any] else { return }
            for (name, node) in value.sorted(by: { $0.key < $1.key }) { try checkKeys(node, child, path: "\(path.isEmpty ? "" : path + ".")\(key).\(name)") }
        }
        switch kind {
        case "root":
            try each("destinations", "destination")
            try each("tenants", "tenant")
            for (index, rule) in ((object["rules"] as? [Any]) ?? []).enumerated() { try checkKeys(rule, "rule", path: "rules[\(index)]") }
        case "destination":
            if let defaults = object["rx_defaults"] { try checkKeys(defaults, "rx_defaults", path: "\(path).rx_defaults") }
        case "rule":
            if let match = object["match"] { try checkKeys(match, "match", path: "\(path).match") }
        default: break
        }
    }

    /// JSON objects with a repeated key decode to the last one; for routing that is an ambiguity, so it is refused.
    private static func rejectDuplicateKeys(in data: Data) throws {
        let bytes = Array(data)
        var stack = [Set<String>?]()   // nil: an array
        var index = 0, expectKey = [Bool]()
        func readString() -> String {
            var scalars = [UInt8]()
            index += 1
            while index < bytes.count, bytes[index] != 0x22 {
                if bytes[index] == 0x5C { scalars.append(bytes[index]); index += 1 }
                if index < bytes.count { scalars.append(bytes[index]) }
                index += 1
            }
            index += 1
            // Decoded as JSON, so "to" and "\u0074o" are the same key.
            let quoted = Data(([0x22] + scalars + [0x22]))
            return (try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed)) as? String ?? String(decoding: scalars, as: UTF8.self)
        }
        while index < bytes.count {
            switch bytes[index] {
            case 0x7B: stack.append([]); expectKey.append(true); index += 1
            case 0x5B: stack.append(nil); expectKey.append(false); index += 1
            case 0x7D, 0x5D: _ = stack.popLast(); _ = expectKey.popLast(); index += 1
            case 0x2C: if let top = stack.last, top != nil { expectKey[expectKey.count - 1] = true }; index += 1
            case 0x22:
                let text = readString()
                if let last = expectKey.last, last, var keys = stack.last ?? nil {
                    guard keys.insert(text).inserted else { throw RulesError(message: "duplicate key \"\(text)\"") }
                    stack[stack.count - 1] = keys
                    expectKey[expectKey.count - 1] = false
                }
            default: index += 1
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, let context): return "missing key \"\(key.stringValue)\" at \(location(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(location(context))"
        @unknown default: return error.localizedDescription
        }
    }

    private static func location(_ context: DecodingError.Context) -> String {
        context.codingPath.map(\.stringValue).joined(separator: ".")
    }
}

/// "12g", "512m", "36G", "1.5GiB": binary units.
public struct MemorySize: Comparable, Sendable, Equatable {
    public let bytes: Int64

    public static func < (lhs: MemorySize, rhs: MemorySize) -> Bool { lhs.bytes < rhs.bytes }

    public static func parse(_ text: String) -> MemorySize? {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("tib", 1_099_511_627_776.0), ("gib", 1_073_741_824.0), ("mib", 1_048_576.0), ("kib", 1_024.0),
                                          ("tb", 1_099_511_627_776.0), ("gb", 1_073_741_824.0), ("mb", 1_048_576.0), ("kb", 1_024.0),
                                          ("t", 1_099_511_627_776.0), ("g", 1_073_741_824.0), ("m", 1_048_576.0), ("k", 1_024.0), ("b", 1)]
        for (suffix, factor) in units where lowered.hasSuffix(suffix) {
            guard let number = Double(lowered.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)), number.isFinite, number >= 0,
                  number * factor < 1e15 else { return nil }
            return MemorySize(bytes: Int64(number * factor))
        }
        return Double(lowered).flatMap { $0.isFinite && $0 >= 0 && $0 < 1e15 ? MemorySize(bytes: Int64($0)) : nil }
    }
}
