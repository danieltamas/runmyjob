import Foundation
import Testing
import RMJCore

struct LogSpoolAcceptanceTests {
    @Test func restartRoundTripPermissionsOrderingAndAcknowledgement() throws {
        let f = try SinkFixture(); defer { f.remove() }
        let dir = f.root.appendingPathComponent("spool")
        let spool = LogSpool(directory: dir)
        #expect(try sinkMode(dir) == 0o700)
        #expect(try spool.append([sinkEntry(2)], now: sinkEpoch.addingTimeInterval(2)) == 0)
        try spool.append([sinkEntry(1)], now: sinkEpoch)
        let reopened = LogSpool(directory: dir)
        let pending = reopened.pending()
        #expect(pending.files == 2); #expect(pending.lines == 2); #expect(pending.bytes > 0)
        #expect(pending.oldest == sinkEpoch)
        let first = try #require(reopened.next())
        #expect(first.entries == [sinkEntry(1)]); #expect(first.created == sinkEpoch)
        #expect(first.id.hasSuffix(".batch"))
        let file = dir.appendingPathComponent(first.id)
        #expect(try sinkMode(file) == 0o600)
        #expect(first.bytes == Int64(try Data(contentsOf: file).count))
        let rows = String(decoding: try Data(contentsOf: file), as: UTF8.self).split(separator: "\n")
        #expect(rows.count == 1)
        #expect(try JSONDecoder().decode(LogEntry.self, from: Data(rows[0].utf8)) == sinkEntry(1))
        reopened.acknowledge(first.id)
        #expect(reopened.next()?.entries == [sinkEntry(2)])
        reopened.acknowledge(try #require(reopened.next()).id)
        #expect(reopened.next() == nil); #expect(reopened.pending().files == 0)
        #expect(reopened.pending().oldest == nil)
    }

    @Test func byteCapDropsOldestAndCountsDroppedFiles() throws {
        let f = try SinkFixture(); defer { f.remove() }
        let dir = f.root.appendingPathComponent("spool")
        let initial = LogSpool(directory: dir)
        try initial.append([sinkEntry()], now: sinkEpoch)
        let bytes = try #require(initial.next()).bytes
        let limited = LogSpool(directory: dir, maxBytes: bytes)
        #expect(try limited.append([sinkEntry(2)], now: sinkEpoch.addingTimeInterval(1)) == 1)
        #expect(limited.pending().files == 1)
        #expect(limited.next()?.entries.map(\.n) == [2])
        #expect(limited.enforceLimits(now: sinkEpoch.addingTimeInterval(2)) == 0)
    }

    @Test func ageLimitAndStaleTemporaryFiles() throws {
        let f = try SinkFixture(); defer { f.remove() }
        let spool = LogSpool(directory: f.root, maxAge: 10)
        try spool.append([sinkEntry()], now: sinkEpoch)
        try spool.append([sinkEntry(2)], now: sinkEpoch.addingTimeInterval(5))
        let stale = f.root.appendingPathComponent("stale.tmp")
        let fresh = f.root.appendingPathComponent("fresh.tmp")
        try Data("partial".utf8).write(to: stale); try Data().write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: sinkEpoch.addingTimeInterval(-3601)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: sinkEpoch], ofItemAtPath: fresh.path)
        #expect(spool.enforceLimits(now: sinkEpoch.addingTimeInterval(11)) == 1)
        #expect(spool.next()?.entries.map(\.n) == [2])
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(spool.enforceLimits(now: sinkEpoch.addingTimeInterval(16)) == 1)
        #expect(spool.next() == nil)
    }

    @Test func rejectionRetentionCorruptionEmptyAppendAndClear() throws {
        let f = try SinkFixture(); defer { f.remove() }
        let spool = LogSpool(directory: f.root)
        #expect(try spool.append([], now: sinkEpoch) == 0)
        #expect(spool.pending().files == 0)
        var rejectedIDs = [String]()
        for n in 1...52 {
            try spool.append([sinkEntry(n)], now: sinkEpoch.addingTimeInterval(Double(n)))
            let batch = try #require(spool.next()); rejectedIDs.append(batch.id); spool.reject(batch.id)
        }
        #expect(spool.rejectedCount() == 50)
        let rejected = f.root.appendingPathComponent("rejected")
        let names = try FileManager.default.contentsOfDirectory(atPath: rejected.path)
        #expect(Set(names) == Set(rejectedIDs.suffix(50)))
        // A real batch filename with damaged contents, followed by a valid batch.
        try spool.append([sinkEntry(53)], now: sinkEpoch.addingTimeInterval(53))
        let corrupt = try #require(spool.next())
        try Data("not JSON\n".utf8).write(to: f.root.appendingPathComponent(corrupt.id))
        try spool.append([sinkEntry(54)], now: sinkEpoch.addingTimeInterval(54))
        #expect(spool.next()?.entries.map(\.n) == [54])
        #expect(FileManager.default.fileExists(atPath: rejected.appendingPathComponent(corrupt.id).path))
        #expect(spool.rejectedCount() == 50)
        try spool.clear()
        #expect(spool.pending().files == 0); #expect(spool.rejectedCount() == 0)
        #expect(spool.next() == nil)
    }

    @Test func drainLockExcludesConcurrentHolderAndReleasesAfterThrow() async throws {
        let f = try SinkFixture(); defer { f.remove() }
        let spool = LogSpool(directory: f.root)
        let gate = SinkLockGate()
        let holder = Task {
            await spool.withDrainLock {
                await gate.enter()
                await gate.waitForRelease()
                return 7
            }
        }
        await gate.waitForEntry()
        let second = LogSpool(directory: f.root)
        let denied = await second.withDrainLock { 99 }
        #expect(denied == nil)
        await gate.release()
        #expect(await holder.value == 7)
        do {
            let _: Int? = try await spool.withDrainLock { throw SinkScriptError.failed }
            Issue.record("Throwing lock body unexpectedly returned")
        } catch {}
        #expect(await second.withDrainLock { 8 } == 8)
    }
}

actor SinkLockGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func enter() { entered = true; entryWaiter?.resume(); entryWaiter = nil }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func waitForRelease() async {
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
