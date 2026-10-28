import Foundation

/// Keeps the last `TailnetState` and its age. Polled every 10 s while the panel is open or a job
/// runs, every 60 s otherwise, and at once on wake from sleep. A connection takes its state from
/// `current(maxAge:)`, which re-reads when the cache is older than the caller allows.
public actor TailnetMonitor {
    public static let activeInterval: Duration = .seconds(10)
    public static let idleInterval: Duration = .seconds(60)

    private let reader: @Sendable () async -> TailnetState
    private var cached: TailnetState?
    private var started = 0
    private var stored = 0
    private var active = false
    private var loop: Task<Void, Never>?

    public init(reader: @escaping @Sendable () async -> TailnetState = { await TailnetState.read() }) {
        self.reader = reader
    }

    public var interval: Duration { active ? Self.activeInterval : Self.idleInterval }
    public var lastState: TailnetState? { cached }

    /// Whether the panel is open or a job is running; the next sleep of the loop uses the new rate.
    public func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if loop != nil { restart() }
    }

    @discardableResult
    public func refresh() async -> TailnetState {
        started += 1
        let sequence = started
        let state = await reader()
        // Reads can overlap; one that began earlier never replaces the result of one that began later.
        guard sequence > stored else {
            // A read that lost is never handed out; the newer one's result, or a new read, stands in.
            if let cached { return cached }
            return await refresh()
        }
        stored = sequence
        cached = state
        return state
    }

    /// The cached state when it is younger than `maxAge`, else a fresh read.
    public func current(maxAge: TimeInterval, now: Date = Date()) async -> TailnetState {
        if let cached, cached.age(at: now) >= 0, cached.age(at: now) <= maxAge { return cached }
        return await refresh()
    }

    /// After sleep the cache describes a network that may be gone: read again now and restart the cadence.
    public func wake() async {
        // Nothing read before the sleep may authorize a connection, not even while the new read runs.
        cached = nil
        stored = started
        await refresh()
        if loop != nil { restart() }
    }

    public func start() {
        guard loop == nil else { return }
        restart()
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: await self.interval)
            }
        }
    }
}
