import Foundation

/// What Settings shows of the tenants: who they are, which boxes they own and in which order jobs try them.
public enum TenantOverview {
    public struct Summary: Sendable, Equatable {
        public let name: String
        public let shared: Bool
        public let owners: [String]
        public let repos: [String]
        /// The tenant's destinations in priority order: `order` first, the rest by name.
        public let destinations: [String]
        /// Two or more destinations.
        public let isGroup: Bool
        public let style: TenantStyle.Resolved
    }

    public static func summaries(_ rules: Rules) -> [Summary] {
        rules.tenants.sorted { $0.key < $1.key }.map { name, tenant in
            let own = rules.destinations.filter { $0.value.tenant == name }.map(\.key).sorted()
            let listed = (tenant.order ?? []).filter(own.contains)
            let boxes = listed + own.filter { !listed.contains($0) }
            return Summary(name: name, shared: tenant.shared == true, owners: tenant.owners ?? [], repos: tenant.repos ?? [],
                           destinations: boxes, isGroup: boxes.count > 1, style: (tenant.style ?? TenantStyle()).resolved(for: name))
        }
    }
}

/// Edits one tenant in the rules file: read, change, validate, write. Refuses when the file changed in between.
public enum TenantEditing {
    public enum Change: Sendable {
        case style(String, TenantStyle?)
        case order(String, [String])
        /// Adds `owner/name` to the tenant's repos so the repo can run on its boxes from the next run.
        case assign(repo: String, tenant: String)
        /// Takes `owner/name` out of the tenant's repos; a runner target that still serves it blocks the change.
        case unassign(repo: String, tenant: String)
        /// Deletes the tenant. Its repos become unclassified and run on this Mac; boxes and rules that still name it block the removal.
        case remove(String)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The tenants a repo can be given to: those with at least one enabled destination, sorted.
    public static func assignable(_ rules: Rules) -> [String] {
        let withBoxes = Set(rules.destinations.values.filter(\.enabled).map(\.tenant))
        return rules.tenants.keys.filter(withBoxes.contains).sorted()
    }

    /// Programs that exist only on macOS.
    static let macOnly: Set<String> = ["swift", "xcodebuild", "xcrun", "codesign", "osascript", "open", "hdiutil", "pkgbuild", "productbuild"]

    /// The tenants whose boxes a rule would send this command to once the repo belongs to them. A command no rule routes
    /// (a Swift build when only Node and Rust rules exist) gets none, so the job offers no "Run remote".
    public static func assignable(_ rules: Rules, command: String, repoCommands: [String] = []) -> [String] {
        let words = CommandWords(argv: command.split(separator: " ").map(String.init))
        // The boxes are Linux: a rule that matches by tenant alone would still send these to a box, where they cannot run.
        // A repo that has run one such program is a Mac repo, and so is the script it wraps its builds in.
        let programs = (repoCommands + [command]).map { CommandWords(argv: $0.split(separator: " ").map(String.init)).program }
        guard !programs.contains(where: macOnly.contains) else { return [] }
        return assignable(rules).filter { tenant in
            let boxes = Set(rules.destinations.filter { $0.value.enabled && $0.value.tenant == tenant }.keys)
            return rules.rules.contains { rule in
                if let tenants = rule.match.tenant, !tenants.contains(tenant) { return false }
                if let commands = rule.match.command, !commands.contains(where: words.matches) { return false }
                return rule.to.contains(where: boxes.contains)
            }
        }
    }

    public static func apply(_ change: Change, home: RMJHome, expected: String? = nil) throws {
        let store = RulesStore(home: home)
        guard case .valid(var rules, let fingerprint) = store.load() else { throw Failure(description: "the rules file is invalid; fix it first") }
        if let expected, expected != fingerprint { throw Failure(description: "the rules file changed on disk; reopen the pane and try again") }
        switch change {
        case .style(let tenant, let style):
            guard rules.tenants[tenant] != nil else { throw Failure(description: "no tenant \(tenant)") }
            rules.tenants[tenant]?.style = style
        case .order(let tenant, let boxes):
            guard rules.tenants[tenant] != nil else { throw Failure(description: "no tenant \(tenant)") }
            rules.tenants[tenant]?.order = boxes.isEmpty ? nil : boxes
        case .assign(let repo, let tenant):
            try assign(repo.lowercased(), to: tenant, in: &rules)
        case .unassign(let repo, let tenant):
            guard rules.tenants[tenant] != nil else { throw Failure(description: "no tenant \(tenant)") }
            let kept = (rules.tenants[tenant]?.repos ?? []).filter { $0.lowercased() != repo.lowercased() }
            rules.tenants[tenant]?.repos = kept.isEmpty ? nil : kept
        case .remove(let tenant):
            guard rules.tenants[tenant] != nil else { throw Failure(description: "no tenant \(tenant)") }
            let boxes = rules.destinations.filter { $0.value.tenant == tenant }.keys.sorted()
            if !boxes.isEmpty { throw Failure(description: "\(tenant) still has \(boxes.count == 1 ? "a box" : "boxes"): \(boxes.joined(separator: ", ")). Move or remove \(boxes.count == 1 ? "it" : "them") first") }
            if let rule = rules.rules.first(where: { $0.match.tenant?.contains(tenant) == true }) {
                throw Failure(description: "the rule \"\(rule.name)\" matches \(tenant). Edit the rule first")
            }
            rules.tenants[tenant] = nil
        }
        do { try store.save(rules, expected: fingerprint) } catch let failure as RulesStore.Failure {
            switch failure {
            case .invalid(let message): throw Failure(description: message)
            case .changedExternally: throw Failure(description: "the rules file changed on disk; reopen the pane and try again")
            }
        }
    }

    private static func assign(_ repo: String, to tenant: String, in rules: inout Rules) throws {
        guard rules.tenants[tenant] != nil else { throw Failure(description: "no tenant \(tenant)") }
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        // A literal name only: a pattern such as `globex/*` would claim every repo of an owner another tenant holds.
        let literal = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(literal.contains) }) else {
            throw Failure(description: "\"\(repo)\" is not owner/name")
        }
        let owner = String(parts[0])
        for (name, other) in rules.tenants.sorted(by: { $0.key < $1.key }) where name != tenant && (other.owners ?? []).contains(where: { $0.lowercased() == owner }) {
            if Tenancy.denies(repoTenant: name, destinationTenant: tenant, tenants: rules.tenants) {
                throw Failure(description: "owner \(owner) belongs to tenant \(name), whose repos never run on \(tenant)'s boxes")
            }
        }
        if let other = rules.tenants.sorted(by: { $0.key < $1.key }).first(where: { $0.key != tenant && ($0.value.repos ?? []).contains { Glob.matches($0.lowercased(), repo) } }) {
            throw Failure(description: "\(repo) already belongs to tenant \(other.key)")
        }
        if (rules.tenants[tenant]?.repos ?? []).contains(where: { Glob.matches($0.lowercased(), repo) }) { return }
        var claimed = rules.tenants[tenant]?.repos ?? []
        claimed.append(repo)
        rules.tenants[tenant]?.repos = claimed
    }
}
