import Foundation

public enum RunnerOperation: String, Sendable, CaseIterable { case start, stop, restart, recreate }

/// What to do when the runner is busy: refuse (the default), let the job finish and then act (drain), or
/// cancel the GitHub job first.
public enum BusyChoice: Sendable, Equatable { case refuse, drain, cancel }

public struct RunnerBusy: Error, Equatable, CustomStringConvertible {
    public let runner: String
    /// The ledger id of the job it is running, when RMJ knows it.
    public let job: String?
    public var description: String {
        "\(runner) is busy" + (job.map { " running job \($0)" } ?? " with a job RMJ has not recorded") + "; drain it or cancel the job"
    }
}

/// start, stop, restart and recreate of the stack's runner containers. A busy runner is never touched unless asked to drain or cancel.
public struct RunnerOperations: Sendable {
    public enum Failure: Error, Equatable { case unknownRunner(String), drainTimedOut(String), remote(String) }

    private let shell: OpsShell
    private let stackDirectory: String
    private let registrations: @Sendable () async throws -> [GitHubRunner]
    private let ledger: Ledger
    private let cancelJob: @Sendable (String) async throws -> Void
    private let sleep: @Sendable (Duration) async -> Void
    private let drainTimeout: Duration

    /// `registrations` lists the runners of every target the destination serves; `cancelJob` takes a ledger job id.
    public init(shell: OpsShell, home: String, registrations: @escaping @Sendable () async throws -> [GitHubRunner], ledger: Ledger,
                cancelJob: @escaping @Sendable (String) async throws -> Void = { _ in throw Failure.remote("no way to cancel a GitHub job was provided") },
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                drainTimeout: Duration = .seconds(4 * 3600)) {
        self.shell = shell
        self.stackDirectory = "\(home)/infra/gh-runners"
        self.registrations = registrations
        self.ledger = ledger
        self.cancelJob = cancelJob
        self.sleep = sleep
        self.drainTimeout = drainTimeout
    }

    public func perform(_ operation: RunnerOperation, runner name: String, choice: BusyChoice = .refuse) async throws {
        try await perform(operation, validated: name, choice: choice)
    }

    private func perform(_ operation: RunnerOperation, validated name: String, choice: BusyChoice) async throws {
        let containers = try await RunnerContainer.list(shell: shell)
        guard let container = containers.first(where: { $0.name == name }) else { throw Failure.unknownRunner(name) }
        var restorePolicy = false
        if container.isRunning, let busy = try await busyRegistration(of: container) {
            let job = try await runningJob(runnerName: busy.name)
            switch choice {
            case .refuse: throw RunnerBusy(runner: name, job: job)
            case .cancel:
                // Cancelling needs a job to cancel: with none recorded the runner stays as it is.
                guard let job else { throw RunnerBusy(runner: name, job: nil) }
                try await cancelJob(job)
            case .drain:
                try await drain(container)
                restorePolicy = operation != .stop
                // A drained runner has exited; stop is done, the rest continue below.
                if operation == .stop { return }
            }
        }
        if restorePolicy { try await run("docker update --restart=unless-stopped \(SSH.quote(name))") }
        switch operation {
        case .start: try await run("docker start \(SSH.quote(name))")
        case .stop: try await run("docker stop \(SSH.quote(name))")
        case .restart: try await run("docker restart \(SSH.quote(name))")
        case .recreate: try await run("cd \(SSH.quote(stackDirectory)) && docker compose up -d --force-recreate \(SSH.quote(name))")
        }
    }

    private func busyRegistration(of container: RunnerContainer) async throws -> GitHubRunner? {
        try await registrations().first { $0.busy && $0.name.hasPrefix(container.id + "-") }
    }

    private func runningJob(runnerName: String) async throws -> String? {
        try await ledger.jobs(in: [.running]).first { GitHubJobInfo.decode($0.github)?.runnerName == runnerName }?.id
    }

    /// Stops the runner from restarting, then waits for its current job (the ephemeral runner exits when it ends).
    private func drain(_ container: RunnerContainer) async throws {
        try await run("docker update --restart=no \(SSH.quote(container.name))")
        var waited = Duration.zero
        while waited < drainTimeout {
            let output = try await shell.run("docker inspect -f '{{.State.Running}}' \(SSH.quote(container.name))", input: nil, timeout: .seconds(30))
            if String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "false" { return }
            await sleep(.seconds(10))
            waited += .seconds(10)
        }
        throw Failure.drainTimedOut(container.name)
    }

    private func run(_ script: String) async throws {
        let output = try await shell.run(script, input: nil, timeout: .seconds(600))
        guard output.status == 0 else { throw Failure.remote(GitHubText.clean(output.stderr, limit: 300)) }
    }
}
