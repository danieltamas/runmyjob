import Foundation

public struct ScalingBox: Sendable {
    public var state: ScaleBox
    public var runners: BurstRunners

    public init(state: ScaleBox, runners: BurstRunners) {
        self.state = state
        self.runners = runners
    }
}

public struct ScaleOutcome: Sendable, Equatable {
    public var action: ScaleAction
    public var succeeded: Bool
    public var detail: String
}

/// One round of the autoscaler: plan, then act. A failed action is reported and the round goes on.
public struct RunnerScaling: Sendable {
    private let planner: RunnerScaler

    public init(planner: RunnerScaler = RunnerScaler()) {
        self.planner = planner
    }

    public func round(boxes: [ScalingBox], demand: [ScaleDemand], tokens: @Sendable (String) -> String?, log: @Sendable (String) -> Void) async -> [ScaleOutcome] {
        let actions = planner.plan(boxes: boxes.map(\.state), demand: demand)
        var outcomes = [ScaleOutcome]()
        for action in actions {
            let outcome: ScaleOutcome
            switch action {
            case .start(let box, let target):
                guard let runners = boxes.first(where: { $0.state.name == box })?.runners else { continue }
                guard let token = tokens(target) else {
                    outcome = ScaleOutcome(action: action, succeeded: false, detail: "no PAT for \(target)")
                    break
                }
                do {
                    let name = try await runners.start(target: target, token: token)
                    outcome = ScaleOutcome(action: action, succeeded: true, detail: name)
                } catch {
                    outcome = ScaleOutcome(action: action, succeeded: false, detail: Self.detail(error, hiding: token))
                }
            case .stop(let box, let container):
                guard let runners = boxes.first(where: { $0.state.name == box })?.runners else { continue }
                do {
                    try await runners.stop(container: container)
                    outcome = ScaleOutcome(action: action, succeeded: true, detail: container)
                } catch {
                    outcome = ScaleOutcome(action: action, succeeded: false, detail: Self.detail(error, hiding: ""))
                }
            }
            outcomes.append(outcome)
            log(Self.line(outcome))
        }
        return outcomes
    }

    private static func detail(_ error: Error, hiding secret: String) -> String {
        var text = String(describing: error)
        if !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "***") }
        return UntrustedText.clean(text, limit: 200)
    }

    private static func line(_ outcome: ScaleOutcome) -> String {
        switch outcome.action {
        case .start(let box, let target): return "start \(target) on \(box)\(outcome.succeeded ? " as \(outcome.detail)" : "")"
        case .stop(let box, let container): return "stop \(container) on \(box)"
        }
    }
}
