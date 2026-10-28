import Foundation

public struct TailnetPeer: Sendable, Equatable {
    public let id: String
    public let dnsName: String
    public let hostName: String
    /// `linux`, `macOS`, `windows`... as Tailscale reports it; empty when unknown.
    public let os: String
    public let addresses: [String]
    public let online: Bool
    public let lastSeen: Date?
    public let keyExpiry: Date?
    /// The DERP region a connection is relayed through; nil when the connection is direct.
    public let relay: String?
}

/// What `tailscale status --json` said, and when. Parsing is total: anything unreadable is `.unknown`.
public struct TailnetState: Sendable, Equatable {
    public enum Standing: Sendable, Equatable {
        case running, stopped, needsLogin, noClient
        case unknown(String)
    }

    public static let fixtureVariable = "RMJ_TAILSCALE_FIXTURE"

    public let standing: Standing
    public let magicDNSEnabled: Bool
    public let peers: [TailnetPeer]
    public let readAt: Date

    public init(standing: Standing, magicDNSEnabled: Bool, peers: [TailnetPeer], readAt: Date) {
        self.standing = standing
        self.magicDNSEnabled = magicDNSEnabled
        self.peers = peers
        self.readAt = readAt
    }

    public func age(at now: Date = Date()) -> TimeInterval { now.timeIntervalSince(readAt) }

    public static func parse(_ data: Data, readAt: Date = Date()) -> TailnetState {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let backend = root["BackendState"] as? String else {
            return TailnetState(standing: .unknown("unreadable tailscale status"), magicDNSEnabled: false, peers: [], readAt: readAt)
        }
        let selfOnline = (root["Self"] as? [String: Any])?["Online"] as? Bool ?? false
        let standing: Standing = switch backend {
        case "Running": selfOnline ? .running : .unknown("this Mac is not online in the tailnet")
        case "Stopped": .stopped
        case "NeedsLogin", "NeedsMachineAuth": .needsLogin
        default: .unknown("backend state \(backend)")
        }
        let magic = (root["CurrentTailnet"] as? [String: Any])?["MagicDNSEnabled"] as? Bool ?? false
        let peers = ((root["Peer"] as? [String: Any]) ?? [:]).values.compactMap { ($0 as? [String: Any]).flatMap(peer) }
        return TailnetState(standing: standing, magicDNSEnabled: magic, peers: peers.sorted { $0.id < $1.id }, readAt: readAt)
    }

    /// The fixture named by `RMJ_TAILSCALE_FIXTURE`, else the CLI of Tailscale.app or on PATH.
    public static func read(runner: ProcessRunner = ProcessRunner(),
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            now: Date = Date()) async -> TailnetState {
        if let path = environment[fixtureVariable], !path.isEmpty {
            guard let data = FileManager.default.contents(atPath: path) else {
                return TailnetState(standing: .unknown("cannot read the fixture \(path)"), magicDNSEnabled: false, peers: [], readAt: now)
            }
            return parse(data, readAt: now)
        }
        let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        guard let cli = FileManager.default.isExecutableFile(atPath: app) ? app : Executables.resolve("tailscale") else {
            return TailnetState(standing: .noClient, magicDNSEnabled: false, peers: [], readAt: now)
        }
        do {
            let output = try await runner.run(cli, ["status", "--json"], timeout: .seconds(10))
            // A stopped or logged-out daemon still answers with JSON; no answer at all means no daemon.
            let state = parse(output.stdout, readAt: now)
            // A command that failed does not authorize a connection, whatever its stdout says.
            guard output.status != 0 else { return state }
            let standing: Standing = if case .unknown = state.standing { .noClient } else { .unknown("tailscale status exited \(output.status)") }
            return TailnetState(standing: standing, magicDNSEnabled: false, peers: [], readAt: now)
        } catch {
            return TailnetState(standing: .unknown("tailscale status failed: \(error.localizedDescription)"), magicDNSEnabled: false, peers: [], readAt: now)
        }
    }

    private static func peer(_ json: [String: Any]) -> TailnetPeer? {
        guard let id = json["ID"] as? String, !id.isEmpty else { return nil }
        let relay = json["Relay"] as? String
        let direct = (json["CurAddr"] as? String).map { !$0.isEmpty } ?? false
        return TailnetPeer(id: id, dnsName: json["DNSName"] as? String ?? "", hostName: json["HostName"] as? String ?? "", os: json["OS"] as? String ?? "",
                           addresses: json["TailscaleIPs"] as? [String] ?? [], online: json["Online"] as? Bool ?? false,
                           lastSeen: date(json["LastSeen"]), keyExpiry: date(json["KeyExpiry"]),
                           relay: direct || relay?.isEmpty != false ? nil : relay)
    }

    /// Tailscale writes the zero time for "never".
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        return parsed.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
    }
}
