import Foundation

extension DestinationSetup {
    /// Sets one destination up from the rules as they are now: the Wizard's "Set up / repair", `rmj destination setup` and the rename healer all end here.
    /// A box that is not online on the tailnet is a failed "reachability" step, not a thrown error.
    public static func repair(_ name: String, rules: Rules, home: RMJHome, tailnet: TailnetState, api: GitHubAPI = GHCLI(),
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              notice: @escaping @Sendable (String) -> Void = { _ in }) async -> Report {
        guard let config = rules.destinations[name] else {
            return Report(steps: [Step(name: "rules", outcome: .failed, detail: "no destination \(name)", hint: "Fix ~/.rmj/rules.json")])
        }
        guard case .online(let address) = DestinationResolver.resolve(DestinationTarget(alias: config.sshAlias, peerID: config.peerID), in: tailnet) else {
            return Report(steps: [Step(name: "reachability", outcome: .failed, detail: "\(name) is not online on the tailnet", hint: "Start the machine or Tailscale on it")])
        }
        let targets = config.runnerTargets ?? []
        let tokens = DestinationOps.tokens(targets, home: home)
        let setup = DestinationSetup(shell: SSHOpsShell(address: address, alias: config.sshAlias), name: name, config: config,
                                     stack: SupportFiles.locate("runner-stack", environment: environment), images: SupportFiles.locate("box/images", environment: environment),
                                     neededImages: rules.images(for: name), tokens: tokens,
                                     registrations: registrations(api: api, targets: targets, tokens: tokens), notice: notice)
        return await setup.run()
    }
}
