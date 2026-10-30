import Foundation
import Testing
import RMJCore

struct MissingProgramsAcceptanceTests {
    @Test func reportsMissingToolsInCatalogThenRequiredOrder() async {
        let (result, _) = await probe(["rx-rust"], requires: ["jq", "zsh", "jq"],
            section: "@@tools rc=0\nmissing:rx-rust:jq\nmissing:rx-rust:zsh\n")
        #expect(result.missingTools == [MissingTools(image: "rx-rust", programs: ["zsh", "jq"])])
    }

    @Test func onlyImagesWithGapsAreListedInImageOrder() async {
        let (second, _) = await probe(["rx-rust", "rx-node", "rx-python", "rx-go"], section: "@@tools rc=0\nmissing:rx-node:bun\n")
        #expect(second.missingTools == [MissingTools(image: "rx-node", programs: ["bun"])])
        let (both, _) = await probe(["rx-go", "rx-node", "rx-python", "rx-rust"],
            section: "@@tools rc=0\nmissing:rx-rust:zsh\nmissing:rx-python:pytest\nmissing:rx-node:bun\nmissing:rx-go:go\n")
        #expect(both.missingTools == [MissingTools(image: "rx-go", programs: ["go"]),
                                    MissingTools(image: "rx-node", programs: ["bun"]),
                                    MissingTools(image: "rx-python", programs: ["pytest"]),
                                    MissingTools(image: "rx-rust", programs: ["zsh"])])
    }

    @Test func emptySuccessfulToolsSectionMeansAllPresent() async {
        let (result, _) = await probe(["rx-rust"], section: "@@tools rc=0\n")
        #expect(result.missingTools == [])
    }

    @Test func noImagesOrNoRequiredToolsOmitsCheck() async throws {
        for images in [[], ["ubuntu"], ["x;y"]] as [[String]] {
            let (result, spy) = await probe(images, section: nil)
            #expect(result.missingTools == nil)
            let script = try #require(await spy.scripts.first)
            #expect(!script.contains("@@tools") && !script.contains("docker run"))
        }
        let (result, spy) = await probe([], requires: ["jq"], section: nil)
        #expect(result.missingTools == nil)
        #expect(await spy.scripts.allSatisfy { !$0.contains("docker run") && !$0.contains("@@tools") })
    }

    @Test func unknownImageUsesExplicitRequirements() async throws {
        let (result, spy) = await probe(["ubuntu"], requires: ["jq"], section: "@@tools rc=0\nmissing:ubuntu:jq\n")
        #expect(result.missingTools == [MissingTools(image: "ubuntu", programs: ["jq"])])
        #expect(try #require(await spy.scripts.first).contains("@@tools"))
    }

    @Test func invalidNamesNeverEnterScriptAndContainersAreHardened() async throws {
        let (_, spy) = await probe(["rx-rust", "rx-node", "rx-python", "rx-go", "x;y"], requires: ["jq", "z sh; rm"], section: "@@tools rc=0\n")
        let script = try #require(await spy.scripts.first)
        #expect(!script.contains("x;y") && !script.contains("z sh; rm"))
        #expect(script.contains("jq"))
        for fragment in ["docker run --rm", "--network none", "--cap-drop ALL",
                         "--security-opt no-new-privileges", "--entrypoint sh", "docker image inspect"] {
            #expect(script.components(separatedBy: fragment).count - 1 == 4)
        }
        for image in ["rx-rust", "rx-node", "rx-python", "rx-go"] {
            #expect(script.contains(image))
        }
    }

    @Test func failedAbsentAndTruncatedToolsSectionsReportUnknown() async {
        for section in [nil, "@@tools rc=1\nmissing:rx-rust:zsh\n"] as [String?] {
            let (result, _) = await probe(["rx-rust"], section: section)
            #expect(result.missingTools == nil)
        }
        let (result, _) = await probe(["rx-rust"], section: "@@tools rc=0\nmissing:rx-rust:zsh\n", truncated: true)
        #expect(result.missingTools == nil)
    }

    @Test func unrequestedImageAndProgramReportsAreIgnored() async {
        let (result, _) = await probe(["rx-rust"], section: "@@tools rc=0\nmissing:ghost:zsh\nmissing:rx-rust:notrequired\n")
        #expect(result.missingTools == [])
    }

    @Test func cardShowsMissingToolsAndDefaultsToEmptyWithoutProbe() async throws {
        let (result, _) = await probe(["rx-rust"], section: "@@tools rc=0\nmissing:rx-rust:zsh\n")
        var input = try #require(DemoShots.snapshot().destinations.first)
        input.probe = result
        #expect(DestinationCardPresentation(input, now: result.probedAt).missingTools == result.missingTools ?? [])
        input.probe = nil
        #expect(DestinationCardPresentation(input, now: result.probedAt).missingTools == [])
    }

    private func probe(_ images: [String], requires: [String] = [], section: String?, truncated: Bool = false)
        async -> (DestinationProbeResult, ProgramsTransport) {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tailnet/running.json").path
        let state = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: runNow)
        var output = programsOutput().replacingOccurrences(of: "@@end", with: (section ?? "") + "@@end")
        if truncated { output = output.replacingOccurrences(of: "@@end", with: "") }
        let spy = ProgramsTransport(output: output)
        let target = DestinationTarget(alias: "ai-eu-1", peerID: "n-ai-acme-1", requires: requires, images: images)
        let result = await DestinationProbe(transport: spy).probe(target, tailnet: state, now: state.readAt)
        if !truncated { #expect(result.availability.isAvailable) }
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
