import Foundation
import RMJCore
import SwiftUI

/// What the Log streaming pane shows: the sinks from `config.json`, their status file and what waits in each spool,
/// read again every two seconds while the pane is open. Every action goes through `LogSinkAdmin`.
@MainActor
final class LogStreamModel: ObservableObject {
    struct Row: Identifiable {
        let sink: LogSinkConfig
        let status: LogSinkStatus
        let pending: LogSpool.Pending
        var id: String { sink.id }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var problems: [String] = []
    /// What the last action on a sink said, by sink id.
    @Published private(set) var results: [String: String] = [:]
    @Published private(set) var busy: Set<String> = []
    private let home = RMJHome()
    private let live: Bool

    init() { live = true }

    /// Rows given, for the screenshot render: nothing is read from disk.
    init(demo rows: [Row]) {
        live = false
        self.rows = rows
    }

    func reload() {
        guard live else { return }
        let loaded = LogSinkStore.load(home: home)
        let statuses = LogSinkStatusStore(home: home).read()
        rows = loaded.sinks.map { sink in
            Row(sink: sink, status: statuses.first { $0.id == sink.id } ?? LogSinkStatus(id: sink.id), pending: LogSinkAdmin.spool(sink, home: home).pending())
        }
        problems = loaded.problems
    }

    func loop() async {
        while live, !Task.isCancelled {
            reload()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func setEnabled(_ sink: LogSinkConfig, _ enabled: Bool) {
        var changed = sink
        changed.enabled = enabled
        replace(changed)
    }

    func replace(_ sink: LogSinkConfig) {
        var all = LogSinkStore.load(home: home).sinks
        if let index = all.firstIndex(where: { $0.id == sink.id }) { all[index] = sink } else { all.append(sink) }
        do { try LogSinkStore.save(all, home: home) } catch { results[sink.id] = "\(error)" }
        reload()
    }

    func sendTest(_ sink: LogSinkConfig) {
        run(sink) {
            let outcome = await LogSinkAdmin.sendTest(sink, secret: try? Keychain().read(account: sink.keychainAccount))
            return (outcome.ok ? "Test line " : "Test line not sent: ") + outcome.message
        }
    }

    /// Sends the spool now instead of at the next beat, ignoring a backoff or an old auth failure.
    func drainNow(_ sink: LogSinkConfig) {
        run(sink) { [home] in
            guard let streamer = LogStreamer(home: home, sinks: [sink]) else { return "Switch the sink on first" }
            await streamer.resume(sinkID: sink.id)
            await streamer.drainUntilEmptyOrTimeout()
            return "Drained what could be sent"
        }
    }

    func discard(_ sink: LogSinkConfig) {
        do { try LogSinkAdmin.discardWaiting(sink, home: home); results[sink.id] = "Waiting lines discarded" } catch { results[sink.id] = "\(error)" }
        reload()
    }

    func remove(_ sink: LogSinkConfig) {
        do { try LogSinkAdmin.remove(sink, home: home) } catch { results[sink.id] = "\(error)" }
        reload()
    }

    private func run(_ sink: LogSinkConfig, _ work: @escaping @Sendable () async -> String) {
        guard !busy.contains(sink.id) else { return }
        busy.insert(sink.id)
        Task {
            let message = await work()
            results[sink.id] = message
            busy.remove(sink.id)
            reload()
        }
    }
}
