import Foundation
import Testing
import RMJCore

struct MissingProgramsAcceptanceTests {
    @Test func reportsOnlyMissingRequiredProgramsInRequiredOrder() async {
        let (result, _) = await probe(["zsh", "jq"], section: "@@tools rc=0\nmissing:zsh\n")
        #expect(result.missingPrograms == ["zsh"])
        let (ordered, _) = await probe(["zsh", "jq"], section: "@@tools rc=0\nmissing:jq\nmissing:zsh\n")
        #expect(ordered.missingPrograms == ["zsh", "jq"])
    }

    @Test func emptySuccessfulToolsSectionMeansAllPresent() async {
        let (result, _) = await probe(["zsh", "jq"], section: "@@tools rc=0\n")
        #expect(result.missingPrograms == [])
    }

    @Test func noRequirementsOmitsCheckAndReportsNil() async throws {
        let (result, spy) = await probe([], section: nil)
        #expect(result.missingPrograms == nil)
        let script = try #require(await spy.scripts.first)
        #expect(!script.contains("@@tools"))
    }

    @Test func invalidProgramNamesNeverEnterScript() async throws {
        let (_, spy) = await probe(["zsh", "z sh; rm", "jq"], section: "@@tools rc=0\n")
        let script = try #require(await spy.scripts.first)
        #expect(!script.contains("z sh; rm"))
        #expect(script.contains("zsh"))
        #expect(script.contains("jq"))
        #expect(script.contains("@@tools"))
    }

    @Test func failedToolsSectionReportsUnknown() async {
        let (result, _) = await probe(["zsh"], section: "@@tools rc=1\nmissing:zsh\n")
        #expect(result.missingPrograms == nil)
    }

    @Test func absentToolsSectionReportsUnknown() async {
        let (result, _) = await probe(["zsh"], section: nil)
        #expect(result.missingPrograms == nil)
    }

    @Test func unrequiredMissingProgramIsIgnored() async {
        let (result, _) = await probe(["zsh"], section: "@@tools rc=0\nmissing:ghost\n")
        #expect(result.missingPrograms == [])
    }

    @Test func cardShowsMissingProgramsAndDefaultsToEmptyWithoutProbe() async throws {
        let (result, _) = await probe(["zsh"], section: "@@tools rc=0\nmissing:zsh\n")
        #expect(result.missingPrograms == ["zsh"])
        var input = try #require(DemoShots.snapshot().destinations.first)
        input.probe = result
        #expect(DestinationCardPresentation(input, now: result.probedAt).missingPrograms == ["zsh"])
        input.probe = nil
        #expect(DestinationCardPresentation(input, now: result.probedAt).missingPrograms == [])
    }

    private func probe(_ requires: [String], section: String?) async -> (DestinationProbeResult, ProgramsTransport) {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tailnet/running.json").path
        let state = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: runNow)
        let output = programsOutput().replacingOccurrences(of: "@@end", with: (section ?? "") + "@@end")
        let spy = ProgramsTransport(output: output)
        let target = DestinationTarget(alias: "ai-eu-1", peerID: "n-ai-acme-1", requires: requires)
        let result = await DestinationProbe(transport: spy).probe(target, tailnet: state, now: state.readAt)
        #expect(result.availability.isAvailable)
        return (result, spy)
    }
}

private actor ProgramsTransport: RemoteTransport {
    let output: String
    private(set) var scripts: [String] = []
    init(output: String) { self.output = output }
    func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput {
        scripts.append(script)
        return ProcessOutput(status: 0, stdout: Data(output.utf8), stderr: "")
    }
}

// Full valid fixture from TailnetAcceptanceTests, with optional tools inserted before end.
private func programsOutput() -> String {
    """
    @@docker rc=0
    27.3.1
    @@rsync rc=0
    rsync  version 3.2.7  protocol version 31
    @@images rc=0
    rmj/runner:latest
    rx/base:1
    @@containers rc=0
    rx-repo-1 0.5% 100MiB / 2GiB
    @@nproc rc=0
    24
    @@mem rc=0
    32768
    @@load rc=0
    1.25
    @@boot rc=0
    boot-first
    @@uptime rc=0
    3600
    @@clock rc=0
    1793102400250000000
    @@end
    """
}
