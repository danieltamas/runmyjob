import RMJCore
import SwiftUI

/// Settings > Tenants: who the tenants are, which boxes form each group and in which order jobs try them, and how each is drawn.
struct TenantsPane: View {
    @ObservedObject var model: PanelModel
    @State private var rules: Rules?
    @State private var problem: String?
    /// The fingerprint of the file as this pane displays it: an edit made on top of a file changed since is refused.
    @State private var shown: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .tenants, title: "Tenants",
                       detail: "A tenant is a company or your own repos. Its boxes form a group: jobs try them in the order below. Colour and pattern mark its cards everywhere.")
            if let problem { ProblemText(text: problem) }
            if let rules {
                let summaries = TenantOverview.summaries(rules)
                if summaries.isEmpty {
                    ProblemText(text: "No tenant yet. Add a destination and name its tenant, or classify a repo from the Jobs list.")
                }
                ForEach(summaries, id: \.name) { summary in
                    TenantCard(summary: summary, raw: rules.tenants[summary.name]?.style ?? TenantStyle(), onChange: apply)
                }
            } else {
                ProblemText(text: "The rules file is invalid; fix it in Routing first.")
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        rules = try? PanelLoader().rules()
        shown = RuleEditing.fingerprint(home: RMJHome())
    }

    private func apply(_ change: TenantEditing.Change) {
        do {
            try TenantEditing.apply(change, home: RMJHome(), expected: shown)
            problem = nil
        } catch {
            problem = "\(error)"
        }
        load()
        model.reloadRules()
    }
}

private struct TenantCard: View {
    let summary: TenantOverview.Summary
    let raw: TenantStyle
    let onChange: (TenantEditing.Change) -> Void
    @State private var draft = TenantStyle()
    @State private var saving: Task<Void, Never>?

    private var resolved: TenantStyle.Resolved { draft.resolved(for: summary.name) }

    var body: some View {
        SettingsCard(title: summary.name, detail: describe) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) { styleControls }
                VStack(alignment: .leading, spacing: 10) {
                    preview
                    boxes
                }
                .frame(width: 210)
            }
        }
        .onAppear { draft = raw }
    }

    private var describe: String {
        var parts = [String]()
        if summary.shared { parts.append("your own repos, may use any box") }
        if !summary.owners.isEmpty { parts.append("owners: " + summary.owners.joined(separator: ", ")) }
        parts.append("\(summary.repos.count) repo\(summary.repos.count == 1 ? "" : "s")")
        parts.append(summary.isGroup ? "group of \(summary.destinations.count) boxes" : summary.destinations.isEmpty ? "no box" : "1 box")
        return parts.joined(separator: " - ")
    }

    private var preview: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(hex: resolved.color).opacity(0.14))
            .overlay { TenantPatternView(tenant: summary.name, style: resolved).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) }
            .overlay { Text(summary.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: resolved.color)) }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .frame(height: 64)
    }

    @ViewBuilder private var styleControls: some View {
        SettingsRow(title: "Colour") {
            ColorPicker("", selection: Binding(get: { Color(hex: resolved.color) }, set: { new in update { $0.color = new.hex } }), supportsOpacity: false)
                .labelsHidden()
        }
        SettingsRow(title: "Pattern") {
            HStack(spacing: 4) {
                ForEach(TenantStyle.patterns, id: \.self) { name in
                    SegmentChip(title: name.capitalized, selected: resolved.pattern == name) { update { $0.pattern = name } }
                }
            }
        }
        if resolved.pattern != "none" {
            slider("Width", value: resolved.width, range: TenantStyle.widthRange, unit: "px") { $0.width = $1 }
            slider("Size", value: resolved.size, range: TenantStyle.sizeRange, unit: "px") { $0.size = $1 }
            slider("Angle", value: resolved.angle, range: TenantStyle.angleRange, unit: "deg") { $0.angle = $1 }
            slider("Scatter", value: resolved.scatter, range: TenantStyle.scatterRange, unit: "") { $0.scatter = $1 }
        }
        if raw != TenantStyle() || draft != TenantStyle() {
            HStack {
                Spacer()
                ChipButton(title: "Use default") { saving?.cancel(); draft = TenantStyle(); onChange(.style(summary.name, nil)) }
            }
        }
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, unit: String, write: @escaping (inout TenantStyle, Double) -> Void) -> some View {
        SettingsRow(title: title) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { value }, set: { new in update { write(&$0, new) } }), in: range).frame(width: 150)
                Text(unit.isEmpty ? String(format: "%.2f", value) : "\(Int(value.rounded())) \(unit)")
                    .font(.meta).monospacedDigit().foregroundStyle(Theme.textTertiary).frame(width: 52, alignment: .trailing)
            }
        }
    }

    /// Applies one edit to the draft and saves it once the hand has been still for a moment.
    private func update(_ edit: (inout TenantStyle) -> Void) {
        var next = draft
        edit(&next)
        draft = next
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            onChange(.style(summary.name, next))
        }
    }

    private var boxes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.isGroup ? "Jobs try boxes in this order" : "Box").font(.meta).foregroundStyle(Theme.textTertiary)
            if summary.destinations.isEmpty { Text("none").font(.meta).foregroundStyle(Theme.textTertiary) }
            ForEach(Array(summary.destinations.enumerated()), id: \.element) { index, name in
                HStack(spacing: 6) {
                    Text("\(index + 1)").font(.meta).monospacedDigit().foregroundStyle(Theme.textTertiary).frame(width: 14)
                    Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    if summary.isGroup {
                        arrow("chevron.up", enabled: index > 0) { move(index, by: -1) }
                        arrow("chevron.down", enabled: index < summary.destinations.count - 1) { move(index, by: 1) }
                    }
                }
            }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.4)).frame(width: 20, height: 20)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .disabled(!enabled)
    }

    private func move(_ index: Int, by offset: Int) {
        var order = summary.destinations
        order.swapAt(index, index + offset)
        onChange(.order(summary.name, order))
    }
}

private extension Color {
    /// `#RRGGBB` of this colour in sRGB.
    var hex: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#808080" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
