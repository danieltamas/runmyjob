import Foundation

public struct LogSinkError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public init(message: String) { self.message = message }
}

/// One log ingestor the owner configured. The secret (password, token, API key) is never here: it lives in the
/// Keychain under `keychainAccount`.
public struct LogSinkConfig: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case loki, datadog, elasticsearch }
    public enum Auth: String, Codable, Sendable { case none, basic, bearer, apikey }

    public static let datadogSites = ["datadoghq.com", "datadoghq.eu", "us3.datadoghq.com", "us5.datadoghq.com", "ap1.datadoghq.com"]

    public var id: String
    public var kind: Kind
    public var name: String
    /// Loki and Elasticsearch: the base URL.
    public var url: String?
    /// Datadog: which regional intake (default `datadoghq.com`).
    public var site: String?
    public var enabled: Bool
    public var tenants: [String]
    /// Every tenant, and jobs without one. Never implied: a sink with neither this nor a tenant is invalid.
    public var all: Bool
    public var auth: Auth
    public var user: String?
    /// Loki's `X-Scope-OrgID`.
    public var orgID: String?
    /// Elasticsearch index (default `rmj-logs`).
    public var index: String?

    public init(id: String, kind: Kind, name: String, url: String? = nil, site: String? = nil, enabled: Bool = true,
                tenants: [String] = [], all: Bool = false, auth: Auth = .none, user: String? = nil, orgID: String? = nil, index: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.url = url; self.site = site; self.enabled = enabled
        self.tenants = tenants; self.all = all; self.auth = auth; self.user = user; self.orgID = orgID; self.index = index
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, url, site, enabled, tenants, all, auth, user, index
        case orgID = "org_id"
    }

    /// Hand-edited files may leave out the switches; the scope is still checked by `validate()`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), kind: try c.decode(Kind.self, forKey: .kind),
                  name: try c.decode(String.self, forKey: .name), url: try c.decodeIfPresent(String.self, forKey: .url),
                  site: try c.decodeIfPresent(String.self, forKey: .site), enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                  tenants: try c.decodeIfPresent([String].self, forKey: .tenants) ?? [], all: try c.decodeIfPresent(Bool.self, forKey: .all) ?? false,
                  auth: try c.decodeIfPresent(Auth.self, forKey: .auth) ?? .none, user: try c.decodeIfPresent(String.self, forKey: .user),
                  orgID: try c.decodeIfPresent(String.self, forKey: .orgID), index: try c.decodeIfPresent(String.self, forKey: .index))
    }

    public var keychainAccount: String { "rmj.sink.\(id)" }

    public func accepts(tenant: String?) -> Bool {
        if all { return true }
        guard let tenant else { return false }
        return tenants.contains(tenant)
    }

    public func validate() throws {
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil else {
            throw LogSinkError(message: "sink id \"\(id)\" must be 1-32 characters: lowercase letters, digits, hyphens")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw LogSinkError(message: "sink \(id): name is empty") }
        guard all || !tenants.isEmpty else { throw LogSinkError(message: "sink \(id) names no tenant (pick tenants, or all)") }
        switch kind {
        case .loki, .elasticsearch:
            try Self.validateURL(url, sink: id)
            if kind == .loki, auth == .apikey { throw LogSinkError(message: "sink \(id): Loki takes no API key (use basic or bearer)") }
            if auth == .basic, user?.isEmpty ?? true { throw LogSinkError(message: "sink \(id): basic auth needs a user name") }
        case .datadog:
            if url != nil { throw LogSinkError(message: "sink \(id): Datadog is chosen by site, not URL") }
            if let site, !Self.datadogSites.contains(site) { throw LogSinkError(message: "sink \(id): unknown Datadog site \"\(site)\"") }
            if auth != .apikey { throw LogSinkError(message: "sink \(id): Datadog needs an API key") }
        }
    }

    /// HTTPS, no credentials in the URL. Plain http only to this Mac or the tailnet, where the wire is already private.
    private static func validateURL(_ text: String?, sink: String) throws {
        guard let text, let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased(), !host.isEmpty else {
            throw LogSinkError(message: "sink \(sink): the URL is missing or not valid")
        }
        guard parts.user == nil, parts.password == nil else { throw LogSinkError(message: "sink \(sink): no credentials in the URL (they go in the Keychain)") }
        switch scheme {
        case "https": return
        case "http" where isPrivate(host): return
        default: throw LogSinkError(message: "sink \(sink): use https (http only to this Mac or a tailnet address)")
        }
    }

    private static func isPrivate(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".ts.net") { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) < 256 }) else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1] ?? 0)
    }
}

/// The `log_sinks` list in `config.json`.
public enum LogSinkStore {
    public struct Loaded: Equatable {
        public let sinks: [LogSinkConfig]
        public let problems: [String]
    }

    /// An entry that does not decode or validate is left out and named, so one bad hand edit never hides the others.
    public static func load(home: RMJHome) -> Loaded {
        guard let list = ConfigFile.read(home)?["log_sinks"] as? [Any] else { return Loaded(sinks: [], problems: []) }
        var sinks: [LogSinkConfig] = []
        var problems: [String] = []
        for (index, item) in list.enumerated() {
            let label = (item as? [String: Any])?["id"] as? String ?? "#\(index + 1)"
            do {
                guard item is [String: Any] else { throw LogSinkError(message: "not a sink entry") }
                let sink = try JSONDecoder().decode(LogSinkConfig.self, from: JSONSerialization.data(withJSONObject: item))
                try sink.validate()
                guard !sinks.contains(where: { $0.id == sink.id }) else { throw LogSinkError(message: "id used twice") }
                sinks.append(sink)
            } catch {
                problems.append("log sink \(label): \(error is LogSinkError ? String(describing: error) : "not a valid sink entry")")
            }
        }
        return Loaded(sinks: sinks, problems: problems)
    }

    /// Bumped on every change to the list or to a secret, so a long-running streamer knows to start over.
    static let revisionKey = "log_sinks_rev"

    public static func revision(home: RMJHome) -> Double { ConfigFile.read(home)?[revisionKey] as? Double ?? 0 }

    /// A secret changed: the streamers rebuild their drainers.
    public static func markChanged(home: RMJHome) { try? ConfigFile.merge([revisionKey: Date().timeIntervalSince1970], home: home) }

    public static func save(_ sinks: [LogSinkConfig], home: RMJHome) throws {
        for sink in sinks { try sink.validate() }
        guard Set(sinks.map(\.id)).count == sinks.count else { throw LogSinkError(message: "two sinks share an id") }
        let encoder = JSONEncoder()
        let objects = try sinks.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
        do { try ConfigFile.merge(["log_sinks": objects, revisionKey: Date().timeIntervalSince1970], home: home) } catch {
            throw LogSinkError(message: "config.json could not be written: \(error.localizedDescription)")
        }
    }
}
