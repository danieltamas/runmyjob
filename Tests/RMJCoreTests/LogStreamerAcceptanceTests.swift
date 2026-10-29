import Foundation
import Testing
import RMJCore

struct LogStreamerAcceptanceTests {
    @Test func noEnabledSinksCreateNoSpool() throws {
        let f = try SinkFixture(); defer { f.remove() }
        let transport = SinkTransport([])
        #expect(LogStreamer(home: f.home, sinks: [], transport: transport, secret: { _ in nil }, host: "mac") == nil)
        #expect(LogStreamer.make(home: f.home) == nil)
        var disabled = sinkConfig(); disabled.enabled = false
        #expect(LogStreamer(home: f.home, sinks: [disabled], transport: transport, secret: { _ in nil }, host: "mac") == nil)
        try LogSinkStore.save([disabled], home: f.home)
        #expect(LogStreamer.make(home: f.home) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("spool").path))
    }

    @Test func tenantDenyAppliesToEveryRequestAndUnscopedRun() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let a = scopedSink("a"), b = scopedSink("b")
        var c = scopedSink("c"); c.all = true
        let transport = successfulTransport()
        let streamer = try makeStreamer(f, [a, b, c], transport)
        let run = try beginStream(streamer, tenant: "a")
        run.add(Data("first\nsecond\n".utf8), now: sinkEpoch)
        await finishStream(run)
        let firstRequests = await transport.requests()
        for host in ["a.example.com", "c.example.com"] {
            let entries = try lokiEntries(firstRequests.filter { $0.url?.host == host })
            #expect(entries.compactMap { $0["msg"] as? String } == ["first", "second", "run finished: done, exit 0"])
        }
        #expect(!firstRequests.contains { $0.url?.host == "b.example.com" })
        #expect(LogSinkAdmin.spool(b, home: f.home).pending().lines == 0)
        let bFiles = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("spool/b").path)
        #expect(bFiles.allSatisfy { $0 == ".lock" })
        let unscoped = try beginStream(streamer, tenant: nil)
        unscoped.add(Data("unscoped\n".utf8))
        await finishStream(unscoped)
        let later = Array((await transport.requests()).dropFirst(firstRequests.count))
        #expect(!later.isEmpty)
        #expect(later.allSatisfy { $0.url?.host == "c.example.com" })
        #expect(try lokiEntries(later).compactMap { $0["msg"] as? String } == ["unscoped", "run finished: done, exit 0"])
        let limited = try makeStreamer(f, [a, b], transport)
        #expect(limited.begin(job: "denied", repo: "owner/repo", tenant: "z", branch: nil,
                              agent: nil, destination: "local", secrets: []) == nil)
    }

    @Test func secretSplitAcrossChunksIsRedactedWithinAssembledLine() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let transport = successfulTransport()
        let streamer = try makeStreamer(f, [sinkConfig()], transport)
        let secret = "private-token-123456"
        let run = try beginStream(streamer, secrets: [secret])
        run.add(Data("before private-token-".utf8))
        run.add(Data("123456 after\n".utf8))
        await finishStream(run)
        let requests = await transport.requests()
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(!String(decoding: try #require(request.httpBody), as: UTF8.self).contains(secret))
        }
        let entries = try lokiEntries(requests)
        let message = try #require(entries.first?["msg"] as? String)
        #expect(message.hasPrefix("before ")); #expect(message.hasSuffix(" after"))
        #expect(message != "before \(secret) after")
    }

    @Test func finishDelivers1200LinesAndClosingEntryInOrder() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let sink = sinkConfig(), transport = successfulTransport()
        let run = try beginStream(makeStreamer(f, [sink], transport))
        for start in stride(from: 1, through: 1200, by: 137) {
            let text = (start...min(start + 136, 1200)).map { "line \($0)\n" }.joined()
            run.add(Data(text.utf8))
        }
        await finishStream(run)
        let entries = try lokiEntries(await transport.requests())
        #expect(entries.compactMap { $0["n"] as? Int } == Array(1...1201))
        #expect(entries.dropLast().compactMap { $0["msg"] as? String } == (1...1200).map { "line \($0)" })
        #expect(entries.last?["msg"] as? String == "run finished: done, exit 0")
        #expect(LogSinkAdmin.spool(sink, home: f.home).pending().files == 0)
    }

    @Test func failingSinkBoundsFinishAndRetainsRecoverableLines() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let sink = sinkConfig(), transport = SinkTransport([])
        let streamer = try makeStreamer(f, [sink], transport)
        let run = try beginStream(streamer)
        run.add(Data("retained\n".utf8))
        let clock = ContinuousClock(), start = ContinuousClock.now
        await finishStream(run)
        #expect(start.duration(to: clock.now) < .seconds(5))
        #expect(LogSinkAdmin.spool(sink, home: f.home).pending().lines > 0)
        await streamer.drainAll(force: true)
        let status = try sinkStatus(f, sink.id)
        #expect(status.lastError != nil)
        #expect(status.waitingLines == 2)
    }

    @Test func freshStreamerDrainsPreviousProcessBacklog() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let sink = sinkConfig()
        do {
            let first = try makeStreamer(f, [sink], SinkTransport([]))
            let run = try beginStream(first)
            run.add(Data("survives restart\n".utf8))
            await finishStream(run)
        }
        #expect(LogSinkAdmin.spool(sink, home: f.home).pending().lines == 2)
        let transport = successfulTransport()
        let second = try makeStreamer(f, [sink], transport)
        await second.drainUntilEmptyOrTimeout()
        #expect(try lokiEntries(await transport.requests()).compactMap { $0["msg"] as? String }
                == ["survives restart", "run finished: done, exit 0"])
        #expect(LogSinkAdmin.spool(sink, home: f.home).pending().files == 0)
    }

    @Test func successfulRunPersistsDeliveryStatus() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let sink = sinkConfig(), transport = successfulTransport()
        let streamer = try makeStreamer(f, [sink], transport)
        let run = try beginStream(streamer)
        run.add(Data("one\ntwo\nthree\n".utf8))
        await finishStream(run)
        let status = try sinkStatus(f, sink.id)
        #expect(status.sent == 4); #expect(status.waitingLines == 0)
        #expect(status.waitingFiles == 0); #expect(status.lastOK != nil)
        #expect(!status.authFailed)
    }

    @Test func authenticationStatusClearsAfterResumeAndSuccessfulDrain() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let sink = sinkConfig(), transport = SinkTransport([.reply(401)] + Array(repeating: .reply(200), count: 20))
        let streamer = try makeStreamer(f, [sink], transport)
        let run = try beginStream(streamer)
        run.add(Data("waiting for credentials\n".utf8))
        await finishStream(run)
        #expect(try sinkStatus(f, sink.id).authFailed)
        #expect(await transport.requests().count == 1)
        await streamer.resume(sinkID: sink.id)
        await streamer.drainAll(force: true)
        let status = try sinkStatus(f, sink.id)
        #expect(!status.authFailed); #expect(status.sent == 2)
        #expect(status.waitingLines == 0); #expect(status.lastOK != nil)
    }

    @Test func archivedGitHubLinesPreserveTimestampAndTenantBoundary() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        var sink = sinkConfig(); sink.kind = .elasticsearch; sink.url = "http://127.0.0.1:9200"
        let transport = successfulTransport(elasticsearchSuccess()), streamer = try makeStreamer(f, [sink], transport)
        var job = JobRecord(id: "gh-job", repo: "owner/repo", command: "ci", location: "github-hosted", queuedAt: sinkEpoch)
        job.github = "owner/repo/actions/runs/1"
        let document = LogDocument(text: "job\tstep\t2026-10-29T08:32:43.0537729Z archived text", isLive: false)
        for tenant in [nil, "b"] as [String?] {
            job.tenant = tenant; streamer.shipArchived(job, document: document)
        }
        #expect(LogSinkAdmin.spool(sink, home: f.home).pending().files == 0)
        await streamer.drainAll(force: true)
        #expect(await transport.requests().isEmpty)
        job.tenant = "a"; streamer.shipArchived(job, document: document)
        await streamer.drainUntilEmptyOrTimeout()
        let requests = await transport.requests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.path == "/_bulk")
        let rows = try #require(request.httpBody).split(separator: 10)
        #expect(rows.count == 2)
        let entry = try jsonObject(Data(try #require(rows.last)))
        #expect(entry["message"] as? String == "archived text")
        #expect(entry["@timestamp"] as? String == "2026-10-29T08:32:43.054Z")
        let metadata = try #require(entry["rmj"] as? [String: Any])
        #expect(metadata["destination"] as? String == "github")
        #expect(metadata["tenant"] as? String == "a")
    }

    @Test func sendTestReportsSuccessAuthenticationAndTransportFailure() async throws {
        for kind in [LogSinkConfig.Kind.loki, .elasticsearch] {
            var sink = sinkConfig(); sink.kind = kind
            let success = kind == .elasticsearch ? elasticsearchSuccess() : SinkStep.reply(204)
            for step in [success, .reply(401), .failure] {
                let transport = SinkTransport([step])
                let result = await LogSinkAdmin.sendTest(sink, secret: nil, transport: transport, host: "mac", now: sinkEpoch)
                switch step {
                case .response(let response):
                    #expect(result.ok == (response.status == (kind == .elasticsearch ? 200 : 204)))
                    #expect(result.message.contains(String(response.status)))
                case .failure: #expect(!result.ok); #expect(!result.message.isEmpty)
                }
                let requests = await transport.requests()
                #expect(requests.count == 1)
                #expect(requests.first?.httpMethod == "POST")
                #expect(requests.first?.url?.path == (kind == .loki ? "/loki/api/v1/push" : "/_bulk"))
                #expect(requests.first?.httpBody?.isEmpty == false)
            }
        }
    }

    @Test func discardWaitingEmptiesSpoolAndResetsWaitingStatus() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let sink = sinkConfig(), spool = LogSinkAdmin.spool(sinkConfig(), home: f.home)
        try spool.append([sinkEntry()], now: Date())
        let streamer = try makeStreamer(f, [sink], SinkTransport([.reply(401)]))
        await streamer.drainAll(force: true)
        #expect(try sinkStatus(f, sink.id).waitingLines == 1)
        #expect(try sinkStatus(f, sink.id).oldestWaiting != nil)
        try LogSinkAdmin.discardWaiting(sink, home: f.home)
        #expect(spool.pending().files == 0); #expect(spool.pending().lines == 0)
        let status = try sinkStatus(f, sink.id)
        #expect(status.waitingFiles == 0); #expect(status.waitingLines == 0)
        #expect(status.oldestWaiting == nil)
    }
}

