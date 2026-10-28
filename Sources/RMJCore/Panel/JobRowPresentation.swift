import Foundation

/// What a Jobs row says, decided here so the rules of docs/DESIGN.md (Jobs) are tested without a view.
public struct JobRowPresentation: Sendable, Equatable {
    /// The hue a piece of text takes: one per meaning (docs/DESIGN.md, One hue per meaning).
    public enum Tone: String, Sendable { case running, ok, crit, warn, local, unknown, plain }

    public enum LocationKind: String, Sendable { case destination, local, github }

    public enum Agent: String, Sendable {
        case claudeCode = "claude-code", codex, opencode, hermes, github, terminal

        init(_ name: String?, github: Bool) {
            if github { self = .github; return }
            self = Agent(rawValue: (name ?? "").lowercased().replacingOccurrences(of: " ", with: "-")) ?? .terminal
        }
    }

    public enum Action: String, Sendable { case log = "Log", rerun = "Rerun" }

    public struct Chip: Sendable, Equatable {
        public let text: String
        public let tone: Tone
    }

    public struct Part: Sendable, Equatable {
        public let text: String
        public let tone: Tone
    }

    public enum Section: String, Sendable, CaseIterable { case running = "Running", queued = "Queued", today = "Today", yesterday = "Yesterday", earlier = "Earlier" }

    public let id: String
    public let state: JobState
    /// The repo, the row's title: it wraps before anything truncates.
    public let title: String
    public let location: Chip
    public let locationKind: LocationKind
    /// The tenant whose colour the location chip takes; nil for `local`.
    public let tenant: String?
    public let agent: Agent
    public let stateChip: Chip
    public let branch: String?
    /// `main checkout` when the command ran in no linked worktree; nil for a GitHub job, which has none.
    public let worktree: String?
    public let commit: String?
    public let dirty: Bool
    /// `workflow / job` or the command, in full; the view truncates it in the middle.
    public let command: String
    public let meta: [Part]
    /// Visible without expanding.
    public let actions: [Action]
    public let section: Section
    public let detail: Detail
    /// The day the row belongs to in the recent groups.
    public let settledAt: Date?

    /// What the opened row adds (docs/DESIGN.md, Jobs, Expanded row).
    public struct Detail: Sendable, Equatable {
        public struct Segment: Sendable, Equatable {
            public let label: String
            public let seconds: TimeInterval
        }

        /// Queued, sync, run as a thin bar; a segment that has no measurement is absent.
        public let timeline: [Segment]
        /// `queued 14:12:03` and so on, each with its provenance.
        public let timestamps: [String]
        public let rule: String?
        public let reason: String?
        public let session: String?
        public let url: URL?
        public let canCancel: Bool
        public let isGitHub: Bool

        init(_ job: JobRecord, info: GitHubJobInfo?) {
            var segments: [Segment] = []
            func add(_ label: String, _ from: Date?, _ to: Date?) {
                if let from, let to, to > from { segments.append(Segment(label: label, seconds: to.timeIntervalSince(from))) }
            }
            add("queued", job.queuedAt, job.syncStartedAt ?? job.startedAt ?? job.endedAt)
            add("sync", job.syncStartedAt, job.syncEndedAt)
            add("run", job.boxStartedAt ?? job.startedAt, job.boxEndedAt ?? job.endedAt)
            timeline = segments
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            func stamp(_ label: String, _ date: Date?, _ provenance: String) -> String? { date.map { "\(label) \(formatter.string(from: $0)) (\(provenance))" } }
            var lines = [stamp("queued", job.queuedAt, "mac"), stamp("started", job.startedAt, "mac"), stamp("ended", job.endedAt, "mac"),
                         stamp("box start", job.boxStartedAt, "box"), stamp("box end", job.boxEndedAt, "box")].compactMap { $0 }
            if let offset = job.clockOffsetMS { lines.append("clock offset \(offset) ms") }
            timestamps = lines
            rule = job.rule
            reason = job.fallbackReason
            session = job.session
            url = info?.htmlUrl.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            canCancel = (job.state == .running || job.state == .syncing || job.state == .queued) && info == nil
            isGitHub = info != nil
        }
    }

    public init(_ job: JobRecord, now: Date, lastOutputAt: Date? = nil, waitingFor: String? = nil,
                calendar: Calendar = .current) {
        let info = GitHubJobInfo.decode(job.github)
        id = job.id
        state = job.state
        title = job.repo
        let isLocal = job.location == "local"
        locationKind = info != nil ? .github : isLocal ? .local : .destination
        location = Chip(text: info != nil ? "github" : job.location, tone: isLocal ? .local : .plain)
        tenant = isLocal ? nil : job.tenant
        agent = Agent(job.agent, github: info != nil)
        branch = job.branch
        worktree = info != nil ? nil : (job.worktree.flatMap { $0.isEmpty ? nil : $0 } ?? "main checkout")
        commit = job.commit.map { String($0.prefix(7)) }
        dirty = job.dirty
        command = job.command
        stateChip = Chip(text: job.state.rawValue, tone: Self.tone(job, now: now))
        actions = [.failed, .lost, .cancelled].contains(job.state) ? [.log, .rerun] : []
        section = Self.section(job, now: now, calendar: calendar)
        settledAt = job.endedAt ?? (job.state == .lost ? job.startedAt : nil)
        detail = Detail(job, info: info)
        meta = Self.meta(job, info: info, now: now, lastOutputAt: lastOutputAt, waitingFor: waitingFor)
    }

