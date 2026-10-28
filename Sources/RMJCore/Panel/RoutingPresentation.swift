import Foundation

/// What the Routing tab says (docs/DESIGN.md, Routing): the tenant deny, the rules in order with their chains, and
/// the GitHub label mapping. The explain answer is the router's own log, so it can never disagree with a real route.
public struct RoutingPresentation: Sendable, Equatable {
    public struct ChainItem: Sendable, Equatable {
        public let name: String
        public let isLocal: Bool
    }

    public struct RuleLine: Sendable, Equatable {
        public let name: String
        public let match: String
        public let chain: [ChainItem]
        /// The image or profile the job runs in.
        public let environment: String?
        public let advisory: String?
    }

    public struct LabelLine: Sendable, Equatable {
        public let repo: String
        public let workflow: String
        public let labels: [String]
        public let served: [String]
        public var mismatch: Bool { served.isEmpty }
    }

    /// Set when the rules file cannot be used: the list is replaced by the message and the path.
    public struct Problem: Sendable, Equatable {
        public let message: String
        public let path: String
    }

    public let denyText: String
    public let rules: [RuleLine]
    public let labels: [LabelLine]
    public let problem: Problem?
    /// The repo and command the explain field starts from: the newest rx job's.
    public let explainRepo: String?
    public let explainCommand: String?
    public let explainSource: String?

    public init(state: RulesState, jobs: [JobRecord]) {
        let last = jobs.filter { $0.github == nil && $0.location != "github" }.max { $0.queuedAt < $1.queuedAt }
        explainRepo = last?.repo
        explainCommand = last?.command
        explainSource = last.map { "from job \($0.id)" }
        switch state {
        case .invalid(let path, let message):
            problem = Problem(message: message, path: path)
            denyText = Self.denyText(nil)
            rules = []
            labels = []
        case .valid(let rules, _):
            problem = nil
            denyText = Self.denyText(rules)
            self.rules = rules.rules.map(Self.line)
            labels = Self.labels(jobs: jobs, rules: rules)
        }
    }

    static func denyText(_ rules: Rules?) -> String {
        guard let rules else { return "A repo of one tenant never runs on another tenant's destination." }
        let pairs = Dictionary(grouping: rules.destinations.filter { $0.value.enabled }, by: { $0.value.tenant })
            .sorted { $0.key < $1.key }
            .map { "\($0.key) -> \($0.value.map(\.key).sorted().joined(separator: ", "))" }
        return "A repo of one tenant never runs on another tenant's destination: " + pairs.joined(separator: "; ") + "."
    }

    static func line(_ rule: Rule) -> RuleLine {
        var parts: [String] = []
        let match = rule.match
        if let tenant = match.tenant { parts.append("tenant \(tenant.joined(separator: ", "))") }
        if let owner = match.owner { parts.append("owner \(owner.joined(separator: ", "))") }
        if let repo = match.repo { parts.append("repo \(repo.joined(separator: ", "))") }
        if let command = match.command { parts.append("command \(command.joined(separator: ", "))") }
        if let path = match.path { parts.append("path \(path.joined(separator: ", "))") }
        if let has = match.has { parts.append("has \(has)") }
        return RuleLine(name: rule.name, match: parts.isEmpty ? "every command" : parts.joined(separator: ", "),
                        chain: rule.to.map { ChainItem(name: $0, isLocal: $0 == "local") }, environment: rule.image ?? rule.profile,
                        advisory: rule.advisory)
    }

    /// Each workflow job the ledger has seen, with the labels it asked for and the destinations that register runners for its repo.
    static func labels(jobs: [JobRecord], rules: Rules) -> [LabelLine] {
        var seen = Set<String>()
        var lines: [LabelLine] = []
        for job in jobs {
            guard let info = GitHubJobInfo.decode(job.github), seen.insert("\(info.repo)|\(job.command)").inserted else { continue }
            let selfHosted = info.labels.contains { $0.lowercased() == "self-hosted" }
            let served = selfHosted ? GitHubRouting.destinations(forRepo: info.repo, rules: rules) : ["github-hosted"]
            lines.append(LabelLine(repo: info.repo, workflow: job.command, labels: info.labels, served: served))
        }
        return lines.sorted { ($0.repo, $0.workflow) < ($1.repo, $1.workflow) }
    }
}

/// The router run for a typed or prefilled command, with the probes the panel already holds.
public enum RoutingExplain {
    public static func explain(repo: String, command: String, state: RulesState, tailnet: TailnetState,
                               probes: ProbeProvider = LiveProbeProvider()) async -> RouteDecision {
        let words = command.split(separator: " ").map(String.init)
        let router = Router(rules: state, tailnet: tailnet, probes: probes, fileExists: { FileManager.default.fileExists(atPath: $0) })
        let identity = RepoIdentity(slug: repo.lowercased(), worktree: "(hypothetical)")
        return await router.route(RouteRequest(command: words, identity: identity)).sanitized()
    }
}
