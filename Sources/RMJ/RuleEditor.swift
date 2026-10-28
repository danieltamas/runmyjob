import RMJCore
import SwiftUI

/// The opened rule: every field of the rule in place, Save / Delete / Move, errors from the validator shown as they are.
struct RuleEditorCard: View {
    let index: Int?
    let count: Int
    let home: RMJHome
    /// Repos RMJ has seen, offered in the picker.
    let repos: [String]
    let close: () -> Void
    let changed: () -> Void
    @State private var draft = RuleDraft()
    @State private var base: Rule?
    @State private var error: String?
    @State private var loaded = false
    @State private var opened: String?

    @State private var destinations: [String] = []
    @State private var more = false

    /// In the same bezel as the rule rows, so opening a rule does not change the width of its card.
    var body: some View {
        Bezel(glow: Theme.teal) { form }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(index == nil ? "New rule" : "Edit rule \((index ?? 0) + 1)").font(.rowTitle).foregroundStyle(Theme.textPrimary)
            Text("Pick what to run and where. If the box cannot take it, the job runs on this Mac.")
                .font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            Eyebrow(text: "What")
            FlowLayout(spacing: 6) {
                ForEach(RulePreset.allCases, id: \.self) { preset in
                    ChoiceChip(title: preset.title, selected: RulePreset.matching(command: draft.command) == preset) { draft.apply(preset) }
                }
                if RulePreset.matching(command: draft.command) == nil { ChoiceChip(title: "Custom", selected: true) { more = true } }
            }
            Eyebrow(text: "Where")
            FlowLayout(spacing: 6) {
                ForEach(destinations, id: \.self) { name in
                    ChoiceChip(title: name, selected: chosen.contains(name)) { toggle(name) }
                }
                ChoiceChip(title: "This Mac", selected: chosen.contains("local")) { toggle("local") }
            }
            RepoPicker(selection: $draft.repo, known: repos)
            Button { withAnimation(Motion.snappy) { more.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(more ? 90 : 0))
                    Text("More").font(.system(size: 12, weight: .medium))
                }.foregroundStyle(Theme.textSecondary)
            }.buttonStyle(PressStyle(scale: 0.98))
            if more {
                FieldBlock(title: "Name") { GlassField(placeholder: draft.suggestedName, text: $draft.name) }
                FieldBlock(title: "Command", detail: "Comma separated; the preset above fills it.") { GlassField(placeholder: "any, e.g. cargo", text: $draft.command, monospaced: true) }
                HStack(alignment: .top, spacing: 8) {
                    FieldBlock(title: "Owner") { GlassField(placeholder: "any", text: $draft.owner, monospaced: true) }
                    FieldBlock(title: "Tenant") { GlassField(placeholder: "any", text: $draft.tenant, monospaced: true) }
                }
                HStack(alignment: .top, spacing: 8) {
                    FieldBlock(title: "Image") { GlassField(placeholder: "default", text: $draft.image, monospaced: true) }
                    FieldBlock(title: "Profile") { GlassField(placeholder: "none", text: $draft.profile, monospaced: true) }
                }
            }
            if let error { StatusLine(text: error, tone: .failed) }
            HStack(spacing: 8) {
                if let index {
                    ActionButton(title: "Delete", style: .destructive) { apply(.delete(index)) }
                    // Icon-only: five labelled buttons are wider than the panel, and the panel grows to fit them.
                    ActionButton(title: "", symbol: "arrow.up", style: .secondary) { apply(.move(index, by: -1)) }.disabled(index == 0).help("Move up")
                    ActionButton(title: "", symbol: "arrow.down", style: .secondary) { apply(.move(index, by: 1)) }.disabled(index >= count - 1).help("Move down")
                }
                Spacer(minLength: 0)
                ActionButton(title: "Cancel", style: .secondary, action: close)
                ActionButton(title: "Save", style: .primary, action: save)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: load)
    }

    private var chosen: [String] { draft.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    private func toggle(_ name: String) {
        var list = chosen
        if let at = list.firstIndex(of: name) { list.remove(at: at) } else { list.append(name) }
        // The Mac is the fallback: it stays last.
        if let at = list.firstIndex(of: "local") { list.append(list.remove(at: at)) }
        draft.to = list.joined(separator: ", ")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        opened = RuleEditing.fingerprint(home: home)
        if case .valid(let rules, _) = RulesStore(home: home).load() { destinations = rules.destinations.filter(\.value.enabled).keys.sorted() }
        guard let index, case .valid(let rules, _) = RulesStore(home: home).load(), rules.rules.indices.contains(index) else { return }
        base = rules.rules[index]
        draft = RuleDraft(rules.rules[index])
    }

    private func save() {
        do {
            var named = draft
            if named.name.trimmingCharacters(in: .whitespaces).isEmpty { named.name = named.suggestedName }
            if named.to.trimmingCharacters(in: .whitespaces).isEmpty { named.to = "local" }
            let rule = try named.rule(base: base)
            apply(index.map { .replace($0, rule) } ?? .append(rule))
        } catch { self.error = "\(error)" }
    }

    private func apply(_ change: RuleEditing.Change) {
        do {
            try RuleEditing.apply(change, home: home, expected: opened)
            error = nil
            changed()
            close()
        } catch { self.error = "\(error)" }
    }
}

