import Foundation

public enum UpdateStatus: Sendable, Equatable { case current, available(ReleaseInfo), unknown }

/// Asks the release feed whether a newer RMJ exists. An unreachable feed changes nothing and is logged once.
public actor UpdateChecker {
    private let repo: String
    private let installed: String
    private let feed: @Sendable (String) async -> ReleaseFeed.Outcome
    private let log: @Sendable (String) -> Void
    private var logged = false

    public init(repo: String, installed: String,
                feed: @escaping @Sendable (String) async -> ReleaseFeed.Outcome = { await ReleaseFeed.latest(repo: $0) },
                log: @escaping @Sendable (String) -> Void) {
        self.repo = repo
        self.installed = installed
        self.feed = feed
        self.log = log
    }

    public func check() async -> UpdateStatus {
        switch await feed(repo) {
        case .release(let release): return ReleaseInfo.isNewer(release.version, than: installed) ? .available(release) : .current
        case .noRelease: return .current
        case .unavailable:
            if !logged {
                logged = true
                log("rmj: cannot read the latest release of \(repo); update checks are skipped until it answers")
            }
            return .unknown
        }
    }
}
