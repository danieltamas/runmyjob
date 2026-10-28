import Foundation

/// A destination as the network layer sees it: the stable peer ID stored when it was added, the
/// ssh alias (user and host-key name only) and, for one configured by address, that address.
public struct DestinationTarget: Sendable, Equatable {
    public let alias: String
    public let peerID: String?
    public let literalAddress: String?

    public init(alias: String, peerID: String?, literalAddress: String? = nil) {
        self.alias = alias
        self.peerID = peerID
        self.literalAddress = literalAddress
    }
}

public enum Availability: Sendable, Equatable {
    case online(address: String)
    case offline(String)
    case unreachable(String)
    case rejected(String)

    public var isAvailable: Bool {
        if case .online = self { return true }
        return false
    }
}

public enum DestinationResolver {
    /// No DNS, no ssh config: the peer is found by its ID (or the literal address among the peers'),
    /// so MagicDNS off, split DNS and renames change nothing.
    public static func resolve(_ target: DestinationTarget, in tailnet: TailnetState) -> Availability {
        switch tailnet.standing {
        case .running: break
        case .stopped: return .offline("tailnet down: stopped")
        case .needsLogin: return .offline("tailnet down: needs login")
        case .noClient: return .offline("tailnet down: Tailscale is not installed or not running")
        case .unknown(let reason): return .offline("tailnet down: \(reason)")
        }
        let peer: TailnetPeer
        if let literal = target.literalAddress {
            guard TailnetAddress.isTailnet(literal), let found = tailnet.peers.first(where: { $0.addresses.contains(literal) }) else {
                return .rejected("not a tailnet address")
            }
            // A destination that also stores its peer ID keeps that identity: the address must be that peer's.
            guard target.peerID == nil || target.peerID == found.id else { return .rejected("address belongs to another peer") }
            peer = found
        } else if let id = target.peerID, let found = tailnet.peers.first(where: { $0.id == id }) {
            peer = found
        } else {
            return .offline("peer not in the tailnet")
        }
        guard peer.online else {
            return .offline(peer.lastSeen.map { "peer offline, last seen \(timestamp($0))" } ?? "peer offline")
        }
        guard let address = target.literalAddress ?? peer.addresses.first else { return .offline("peer has no tailnet address") }
        guard TailnetAddress.isTailnet(address) else { return .rejected("not a tailnet address") }
        return .online(address: address)
    }

    static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
