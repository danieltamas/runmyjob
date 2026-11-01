import Foundation
import Testing
@testable import RMJCore

// U16 seams not spelled out in PLAN: FrameAssembler.feed(Data) -> [String],
// and BoxStreams accepts the same injected dependencies as BoxStream, without target/onResult.
// Additional internal seams required by the cost tests:
// SectionCache.merge(frame:address:at:timing:) -> DestinationProbeResult? (init has no arguments).
// DestinationProbe.streamSteps(requires:images:) -> [(name: String, command: String,
// maximumCommands: Int)]; counts include all wrapper processes and bounded loop iterations.
struct BoxStreamAcceptanceTests {
    @Test func assemblerPreservesEveryByteSplitIncludingUTF8AndEnd() {
        let frame = "@@clock rc=0\n123\n@@osname rc=0\nCaf\u{e9}\n@@end\n"
        let bytes = Data(frame.utf8)
        for offset in 0...bytes.count {
            var assembler = FrameAssembler()
            let frames = assembler.feed(Data(bytes.prefix(offset))) + assembler.feed(Data(bytes.dropFirst(offset)))
            #expect(frames.map(normalized) == [normalized(frame)], "split at byte \(offset)")
        }
    }

    @Test func assemblerDropsGarbageAndReturnsTwoFramesInOrder() {
        var assembler = FrameAssembler()
        let a = "@@clock rc=0\n1\n@@end\n"
        let b = "@@clock rc=0\n2\n@@end\n"
        #expect(assembler.feed(Data(("ssh banner\nnoise\n" + a + b).utf8)).map(normalized)
                == [normalized(a), normalized(b)])
    }

    @Test func oversizedFrameResynchronisesAtNextClockEvenAcrossChunks() {
        for prefix in ["", "@@docker rc=0\nnot a new frame\n"] {
            var assembler = FrameAssembler()
            let oversized = "@@clock rc=0\n" + String(repeating: "x", count: 256 * 1024 + 1)
            #expect(assembler.feed(Data(oversized.utf8)).isEmpty)
            #expect(assembler.feed(Data(("\n" + prefix + "@@cl").utf8)).isEmpty)
            let recovered = "@@clock rc=0\n2\n@@end\n"
            #expect(assembler.feed(Data("ock rc=0\n2\n@@end\n".utf8)).map(normalized) == [normalized(recovered)])
        }
    }

    @Test func completeFramesPublishAtArrivalAndKeepTheRealReadings() async throws {
        let h = StreamHarness(sessions: [.init(chunks: [probeFrame])])
        let stream = h.makeStream()
        await stream.start()
        await eventually { h.results.values.count == 1 }
        let expected = try #require(DestinationProbe.parse(probeFrame, address: "100.64.0.10",
            probedAt: h.clock.now, callSeconds: 0))
        #expect(await stream.latest == expected)
        #expect(h.results.values == [expected])
        h.clock.advance(10)
        await h.transport.emit(probeFrame.replacingOccurrences(of: "6.4", with: "7.4"))
        await eventually { h.results.values.count == 2 }
        #expect(h.results.values.last?.probedAt == h.clock.now)
        await stream.stop()
    }

    @Test func malformedMissingAndTruncatedFramesNeverPublishHealthy() async {
        let bad = ["@@clock rc=no\n1\n@@end\n", "@@clock rc=0\n1\n@@end\n",
                   probeFrame.replacingOccurrences(of: "@@mem rc=0", with: "@@mem rc=no"),
                   probeFrame.replacingOccurrences(of: "@@mem rc=0\n26624\n", with: ""),
                   probeFrame.replacingOccurrences(of: "@@end\n", with: "")]
        for text in bad {
            let h = StreamHarness(sessions: [.init(chunks: [text], end: .status(0))])
            let stream = h.makeStream()
            await stream.start()
            await eventually { !h.results.values.isEmpty }
            #expect(h.results.values.allSatisfy { !$0.availability.isAvailable })
            #expect(await stream.latest?.availability.isAvailable == false)
            await stream.stop()
        }
    }

    @Test func unavailableResolverNeverConnectsAndRetriesWithItsExactAvailability() async {
        for state in [tailnet(standing: .stopped), tailnet(online: false), tailnet(address: "192.0.2.1")] {
            let h = StreamHarness(sessions: [], state: state)
            let stream = h.makeStream()
            await stream.start()
            let expected = DestinationResolver.resolve(h.target, in: state)
            await eventually { h.results.values.contains { $0.availability == expected } }
            #expect(await h.transport.calls.isEmpty)
            #expect(h.results.values.last?.cores == nil)
            h.network.set(tailnet())
            await eventually { await !h.sleeper.backoffs.isEmpty }
            await h.sleeper.releaseAll()
            await eventually { await h.transport.calls.count == 1 }
            await stream.stop()
        }
    }

    @Test func everyReconnectResolvesAgainAndNeverOverlapsSessions() async {
        let h = StreamHarness(sessions: [.init(chunks: [probeFrame], end: .status(17)), .init()])
        let stream = h.makeStream()
        await stream.start()
        await eventually { h.results.values.contains { !$0.availability.isAvailable } }
        let good = h.results.values.first { $0.availability.isAvailable }
        let failed = h.results.values.last
        if case .unreachable(let reason) = failed?.availability {
            #expect(reason.hasPrefix("ssh exit 17:"))
        } else {
            Issue.record("An ended session must publish unreachable")
        }
        #expect(failed?.probedAt == good?.probedAt)
        #expect(failed?.containers == good?.containers)
        #expect(failed?.cores == 24)
        h.network.set(tailnet(address: "100.64.0.20"))
        await eventually { await !h.sleeper.backoffs.isEmpty }
        await h.sleeper.releaseAll()
        await eventually { await h.transport.calls.count == 2 }
        #expect(await h.transport.calls.map(\.address) == ["100.64.0.10", "100.64.0.20"])
        #expect(await h.transport.maximumActive == 1)
        await stream.stop()
    }

    @Test func allExitStatusesAndThrowsPublishUnreachable() async {
        for end in [ScriptedStream.End.status(0), .status(255), .failure] {
            let h = StreamHarness(sessions: [.init(chunks: [probeFrame], end: end)])
            let stream = h.makeStream()
            await stream.start()
            await eventually { h.results.values.contains { !$0.availability.isAvailable } }
            #expect(h.results.values.last?.cores == 24)
            #expect(h.results.values.last?.probedAt == h.results.values.first?.probedAt)
            await stream.stop()
        }
    }

    @Test func backoffCapsAtSixtyWithTwentyPercentJitterAndResetsAfterAFrame() async {
        let sessions = Array(repeating: ScriptedStream.Session(end: .status(1)), count: 7)
            + [.init(chunks: [probeFrame], end: .status(1)), .init()]
        let h = StreamHarness(sessions: sessions)
        let stream = h.makeStream()
        await stream.start()
        for (index, base) in [2.0, 4, 8, 16, 32, 60, 60, 2].enumerated() {
            await eventually { await h.sleeper.backoffs.count > index }
            let delays = await h.sleeper.backoffs
            if delays.indices.contains(index) {
                let seconds = seconds(delays[index])
                #expect(seconds >= base * 0.8 && seconds <= base * 1.2)
            }
            await h.sleeper.releaseAll()
        }
        await eventually { await h.transport.calls.count == 9 }
        await stream.stop()
    }

    @Test func silenceUsesInjectedClockCancelsAndReconnectsAfterThirtySeconds() async {
        let h = StreamHarness(sessions: [.init(chunks: [probeFrame]), .init()])
        let stream = h.makeStream()
        await stream.start()
        await eventually { h.results.values.count == 1 }
        await eventually { await h.sleeper.hasCheck }
        h.clock.advance(29)
        await h.sleeper.releaseChecks()
        await settle()
        #expect(h.results.values.allSatisfy { $0.availability.isAvailable })
        #expect(await h.transport.cancelled == 0)
        await eventually { await h.sleeper.hasCheck }
        h.clock.advance(1)
        await h.sleeper.releaseChecks()
        await eventually { h.results.values.last?.availability == .unreachable("no frames for 30 s") }
        await eventually { await h.transport.cancelled == 1 }
        #expect(h.results.values.last?.probedAt == h.results.values.first?.probedAt)
        #expect(h.results.values.last?.cores == 24)
        await eventually { await !h.sleeper.backoffs.isEmpty }
        await h.sleeper.releaseAll()
        await eventually { await h.transport.calls.count == 2 }
        await stream.stop()
    }

    @Test func tailnetChangeMidSessionCancelsAndPreservesLastGoodReadings() async {
        for state in [tailnet(standing: .stopped), tailnet(online: false), tailnet(address: "192.0.2.1")] {
            let h = StreamHarness(sessions: [.init(chunks: [probeFrame])])
            let stream = h.makeStream()
            await stream.start()
            await eventually { h.results.values.count == 1 }
            h.network.set(state)
            await eventually { await h.sleeper.hasCheck }
            await h.sleeper.releaseChecks()
            let expected = DestinationResolver.resolve(h.target, in: state)
            await eventually { h.results.values.last?.availability == expected }
            await eventually { await h.transport.cancelled == 1 }
            #expect(h.results.values.last?.cores == 24)
            #expect(h.results.values.last?.probedAt == h.results.values.first?.probedAt)
            #expect(await h.transport.calls.count == 1)
            await stream.stop()
        }
    }

    @Test func stopSuppressesLateCallbacksAndPendingReconnect() async {
        for end in [ScriptedStream.End.hang, .status(1)] {
            let h = StreamHarness(sessions: [.init(chunks: [probeFrame], end: end)])
            let stream = h.makeStream()
            await stream.start()
            await eventually { h.results.values.count >= (end == .hang ? 1 : 2) }
            await stream.stop()
            let before = h.results.values
            let latest = await stream.latest
            await h.transport.emit(probeFrame)
            h.clock.advance(1000)
            await h.sleeper.releaseAll()
            await settle()
            #expect(h.results.values == before)
            #expect(await stream.latest == latest)
            #expect(await h.transport.calls.count == 1)
            if end == .hang { #expect(await h.transport.cancelled == 1) }
        }
    }

    @Test func transportGetsOnlyTheReadOnlyProbeLoop() async throws {
        let h = StreamHarness(sessions: [.init()])
        let stream = h.makeStream()
        await stream.start()
        await eventually { await h.transport.calls.count == 1 }
        let call = try #require(await h.transport.calls.first)
        let expected = DestinationProbe.streamScript(requires: h.target.requires, images: h.target.images,
                                                    interval: 10, heavyEvery: 6, rareEvery: 30)
        #expect(call.script == expected)
        #expect(call.alias == h.target.alias)
        #expect(expected.contains("while :; do") && expected.contains("sleep 10"))
        var stripped = expected
        for allowed in ["2>&1", "2>/dev/null", ">/dev/null"] {
            stripped = stripped.replacingOccurrences(of: allowed, with: "")
        }
        #expect(stripped.range(of: #"\bnc\b"#, options: .regularExpression) == nil)
        for forbidden in ["sudo", "socat", " -l", ">"] { #expect(!stripped.contains(forbidden)) }
        await stream.stop()
    }

    @Test func standardTimingMatchesTheCostContract() {
        let timing = BoxStream.Timing.standard
        #expect(timing.frameInterval == 10 && timing.heavyEvery == 6 && timing.rareEvery == 30)
        #expect(timing.silence == .seconds(30))
    }

    @Test func lightFramesMergeWithoutLosingOlderTierReadings() async throws {
        let h = StreamHarness(sessions: [.init(chunks: [probeFrame])])
        let stream = h.makeStream()
        await stream.start()
        await eventually { h.results.values.count == 1 }
        let first = try #require(await stream.latest)
        h.clock.advance(10)
        let light = lightFrame().replacingOccurrences(of: "6.4", with: "7.4")
            .replacingOccurrences(of: "26624", with: "25000")
            .replacingOccurrences(of: "12 34", with: "56 78")
        await h.transport.emit(light)
        await eventually { await stream.latest?.probedAt == h.clock.now }
        let next = try #require(await stream.latest)
        #expect(next.containers == first.containers && next.images == first.images)
        #expect(next.sensors?.diskHealth == first.sensors?.diskHealth)
        #expect(next.load == 7.4 && next.memoryFreeMB == 25000)
        #expect(next.sensors?.netRxBytes == 56 && next.sensors?.netTxBytes == 78)
        await stream.stop()
    }

    @Test func cachedHeavyAndRareReadingsExpireAtThreePeriods() throws {
        var cache = SectionCache()
        let at = Date(timeIntervalSince1970: 1_793_102_400)
        func merged(_ frame: String, _ age: TimeInterval) throws -> DestinationProbeResult {
            let merged = cache.merge(frame: frame, address: "100.64.0.10", at: at.addingTimeInterval(age),
                                     timing: .standard)
            return try #require(merged)
        }
        let first = try merged(probeFrame, 0)
        let before = try merged(lightFrame(), 179.999)
        #expect(before.containers == first.containers && before.docker == first.docker)
        let expired = try merged(lightFrame(), 180)
        if case .unavailable = expired.containers {} else { Issue.record("Expired containers must be unavailable") }
        if case .unavailable = expired.docker {} else { Issue.record("Expired docker must be unavailable") }
        #expect(expired.images == first.images && expired.sensors?.diskHealth == first.sensors?.diskHealth)
        let rareBefore = try merged(lightFrame(), 899.999)
        #expect(rareBefore.images == first.images)
        let rareExpired = try merged(lightFrame(), 900)
        if case .unavailable = rareExpired.images {} else { Issue.record("Expired images must be unavailable") }
        #expect(rareExpired.sensors?.diskHealth == nil && rareExpired.cores == nil)
    }

    @Test func missingLightSectionDropsFrameAndFailedLightNeverReusesPreviousValue() throws {
        var cache = SectionCache()
        let at = Date(timeIntervalSince1970: 1_793_102_400)
        #expect(cache.merge(frame: probeFrame, address: "100.64.0.10", at: at, timing: .standard) != nil)
        for name in DestinationProbe.lightSections {
            let missing = frameKeeping(Set(DestinationProbe.lightSections).subtracting([name]))
            #expect(cache.merge(frame: missing, address: "100.64.0.10",
                                at: at.addingTimeInterval(10), timing: .standard) == nil, "missing \(name)")
        }
        let failed = lightFrame().replacingOccurrences(of: "@@mem rc=0\n26624\n", with: "@@mem rc=1\nread failed\n")
            .replacingOccurrences(of: "@@net rc=0\n12 34\n", with: "@@net rc=0\n\n")
        let merged = cache.merge(frame: failed, address: "100.64.0.10",
                                           at: at.addingTimeInterval(20), timing: .standard)
        let next = try #require(merged)
        #expect(next.memoryFreeMB == nil && next.sensors?.netRxBytes == nil && next.sensors?.netTxBytes == nil)
    }

    @Test func missingLightFrameDoesNotPublishOrResetSilence() async {
        let h = StreamHarness(sessions: [.init(chunks: [probeFrame])])
        let stream = h.makeStream()
        await stream.start()
        await eventually { h.results.values.count == 1 }
        let first = await stream.latest
        h.clock.advance(20)
        await h.transport.emit(frameKeeping(Set(DestinationProbe.lightSections).subtracting(["load"])))
        await settle()
        #expect(await stream.latest == first && h.results.values.count == 1)
        h.clock.advance(10)
        await eventually { await h.sleeper.hasCheck }
        await h.sleeper.releaseChecks()
        await eventually { h.results.values.last?.availability == .unreachable("no frames for 30 s") }
        await stream.stop()
    }

    @Test func tierPartitionAndLightCommandBudgetMatchActualSteps() {
        let light = Set(DestinationProbe.lightSections), heavy = Set(DestinationProbe.heavySections)
        let rare = Set(DestinationProbe.rareSections)
        #expect(light == Set(["clock", "mem", "memtotal", "load", "boot", "uptime", "cpustat", "swap",
                              "net", "psi", "hwmon", "disk", "clockend"]))
        #expect(heavy == Set(["docker", "containers"]))
        #expect(rare == Set(["rsync", "images", "nproc", "diskhealth", "osname", "virt", "tools"]))
        #expect(light.isDisjoint(with: heavy) && light.isDisjoint(with: rare) && heavy.isDisjoint(with: rare))
        let steps = DestinationProbe.streamSteps(requires: ["git"], images: ["swift:6"])
        #expect(light.union(heavy).union(rare) == Set(steps.map(\.name)))
        #expect(steps.count == Set(steps.map(\.name)).count)
        let lightSteps = steps.filter { light.contains($0.name) }
        #expect(lightSteps.count == light.count)
        #expect(lightSteps.allSatisfy { $0.maximumCommands >= 0 })
        #expect(lightSteps.reduce(0) { $0 + $1.maximumCommands } <= 14)
        for step in lightSteps {
            for forbidden in ["docker", "dmesg", "smartctl", "lsblk", "findmnt", "systemd-detect-virt"] {
                #expect(!step.command.contains(forbidden), "\(step.name): \(forbidden)")
            }
        }
    }

    @Test func scriptGatesExpensiveCommandsAndStartsAllTiersAtZero() throws {
        let script = DestinationProbe.streamScript(requires: ["git"], images: ["swift:6"],
                                                   interval: 10, heavyEvery: 6, rareEvery: 30)
        // Text seam: generated outer tier branches occupy separate lines, ending in a standalone fi.
        func branch(_ every: Int) throws -> String {
            let pattern = "(?ms)^ *if [^\\n]*i[^\\n]*% *\(every)\\b[^\\n]*(?:-eq|==|=) *0[^\\n]*then[^\\n]*\\n.*?^ *fi\\b[^\\n]*"
            let range = try #require(script.range(of: pattern, options: .regularExpression))
            return String(script[range])
        }
        let heavy = try branch(6), rare = try branch(30)
        #expect(heavy.contains("docker stats --no-stream"))
        #expect(script.components(separatedBy: "docker stats").count == 2)
        #expect(!rare.contains("docker stats"))
        let light = script.replacingOccurrences(of: heavy, with: "").replacingOccurrences(of: rare, with: "")
        for forbidden in ["docker", "dmesg", "smartctl", "lsblk", "findmnt", "systemd-detect-virt"] {
            #expect(!light.contains(forbidden))
        }
        let zero = try #require(script.range(of: #"\bi=0\b"#, options: .regularExpression))
        let loop = try #require(script.range(of: "while :; do"))
        #expect(zero.lowerBound < loop.lowerBound)
        let increment = try #require(script.range(of: "i=$((i+1))"))
        let heavyRange = try #require(script.range(of: heavy)), rareRange = try #require(script.range(of: rare))
        #expect(loop.upperBound < heavyRange.lowerBound && loop.upperBound < rareRange.lowerBound)
        #expect(heavyRange.upperBound < increment.lowerBound && rareRange.upperBound < increment.lowerBound)
        for name in DestinationProbe.lightSections { #expect(light.contains("@@\(name) rc=")) }
        for name in DestinationProbe.heavySections { #expect(heavy.contains("@@\(name) rc=")) }
        for name in DestinationProbe.rareSections { #expect(rare.contains("@@\(name) rc=")) }
    }

    @Test func lightSampleAndOneHundredMergesMeetCostBudget() throws {
        let frame = lightFrame()
        #expect(frame.utf8.count < 3 * 1024)
        var cache = SectionCache()
        let at = Date(timeIntervalSince1970: 1_793_102_400)
        #expect(cache.merge(frame: probeFrame, address: "100.64.0.10", at: at, timing: .standard) != nil)
        let clock = ContinuousClock()
        let start = clock.now
        var valid = 0
        var last: DestinationProbeResult?
        for turn in 1...100 {
            last = cache.merge(frame: frame, address: "100.64.0.10",
                               at: at.addingTimeInterval(Double(turn * 10)), timing: .standard)
            if last != nil { valid += 1 }
        }
        let elapsed = start.duration(to: clock.now)
        #expect(valid == 100 && last?.memoryFreeMB == 26624)
        #expect(elapsed < .milliseconds(100))
    }

    @Test func equalResultsOnlyNotifyOnceAMinuteButChangesNotifyImmediately() async {
        let h = StreamHarness(sessions: [.init(chunks: [probeFrame])])
        let stream = h.makeStream()
        await stream.start()
        await eventually { h.results.values.count == 1 }
        // Keep remote clock in step with the injected clock so clockOffsetMS does not change.
        for turn in 1...6 {
            h.clock.advance(10)
            await h.transport.emit(frameAt(h.clock.now))
            await eventually { await stream.latest?.probedAt == h.clock.now }
            #expect(turn < 6 ? h.results.values.count == 1 : h.results.values.count <= 2)
        }
        var count = h.results.values.count
        var changed = lightFrame()
        for (old, new) in [("6.4", "7.4"), ("26624", "25000"), ("12 34", "56 78")] {
            h.clock.advance(1)
            changed = changed.replacingOccurrences(of: old, with: new)
            await h.transport.emit(frameAt(h.clock.now, frame: changed))
            count += 1
            await eventually { h.results.values.count == count }
        }
        h.network.set(tailnet(online: false))
        await eventually { await h.sleeper.hasCheck }
        await h.sleeper.releaseChecks()
        await eventually { h.results.values.last?.availability.isAvailable == false }
        #expect(h.results.values.count == count + 1)
        h.network.set(tailnet())
        await eventually { await !h.sleeper.backoffs.isEmpty }
        await h.sleeper.releaseAll()
        await eventually { await h.transport.calls.count == 2 }
        await h.transport.emit(frameAt(h.clock.now, frame: probeFrame))
        await eventually { h.results.values.last?.availability.isAvailable == true }
        #expect(h.results.values.count == count + 2)
        await stream.stop()
    }

    @Test func streamsEnsureIsIdempotentStopsRemovedAndRestartsEveryChangedTargetField() async {
        let h = StreamHarness(sessions: Array(repeating: .init(chunks: [probeFrame]), count: 12))
        let streams = BoxStreams(transport: h.transport, tailnet: { h.network.value }, clock: { h.clock.now },
                                 timing: .standard, sleep: { try await h.sleeper.sleep($0) })
        await streams.ensure(destinations: ["one": h.target, "two": h.target])
        await eventually { await streams.latest().count == 2 }
        #expect(await h.transport.calls.count == 2)
        await streams.ensure(destinations: ["one": h.target, "two": h.target])
        await settle()
        #expect(await h.transport.calls.count == 2)
        await streams.ensure(destinations: ["one": h.target])
        await eventually { await h.transport.cancelled == 1 }
        #expect(await streams.latest()["two"] == nil)
        let changed = [
            DestinationTarget(alias: "renamed", peerID: "peer"),
            DestinationTarget(alias: "box", peerID: "peer", literalAddress: "100.64.0.10"),
            DestinationTarget(alias: "box", peerID: nil, literalAddress: "100.64.0.10"),
            DestinationTarget(alias: "box", peerID: "peer", requires: ["git"]),
            DestinationTarget(alias: "box", peerID: "peer", requires: ["git"], images: ["swift:6"])
        ]
        for (index, target) in changed.enumerated() {
            await streams.ensure(destinations: ["one": target])
            await eventually { await h.transport.calls.count == index + 3 }
            #expect(await h.transport.cancelled == index + 2)
        }
        await streams.ensure(destinations: [:]) // Disabled targets are omitted: DestinationTarget has no enabled field.
        await eventually { await h.transport.cancelled == 7 }
        #expect(await streams.latest().isEmpty)
        await streams.ensure(destinations: ["one": h.target])
        await eventually { await streams.latest().count == 1 }
        await streams.stopAll()
        let count = await h.transport.calls.count
        await h.transport.emit(probeFrame)
        await h.sleeper.releaseAll()
        await settle()
        #expect(await h.transport.calls.count == count)
        #expect(await h.transport.active == 0)
        #expect(await streams.latest().isEmpty)
    }
}
