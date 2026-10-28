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

    var body: some View {
        ModalFrame(title: "Tokens for \(name)", detail: "GitHub tokens that register the runners. They are stored in your Keychain, never in a file.", content: {
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
}
