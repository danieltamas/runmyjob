import Foundation

public enum JobState: String, Sendable, CaseIterable {
    case queued, syncing, running, done, failed, cancelled, lost, skipped

    /// A state only moves to a higher rank, so a late event never moves a settled row backwards.
    /// `lost` ranks between running and the outcomes: reconcile can still settle it.
    var rank: Int {
        switch self {
        case .queued: 0
        case .syncing: 1
        case .running: 2
        case .lost: 3
        case .done, .failed, .cancelled, .skipped: 4
        }
    }

    public var isSettled: Bool { rank == 4 }
    static func below(_ state: JobState) -> [JobState] { allCases.filter { $0.rank < state.rank } }
}

public struct JobRecord: Sendable, Equatable {
    public var id: String
    public var repo: String
    public var command: String
    /// A destination name, `local` or `github-hosted`.
    public var location: String
    public var destination: String?
    public var fallbackReason: String?
    /// `box`, or `mac` when a suite may have skipped Linux-only cases.
    public var environment: String
    public var rule: String?
    public var warmth: String
    public var state: JobState
    public var exitCode: Int?
    public var queuedAt: Date
    public var syncStartedAt: Date?
    public var syncEndedAt: Date?
    public var startedAt: Date?
    public var endedAt: Date?
    public var boxStartedAt: Date?
    public var boxEndedAt: Date?
    public var boxExit: Int?
    public var macElapsedMS: Int?
    public var clockOffsetMS: Int?
    /// What a run on this Mac cost on average: processor in percent of one core, resident memory in bytes.
    public var avgCPU: Double?
    public var avgMemoryBytes: Int64?
    public var github: String?
    /// Where the command came from: the checkout, its state and the agent that asked.
    public var tenant: String?
    public var worktree: String?
    public var branch: String?
    public var commit: String?
    public var dirty = false
    public var agent: String?
    public var session: String?

    public init(id: String, repo: String, command: String, location: String, destination: String? = nil,
                fallbackReason: String? = nil, environment: String = "box", rule: String? = nil, warmth: String = "unknown",
                state: JobState = .queued, queuedAt: Date) {
        self.id = id
        self.repo = repo
        self.command = command
        self.location = location
        self.destination = destination
        self.fallbackReason = fallbackReason
        self.environment = environment
        self.rule = rule
        self.warmth = warmth
        self.state = state
        self.queuedAt = queuedAt
    }

    public enum Timing: Sendable, Equatable {
        case box(milliseconds: Int)
        case mac(milliseconds: Int)
        case unknown
    }

    /// The box pair when both exist and the end is after the start, else the Mac's monotonic
    /// elapsed, else unknown. A contradictory value is unknown, never negative.
    public var duration: Timing {
        if let start = boxStartedAt, let end = boxEndedAt, end > start {
            return .box(milliseconds: Int((end.timeIntervalSince(start) * 1000).rounded()))
        }
        if let elapsed = macElapsedMS, elapsed >= 0 { return .mac(milliseconds: elapsed) }
        return .unknown
    }
}

/// Fields a transition may set along with the new state. Only these columns are ever written.
public struct JobPatch: Sendable {
    public var exitCode: Int?
    public var syncStartedAt: Date?
    public var syncEndedAt: Date?
    public var startedAt: Date?
    public var endedAt: Date?
    public var boxStartedAt: Date?
    public var boxEndedAt: Date?
    public var boxExit: Int?
    public var macElapsedMS: Int?
    public var clockOffsetMS: Int?
    public var avgCPU: Double?
    public var avgMemoryBytes: Int64?
    public var github: String?
    public var fallbackReason: String?

    public init() {}
}
