import Foundation
import Testing
@testable import RMJCore

struct DiskHealthAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 1_793_102_400)

    @Test func singleProbeScriptIncludesUnprivilegedBoundedDiskHealth() async throws {
        let (_, transport) = await remote(section("diskhealth", "ro 0"))
        let scripts = await transport.scripts
        #expect(scripts.count == 1)
        let script = try #require(scripts.first)
        #expect(script.contains("@@diskhealth rc="))
        #expect(!script.contains("sudo"))
        #expect(script.components(separatedBy: "\n").filter { $0.contains("@@diskhealth rc=") }
            .allSatisfy { $0.contains("head -c 16384") })
        #expect(script.components(separatedBy: "@@end").count == 2)
    }

    @Test func validFieldsAndInclusiveInodeBoundsReachProbeSensors() async throws {
        for percent in [0, 89, 90, 96, 97, 100] {
            let (probe, _) = await remote(section("diskhealth", "ro 1\ninodes \(percent)\nioerr 7\nsmart passed"))
            let health = try #require(probe.sensors?.diskHealth)
            #expect(health.readOnly == true)
            #expect(health.inodePercent == percent)
            #expect(health.ioErrors == 7)
            #expect(health.smartPassed == true)
        }
        let (probe, _) = await remote(section("diskhealth", "ro 0\nioerr 0\nsmart failed"))
        let health = try #require(probe.sensors?.diskHealth)
        #expect(health.readOnly == false && health.ioErrors == 0 && health.smartPassed == false)
        #expect(health.inodePercent == nil)
    }

    @Test func malformedLinesAreIgnoredIndividuallyWithoutErasingGoodFields() async throws {
        for bad in malformedLines {
            for body in [bad + "\nro 0\ninodes 42\nioerr 0\nsmart passed",
                         "ro 0\ninodes 42\nioerr 0\nsmart passed\n" + bad] {
                let (probe, _) = await remote(section("diskhealth", body))
                let health = try #require(probe.sensors?.diskHealth)
                #expect(health.readOnly == false, "Bad line: \(bad)")
                #expect(health.inodePercent == 42, "Bad line: \(bad)")
                #expect(health.ioErrors == 0, "Bad line: \(bad)")
                #expect(health.smartPassed == true, "Bad line: \(bad)")
            }
        }
    }

    @Test func unusableOrFailedSectionHasNoDiskHealthAndPreservesOtherSensors() async {
        for body in [""] + malformedLines + [malformedLines.joined(separator: "\n")] {
            let (probe, _) = await remote(section("diskhealth", body) + section("net", "12 34"))
            #expect(probe.sensors?.diskHealth == nil, "Body: \(body)")
            #expect(probe.sensors?.netRxBytes == 12)
            #expect(probe.availability.isAvailable)
        }
        for rc in [1, 2, 127] {
            let (probe, _) = await remote(section("diskhealth", "ro 1\ninodes 100\nioerr 9\nsmart failed", rc: rc)
                                          + section("net", "12 34"))
            #expect(probe.sensors?.diskHealth == nil)
            #expect(probe.sensors?.netTxBytes == 34)
        }
    }

    @Test func anyFailedSMARTWinsRegardlessOfOrder() async throws {
        for body in ["smart passed\nsmart failed", "smart failed\nsmart passed"] {
            let (probe, _) = await remote(section("diskhealth", body))
            #expect(try #require(probe.sensors?.diskHealth).smartPassed == false)
        }
    }

    @Test func healthChipAbsentWithoutActionableOrCheckedSignals() async throws {
        for extra in ["", section("net", "12 34"), section("diskhealth", ""),
                      section("diskhealth", "inodes 0"), section("diskhealth", "inodes 89")] {
            let (probe, _) = await remote(extra)
            #expect(try chips(probe).allSatisfy { $0.id != "health" })
        }
    }

    @Test func healthChipPriorityThresholdsTonesAndDetails() async throws {
        let cases: [(String, String, JobRowPresentation.Tone, String)] = [
            ("smart failed\nro 1\nioerr 7\ninodes 100", "SMART failing", .crit, "replace the disk"),
            ("smart passed\nro 1\nioerr 7\ninodes 100", "Read-only", .crit, "remounted after errors"),
            ("ro 0\nioerr 1\ninodes 100", "1 I/O errors", .warn, "in the kernel log"),
            ("smart passed\nioerr 23\ninodes 97", "23 I/O errors", .warn, "in the kernel log"),
            ("inodes 90", "Inodes 90%", .warn, "files, not bytes"),
            ("inodes 96", "Inodes 96%", .warn, "files, not bytes"),
            ("inodes 97", "Inodes 97%", .crit, "files, not bytes"),
            ("inodes 100", "Inodes 100%", .crit, "files, not bytes"),
            ("smart passed\ninodes 89\nro 0\nioerr 0", "OK", .ok, "SMART passed"),
            ("smart passed", "OK", .ok, "SMART passed"),
            ("ro 0", "OK", .plain, "no SMART here"),
            ("ioerr 0\ninodes 89", "OK", .plain, "no SMART here")
        ]
        for (body, value, tone, detail) in cases {
            let (probe, _) = await remote(section("diskhealth", body))
            let health = try #require(try chips(probe).first { $0.id == "health" })
            #expect(health.value == value, "Body: \(body)")
            #expect(health.tone == tone, "Body: \(body)")
            #expect(health.detail == detail, "Body: \(body)")
        }
    }

    private var malformedLines: [String] {
        ["inodes 101", "inodes -1", "inodes nan", "ioerr -1", "ioerr many", "ro 2", "ro true",
         "smart unknown", "smart FAILED", "unknown 1", "ro", "smart", "inodes", "ioerr",
         "ro 1 extra", "inodes 97 extra", "ioerr 7 extra", "smart failed extra",
         "\u{1B}[31mro 1\u{1B}[0m", "inodes \u{1B}[31m97\u{1B}[0m",
         "ioerr \u{1B}[31m7\u{1B}[0m", "smart \u{1B}[31mfailed\u{1B}[0m"]
    }

    private func chips(_ probe: DestinationProbeResult) throws -> [SensorChip] {
        let demo = try #require(DemoShots.snapshot().destinations.first)
        let input = DestinationCardInput(name: demo.name, config: demo.config, availability: probe.availability,
                                         probe: probe, pollInterval: 30, history: [])
        return SensorChips.chips(input, stale: nil)
    }

    private func section(_ name: String, _ body: String, rc: Int = 0) -> String {
        "@@\(name) rc=\(rc)\n\(body)\n"
    }

    private func remote(_ extra: String) async -> (DestinationProbeResult, DiskHealthTransport) {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tailnet/running.json").path
        let state = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: now)
        var base = section("docker", "27.3.1") + section("rsync", "rsync version 3.2.7 protocol version 31")
        base += section("images", "rmj/runner:latest") + section("containers", "")
        base += section("nproc", "24") + section("mem", "26624") + section("memtotal", "36864")
        base += section("disk", "1030000 300000") + section("load", "6.4")
        base += section("boot", "boot-first") + section("uptime", "129600") + section("clock", "1793102400250000000")
        let transport = DiskHealthTransport(output: base + extra + "@@end\n")
        let target = DestinationTarget(alias: "ai-eu-1", peerID: "n-ai-acme-1")
        return (await DestinationProbe(transport: transport).probe(target, tailnet: state, now: now), transport)
    }
}

private actor DiskHealthTransport: RemoteTransport {
    let output: String
    private(set) var scripts: [String] = []
    init(output: String) { self.output = output }
    func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput {
        scripts.append(script)
        return ProcessOutput(status: 0, stdout: Data(output.utf8), stderr: "")
    }
}
