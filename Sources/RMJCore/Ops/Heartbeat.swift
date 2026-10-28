import Foundation

/// Three failed probes in a row while an rx job runs on a destination mark the job `lost` and notify once;
/// the box answering again ends the outage, and the reconciler settles the job from its records. A wake
/// from sleep restarts the count, so the Mac's own sleep never produces a `lost`. GitHub rows are never touched.
public actor Heartbeat {
    public static let threshold = 3

    private let ledger: Ledger
    private let notify: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private var failures = [String: Int]()
    private var notified = Set<String>()
    private var generation = [String: Int]()
    private var wakes = 0

    public init(ledger: Ledger, notify: @escaping @Sendable (String) -> Void, now: @escaping @Sendable () -> Date = Date.init) {
        self.ledger = ledger
        self.notify = notify
        self.now = now
    }

    public func record(destination: String, reachable: Bool) async throws {
        guard !reachable else {
            generation[destination, default: 0] += 1
            failures[destination] = nil
            notified.remove(destination)
            return
        }
        failures[destination, default: 0] += 1
        guard failures[destination, default: 0] >= Self.threshold else { return }
        let started = (generation[destination, default: 0], wakes)
        let running = try await ledger.jobs(in: [.running]).filter { $0.destination == destination && $0.github == nil }
        var flipped = [String]()
        // A success or a wake while the ledger was read ends this outage count: nothing is marked from a stale view.
        for job in running {
            guard (generation[destination, default: 0], wakes) == started else { break }
            if try await ledger.advance(job.id, to: .lost, at: now(), detail: "destination unreachable") { flipped.append(job.id) }
        }
        if !flipped.isEmpty, notified.insert(destination).inserted {
            notify("\(destination) is unreachable; \(flipped.count) running job\(flipped.count == 1 ? "" : "s") marked lost")
        }
    }

    /// After sleep the probes start from zero.
    public func wake() {
        wakes += 1
        failures.removeAll()
    }
}
