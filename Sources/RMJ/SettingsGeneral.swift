import AppKit
import RMJCore
import ServiceManagement
import SwiftUI

struct GeneralPane: View {
    @AppStorage("menuBarElapsed") private var elapsedInMenuBar = false
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?
    private let home = RMJHome()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .general, title: "General", detail: "How RMJ looks and when it opens.")
            SettingsCard(title: "Theme", detail: "How the panel and this window look. A colour means the same in each.") {
                HStack(spacing: 6) {
                    ForEach(Look.allCases) { look in
                        SegmentChip(title: look.title, selected: Appearance.shared.look == look) {
                            withAnimation(Motion.gentle) { Appearance.shared.choose(look) }
                        }
                    }
                }
            }
            SettingsCard(title: "Open at login", detail: "RMJ only tracks jobs while it runs.") {
                SwitchRow(title: "Open RMJ when you log in", isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
                if let loginProblem { ProblemText(text: loginProblem) }
            }
            SettingsCard(title: "Menu bar text", detail: "How long the longest running job has run, next to the icon.") {
                SwitchRow(title: "Show elapsed time in the menu bar", isOn: $elapsedInMenuBar)
            }
            SettingsCard(title: "Data folder", detail: "The ledger and logs on this Mac. Secrets are in the Keychain, never here.") {
                SettingsRow(title: home.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    PillButton(title: "Show in Finder", symbol: "arrow.up.right", prominent: false) {
                        try? home.prepare()
                        NSWorkspace.shared.activateFileViewerSelecting([home.url])
                    }
                }
            }
        }
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            opensAtLogin = SMAppService.mainApp.status == .enabled
            loginProblem = nil
        } catch {
            opensAtLogin = SMAppService.mainApp.status == .enabled
            loginProblem = "Could not change the login item: \(error.localizedDescription)"
        }
    }
}

struct TailscalePane: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let state = model.snapshot.tailnet
        let chip = model.snapshot.tailnetChip
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .tailscale, title: "Tailscale", detail: "Every destination is reached on the tailnet and nowhere else.")
            SettingsCard(title: "State", detail: "Read from the Tailscale client every 10 s while the panel is open or a job runs.") {
                SettingsRow(title: chip.text) { Chip(text: standing(state.standing), color: Theme.color(chip.tone)) }
                RowDivider()
                SettingsRow(title: "Client") {
                    Text(Executables.resolve("tailscale")?.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "not found")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                }
                if state.standing != .running {
                    RowDivider()
                    Text("Every job runs on this Mac until the tailnet is up.").font(.system(size: 12)).foregroundStyle(Theme.warn)
                    PillButton(title: "Open Tailscale", symbol: "arrow.up.right", prominent: false) {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys") ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos") {
                            NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        } else {
                            model.say("Tailscale is not installed.")
                        }
                    }
                }
            }
            SettingsCard(title: "Peers RMJ uses", detail: "Destinations are found by node ID, so renames and DNS settings change nothing.") {
                let peers = model.snapshot.cards
                if peers.isEmpty { Text("No destination yet.").font(.meta).foregroundStyle(Theme.textTertiary) }
                ForEach(Array(peers.enumerated()), id: \.offset) { index, card in
                    if index > 0 { RowDivider() }
                    SettingsRow(title: card.name, detail: model.snapshot.destinations[index].config.peerID.isEmpty ? "no node ID yet" : model.snapshot.destinations[index].config.peerID) {
                        Chip(text: card.state.text, color: Theme.color(card.state.tone), style: .outline)
                    }
                }
            }
        }
    }

    private func standing(_ standing: TailnetState.Standing) -> String {
        switch standing {
        case .running: "running"
        case .stopped: "stopped"
        case .needsLogin: "needs login"
        case .noClient: "no client"
        case .unknown(let reason): reason
        }
    }
}

struct RetentionPane: View {
    @State private var status: RetentionStatus?
    @State private var note: String?
    private let home = RMJHome()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .retention, title: "Retention", detail: "Jobs and their logs are kept for 30 days.")
            SettingsCard(title: "Logs on this Mac", detail: "The folder holds at most 2 GB; the oldest finished logs go first.") {
                SettingsRow(title: status.map { "\($0.files) files, \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file)) of 2 GB" } ?? "Reading...") {
                    PillButton(title: "Prune now", symbol: "trash", prominent: false) { Task { await pruneNow() } }
                }
                RowDivider()
                SettingsRow(title: "Pending pulls", detail: "Logs still on a box, fetched when it is reachable.") {
                    Text("\(status?.pending ?? 0)").font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
                if let note { Text(note).font(.meta).foregroundStyle(Theme.textTertiary) }
            }
        }
        .task { status = await RetentionStatus.read(home: home) }
    }

    private func pruneNow() async {
        do {
            let removed = try await RetentionStatus.pruneNow(home: home)
            note = removed == 0 ? "Nothing older than 30 days." : "Removed \(removed) job\(removed == 1 ? "" : "s") older than 30 days."
        } catch {
            note = "Prune failed: \(error.localizedDescription)"
        }
        status = await RetentionStatus.read(home: home)
    }
}
