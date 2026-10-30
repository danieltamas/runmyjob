import RMJCore
import SwiftUI

/// The box's sensors as tiny icon-and-value chips (docs/DESIGN.md, Destinations). The icon says what the number is, so
/// the label stays out of the row; the colour is the chip's tone.
enum SensorIcon {
    static func symbol(_ id: String) -> String {
        switch id {
        case "cpu": "cpu"
        case "memory": "memorychip"
        case "load": "speedometer"
        case "disk": "internaldrive"
        case "down": "arrow.down"
        case "up": "arrow.up"
        case "uptime": "clock"
        case "swap": "arrow.triangle.swap"
        case "temp": "thermometer.medium"
        default: "fan"
        }
    }

    static func title(_ id: String) -> String {
        switch id {
        case "cpu": "CPU busy"
        case "memory": "Memory used"
        case "load": "Load"
        case "disk": "Disk used"
        case "down": "Download"
        case "up": "Upload"
        case "uptime": "Uptime"
        case "swap": "Swap used"
        case "temp": "Hottest sensor"
        default: "Fastest fan"
        }
    }
}

struct SensorGlyph: View {
    let chip: SensorChip
    /// The panel is on screen: a fan that turns while nobody looks would only cost battery.
    let visible: Bool
    @State private var turned = false

    private var spins: Bool { chip.spinning && visible }

    var body: some View {
        Image(systemName: SensorIcon.symbol(chip.id))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(chip.tone == .plain ? Theme.textTertiary : Theme.color(chip.tone))
            .rotationEffect(.degrees(turned ? 360 : 0))
            .onAppear { turn(spins) }
            .onChange(of: spins) { _, now in turn(now) }
            .frame(width: 13)
            .help([SensorIcon.title(chip.id), chip.detail].compactMap { $0 }.joined(separator: " "))
    }

    private func turn(_ on: Bool) {
        if on { withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { turned = true } }
        else { withAnimation(nil) { turned = false } }
    }
}

/// One compact row: icon, value. When the card is too narrow for every chip the network pair drops out first.
struct SensorRow: View {
    let chips: [SensorChip]
    let visible: Bool

    private static let compact: Set<String> = ["cpu", "memory", "load", "disk", "down", "up", "swap", "temp", "fan"]

    var body: some View {
        let row = chips.filter { Self.compact.contains($0.id) }
        ViewThatFits(in: .horizontal) {
            line(row)
            line(row.filter { $0.id != "down" && $0.id != "up" })
            line(row.filter { ["cpu", "memory", "load", "disk"].contains($0.id) })
        }
    }

    private func line(_ chips: [SensorChip]) -> some View {
        HStack(spacing: 10) {
            ForEach(chips, id: \.id) { chip in
                HStack(spacing: 3) {
                    SensorGlyph(chip: chip, visible: visible)
                    Text(chip.value).font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(chip.tone == .plain ? Theme.textPrimary : Theme.color(chip.tone))
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }
}

/// A smooth line over a zero baseline, so noise reads as noise: the chart scales from 0 to the larger of the data's
/// peak and `ceiling` (100 for a percentage), never from the data's own minimum.
struct Sparkline: Shape {
    let values: [Double]
    var ceiling: Double?
    var closed = false

    func path(in rect: CGRect) -> Path {
        guard values.count > 1, let peak = values.max() else { return Path() }
        let top = max(ceiling ?? 0, peak * 1.15, 0.0001)
        let points = values.enumerated().map { index, value in
            CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: rect.maxY - rect.height * CGFloat(min(max(value / top, 0), 1)))
        }
        return Path { path in
            path.move(to: points[0])
            // Catmull-Rom through the points, as cubic segments, so the line is smooth and never overshoots the data's turns.
            for index in 0..<points.count - 1 {
                let p0 = points[max(index - 1, 0)], p1 = points[index], p2 = points[index + 1], p3 = points[min(index + 2, points.count - 1)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(max(p1.y + (p2.y - p0.y) / 6, rect.minY), rect.maxY))
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(max(p2.y - (p3.y - p1.y) / 6, rect.minY), rect.maxY))
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
            if closed {
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}

/// The open card's version: the same chip with its name and, where there is history, a sparkline behind the trend.
struct SensorTile: View {
    let chip: SensorChip
    let visible: Bool

    /// A percentage is drawn against 100, everything else against its own peak.
    private var ceiling: Double? { chip.id == "cpu" || chip.id == "disk" ? 100 : nil }

    @ViewBuilder
    private func chart(_ color: Color) -> some View {
        let line = Sparkline(values: chip.series, ceiling: ceiling)
        ZStack {
            Sparkline(values: chip.series, ceiling: ceiling, closed: true)
                .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
            line.stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 16).padding(.top, 2)
        .opacity(chip.series.count > 2 ? 1 : 0)
    }

    var body: some View {
        let color = chip.tone == .plain ? Theme.teal : Theme.color(chip.tone)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                SensorGlyph(chip: chip, visible: visible)
                Text(SensorIcon.title(chip.id)).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(chip.value).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(chip.tone == .plain ? Theme.textPrimary : color)
                if let detail = chip.detail { Text(detail).font(.system(size: 10)).foregroundStyle(Theme.textTertiary) }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            chart(color)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hairline.opacity(0.35)))
    }
}
