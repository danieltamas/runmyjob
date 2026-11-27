import Foundation
import Testing
@testable import RMJCore

struct RunnerJobSightingAcceptanceTests {
    @Test func runnerJobsFrameAcceptsOnlyValidSightings() throws {
        let section = """
        @@runnerjobs rc=0
        danieltamas/kazu 46020620866
        org:x 1
        a/b/c 2
        a/b 0
        a/b x
        ../x 3
        \u{1B}[31macme/escaped 4\u{1B}[0m

        """
        let frame = probeFrame.replacingOccurrences(of: "@@end", with: section + "@@end")
        let result = try parse(frame)
        let sightings = try #require(result.runnerJobs)
        #expect(sightings.count == 1)
        #expect(sightings.map(\.repo) == ["danieltamas/kazu"])
        #expect(sightings.map(\.runID) == [46_020_620_866])
    }

    @Test func missingRunnerJobsSectionIsUnknown() throws {
        #expect(try parse(probeFrame).runnerJobs == nil)
    }

    @Test func runnerJobsStepIsHeavyAndOwnsAllDockerExecCalls() throws {
        let script = DestinationProbe.streamScript(requires: [], images: [], interval: 10,
                                                   heavyEvery: 6, rareEvery: 30)
        // Use the same outer-branch and one-line step seams as BoxStreamAcceptanceTests.
        let pattern = #"(?ms)^ *if [^\n]*i[^\n]*% *6\b[^\n]*(?:-eq|==|=) *0[^\n]*then[^\n]*\n.*?^ *fi\b[^\n]*"#
        let range = try #require(script.range(of: pattern, options: .regularExpression))
        let heavy = String(script[range])
        let runnerSteps = script.components(separatedBy: "\n").filter { $0.contains("@@runnerjobs rc=") }
        #expect(runnerSteps.count == 1)
        let runner = try #require(runnerSteps.first)
        #expect(heavy.contains(runner))
        #expect(runner.contains("docker exec"))
        #expect(!script.replacingOccurrences(of: runner, with: "").contains("docker exec"))
    }

    @Test func workerScanHasNoDockerAndKeepsSeenWorkersInTheLoopShell() throws {
        let script = DestinationProbe.streamScript(requires: [], images: [], interval: 10,
                                                   heavyEvery: 6, rareEvery: 30)
        let runner = try #require(script.components(separatedBy: "\n").first { $0.contains("@@runnerjobs rc=") })
        let assignment = try #require(runner.range(of: #"\brw=[^;\n]+"#, options: .regularExpression))
        let scan = String(runner[..<assignment.upperBound])
        #expect(scan.contains("/proc/") && scan.contains("Runner.Worker"))
        #expect(!scan.contains("docker"))
        // The scan and its rw assignment must precede output capture, in the loop's own shell.
        // Wrapping them in $(...) discards the seen-worker set at the end of each heavy turn.
        #expect(!scan.contains("$("))
        #expect(runner[assignment.upperBound...].contains("docker exec"))
    }

    private func parse(_ frame: String) throws -> DestinationProbeResult {
        try #require(DestinationProbe.parse(frame, address: "100.64.0.10",
            probedAt: Date(timeIntervalSince1970: 1_793_102_400), callSeconds: 0))
    }
}
