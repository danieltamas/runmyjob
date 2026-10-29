import RMJCore
import SwiftUI

/// Optional streaming of every run's output to Loki, Datadog or Elasticsearch (docs/LOG-STREAMING.md).
struct LogStreamPane: View {
    @StateObject private var model: LogStreamModel
    @State private var editing: SinkSheetItem?
    @State private var removing: String?

    init(model: @autoclosure @escaping () -> LogStreamModel = LogStreamModel()) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .logs, title: "Log streaming",
                       detail: "Optional. Send each run's output, as it happens, to a log ingestor. Nothing leaves this Mac until you add a sink.")
            if model.rows.isEmpty {
                SettingsCard(title: "No sinks", detail: "A sink names the tenants it may receive: output of any other tenant never reaches it.") { addMenu }
            } else {
                ForEach(model.rows) { card($0) }
                HStack { addMenu; Spacer() }
            }
            ForEach(model.problems, id: \.self) { ProblemText(text: $0) }
        }
        .task { await model.loop() }
        .sheet(item: $editing) { item in
            LogSinkSheet(kind: item.kind, existing: item.sink) { editing = nil; model.reload() }
        }
    }

    private var addMenu: some View {
        HStack(spacing: 8) {
            ForEach([LogSinkConfig.Kind.loki, .datadog, .elasticsearch], id: \.self) { kind in
                ActionButton(title: "Add \(Self.title(kind))", symbol: "plus") { editing = SinkSheetItem(kind: kind, sink: nil) }
            }
        }
    }

    static func title(_ kind: LogSinkConfig.Kind) -> String {
        switch kind {
        case .loki: "Loki"
        case .datadog: "Datadog"
        case .elasticsearch: "Elasticsearch"
        }
    }

    private func card(_ row: LogStreamModel.Row) -> some View {
        let sink = row.sink
        let busy = model.busy.contains(sink.id)
        return SettingsCard(title: sink.name, detail: scope(sink)) {
            HStack(spacing: 8) {
                Chip(text: Self.title(sink.kind), color: Theme.neutral, style: .outline)
                let state = Self.state(row)
                Chip(text: state.text, color: state.color)
                Spacer(minLength: 0)
            }
            Text(counts(row)).font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let error = row.status.lastError, let at = row.status.lastErrorAt, at > (row.status.lastOK ?? .distantPast) {
                Text("Last error: \(error)").font(.meta).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            if let said = model.results[sink.id] { Text(said).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
            RowDivider()
            SwitchRow(title: "Stream to this sink", detail: sink.enabled ? nil : "Paused: what waits is kept and sent when you switch it on.",
                      isOn: Binding(get: { sink.enabled }, set: { model.setEnabled(sink, $0) }))
            HStack(spacing: 8) {
                ActionButton(title: "Send test line", disabled: busy) { model.sendTest(sink) }
                ActionButton(title: "Drain now", disabled: busy || !sink.enabled || row.pending.files == 0) { model.drainNow(sink) }
                ActionButton(title: "Discard waiting", disabled: row.pending.files == 0) { model.discard(sink) }
                Spacer(minLength: 0)
                ActionButton(title: "Edit") { editing = SinkSheetItem(kind: sink.kind, sink: sink) }
                if removing == sink.id {
                    ActionButton(title: "Delete spool and secret", style: .destructive) { removing = nil; model.remove(sink) }
                } else {
                    ActionButton(title: "Remove") { removing = sink.id }
                }
            }
        }
    }

    private func scope(_ sink: LogSinkConfig) -> String {
        let who = sink.all ? "All tenants" : "Tenants: " + sink.tenants.joined(separator: ", ")
        switch sink.kind {
        case .datadog: return who + " - " + (sink.site ?? "datadoghq.com")
        default: return who + " - " + (sink.url ?? "")
        }
    }

    private static func state(_ row: LogStreamModel.Row) -> (text: String, color: Color) {
        if !row.sink.enabled { return (row.pending.files > 0 ? "Paused, \(row.pending.lines) waiting" : "Paused", Theme.neutral) }
        if row.status.authFailed { return ("Credentials rejected", Theme.danger) }
        switch LogStreamIndicator.state(sinks: [row.sink], status: [row.status], now: Date()) {
        case .failing: return ("Failing", Theme.warn)
        default: return ("Streaming", Theme.teal)
        }
    }

    private func counts(_ row: LogStreamModel.Row) -> String {
        var parts = ["\(row.status.sent) sent"]
        if row.pending.files > 0 {
            let age = row.pending.oldest.map { " (oldest \(PanelFormat.duration(Date().timeIntervalSince($0))))" } ?? ""
            parts.append("\(row.pending.lines) waiting\(age)")
        }
        if row.status.rejected > 0 { parts.append("\(row.status.rejected) rejected") }
        if row.status.dropped > 0 { parts.append("\(row.status.dropped) dropped") }
        return parts.joined(separator: " - ")
    }
}

struct SinkSheetItem: Identifiable {
    let kind: LogSinkConfig.Kind
    let sink: LogSinkConfig?
    var id: String { sink?.id ?? "new-\(kind.rawValue)" }
}
