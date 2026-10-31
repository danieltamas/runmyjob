import Foundation
import Testing
@testable import RMJCore

private func burstOutput(_ text: String = "", status: Int32 = 0, stderr: String = "") -> ProcessOutput {
    ProcessOutput(status: status, stdout: Data(text.utf8), stderr: stderr)
}

private final class BurstShell: OpsShell, @unchecked Sendable {
    struct Call: Sendable { let script: String; let input: Data? }
    private let lock = NSLock()
    private var storage: [Call] = []
    let answer: @Sendable (Int) throws -> ProcessOutput
    init(answer: @escaping @Sendable (Int) throws -> ProcessOutput = { _ in burstOutput() }) {
        self.answer = answer
    }
    var calls: [Call] { lock.withLock { storage } }
    func run(_ script: String, input: Data?, timeout: Duration) async throws -> ProcessOutput {
        let index = lock.withLock { storage.append(Call(script: script, input: input)); return storage.count }
        return try answer(index)
    }
    func sync(directory: URL, to remote: String) async throws { Issue.record("Unexpected sync") }
}

private final class BurstLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    func append(_ line: String) { lock.withLock { storage.append(line) } }
}

private struct BurstTransportError: Error, CustomStringConvertible {
    let description: String
}

private let burstPAT = "github_pat_BurstFixture123"
private let burstTarget = "danieltamas/lexito.ro"

