import AppKit
import RMJCore
import SwiftUI

/// Settings > Cleaner: what RMJ removes from this Mac, when, and what it removed (docs/ARCHITECTURE.md, "The cleaner").
struct CleanerPane: View {
    @StateObject private var model: CleanerModel
    @State private var confirming = false
    @State private var newPattern = ""
    @State private var newHours = 48

    init(model: @autoclosure @escaping () -> CleanerModel = CleanerModel()) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .cleaner, title: "Cleaner",
                       detail: "Removes build folders and idle agent worktrees nobody uses any more. It never touches a folder in use, a recent one, or a worktree with unsaved or unpushed work.")
            if let problem = model.problem {
                SettingsCard(title: "The cleaner's settings are not usable", detail: problem) {
                    ActionButton(title: "Reset to defaults", symbol: "arrow.counterclockwise") { model.reset() }
                }
            } else {
                schedule
                targets
                cleanNow
            }
            if let refusal = model.refusal { ProblemText(text: refusal) }
            historyCard
        }
        .task { await model.loop() }
    }

    private static let intervals = [1, 6, 12, 24, 48, 72, 168]
    private static let idleHours = [6, 12, 24, 48, 72, 168, 720]

    private func options(_ base: [Int], including current: Int) -> [Int] {
        base.contains(current) ? base : (base + [current]).sorted()
    }

    private func label(hours: Int) -> String {
        hours % 24 == 0 && hours >= 48 ? "\(hours / 24) days" : hours == 1 ? "1 hour" : "\(hours) hours"
    }

    private var schedule: some View {
        let current = model.config.schedule
        return SettingsCard(title: "Automatic cleaning", detail: "While RMJ is running it checks every few minutes whether a run is due.") {
            SwitchRow(title: "Clean on a schedule", detail: current == nil ? "Off: the cleaner only runs when you ask." : nil,
                      isOn: Binding(get: { current != nil }, set: { model.setScheduled($0) }))
            if let current {
                RowDivider()
                SettingsRow(title: "Run every") {
                    Picker("", selection: Binding(get: { current.everyHours }, set: { model.setEvery($0) })) {
                        ForEach(options(Self.intervals, including: current.everyHours), id: \.self) { Text(label(hours: $0)).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                RowDivider()
                SwitchRow(title: "Remove for real", detail: current.apply ? "Each scheduled run removes what it finds." : "Each scheduled run only lists what it would remove, so you can look first.",
                          isOn: Binding(get: { current.apply }, set: { model.setApply($0) }))
            }
        }
    }

    private var targets: some View {
        SettingsCard(title: "What it cleans", detail: "A folder is cleaned only when nothing in it was touched for the idle time.") {
            ForEach(Array(model.config.targets.enumerated()), id: \.offset) { index, target in
                if index > 0 { RowDivider() }
                SettingsRow(title: UntrustedText.clean(target.path, limit: 200), detail: target.kind == .worktrees ? "Idle git worktrees of this repository" : "Folders matching this pattern") {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(get: { target.afterHours }, set: { model.setIdle($0, at: index) })) {
                            ForEach(options(Self.idleHours, including: target.afterHours), id: \.self) { Text("idle \(label(hours: $0))").tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                        ActionButton(title: "Remove", symbol: "minus.circle") { model.removeTarget(at: index) }
                    }
                }
            }
            if model.config.targets.isEmpty { Text("Nothing is cleaned.").font(.meta).foregroundStyle(Theme.textTertiary) }
            RowDivider()
            HStack(spacing: 8) {
                TextField("Folder or name pattern, e.g. /private/tmp/bton-*", text: $newPattern)
                    .textFieldStyle(.roundedBorder).font(.meta)
                Picker("", selection: $newHours) {
                    ForEach(Self.idleHours, id: \.self) { Text("idle \(label(hours: $0))").tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                ActionButton(title: "Add build folder", symbol: "plus", disabled: newPattern.trimmingCharacters(in: .whitespaces).isEmpty) {
                    model.add(CleanTarget(kind: .scratch, path: newPattern.trimmingCharacters(in: .whitespaces), afterHours: newHours))
                    newPattern = ""
                }
            }
            HStack { ActionButton(title: "Add git repository...", symbol: "plus") { chooseRepository() }; Spacer(minLength: 0) }
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose a git repository: its idle worktrees are cleaned."
        if panel.runModal() == .OK, let url = panel.url { model.add(CleanTarget(kind: .worktrees, path: url.path, afterHours: newHours)) }
    }

    private var cleanNow: some View {
        SettingsCard(title: "Clean now", detail: "Look first: a check lists what would be removed and changes nothing.") {
            HStack(spacing: 8) {
                ActionButton(title: model.busy ? "Working..." : "Check what would go", symbol: "magnifyingglass", disabled: model.busy) { confirming = false; model.check() }
                if let result = model.result, !result.apply {
                    let count = result.items.filter { $0.action == .wouldRemove }.count
                    if confirming {
                        ActionButton(title: "Yes, remove \(count)", style: .destructive, disabled: model.busy) { confirming = false; model.remove() }
                        ActionButton(title: "Cancel") { confirming = false }
                    } else {
                        ActionButton(title: "Remove \(count) \(count == 1 ? "item" : "items") (\(Self.size(result.items.filter { $0.action == .wouldRemove }.reduce(0) { $0 + $1.bytes })))",
                                     symbol: "trash", style: .destructive, disabled: model.busy || count == 0) { confirming = true }
                    }
                }
                Spacer(minLength: 0)
            }
            if let result = model.result { outcome(result) }
        }
    }

    private func outcome(_ run: CleanRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = run.problem { ProblemText(text: problem) }
            Text(Self.summary(run)).font(.meta).foregroundStyle(Theme.textSecondary)
            ForEach(Array(Self.shown(run).prefix(12).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Chip(text: Self.word(item.action), color: Self.color(item.action))
                    Text(UntrustedText.clean(item.path, limit: 200)).font(.meta).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(item.action == .skipped ? item.reason : Self.size(item.bytes)).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            if Self.shown(run).count > 12 { Text("and \(Self.shown(run).count - 12) more, all in the log").font(.meta).foregroundStyle(Theme.textTertiary) }
        }
    }

    private var historyCard: some View {
        SettingsCard(title: "History", detail: "Every run is kept for 90 days, with one line per item in the log.") {
            if model.history.isEmpty { Text("No runs yet.").font(.meta).foregroundStyle(Theme.textTertiary) }
            ForEach(Array(model.history.enumerated()), id: \.offset) { index, run in
                if index > 0 { RowDivider() }
                HStack(spacing: 8) {
                    Chip(text: run.apply ? "Removed" : "Check", color: run.apply ? Theme.teal : Theme.neutral)
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.meta).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    Text(run.problem ?? Self.summary(run)).font(.meta).foregroundStyle(run.problem == nil ? Theme.textTertiary : Theme.warn).lineLimit(1)
                }
            }
            HStack { ActionButton(title: "Show log", symbol: "doc.text") { model.revealLog() }; Spacer(minLength: 0) }
        }
    }

    static func summary(_ run: CleanRun) -> String {
        let removed = run.items.filter { $0.action == .removed }.count
        let would = run.items.filter { $0.action == .wouldRemove }.count
        let skipped = shown(run).filter { $0.action == .skipped }.count
        let failed = run.items.filter { $0.action == .failed }.count
        var parts = [run.apply ? "\(removed) removed, \(size(run.freedBytes)) freed" : "\(would) would go, \(size(run.items.filter { $0.action == .wouldRemove }.reduce(0) { $0 + $1.bytes }))"]
        if skipped > 0 { parts.append("\(skipped) kept") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: ", ")
    }

    /// What the list names: files that match a pattern are not candidates and stay in the log only; what would go comes first.
    static func shown(_ run: CleanRun) -> [CleanItem] {
        let order: [CleanAction: Int] = [.removed: 0, .wouldRemove: 0, .failed: 1, .skipped: 2]
        return run.items.filter { !($0.action == .skipped && $0.reason == "not a directory") }
            .enumerated().sorted { (order[$0.element.action] ?? 3, $0.offset) < (order[$1.element.action] ?? 3, $1.offset) }.map(\.element)
    }

    static func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func word(_ action: CleanAction) -> String {
        switch action {
        case .removed: "Removed"
        case .wouldRemove: "Would go"
        case .skipped: "Kept"
        case .failed: "Failed"
        }
    }

    static func color(_ action: CleanAction) -> Color {
        switch action {
        case .removed: Theme.teal
        case .wouldRemove: Theme.warn
        case .skipped: Theme.neutral
        case .failed: Theme.crit
        }
    }
}
