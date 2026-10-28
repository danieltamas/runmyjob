import AppKit
import RMJCore
import SwiftUI

/// Which coding agents send their builds through RMJ. Claude Code gets a pre-command hook; the others get shims.
struct HooksPane: View {
    @State private var statuses: [HookInstaller.Status] = []
    @State private var error: String?
    private let installer = HooksCommand.installer(environment: ProcessInfo.processInfo.environment)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .hooks, title: "Hooks", detail: "Route an agent's cargo test and just check through RMJ, so they run on your boxes and show up in Jobs.")
            SettingsCard(title: "Agents", detail: "Only commands in a repo that one of your tenants owns are routed. Everything else runs as before.") {
                VStack(spacing: 8) {
                    ForEach(statuses, id: \.harness) { row($0) }
                }
                if let error { StatusLine(text: error, tone: .failed) }
            }
            notes
        }
        .onAppear { statuses = installer.status() }
    }

    private func row(_ status: HookInstaller.Status) -> some View {
        let installed = status.state == .installed || status.state == .shimsOnly(installed: true)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.harness.title).font(.rowTitle).foregroundStyle(Theme.textPrimary)
                Text(detail(status)).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Chip(text: HooksCommand.describe(status.state), color: installed ? Theme.ok : Theme.textSecondary, style: installed ? .tinted : .outline)
            if status.state != .notPresent {
                ActionButton(title: installed ? "Remove" : "Install", style: installed ? .secondary : .primary) { change(status.harness, install: !installed) }
            }
        }
    }

    private func detail(_ status: HookInstaller.Status) -> String {
        switch status.harness {
        case .claudeCode: "A pre-command hook in ~/.claude/settings.json: one entry, easy to remove."
        default: "Shims for cargo and just in ~/.rmj/shims. Put that folder first on the PATH of this agent's environment. scripts/check.sh cannot be shimmed."
        }
    }

    private func change(_ harness: HookInstaller.Harness, install: Bool) {
        do {
            statuses = install ? try installer.install(harness) : try installer.remove(harness)
            error = nil
        } catch { self.error = "\(error)" }
    }

    /// Other things on this Mac that look at the same commands, so nothing is a surprise.
    @ViewBuilder private var notes: some View {
        let bton = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ro.danieltamas.bton") != nil
        let oldGuard = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/agent-os/hooks/shared/remote-build-guard.sh")
        if bton || oldGuard {
            SettingsCard(title: "Found on this Mac") {
                VStack(alignment: .leading, spacing: 6) {
                    if bton {
                        Text("Bton is installed. Its agents are ordinary Claude Code and Codex sessions, so these hooks cover them too. RMJ does not depend on Bton.")
                    }
                    if oldGuard {
                        Text("The older fleet guard from agent-os is installed. It blocks the same commands: once the RMJ hook is on, stop linking the old one.")
                    }
                }
                .font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
