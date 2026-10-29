import Foundation
import Testing
import RMJCore

struct LogSinkPipelineAcceptanceTests {
    @Test func shipperScopesRedactsChunksAndFansOut() throws {
        let f = try SinkFixture(); defer { f.remove() }
        let scoped = sinkConfig()
        var all = sinkConfig("all"); all.all = true; all.tenants = []
        var disabled = sinkConfig("disabled"); disabled.enabled = false
        let entries = (1...1001).map { sinkEntry($0, line: "token-secret token-secret") }
            + [sinkEntry(1002, tenant: "b"), sinkEntry(1003, tenant: nil)]
        let shipper = LogShipper(sinks: [scoped, all, disabled], spoolRoot: f.root,
                                 secrets: ["token-secret"], now: { sinkEpoch })
        #expect(try shipper.ship(entries) == ["a": 1001, "all": 1003])
        #expect(LogShipper.spoolDirectory(root: f.root, sinkID: "a") == f.root.appendingPathComponent("a"))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("disabled").path))
        for (id, count) in [("a", 1001), ("all", 1003)] {
            let spool = LogSpool(directory: LogShipper.spoolDirectory(root: f.root, sinkID: id))
            #expect(spool.pending().files == 3); #expect(spool.pending().lines == count)
            var received = [LogEntry]()
            var sizes = [Int]()
            while let batch = spool.next() {
                sizes.append(batch.entries.count); received += batch.entries; spool.acknowledge(batch.id)
            }
            #expect(sizes == [500, 500, count - 1000])
            #expect(received.map(\.n) == Array(1...count))
            #expect(received.prefix(1001).allSatisfy { $0.line == "[redacted] [redacted]" })
            #expect(received.allSatisfy { !$0.line.contains("token-secret") })
            if id == "a" { #expect(received.allSatisfy { $0.tenant == "a" }) }
            else { #expect(received[1001].tenant == "b"); #expect(received[1002].tenant == nil) }
        }
    }

    @Test func shipperWithNoAcceptedEntriesWritesNothing() throws {
        let f = try SinkFixture(); defer { f.remove() }
        let root = f.root.appendingPathComponent("unused")
        let shipper = LogShipper(sinks: [sinkConfig()], spoolRoot: root)
        #expect(try shipper.ship([sinkEntry(tenant: "b"), sinkEntry(tenant: nil)]).isEmpty)
        #expect(try shipper.ship([]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
        #expect(try LogShipper(sinks: [], spoolRoot: root).ship([sinkEntry()]).isEmpty)
    }

    @Test func assemblerSplitsCarriesCleansAndClassifies() {
        var assembler = LogLineAssembler(job: "job", repo: "owner/repo", tenant: "a", branch: "main", agent: "terminal", destination: "ai-eu-1")
        let first = assembler.add(Data("hello\r\nerror: broken\nwarn".utf8), now: sinkEpoch)
        #expect(first.map(\.line) == ["hello", "error: broken"])
        #expect(first.map(\.n) == [1, 2]); #expect(first.map(\.level) == [.info, .error])
        let later = sinkEpoch.addingTimeInterval(1)
        let second = assembler.add(Data("ing: old\n\u{1b}[31mred\u{1b}[0m\u{200b}\n\nPASS test\npart".utf8), now: later)
        #expect(second.map(\.line) == ["warning: old", "red", "", "PASS test"])
        #expect(second.map(\.n) == [3, 4, 5, 6]); #expect(second.map(\.level) == [.warn, .info, .info, .info])
        let tail = assembler.flush(now: later)
        #expect(tail.map(\.line) == ["part"]); #expect(tail.map(\.n) == [7])
        #expect(assembler.flush(now: later).isEmpty)
        for entry in first + second + tail {
            #expect(entry.job == "job"); #expect(entry.repo == "owner/repo"); #expect(entry.tenant == "a")
            #expect(entry.branch == "main"); #expect(entry.agent == "terminal"); #expect(entry.destination == "ai-eu-1")
        }
        #expect(first.allSatisfy { $0.time == sinkEpoch }); #expect(second.allSatisfy { $0.time == later })
    }

    @Test func assemblerCarriesSplitUTF8AndEscapeSequences() {
        var assembler = LogLineAssembler(job: "job", repo: "r", tenant: nil, branch: nil, agent: nil, destination: "local")
        #expect(assembler.add(Data([0xc3]), now: sinkEpoch).isEmpty)
        let result = assembler.add(Data([0xa9, 0x1b, 0x5b]), now: sinkEpoch)
        #expect(result.isEmpty)
        let lines = assembler.add(Data("31m!\u{1b}[0m\n".utf8), now: sinkEpoch)
        #expect(lines.map(\.line) == ["\u{e9}!"])
        #expect(assembler.flush(now: sinkEpoch).isEmpty)
    }

    @Test func assemblerFinishIncludesResourcesAndUsesNextNumber() {
        var assembler = LogLineAssembler(job: "job", repo: "r", tenant: nil, branch: nil, agent: nil, destination: "local")
        _ = assembler.add(Data("one\n".utf8), now: sinkEpoch)
        let failed = assembler.finish(state: "failed", exitCode: 7, seconds: 75, avgCPU: 118,
                                      avgMemoryBytes: 536_870_912, now: sinkEpoch)
        let memory = ByteCountFormatter.string(fromByteCount: 536_870_912, countStyle: .memory)
        #expect(failed.line == "run finished: failed, exit 7, 1m 15s, avg cpu 118%, avg mem \(memory)")
        #expect(failed.n == 2); #expect(failed.level == .error); #expect(failed.time == sinkEpoch)
        let done = assembler.finish(state: "done", exitCode: nil, seconds: nil, avgCPU: nil, avgMemoryBytes: nil, now: sinkEpoch)
        #expect(done.line == "run finished: done"); #expect(done.n == 3); #expect(done.level == .info)
        let lost = assembler.finish(state: "lost", exitCode: nil, seconds: nil, avgCPU: nil, avgMemoryBytes: nil, now: sinkEpoch)
        #expect(lost.level == .error)
    }

    @Test func statusStoreMergesRoundTripsRemovesAndSecuresFile() throws {
        let f = try SinkFixture(); defer { f.remove() }
        let store = LogSinkStatusStore(home: f.home)
        #expect(store.read().isEmpty)
        let first = LogSinkStatus(id: "a", sent: 10, rejected: 2, dropped: 3, waitingFiles: 4, waitingLines: 5,
                                 oldestWaiting: sinkEpoch, lastOK: sinkEpoch, lastError: "503",
                                 lastErrorAt: sinkEpoch.addingTimeInterval(1), authFailed: true)
        let second = LogSinkStatus(id: "b", sent: 9)
        try store.update(first); try store.update(second)
        #expect(Set(store.read().map(\.id)) == Set(["a", "b"]))
        #expect(store.read().first { $0.id == "a" } == first)
        #expect(try sinkMode(f.root.appendingPathComponent("log-sinks.json")) == 0o600)
        let replacement = LogSinkStatus(id: "a", sent: 20)
        try store.update(replacement)
        let reopened = LogSinkStatusStore(home: f.home)
        #expect(reopened.read().count == 2)
        #expect(reopened.read().first { $0.id == "a" } == replacement)
        #expect(reopened.read().first { $0.id == "b" } == second)
        try store.remove(id: "a"); try store.remove(id: "missing")
        #expect(store.read() == [second])
        try store.remove(id: "b"); #expect(store.read().isEmpty)
        try Data("not JSON".utf8).write(to: f.root.appendingPathComponent("log-sinks.json"))
        #expect(store.read().isEmpty)
    }

    @Test func indicatorTruthTableIgnoresDisabledAndUnrelatedSinks() {
        let sink = sinkConfig()
        var disabled = sinkConfig("disabled"); disabled.enabled = false
        let now = sinkEpoch.addingTimeInterval(1000)
        #expect(LogStreamIndicator.state(sinks: [], status: [], now: now) == .off)
        #expect(LogStreamIndicator.state(sinks: [disabled], status: [LogSinkStatus(id: "disabled", authFailed: true)], now: now) == .off)
        #expect(LogStreamIndicator.state(sinks: [sink], status: [], now: now) == .healthy)
        let cases: [(LogSinkStatus, LogStreamIndicator)] = [
            (LogSinkStatus(id: "a", authFailed: true), .failing),
            (LogSinkStatus(id: "a", lastErrorAt: now.addingTimeInterval(-299)), .failing),
            (LogSinkStatus(id: "a", lastErrorAt: now.addingTimeInterval(-301)), .healthy),
            (LogSinkStatus(id: "a", lastOK: now, lastErrorAt: now.addingTimeInterval(-1)), .healthy),
            (LogSinkStatus(id: "a", lastOK: now, lastErrorAt: now), .healthy),
            (LogSinkStatus(id: "a", lastOK: now.addingTimeInterval(-2), lastErrorAt: now.addingTimeInterval(-1)), .failing),
            (LogSinkStatus(id: "a", oldestWaiting: now.addingTimeInterval(-301)), .failing),
            (LogSinkStatus(id: "a", oldestWaiting: now.addingTimeInterval(-300)), .healthy),
            (LogSinkStatus(id: "a", oldestWaiting: now.addingTimeInterval(-299)), .healthy),
            (LogSinkStatus(id: "a", lastError: "old text only"), .healthy)
        ]
        for (status, expected) in cases {
            #expect(LogStreamIndicator.state(sinks: [sink], status: [status], now: now) == expected)
        }
        #expect(LogStreamIndicator.state(sinks: [sink, disabled], status: [LogSinkStatus(id: "disabled", authFailed: true), LogSinkStatus(id: "other", authFailed: true)], now: now) == .healthy)
        var second = sinkConfig("b"); second.all = true
        #expect(LogStreamIndicator.state(sinks: [sink, second], status: [LogSinkStatus(id: "b", authFailed: true)], now: now) == .failing)
    }
}
