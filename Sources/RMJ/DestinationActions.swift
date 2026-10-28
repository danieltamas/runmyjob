import AppKit
import RMJCore

/// The buttons of a Destinations card. Each one says what it will do before it does it, and what it did after.
@MainActor
enum DestinationActions {
    static func perform(_ action: DestinationCardPresentation.Action, on card: DestinationCardPresentation, model: PanelModel) {
        switch action {
        case .logs:
            NSWorkspace.shared.open(RMJHome().url.appendingPathComponent("logs", isDirectory: true))
        case .prune:
            Task { await prune(card) }
        case .rebuild:
            Task { await rebuild(card) }
        }
    }

    private static func ops(_ card: DestinationCardPresentation) -> DestinationOps? {
        guard let config = (try? PanelLoader())?.rules()?.destinations[card.name] else { return nil }
        return DestinationOps(name: card.name, config: config, home: RMJHome())
    }

    private static func prune(_ card: DestinationCardPresentation) async {
        guard let ops = ops(card) else { return alert("Cannot prune", "The rules file has no destination named \(card.name).") }
        do {
            let found = try await ops.pruneCandidates()
            guard !found.isEmpty else { return alert("Nothing to prune", "No stale registration for \(card.name) is older than 10 minutes.") }
            let list = found.map { "\($0.target): \($0.runner)" }.joined(separator: "\n")
            guard confirm("Delete \(found.count) stale registration\(found.count == 1 ? "" : "s")?", "Offline, idle, labelled \(card.name), older than 10 minutes:\n\n\(list)", button: "Delete") else { return }
            let result = try await ops.prune()
            let skipped = result.skipped.map { "\($0.runner): \($0.reason)" }.joined(separator: "\n")
            alert("Pruned \(result.deleted.count)", skipped.isEmpty ? result.deleted.joined(separator: "\n") : "Skipped:\n\(skipped)")
        } catch {
            alert("Prune failed", "\(error)")
        }
    }

    private static func rebuild(_ card: DestinationCardPresentation) async {
        guard let ops = ops(card), let address = await availableAddress(ops) else { return alert("Cannot rebuild", "\(card.name) is not reachable on the tailnet.") }
        guard confirm("Rebuild the runner images on \(card.name)?", "Runs docker compose build in \(ops.config.home)/infra/gh-runners. Running runners keep their image until they are recreated.", button: "Rebuild") else { return }
        do {
            try await ops.rebuildImages(shell: SSHOpsShell(address: address, alias: ops.config.sshAlias))
            alert("Images rebuilt", "The next recreate of a runner uses them.")
        } catch {
            alert("Rebuild failed", "\(error)")
        }
    }

    private static func availableAddress(_ ops: DestinationOps) async -> String? {
        let tailnet = await TailnetState.read()
        guard case .online(let address) = DestinationResolver.resolve(DestinationTarget(alias: ops.config.sshAlias, peerID: ops.config.peerID), in: tailnet) else { return nil }
        return address
    }

    private static func confirm(_ title: String, _ detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }
}
