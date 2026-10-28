import Foundation

/// The header, the menu bar icon and the footer, decided from plain inputs (docs/DESIGN.md, The menu bar icon and
/// The panel).
public enum MenuBarIconState: Sendable, Equatable {
    case idle
    /// 1 to 9; ten and more read `9+`.
    case running(Int)
    case failed
    case tailnetDown

    public var countLabel: String? {
        guard case .running(let count) = self else { return nil }
        return count > 9 ? "9+" : String(count)
    }

    /// Tailnet down wins over everything: nothing is routed while it lasts. A failure badge stays until seen.
    public static func resolve(tailnet: TailnetState.Standing, running: Int, unseenFailure: Bool) -> MenuBarIconState {
        if tailnet != .running { return .tailnetDown }
        if unseenFailure { return .failed }
        return running > 0 ? .running(running) : .idle
    }
}

public struct TailnetChip: Sendable, Equatable {
    public let text: String
    public let tone: JobRowPresentation.Tone

    /// `relayed` when any peer in use goes through a relay; `key expires in 3 d` inside two weeks.
    public init(_ state: TailnetState, now: Date) {
        switch state.standing {
        case .running:
            let expiring = state.peers.compactMap(\.keyExpiry).filter { $0.timeIntervalSince(now) < 14 * 86_400 }.min()
            if let expiring {
                let days = max(0, Int(expiring.timeIntervalSince(now) / 86_400))
                self.init(text: "key expires in \(days) d", tone: .warn)
            } else if state.peers.contains(where: { $0.online && $0.relay != nil }) {
                self.init(text: "relayed", tone: .warn)
            } else {
                self.init(text: "tailnet up", tone: .ok)
            }
        case .noClient: self.init(text: "no client", tone: .unknown)
        case .stopped, .needsLogin, .unknown: self.init(text: "tailnet down", tone: .unknown)
        }
    }

    init(text: String, tone: JobRowPresentation.Tone) {
        self.text = text
        self.tone = tone
    }
}

/// `GitHub 12 s`, `boxes 30 s`, and the rate budget when it runs low.
public struct PanelFooter: Sendable, Equatable {
    public static let budgetThreshold = 500

    public let polls: [String]
    public let rateBudget: String?

    public init(githubPolledAt: Date?, boxesPolledAt: Date?, rateRemaining: Int?, now: Date) {
        func age(_ label: String, _ date: Date?) -> String {
            date.map { "\(label) \(PanelFormat.wait(now.timeIntervalSince($0)))" } ?? "\(label) -"
        }
        polls = [age("GitHub", githubPolledAt), age("boxes", boxesPolledAt)]
        rateBudget = rateRemaining.flatMap { $0 < Self.budgetThreshold ? "rate budget \($0)" : nil }
    }
}
