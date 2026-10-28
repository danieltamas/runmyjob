import Foundation

/// A rule as the editor's text fields hold it: lists are comma separated. Fields the editor does not show (volumes,
/// cold marker, memory, cpus) are carried over from the rule being edited.
public struct RuleDraft: Equatable, Sendable {
    public var name = ""
    public var owner = ""
    public var repo = ""
    public var tenant = ""
    public var path = ""
    public var command = ""
    public var has = ""
    public var to = "local"
    public var image = ""
    public var profile = ""
    public var advisory = ""

    public init() {}

    public init(_ rule: Rule) {
        func text(_ list: [String]?) -> String { (list ?? []).joined(separator: ", ") }
        name = rule.name
        owner = text(rule.match.owner)
        repo = text(rule.match.repo)
        tenant = text(rule.match.tenant)
        path = text(rule.match.path)
        command = text(rule.match.command)
        has = rule.match.has ?? ""
        to = text(rule.to)
        image = rule.image ?? ""
        profile = rule.profile ?? ""
        advisory = rule.advisory ?? ""
    }

    private static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The rule these fields describe, on top of `base`'s untouched fields. Validation happens when it is saved.
    public func rule(base: Rule?) throws -> Rule {
        var object = (base.flatMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } as? [String: Any]) ?? [:]
        var match = [String: Any]()
        for (key, value) in [("owner", owner), ("repo", repo), ("tenant", tenant), ("path", path), ("command", command)] where !Self.list(value).isEmpty {
            match[key] = Self.list(value)
        }
        if !has.isEmpty { match["has"] = has }
        object["name"] = name
        object["match"] = match
        object["to"] = Self.list(to)
        for (key, value) in [("image", image), ("profile", profile), ("advisory", advisory)] { object[key] = value.isEmpty ? nil : value }
        return try JSONDecoder().decode(Rule.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

/// Edits the rules list in the rules file: read, change, validate, write. Refuses when the file changed in between.
public enum RuleEditing {
    public enum Change: Sendable {
        case replace(Int, Rule)
        case append(Rule)
        case delete(Int)
        case move(Int, by: Int)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The fingerprint of the rules file as it is now; an editor keeps it from when it opened.
    public static func fingerprint(home: RMJHome) -> String? {
        guard case .valid(_, let fingerprint) = RulesStore(home: home).load() else { return nil }
        return fingerprint
    }

    /// With `expected`, refuses when the file is not the one the editor opened (another edit moved or changed rules).
    public static func apply(_ change: Change, home: RMJHome, expected: String? = nil) throws {
        let store = RulesStore(home: home)
        guard case .valid(var rules, let fingerprint) = store.load() else { throw Failure(description: "the rules file is invalid; fix it first") }
        if let expected, expected != fingerprint { throw Failure(description: "the rules file changed on disk; reopen the rule and try again") }
        switch change {
        case .replace(let index, let rule):
            guard rules.rules.indices.contains(index) else { throw Failure(description: "that rule no longer exists") }
            rules.rules[index] = rule
        case .append(let rule):
            rules.rules.append(rule)
        case .delete(let index):
            guard rules.rules.indices.contains(index) else { throw Failure(description: "that rule no longer exists") }
            rules.rules.remove(at: index)
        case .move(let index, let offset):
            let target = index + offset
            guard rules.rules.indices.contains(index), rules.rules.indices.contains(target) else { return }
            rules.rules.swapAt(index, target)
        }
        do { try store.save(rules, expected: fingerprint) } catch let failure as RulesStore.Failure {
            switch failure {
            case .invalid(let message): throw Failure(description: message)
            case .changedExternally: throw Failure(description: "the rules file changed on disk; reopen the rule and try again")
            }
        }
    }
}

/// "Build X on the remote machine" without writing match patterns: the toolchains a rule can target by its command.
public enum RulePreset: String, CaseIterable, Sendable {
    case anything, node, rust, swift, python, go

    public var title: String {
        switch self {
        case .anything: "Anything"
        case .node: "Node"
        case .rust: "Rust"
        case .swift: "Swift"
        case .python: "Python"
        case .go: "Go"
        }
    }

    /// The commands that start this toolchain; empty matches every command.
    public var commands: [String] {
        switch self {
        case .anything: []
        case .node: ["npm", "npx", "pnpm", "yarn", "bun", "node"]
        case .rust: ["cargo", "rustc"]
        case .swift: ["swift", "xcodebuild"]
        case .python: ["python", "python3", "pytest", "uv", "pip"]
        case .go: ["go"]
        }
    }

    /// The preset a draft's command list is exactly, so an opened rule shows its chip lit.
    public static func matching(command: String) -> RulePreset? {
        let words = Set(command.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return allCases.first { Set($0.commands) == words }
    }
}

extension RuleDraft {
    /// Sets the command list from a preset.
    public mutating func apply(_ preset: RulePreset) {
        command = preset.commands.joined(separator: ", ")
    }

    /// A name for a rule left unnamed: `Rust builds on ai-eu-1`.
    public var suggestedName: String {
        let what = RulePreset.matching(command: command).map { $0 == .anything ? "Builds" : "\($0.title) builds" } ?? "Matching builds"
        let place = Self.names(to).first { $0 != "local" }.map { "on \($0)" } ?? "locally"
        return "\(what) \(place)"
    }

    private static func names(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
