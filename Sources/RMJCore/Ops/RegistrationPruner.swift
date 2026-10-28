import Foundation

/// Deletes the stale registrations an ephemeral runner stack leaves behind: only this stack's own naming
/// shape (`<12 hex container id>-<10 digit epoch>`), labelled with this destination, offline, idle, and
/// older than ten minutes. Each candidate is read again right before its delete.
public struct RegistrationPruner: Sendable {
    public static let minimumAge: TimeInterval = 600

    public struct Skip: Sendable, Equatable {
        public let runner: String
        public let reason: String
    }

    public struct Result: Sendable, Equatable {
        public var deleted: [String] = []
        public var skipped: [Skip] = []
    }

    private let api: GitHubWriteAPI
    private let now: @Sendable () -> Date

    public init(api: GitHubWriteAPI, now: @escaping @Sendable () -> Date = Date.init) {
        self.api = api
        self.now = now
    }

    /// What `prune` would delete, from one listing. Nothing is changed.
    public func candidates(target: String, destinationLabel: String, token: String?) async throws -> [GitHubRunner] {
        try await GitHubRunners.list(api: api, target: target, token: token).filter { Self.qualifies($0, label: destinationLabel, now: now()) }
    }

    public func prune(target: String, destinationLabel: String, token: String?) async throws -> Result {
        guard let path = RunnerTarget.path(target) else { throw GitHubRunners.Failure(message: "bad runner target") }
        var result = Result()
        for candidate in try await candidates(target: target, destinationLabel: destinationLabel, token: token) {
            // It may have come back between the listing and now.
            guard let current = try await GitHubRunners.get(api: api, target: target, id: candidate.id, token: token) else {
                result.skipped.append(Skip(runner: candidate.name, reason: "already gone"))
                continue
            }
            guard Self.qualifies(current, label: destinationLabel, now: now()) else {
                result.skipped.append(Skip(runner: candidate.name, reason: current.online ? "came back online" : "no longer matches"))
                continue
            }
            let response = try await api.delete("\(path)/\(candidate.id)", token: token)
            if response.status == 204 || response.status == 404 { result.deleted.append(candidate.name) }
            else { result.skipped.append(Skip(runner: candidate.name, reason: "GitHub answered \(response.status)")) }
        }
        return result
    }

    static func qualifies(_ runner: GitHubRunner, label: String, now: Date) -> Bool {
        guard !runner.online, !runner.busy, runner.labels.contains(label), let epoch = epoch(of: runner.name) else { return false }
        return now.timeIntervalSince1970 - epoch > minimumAge
    }

    /// `<12 hex>-<10 digits>`: a container id and the registration time.
    static func epoch(of name: String) -> TimeInterval? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 12, parts[0].allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
              parts[1].count == 10, parts[1].allSatisfy({ ("0"..."9").contains($0) }), let epoch = TimeInterval(parts[1]) else { return nil }
        return epoch
    }
}
