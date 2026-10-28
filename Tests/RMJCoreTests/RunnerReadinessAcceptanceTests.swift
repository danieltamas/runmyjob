import Testing
import Foundation
import RMJCore

// RunnerContainer's memberwise initializer and parser are internal. This stub supplies
// fixture bytes to its public list API without running a process or reaching a host.
private struct ReadinessFixtureShell: OpsShell {
    let state: String

    func run(_ script: String, input: Data?, timeout: Duration) async throws -> ProcessOutput {
        ProcessOutput(status: 0, stdout: Data(
            "runner-fixture\tabc123def456\tgh-runner:2.338.2\t\(state)\tfixture status\n".utf8
        ), stderr: "")
    }

    func sync(directory: URL, to remote: String) async throws {
        Issue.record("Readiness fixtures must never sync files")
    }
}

private let readinessNow = Date(timeIntervalSince1970: 1_793_102_400)

private func readinessCard(state: String = "running", registrations: [String: [GitHubRunner]]) async throws -> DestinationCardInput {
    var rules = Rules.shipped
    rules.destinations = ["ai-eu-1": try #require(rules.destinations["ai-eu-1"])]
    rules.destinations["ai-eu-1"]?.peerID = "n-ai-acme-1"
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/tailnet/running.json")
    let tailnet = TailnetState.parse(try Data(contentsOf: fixture), readAt: readinessNow)
    let containers = try await RunnerContainer.list(shell: ReadinessFixtureShell(state: state))
    #expect(containers.count == 1)
    let cards = DestinationLoader().cards(rules: rules, tailnet: tailnet, jobs: [], probes: [:],
        runners: ["ai-eu-1": containers], registrations: registrations, now: readinessNow)
    return try #require(cards.first)
}

private func readinessRegistration(name: String, online: Bool = true, busy: Bool = false) -> GitHubRunner {
    GitHubRunner(id: 1, name: name, online: online, busy: busy, labels: [])
}

struct RunnerReadinessAcceptanceTests {
    @Test(arguments: [false, true])
    func onlineRegistrationMarksRunningContainerRegisteredAndCopiesBusy(busy: Bool) async throws {
        let card = try await readinessCard(registrations: ["ai-eu-1": [
            readinessRegistration(name: "abc123def456-1793102400", busy: busy)
        ]])
        let runner = try #require(card.runners.first)
        #expect(runner.readiness == "registered")
        #expect(runner.busy == busy)
    }

    @Test(arguments: ["absent", "offline", "other-id", "bare-id", "non-numeric", "empty-suffix"])
    func runningContainerWithoutMatchingOnlineRegistrationIsCritical(kind: String) async throws {
        let registrations: [GitHubRunner]
        switch kind {
        case "absent": registrations = []
        case "offline": registrations = [readinessRegistration(name: "abc123def456-1793102400", online: false)]
        case "other-id": registrations = [readinessRegistration(name: "fff123def456-1793102400")]
        case "bare-id": registrations = [readinessRegistration(name: "abc123def456")]
        case "non-numeric": registrations = [readinessRegistration(name: "abc123def456-invalid")]
        default: registrations = [readinessRegistration(name: "abc123def456-")]
        }
        let card = try await readinessCard(registrations: ["ai-eu-1": registrations])
        #expect(try #require(card.runners.first).readiness == "not registered")
        let line = try #require(DestinationCardPresentation(card, now: readinessNow).runners.first)
        #expect(line.tone == .crit)
        #expect(line.state == "not registered")
    }

    @Test func missingDestinationRegistrationReadingDoesNotMarkContainerFailed() async throws {
        let card = try await readinessCard(registrations: ["unrelated-destination": []])
        #expect(try #require(card.runners.first).readiness == "registered")
        let line = try #require(DestinationCardPresentation(card, now: readinessNow).runners.first)
        #expect(line.tone == .ok)
        #expect(line.state == "online")
    }

    @Test(arguments: ["exited", "created", "paused"])
    func stoppedContainerIsNeverMarkedNotRegistered(state: String) async throws {
        let card = try await readinessCard(state: state, registrations: ["ai-eu-1": []])
        #expect(try #require(card.runners.first).readiness != "not registered")
        let line = try #require(DestinationCardPresentation(card, now: readinessNow).runners.first)
        #expect(line.state == state)
        #expect(line.tone != .crit)
    }
}
