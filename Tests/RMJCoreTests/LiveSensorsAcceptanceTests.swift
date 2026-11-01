import Foundation
import Testing
@testable import RMJCore

struct LiveSensorsAcceptanceTests {
    @Test func intervalChangeRestartsImmediatelyWithoutConsumingBackoff() async {
        let h = StreamHarness(sessions: [.init(), .init(end: .status(17)), .init()])
        var timing = BoxStream.Timing.standard
        timing.jitter = 0
        let stream = BoxStream(target: h.target, transport: h.transport, tailnet: { h.network.value },
            clock: { h.clock.now }, timing: timing, sleep: { try await h.sleeper.sleep($0) },
            onResult: { h.results.append($0) })
        await stream.start()
        await eventually { await h.transport.calls.count == 1 }
        #expect(await h.sleeper.backoffs.isEmpty)
        await stream.setFrameInterval(2)
        // No sleep is released: reaching session two proves restart needs no backoff.
        await eventually { await h.transport.calls.count == 2 }
        #expect(await h.transport.calls.last?.script == script(h.target, interval: 2, heavy: 30, rare: 150))
        await eventually { await !h.sleeper.backoffs.isEmpty }
        #expect(await h.sleeper.backoffs == [.seconds(2)])
        #expect(await h.transport.cancelled == 1)
        #expect(await h.transport.maximumActive == 1)
        await h.sleeper.releaseAll()
        await eventually { await h.transport.calls.count == 3 }
        await stream.stop()
    }

    @Test func equalIntervalsIncludingStartingValueDoNotRestart() async {
        let h = StreamHarness(sessions: [.init(), .init()])
        let stream = h.makeStream()
        await stream.start()
        await eventually { await h.transport.calls.count == 1 }
        await stream.setFrameInterval(10)
        await stream.setFrameInterval(10)
        await settle()
        #expect(await h.transport.calls.count == 1)
        #expect(await h.transport.cancelled == 0)
        await stream.setFrameInterval(2)
        await eventually { await h.transport.calls.count == 2 }
        await stream.setFrameInterval(2)
        await stream.setFrameInterval(2)
        await settle()
        #expect(await h.transport.calls.count == 2)
        #expect(await h.transport.cancelled == 1)
        #expect(await h.sleeper.backoffs.isEmpty)
        await stream.stop()
    }

    @Test func intervalChangesRederiveTiersAndSilenceHasThirtySecondFloor() async {
        let h = StreamHarness(sessions: [])
        let stream = h.makeStream()
        await stream.start()
        await eventually { await h.transport.calls.count == 1 }
        var count = 1
        for (interval, heavy, rare) in [(2, 30, 150), (10, 6, 30), (60, 1, 5), (1, 60, 300), (2, 30, 150)] {
            await stream.setFrameInterval(interval)
            count += 1
            await eventually { await h.transport.calls.count == count }
            #expect(await h.transport.calls.last?.script == script(h.target, interval: interval, heavy: heavy, rare: rare))
        }
        h.clock.advance(29)
        await eventually { await h.sleeper.hasCheck }
        await h.sleeper.releaseChecks()
        await settle()
        #expect(h.results.values.isEmpty)
        #expect(await h.transport.active == 1)
        #expect(await h.transport.calls.count == count)
        h.clock.advance(1)
        await eventually { await h.sleeper.hasCheck }
        await h.sleeper.releaseChecks()
        await eventually { h.results.values.last?.availability == .unreachable("no frames for 30 s") }
        await stream.stop()
    }

