import Foundation
import Testing
import RMJCore

struct LogSinkDrainerAcceptanceTests {
    @Test func retry503Then200KeepsFileAndHonorsBackoff() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let spool = LogSpool(directory: f.root)
        try spool.append([sinkEntry()], now: sinkEpoch)
        let transport = SinkTransport([.reply(503), .reply(200)])
        let drainer = LogSinkDrainer(sink: sinkConfig(), secret: nil, spool: spool, transport: transport, host: "mac")
        let failed = await drainer.drain(now: sinkEpoch)
        expectBackoff(failed.health, until: sinkEpoch.addingTimeInterval(1))
        #expect(failed.files == 0); #expect(failed.lines == 0); #expect(failed.lastError?.contains("503") == true)
        #expect(spool.pending().files == 1)
        let early = await drainer.drain(now: sinkEpoch.addingTimeInterval(0.5))
        #expect(early.health == failed.health); #expect(await transport.requests().count == 1)
        let ok = await drainer.drain(now: sinkEpoch.addingTimeInterval(1))
        #expect(ok.files == 1); #expect(ok.lines == 1); #expect(ok.health == .ok); #expect(ok.lastError == nil)
        #expect(spool.pending().files == 0)
        let requests = await transport.requests()
        #expect(requests.count == 2); #expect(requests[0].httpBody == requests[1].httpBody)
    }

    @Test func transientFailuresDoubleToCapAndResetAfterSuccess() async throws {
        for first in [SinkStep.reply(408), .reply(429), .reply(500), .failure] {
            let f = try SinkFixture(); defer { f.remove() }
            let spool = LogSpool(directory: f.root)
            try spool.append([sinkEntry()], now: sinkEpoch)
            let transport = SinkTransport([first] + Array(repeating: .reply(503), count: 9) + [.reply(204), .reply(503)])
            let drainer = LogSinkDrainer(sink: sinkConfig(), secret: nil, spool: spool, transport: transport, host: "mac")
            var now = sinkEpoch
            for delay in [1.0, 2, 4, 8, 16, 32, 64, 128, 256, 300] {
                let outcome = await drainer.drain(now: now)
                expectBackoff(outcome.health, until: now.addingTimeInterval(delay))
                #expect(outcome.lastError != nil); #expect(spool.pending().files == 1)
                if case .failure = first, now == sinkEpoch { #expect(outcome.lastError?.contains("scripted transport failure") == true) }
                now = now.addingTimeInterval(delay)
            }
            #expect(await drainer.drain(now: now).files == 1)
            try spool.append([sinkEntry(2)], now: now)
            expectBackoff(await drainer.drain(now: now).health, until: now.addingTimeInterval(1))
        }
    }

    @Test func retryAfterIsHonoredAndCapped() async throws {
        for delay in [42.0, 7200] {
            let f = try SinkFixture(); defer { f.remove() }
            let spool = LogSpool(directory: f.root); try spool.append([sinkEntry()], now: sinkEpoch)
            let transport = SinkTransport([.response(LogSinkResponse(status: 429, retryAfter: delay)), .reply(200)])
            let drainer = LogSinkDrainer(sink: sinkConfig(), secret: nil, spool: spool, transport: transport, host: "mac")
            let until = sinkEpoch.addingTimeInterval(min(delay, 3600))
            expectBackoff(await drainer.drain(now: sinkEpoch).health, until: until)
            _ = await drainer.drain(now: until.addingTimeInterval(-0.1))
            #expect(await transport.requests().count == 1)
            #expect(await drainer.drain(now: until).files == 1)
        }
    }

    @Test func authenticationFailuresPauseUntilResume() async throws {
        for status in [401, 403] {
            let f = try SinkFixture(); defer { f.remove() }
            let spool = LogSpool(directory: f.root); try spool.append([sinkEntry()], now: sinkEpoch)
            let transport = SinkTransport([.reply(status), .reply(200)])
            let drainer = LogSinkDrainer(sink: sinkConfig(), secret: nil, spool: spool, transport: transport, host: "mac")
            let outcome = await drainer.drain(now: sinkEpoch)
            if case .authFailed(let reason) = outcome.health { #expect(reason.contains(String(status))) }
            else { Issue.record("Expected authFailed") }
            #expect(outcome.lastError?.contains(String(status)) == true)
            #expect(spool.pending().files == 1)
            #expect(await drainer.drain(now: sinkEpoch.addingTimeInterval(9999)).health == outcome.health)
            #expect(await transport.requests().count == 1)
            await drainer.resume()
            #expect(await drainer.drain(now: sinkEpoch).files == 1)
        }
    }

    @Test func permanentClientErrorRejectsAndContinuesOldestFirst() async throws {
        for status in [400, 404, 413, 422] {
            let f = try SinkFixture(); defer { f.remove() }
            let spool = LogSpool(directory: f.root)
            try spool.append([sinkEntry(1)], now: sinkEpoch)
            try spool.append([sinkEntry(2)], now: sinkEpoch.addingTimeInterval(1))
            let transport = SinkTransport([.reply(status), .reply(202)])
            let drainer = LogSinkDrainer(sink: sinkConfig(), secret: nil, spool: spool, transport: transport, host: "mac")
            let outcome = await drainer.drain(now: sinkEpoch.addingTimeInterval(2))
            #expect(outcome.rejected == 1); #expect(outcome.files == 1); #expect(outcome.lines == 1)
            #expect(outcome.health == .ok); #expect(outcome.lastError == nil)
            #expect(spool.pending().files == 0); #expect(spool.rejectedCount() == 1)
            #expect(try await sentNumbers(transport) == [1, 2])
        }
    }

    @Test func oversizedFileAcknowledgesOnlyAfterEveryChunkSucceeds() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let spool = LogSpool(directory: f.root)
        try spool.append((1...1001).map { sinkEntry($0) }, now: sinkEpoch)
        let transport = SinkTransport([.reply(200), .reply(503), .reply(200), .reply(200), .reply(200)])
        let drainer = LogSinkDrainer(sink: sinkConfig(), secret: nil, spool: spool, transport: transport, host: "mac")
        let failed = await drainer.drain(now: sinkEpoch)
        #expect(failed.files == 0); #expect(spool.pending().lines == 1001)
        let ok = await drainer.drain(now: sinkEpoch.addingTimeInterval(1))
        #expect(ok.files == 1); #expect(ok.lines == 1001); #expect(spool.pending().files == 0)
        let requests = await transport.requests()
        #expect(requests.count == 5)
        #expect(try await sentNumbers(transport) == Array(1...1000) + Array(1...1001))
    }

    @Test func elasticsearchBulkItemErrorsRejectOrBackoff() async throws {
        for retry in [false, true] {
            let f = try SinkFixture(); defer { f.remove() }
            let spool = LogSpool(directory: f.root); try spool.append([sinkEntry()], now: sinkEpoch)
            var sink = sinkConfig(); sink.kind = .elasticsearch
            let body = Data("{\"errors\":true,\"items\":[{\"create\":{\"status\":\(retry ? 429 : 400)}}]}".utf8)
            let transport = SinkTransport([.response(LogSinkResponse(status: 200, body: body))])
            let drainer = LogSinkDrainer(sink: sink, secret: nil, spool: spool, transport: transport, host: "mac")
            let outcome = await drainer.drain(now: sinkEpoch)
            if retry {
                expectBackoff(outcome.health, until: sinkEpoch.addingTimeInterval(1))
                #expect(spool.pending().files == 1); #expect(outcome.rejected == 0)
            } else {
                #expect(outcome.rejected == 1); #expect(spool.pending().files == 0)
            }
            #expect(outcome.files == 0)
        }
    }

    @Test func disabledSinkAndBusyLockLeaveSpoolUntouched() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let spool = LogSpool(directory: f.root); try spool.append([sinkEntry()], now: sinkEpoch)
        var sink = sinkConfig(); sink.enabled = false
        let transport = SinkTransport([.reply(200)])
        let paused = LogSinkDrainer(sink: sink, secret: nil, spool: spool, transport: transport, host: "mac")
        #expect(await paused.drain(now: sinkEpoch).health == .paused)
        sink.enabled = true
        let active = LogSinkDrainer(sink: sink, secret: nil, spool: spool, transport: transport, host: "mac")
        let held = await spool.withDrainLock { await active.drain(now: sinkEpoch) }
        let busy = try #require(held)
        #expect(busy.files == 0); #expect(busy.lines == 0); #expect(busy.health == .ok)
        #expect(await transport.requests().isEmpty); #expect(spool.pending().files == 1)
        #expect(await active.drain(now: sinkEpoch).files == 1)
    }

    @Test func independentSinksKeepHealthySinkInOrder() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let down = LogSpool(directory: f.root.appendingPathComponent("down"))
        let up = LogSpool(directory: f.root.appendingPathComponent("up"))
        for n in 1...3 {
            try down.append([sinkEntry(n)], now: sinkEpoch.addingTimeInterval(Double(n)))
            try up.append([sinkEntry(n)], now: sinkEpoch.addingTimeInterval(Double(n)))
        }
        let bad = SinkTransport([.failure]); let good = SinkTransport([.reply(200), .reply(200), .reply(200)])
        let a = LogSinkDrainer(sink: sinkConfig("down"), secret: nil, spool: down, transport: bad, host: "mac")
        let b = LogSinkDrainer(sink: sinkConfig("up"), secret: nil, spool: up, transport: good, host: "mac")
        async let failure = a.drain(now: sinkEpoch)
        async let success = b.drain(now: sinkEpoch)
        let (failed, ok) = await (failure, success)
        #expect(failed.files == 0); #expect(ok.files == 3); #expect(ok.lines == 3)
        #expect(down.pending().lines == 3); #expect(up.pending().files == 0)
        #expect(try await sentNumbers(good) == [1, 2, 3])
    }
}

