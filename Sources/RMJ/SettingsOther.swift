import AppKit
import RMJCore
import SwiftUI

/// Panes whose controls arrive with their own units (docs/PLAN.md): each says what exists today and what does not.
private struct Pending: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hourglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct NotificationsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .notifications, title: "Notifications", detail: "Failed or lost jobs, an unreachable destination, finished jobs.")
            SettingsCard(title: "Alerts") {
                Pending(text: "Notifications arrive with U11. The menu bar badge already marks a failure you have not seen.")
            }
        }
    }
}

struct AgentPane: View {
    private static let connect = "claude mcp add rmj -- ~/.local/bin/rmj mcp"
    @State private var enabled = AgentAccess.isEnabled(home: RMJHome())
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .agent, title: "Agent access", detail: "What an agent can read from RMJ, and nothing more.")
            SettingsCard(title: "MCP server", detail: "rmj mcp is read-only and local: jobs, failures, redacted logs, destinations and routing explanations. It starts, reruns and cancels nothing, and opens no connection to a box.") {
                SwitchRow(title: "Let agents read RMJ data", isOn: Binding(get: { enabled }, set: { change($0) }))
                if let error { StatusLine(text: error, tone: .failed) }
                InstallLine(command: Self.connect)
            }
            SettingsCard(title: "What the switch covers") {
                Text("It governs the MCP server only. An agent with a shell on this Mac can still run rmj, whose read commands have no switch; withhold run, rerun and cancel from it with a hook if it should only inspect.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { enabled = AgentAccess.isEnabled(home: RMJHome()) }
    }

    private func change(_ on: Bool) {
        do {
            try AgentAccess.set(on, home: RMJHome())
            error = nil
        } catch {
            self.error = "Cannot change the setting: \(error.localizedDescription)"
        }
        enabled = AgentAccess.isEnabled(home: RMJHome())
    }
}

struct AboutPane: View {
    private static let repo = URL(string: "https://github.com/danieltamas/runmyjob")!

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .about, title: "About Run My Job (RMJ)", detail: "Who makes it, where it lives, and which build this is.")
            Bezel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 16) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Run My Job (RMJ)").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Text(Self.versionLine).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                            Text("Checking for updates arrives with U11.").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsCard(title: "Why it exists", detail: nil) {
                Text("""
                    Builds and test suites should not run on the laptop you work on. RMJ sends them to your own boxes over \
                    Tailscale, tracks every run in one place with exact timings, keeps the logs for 30 days, and runs the job \
                    here when no box is reachable. It lives in the menu bar and never leaves your tailnet.
                    """)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard(title: "Made by Daniel Tamas", detail: "Open source under the MIT license.") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        link("Repository", Self.repo)
                        link("Report an issue", Self.repo.appendingPathComponent("issues"))
                    }
                    HStack(spacing: 8) {
                        link("danieltamas.com", URL(string: "https://danieltamas.com")!)
                        link("Daniel on GitHub", URL(string: "https://github.com/danieltamas")!)
                    }
                }
            }
        }
    }

    /// `v0.1.0 + 3 commits (abc1234), built from source, uncommitted changes`, from the bundle's version and the
    /// `git describe` the installer stamps into Info.plist.
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        var source = info?["RMJSource"] as? String
        let dirty = source?.hasSuffix("-dirty") ?? false
        if dirty { source?.removeLast("-dirty".count) }
        var line = "v\(version)"
        if let source, let match = source.wholeMatch(of: /v?(\d+\.\d+\.\d+)(?:-(\d+)-g([0-9a-f]+))?/) {
            line = "v\(match.1)"
            if let commits = match.2.flatMap({ Int($0) }), commits > 0 { line += " + \(commits) commit\(commits == 1 ? "" : "s")" }
            if let commit = match.3 { line += " (\(commit))" }
        } else if let source, !source.isEmpty {
            line += " (\(source))"
        }
        if info?["RMJSource"] != nil { line += ", built from source" }
        if dirty { line += ", uncommitted changes" }
        return line
    }

    private func link(_ title: String, _ url: URL) -> some View {
        PillButton(title: title, symbol: "arrow.up.right", prominent: false) { NSWorkspace.shared.open(url) }
    }
}