    static func tone(_ job: JobRecord, now: Date) -> Tone {
        switch job.state {
        case .syncing, .running: .running
        case .queued: now.timeIntervalSince(job.queuedAt) > 60 ? .warn : .unknown
        case .done: .ok
        case .failed, .lost: .crit
        case .cancelled, .skipped: .unknown
        }
    }

    static func section(_ job: JobRecord, now: Date, calendar: Calendar) -> Section {
        switch job.state {
        case .syncing, .running: return .running
        case .queued: return .queued
        default:
            let day = job.endedAt ?? job.startedAt ?? job.queuedAt
            if calendar.isDate(day, inSameDayAs: now) { return .today }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return .yesterday }
            return .earlier
        }
    }

    /// The measured length of a run and where the measurement came from.
    static func duration(_ job: JobRecord, info: GitHubJobInfo?) -> (seconds: TimeInterval, provenance: String)? {
        if let info, let start = info.startedAt, let end = info.completedAt { return (end.timeIntervalSince(start), "github") }
        if let start = job.boxStartedAt, let end = job.boxEndedAt { return (end.timeIntervalSince(start), "box") }
        if let ms = job.macElapsedMS { return (TimeInterval(ms) / 1000, "mac") }
        if let start = job.startedAt, let end = job.endedAt { return (end.timeIntervalSince(start), "mac") }
        return nil
    }

    static func meta(_ job: JobRecord, info: GitHubJobInfo?, now: Date, lastOutputAt: Date?, waitingFor: String?) -> [Part] {
        func part(_ text: String, _ tone: Tone = .plain) -> Part { Part(text: text, tone: tone) }
        func lastOutput() -> Part? {
            guard let lastOutputAt else { return nil }
            let age = now.timeIntervalSince(lastOutputAt)
            return part("last output \(PanelFormat.age(age))", age > 60 ? .warn : .plain)
        }
        switch job.state {
        case .syncing:
            return [part("syncing \(PanelFormat.duration(now.timeIntervalSince(job.syncStartedAt ?? job.queuedAt)))", .running)]
        case .running:
            let elapsed = part(PanelFormat.duration(now.timeIntervalSince(job.startedAt ?? job.queuedAt)), .running)
            var parts = [elapsed]
            if let info, let step = info.currentStep {
                let number = info.currentStepNumber ?? info.stepsDone + 1
                parts.append(part("step \(number)/\(info.stepsTotal) \(step)"))
            }
            if let output = lastOutput() { parts.append(output) }
            return parts
        case .queued:
            if let info { return queued(info, waited: now.timeIntervalSince(job.queuedAt), now: now) }
            if let waitingFor { return [part("waiting for \(waitingFor)", .warn)] }
            return [part("probing \(job.destination ?? job.location)")]
        case .done:
            var parts: [Part] = []
            if let (seconds, provenance) = duration(job, info: info) { parts.append(part("\(PanelFormat.duration(seconds)), \(provenance)", .ok)) }
            if job.warmth != "unknown" { parts.append(part(job.warmth)) }
            return parts
        case .failed, .lost, .cancelled:
            var parts = [part(outcome(job), .crit)]
            if let (seconds, provenance) = duration(job, info: info) { parts.append(part("\(PanelFormat.duration(seconds)), \(provenance)")) }
            if let reason = job.fallbackReason { parts.append(part("local: \(reason)", .local)) }
            if job.environment == "mac" { parts.append(part("environment: mac", .local)) }
            return parts
        case .skipped:
            return [part(info?.conclusion ?? "skipped")]
        }
    }

    static func outcome(_ job: JobRecord) -> String {
        switch job.state {
        case .lost: "lost: destination unreachable"
        case .cancelled: "cancelled"
        default: job.exitCode.map { "failed, exit \($0)" } ?? "failed"
        }
    }

    static func queued(_ info: GitHubJobInfo, waited: TimeInterval, now: Date) -> [Part] {
        var parts = [Part(text: "waiting \(PanelFormat.wait(waited))", tone: waited > 60 ? .warn : .plain)]
        if !info.labels.isEmpty { parts.append(Part(text: info.labels.joined(separator: ", "), tone: .plain)) }
        if info.waitingOnDependency {
            parts.append(Part(text: "waiting on another job", tone: .plain))
        } else if let observation = info.observation {
            // The summary names the registrations in parentheses; the cause carries the one that matters.
            let counts = observation.summary.components(separatedBy: " (").first ?? observation.summary
            parts.append(Part(text: "\(counts), observed \(PanelFormat.wait(now.timeIntervalSince(observation.observedAt))) ago", tone: .plain))
            if observation.suspectedCause == "unknown" {
                parts.append(Part(text: "cause unknown", tone: .plain))
            } else {
                let name = observation.suspectedCause == "stale registration" ? observation.matches.first.map { " \($0.name.prefix(4))..." } : nil
                parts.append(Part(text: observation.suspectedCause + (name ?? ""), tone: .warn))
            }
        }
        return parts
    }
}

public extension Sequence where Element == JobRecord {
    /// Rows grouped in the Jobs tab's order, each group newest first.
    func panelRows(now: Date, lastOutput: [String: Date] = [:], waitingFor: [String: String] = [:],
                   calendar: Calendar = .current) -> [(JobRowPresentation.Section, [JobRowPresentation])] {
        let rows = sorted { $0.queuedAt > $1.queuedAt }.map { JobRowPresentation($0, now: now, lastOutputAt: lastOutput[$0.id], waitingFor: waitingFor[$0.id], calendar: calendar) }
        return JobRowPresentation.Section.allCases.compactMap { section in
            let inSection = rows.filter { $0.section == section }
            return inSection.isEmpty ? nil : (section, inSection)
        }
    }
}
