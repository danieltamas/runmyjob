import Foundation

/// Runs the cleaner when `clean.json` asks for it and the last run is old enough.
public struct CleanScheduler: Sendable {
    let ledger: Ledger
    let home: RMJHome
    let now: @Sendable () -> Date
    let inUse: (@Sendable (String) async -> Bool)?

    public init(ledger: Ledger, home: RMJHome, now: @escaping @Sendable () -> Date = { Date() },
                inUse: (@Sendable (String) async -> Bool)? = nil) {
        self.ledger = ledger
        self.home = home
        self.now = now
        self.inUse = inUse
    }

    /// nil when nothing was due or the config does not allow it; a run that could not start carries its `problem`
    /// and is not recorded, so the next call tries again.
    public func runIfDue() async -> CleanRun? {
        let loaded = CleanConfig.load(home: home)
        guard loaded.problem == nil, let schedule = loaded.config.schedule else { return nil }
        let cleaner = Cleaner(ledger: ledger, config: loaded.config, logDirectory: home.url.appendingPathComponent("logs"), now: now, inUse: inUse)
        // Checked again under the cleaner's lock: a run that finished while this one waited for it counts.
        return await cleaner.execute(apply: schedule.apply, source: "schedule") { await isDue(schedule) }
    }

    /// A history that cannot be read is not "never cleaned": nothing runs until it can be.
    private func isDue(_ schedule: CleanSchedule) async -> Bool {
        guard let rows = try? await ledger.database.query("SELECT MAX(started_at) AS latest FROM clean_run") else { return false }
        guard let latest = rows.first?["latest"]?.intValue else { return true }
        return now().timeIntervalSince(Ledger.date(latest)) >= Double(schedule.everyHours) * 3600
    }
}
