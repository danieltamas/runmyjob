import RMJCore
import SwiftUI

struct JobsTab: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let sections = model.snapshot.rows
        if sections.isEmpty {
            EmptyState(symbol: "bolt.horizontal", title: "No jobs yet",
                       detail: "Agents' cargo test and just check land here once the hook is installed (Settings > Hooks).")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sections, id: \.0) { section, rows in
                    Eyebrow(text: section.rawValue).padding(.top, 6).padding(.leading, 4)
                    ForEach(rows, id: \.id) { row in
                        JobRowView(row: row, expanded: model.expanded.contains(row.id), model: model) {
                            withAnimation(Motion.snappy) { model.toggle(row.id) }
                        }
                    }
                }
            }
        }
    }
}

extension JobRowPresentation.Agent {
    var symbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .opencode: "curlybraces"
        case .hermes: "paperplane"
        case .github: "cat"
        case .terminal: "terminal"
        }
    }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .hermes: "Hermes"
        case .github: "GitHub"
        case .terminal: "terminal"
        }
    }
}

/// One job: two lines and a meta line (docs/DESIGN.md, Jobs). Log and Rerun sit in the row of a failed job.
struct JobRowView: View {
    let row: JobRowPresentation
    let expanded: Bool
    let model: PanelModel
    let toggle: () -> Void

    var body: some View {
        HoverCard(accent: Theme.color(row.stateChip.tone), action: toggle) {
            VStack(alignment: .leading, spacing: 5) {
                titleLine
                detailLine
                Text(row.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(expanded ? 4 : 1).truncationMode(.middle).help(row.command)
                metaLine
                if !row.actions.isEmpty { actions }
                if expanded { Expansion(row: row, model: model) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var titleLine: some View {
        HStack(alignment: .top, spacing: 6) {
            // The title takes the free width and wraps to a second line before anything truncates.
            Text(row.title).font(.rowTitle).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            Chip(text: row.location.text, symbol: row.locationKind == .local ? "laptopcomputer" : nil,
                 color: row.locationKind == .local ? Theme.local : Theme.tenant(row.tenant))
            // A GitHub row already says "github" in its location chip.
            if row.agent != .github {
                Image(systemName: row.agent.symbol).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 14, height: 18).help(row.agent.title)
            }
            Chip(text: row.stateChip.text, color: Theme.color(row.stateChip.tone), style: row.state == .running ? .filled : .tinted)
        }
    }

    private var detailLine: some View {
        HStack(spacing: 6) {
            if let branch = row.branch { Text(branch).lineLimit(1).truncationMode(.middle) }
            if let worktree = row.worktree { Text(worktree).lineLimit(1).truncationMode(.middle) }
            if let commit = row.commit { Text(commit).font(.system(size: 11, design: .monospaced)) }
            if row.dirty { Circle().fill(Theme.warn).frame(width: 5, height: 5).help("uncommitted changes") }
        }
        .font(.meta).foregroundStyle(Theme.textTertiary)
    }

    private var metaLine: some View {
        row.meta.enumerated().reduce(Text("")) { text, item in
            let part = Text(item.element.text).foregroundStyle(Theme.color(item.element.tone))
            return item.offset == 0 ? part : Text("\(text)\(Text("  \u{00B7}  ").foregroundStyle(Theme.textTertiary))\(part)")
        }
        .font(.system(size: 11, design: .default).monospacedDigit())
        .lineLimit(expanded || row.state == .queued ? nil : 1).truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ForEach(row.actions, id: \.self) { action in
                ChipButton(title: action.rawValue) { JobActions.perform(action, on: row, model: model) }
            }
        }
        .padding(.top, 2)
    }
}

/// The rest of a row once opened: where the time went, what rule applied, the end of the log and the actions.
private struct Expansion: View {
    let row: JobRowPresentation
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.vertical, 2)
            timeline
            ForEach(row.detail.timestamps, id: \.self) { Text($0).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary) }
            if let rule = row.detail.rule { fact("rule", rule) }
            if let reason = row.detail.reason, !row.meta.contains(where: { $0.text == "local: \(reason)" }) { fact("fallback", reason) }
            if let session = row.detail.session { fact("session", session) }
            fact("job", row.id)
            logTail
            buttons
        }
    }

    @ViewBuilder
    private var timeline: some View {
        let segments = row.detail.timeline
        let total = max(1, segments.reduce(0) { $0 + $1.seconds })
        if !segments.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.label) { segment in
                            Capsule().fill(color(segment.label)).frame(width: max(4, proxy.size.width * segment.seconds / total))
                        }
                    }
                }
                .frame(height: 5)
                Text(segments.map { "\($0.label) \(PanelFormat.duration($0.seconds))" }.joined(separator: "  \u{00B7}  ")).font(.meta).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func color(_ label: String) -> Color {
        label == "queued" ? Theme.unknown : label == "sync" ? Theme.warn : Theme.running
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).foregroundStyle(Theme.textTertiary)
            Text(value).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
        }
        .font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var logTail: some View {
        switch model.tails[row.id] {
        case .lines(let lines) where !lines.isEmpty:
            Text(lines.joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .lineLimit(40).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(Theme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous)).textSelection(.enabled)
        case .lines:
            Text("The log is empty so far.").font(.meta).foregroundStyle(Theme.textTertiary)
        case .note(let note):
            Text("log: \(note)").font(.meta).foregroundStyle(Theme.textTertiary)
        case nil:
            EmptyView()
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            ChipButton(title: "Open log") { JobActions.perform(.log, on: row, model: model) }
            if row.detail.canCancel {
                ChipButton(title: "Cancel", destructive: true) { JobActions.cancel(row, model: model) }
            }
            if row.state.isSettledOrLost { ChipButton(title: "Rerun") { JobActions.perform(.rerun, on: row, model: model) } }
            if let url = row.detail.url { ChipButton(title: "Open on GitHub") { NSWorkspace.shared.open(url) } }
            if !row.detail.isGitHub { ChipButton(title: "Explain route") { JobActions.explain(row, model: model) } }
        }
    }
}

extension JobState {
    /// Rows that offer `Rerun` once opened: finished ones, and `lost`.
    var isSettledOrLost: Bool { isSettled || self == .lost }
}

/// The buttons of a row.
enum JobActions {
    @MainActor static func perform(_ action: JobRowPresentation.Action, on row: JobRowPresentation, model: PanelModel) {
        switch action {
        case .log:
            let url = RMJHome().url.appendingPathComponent("logs/\(row.id).log")
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) } else { model.say("No archived log for \(row.id) yet.") }
        case .rerun:
            if row.detail.isGitHub {
                model.say("Rerunning \(row.title)...")
                Task {
                    let problem = await GitHubCommand.rerunJob(row.id)
                    model.say(problem ?? "Rerun requested for \(row.title).")
                }
            } else {
                // The ledger keeps the worktree's name, not its path: the command is copied for the checkout it came from.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("rmj run -- \(row.command)", forType: .string)
                model.say("Copied the command: run it in \(row.worktree ?? "the checkout") (its path is not recorded).")
            }
        }
    }

    @MainActor static func cancel(_ row: JobRowPresentation, model: PanelModel) {
        model.say("Cancelling \(row.id)...")
        Task { model.say(await RunCommand.cancelJob(row.id) ?? "Cancelled \(row.id).") }
    }

    @MainActor static func explain(_ row: JobRowPresentation, model: PanelModel) {
        model.explain = (row.title, row.command)
        model.select(.routing)
    }
}
