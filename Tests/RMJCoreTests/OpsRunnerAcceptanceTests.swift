import Testing
import Foundation
import RMJCore

private let u6RunnerName = "runner-ledger"
private let u6Registration = GitHubRunner(id: 77, name: "abc123abc123-1790000000", online: true, busy: true, labels: ["ai-eu-1"])

private func u6RunnerShell(finishesAfter: Int? = nil) -> FakeShell {
    FakeShell { script, count in
        if script.contains("docker ps -a") {
            return u6Output("runner-ledger\tabc123abc123\tgh-runner:2.338.2\trunning\tUp 1 hour\n")
        }
        if script.contains("docker inspect -f") { return u6Output(finishesAfter.map { count >= $0 ? "false" : "true" } ?? "true") }
        return u6Output()
    }
}

private func u6Operations(_ shell: FakeShell, ledger: Ledger, busy: Bool = true,
                          timeout: Duration = .seconds(100),
                          cancel: @escaping @Sendable (String) async throws -> Void = { _ in }) -> RunnerOperations {
    RunnerOperations(shell: shell, home: "/home/fixture", registrations: {
        var runner = u6Registration
        runner.busy = busy
        return [runner]
    }, ledger: ledger, cancelJob: cancel, sleep: { _ in }, drainTimeout: timeout)
}

private func u6Mutations(_ shell: FakeShell) -> [String] {
    shell.calls.map(\.script).filter { script in
        ["docker stop ", "docker restart ", "docker start ", "docker compose ", "docker update "].contains { script.contains($0) }
    }
}

struct OpsRunnerAcceptanceTests {
    @Test func busyRunnerRefusesEveryOperationAndNamesKnownJob() async throws {
        let f = try U6Fixture(); defer { f.remove() }
        let row = f.job("gh-77-1", github: true)
        #expect(GitHubJobInfo.decode(row.github)?.runnerName == u6Registration.name)
        try await f.ledger.insert(row)
        for operation in [RunnerOperation.stop, .restart, .recreate, .start] {
            let shell = u6RunnerShell()
            do {
                try await u6Operations(shell, ledger: f.ledger).perform(operation, runner: u6RunnerName, choice: .refuse)
                Issue.record("Busy runner accepted \(operation)")
            } catch let error as RunnerBusy {
                #expect(error.runner == u6RunnerName)
                #expect(error.job == "gh-77-1")
                #expect(error.description.contains("gh-77-1"))
            }
            #expect(u6Mutations(shell).isEmpty)
        }
        let empty = try U6Fixture(); defer { empty.remove() }
        let shell = u6RunnerShell()
        do {
            try await u6Operations(shell, ledger: empty.ledger).perform(.stop, runner: u6RunnerName)
            Issue.record("Unknown busy job was accepted")
        } catch let error as RunnerBusy {
            #expect(error.runner == u6RunnerName && error.job == nil)
        }
        #expect(u6Mutations(shell).isEmpty)
    }

    @Test func idleRunnerPerformsEachOperationAndUnknownNamesNeverMutate() async throws {
        let f = try U6Fixture(); defer { f.remove() }
        for (operation, command) in [
            (RunnerOperation.stop, "docker stop 'runner-ledger'"),
            (.restart, "docker restart 'runner-ledger'"),
            (.recreate, "cd '/home/fixture/infra/gh-runners' && docker compose up -d --force-recreate 'runner-ledger'"),
            (.start, "docker start 'runner-ledger'")
        ] {
            let shell = u6RunnerShell()
            try await u6Operations(shell, ledger: f.ledger, busy: false).perform(operation, runner: u6RunnerName)
            #expect(u6Mutations(shell) == [command])
        }
        for name in ["missing-runner", "runner-ledger; touch /tmp/injected"] {
            let shell = u6RunnerShell()
            await #expect(throws: RunnerOperations.Failure.unknownRunner(name)) {
                try await u6Operations(shell, ledger: f.ledger).perform(.start, runner: name)
            }
            #expect(u6Mutations(shell).isEmpty)
            #expect(shell.calls.allSatisfy { $0.script.contains("docker ps -a") })
        }
    }

    @Test func drainWaitsForExitBeforeRecreateAndStopNeedsNoStopCommand() async throws {
        let f = try U6Fixture(); defer { f.remove() }
        try await f.ledger.insert(f.job("gh-77-1", github: true))
        for operation in [RunnerOperation.stop, .recreate] {
            let shell = u6RunnerShell(finishesAfter: 3)
            try await u6Operations(shell, ledger: f.ledger).perform(operation, runner: u6RunnerName, choice: .drain)
            let scripts = shell.calls.map(\.script)
            let disable = try #require(scripts.firstIndex { $0.contains("docker update --restart=no ") })
            let polls = scripts.indices.filter { scripts[$0].contains("docker inspect -f") }
            #expect(polls.count == 3)
            let first = try #require(polls.first)
            let last = try #require(polls.last)
            #expect(disable < first)
            #expect(!scripts.contains { $0.contains("docker stop ") })
            if operation == .stop {
                #expect(u6Mutations(shell) == ["docker update --restart=no 'runner-ledger'"])
            } else {
                let restore = try #require(scripts.firstIndex { $0.contains("docker update --restart=unless-stopped ") })
                let recreate = try #require(scripts.firstIndex { $0.contains("docker compose up -d --force-recreate ") })
                #expect(last < restore && restore < recreate)
                #expect(scripts[recreate].contains("cd '/home/fixture/infra/gh-runners'"))
            }
        }
        let stuck = u6RunnerShell()
        await #expect(throws: RunnerOperations.Failure.drainTimedOut(u6RunnerName)) {
            try await u6Operations(stuck, ledger: f.ledger, timeout: .seconds(20))
                .perform(.recreate, runner: u6RunnerName, choice: .drain)
        }
        #expect(stuck.calls.filter { $0.script.contains("docker inspect -f") }.count == 2)
        #expect(!stuck.calls.contains { $0.script.contains("--force-recreate") || $0.script.contains("--restart=unless-stopped") })
    }

    @Test func cancelKnownJobPrecedesEveryRunnerOperation() async throws {
        let f = try U6Fixture(); defer { f.remove() }
        try await f.ledger.insert(f.job("gh-77-1", github: true))
        for operation in RunnerOperation.allCases {
            let shell = u6RunnerShell()
            let cancelled = U6Messages()
            let ops = u6Operations(shell, ledger: f.ledger, cancel: { id in
                #expect(u6Mutations(shell).isEmpty)
                cancelled.append(id)
            })
            try await ops.perform(operation, runner: u6RunnerName, choice: .cancel)
            #expect(cancelled.values == ["gh-77-1"])
            #expect(u6Mutations(shell).count == 1)
            let expected = operation == .recreate ? "docker compose up -d --force-recreate" : "docker \(operation.rawValue) "
            #expect(u6Mutations(shell).first?.contains(expected) == true)
        }
    }
}
