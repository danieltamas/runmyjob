import RMJCore
import SwiftUI

/// Reads the tailnet, the rules file and the boxes for Settings > Destinations. The boxes are probed when the pane opens
/// and every 5 minutes while it stays open; the panel's own loop keeps probing them in the background.
@MainActor
final class BoxesModel: ObservableObject {
    @Published var inventory = BoxInventory(tailnet: TailnetState(standing: .unknown("not read"), magicDNSEnabled: false, peers: [], readAt: Date()),
                                            rules: nil, probes: [:], now: Date())
    @Published var tailnet: TailnetState?
    @Published var refreshing = false
    private var probes: [String: DestinationProbeResult] = [:]

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        let state = await TailnetState.read()
        let rules = (try? PanelLoader())?.rules()
        for (name, config) in rules?.destinations ?? [:] where config.enabled {
            probes[name] = await DestinationProbe().probe(DestinationTarget(alias: config.sshAlias, peerID: config.peerID, requires: config.requires ?? []), tailnet: state)
        }
        tailnet = state
        inventory = BoxInventory(tailnet: state, rules: rules, probes: probes, now: Date())
    }

    func loop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(PanelModel.backgroundProbeInterval))
        }
    }
}

struct DestinationsPane: View {
    @ObservedObject var model: PanelModel
    @StateObject private var boxes = BoxesModel()
    @State private var adding: BoxInventory.Row?
    @State private var repairing: String?
    @State private var tokens: String?

    /// Only machines that can be a destination (Linux) or already are one; Macs and Windows PCs are not listed.
    private var viable: [BoxInventory.Row] { boxes.inventory.rows.filter { $0.canBeDestination || $0.destination != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .destinations, title: "Destinations",
                       detail: "The machines on your tailnet. Add one and RMJ sets it up: images, runners, tokens. Nothing is installed on it.")
            HStack {
                Text(boxes.refreshing ? "Reading the tailnet..." : "\(viable.count) Linux machine\(viable.count == 1 ? "" : "s") on the tailnet")
                    .font(.meta).foregroundStyle(Theme.textTertiary)
                Spacer()
                ChipButton(title: "Refresh") { Task { await boxes.refresh() } }
            }
            if viable.isEmpty, !boxes.refreshing {
                ProblemText(text: "No Linux machine on the tailnet. " + (boxes.tailnet.map { TailnetChip($0, now: Date()).text } ?? "") + " Open Tailscale and sign in.")
            }
            ForEach(viable, id: \.peerID) { row in
                BoxRow(row: row, onAdd: { adding = row }, onRepair: { repairing = $0 }, onTokens: { tokens = $0 })
            }
        }
        .task { await boxes.loop() }
        .sheet(item: Binding(get: { adding.map { PeerSheet(row: $0) } }, set: { adding = $0?.row })) { sheet in
            DestinationWizard(row: sheet.row, tenants: Set((try? PanelLoader())?.rules()?.tenants.keys.map { $0 } ?? []).sorted()) {
                adding = nil
                Task { await boxes.refresh() }
            }
        }
        .sheet(item: Binding(get: { tokens.map { NameSheet(name: $0) } }, set: { tokens = $0?.name })) { sheet in
            TokensSheet(name: sheet.name) { tokens = nil }
        }
        .sheet(item: Binding(get: { repairing.map { NameSheet(name: $0) } }, set: { repairing = $0?.name })) { sheet in
            SetupRunView(name: sheet.name, tokens: [:]) {
                repairing = nil
                Task { await boxes.refresh() }
            }
        }
    }
}

struct PeerSheet: Identifiable { let row: BoxInventory.Row; var id: String { row.peerID } }
struct NameSheet: Identifiable { let name: String; var id: String { name } }

private struct BoxRow: View {
    let row: BoxInventory.Row
    let onAdd: () -> Void
    let onRepair: (String) -> Void
    let onTokens: (String) -> Void

    var body: some View {
        Bezel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(row.online ? Theme.ok : Theme.neutral).frame(width: 8, height: 8)
                    Text(row.host).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    if let name = row.destination { Chip(text: "destination: \(name)", color: Theme.teal) }
                    Spacer()
                    Chip(text: row.os.isEmpty ? "unknown os" : row.os)
                    if let address = row.address { Text(address).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary) }
                }
                let facts = [row.osName, row.memory, row.disk].compactMap { $0 }
                if !facts.isEmpty {
                    Text(facts.joined(separator: "  -  ")).font(.meta).foregroundStyle(Theme.textSecondary)
                    if let probed = row.probedText { Text(probed).font(.meta).foregroundStyle(Theme.textTertiary) }
                }
                if let name = row.destination {
                    HStack { ChipButton(title: "Set up / repair") { onRepair(name) }; ChipButton(title: "Tokens") { onTokens(name) }; Spacer() }
                } else if row.canBeDestination {
                    HStack { ChipButton(title: "Add as destination", action: onAdd); Spacer() }
                } else {
                    Text("Destinations run docker on Linux; this machine is not one.").font(.meta).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