// Shell syntax is inspected without executing it. Ignore quoting of these plain, space-free arguments.
private func burstWords(_ script: String) -> [String] {
    script.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
        .replacingOccurrences(of: "\\\n", with: " ").split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

private func burstExecutor(_ shell: BurstShell, labels: [String: [String]] = [:]) -> BurstRunners {
    BurstRunners(shell: shell, home: "/home/fixture", host: "fixture-box", version: "2.338.2", labels: labels)
}

private func burstName(_ script: String) throws -> String {
    let words = burstWords(script)
    let index = try #require(words.firstIndex(of: "--name"))
    return try #require(words.dropFirst(index + 1).first)
}

private func burstState(_ bursts: [ScaleBurst] = []) -> ScaleBox {
    ScaleBox(name: "fixture-box", targets: [burstTarget], cpus: 16, load1: 0,
             memoryBudgetBytes: 64 * 1_073_741_824, memoryCommittedBytes: 0, online: true, bursts: bursts)
}

private func expectCleanBurstText(_ text: String) {
    #expect(!text.contains(burstPAT))
    #expect(!text.contains("\n") && !text.contains("\r"))
    #expect(!text.contains("\u{001B}") && !text.contains("\u{200B}"))
}

struct BurstRunnersAcceptanceTests {
    @Test func startPinsResourcesNetworkImageScopeLabelsAndStdinOnlyPAT() async throws {
        for (target, scope, path, slug, label) in [
            (burstTarget, "repo", burstTarget, "danieltamas-lexito-ro", "lexito-ro"),
            ("org:Gamerina", "org", "Gamerina", "org-gamerina", "gamerina"),
            ("Owner/My..Repo", "repo", "Owner/My..Repo", "owner-my-repo", "my--repo")
        ] {
            let shell = BurstShell()
            let extras = [label, "custom", "custom", "invalid label", "_invalid", "Custom"]
            let runner = burstExecutor(shell, labels: [target: extras])
            let name = try await runner.start(target: target, token: burstPAT)
            #expect(shell.calls.count == 1)
            let call = try #require(shell.calls.first)
            #expect(call.input == Data("GH_PAT=\(burstPAT)\n".utf8))
            #expect(!call.script.contains(burstPAT) && !name.contains(burstPAT))
            #expect(name.range(of: "^burst-\(slug)-[0-9a-f]{6}$", options: .regularExpression) != nil)
            #expect(try burstName(call.script) == name)
            #expect(call.script.contains("while IFS='=' read -r name value; do export \"$name=$value\"; done"))
            let words = burstWords(call.script)
            let flat = words.joined(separator: " ")
            for argument in ["docker run -d --rm", "--name \(name)", "--label rmj.burst=\(target)",
                             "--network gh-runners_ci", "--cpus 4", "--memory 8g", "--pids-limit 2048",
                             "--security-opt no-new-privileges:true", "-e RUNNER_SCOPE=\(scope)",
                             "-e RUNNER_TARGET=\(path)", "-e RUNNER_LABELS_BASE=self-hosted,linux,x64,fixture-box",
                             "-e RUNNER_LABELS=\(label),custom,Custom", "-e GH_PAT", "gh-runner:2.338.2"] {
                #expect(flat.contains(argument), "Missing required argument: \(argument)")
            }
            #expect(!flat.contains("-e GH_PAT="))
            #expect(!flat.contains("--restart"))
            let compose = RunnerCompose(base: "", targets: [target], host: "fixture-box", labels: [target: extras])
            #expect(compose.generated?.contains("RUNNER_LABELS: \(label),custom,Custom") == true)
            #expect(RunnerCompose.runnerLabels(service: "runner-\(label)", extras: extras) == "\(label),custom,Custom")
        }
    }

    @Test func invalidTargetAndTokenNeverReachShell() async throws {
        for target in ["", "owner", "owner/repo/extra", "org:", "org:bad/name", "owner/repo;id", "owner/$(id)", "a/b\n"] {
            let shell = BurstShell()
            await #expect(throws: (any Error).self) {
                _ = try await burstExecutor(shell).start(target: target, token: burstPAT)
            }
            #expect(shell.calls.isEmpty)
        }
        for token in ["", "bad token", "bad\ntoken", "bad\rtoken", "bad\ttoken", "bad=value"] {
            let shell = BurstShell()
            await #expect(throws: RunnerStackDeployer.Failure.badToken(burstTarget)) {
                _ = try await burstExecutor(shell).start(target: burstTarget, token: token)
            }
            #expect(shell.calls.isEmpty)
        }
    }

    @Test func failingStartReturnsCleanRemoteFailureWithoutEchoedPAT() async throws {
        let shell = BurstShell { _ in
            burstOutput(burstPAT, status: 1, stderr: "\u{001B}[31mfailed \(burstPAT)\u{200B}\nsecond line")
        }
        do {
            _ = try await burstExecutor(shell).start(target: burstTarget, token: burstPAT)
            Issue.record("Expected start failure")
        } catch let error as RunnerStackDeployer.Failure {
            guard case .remote(let detail) = error else { Issue.record("Expected remote failure"); return }
            expectCleanBurstText(detail)
            expectCleanBurstText(error.description)
            #expect(!detail.isEmpty)
        }
        #expect(shell.calls.count == 1)
        #expect(shell.calls.allSatisfy { !$0.script.contains(burstPAT) })
    }

    @Test func stopAcceptsOnlyOwnedNameShapeAndUsesNoInput() async throws {
        let shell = BurstShell()
        let runner = burstExecutor(shell)
        for invalid in ["runner-lexito-ro", "burst-x-ABCDEF", "burst-x-abcde", "burst-x-abcdef0",
                        "burst-x-abcdef;id", "burst-x-abcdef\n", "burst-X-abcdef", "burst-abcdef", ""] {
            await #expect(throws: (any Error).self) { try await runner.stop(container: invalid) }
        }
        #expect(shell.calls.isEmpty)
        try await runner.stop(container: "burst-lexito-ro-abcdef")
        #expect(shell.calls.count == 1)
        #expect(burstWords(try #require(shell.calls.first).script).joined(separator: " ") ==
                "docker rm -f burst-lexito-ro-abcdef")
        #expect(shell.calls.first?.input == nil)
        let failed = BurstShell { _ in burstOutput(status: 1, stderr: "\u{001B}[31mdenied\nextra") }
        do {
            try await burstExecutor(failed).stop(container: "burst-lexito-ro-abcdef")
            Issue.record("Expected stop failure")
        } catch let error as RunnerStackDeployer.Failure {
            guard case .remote(let detail) = error else { Issue.record("Expected remote failure"); return }
            expectCleanBurstText(detail)
        }
    }

    @Test func listPinsRemoteEpochTabSchemaExitedRowsAndNonnegativeDoubleAge() async throws {
        let shell = BurstShell { _ in burstOutput("""
        now=1000
        burst-lexito-ro-aaaaaa\tid1\tdanieltamas/lexito.ro\t900\trunning
        burst-gamerina-bbbbbb\tid2\torg:Gamerina\t999\texited
        burst-future-cccccc\tid3\torg:Gamerina\t1001\trunning
        runner-floor\tid4\torg:Gamerina\t900\trunning
        malformed
        burst-bad-dddddd\tid5\torg:Gamerina\tnot-a-number\trunning
        burst-short-eeeeee\tid6\torg:Gamerina
        """) }
        let rows = try await burstExecutor(shell).list().sorted { $0.name < $1.name }
        #expect(rows.map(\.name) == ["burst-future-cccccc", "burst-gamerina-bbbbbb", "burst-lexito-ro-aaaaaa"])
        #expect(rows.map(\.id) == ["id3", "id2", "id1"])
        #expect(rows.map(\.target) == ["org:Gamerina", "org:Gamerina", burstTarget])
        let ages: [Double] = rows.map(\.ageSeconds)
        #expect(ages == [0, 1, 100])
        #expect(rows.map(\.running) == [true, false, true])
        #expect(shell.calls.count == 1 && shell.calls.first?.input == nil)
        let script = try #require(shell.calls.first).script
        #expect(script.contains("docker ps") && script.contains("label=rmj.burst"))
        #expect(script.contains("docker inspect") && script.contains("now="))
        for text in ["", "burst-x-abcdef\tid\torg:Gamerina\t900\trunning\n", "now=bad\n"] {
            let missingClock = BurstShell { _ in burstOutput(text) }
            #expect(try await burstExecutor(missingClock).list().isEmpty)
        }
        let failed = BurstShell { _ in burstOutput(status: 1, stderr: "denied\nextra") }
        do {
            _ = try await burstExecutor(failed).list()
            Issue.record("Expected list failure")
        } catch let error as RunnerStackDeployer.Failure {
            guard case .remote(let detail) = error else { Issue.record("Expected remote failure"); return }
            expectCleanBurstText(detail)
        }
    }
}

