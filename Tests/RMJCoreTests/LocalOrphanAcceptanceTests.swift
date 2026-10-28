import Darwin
import Foundation
import Testing
import RMJCore

struct LocalOrphanAcceptanceTests {
    @Test func oldLocalRunWithoutClientBecomesLostWithExplanation() async throws {
        let f = try LocalOrphanFixture(); defer { f.remove() }
        let id = try await f.insert()
        let events = try await f.ledger.events(id)

        #expect(await f.settle() == [id])
        #expect(try await f.ledger.job(id)?.state == .lost)
        let after = try await f.ledger.events(id)
        #expect(after.count == events.count + 1)
        #expect(after.last?.detail == "client stopped before the command finished")
    }

    @Test func oldLocalRunWithLivingClientStaysRunning() async throws {
        let f = try LocalOrphanFixture(); defer { f.remove() }
        let id = try await f.insert()
        try f.writeClient(id, pid: getpid())
        let before = try await f.ledger.job(id)
        let events = try await f.ledger.events(id)

        #expect(await f.settle().isEmpty)
        #expect(try await f.ledger.job(id)?.state == .running)
        #expect(try await f.ledger.job(id) == before)
        #expect(try await f.ledger.events(id) == events)
    }

    @Test func oldLocalRunWithExitedClientBecomesLost() async throws {
        let f = try LocalOrphanFixture(); defer { f.remove() }
        let id = try await f.insert()
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try client.run()
        let pid = client.processIdentifier
        client.waitUntilExit()
        #expect(client.terminationStatus == 0)
        try f.writeClient(id, pid: pid)

        #expect(await f.settle() == [id])
        #expect(try await f.ledger.job(id)?.state == .lost)
        #expect(try await f.ledger.events(id).last?.detail == "client stopped before the command finished")
    }

    @Test func youngLocalRunWithoutClientIsUntouched() async throws {
        let f = try LocalOrphanFixture(); defer { f.remove() }
        let id = try await f.insert(age: Reconciler.localGrace / 2)
        let before = try await f.ledger.job(id)
        let events = try await f.ledger.events(id)

        #expect(await f.settle().isEmpty)
        #expect(try await f.ledger.job(id) == before)
        #expect(try await f.ledger.events(id) == events)
    }

    @Test func githubBoxAndSettledRowsAreUntouched() async throws {
        let f = try LocalOrphanFixture(); defer { f.remove() }
        let github = try await f.insert(github: "{}")
        let box = try await f.insert(location: "acme-box")
        var ids = [github, box]
        for state in JobState.allCases where state.isSettled {
            ids.append(try await f.insert(state: state))
        }
        var rows = [JobRecord]()
        var events = [[Ledger.Event]]()
        for id in ids {
            rows.append(try #require(try await f.ledger.job(id)))
            events.append(try await f.ledger.events(id))
        }
        // An eligible row makes this a selective reconciliation rather than an empty scan.
        let orphan = try await f.insert()

        #expect(await f.settle() == [orphan])
        for (index, id) in ids.enumerated() {
            #expect(try await f.ledger.job(id) == rows[index])
            #expect(try await f.ledger.events(id) == events[index])
        }
    }

    @Test func settlingLocalOrphanTwiceLeavesRowAndEventsUnchanged() async throws {
        let f = try LocalOrphanFixture(); defer { f.remove() }
        let id = try await f.insert()
        #expect(await f.settle() == [id])
        let before = try await f.ledger.job(id)
        let events = try await f.ledger.events(id)

        #expect(await f.settle().isEmpty)
        #expect(try await f.ledger.job(id) == before)
        #expect(try await f.ledger.events(id) == events)
    }
}

private struct LocalOrphanFixture {
    let root: URL
    let ledger: Ledger
    let archive: LogArchive
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-local-orphan-" + UUID().uuidString)
        let home = RMJHome(environment: ["RMJ_HOME": root.path])
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        let database = try Database(url: home.url.appendingPathComponent("ledger.sqlite"))
        ledger = Ledger(database: database)
        archive = LogArchive(database: database, directory: home.url.appendingPathComponent("logs"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func insert(state: JobState = .running, age: TimeInterval = Reconciler.localGrace + 1,
                location: String = "local", github: String? = nil) async throws -> String {
        let id = ULID.make()
        var row = JobRecord(id: id, repo: "acme/ledger", command: "true", location: location,
                            state: state, queuedAt: now.addingTimeInterval(-age))
        row.github = github
        try await ledger.insert(row)
        return id
    }

    func writeClient(_ id: String, pid: pid_t) throws {
        try FileManager.default.createDirectory(at: archive.directory, withIntermediateDirectories: true)
        try Data("\(pid)\n".utf8).write(to: archive.directory.appendingPathComponent("\(id).client"))
    }

    func settle() async -> [String] {
        await Reconciler.settleLocal(ledger: ledger, archive: archive, now: now)
    }
}
