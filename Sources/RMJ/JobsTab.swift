import RMJCore
import SwiftUI

struct JobsTab: View {
    @ObservedObject var model: PanelModel
    @State private var shown = RowPaging.pageSize
    @State private var filter = JobRowFilter()

    var body: some View {
        let all = model.snapshot.allRows
        if all.isEmpty {
            EmptyState(symbol: "bolt.horizontal", title: "No jobs yet",
                       detail: "Agents' cargo test and just check land here once the hook is installed (Settings > Hooks).")
        } else {
            let sections = filter.apply(all)
            VStack(alignment: .leading, spacing: 8) {
                filterBar
                if sections.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "Nothing matches", detail: "No job of the last thirty days fits this search.")
                }
                ForEach(RowPaging.page(sections, limit: shown), id: \.0) { section, rows in
                    Eyebrow(text: "\(section.rawValue) - \(sections.first { $0.0 == section }?.1.count ?? rows.count)").padding(.top, 6).padding(.leading, 4)
                    ForEach(rows, id: \.id) { row in
                        JobRowHost(row: row, model: model)
                    }
                }
                let settled = RowPaging.total(sections)
                if settled > shown {
                    ActionButton(title: "Show \(min(RowPaging.pageSize, settled - shown)) more of \(settled - shown)", style: .secondary) {
                        shown += RowPaging.pageSize
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: filter) { _, _ in shown = RowPaging.pageSize }
        }
    }

    /// Search over the thirty days, and one outcome or origin at a time.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassField(placeholder: "Search repo, command, branch, box", text: $filter.query)
            HStack(spacing: 6) {
                ForEach(JobRowFilter.Kind.allCases, id: \.self) { kind in
                    let on = filter.kind == kind
                    Button { filter.kind = kind } label: {
                        Chip(text: kind.rawValue, color: on ? Theme.teal : Theme.textSecondary, style: on ? .tinted : .outline)
                    }
                    .buttonStyle(.plain)
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

/// Holds the open state of one row, so opening it redraws that row alone, not the list.
struct JobRowHost: View {
    let row: JobRowPresentation
    let model: PanelModel
    @State private var expanded: Bool

    init(row: JobRowPresentation, model: PanelModel) {
        self.row = row
        self.model = model
        _expanded = State(initialValue: model.openJobs.contains(row.id))
    }

    var body: some View {
        JobRowView(row: row, expanded: expanded, model: model) {
            withAnimation(Motion.snappy) { expanded.toggle() }
            if expanded { model.openJobs.insert(row.id) } else { model.openJobs.remove(row.id) }
        }
    }
}

/// One job: who and where, what ran, how it went (docs/DESIGN.md, Jobs). Log and Rerun sit in the row of a failed job.
struct JobRowView: View {
    let row: JobRowPresentation
    let expanded: Bool
    let model: PanelModel
    let toggle: () -> Void

    var body: some View {
        HoverCard(accent: Theme.color(row.stateChip.tone), action: toggle) {
            VStack(alignment: .leading, spacing: 8) {
                titleLine
                contextLine
                commandWell
                footer
                if !row.actions.isEmpty, !expanded { actions }
                Collapsible(open: expanded) { JobExpansion(row: row, model: model).padding(.top, 2) }
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
            Chip(text: row.stateChip.text, color: Theme.color(row.stateChip.tone), style: row.state == .running ? .filled : .tinted)
        }
    }

    /// Branch, checkout, commit and who started it, each with its glyph.
    private var contextLine: some View {
        HStack(spacing: 10) {
            if let branch = row.branch { glyph("arrow.triangle.branch", branch) }
            if let worktree = row.worktree { glyph("folder", worktree) }
            if let commit = row.commit {
                Text(commit).font(.system(size: 10.5, design: .monospaced)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.wash.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if row.dirty { Circle().fill(Theme.warn).frame(width: 5, height: 5).help("uncommitted changes") }
            Spacer(minLength: 0)
            if row.agent != .github {
                HStack(spacing: 3) {
                    Image(systemName: row.agent.symbol).font(.system(size: 10))
                    Text(row.agent.title).lineLimit(1)
                }
            }
        }
        .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
    }

    private func glyph(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9.5))
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .layoutPriority(-1)
    }

    /// The command in a recessed well, as it was typed.
    private var commandWell: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("$").foregroundStyle(Theme.teal.opacity(0.8))
            Text(row.command).foregroundStyle(Theme.textSecondary)
                .lineLimit(expanded ? 6 : 1).truncationMode(.middle).help(row.command)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// How it is going or how it went; a run on this Mac adds its processor and memory.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            metaLine
            if let load = row.load { LoadGauges(load: load) }
        }
    }

    private var metaLine: some View {
        row.meta.enumerated().reduce(Text("")) { text, item in
            let part = Text(item.element.text).foregroundStyle(Theme.color(item.element.tone))
            return item.offset == 0 ? part : Text("\(text)\(Text("  \u{00B7}  ").foregroundStyle(Theme.textTertiary))\(part)")
        }
        .font(.system(size: 11, design: .default).monospacedDigit())
        .lineLimit(expanded || row.state == .queued ? nil : 2).truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .help(row.detail.moments)
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
            if let archived = LogTail.archived(jobID: row.id, home: RMJHome()) { NSWorkspace.shared.open(archived) } else if row.detail.isGitHub {
                model.say("Fetching the log of \(row.title) from GitHub...")
                Task {
                    let problem = await GitHubCommand.fetchLog(row.id)
                    if let problem { model.say(problem) } else { NSWorkspace.shared.open(url); model.say("Opened the log of \(row.title).") }
                }
            } else { model.say("No archived log for \(row.id) yet.") }
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

/// Processor (percent of one core) and resident memory of a running job on this Mac, each with a thin bar.
private struct LoadGauges: View {
    let load: JobLoad
    private static let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    private static let memory = Double(ProcessInfo.processInfo.physicalMemory)

    var body: some View {
        HStack(spacing: 14) {
            gauge("CPU", "\(Int(load.cpuPercent.rounded()))%", fraction: load.cpuPercent / (100 * Self.cores))
            gauge("MEM", ByteCountFormatter.string(fromByteCount: load.memoryBytes, countStyle: .memory), fraction: Double(load.memoryBytes) / Self.memory)
        }
    }

    private func gauge(_ label: String, _ value: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(label).foregroundStyle(Theme.textTertiary)
                Text(value).foregroundStyle(Theme.textPrimary).monospacedDigit()
            }
            .font(.system(size: 10.5, weight: .medium))
            Capsule().fill(Theme.wash.opacity(0.10)).frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(Theme.running).frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
