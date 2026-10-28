import AppKit
import RMJCore
import SwiftUI

/// The rest of a row once opened: where the time went, when it happened, what rule applied and the actions.
struct JobExpansion: View {
    let row: JobRowPresentation
    @ObservedObject var model: PanelModel

    /// `queued 2026-10-25 15:58:20 (mac)` split into its parts; anything else (`clock offset 12 ms`) stays a plain note.
    private struct Stamp {
        let label: String, date: String, time: String, clock: String
        static func parse(_ text: String) -> Stamp? {
            guard let match = text.firstMatch(of: /^(.+?) (\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) \((\w+)\)$/) else { return nil }
            return Stamp(label: String(match.1), date: String(match.2), time: String(match.3), clock: String(match.4))
        }
    }

    var body: some View {
        let stamps = row.detail.timestamps.compactMap(Stamp.parse)
        let notes = row.detail.timestamps.filter { Stamp.parse($0) == nil }
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            phases
            tiles(stamps.filter { ["queued", "started", "ended"].contains($0.label) })
            boxLine(stamps.filter { $0.label.hasPrefix("box") }, notes)
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

    // MARK: moments

    @ViewBuilder
    private func tiles(_ stamps: [Stamp]) -> some View {
        if !stamps.isEmpty {
            HStack(spacing: 6) {
                ForEach(stamps, id: \.label) { stamp in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stamp.label.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.textTertiary)
                        Text(stamp.time).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                        Text(stamp.date).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.canvas.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                }
            }
        }
    }

    /// The box's own clock, when it ran there: its start and end beside the clock offset.
    @ViewBuilder
    private func boxLine(_ box: [Stamp], _ notes: [String]) -> some View {
        if !box.isEmpty || !notes.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "server.rack").font(.system(size: 10))
                if let start = box.first(where: { $0.label == "box start" }), let end = box.first(where: { $0.label == "box end" }) {
                    Text("\(start.time)").monospacedDigit()
                    Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold))
                    Text("\(end.time)").monospacedDigit()
                }
                ForEach(notes, id: \.self) { Text($0) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
        }
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
