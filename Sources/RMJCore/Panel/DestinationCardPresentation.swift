import Foundation

/// What a Destinations card says (docs/DESIGN.md, Destinations), decided here so the rules are tested without a view.
/// A destination is never `ok` on a guess: a measurement older than its poll interval is marked stale with its
/// last-success time, and an offline card keeps only the actions that do not need the box.
public struct DestinationCardInput: Sendable {
    public struct Runner: Sendable, Equatable {
        public var container: RunnerContainer
        /// The job it runs now, from its registration.
        public var job: String?
        /// `registered`, `registration failed: <error>`, `PAT lacks permission`.
        public var readiness: String
        public var busy: Bool
        public var cpu: String?
        public var memory: String?

        public init(container: RunnerContainer, job: String? = nil, readiness: String = "registered", busy: Bool = false,
                    cpu: String? = nil, memory: String? = nil) {
            self.container = container
            self.job = job
            self.readiness = readiness
            self.busy = busy
            self.cpu = cpu
            self.memory = memory
        }
    }

    public var name: String
    public var config: DestinationConfig
    public var availability: Availability
    public var probe: DestinationProbeResult?
    public var runners: [Runner]
    public var staleRegistrations: Int
    /// The newest runner release and the date it stays served until, when known.
    public var latestRunner: (version: String, servedUntil: String?)?
    public var rxJobs: [JobRecord]
    public var images: [String]
    public var pollInterval: TimeInterval

    public init(name: String, config: DestinationConfig, availability: Availability, probe: DestinationProbeResult? = nil,
                runners: [Runner] = [], staleRegistrations: Int = 0, latestRunner: (version: String, servedUntil: String?)? = nil,
                rxJobs: [JobRecord] = [], images: [String] = [], pollInterval: TimeInterval = 30) {
        self.name = name
        self.config = config
        self.availability = availability
        self.probe = probe
        self.runners = runners
        self.staleRegistrations = staleRegistrations
        self.latestRunner = latestRunner
        self.rxJobs = rxJobs
        self.images = images
        self.pollInterval = pollInterval
    }
}

