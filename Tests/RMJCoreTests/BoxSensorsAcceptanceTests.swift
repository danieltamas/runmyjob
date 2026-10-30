import Foundation
import Testing
@testable import RMJCore

struct BoxSensorsAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 1_793_102_400)

    @Test func virtualizationMappingsRespectExitStatus() async throws {
        let groups: [(SystemKind, [String])] = [
            (.bareMetal, ["none"]), (.wsl, ["wsl"]),
            (.container, ["docker", "podman", "lxc", "lxc-libvirt", "openvz", "systemd-nspawn", "rkt"]),
            (.vm, ["kvm", "qemu", "vmware", "microsoft", "oracle", "xen", "amazon", "parallels", "bhyve"])
        ]
        for (kind, words) in groups {
            for word in words {
                let (probe, _) = await remote(section("virt", word, rc: word == "none" ? 1 : 0))
                #expect(try #require(probe.sensors).kind == kind)
            }
        }
        let virtualizationCases: [(String, Int)] = [("none", 127), ("kvm", 127), ("", 0), ("not-a-hypervisor", 0)]
        for (word, rc) in virtualizationCases {
            // A valid independent step makes the unknown kind observable without assuming a snapshot exists for unknown alone.
            let (probe, _) = await remote(section("virt", word, rc: rc) + section("net", "1 2"))
            #expect(try #require(probe.sensors).kind == .unknown)
        }
    }

    @Test func fullLinuxSnapshotAndSingleCappedSSHScript() async throws {
        let (probe, transport) = await remote(linuxSections)
        #expect(probe.availability.isAvailable)
        #expect(try #require(probe.sensors) == SensorSnapshot(
            kind: .bareMetal, cpuBusyTicks: 5987, cpuTotalTicks: 22317,
            swapTotalMB: 2048, swapUsedMB: 512, netRxBytes: 40_000_000, netTxBytes: 5000,
            cpuPressure: 1.25, memoryPressure: 0.40, hottestC: 91, fansRPM: [1200, 2987]))
        let scripts = await transport.scripts
        #expect(scripts.count == 1)
        let script = try #require(scripts.first)
        for name in ["virt", "cpustat", "swap", "net", "psi", "hwmon"] {
            #expect(script.contains("@@\(name) rc="))
        }
        #expect(script.contains("head -c 16384"))
        #expect(script.contains("@@end"))
        #expect(!script.contains("sudo"))
    }

    @Test func wslWithoutKernelOrHardwareFilesHasNoEmptyHardwareChips() async throws {
        let (probe, _) = await remote(section("virt", "wsl") + section("psi", "") + section("hwmon", ""))
        let sensors = try #require(probe.sensors)
        #expect(sensors.kind == .wsl)
        #expect(sensors.hottestC == nil && sensors.fansRPM.isEmpty)
        #expect(sensors.cpuPressure == nil && sensors.memoryPressure == nil)
        let presentation = try card([probe])
        #expect(!presentation.sensors.contains { ["temp", "fan"].contains($0.id) })
        #expect(presentation.sensors.allSatisfy { !$0.value.isEmpty })
    }

    @Test func oldAndEntirelyUnusableSensorSectionsLeaveSnapshotAbsent() async {
        var unusableSections: String = section("virt", "", rc: 127)
        unusableSections += section("cpustat", "bad")
        unusableSections += section("swap", "nan nan")
        unusableSections += section("net", "-1 -2")
        unusableSections += section("psi", "")
        unusableSections += section("hwmon", "")
        let extras: [String] = ["", unusableSections]
        for extra in extras {
            let (probe, _) = await remote(extra)
            #expect(probe.availability.isAvailable)
            #expect(probe.cores == 24 && probe.load == 6.4)
            #expect(probe.sensors == nil)
        }
    }

    @Test func hostileNumbersAreDroppedAndOtherStepsSurvive() async throws {
        for bad in ["-1", "nan", "inf", "1000000000000001", String(repeating: "9", count: 5000)] {
            var extra: String = section("virt", "wsl")
            extra += section("cpustat", "cpu \(bad) 0 0 10 0 0 0 0")
            extra += section("swap", "\(bad) \(bad)")
            extra += section("net", "\(bad) \(bad)")
            extra += section("psi", "cpu \(bad)\nmemory \(bad)")
            extra += section("hwmon", "temp 200000000\nfan \(bad)")
            let (probe, _) = await remote(extra)
            let s = try #require(probe.sensors)
            #expect(s.kind == .wsl)
            #expect(s.cpuBusyTicks == nil && s.cpuTotalTicks == nil)
            #expect(s.swapTotalMB == nil && s.swapUsedMB == nil)
            #expect(s.netRxBytes == nil && s.netTxBytes == nil)
            #expect(s.cpuPressure == nil && s.memoryPressure == nil)
            #expect(s.hottestC == nil && s.fansRPM.isEmpty)
            #expect(probe.load == 6.4)
        }
        let (probe, _) = await remote(section("virt", "\u{1B}[31mw\u{202E}sl\u{1B}[0m")
                                    + section("psi", "cpu 1.25\nmemory nan"))
        #expect(try #require(probe.sensors).kind == .wsl)
        #expect(probe.sensors?.cpuPressure == 1.25 && probe.sensors?.memoryPressure == nil)
        let display = try card([probe])
        let sensorStrings: [String] = display.sensors.flatMap { [$0.id, $0.label, $0.value, $0.stale ?? ""] }
        let detailStrings: [String] = display.sensorDetails.flatMap { [$0.label, $0.value, $0.stale ?? ""] }
        let capacityStrings: [String] = display.capacity.flatMap { [$0.label, $0.value, $0.stale ?? ""] }
        let displayStrings: [String] = [display.systemKind ?? "", display.name, display.state.text, display.lastProbe]
        var strings: [String] = sensorStrings
        strings.append(contentsOf: detailStrings)
        strings.append(contentsOf: capacityStrings)
        strings.append(contentsOf: displayStrings)
        #expect(strings.allSatisfy { !$0.contains("\u{1B}") && !$0.contains("\u{202E}") })
    }

    @Test func malformedCPUAndHardwareBoundaries() async throws {
        for line in ["cpu 1 2 3", "cpu0 1 2 3 4 5 6 7 8", "cpu 1 2 x 4 5 6 7 8"] {
            let (probe, _) = await remote(section("virt", "wsl") + section("cpustat", line))
            #expect(probe.sensors?.cpuBusyTicks == nil && probe.sensors?.cpuTotalTicks == nil)
        }
        let hardwareCases: [(String, Double)] = [("-50000", -50.0), ("150000", 150.0)]
        for (raw, expected) in hardwareCases {
            let (probe, _) = await remote(section("hwmon", "temp \(raw)\nfan 0\nfan -1\nfan 2000"))
            #expect(probe.sensors?.hottestC == expected)
            #expect(probe.sensors?.fansRPM == [2000])
        }
        let (probe, _) = await remote(section("virt", "wsl") + section("hwmon", "temp -50001\ntemp 150001"))
        #expect(probe.sensors?.hottestC == nil)
    }

    @Test func oneFailedStepDoesNotDiscardIndependentReadings() async throws {
        for name in ["cpustat", "swap", "net", "psi", "hwmon"] {
            let (result, _) = await remote(section("virt", "wsl") + section(name, "", rc: 1))
            #expect(try #require(result.sensors).kind == .wsl)
            #expect(result.availability.isAvailable && result.cores == 24)
        }
        let (result, _) = await remote(section("cpustat", "bad") + section("net", "12 34"))
        #expect(result.sensors?.cpuBusyTicks == nil && result.sensors?.cpuTotalTicks == nil)
        #expect(result.sensors?.netRxBytes == 12 && result.sensors?.netTxBytes == 34)
    }

    @Test func missingEndStillRejectsWholeProbe() async {
        let (probe, _) = await remote(linuxSections, ended: false)
        #expect(!probe.availability.isAvailable)
        #expect(probe.sensors == nil)
    }

    @Test func ratesUseDeltasAndRejectInvalidIntervalsOrAnyCounterReset() {
        let older = sample(0), newer = sample(1)
        let rates = SensorRates.between(older, at: now, and: newer, at: now.addingTimeInterval(30))
        #expect(rates.cpuBusyPercent == 50)
        #expect(rates.rxBytesPerSecond == 1_000_000)
        #expect(rates.txBytesPerSecond == 100)
        for seconds in [0.0, -30.0] {
            expectEmpty(SensorRates.between(older, at: now, and: newer, at: now.addingTimeInterval(seconds)))
        }
        let invalid = [
            SensorSnapshot(cpuBusyTicks: 5986, cpuTotalTicks: 23517, netRxBytes: 70_000_000, netTxBytes: 8000),
            SensorSnapshot(cpuBusyTicks: 6587, cpuTotalTicks: 22316, netRxBytes: 70_000_000, netTxBytes: 8000),
            SensorSnapshot(cpuBusyTicks: 6587, cpuTotalTicks: 22317, netRxBytes: 70_000_000, netTxBytes: 8000),
            SensorSnapshot(cpuBusyTicks: 6587, cpuTotalTicks: 23517, netRxBytes: 39_999_999, netTxBytes: 8000),
            SensorSnapshot(cpuBusyTicks: 6587, cpuTotalTicks: 23517, netRxBytes: 70_000_000, netTxBytes: 4999)
        ]
        for s in invalid {
            expectEmpty(SensorRates.between(older, at: now, and: s, at: now.addingTimeInterval(30)))
        }
    }

    @Test func fixedChipOrderValuesAndSeries() throws {
        let display = try card(history())
        #expect(display.sensors.map(\.id) == ["cpu", "memory", "load", "disk", "down", "up", "uptime"])
        #expect(display.sensors.map(\.value) == ["50%", "10 GB", "6.4", "71%", "1.0 MB/s", "100 B/s", "1d 12h"])
        #expect(display.sensors.allSatisfy { $0.tone == .plain && !$0.spinning && $0.stale == nil })
        #expect(try chip("cpu", display).series == [50, 50])
        #expect(try chip("load", display).series == [6.4, 6.4, 6.4])
        #expect(try chip("down", display).series == [1_000_000, 1_000_000])
        #expect(try chip("up", display).series == [100, 100])
    }

    @Test func noRateChipsUntilThereAreTwoSamples() throws {
        let newest = probe(sample(2), at: now)
        for h in [[], [newest]] as [[DestinationProbeResult]] {
            let display = try card(h, newest: newest)
            #expect(display.sensors.map(\.id) == ["memory", "load", "disk", "uptime"])
            #expect(display.sensors.allSatisfy { !$0.value.isEmpty })
        }
    }

    @Test func uptimeAndDecimalNetworkFormats() throws {
        let uptimeCases: [(Double, String)] = [(129_600.0, "1d 12h"), (18_180, "5h 3m"), (720, "12m")]
        for (seconds, text) in uptimeCases {
            let display = try card([probe(sample(0), at: now, uptime: seconds)])
            #expect(try chip("uptime", display).value == text)
        }
        let networkCases: [(Int, String)] = [(999, "999 B/s"), (1000, "1 KB/s"), (707_000, "707 KB/s"),
                             (1_000_000, "1.0 MB/s"), (1_500_000, "1.5 MB/s")]
        for (rate, text) in networkCases {
            let a = SensorSnapshot(cpuBusyTicks: 0, cpuTotalTicks: 100, netRxBytes: 0, netTxBytes: 0)
            let b = SensorSnapshot(cpuBusyTicks: 50, cpuTotalTicks: 200,
                                   netRxBytes: Int64(rate * 30), netTxBytes: Int64(rate * 30))
            let display = try card([probe(a, at: now.addingTimeInterval(-30)), probe(b, at: now)])
            #expect(try chip("down", display).value == text)
            #expect(try chip("up", display).value == text)
        }
    }

    @Test func swapPresenceFormattingAndTone() throws {
        let swapCases: [(Int, String, JobRowPresentation.Tone)] = [(512, "512 MB", JobRowPresentation.Tone.plain),
                                   (1023, "1023 MB", .plain), (1024, "1.0 GB", .warn), (1536, "1.5 GB", .warn)]
        for (used, text, tone) in swapCases {
            let s = SensorSnapshot(swapTotalMB: 2048, swapUsedMB: used)
            let display = try card([probe(s, at: now)])
            #expect(try chip("swap", display).value == text)
            #expect(try chip("swap", display).tone == tone)
        }
        for used in [nil, 0] as [Int?] {
            let display = try card([probe(SensorSnapshot(swapTotalMB: 2048, swapUsedMB: used), at: now)])
            #expect(!display.sensors.contains { $0.id == "swap" })
        }
    }

    @Test func temperatureThresholdsAndFastestFan() throws {
        let temperatureCases: [(Double, JobRowPresentation.Tone)] = [(79.9, JobRowPresentation.Tone.plain), (80, .warn), (89.9, .warn), (90, .crit), (91, .crit)]
        for (temp, tone) in temperatureCases {
            let display = try card([probe(SensorSnapshot(hottestC: temp, fansRPM: [1200, 2987, 2500]), at: now)])
            #expect(try chip("temp", display).tone == tone)
            if temp == 91 { #expect(try chip("temp", display).value == "91 C") }
            let fan = try chip("fan", display)
            #expect(fan.value == "2987 rpm" && fan.spinning && fan.tone == .plain)
        }
    }

    @Test func cpuAndLoadThresholdsAreInclusive() throws {
        let cpuCases: [(Double, JobRowPresentation.Tone)] = [(84.9, JobRowPresentation.Tone.plain), (85, .warn), (85.1, .warn),
                             (94.9, .warn), (95, .crit), (95.1, .crit)]
        for (busy, tone) in cpuCases {
            let a = SensorSnapshot(cpuBusyTicks: 0, cpuTotalTicks: 100, netRxBytes: 0, netTxBytes: 0)
            let b = SensorSnapshot(cpuBusyTicks: Int64((busy * 10).rounded()), cpuTotalTicks: 1100,
                                   netRxBytes: 1, netTxBytes: 1)
            let display = try card([probe(a, at: now.addingTimeInterval(-30)), probe(b, at: now)])
            #expect(try chip("cpu", display).tone == tone)
        }
        let loadCases: [(Double, JobRowPresentation.Tone)] = [(23.9, JobRowPresentation.Tone.plain), (24, .warn), (24.1, .warn),
                             (47.9, .warn), (48, .crit), (48.1, .crit)]
        for (load, tone) in loadCases {
            #expect(try chip("load", card([probe(sample(0), at: now, load: load)])).tone == tone)
        }
    }

    @Test func memoryAndDiskUsedShareTones() throws {
        let capacityCases: [(Int, JobRowPresentation.Tone)] = [(16, JobRowPresentation.Tone.plain), (15, .warn), (5, .crit)]
        for (free, tone) in capacityCases {
            let display = try card([probe(sample(0), at: now, memoryTotal: 100, memoryFree: free,
                                         diskTotal: 100, diskFree: free)])
            #expect(try chip("memory", display).tone == tone)
            #expect(try chip("disk", display).tone == tone)
        }
    }

    @Test func historyIsBoundedAndUsesNewestSixtyProbes() throws {
        let h = (0..<75).map { i in
            probe(sample(i), at: now.addingTimeInterval(Double(i - 74) * 30), load: Double(i))
        }
        let display = try card(h)
        #expect(try chip("load", display).series == (15..<75).map(Double.init))
        for id in ["cpu", "down", "up"] {
            // Sixty retained probes provide fifty-nine consecutive pairs.
            #expect(try chip(id, display).series.count == 59)
        }
        #expect(display.sensors.allSatisfy { $0.series.count <= 60 })
    }

    @Test func staleChipsMatchCapacityMarkerAndOfflineKeepsCachedValues() throws {
        let h = history()
        for availability in [Availability.online(address: "100.64.0.10"), .offline("peer offline")] {
            let input = try input(h, availability: availability)
            let later = now.addingTimeInterval(31)
            let display = DestinationCardPresentation(input, now: later)
            let marker = try #require(DestinationCardPresentation.staleMarker(input, now: later))
            #expect(marker.range(of: #"^as of [0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil)
            #expect(display.capacity.allSatisfy { $0.stale == marker })
            #expect(!display.sensors.isEmpty)
            #expect(display.sensors.allSatisfy { $0.stale == marker })
        }
        let offline = try input([], availability: .offline("peer offline"))
        let display = DestinationCardPresentation(offline, now: now)
        #expect(display.sensors.isEmpty && display.sensorDetails.isEmpty && display.systemKind == nil)
    }

    @Test func systemKindLabelsAndOrderedDetailLines() throws {
        let systemKindCases: [(SystemKind, String)] = [(SystemKind.bareMetal, "bare metal"), (.vm, "VM"), (.wsl, "WSL"), (.container, "container")]
        for (kind, label) in systemKindCases {
            let s = SensorSnapshot(kind: kind, swapTotalMB: 2048, swapUsedMB: 512,
                                   cpuPressure: 1.25, memoryPressure: 0.40)
            let display = try card([probe(s, at: now)])
            #expect(display.systemKind == label)
            #expect(display.sensorDetails.map(\.label) == ["system", "swap", "cpu pressure", "memory pressure"])
            #expect(display.sensorDetails.map(\.value) == [label, "512 MB of 2.0 GB", "1.3%", "0.4%"])
        }
        for total in [nil, 0] as [Int?] {
            let display = try card([probe(SensorSnapshot(swapTotalMB: total), at: now)])
            #expect(display.systemKind == nil && display.sensorDetails.isEmpty)
        }
    }

    private func expectEmpty(_ rates: SensorRates) {
        #expect(rates.cpuBusyPercent == nil && rates.rxBytesPerSecond == nil && rates.txBytesPerSecond == nil)
    }

    private func chip(_ id: String, _ display: DestinationCardPresentation) throws -> SensorChip {
        try #require(display.sensors.first { $0.id == id })
    }

    private func sample(_ index: Int) -> SensorSnapshot {
        SensorSnapshot(kind: .bareMetal, cpuBusyTicks: 5987 + Int64(index) * 600,
                       cpuTotalTicks: 22317 + Int64(index) * 1200,
                       netRxBytes: 40_000_000 + Int64(index) * 30_000_000, netTxBytes: 5000 + Int64(index) * 3000)
    }

    private func history() -> [DestinationProbeResult] {
        (0..<3).map { probe(sample($0), at: now.addingTimeInterval(Double($0 - 2) * 30)) }
    }

    private func probe(_ sensors: SensorSnapshot, at time: Date, load: Double = 6.4, uptime: Double = 129_600,
                       memoryTotal: Int = 36864, memoryFree: Int = 26624,
                       diskTotal: Int = 1_030_000, diskFree: Int = 300_000) -> DestinationProbeResult {
        var result = DestinationProbeResult(
            availability: .online(address: "100.64.0.10"), docker: .ok("27.3", at: time), rsync: .ok("3.3", at: time),
            images: .ok([], at: time), containers: .ok([], at: time), cores: 24,
            memoryFreeMB: memoryFree, memoryTotalMB: memoryTotal, diskTotalMB: diskTotal, diskFreeMB: diskFree,
            osName: "Linux", load: load, bootID: "boot-first", uptime: uptime, clockOffsetMS: 0, probedAt: time)
        result.sensors = sensors
        return result
    }

    private func input(_ h: [DestinationProbeResult], newest: DestinationProbeResult? = nil,
                       availability: Availability = .online(address: "100.64.0.10")) throws -> DestinationCardInput {
        let demo = try #require(DemoShots.snapshot().destinations.first)
        return DestinationCardInput(name: demo.name, config: demo.config, availability: availability,
                                    probe: newest ?? h.last, pollInterval: 30, history: h)
    }

    private func card(_ h: [DestinationProbeResult], newest: DestinationProbeResult? = nil) throws -> DestinationCardPresentation {
        DestinationCardPresentation(try input(h, newest: newest), now: now)
    }

    private func section(_ name: String, _ body: String, rc: Int = 0) -> String {
        "@@\(name) rc=\(rc)\n\(body)\n"
    }

    private var linuxSections: String {
        var sections: String = section("virt", "none", rc: 1)
        sections += section("cpustat", "cpu 4705 150 1120 16250 80 0 12 0 0 0")
        sections += section("swap", "2048 512")
        sections += section("net", "40000000 5000")
        sections += section("psi", "cpu 1.25\nmemory 0.40")
        sections += section("hwmon", "temp 45000\ntemp 91000\nfan 1200\nfan 0\nfan 2987")
        return sections
    }

    // TailnetAcceptanceTests' fixture and one-call RemoteTransport boundary; its helpers are file-private.
    private func remote(_ extra: String, ended: Bool = true) async -> (DestinationProbeResult, SensorsTransport) {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tailnet/running.json").path
        let state = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: now)
        var base: String = section("docker", "27.3.1")
        base += section("rsync", "rsync version 3.2.7 protocol version 31")
        base += section("images", "rmj/runner:latest\nrx/base:1")
        base += section("containers", "rx-repo-1 0.5% 100MiB / 2GiB")
        base += section("nproc", "24")
        base += section("mem", "26624")
        base += section("memtotal", "36864")
        base += section("disk", "1030000 300000")
        base += section("load", "6.4")
        base += section("boot", "boot-first")
        base += section("uptime", "129600")
        base += section("clock", "1793102400250000000")
        let transport = SensorsTransport(output: base + extra + (ended ? "@@end\n" : ""))
        let target = DestinationTarget(alias: "ai-eu-1", peerID: "n-ai-acme-1")
        let result = await DestinationProbe(transport: transport).probe(target, tailnet: state, now: now)
        return (result, transport)
    }
}

private actor SensorsTransport: RemoteTransport {
    let output: String
    private(set) var scripts: [String] = []
    init(output: String) { self.output = output }
    func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput {
        scripts.append(script)
        return ProcessOutput(status: 0, stdout: Data(output.utf8), stderr: "")
    }
}