struct RunnerScalingAcceptanceTests {
    @Test func twoQueuedJobsStartTwiceWithPATOnlyInInput() async throws {
        let shell = BurstShell()
        let log = BurstLog()
        let outcomes = await RunnerScaling().round(
            boxes: [ScalingBox(state: burstState(), runners: burstExecutor(shell))],
            demand: [ScaleDemand(target: burstTarget, waitingSeconds: [20, 40], idleRunners: 0)],
            tokens: { $0 == burstTarget ? burstPAT : nil }, log: { log.append($0) })
        #expect(outcomes.map(\.action) == [.start(box: "fixture-box", target: burstTarget),
                                          .start(box: "fixture-box", target: burstTarget)])
        #expect(outcomes.map(\.succeeded) == [true, true])
        #expect(shell.calls.count == 2)
        for call in shell.calls {
            #expect(call.input == Data("GH_PAT=\(burstPAT)\n".utf8))
            #expect(call.script.contains("docker run") && !call.script.contains(burstPAT))
        }
        #expect(log.lines.count == 2)
        #expect(log.lines.allSatisfy { $0.hasPrefix("start ") && $0.contains("lexito.ro on fixture-box") })
        for text in log.lines + outcomes.map(\.detail) { expectCleanBurstText(text) }
    }

    @Test func missingPATProducesFailedOutcomeAndNoShellCall() async throws {
        let shell = BurstShell()
        let log = BurstLog()
        let outcomes = await RunnerScaling().round(
            boxes: [ScalingBox(state: burstState(), runners: burstExecutor(shell))],
            demand: [ScaleDemand(target: burstTarget, waitingSeconds: [20], idleRunners: 0)],
            tokens: { _ in nil }, log: { log.append($0) })
        let outcome = try #require(outcomes.first)
        #expect(outcomes.count == 1 && !outcome.succeeded && outcome.detail.contains("no PAT"))
        #expect(outcome.action == .start(box: "fixture-box", target: burstTarget))
        #expect(shell.calls.isEmpty)
        for text in log.lines + outcomes.map(\.detail) { expectCleanBurstText(text) }
    }

    @Test func failedStartIsReportedAndNextStartStillExecutes() async throws {
        for transportFailure in [false, true] {
            let shell = BurstShell { index in
                if index == 1 {
                    let text = "\u{001B}[31mfailed \(burstPAT)\u{200B}\nsecond line"
                    if transportFailure { throw BurstTransportError(description: text) }
                    return burstOutput(status: 1, stderr: text)
                }
                return burstOutput()
            }
            let log = BurstLog()
            let outcomes = await RunnerScaling().round(
                boxes: [ScalingBox(state: burstState(), runners: burstExecutor(shell))],
                demand: [ScaleDemand(target: burstTarget, waitingSeconds: [20, 20], idleRunners: 0)],
                tokens: { _ in burstPAT }, log: { log.append($0) })
            #expect(outcomes.map(\.succeeded) == [false, true])
            #expect(shell.calls.count == 2 && log.lines.count == 2)
            #expect(outcomes.first?.detail.isEmpty == false)
            for text in log.lines + outcomes.map(\.detail) { expectCleanBurstText(text) }
        }
    }

    @Test func stopFailurePrecedesStartAndDoesNotAbortRound() async throws {
        let shell = BurstShell { index in
            index == 1 ? burstOutput(status: 1, stderr: "\u{001B}[31mstop failed\nextra") : burstOutput()
        }
        let log = BurstLog()
        let old = ScaleBurst(name: "burst-stuck-abcdef", target: burstTarget, ageSeconds: 180, busy: nil)
        let outcomes = await RunnerScaling().round(
            boxes: [ScalingBox(state: burstState([old]), runners: burstExecutor(shell))],
            demand: [ScaleDemand(target: burstTarget, waitingSeconds: [20], idleRunners: 0)],
            tokens: { _ in burstPAT }, log: { log.append($0) })
        #expect(outcomes.map(\.action) == [.stop(box: "fixture-box", container: old.name),
                                          .start(box: "fixture-box", target: burstTarget)])
        #expect(outcomes.map(\.succeeded) == [false, true])
        #expect(shell.calls.count == 2)
        #expect(shell.calls.first?.script.contains("docker rm -f") == true)
        #expect(shell.calls.last?.script.contains("docker run") == true)
        #expect(log.lines.count == 2)
        #expect(log.lines.first == "stop \(old.name) on fixture-box")
        #expect(log.lines.last?.hasPrefix("start ") == true)
        #expect(log.lines.last?.contains("lexito.ro on fixture-box") == true)
        for text in log.lines + outcomes.map(\.detail) { expectCleanBurstText(text) }
    }
}
