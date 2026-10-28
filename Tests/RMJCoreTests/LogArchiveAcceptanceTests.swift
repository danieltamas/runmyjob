import Testing
import Foundation
import RMJCore

private actor FixtureLogSource: LogSource {
    enum Offline: Error { case boxOffline }
    private var offline = true
    private var calls: [String] = []
    func setOnline() { offline = false }
    func calledIDs() -> [String] { calls }
    func pull(jobID: String, into writer: LogWriter) async throws {
        calls.append(jobID)
        // A failed transfer may already have streamed a partial chunk.
        if offline {
            await writer.write(Data("partial".utf8))
            throw Offline.boxOffline
        }
        await writer.write(Data("content for \(jobID)\n".utf8))
    }
}

struct LogArchiveAcceptanceTests {
    @Test func sixtyMegabyteStreamCapsAtFiftyMegabytesPlusMarker() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        try await f.ledger.insert(f.job("large"))
        let archive = LogArchive(database: f.database, directory: f.logs)
        let writer = try archive.writer(jobID: "large", secrets: [])
        let chunk = Data(repeating: 120, count: 1024 * 1024)
        for _ in 0..<60 { await writer.write(chunk) }
        let entry = try #require(try await writer.finish(complete: true))
        #expect(entry.status == .available)
        #expect(entry.truncated)
        let path = try #require(entry.path)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size - 128)
        let tail = try #require(try handle.readToEnd())
        let suffix = Data("[rmj: log truncated at 50 MB]\n".utf8)
        #expect(tail.suffix(suffix.count) == suffix)
        // Read the marker from the actual tail, including its leading newline.
        let markerStart = try #require(tail.firstIndex(of: 10))
        let marker = tail[markerStart...]
        #expect(marker == Data("\n[rmj: log truncated at 50 MB]\n".utf8))
        #expect(size == UInt64(50 * 1024 * 1024 + marker.count))
        #expect(entry.bytes == Int(size))
    }

    @Test func secretsAreRedactedWithinAcrossAndAtEndOfChunks() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        let pat = "ghp_FIXTUREvalue1234567890"
        let chunks: [[String]] = [
            ["before " + pat + " after\n"],
            ["before ghp_FIX", "TUREvalue1234567890 after\n"],
            ["before g", "h", "p_FIXTUREvalue1234567890 after\n"],
            ["before ", pat],
            ["before "] + pat.map { String($0) } + [" after\n"]
        ]
        for (index, parts) in chunks.enumerated() {
            let id = "secret-\(index)"
            try await f.ledger.insert(f.job(id))
            let writer = try f.archive.writer(jobID: id, secrets: ["", pat, ""])
            for part in parts { await writer.write(Data(part.utf8)) }
            // Known secrets must not reach even the unfinished local file.
            let partial = try Data(contentsOf: f.logs.appendingPathComponent("\(id).log.part"))
            #expect(partial.range(of: Data(pat.utf8)) == nil)
            let entry = try #require(try await writer.finish(complete: true))
            let path = try #require(entry.path)
            let text = try String(contentsOfFile: path, encoding: .utf8)
            #expect(!text.contains(pat))
            #expect(text == (index == 3 ? "before [redacted]" : "before [redacted] after\n"))
            #expect(entry.status == .available)
            #expect(!entry.truncated)
        }
    }

    @Test func offlinePendingPullRetriesAndPrioritizesFailures() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        let now = Date(timeIntervalSince1970: 10000)
        for (index, state) in [JobState.done, .failed, .running, .queued].enumerated() {
            let id = state.rawValue
            try await f.ledger.insert(f.job(id, state: state))
            try await f.archive.markPending(jobID: id, now: now.addingTimeInterval(Double(index)))
        }
        let source = FixtureLogSource()
        let pull = LogPull(ledger: f.ledger, archive: f.archive)
        #expect(try await pull.reconcile(source: source, secrets: [], now: now).isEmpty)
        #expect(await source.calledIDs() == ["failed", "done"])
        for id in ["failed", "done"] {
            let pending = try #require(try await f.archive.entry(jobID: id))
            #expect(pending.status == .pending)
            #expect(!(pending.reason ?? "").isEmpty)
            #expect(pending.path == nil)
            #expect(!FileManager.default.fileExists(atPath: f.logs.appendingPathComponent("\(id).log").path))
            #expect(!FileManager.default.fileExists(atPath: f.logs.appendingPathComponent("\(id).log.part").path))
        }
        await source.setOnline()
        let entries = try await pull.reconcile(source: source, secrets: [], now: now.addingTimeInterval(10))
        #expect(entries.map(\.jobID) == ["failed", "done"])
        #expect(await source.calledIDs() == ["failed", "done", "failed", "done"])
        for entry in entries {
            #expect(entry.status == .available)
            #expect(entry.reason == nil)
            let path = try #require(entry.path)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "content for \(entry.jobID)\n")
        }
        for id in ["queued", "running"] {
            #expect(try await f.archive.entry(jobID: id)?.status == .pending)
            #expect(!FileManager.default.fileExists(atPath: f.logs.appendingPathComponent("\(id).log").path))
        }
    }

    @Test func unfinishedAndAbandonedWritersNeverPublishFinalLogs() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        try await f.ledger.insert(f.job("abandoned", state: .running))
        let writer = try f.archive.writer(jobID: "abandoned", secrets: [])
        await writer.write(Data("still running".utf8))
        let final = f.logs.appendingPathComponent("abandoned.log")
        let part = final.appendingPathExtension("part")
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(FileManager.default.fileExists(atPath: part.path))
        #expect(try await f.archive.entry(jobID: "abandoned") == nil)
        try await writer.finish(complete: false)
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(!FileManager.default.fileExists(atPath: part.path))
        #expect(try await f.archive.entry(jobID: "abandoned") == nil)
    }

    @Test func unsafeJobIDsAndSidesThrowWithoutWritingFiles() throws {
        let f = try U2Fixture()
        defer { f.remove() }
        let before = try FileManager.default.subpathsOfDirectory(atPath: f.directory.path).sorted()
        for value in ["/", "..", "", " ", "has space", "../escape", "nested/name"] {
            #expect(throws: LogArchive.Failure.invalidJobID) {
                _ = try f.archive.writer(jobID: value, secrets: [])
            }
            #expect(throws: LogArchive.Failure.invalidJobID) {
                _ = try f.archive.writer(jobID: "safe", side: value, secrets: [])
            }
        }
        #expect(try FileManager.default.subpathsOfDirectory(atPath: f.directory.path).sorted() == before)
        #expect(!FileManager.default.fileExists(atPath: f.logs.path))
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("escape.log").path))
    }

    @Test func quotaEvictsOldestCompletedLogAndKeepsNewerTwo() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        let archive = LogArchive(database: f.database, directory: f.logs, logCap: 4096, quotaBytes: 3000)
        let now = Date(timeIntervalSince1970: 10000)
        for index in 0..<3 {
            let id = "quota-\(index)"
            try await f.ledger.insert(f.job(id, state: .done))
            let writer = try archive.writer(jobID: id, secrets: [])
            await writer.write(Data(repeating: 97, count: 1500))
            try await writer.finish(complete: true, now: now.addingTimeInterval(Double(index)))
        }
        let oldest = try #require(try await archive.entry(jobID: "quota-0"))
        #expect(oldest.status == .unavailable)
        #expect(oldest.reason == "pruned: quota")
        #expect(!FileManager.default.fileExists(atPath: f.logs.appendingPathComponent("quota-0.log").path))
        for id in ["quota-1", "quota-2"] {
            let entry = try #require(try await archive.entry(jobID: id))
            #expect(entry.status == .available)
            #expect(entry.bytes == 1500)
            let path = try #require(entry.path)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(repeating: 97, count: 1500))
        }
    }

    @Test func logDirectoryAndFileHavePrivatePermissions() async throws {
        let f = try U2Fixture()
        defer { f.remove() }
        try await f.ledger.insert(f.job("permissions"))
        let writer = try f.archive.writer(jobID: "permissions", secrets: [])
        await writer.write(Data("private log".utf8))
        let entry = try #require(try await writer.finish(complete: true))
        let path = try #require(entry.path)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: f.logs.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
    }
}
