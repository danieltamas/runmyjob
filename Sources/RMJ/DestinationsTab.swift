import RMJCore
import SwiftUI

struct DestinationsTab: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let cards = model.snapshot.cards
        if cards.isEmpty {
            EmptyState(symbol: "server.rack", title: "No destinations yet",
                       detail: "Add a box in Settings > Destinations. Until then every job runs on this Mac.")
        } else {
            VStack(spacing: 10) {
                ForEach(cards, id: \.name) { DestinationCard(card: $0, model: model) }
            }
        }
    }
}

/// One destination (docs/DESIGN.md, Destinations): two lines closed, so twenty boxes stay a scannable list; the
/// capacity detail, runners, images and actions open on a tap. The accent is the tenant's.
struct DestinationCard: View {
    let card: DestinationCardPresentation
    @ObservedObject var model: PanelModel
    @State private var showAllImages = false

    private var key: String { "dest:" + card.name }
    private var open: Bool { model.expanded.contains(key) }

    var body: some View {
        HoverCard(accent: Theme.tenant(card.tenant), action: { withAnimation(Motion.spring) { model.toggle(key) } }) {
            VStack(alignment: .leading, spacing: 0) {
                header
                summary.padding(.top, 7)
                // The small chips give way to the tiles: they fold away as the card opens and come back as it closes.
                if !card.sensors.isEmpty {
                    Collapsible(open: !open, lazy: false) {
                        SensorRow(chips: card.sensors, visible: model.panelVisible && !open).padding(.top, 5)
                            .opacity(open ? 0 : 1).animation(Motion.snappy, value: open)
                    }
                }
                Collapsible(open: open, lazy: false) { details.padding(.top, 7) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(card.name).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            Chip(text: card.tenant, color: Theme.tenant(card.tenant), style: .outline)
            Spacer(minLength: 4)
            Chip(text: card.state.text, color: Theme.color(card.state.tone), style: card.state.tone == .ok ? .tinted : .outline)
                .lineLimit(1)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
        }
    }

    private func value(_ label: String) -> DestinationCardPresentation.Line? { card.capacity.first { $0.label == label } }

    /// The few numbers that decide where a job goes: slots, memory, load, and the runners' health.
    private var summary: some View {
        HStack(spacing: 12) {
            if let slots = value("rx slots") { stat("rx", slots.value, tone: slots.tone) }
            if let memory = value("memory budget") { stat("mem", memory.value.replacingOccurrences(of: " of ", with: "/"), tone: memory.tone) }
            if !card.missingTools.isEmpty { stat("missing", card.missingTools.flatMap(\.programs).joined(separator: ", "), tone: .warn) }
            if !card.runners.isEmpty {
                let healthy = card.runners.filter { $0.tone == .ok }.count
                stat("runners", "\(healthy)/\(card.runners.count)", tone: healthy == card.runners.count ? .plain : .warn)
            }
            Spacer(minLength: 0)
            if let stale = card.capacity.first?.stale { Chip(text: stale, color: Theme.unknown, style: .dashed) }
        }
        .font(.meta).lineLimit(1)
    }

    private func stat(_ label: String, _ text: String, tone: JobRowPresentation.Tone) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.textTertiary)
            Text(text).foregroundStyle(tone == .plain ? Theme.textPrimary : Theme.color(tone)).monospacedDigit()
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            if !card.sensors.isEmpty {
                section(card.systemKind.map { "Sensors, \($0)" } ?? "Sensors") { sensorTiles.opacity(open ? 1 : 0).animation(Motion.gentle.delay(open ? 0.08 : 0), value: open) }
            }
            if !card.capacity.isEmpty {
                section("Capacity") { ForEach(card.capacity.filter { !["load", "free memory"].contains($0.label) || card.sensors.isEmpty }, id: \.label) { line($0) } }
            }
            if !card.rxContainers.isEmpty {
                section("rx jobs") { ForEach(card.rxContainers, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary) } }
            }
            if !card.runners.isEmpty {
                section("Runners") { ForEach(card.runners, id: \.name) { runner($0) } }
            }
            if !card.images.isEmpty || card.otherImages > 0 { section("Images (\(card.images.count))") { images } }
            footer
        }
    }

    /// Pressure only matters when the box is stalling, so it says nothing while it is low.
    private var stalling: String? {
        let high = card.sensorDetails.filter { $0.label.hasSuffix("pressure") && (Double($0.value.dropLast()) ?? 0) >= 5 }
        return high.isEmpty ? nil : "stalling: " + high.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
    }

    private var sensorTiles: some View {
        VStack(alignment: .leading, spacing: 5) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(card.sensors, id: \.id) { SensorTile(chip: $0, visible: model.panelVisible) }
            }
            if let pressure = stalling { Text(pressure).font(.meta).foregroundStyle(Theme.warn) }
        }
    }

    @ViewBuilder
    private var images: some View {
        let shown = showAllImages ? card.images : Array(card.images.prefix(4))
        ForEach(shown, id: \.label) { image in
            VStack(alignment: .leading, spacing: 1) {
                Text(image.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                if let summary = BuildEnvironments.catalog.first(where: { $0.image == image.label })?.summary {
                    Text(summary).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                if let gap = card.missingTools.first(where: { $0.image == image.label }) {
                    Text("missing in the image: \(gap.programs.joined(separator: ", ")). Add to its Dockerfile, then Set up again.")
                        .font(.meta).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if card.otherImages > 0 {
            Text("plus \(card.otherImages) other image\(card.otherImages == 1 ? "" : "s") on this box").font(.meta).foregroundStyle(Theme.textTertiary)
        }
        if card.images.count > 4 {
            LinkButton(title: showAllImages ? "Show fewer" : "Show \(card.images.count - 4) more") { withAnimation(Motion.spring) { showAllImages.toggle() } }
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(text: title)
            content()
        }
    }

    private func line(_ line: DestinationCardPresentation.Line) -> some View {
        HStack(spacing: 6) {
            Text(line.label).foregroundStyle(Theme.textTertiary)
            Text(line.value).foregroundStyle(Theme.color(line.tone)).monospacedDigit()
        }
        .font(.meta).lineLimit(1)
    }

    private func runner(_ runner: DestinationCardPresentation.RunnerLine) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.color(runner.tone)).frame(width: 6, height: 6)
            Text(runner.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Text(runner.detail).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.lastProbe).font(.meta).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 8) {
                ForEach(card.actions, id: \.action) { state in
                    if state.available {
                        ChipButton(title: state.action.rawValue) { DestinationActions.perform(state.action, on: card, model: model) }
                    } else if let reason = state.reason {
                        Text("\(state.action.rawValue): \(reason)").font(.meta).foregroundStyle(Theme.unknown).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
