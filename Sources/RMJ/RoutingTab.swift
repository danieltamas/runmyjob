import AppKit
import RMJCore
import SwiftUI

struct RoutingTab: View {
    @ObservedObject var model: PanelModel
    @State private var repo = ""
    @State private var command = ""
    @State private var answer: RouteDecision?
    @State private var asking = false
    @State private var testing = false

    var body: some View {
        if let routing = model.snapshot.routing {
            VStack(alignment: .leading, spacing: 10) {
                deny(routing)
                if let problem = routing.problem { self.problem(problem) } else {
                    rulesCard(routing)
                    explain(routing)
                    labelsCard(routing)
                }
            }
            .onAppear { prefill(routing) }
            .onChange(of: model.explain?.command) { _, _ in jump() }
        } else {
            EmptyState(symbol: "arrow.triangle.branch", title: "Reading the rules...")
        }
    }

    /// `Explain route` on a row: its repo and command, answered at once.
    private func jump() {
        guard let target = model.explain else { return }
        repo = target.repo
        command = target.command
        model.explain = nil
        testing = true
        Task { await ask() }
    }

    private func prefill(_ routing: RoutingPresentation) {
        if model.explain != nil { return jump() }
        guard repo.isEmpty, command.isEmpty else { return }
        repo = routing.explainRepo ?? ""
        command = routing.explainCommand ?? ""
    }

    /// A dry run of the rules: closed it is one line, open it takes a repo and a command and says which rule catches
    /// them and where the job would go. Nothing runs.
    private func explain(_ routing: RoutingPresentation) -> some View {
        HoverCard(accent: nil, action: testing ? nil : { withAnimation(Motion.spring) { testing = true } }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Test your rules").font(.rowTitle).foregroundStyle(Theme.textPrimary)
                        Text("Check which rule catches a repo and where its build would run. Nothing is run.")
                            .font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if testing { IconButton(symbol: "xmark", help: "Close", size: 22) { withAnimation(Motion.spring) { testing = false; answer = nil } } }
                }
                if testing {
                    FieldBlock(title: "Repo") { GlassField(placeholder: "owner/name", text: $repo, monospaced: true) }
                    FieldBlock(title: "Command") { GlassField(placeholder: "cargo test", text: $command, monospaced: true) }
                    HStack {
                        Spacer()
                        ActionButton(title: asking ? "Testing..." : "Test", style: .primary) { Task { await ask() } }
                            .disabled(asking || repo.isEmpty || command.isEmpty)
                    }
                    if let answer {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(answer.location == .local ? "Runs on this Mac" : "Runs on \(answer.locationName)")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(answer.location == .local ? Theme.local : Theme.ok)
                            ForEach(Array(answer.explanation.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ask() async {
        asking = true
        defer { asking = false }
        answer = await RoutingExplain.explain(repo: repo, command: command, state: model.snapshot.rulesState ?? .invalid(path: "", message: "no rules read"),
                                              tailnet: model.snapshot.tailnet)
    }

    private func deny(_ routing: RoutingPresentation) -> some View {
        HoverCard(accent: Theme.crit, action: nil) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(Theme.crit)
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: "Tenant deny")
                    Text(routing.denyText).font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func problem(_ problem: RoutingPresentation.Problem) -> some View {
        HoverCard(accent: Theme.crit, action: nil) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Rules file")
                Text(problem.message).font(.system(size: 12)).foregroundStyle(Theme.crit).fixedSize(horizontal: false, vertical: true)
                Text("The last valid rules stay in force: with none, every job runs on this Mac.").font(.meta).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ChipButton(title: "Open file") { NSWorkspace.shared.open(URL(fileURLWithPath: problem.path)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rulesCard(_ routing: RoutingPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: "Rules, first match wins")
                Spacer()
            }
            .padding(.horizontal, 4).padding(.top, 4)
            if model.editingRule == -1 {
                RuleEditorCard(index: nil, count: routing.rules.count, home: RMJHome(), repos: model.knownRepos, close: { withAnimation(Motion.spring) { model.editingRule = nil } }, changed: reload)
            }
            ForEach(Array(routing.rules.enumerated()), id: \.offset) { index, rule in
                if model.editingRule == index {
                    RuleEditorCard(index: index, count: routing.rules.count, home: RMJHome(), repos: model.knownRepos, close: { withAnimation(Motion.spring) { model.editingRule = nil } }, changed: reload)
                } else {
                    ruleRow(index, rule)
                }
            }
        }
    }

    private func reload() { model.reloadRules() }

    /// Two lines closed: the name with its chain, and what it matches. Tapping opens the editor in place.
    private func ruleRow(_ index: Int, _ rule: RoutingPresentation.RuleLine) -> some View {
        HoverCard(accent: nil, action: { withAnimation(Motion.spring) { model.editingRule = index } }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textTertiary).frame(width: 14)
                    Text(rule.name).font(.rowTitle).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                }
                HStack(spacing: 5) {
                    ForEach(Array(rule.chain.enumerated()), id: \.offset) { position, item in
                        if position > 0 { Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textTertiary) }
                        Chip(text: item.name, color: item.isLocal ? Theme.local : Theme.textPrimary)
                    }
                    if let environment = rule.environment { Chip(text: environment, color: Theme.textSecondary, style: .outline) }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 22)
                Text(rule.match).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true).padding(.leading, 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labelsCard(_ routing: RoutingPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "GitHub label mapping").padding(.leading, 4).padding(.top, 4)
            if routing.labels.isEmpty {
                Text("Workflows appear here once the GitHub poller has seen their jobs.").font(.meta).foregroundStyle(Theme.textTertiary).padding(.leading, 4)
            }
            ForEach(routing.labels, id: \.workflow) { line in
                HoverCard(accent: line.mismatch ? Theme.warn : nil, action: nil) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.repo).font(.rowTitle).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                        Text(line.workflow).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                        Text("runs-on: " + line.labels.joined(separator: ", ")).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        if line.mismatch {
                            Text("no destination serves these labels").font(.meta).foregroundStyle(Theme.warn)
                        } else {
                            Text("served by " + line.served.joined(separator: ", ")).font(.meta).foregroundStyle(Theme.ok)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
