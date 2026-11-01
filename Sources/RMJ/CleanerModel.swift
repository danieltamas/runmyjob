import AppKit
import Foundation
import RMJCore
import SwiftUI

/// What the Cleaner pane shows and does: `clean.json` through `CleanConfigStore`, the last check, the history.
/// Every edit is validated and saved as it is made; nothing here needs the file or the CLI.
@MainActor
final class CleanerModel: ObservableObject {
    @Published private(set) var config = CleanConfig.defaults
    /// Why `clean.json` is rejected: the pane then offers a reset instead of edits.
    @Published private(set) var problem: String?
    /// The last "Check what would go" or removal, shown until the next one.
    @Published private(set) var result: CleanRun?
    @Published private(set) var history: [CleanRun] = []
    @Published private(set) var busy = false
    /// The last edit that was refused, in words.
    @Published private(set) var refusal: String?
    private let home = RMJHome()
    private let live: Bool
    private var cached: CleanSettingsService?

    init() { live = true }

    /// State given, for the screenshot render: nothing is read from or written to disk.
    init(demo config: CleanConfig, problem: String? = nil, result: CleanRun? = nil, history: [CleanRun] = []) {
        live = false
        self.config = config
        self.problem = problem
        self.result = result
        self.history = history
    }

    var logFile: URL { home.url.appendingPathComponent("logs/clean.log") }

    func reload() async {
        guard live else { return }
        let loaded = CleanConfigStore(home: home).load()
        config = loaded.config
        problem = loaded.problem
        if let service = service() { history = (try? await service.history(limit: 10)) ?? history }
    }

    func loop() async {
        while live, !Task.isCancelled {
            if !busy { await reload() }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func setScheduled(_ on: Bool) {
        change { $0.schedule = on ? CleanSchedule(everyHours: 24, apply: false) : nil }
    }

    func setEvery(_ hours: Int) { change { $0.schedule?.everyHours = hours } }
    func setApply(_ apply: Bool) { change { $0.schedule?.apply = apply } }

    func setIdle(_ hours: Int, at index: Int) {
        change { if $0.targets.indices.contains(index) { $0.targets[index].afterHours = hours } }
    }

    func removeTarget(at index: Int) {
        change { if $0.targets.indices.contains(index) { $0.targets.remove(at: index) } }
    }

    func add(_ target: CleanTarget) {
        change { $0.targets.append(target) }
    }

    func reset() {
        do { try CleanConfigStore(home: home).reset(); refusal = nil } catch { refusal = "\(error)" }
        Task { await reload() }
    }

    /// "Check what would go": a dry run, nothing is removed.
    func check() { run(apply: false) }

    /// "Remove": decided again now (a folder that is in use stays). A fresh check goes first: if it lists anything
    /// the confirmed check did not, nothing is removed and the new list waits for another confirmation.
    func remove() {
        guard let confirmed = result, !confirmed.apply else { return run(apply: true) }
        let allowed = Set(confirmed.items.filter { $0.action == .wouldRemove }.map(\.path))
        guard !busy, let service = service() else { return }
        busy = true
        refusal = nil
        Task {
            do {
                let fresh = try await service.run(apply: false)
                if Set(fresh.items.filter { $0.action == .wouldRemove }.map(\.path)).isSubset(of: allowed) {
                    result = try await service.run(apply: true)
                } else {
                    result = fresh
                    refusal = "More than the confirmed list qualified in the meantime: nothing was removed. Check the new list."
                }
            } catch { refusal = (error as? CleanConfigStore.Invalid)?.message ?? "\(error)" }
            busy = false
            await reload()
        }
    }

    func revealLog() {
        let file = FileManager.default.fileExists(atPath: logFile.path) ? logFile : logFile.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func change(_ edit: (inout CleanConfig) -> Void) {
        // Edit what is on disk now, not what the last poll saw: another writer's change is not undone by this one.
        let stored: (config: CleanConfig, problem: String?) = live ? CleanConfigStore(home: home).load() : (config, nil)
        guard stored.problem == nil else { problem = stored.problem; return }
        var edited = stored.config
        edit(&edited)
        do {
            try CleanConfigStore(home: home).save(edited)
            config = edited
            refusal = nil
            result = nil
        } catch { refusal = (error as? CleanConfigStore.Invalid)?.message ?? "\(error)" }
    }

    private func run(apply: Bool) {
        guard !busy, let service = service() else { return }
        busy = true
        refusal = nil
        Task {
            do { result = try await service.run(apply: apply) } catch { refusal = (error as? CleanConfigStore.Invalid)?.message ?? "\(error)" }
            busy = false
            await reload()
        }
    }

    /// Opened once: the pane re-reads every few seconds and must not reopen (and migrate) the database each time.
    private func service() -> CleanSettingsService? {
        guard live else { return nil }
        if cached == nil {
            do { cached = CleanSettingsService(ledger: Ledger(database: try Database(url: home.url.appendingPathComponent("rmj.sqlite"))), home: home) }
            catch { refusal = "The ledger cannot be opened: \(UntrustedText.clean("\(error)", limit: 160))" }
        }
        return cached
    }
}
