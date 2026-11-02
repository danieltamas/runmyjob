import Foundation

/// The app's rename check: heals the rules when GitHub renamed a repo they name, then sets the affected boxes up again.
/// A box that is off or fails keeps its place in `pending_repairs.json` and is tried again on the next check, also after a restart.
public struct RepoRenameWatch: Sendable {
    /// A refusal that stands is told once, not at every check.
    private final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var told = Set<String>()
        func firstTime(_ text: String) -> Bool { lock.withLock { told.insert(text).inserted } }
    }

    private static let told = Told()

    private let home: RMJHome
    private let api: GitHubAPI
    private let notice: @Sendable (String, String) -> Void

    public init(home: RMJHome, api: GitHubAPI = GHCLI(), notice: @escaping @Sendable (String, String) -> Void) {
        self.home = home
        self.api = api
        self.notice = notice
    }

    public func check(tailnet: @Sendable () async -> TailnetState) async {
        let healer = RepoRenameHealer(home: home, api: api,
                                      readToken: { try? Keychain().read(account: "rmj.pat.\($0)") },
                                      writeToken: { try Keychain().write($1, account: "rmj.pat.\($0)") })
        let result = await healer.run()
        for heal in result.healed { notice("Repo renamed", "\(heal.old) is now \(heal.new). The rules follow it; the box runner is being set up again.") }
        for refusal in result.refused {
            let text = "\(refusal.old) is now \(refusal.new): \(refusal.reason)."
            if Self.told.firstTime(text) { notice("Repo renamed, not followed", text) }
        }
        let pending = PendingRepairs(home: home)
        guard !pending.names.isEmpty else { return }
        let state = await tailnet()
        for name in pending.names.sorted() {
            // The rules are read again for each box: an edit made while an earlier box was being set up must not be deployed over.
            guard case .valid(let rules, let fingerprint) = RulesStore(home: home).load() else { return }
            guard rules.destinations[name] != nil else { try? pending.remove([name]); continue }
            let report = await DestinationSetup.repair(name, rules: rules, home: home, tailnet: state, api: api)
            // Rules edited while the box was being set up: it may hold what the old rules said, so it stays pending and is set up again from the new ones.
            guard case .valid(_, let after) = RulesStore(home: home).load(), after == fingerprint else { continue }
            if report.isReady, (try? pending.remove([name])) != nil { notice("Box set up", "\(name) runs the renamed repo's runner now.") }
        }
    }
}