public struct DestinationCardPresentation: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable { case prune = "Prune", rebuild = "Rebuild", logs = "Cached logs" }

    public struct Line: Sendable, Equatable {
        public let label: String
        public let value: String
        public let tone: JobRowPresentation.Tone
        /// `as of 14:43` when the reading is older than its poll interval.
        public let stale: String?
    }

    public struct RunnerLine: Sendable, Equatable {
        public let name: String
        public let version: String
        public let detail: String
        public let state: String
        public let tone: JobRowPresentation.Tone
    }

    public struct ActionState: Sendable, Equatable {
        public let action: Action
        public let available: Bool
        /// Why it is unavailable: shown in its place.
        public let reason: String?
    }

    public let name: String
    public let tenant: String
    public let roles: [String]
    public let state: JobRowPresentation.Chip
    public let capacity: [Line]
    public let rxContainers: [String]
    public let runners: [RunnerLine]
    public let images: [Line]
    /// Programs the destination requires that the last probe did not find on the box.
    public let missingPrograms: [String]
    public let lastProbe: String
    public let actions: [ActionState]

    public init(_ input: DestinationCardInput, now: Date) {
        name = input.name
        tenant = input.config.tenant
        roles = input.config.roles
        state = Self.stateChip(input, now: now)
        let online = input.availability.isAvailable
        let stale = Self.staleMarker(input, now: now)
        capacity = online || input.probe != nil ? Self.capacity(input, stale: stale) : []
        rxContainers = input.rxJobs.filter { $0.state == .running || $0.state == .syncing }.map(\.id)
        runners = input.runners.map { Self.runnerLine($0, latest: input.latestRunner) }
        images = input.images.map { Line(label: $0, value: "", tone: .plain, stale: nil) }
        missingPrograms = input.probe?.missingPrograms ?? []
        lastProbe = input.probe.map { "probed \(PanelFormat.age(now.timeIntervalSince($0.probedAt)))" } ?? "never probed"
        let reason = Self.offlineReason(input.availability)
        actions = [
            ActionState(action: .prune, available: true, reason: nil),
            ActionState(action: .logs, available: true, reason: nil),
            ActionState(action: .rebuild, available: online, reason: online ? nil : reason),
        ]
    }

    static func stateChip(_ input: DestinationCardInput, now: Date) -> JobRowPresentation.Chip {
        switch input.availability {
        case .online:
            if let probe = input.probe, let note = recentReboot(probe, now: now) { return .init(text: note, tone: .warn) }
            return .init(text: "online", tone: .ok)
        case .offline(let why): return .init(text: why.hasPrefix("tailnet down") ? "tailnet down" : "offline: \(why)", tone: .unknown)
        case .unreachable(let why): return .init(text: "unreachable: \(why)", tone: .unknown)
        case .rejected(let why): return .init(text: "rejected: \(why)", tone: .crit)
        }
    }

    static func recentReboot(_ probe: DestinationProbeResult, now: Date) -> String? {
        guard let uptime = probe.uptime, uptime < 3_600 else { return nil }
        return "rebooted \(PanelFormat.wait(uptime)) ago"
    }

    static func offlineReason(_ availability: Availability) -> String? {
        switch availability {
        case .online: nil
        case .offline(let why), .unreachable(let why), .rejected(let why): why
        }
    }

    static func staleMarker(_ input: DestinationCardInput, now: Date) -> String? {
        guard let probe = input.probe, now.timeIntervalSince(probe.probedAt) > input.pollInterval else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "as of \(formatter.string(from: probe.probedAt))"
    }

    static func capacity(_ input: DestinationCardInput, stale: String?) -> [Line] {
        var lines: [Line] = []
        let maxJobs = input.config.maxJobs
        let rx = input.probe?.containers.value.map { $0.filter { !$0.name.hasPrefix("runner-") }.count } ?? input.rxJobs.count
        lines.append(Line(label: "rx slots", value: "\(rx) of \(maxJobs)", tone: rx >= maxJobs ? .warn : .plain, stale: stale))
        if let budget = MemorySize.parse(input.config.memoryBudget), let containers = input.probe?.containers.value {
            let used = committed(containers)
            lines.append(Line(label: "memory budget", value: "\(gigabytes(used)) of \(gigabytes(budget.bytes))",
                              tone: used > budget.bytes ? .warn : .plain, stale: stale))
        }
        if let cores = input.probe?.cores { lines.append(Line(label: "cpu", value: "\(cores) cores", tone: .plain, stale: stale)) }
        if let load = input.probe?.load { lines.append(Line(label: "load", value: String(format: "%.1f", load), tone: .plain, stale: stale)) }
        if let free = input.probe?.memoryFreeMB { lines.append(Line(label: "free memory", value: "\(gigabytes(Int64(free) * 1_048_576))", tone: .plain, stale: stale)) }
        return lines
    }

    /// rx containers count at their limit, runner containers at what they use now (the router's rule).
    static func committed(_ containers: [ContainerSample]) -> Int64 {
        containers.reduce(0) { total, container in
            let parts = container.memory.split(separator: "/").map { MemorySize.parse($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 else { return total }
            return total + ((container.name.hasPrefix("runner-") ? parts[0] : parts[1])?.bytes ?? 0)
        }
    }

    static func gigabytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return value >= 10 ? "\(Int(value.rounded())) GB" : String(format: "%.1f GB", value)
    }

    static func runnerLine(_ runner: DestinationCardInput.Runner, latest: (version: String, servedUntil: String?)?) -> RunnerLine {
        let version = runner.container.version ?? "unknown"
        var detail = "version \(version)"
        if let latest, latest.version != version {
            detail += ", latest \(latest.version)" + (latest.servedUntil.map { ", served until \($0)" } ?? "")
        }
        if let job = runner.job { detail += ", job \(job)" }
        let usage = [runner.cpu, runner.memory].compactMap { $0 }.joined(separator: " ")
        if !usage.isEmpty { detail += ", \(usage)" }
        let failed = runner.readiness != "registered"
        let state = failed ? runner.readiness : runner.busy ? "busy" : runner.container.isRunning ? "online" : runner.container.state
        let tone: JobRowPresentation.Tone = failed ? .crit : runner.busy ? .running : runner.container.isRunning ? .ok : .unknown
        return RunnerLine(name: runner.container.name, version: version, detail: detail, state: state, tone: tone)
    }
}