enum SinkScriptError: Error, CustomStringConvertible {
    case failed
    var description: String { "scripted transport failure" }
}
enum SinkStep: Sendable {
    case response(LogSinkResponse), failure
    static func reply(_ status: Int) -> SinkStep { .response(LogSinkResponse(status: status)) }
}
actor SinkTransport: LogSinkTransport {
    private var script: [SinkStep]
    private var recorded: [URLRequest] = []
    init(_ script: [SinkStep]) { self.script = script }
    func send(_ request: URLRequest) async throws -> LogSinkResponse {
        recorded.append(request)
        guard !script.isEmpty else { throw SinkScriptError.failed }
        switch script.removeFirst() {
        case .response(let response): return response
        case .failure: throw SinkScriptError.failed
        }
    }
    func requests() -> [URLRequest] { recorded }
}
func expectBackoff(_ health: SinkHealth, until: Date) {
    if case .backoff(let actual, let reason) = health {
        #expect(actual == until); #expect(!reason.isEmpty)
    } else { Issue.record("Expected backoff, got \(health)") }
}
func sentNumbers(_ transport: SinkTransport) async throws -> [Int] {
    var numbers = [Int]()
    for request in await transport.requests() {
        let data = try #require(request.httpBody)
        let streams = try #require(try jsonObject(data)["streams"] as? [[String: Any]])
        for stream in streams {
            for value in try #require(stream["values"] as? [[String]]) {
                numbers.append(try #require(try jsonObject(Data(value[1].utf8))["n"] as? Int))
            }
        }
    }
    return numbers
}
