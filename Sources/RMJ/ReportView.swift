import AppKit
import RMJCore
import SwiftUI

/// The run report: telemetry on the left, the log on the right, colored by what each line says.
struct ReportView: View {
    @ObservedObject var model: ReportModel
    @ObservedObject private var appearance = Appearance.shared
    @State private var query = ""
    @State private var filter = LogFilter.all
    @State private var follow = true

    enum LogFilter: String, CaseIterable { case all = "All", errors = "Errors", warnings = "Warnings" }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 0.5)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                logPane
            }
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .background(Backdrop())
        .preferredColorScheme(Theme.scheme)
        .id(appearance.look)
    }

    // MARK: sidebar

    private static let hoisted: Set<String> = ["Status", "Exit code", "Queue wait", "Run", "Elapsed", "Avg CPU", "Avg memory"]

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let report = model.report {
                    hero(report)
                    runTime(report)
                    tiles(report)
                    ForEach(report.sections.filter { $0.title != "Result" && $0.title != "Resources" }, id: \.title) { section in
                        card(section.title, trailing: section.title == "Timing" ? date(report) : nil) {
                            ForEach(section.facts.filter { !Self.hoisted.contains($0.label) }, id: \.label) { fact in
                                factRow(fact.label, shown(fact), fact.tone)
                            }
                        }
                    }
                } else if model.loaded {
                    Text("This run is not in the ledger.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                if let log = model.log { logTiles(log) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(width: 300)
        .background(Theme.canvas.opacity(0.55))
    }

    private func hero(_ report: RunReport) -> some View {
        let tone = Theme.color(report.stateTone)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: Self.symbol(report.stateText))
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(tone)
                .frame(width: 44, height: 44)
                .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(tone.opacity(0.28), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(report.stateText.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(tone)
                Text(report.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private static func symbol(_ state: String) -> String {
        switch state {
        case "done": "checkmark"
        case "failed", "lost": "xmark"
        case "cancelled": "slash.circle"
        case "running", "syncing": "bolt.fill"
        default: "clock"
        }
    }

    /// The run's length large, and where the time went under it.
    @ViewBuilder private func runTime(_ report: RunReport) -> some View {
        if let seconds = report.runSeconds {
            card(nil) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(PanelFormat.duration(seconds)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                        Text(report.stateTone == .running ? "running" : "run time").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    }
                    if !report.phases.isEmpty { phaseBar(report.phases) }
                }
            }
        }
    }

    private func phaseBar(_ phases: [JobRowPresentation.Detail.Segment]) -> some View {
        let total = max(1, phases.reduce(0) { $0 + $1.seconds })
        return VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                let gaps = CGFloat(phases.count - 1) * 2
                HStack(spacing: 2) {
                    ForEach(phases, id: \.label) { phase in
                        Capsule().fill(phaseColor(phase.label)).frame(width: max(4, (proxy.size.width - gaps) * phase.seconds / total))
                    }
                }
            }
            .frame(height: 6)
            HStack(spacing: 12) {
                ForEach(phases, id: \.label) { phase in
                    HStack(spacing: 4) {
                        Circle().fill(phaseColor(phase.label)).frame(width: 5, height: 5)
                        Text(phase.label).foregroundStyle(Theme.textTertiary)
                        Text(PanelFormat.duration(phase.seconds)).foregroundStyle(Theme.textPrimary).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5, weight: .medium))
        }
    }

    private func phaseColor(_ label: String) -> Color {
        label == "queued" ? Theme.unknown : label == "sync" ? Theme.warn : Theme.running
    }

    /// The numbers worth a glance: queue wait, exit code and what the run cost.
    @ViewBuilder private func tiles(_ report: RunReport) -> some View {
        let all = report.sections.flatMap(\.facts)
        let picks: [(String, String, String)] = [("Queue wait", "hourglass", "Queue wait"), ("Exit code", "terminal", "Exit code"),
                                                  ("Avg CPU", "cpu", "Avg CPU"), ("Avg memory", "memorychip", "Memory")]
        let present = picks.compactMap { label, symbol, title in all.first { $0.label == label }.map { ($0, symbol, title) } }
        if !present.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(present, id: \.0.label) { fact, symbol, title in tile(symbol, title, fact.value, fact.tone) }
            }
        }
    }

    private func tile(_ symbol: String, _ title: String, _ value: String, _ tone: JobRowPresentation.Tone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
            }
            .foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(tone == .plain ? Theme.textPrimary : Theme.color(tone))
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private func logTiles(_ log: LogDocument) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            tile("text.alignleft", "Lines", log.truncated ? "last \(log.lines.count)" : "\(log.lines.count)", .plain)
            tile("doc", log.isLive ? "Size (live)" : "Size", ByteCountFormatter.string(fromByteCount: log.byteCount, countStyle: .file), log.isLive ? .running : .plain)
            tile("exclamationmark.octagon", "Errors", "\(log.errorCount)", log.errorCount > 0 ? .crit : .plain)
            tile("exclamationmark.triangle", "Warnings", "\(log.warningCount)", log.warningCount > 0 ? .warn : .plain)
        }
    }

    private func card<Content: View>(_ title: String?, trailing: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                HStack {
                    Eyebrow(text: title)
                    Spacer(minLength: 6)
                    if let trailing { Text(trailing).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary) }
                }
            }
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.core, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private static let icons = ["Location": "server.rack", "Environment": "cpu", "Rule": "list.bullet.rectangle", "Fallback": "arrow.uturn.down",
                                "Tenant": "building.2", "Repo": "shippingbox", "Worktree": "folder", "Branch": "arrow.triangle.branch",
                                "Commit": "number", "Agent": "person.crop.circle", "Session": "key", "Queued": "tray.and.arrow.down",
                                "Started": "play", "Ended": "stop", "Sync": "arrow.triangle.2.circlepath", "Box run": "timer",
                                "Box start": "play", "Box end": "stop", "Clock offset": "clock.arrow.2.circlepath"]

    private func factRow(_ label: String, _ value: String, _ tone: JobRowPresentation.Tone) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.icons[label] ?? "circle.fill").font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary).frame(width: 14)
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            pill(label, value, tone)
        }
    }

    /// Every value is a small badge: one shape for a branch, a commit, a tenant or a time, tinted by what it means.
    private func pill(_ label: String, _ value: String, _ tone: JobRowPresentation.Tone) -> some View {
        let tint = tone == .plain ? Theme.textPrimary : Theme.color(tone)
        return HStack(spacing: 5) {
            if label == "Tenant" { Circle().fill(Theme.tenant(value)).frame(width: 6, height: 6) }
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(tint).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tone == .plain ? Theme.wash.opacity(0.07) : tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tone == .plain ? Theme.hairline : tint.opacity(0.25), lineWidth: 0.5))
        .textSelection(.enabled)
    }

    /// A timestamp shows its time; the date goes once in the card's header. A commit shows its short form.
    private func shown(_ fact: RunReport.Fact) -> String {
        if fact.value.count == 19, fact.value.dropFirst(10).first == " " { return String(fact.value.suffix(8)) }
        if fact.label == "Commit" { return fact.value.count > 18 ? String(fact.value.prefix(10)) + (fact.value.hasSuffix("(dirty)") ? " (dirty)" : "") : fact.value }
        return fact.value
    }

    private func date(_ report: RunReport) -> String? {
        report.sections.flatMap(\.facts).first { $0.value.count == 19 && $0.value.dropFirst(10).first == " " }.map { String($0.value.prefix(10)) }
    }

    // MARK: header and log

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.report?.command ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                .lineLimit(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                GlassField(placeholder: "Search the log", text: $query).frame(maxWidth: 260)
                ForEach(LogFilter.allCases, id: \.self) { option in
                    Button { withAnimation(Motion.snappy) { filter = option } } label: {
                        Text(option.rawValue).font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(filter == option ? Theme.textPrimary : Theme.textTertiary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(filter == option ? Theme.core : .clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: filter == option ? 0.5 : 0))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle(scale: 0.97, hit: AnyShape(Capsule()), lift: 0.08))
                }
                Spacer(minLength: 8)
                if model.log?.isLive == true {
                    ChipButton(title: follow ? "Following" : "Follow") { follow.toggle() }
                }
                ChipButton(title: "Copy log") { copy() }
                ChipButton(title: "Reveal") { reveal() }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var visible: [LogLine] {
        guard let log = model.log else { return [] }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return log.lines.filter { line in
            switch filter {
            case .all: true
            case .errors: line.kind == .error
            case .warnings: line.kind == .warning
            }
        }.filter { needle.isEmpty || $0.text.lowercased().contains(needle) }
    }

    @ViewBuilder private var logPane: some View {
        if let log = model.log {
            ReportLogView(lines: visible, query: query, structure: "\(filter.rawValue)|\(query)", revision: log.byteCount,
                          follow: follow && log.isLive, truncated: log.truncated,
                          landOn: log.isLive ? nil : log.lines.first { $0.kind == .error }?.number)
        } else if model.loaded {
            VStack(spacing: 6) {
                Text("No log on this Mac").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text("Logs of box and GitHub jobs are fetched when the job settles; this run has none yet.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    // MARK: actions

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visible.map(\.text).joined(separator: "\n"), forType: .string)
    }

    private func reveal() {
        let home = RMJHome()
        guard let url = LogTail.candidates(jobID: model.jobID, home: home).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
