import RMJCore
import SwiftUI

/// On a job that ran here because no tenant claims its repo: pick a tenant and the repo joins it, so the next run can go to that tenant's boxes.
struct JobTagMenu: View {
    let repo: String
    let command: String
    let model: PanelModel

    /// Only tenants a rule would send this command to are offered: tagging a Swift build to a tenant with only Node rules would change nothing.
    private var tenants: [String] {
        guard case .valid(let rules, _)? = model.snapshot.rulesState else { return [] }
        return TenantEditing.assignable(rules, command: command, repoCommands: model.snapshot.repoCommands[repo] ?? [])
    }

    var body: some View {
        if !tenants.isEmpty {
            Menu {
                Section("Run \(repo) on a tenant's boxes from the next run") {
                    ForEach(tenants, id: \.self) { tenant in
                        Button { tag(tenant) } label: { Label(tenant, systemImage: "building.2") }
                    }
                }
            } label: {
                Chip(text: "Run remote", symbol: "tag", color: Theme.local, style: .dashed)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("This repo belongs to no tenant, so its jobs run on this Mac. Pick a tenant to let them run on its boxes.")
        }
    }

    private func tag(_ tenant: String) {
        do {
            try TenantEditing.apply(.assign(repo: repo, tenant: tenant), home: RMJHome())
            model.say("\(repo) now belongs to \(tenant); its next run can use \(tenant)'s boxes")
            model.reloadRules()
        } catch {
            model.say("\(error)")
        }
    }
}
