import Foundation

/// Every machine on the tailnet with what Tailscale knows of it, joined with the destination configured for it and the
/// last probe: the Settings > Destinations list. Nothing here contacts a machine.
public struct BoxInventory: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public let peerID: String
        public let host: String
        public let address: String?
        public let os: String
        public let online: Bool
        /// The destination name when the rules file configures this peer.
        public let destination: String?
        /// Setup deploys docker containers: only a Linux peer can be a destination.
        public let canBeDestination: Bool
        public let osName: String?
        public let memory: String?
        public let disk: String?
        public let probedText: String?
    }

    public let rows: [Row]

    public init(tailnet: TailnetState, rules: Rules?, probes: [String: DestinationProbeResult], now: Date) {
        let configured = Dictionary((rules?.destinations ?? [:]).map { ($0.value.peerID, $0.key) }, uniquingKeysWith: { first, _ in first })
        rows = tailnet.peers.map { peer in
            let name = configured[peer.id]
            let probe = name.flatMap { probes[$0] }
            return Row(peerID: peer.id, host: peer.hostName.isEmpty ? peer.dnsName : peer.hostName, address: peer.addresses.first,
                       os: peer.os, online: peer.online, destination: name, canBeDestination: peer.os.lowercased() == "linux",
                       osName: probe?.osName, memory: probe.flatMap(Self.memory), disk: probe.flatMap(Self.disk),
                       probedText: probe.map { "probed \(PanelFormat.age(now.timeIntervalSince($0.probedAt)))" })
        }.sorted { ($0.destination != nil ? 0 : 1, !$0.online ? 1 : 0, $0.host) < ($1.destination != nil ? 0 : 1, !$1.online ? 1 : 0, $1.host) }
    }

    private static func gigabytes(_ megabytes: Int) -> String {
        let value = Double(megabytes) / 1024
        return value >= 100 ? String(format: "%.0f GB", value) : String(format: "%.1f GB", (value * 10).rounded() / 10)
    }

    static func memory(_ probe: DestinationProbeResult) -> String? {
        guard let total = probe.memoryTotalMB else { return nil }
        guard let free = probe.memoryFreeMB else { return "\(gigabytes(total)) RAM" }
        return "\(gigabytes(total)) RAM, \(gigabytes(free)) available"
    }

    static func disk(_ probe: DestinationProbeResult) -> String? {
        guard let total = probe.diskTotalMB else { return nil }
        guard let free = probe.diskFreeMB else { return "\(gigabytes(total)) disk" }
        return "\(gigabytes(total)) disk, \(gigabytes(free)) free"
    }
}

public extension Rules {
    /// The `rx-*` images the rules send to a destination, so setup builds exactly those.
    func images(for destination: String) -> [String] {
        Array(Set(rules.filter { $0.to.contains(destination) }.compactMap(\.image))).sorted()
    }
}
