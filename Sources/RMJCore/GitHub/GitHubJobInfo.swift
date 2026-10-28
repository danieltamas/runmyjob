import Foundation

/// What a queued job is waiting on, as observed: not a verdict. `suspectedCause` is set only when
/// exactly one explanation fits the registrations, else `unknown`.
public struct QueueObservation: Codable, Sendable, Equatable {
    public struct Match: Codable, Sendable, Equatable {
        public var name: String
        /// `online idle`, `online busy`, `offline idle` or `offline busy`.
        public var state: String
    }

    public var labels: [String]
    public var matches: [Match]
    public var observedAt: Date
    public var suspectedCause: String
    /// `0 online, 1 offline idle (runner-a)`.
    public var summary: String
}

public enum QueueAnalysis {
    /// A runner can take a job when it carries every label the job asks for.
    public static func observe(labels: [String], registrations: [RunnerRegistration], now: Date) -> QueueObservation {
        let wanted = Set(labels.map { $0.lowercased() })
        let matching = registrations.filter { wanted.isSubset(of: Set($0.labels.map { $0.lowercased() })) }
        let matches = matching.map { QueueObservation.Match(name: GitHubText.clean($0.name), state: Self.state($0)) }
        let online = matching.filter(\.online)
        let offlineIdle = matching.filter { !$0.online && !$0.busy }
        // Each cause is one explanation; a cause is named only when it is the only one that fits.
        var candidates = [String]()
        // A stale registration explains the wait only when nothing online could take the job; busy runners are a rival explanation.
        if !offlineIdle.isEmpty, online.isEmpty { candidates.append("stale registration") }
        if online.isEmpty, offlineIdle.isEmpty { candidates.append("none online") }
        if !online.isEmpty, online.allSatisfy(\.busy) { candidates.append("all busy") }
        if !offlineIdle.isEmpty, !online.isEmpty, online.allSatisfy(\.busy) { candidates.append("stale registration") }
        let cause = candidates.count == 1 ? candidates[0] : "unknown"
        return QueueObservation(labels: labels.map { GitHubText.clean($0) }, matches: matches, observedAt: now, suspectedCause: cause,
                                summary: summary(matching))
    }

    static func state(_ runner: RunnerRegistration) -> String {
        "\(runner.online ? "online" : "offline") \(runner.busy ? "busy" : "idle")"
    }

    static func summary(_ matching: [RunnerRegistration]) -> String {
        var parts = matching.contains(where: \.online) ? [] : ["0 online"]
        for state in ["online idle", "online busy", "offline idle", "offline busy"] {
            let named = matching.filter { Self.state($0) == state }
            if !named.isEmpty { parts.append("\(named.count) \(state) (\(named.map { GitHubText.clean($0.name) }.joined(separator: ", ")))") }
        }
        return parts.joined(separator: ", ")
    }
}

/// The `github` column of a job row, JSON encoded.
public struct GitHubJobInfo: Codable, Sendable, Equatable {
    public var repo: String
    /// The job's own name (the workflow name is in the row's command).
    public var name: String
    /// The destination whose runner took the job, when the registrations say so.
    public var destination: String?
    public var runId: Int64
    public var jobId: Int64
    public var runAttempt: Int
    public var status: String
    public var conclusion: String?
    public var htmlUrl: String?
    public var runnerName: String?
    public var labels: [String]
    public var currentStep: String?
    public var currentStepNumber: Int?
    public var stepsDone: Int
    public var stepsTotal: Int
    public var createdAt: Date?
    public var startedAt: Date?
    public var completedAt: Date?
    public var observation: QueueObservation?
    /// Set while the job waits on a `needs` dependency rather than on a runner.
    public var waitingOnDependency: Bool
    /// The ledger id of the same job's previous attempt.
    public var parentAttempt: String?

    public var json: String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func decode(_ json: String?) -> GitHubJobInfo? {
        guard let json else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GitHubJobInfo.self, from: Data(json.utf8))
    }
}

/// Names from GitHub are attacker-influenced text: terminal escape sequences go first, then invisible Unicode.
public enum GitHubText {
    public static func clean(_ text: String, limit: Int = 200) -> String {
        var sanitizer = LogSanitizer()
        return UntrustedText.clean(String(decoding: sanitizer.clean(Data(text.utf8)), as: UTF8.self), limit: limit)
    }
}

public enum GitHubMapping {
    /// GitHub's words to the ledger's: a conclusion decides a settled job; `skipped` is never a failure,
    /// `timed_out` always is.
    public static func state(status: String?, conclusion: String?) -> JobState {
        switch status {
        case "completed":
            switch conclusion {
            case "success", "neutral": return .done
            case "cancelled": return .cancelled
            case "skipped": return .skipped
            default: return .failed
            }
        case "in_progress": return .running
        default: return .queued
        }
    }

    /// Dependency wait is shown apart from the runner queue: another job of the run was still running when this one was created.
    static func waitsOnDependency(_ job: GHJob, siblings: [GHJob]) -> Bool {
        guard job.status == "queued" || job.status == "waiting", let created = job.createdAt else { return false }
        return siblings.contains { other in
            guard other.id != job.id, let started = other.startedAt, started <= created else { return false }
            return other.completedAt.map { $0 >= created } ?? true
        }
    }

    public static func ledgerID(jobID: Int64, attempt: Int) -> String { "gh-\(jobID)-\(attempt)" }

    /// A queued job that has no runner assigned yet and no created steps may be waiting on `needs`.
    public static func info(repo: String, run: GHRun, job: GHJob, observation: QueueObservation?, parent: String?) -> GitHubJobInfo {
        let steps = job.steps ?? []
        let current = steps.first { $0.status == "in_progress" } ?? steps.first { $0.status == "queued" || $0.status == "pending" }
        let done = steps.filter { $0.status == "completed" }.count
        return GitHubJobInfo(repo: repo, name: GitHubText.clean(job.name), destination: nil, runId: job.runId, jobId: job.id, runAttempt: job.runAttempt, status: job.status ?? "queued",
                             conclusion: job.conclusion, htmlUrl: job.htmlUrl, runnerName: job.runnerName.map { GitHubText.clean($0) },
                             labels: job.labels.map { GitHubText.clean($0) }, currentStep: job.status == "in_progress" ? current.map { GitHubText.clean($0.name) } : nil,
                             currentStepNumber: job.status == "in_progress" ? current?.number : nil, stepsDone: done, stepsTotal: steps.count,
                             createdAt: job.createdAt, startedAt: job.startedAt, completedAt: job.completedAt, observation: observation,
                             waitingOnDependency: job.status == "waiting", parentAttempt: parent)
    }
}