private func scopedSink(_ id: String) -> LogSinkConfig {
    var sink = sinkConfig(id); sink.tenants = [id]; sink.url = "https://\(id).example.com"
    return sink
}
private func elasticsearchSuccess() -> SinkStep {
    .response(LogSinkResponse(status: 200, body: Data("{\"errors\":false,\"items\":[]}".utf8)))
}
private func successfulTransport(_ step: SinkStep = .reply(200)) -> SinkTransport {
    SinkTransport(Array(repeating: step, count: 100))
}
private func makeStreamer(_ f: SinkFixture, _ sinks: [LogSinkConfig], _ transport: SinkTransport) throws -> LogStreamer {
    let secret: @Sendable (LogSinkConfig) -> String? = { _ in nil }
    let streamer = LogStreamer(home: f.home, sinks: sinks, transport: transport, secret: secret, host: "mac")
    return try #require(streamer)
}
private func beginStream(_ streamer: LogStreamer, tenant: String? = "a", secrets: [String] = []) throws -> LogStream {
    try #require(streamer.begin(job: UUID().uuidString, repo: "owner/repo", tenant: tenant, branch: "main",
                                agent: "terminal", destination: "local", secrets: secrets))
}
private func finishStream(_ stream: LogStream) async {
    await stream.finish(state: "done", exitCode: 0, seconds: nil, avgCPU: nil, avgMemoryBytes: nil)
}
private func sinkStatus(_ f: SinkFixture, _ id: String) throws -> LogSinkStatus {
    try #require(LogSinkStatusStore(home: f.home).read().first { $0.id == id })
}
private func lokiEntries(_ requests: [URLRequest]) throws -> [[String: Any]] {
    try requests.flatMap { request in
        let body = try #require(request.httpBody)
        let object = try jsonObject(body)
        let streams = try #require(object["streams"] as? [[String: Any]])
        return try streams.flatMap { stream in
            try #require(stream["values"] as? [[String]]).map { value in
                #expect(value.count == 2)
                return try jsonObject(Data(value[1].utf8))
            }
        }
    }
}
