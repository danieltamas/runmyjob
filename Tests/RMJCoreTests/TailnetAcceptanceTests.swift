import Foundation
import Testing
import RMJCore

private func fixturePath(_ name: String) -> String {
    #filePath.split(separator: "/", omittingEmptySubsequences: false)
        .dropLast(2).joined(separator: "/") + "/Fixtures/tailnet/\(name).json"
}

private func fixture(_ name: String) async -> TailnetState {
    await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": fixturePath(name)],
                            now: .init(timeIntervalSince1970: 1_793_102_400))
}

private let target = DestinationTarget(alias: "ai-eu-1", peerID: "n-ai-acme-1")
private let targets = [
    target,
    DestinationTarget(alias: "other-box", peerID: "n-other-1"),
    DestinationTarget(alias: "missing-box", peerID: "n-missing"),
    DestinationTarget(alias: "literal-box", peerID: nil, literalAddress: "100.64.0.10")
]

private func cannedOutput(boot: String = "boot-first") -> String {
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
    \(boot)
    @@uptime rc=0
    3600
    @@clock rc=0
    1793102400250000000
    @@end
    """
}

private actor SpyTransport: RemoteTransport {
    struct Call: Sendable {
        let address: String
        let alias: String
        let script: String
        let timeout: Duration
    }

    private(set) var calls: [Call] = []
    let output: String
    let status: Int32
    let timesOut: Bool

    init(output: String = cannedOutput(), status: Int32 = 0, timesOut: Bool = false) {
        self.output = output
        self.status = status
        self.timesOut = timesOut
    }

    func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput {
        calls.append(Call(address: address, alias: alias, script: script, timeout: timeout))
        if timesOut { throw ProcessRunner.Failure.timedOut }
        return ProcessOutput(status: status, stdout: .init(output.utf8), stderr: "connection refused")
    }
}

struct TailnetAcceptanceTests {
    @Test func stoppedTailnetMakesEveryDestinationOfflineWithoutTransportCalls() async {
        let state = await fixture("stopped")
        #expect(state.standing == .stopped)
        let spy = SpyTransport()
        for destination in targets {
            let result = await DestinationProbe(transport: spy).probe(destination, tailnet: state)
            guard case .offline = result.availability else {
                Issue.record("Stopped tailnet must make every destination offline")
                continue
            }
            #expect(!result.availability.isAvailable)
        }
        #expect(await spy.calls.isEmpty)
    }

    @Test func needsLoginMakesEveryDestinationOfflineWithoutTransportCalls() async {
        let state = await fixture("needs-login")
        #expect(state.standing == .needsLogin)
        let spy = SpyTransport()
        for destination in targets {
            let result = await DestinationProbe(transport: spy).probe(destination, tailnet: state)
            guard case .offline = result.availability else {
                Issue.record("Logged-out tailnet must make every destination offline")
                continue
            }
            #expect(!result.availability.isAvailable)
        }
        #expect(await spy.calls.isEmpty)
    }

    @Test func unreadableAndEmptyStatusBecomeUnknownWithoutCrashing() async {
        let malformed = TailnetState.parse(.init("not JSON".utf8))
        let empty = TailnetState.parse(.init())
        let spy = SpyTransport()
        for state in [malformed, empty] {
            guard case .unknown = state.standing else {
                Issue.record("Unreadable status must be unknown")
                continue
            }
            let result = await DestinationProbe(transport: spy).probe(target, tailnet: state)
            #expect(!result.availability.isAvailable)
        }
        #expect(await spy.calls.isEmpty)
    }

    @Test func offlinePeerReportsLastSeenWithoutTransportCalls() async {
        let state = await fixture("peer-offline")
        let expected = Availability.offline("peer offline, last seen 2026-10-27T08:00:00Z")
        #expect(DestinationResolver.resolve(target, in: state) == expected)
        let spy = SpyTransport()
        let result = await DestinationProbe(transport: spy).probe(target, tailnet: state)
        #expect(result.availability == expected)
        #expect(!result.availability.isAvailable)
        #expect(await spy.calls.isEmpty)
    }

    @Test func sshTimeoutIsUnreachableAndUnavailable() async {
        let spy = SpyTransport(timesOut: true)
        let result = await DestinationProbe(transport: spy).probe(target, tailnet: await fixture("running"))
        #expect(result.availability == .unreachable("ssh timeout"))
        #expect(!result.availability.isAvailable)
        #expect(await spy.calls.count == 1)
    }

    @Test func runningPeerParsesProbeReadingsAndUsesVerifiedAddress() async throws {
        let state = await fixture("running")
        let spy = SpyTransport()
        let result = await DestinationProbe(transport: spy).probe(target, tailnet: state, now: state.readAt)
        #expect(result.availability == .online(address: "100.64.0.10"))
        #expect(result.availability.isAvailable)
        #expect(result.dockerReady)
        #expect(result.rsyncReady)
        #expect(result.docker == .ok("27.3.1", at: state.readAt))
        #expect(result.rsync == .ok("rsync  version 3.2.7  protocol version 31", at: state.readAt))
        #expect(result.cores == 24)
        #expect(result.memoryFreeMB == 32768)
        #expect(result.load == 1.25)
        #expect(result.bootID == "boot-first")
        #expect(result.uptime == 3600)
        #expect(result.clockOffsetMS == 250)
        #expect(result.probedAt == state.readAt)
        let calls = await spy.calls
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.address == "100.64.0.10")
        #expect(call.alias == "ai-eu-1")
        #expect(call.timeout == .seconds(20))
        for section in ["docker", "rsync", "images", "containers", "nproc", "mem", "load", "boot", "uptime", "clock"] {
            #expect(call.script.contains("@@\(section) rc="))
        }
        #expect(call.script.contains("@@end"))
    }

    @Test func stablePeerIDSurvivesRenameAndDisabledMagicDNS() async throws {
        let running = await fixture("running")
        let renamed = await fixture("renamed-peer")
        let noDNS = await fixture("magicdns-off")
        let originalPeer = try #require(running.peers.first { $0.id == target.peerID })
        let renamedPeer = try #require(renamed.peers.first { $0.id == target.peerID })
        #expect(originalPeer.hostName != renamedPeer.hostName)
        #expect(originalPeer.dnsName != renamedPeer.dnsName)
        #expect(running.magicDNSEnabled)
        #expect(!noDNS.magicDNSEnabled)
        #expect(noDNS.peers.allSatisfy { $0.dnsName.isEmpty })
        for state in [running, renamed, noDNS] {
            #expect(DestinationResolver.resolve(target, in: state) == .online(address: "100.64.0.10"))
        }
    }

    @Test func publicLiteralIsRejectedBeforeTransportAndPeerLiteralResolves() async {
        let state = await fixture("running")
        let publicTarget = DestinationTarget(alias: "public-box", peerID: nil, literalAddress: "8.8.8.8")
        #expect(DestinationResolver.resolve(publicTarget, in: state) == .rejected("not a tailnet address"))
        let spy = SpyTransport()
        let result = await DestinationProbe(transport: spy).probe(publicTarget, tailnet: state)
        #expect(result.availability == .rejected("not a tailnet address"))
        #expect(!result.availability.isAvailable)
        #expect(await spy.calls.isEmpty)
        let literal = DestinationTarget(alias: "literal-box", peerID: nil, literalAddress: "100.64.0.20")
        #expect(DestinationResolver.resolve(literal, in: state) == .online(address: "100.64.0.20"))
    }

    @Test func sshAndRsyncCarryEveryRequiredOptionAndCommandSuffix() throws {
        let command = ["sh", "-c", "echo ready"]
        let arguments = try SSH.arguments(address: "100.64.0.10", alias: target.alias, command: command)
        let shell = try SSH.rsyncShell(address: "100.64.0.10", alias: target.alias)
        let shellWords = shell.split(separator: " ").map(String.init)
        #expect(shellWords.first == "ssh")
        let options = ["HostName=100.64.0.10", "HostKeyAlias=ai-eu-1", "ProxyCommand=none",
                       "ProxyJump=none", "ControlMaster=auto", "ControlPersist=10m", "BatchMode=yes",
                       "ConnectTimeout=5", "RequestTTY=no", "StrictHostKeyChecking=yes", "ServerAliveInterval=15"]
        for option in options {
            #expect(zip(arguments, arguments.dropFirst()).contains { $0 == "-o" && $1 == option })
            #expect(zip(shellWords, shellWords.dropFirst()).contains { $0 == "-o" && $1 == option })
        }
        for words in [arguments, shellWords] {
            let controlPathOption = try #require(zip(words, words.dropFirst()).first {
                $0 == "-o" && $1.hasPrefix("ControlPath=")
            }?.1)
            let controlPath = String(controlPathOption.dropFirst("ControlPath=".count))
            #expect(controlPath.hasSuffix("/%C"))
            let directory = URL(fileURLWithPath: controlPath).deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL.path
            #expect(directory != "/tmp" && !directory.hasPrefix("/tmp/"))
            #expect(directory != "/private/tmp" && !directory.hasPrefix("/private/tmp/"))
            let attributes = try FileManager.default.attributesOfItem(atPath: directory)
            #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        #expect(Array(arguments.suffix(command.count + 2)) == [target.alias, "--"] + command)
        #expect(Array(shellWords.dropFirst()) == Array(arguments.dropLast(command.count + 2)))
    }

    @Test func sshRejectsUnsafeAliasesAndHostnameAddresses() {
        for alias in ["bad alias", "-option", ";", ""] {
            #expect(throws: SSH.Failure.invalidAlias) {
                try SSH.arguments(address: "100.64.0.10", alias: alias, command: ["true"])
            }
            #expect(throws: SSH.Failure.invalidAlias) {
                try SSH.rsyncShell(address: "100.64.0.10", alias: alias)
            }
        }
        #expect(throws: SSH.Failure.invalidAddress) {
            try SSH.arguments(address: "ai-eu-1", alias: target.alias, command: ["true"])
        }
        #expect(throws: SSH.Failure.invalidAddress) {
            try SSH.rsyncShell(address: "ai-eu-1", alias: target.alias)
        }
    }

    @Test func changedBootIDReportsBootTimeAndMatchingOrAbsentIDDoesNot() async {
        let state = await fixture("running")
        let first = await DestinationProbe(transport: SpyTransport()).probe(target, tailnet: state, now: state.readAt)
        let second = await DestinationProbe(transport: SpyTransport(output: cannedOutput(boot: "boot-second")))
            .probe(target, tailnet: state, now: state.readAt)
        #expect(first.bootID == "boot-first")
        #expect(second.bootID == "boot-second")
        #expect(second.rebootNote(previousBootID: first.bootID) == "rebooted since 2026-10-27T11:00:00Z")
        #expect(second.rebootNote(previousBootID: second.bootID) == nil)
        #expect(second.rebootNote(previousBootID: nil) == nil)
    }

    @Test func fixtureEnvironmentReadsFileAndMissingFileBecomesUnknown() async {
        let state = await fixture("running")
        #expect(state.standing == .running)
        #expect(state.peers.count == 2)
        #expect(state.peers.contains { $0.id == "n-ai-acme-1" && $0.addresses.first == "100.64.0.10" })
        let missing = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": fixturePath("does-not-exist")])
        guard case .unknown = missing.standing else {
            Issue.record("A missing fixture file must yield unknown")
            return
        }
    }

    @Test func relayAndExpiredKeyAreReportedWithoutBlockingResolution() async throws {
        let running = await fixture("running")
        let relayed = await fixture("relayed")
        let expired = await fixture("key-expired")
        #expect(try #require(running.peers.first { $0.id == target.peerID }).relay == nil)
        #expect(try #require(relayed.peers.first { $0.id == target.peerID }).relay == "fra")
        let expiry = try #require(expired.peers.first { $0.id == target.peerID }?.keyExpiry)
        #expect(expiry < expired.readAt)
        for state in [relayed, expired] {
            #expect(DestinationResolver.resolve(target, in: state) == .online(address: "100.64.0.10"))
        }
    }

    @Test func nonzeroSSHExitIsUnreachableWithExitReason() async {
        let spy = SpyTransport(status: 255)
        let result = await DestinationProbe(transport: spy).probe(target, tailnet: await fixture("running"))
        guard case .unreachable(let reason) = result.availability else {
            Issue.record("Non-zero ssh exit must be unreachable")
            return
        }
        #expect(reason.hasPrefix("ssh exit"))
        #expect(!result.availability.isAvailable)
        #expect(await spy.calls.count == 1)
    }

    @Test func dockerFailureKeepsDestinationOnlineWithoutDockerReady() async {
        let state = await fixture("running")
        let output = cannedOutput().replacingOccurrences(of: "@@docker rc=0\n27.3.1",
                                                         with: "@@docker rc=1\ndaemon unavailable\nextra detail")
        let result = await DestinationProbe(transport: SpyTransport(output: output))
            .probe(target, tailnet: state, now: state.readAt)
        #expect(result.docker == .failed("daemon unavailable", at: state.readAt))
        #expect(!result.dockerReady)
        #expect(result.availability == .online(address: "100.64.0.10"))
    }

    @Test func dockerExit127MeansNotInstalled() async {
        let state = await fixture("running")
        let output = cannedOutput().replacingOccurrences(of: "@@docker rc=0", with: "@@docker rc=127")
        let result = await DestinationProbe(transport: SpyTransport(output: output))
            .probe(target, tailnet: state, now: state.readAt)
        #expect(result.docker == .unavailable("not installed", at: state.readAt))
        #expect(!result.dockerReady)
    }

    @Test func missingEndMarkerAndEmptySuccessfulSSHOutputAreUnreachable() async {
        let state = await fixture("running")
        for output in [cannedOutput().replacingOccurrences(of: "@@end", with: ""), ""] {
            let result = await DestinationProbe(transport: SpyTransport(output: output, status: 0))
                .probe(target, tailnet: state)
            #expect(result.availability == .unreachable("incomplete probe output"))
            #expect(!result.dockerReady)
        }
    }

    @Test func repeatedSectionCannotOverrideFirstReading() async {
        let state = await fixture("running")
        let output = cannedOutput().replacingOccurrences(of: "@@end", with: "@@docker rc=0\n99.0\n@@end")
        let result = await DestinationProbe(transport: SpyTransport(output: output))
            .probe(target, tailnet: state, now: state.readAt)
        #expect(result.docker == .ok("27.3.1", at: state.readAt))
    }

    @Test func unknownSectionHeaderRemainsContent() async {
        let state = await fixture("running")
        let output = cannedOutput().replacingOccurrences(of: "rmj/runner:latest", with: "@@bogus rc=0\nrmj/runner:latest")
        let result = await DestinationProbe(transport: SpyTransport(output: output))
            .probe(target, tailnet: state, now: state.readAt)
        #expect(result.images == .ok(["@@bogus rc=0", "rmj/runner:latest", "rx/base:1"], at: state.readAt))
    }

    @Test func nonfiniteOrHugeClockAndNonnumericCoreCountAreAbsent() async {
        let state = await fixture("running")
        for clock in ["nan", "1e300"] {
            let output = cannedOutput().replacingOccurrences(of: "1793102400250000000", with: clock)
                .replacingOccurrences(of: "@@nproc rc=0\n24", with: "@@nproc rc=0\nnot a number")
            let result = await DestinationProbe(transport: SpyTransport(output: output))
                .probe(target, tailnet: state, now: state.readAt)
            #expect(result.clockOffsetMS == nil)
            #expect(result.cores == nil)
            #expect(result.availability.isAvailable)
        }
    }

    @Test func remoteReadingsStripEscapeAndZeroWidthScalars() async {
        let state = await fixture("running")
        let output = cannedOutput().replacingOccurrences(of: "27.3.1", with: "\u{1B}[31m27.\u{200B}3.1")
        let result = await DestinationProbe(transport: SpyTransport(output: output))
            .probe(target, tailnet: state, now: state.readAt)
        #expect(result.docker == .ok("[31m27.3.1", at: state.readAt))
        #expect(result.docker.value?.contains("\u{1B}") == false)
        #expect(result.docker.value?.contains("\u{200B}") == false)
    }

    @Test func untrustedTextCapsLengthAndStripsNonbreakingSpace() {
        #expect(UntrustedText.clean(String(repeating: "x", count: 500)) == String(repeating: "x", count: 200))
        #expect(UntrustedText.clean("before\u{00A0}after") == "beforeafter")
    }

    @Test func imageAndContainerReadingsParseAndReportMissingImages() async throws {
        let state = await fixture("running")
        let result = await DestinationProbe(transport: SpyTransport()).probe(target, tailnet: state, now: state.readAt)
        #expect(result.images == .ok(["rmj/runner:latest", "rx/base:1"], at: state.readAt))
        #expect(result.missingImages(expected: ["rmj/runner:latest", "absent:1"]) == ["absent:1"])
        let samples = try #require(result.containers.value)
        #expect(samples.count == 1)
        let sample = try #require(samples.first)
        #expect(sample.name == "rx-repo-1")
        #expect(sample.cpu == "0.5%")
        #expect(sample.memory == "100MiB / 2GiB")
        #expect(result.containers == .ok(samples, at: state.readAt))
    }

    @Test func emptySuccessfulContainersSectionIsAnEmptyList() async {
        let state = await fixture("running")
        let output = cannedOutput().replacingOccurrences(of: "rx-repo-1 0.5% 100MiB / 2GiB", with: "")
        let result = await DestinationProbe(transport: SpyTransport(output: output))
            .probe(target, tailnet: state, now: state.readAt)
        #expect(result.containers == .ok([], at: state.readAt))
    }

    @Test func tailnetAddressChecksIPv4AndIPv6BoundariesAndRejectsPublicSSH() {
        for address in ["100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1"] {
            #expect(TailnetAddress.isTailnet(address))
        }
        for address in ["100.63.255.255", "100.128.0.1", "8.8.8.8", "127.0.0.1",
                        "ai-eu-1", "fd7a:115c:a1e1::1", ""] {
            #expect(!TailnetAddress.isTailnet(address))
        }
        #expect(throws: SSH.Failure.invalidAddress) {
            try SSH.arguments(address: "8.8.8.8", alias: target.alias, command: ["true"])
        }
    }

    @Test func literalAddressOfAnotherPeerIsRejectedWithoutTransport() async {
        let state = await fixture("running")
        let mismatched = DestinationTarget(alias: target.alias, peerID: target.peerID, literalAddress: "100.64.0.20")
        let spy = SpyTransport()
        let result = await DestinationProbe(transport: spy).probe(mismatched, tailnet: state)
        #expect(result.availability == .rejected("address belongs to another peer"))
        #expect(await spy.calls.isEmpty)
    }

    @Test func publicFirstPeerAddressInStatusFileIsRejectedWithoutTransport() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }
        let json = """
        {"BackendState":"Running","Self":{"Online":true},"Peer":{"peer":{
          "ID":"n-ai-acme-1","Online":true,"TailscaleIPs":["8.8.8.8","100.64.0.10"]
        }}}
        """
        try Data(json.utf8).write(to: path)
        let state = await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path.path])
        #expect(state.standing == .running)
        #expect(DestinationResolver.resolve(target, in: state) == .rejected("not a tailnet address"))
        let spy = SpyTransport()
        let result = await DestinationProbe(transport: spy).probe(target, tailnet: state)
        #expect(result.availability == .rejected("not a tailnet address"))
        #expect(await spy.calls.isEmpty)
    }

    @Test func monitorReusesYoungCacheAndRereadsOldCacheWithoutSleeping() async {
        let readAt = Date(timeIntervalSince1970: 1_793_102_400)
        let reader = CountingTailnetReader(readAt: readAt)
        let monitor = TailnetMonitor(reader: { await reader.read() })
        #expect(await monitor.lastState == nil)
        let first = await monitor.current(maxAge: 10, now: readAt)
        let cached = await monitor.current(maxAge: 10, now: readAt.addingTimeInterval(9))
        #expect(cached == first)
        #expect(await reader.calls == 1)
        _ = await monitor.current(maxAge: 10, now: readAt.addingTimeInterval(11))
        #expect(await reader.calls == 2)
        #expect(await monitor.lastState == first)
    }

    @Test func monitorWakeRereadsImmediatelyWithoutSleeping() async {
        let reader = CountingTailnetReader(readAt: Date(timeIntervalSince1970: 1_793_102_400))
        let monitor = TailnetMonitor(reader: { await reader.read() })
        _ = await monitor.refresh()
        #expect(await reader.calls == 1)
        await monitor.wake()
        #expect(await reader.calls == 2)
        #expect(await monitor.lastState != nil)
    }

    @Test func monitorUsesIdleAndActiveIntervals() async {
        let monitor = TailnetMonitor()
        #expect(TailnetMonitor.idleInterval == .seconds(60))
        #expect(TailnetMonitor.activeInterval == .seconds(10))
        #expect(await monitor.interval == TailnetMonitor.idleInterval)
        await monitor.setActive(true)
        #expect(await monitor.interval == TailnetMonitor.activeInterval)
        await monitor.setActive(false)
        #expect(await monitor.interval == TailnetMonitor.idleInterval)
    }
}

private actor CountingTailnetReader {
    private(set) var calls = 0
    let readAt: Date

    init(readAt: Date) { self.readAt = readAt }

    func read() -> TailnetState {
        calls += 1
        return TailnetState.parse(Data("{\"BackendState\":\"Running\",\"Self\":{\"Online\":true}}".utf8), readAt: readAt)
    }
}
