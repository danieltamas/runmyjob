import AppKit
import RMJCore
import SwiftUI

/// What the Hooks pane shows about the guard: the switch, and the blocks agents ran into, read from `guard.log`.
@MainActor
final class GuardModel: ObservableObject {
    @Published private(set) var enabled = true
    @Published private(set) var entries: [GuardLog.Entry] = []
    @Published private(set) var refusal: String?
    private let home = RMJHome()
    private let live: Bool

    init() { live = true }

    /// State given, for the screenshot render: nothing is read from or written to disk.
    init(demo enabled: Bool, entries: [GuardLog.Entry]) {
        live = false
        self.enabled = enabled
        self.entries = entries
    }

    /// The reads happen off the main actor: the log may be large or slow.
    func reload() async {
        guard live else { return }
        let home = home
        let read = await Task.detached { (GuardSettings.enabled(home: home), GuardLog(home: home).recent(limit: 10)) }.value
        (enabled, entries) = read
    }

    func loop() async {
        while live, !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func setEnabled(_ on: Bool) {
        do { try GuardSettings.set(on, home: home); refusal = nil } catch { refusal = "\(error)" }
        Task { await reload() }
    }

    func revealLog() {
        let file = home.url.appendingPathComponent("logs/guard.log")
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: file.path) ? file : file.deletingLastPathComponent()])
    }
}

struct GuardCards: View {
    @StateObject private var model: GuardModel

    init(model: @autoclosure @escaping () -> GuardModel = GuardModel()) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "Routing of suites", detail: "An agent's test or check command in a repo your rules route to a box is stopped, with the command to run instead.") {
                SwitchRow(title: "Send tests and checks through RMJ",
                          detail: model.enabled ? "A headless job that must run its own tests can set RMJ_GUARD=off in its environment."
                                                : "Agents run their own tests here. Nothing is blocked or advised.",
                          isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                if let refusal = model.refusal { ProblemText(text: refusal) }
            }
            SettingsCard(title: "Recent blocks", detail: "Every time the guard stopped or advised an agent, newest first.") {
                if model.entries.isEmpty { Text("Nothing was blocked yet.").font(.meta).foregroundStyle(Theme.textTertiary) }
                ForEach(Array(model.entries.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { RowDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Chip(text: entry.verdict == "block" ? "Blocked" : "Advice", color: entry.verdict == "block" ? Theme.warn : Theme.neutral)
                            .frame(width: 76, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.command).font(.meta).foregroundStyle(Theme.textPrimary).lineLimit(2).truncationMode(.middle)
                            Text([entry.repo, entry.at.formatted(date: .abbreviated, time: .shortened)].filter { !$0.isEmpty }.joined(separator: " - "))
                                .font(.meta).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                HStack { ActionButton(title: "Show log", symbol: "doc.text") { model.revealLog() }; Spacer(minLength: 0) }
            }
        }
        .task { await model.loop() }
    }
}
