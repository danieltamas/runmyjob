import Foundation

/// A one-shot runner started by RMJ on top of a box's static runners.
public struct ScaleBurst: Sendable, Equatable {
    public var name: String
    public var target: String
    public var ageSeconds: Double
    /// nil: not registered with GitHub yet; false: online and idle; true: running a job.
    public var busy: Bool?

    public init(name: String, target: String, ageSeconds: Double, busy: Bool?) {
        self.name = name
        self.target = target
        self.ageSeconds = ageSeconds
        self.busy = busy
    }
}

public struct ScaleBox: Sendable, Equatable {
    public var name: String
    /// The box's `runner_targets`: the tenant check of rules validation already ties them to the box's tenant.
    public var targets: [String]
    public var cpus: Int
    public var load1: Double
    public var memoryBudgetBytes: Int64
    public var memoryCommittedBytes: Int64
    /// Reachable, with a probe fresh enough to trust.
    public var online: Bool
    public var bursts: [ScaleBurst]

    public init(name: String, targets: [String], cpus: Int, load1: Double, memoryBudgetBytes: Int64, memoryCommittedBytes: Int64,
                online: Bool, bursts: [ScaleBurst] = []) {
        self.name = name
        self.targets = targets
        self.cpus = cpus
        self.load1 = load1
        self.memoryBudgetBytes = memoryBudgetBytes
        self.memoryCommittedBytes = memoryCommittedBytes
        self.online = online
        self.bursts = bursts
    }
}

public struct ScaleDemand: Sendable, Equatable {
    public var target: String
    /// One entry per queued job the target's runners can serve: how long it has waited.
    public var waitingSeconds: [Double]
    /// Online, not busy runners registered for the target, static and burst, on any box.
    public var idleRunners: Int

    public init(target: String, waitingSeconds: [Double], idleRunners: Int) {
        self.target = target
        self.waitingSeconds = waitingSeconds
        self.idleRunners = idleRunners
    }
}

public enum ScaleAction: Sendable, Equatable {
    case start(box: String, target: String)
    case stop(box: String, container: String)
}

/// Decides how many idle runners each box offers. GitHub hands a job to whichever idle runner asks first, so RMJ cannot route a
/// job; it starts burst runners on the box with the most headroom while jobs wait with no idle runner, and stops idle ones when
/// the queue is empty. A burst for a target only goes to a box that lists the target, so two companies never mix.
public struct RunnerScaler: Sendable {
    public var burstCap = 3
    public var runnerMemoryBytes: Int64 = 8 * 1_073_741_824
    public var runnerCPUs = 4
    /// A job younger than this still gets the idle static runner.
    public var minWaitSeconds = 20.0
    public var idleGraceSeconds = 60.0
    public var unregisteredLimitSeconds = 180.0
    public var loadCeiling = 0.9

    public init() {}

    public func plan(boxes: [ScaleBox], demand: [ScaleDemand]) -> [ScaleAction] {
        stops(boxes: boxes, demand: demand) + starts(boxes: boxes, demand: demand)
    }

    private func stops(boxes: [ScaleBox], demand: [ScaleDemand]) -> [ScaleAction] {
        var actions = [ScaleAction]()
        for box in boxes where box.online {
            for burst in box.bursts.sorted(by: { $0.name < $1.name }) {
                switch burst.busy {
                case .some(true):
                    continue
                case .some(false):
                    let waiting = demand.contains { Self.same($0.target, burst.target) && !$0.waitingSeconds.isEmpty }
                    if burst.ageSeconds >= idleGraceSeconds, !waiting { actions.append(.stop(box: box.name, container: burst.name)) }
                case nil:
                    if burst.ageSeconds >= unregisteredLimitSeconds { actions.append(.stop(box: box.name, container: burst.name)) }
                }
            }
        }
        return actions
    }

    /// What a box would carry after the starts already picked in this call.
    private struct Placement { var planned = 0, committed: Int64, count: Int }

    private func starts(boxes: [ScaleBox], demand: [ScaleDemand]) -> [ScaleAction] {
        var placements = Dictionary(uniqueKeysWithValues: boxes.map { ($0.name, Placement(committed: $0.memoryCommittedBytes, count: $0.bursts.count)) })
        var actions = [ScaleAction]()
        for entry in demand {
            let waiting = entry.waitingSeconds.filter { $0 >= minWaitSeconds }.count
            let pending = boxes.flatMap(\.bursts).filter { Self.same($0.target, entry.target) && $0.busy == nil && $0.ageSeconds < unregisteredLimitSeconds }.count
            var need = waiting - entry.idleRunners - pending
            while need > 0, let pick = best(for: entry.target, boxes: boxes, placements: placements) {
                actions.append(.start(box: pick, target: entry.target))
                placements[pick]?.planned += 1
                placements[pick]?.committed += runnerMemoryBytes
                placements[pick]?.count += 1
                need -= 1
            }
        }
        return actions
    }

    private func best(for target: String, boxes: [ScaleBox], placements: [String: Placement]) -> String? {
        var best: (name: String, score: Double, free: Int64)?
        for box in boxes where box.online && box.cpus > 0 && box.targets.contains(where: { Self.same($0, target) }) {
            guard let placement = placements[box.name], placement.count < burstCap else { continue }
            let free = box.memoryBudgetBytes - placement.committed
            let load = box.load1 + Double(placement.planned * runnerCPUs)
            guard free >= runnerMemoryBytes, box.load1 / Double(box.cpus) < loadCeiling else { continue }
            let score = load / Double(box.cpus)
            if let current = best, (current.score, -current.free, current.name) <= (score, -free, box.name) { continue }
            best = (box.name, score, free)
        }
        return best?.name
    }

    static func same(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }
}