    @Test func collectionUpdatesAllRunningAndFutureStreams() async {
        let h = StreamHarness(sessions: [])
        let streams = BoxStreams(transport: h.transport, tailnet: { h.network.value }, clock: { h.clock.now },
            sleep: { try await h.sleeper.sleep($0) })
        await streams.ensure(destinations: ["one": h.target, "two": h.target])
        await eventually { await h.transport.calls.count == 2 }
        await streams.setFrameInterval(2)
        await eventually { await h.transport.calls.count == 4 }
        #expect(await h.transport.calls.suffix(2).allSatisfy {
            $0.script == script(h.target, interval: 2, heavy: 30, rare: 150)
        })
        #expect(await h.transport.cancelled == 2)
        #expect(await h.sleeper.backoffs.isEmpty)
        await streams.ensure(destinations: ["one": h.target, "two": h.target, "later": h.target])
        await eventually { await h.transport.calls.count == 5 }
        #expect(await h.transport.calls.last?.script == script(h.target, interval: 2, heavy: 30, rare: 150))
        await streams.stopAll()
    }

    @Test func everyFrameReachesNamedCallbackAndLatestDespiteRepeatSuppression() async {
        let h = StreamHarness(sessions: [.init()])
        let frames = LockedValue<[(String, DestinationProbeResult)]>([])
        let results = LockedValue<[(String, DestinationProbeResult)]>([])
        let streams = BoxStreams(transport: h.transport, tailnet: { h.network.value }, clock: { h.clock.now },
            sleep: { try await h.sleeper.sleep($0) },
            onResult: { name, result in results.update { $0.append((name, result)) } },
            onFrame: { name, result in frames.update { $0.append((name, result)) } })
        await streams.setFrameInterval(2)
        await streams.ensure(destinations: ["sensor-box": h.target])
        await eventually { await h.transport.calls.count == 1 }
        await h.transport.emit(probeFrame)
        await eventually { frames.value.count == 1 && results.value.count == 1 }
        let first = await streams.latest()["sensor-box"]
        #expect(first == frames.value.first?.1)
        #expect(first?.memoryFreeMB == 26624)
        // Identical bytes at the same fake time make equality exact, including cached tier ages.
        await h.transport.emit(probeFrame)
        await eventually { frames.value.count == 2 }
        await settle()
        #expect(frames.value.map(\.0) == ["sensor-box", "sensor-box"])
        #expect(frames.value.first?.1 == frames.value.last?.1)
        #expect(results.value.count == 1)
        #expect(results.value.first?.0 == "sensor-box")
        h.clock.advance(2)
        await h.transport.emit(frameAt(h.clock.now).replacingOccurrences(of: "26624", with: "25000"))
        await eventually { frames.value.count == 3 }
        await eventually { await streams.latest()["sensor-box"]?.memoryFreeMB == 25000 }
        #expect(await streams.latest()["sensor-box"] == frames.value.last?.1)
        h.network.set(tailnet(online: false))
        await eventually { await h.sleeper.hasCheck }
        await h.sleeper.releaseChecks()
        await eventually { frames.value.last?.1.availability.isAvailable == false }
        #expect(frames.value.last?.0 == "sensor-box")
        #expect(await streams.latest()["sensor-box"] == frames.value.last?.1)
        await streams.stopAll()
    }

    @Test func restartRetainsGoodReadingsUntilNewFullFrameWithoutPublishingUnreachable() async throws {
        let h = StreamHarness(sessions: [.init(chunks: [probeFrame]), .init()])
        let stream = h.makeStream()
        await stream.start()
        await eventually { h.results.values.count == 1 }
        let good = try #require(await stream.latest)
        await stream.setFrameInterval(2)
        await eventually { await h.transport.calls.count == 2 }
        await settle()
        #expect(await stream.latest == good)
        #expect(h.results.values == [good])
        let receivedScript = try #require(await h.transport.calls.last?.script)
        #expect(receivedScript.hasPrefix("i=0\n"))
        #expect(receivedScript.contains("i % 30"))
        #expect(receivedScript.contains("i % 150"))
        for name in DestinationProbe.heavySections + DestinationProbe.rareSections where name != "tools" {
            #expect(receivedScript.contains("@@\(name) rc="))
        }
        h.clock.advance(2)
        await h.transport.emit(frameAt(h.clock.now, frame: probeFrame)
            .replacingOccurrences(of: "26624", with: "25000"))
        await eventually { await stream.latest?.memoryFreeMB == 25000 }
        let refreshed = try #require(await stream.latest)
        #expect(refreshed.cores == good.cores)
        #expect(refreshed.probedAt == h.clock.now)
        #expect(h.results.values.allSatisfy { $0.availability.isAvailable })
        await stream.stop()
    }

    @Test func oneHundredLightFramesAssembleAndMergeUnderTwoHundredMilliseconds() {
        var timing = BoxStream.Timing.standard
        timing.frameInterval = 2
        timing.heavyEvery = 30
        timing.rareEvery = 150
        let at = Date(timeIntervalSince1970: 1_793_102_400)
        let data = Data(lightFrame().utf8)
        var assembler = FrameAssembler()
        var cache = SectionCache()
        var merged = 0
        var last: DestinationProbeResult?
        let clock = ContinuousClock()
        let start = clock.now
        for turn in 0..<100 {
            for frame in assembler.feed(data) {
                last = cache.merge(frame: frame, address: "100.64.0.10",
                    at: at.addingTimeInterval(Double(turn * 2)), timing: timing)
                if last != nil { merged += 1 }
            }
        }
        let elapsed = start.duration(to: clock.now)
        #expect(merged == 100)
        #expect(last?.memoryFreeMB == 26624)
        #expect(last?.probedAt == at.addingTimeInterval(198))
        #expect(elapsed < .milliseconds(200))
    }

    private func script(_ target: DestinationTarget, interval: Int, heavy: Int, rare: Int) -> String {
        DestinationProbe.streamScript(requires: target.requires, images: target.images,
            interval: interval, heavyEvery: heavy, rareEvery: rare)
    }
}