/// The repos a rule is limited to: the chosen ones as removable chips, a menu of the repos RMJ knows, and a field for one
/// that is not listed or for a pattern like app-*. Nothing chosen means every repo.
private struct RepoPicker: View {
    @Binding var selection: String
    let known: [String]
    @State private var typed = ""

    private var chosen: [String] { selection.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Only these repos")
            FlowLayout(spacing: 6) {
                if chosen.isEmpty { Chip(text: "All repos", color: Theme.textSecondary, style: .outline) }
                ForEach(chosen, id: \.self) { repo in
                    Button { withAnimation(Motion.snappy) { set(chosen.filter { $0 != repo }) } } label: {
                        HStack(spacing: 5) {
                            Text(repo).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .padding(.horizontal, 10).frame(height: 26)
                        .foregroundStyle(Theme.textPrimary)
                        .background(Capsule().fill(Theme.brand.opacity(0.18)))
                        .overlay(Capsule().strokeBorder(Theme.brand.opacity(0.5), lineWidth: 0.5))
                    }
                    .buttonStyle(PressStyle(scale: 0.97))
                    .help("Remove \(repo)")
                }
                menu
            }
            GlassField(placeholder: "owner/name or a pattern like app-*", text: $typed, monospaced: true)
                .onSubmit(addTyped)
            Text("Only builds from these repos go through this rule. Leave it empty for every repo.")
                .font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var menu: some View {
        let options = known.filter { !chosen.contains($0) }
        return Menu {
            ForEach(options, id: \.self) { repo in Button(repo) { withAnimation(Motion.snappy) { set(chosen + [repo]) } } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("Add repo").font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11).frame(height: 26)
            .foregroundStyle(Theme.textPrimary)
            .background(Capsule().fill(Theme.wash.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(options.isEmpty)
        .help(options.isEmpty ? "No other repos seen yet: type one below" : "Choose a repo RMJ has seen")
    }

    private func addTyped() {
        let value = typed.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        if !chosen.contains(value) { withAnimation(Motion.snappy) { set(chosen + [value]) } }
        typed = ""
    }

    private func set(_ list: [String]) { selection = list.joined(separator: ", ") }
}

/// A pick-one or pick-several option: filled when chosen, a hairline capsule when not.
private struct ChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 11).frame(height: 26)
                .foregroundStyle(selected ? Theme.canvas : Theme.textPrimary)
                .background { if selected { Capsule().fill(Theme.brand) } else { Capsule().fill(Theme.wash.opacity(0.07)) } }
                .overlay(Capsule().strokeBorder(selected ? Color.white.opacity(0.25) : Theme.hairline, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }
}

/// Wraps its children onto lines of the width it is given.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 320, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrange(width: bounds.width, subviews: subviews).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + lineHeight), origins)
    }
}
