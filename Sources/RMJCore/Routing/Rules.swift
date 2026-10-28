import Foundation

/// `~/.rmj/rules.json`: strict JSON, specified in docs/ROUTING.md.
public struct Rules: Codable, Sendable, Equatable {
    public var destinations: [String: DestinationConfig]
    public var tenants: [String: TenantConfig]
    public var rules: [Rule]

    public init(destinations: [String: DestinationConfig] = [:], tenants: [String: TenantConfig] = [:], rules: [Rule] = []) {
        self.destinations = destinations
        self.tenants = tenants
        self.rules = rules
    }
}

public struct DestinationConfig: Codable, Sendable, Equatable {
    public struct Defaults: Codable, Sendable, Equatable {
        public var cpus: Int?
        public var memory: String?
    }

    public var enabled: Bool
    public var peerID: String
    public var sshAlias: String
    public var tenant: String
    public var roles: [String]
    public var home: String
    public var maxJobs: Int
    public var memoryBudget: String
    public var rxDefaults: Defaults?
    public var runnerStack: String?
    public var runnerTargets: [String]?

    enum CodingKeys: String, CodingKey {
        case enabled, tenant, roles, home
        case peerID = "peer_id", sshAlias = "ssh_alias", maxJobs = "max_jobs", memoryBudget = "memory_budget"
        case rxDefaults = "rx_defaults", runnerStack = "runner_stack", runnerTargets = "runner_targets"
    }
}

public struct TenantConfig: Codable, Sendable, Equatable {
    public var owners: [String]?
    public var repos: [String]?
    /// Not a company: its repos may run on any destination and its destinations take any repo.
    public var shared: Bool?
}

public struct Rule: Codable, Sendable, Equatable {
    public struct Match: Codable, Sendable, Equatable {
        public var owner: [String]?
        public var repo: [String]?
        public var tenant: [String]?
        public var path: [String]?
        public var command: [String]?
        public var has: String?
    }

    public var name: String
    public var match: Match
    public var to: [String]
    public var advisory: String?
    public var image: String?
    public var profile: String?
    public var volumes: [String]?
    public var coldMarker: [String: String]?
    public var memory: String?
    public var cpus: Int?

    enum CodingKeys: String, CodingKey {
        case name, match, to, advisory, image, profile, volumes, memory, cpus
        case coldMarker = "cold_marker"
    }
}

extension Rules {
    /// What a fresh install starts with: nothing is routed anywhere until a destination is added.
    public static let starterJSON = """
    { "destinations": {}, "tenants": {}, "rules": [] }
    """

    public static var starter: Rules {
        // The literal above is covered by a test; a failure here is a programming error.
        try! JSONDecoder().decode(Rules.self, from: Data(starterJSON.utf8))
    }
}
