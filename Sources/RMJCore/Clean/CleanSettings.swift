import Foundation

/// `~/.rmj/clean.json` as the Settings pane edits it: validated before it is written, replaced atomically.
public struct CleanConfigStore: Sendable {
    public struct Invalid: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    let home: RMJHome
    var file: URL { home.url.appendingPathComponent("clean.json") }

    public init(home: RMJHome) { self.home = home }

    public func load() -> (config: CleanConfig, problem: String?) { CleanConfig.load(home: home) }

    /// Nothing is written when the config is invalid.
    public func save(_ config: CleanConfig) throws {
        if let problem = config.validate() { throw Invalid(message: problem) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try home.prepare()
        // Written private under a temporary name, then renamed over the file: a reader never sees half of it.
        let temporary = home.url.appendingPathComponent(".clean.json.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(config), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        // rename(2) keeps the temporary file's 0600 and works whether or not clean.json exists.
        guard rename(temporary.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Back to the defaults: the file goes.
    public func reset() throws {
        do { try FileManager.default.removeItem(at: file) } catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
}

/// What the Settings pane's buttons run: the saved config, `source` "ui" in the trail.
public struct CleanSettingsService: Sendable {
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

    /// Throws `CleanConfigStore.Invalid` when the file is rejected: nothing is removed or recorded then.
    public func run(apply: Bool) async throws -> CleanRun {
        let loaded = CleanConfigStore(home: home).load()
        if let problem = loaded.problem { throw CleanConfigStore.Invalid(message: problem) }
        return await Cleaner(ledger: ledger, config: loaded.config, logDirectory: home.url.appendingPathComponent("logs"),
                             now: now, inUse: inUse).run(apply: apply, source: "ui")
    }

    public func history(limit: Int) async throws -> [CleanRun] { try await ledger.cleanRuns(limit: limit) }
}
