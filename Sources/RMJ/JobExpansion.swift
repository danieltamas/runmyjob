import AppKit
import RMJCore
import SwiftUI

/// The rest of a row once opened: where the time went, when it happened, what rule applied and the actions.
struct JobExpansion: View {
    let row: JobRowPresentation
    let model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            phases
            properties
            buttons
        }
    }

    // MARK: phases

    @ViewBuilder
    private var phases: some View {
        let segments = row.detail.timeline
        let total = max(1, segments.reduce(0) { $0 + $1.seconds })
        if !segments.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { proxy in
                    let gaps = CGFloat(segments.count - 1) * 2
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.label) { segment in
                            Capsule().fill(color(segment.label)).frame(width: max(4, (proxy.size.width - gaps) * segment.seconds / total))
                        }
                    }
                }
                .frame(height: 6)
                HStack(spacing: 14) {
                    ForEach(segments, id: \.label) { segment in
                        HStack(spacing: 5) {
                            Circle().fill(color(segment.label)).frame(width: 6, height: 6)
                            Text(segment.label).foregroundStyle(Theme.textTertiary)
                            Text(PanelFormat.duration(segment.seconds)).foregroundStyle(Theme.textPrimary).monospacedDigit()
                                .help(row.detail.moments)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, weight: .medium))
            }
        }
    }

    private func color(_ label: String) -> Color {
        label == "queued" ? Theme.unknown : label == "sync" ? Theme.warn : Theme.running
    }

    // MARK: properties

    private var properties: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let rule = row.detail.rule { property("list.bullet.rectangle", "rule", rule) }
            if let reason = row.detail.reason, !row.meta.contains(where: { $0.text == "local: \(reason)" }) {
                property("arrow.uturn.down", "fallback", reason)
            }
            if let session = row.detail.session { property("person.crop.circle", "session", session, copy: true) }
            property("number", "job", row.id, copy: true)
        }
    }

    private func property(_ symbol: String, _ label: String, _ value: String, copy: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.textTertiary).frame(width: 14)
            Text(label).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle).help(copy ? "Click to copy" : value)
        }
        .font(.system(size: 11))
        .contentShape(Rectangle())
        .onTapGesture {
            guard copy else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            model.say("Copied \(label) \(value).")
        }
    }

    // MARK: actions

    private var buttons: some View {
        HStack(spacing: 8) {
            ChipButton(title: "Open log") { JobActions.perform(.log, on: row, model: model) }
            if row.detail.canCancel { ChipButton(title: "Cancel", destructive: true) { JobActions.cancel(row, model: model) } }
            if row.state.isSettledOrLost { ChipButton(title: "Rerun") { JobActions.perform(.rerun, on: row, model: model) } }
            if let url = row.detail.url { ChipButton(title: "Open on GitHub") { NSWorkspace.shared.open(url) } }
            if !row.detail.isGitHub { ChipButton(title: "Explain route") { JobActions.explain(row, model: model) } }
        }
    }
}
