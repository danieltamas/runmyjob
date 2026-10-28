import RMJCore
import SwiftUI

/// Replaces the GitHub PATs a destination's runners register with. One field per GitHub owner; an empty field keeps
/// the stored token. A new token reaches the box on the next Set up / repair.
struct TokensSheet: View {
    let name: String
    let done: () -> Void
    @State private var groups: [(owner: String, targets: [String], stored: Bool)] = []
    @State private var entered: [String: String] = [:]
    @State private var problem: String?
    @State private var saved = false
    @State private var newTarget = ""

    var body: some View {
        ModalFrame(title: "Tokens for \(name)", detail: "GitHub tokens that register the runners. They are stored in your Keychain, never in a file.", content: {
            FieldBlock(title: "Repos and organizations", detail: "Runners register for these. Use owner/repo or org:Name. Each GitHub owner gets one token below.") {
                HStack(spacing: 8) {
                    GlassField(placeholder: "owner/repo or org:Name", text: $newTarget)
                    ChipButton(title: "Add", action: addTarget)
                }
                ForEach(groups.flatMap(\.targets), id: \.self) { target in
                    HStack {
                        Text(target).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        ChipButton(title: "Remove") { removeTarget(target) }
                    }
                }
            }
            if groups.isEmpty { Text("This destination has no runner targets.").font(.meta).foregroundStyle(Theme.textSecondary) }
            ForEach(groups, id: \.owner) { group in
                FieldBlock(title: group.owner, detail: group.targets.joined(separator: ", ") + (group.stored ? "  -  stored" : "  -  missing")) {
                    SecretField(placeholder: group.stored ? "Leave empty to keep the stored token" : "Personal access token", text: Binding(get: { entered[group.owner] ?? "" }, set: { entered[group.owner] = $0 }))
                }
            }
            if let problem { ProblemText(text: problem) }
            if saved { StatusLine(text: "Saved. Run Set up / repair to put the new token on the box.", tone: .ok) }
        }, footer: ModalFooter(secondary: .init(title: saved ? "Done" : "Cancel", run: done),
                               primary: saved ? nil : .init(title: "Save", disabled: entered.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }, run: save)))
        .onAppear(perform: load)
    }

    private func load() {
        guard case .valid(let rules, _) = RulesStore(home: RMJHome()).load(), let targets = rules.destinations[name]?.runnerTargets else { return }
        let found = DestinationOps.tokens(targets, home: RMJHome())
        let byOwner = Dictionary(grouping: targets) { $0.hasPrefix("org:") ? $0 : String($0.split(separator: "/").first ?? "") }
        groups = byOwner.keys.sorted().map { owner in
            let covered = byOwner[owner] ?? []
            return (owner, covered, covered.allSatisfy { found[$0] != nil })
        }
    }

    private func save() {
        for group in groups {
            let token = (entered[group.owner] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            for target in group.targets {
                do { try Keychain().write(token, account: "rmj.pat.\(target)") } catch {
                    problem = "Could not store the token for \(target): \(error)"
                    return
                }
            }
        }
        problem = nil
        entered = [:]
        saved = true
        load()
    }

    private func addTarget() {
        let target = newTarget.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        edit { $0.append(target) }
        newTarget = ""
    }

    private func removeTarget(_ target: String) { edit { $0.removeAll { $0 == target } } }

    /// Rewrites this destination's `runner_targets` in rules.json; the rules validator refuses a target outside the tenant.
    private func edit(_ change: (inout [String]) -> Void) {
        let store = RulesStore(home: RMJHome())
        guard case .valid(var rules, let fingerprint) = store.load(), var destination = rules.destinations[name] else { return }
        var targets = destination.runnerTargets ?? []
        change(&targets)
        destination.runnerTargets = Array(Set(targets)).sorted()
        rules.destinations[name] = destination
        do { try store.save(rules, expected: fingerprint); problem = nil; saved = false; load() } catch { problem = "Could not update the targets: \(error)" }
    }
}
