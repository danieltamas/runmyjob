import Foundation

/// The telemetry of one run, grouped for the report screen: what happened, where, when, and what it cost.
public struct RunReport: Sendable, Equatable {
    public struct Fact: Sendable, Equatable {
        public let label: String
        public let value: String
        public let tone: JobRowPresentation.Tone
    }

    public struct Section: Sendable, Equatable {
        public let title: String
        public let facts: [Fact]
    }

    public let title: String
    public let command: String
    public let stateText: String
    public let stateTone: JobRowPresentation.Tone
    public let sections: [Section]
    /// Where the time went: queued, sync, run; a phase with no measurement is absent.
    public let phases: [JobRowPresentation.Detail.Segment]
    /// How long the command ran, or has been running; nil before it started.
    public let runSeconds: TimeInterval?

    public init(_ job: JobRecord, now: Date) {
        title = job.repo
        command = job.command
        stateText = job.state.rawValue
        stateTone = Self.tone(job.state)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func fact(_ label: String, _ value: String?, _ tone: JobRowPresentation.Tone = .plain) -> Fact? {
            value.map { Fact(label: label, value: $0, tone: tone) }
        }
        func stamp(_ date: Date?) -> String? { date.map(formatter.string(from:)) }
        func span(_ from: Date?, _ to: Date?) -> String? {
            guard let from, let to, to > from else { return nil }
            return PanelFormat.duration(to.timeIntervalSince(from))
        }
        func exit(_ label: String, _ code: Int?) -> Fact? { code.flatMap { fact(label, String($0), $0 == 0 ? .ok : .crit) } }
        var segments: [JobRowPresentation.Detail.Segment] = []
        func phase(_ label: String, _ from: Date?, _ to: Date?) {
            if let from, let to, to > from { segments.append(.init(label: label, seconds: to.timeIntervalSince(from))) }
        }
        phase("queued", job.queuedAt, job.syncStartedAt ?? job.startedAt ?? job.endedAt)
        phase("sync", job.syncStartedAt, job.syncEndedAt)
        phase("run", job.boxStartedAt ?? job.startedAt, job.boxEndedAt ?? job.endedAt)
        phases = segments
        runSeconds = job.startedAt.map { max(0, (job.endedAt ?? now).timeIntervalSince($0)) }
        let running = job.endedAt == nil && job.startedAt != nil
        let groups: [(String, [Fact?])] = [
            ("Result", [fact("Status", job.state.rawValue, stateTone), exit("Exit code", job.exitCode), exit("Box exit", job.boxExit)]),
            ("Where", [fact("Location", job.destination ?? job.location), fact("Environment", job.environment), fact("Rule", job.rule),
                       fact("Fallback", job.fallbackReason, .warn), fact("Tenant", job.tenant), fact("Repo", job.repo),
                       fact("Worktree", job.worktree), fact("Branch", job.branch),
                       fact("Commit", job.commit.map { job.dirty ? "\($0) (dirty)" : $0 }), fact("Agent", job.agent), fact("Session", job.session)]),
            ("Timing", [fact("Queued", stamp(job.queuedAt)), fact("Started", stamp(job.startedAt)), fact("Ended", stamp(job.endedAt)),
                        fact("Queue wait", span(job.queuedAt, job.startedAt)), fact("Sync", span(job.syncStartedAt, job.syncEndedAt)),
                        fact(running ? "Elapsed" : "Run", running ? span(job.startedAt, now) : span(job.startedAt, job.endedAt)),
                        fact("Box run", span(job.boxStartedAt, job.boxEndedAt)), fact("Box start", stamp(job.boxStartedAt)),
                        fact("Box end", stamp(job.boxEndedAt)), fact("Clock offset", job.clockOffsetMS.map { "\($0) ms" })]),
            ("Resources", [fact("Avg CPU", job.avgCPU.map { "\(Int($0.rounded()))%" }),
                           fact("Avg memory", job.avgMemoryBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) })]),
        ]
        sections = groups.compactMap { title, facts in
            let present = facts.compactMap { $0 }
            return present.isEmpty ? nil : Section(title: title, facts: present)
        }
    }

    private static func tone(_ state: JobState) -> JobRowPresentation.Tone {
        switch state {
        case .done: .ok
        case .failed, .lost: .crit
        case .cancelled: .warn
        case .running, .syncing: .running
        default: .unknown
        }
    }
}
