import Foundation
import Testing
import RMJCore

private let noticeNow = Date(timeIntervalSince1970: 1_793_145_600)

private struct NoticeFixture {
    let home: RMJHome
    let database: Database
    let ledger: Ledger
    let archive: LogArchive
    var config: URL { home.url.appendingPathComponent("config.json") }
    var settings: NotificationSettings { NotificationSettings.load(home: home) }

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-notice-\(UUID())")
        home = RMJHome(environment: ["RMJ_HOME": root.path])
        try home.prepare()
        database = try Database(url: root.appendingPathComponent("rmj.sqlite"))
        ledger = Ledger(database: database)
        archive = LogArchive(database: database, directory: root.appendingPathComponent("logs"))
    }

    func remove() { try? FileManager.default.removeItem(at: home.url) }
    func planner(secrets: [String] = []) -> NotificationPlanner {
        NotificationPlanner(home: home, archive: archive, secrets: { secrets }, now: { noticeNow })
    }
    func running(_ n: Int, command: String = "cargo test") -> JobRecord {
        var job = JobRecord(id: "01J00000000000" + String(format: "%012d", n),
                            repo: "acme/ledger", command: command, location: "box-a",
                            destination: "box-a", state: .running,
                            queuedAt: noticeNow.addingTimeInterval(-200))
        job.startedAt = noticeNow.addingTimeInterval(-180)
        return job
    }
    func settled(_ n: Int, state: JobState = .failed, command: String = "cargo test",
                 reason: String = "compiler exited 1", age: TimeInterval = 5) async throws -> JobRecord {
        let end = noticeNow.addingTimeInterval(-age)
        var job = running(n, command: command)
        job.queuedAt = end.addingTimeInterval(-200)
        job.startedAt = end.addingTimeInterval(-180)
        try await ledger.insert(job)
        var patch = JobPatch()
        patch.endedAt = end
        patch.boxStartedAt = end.addingTimeInterval(-166)
        patch.boxEndedAt = end
        patch.macElapsedMS = 999_000
        patch.exitCode = state == .done ? 0 : 1
        try await ledger.advance(job.id, to: state, at: end, detail: reason, patch: patch)
        return try #require(try await ledger.job(job.id))
    }
    func writeLog(_ job: JobRecord) async throws -> URL {
        let writer = try archive.writer(jobID: job.id, secrets: [], now: noticeNow)
        await writer.write(Data("compiler output\n".utf8))
        try await writer.finish(complete: true, now: noticeNow)
        return archive.directory.appendingPathComponent("\(job.id).log")
    }
}

private func noticeMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}

struct NotificationAcceptanceTests {
    @Test("A failed job announces its repo command destination box duration and reason")
    func failedJobDetails() async throws {
        let f = try NoticeFixture()
        defer { f.remove() }
        let job = try await f.settled(1)
        let notices = await f.planner().settled([job], settings: f.settings)
        #expect(notices.count == 1)
        let notice = try #require(notices.first)
        #expect(notice.kind == .failed)
        #expect(notice.jobID == job.id)
        #expect(notice.title.contains("acme/ledger"))
        for text in ["acme/ledger", "cargo test", "box-a", "2m 46s", "compiler exited 1"] {
            #expect(notice.body.contains(text))
        }
    }

    @Test("A job is announced once across repeated calls and planner restarts")
    func persistedDedupe() async throws {
        let f = try NoticeFixture()
        defer { f.remove() }
        let job = try await f.settled(1)
        let planner = f.planner()
        #expect(await planner.settled([job], settings: f.settings).count == 1)
        #expect(await planner.settled([job], settings: f.settings).isEmpty)
        #expect(await f.planner().settled([job], settings: f.settings).isEmpty)
        #expect(try noticeMode(f.home.url.appendingPathComponent("notified.json")) == 0o600)
    }

    @Test("Secrets in commands and event details never appear in notices")
    func secretRedaction() async throws {
        let f = try NoticeFixture()
        defer { f.remove() }
        let secret = "ghp_noticeSecretValue1234567890"
        let job = try await f.settled(1, command: "cargo test --token \(secret)", reason: "rejected \(secret)")
        _ = try await f.writeLog(job)
        let notices = await f.planner(secrets: [secret]).settled([job], settings: f.settings)
        #expect(notices.count == 1)
        for notice in notices {
            #expect(!notice.title.contains(secret))
            #expect(!notice.body.contains(secret))
            let path = notice.logPath?.absoluteString ?? ""
            #expect(path.contains(secret) == false)
        }
    }

    @Test("Only available logs inside the archive become notice actions")
    func archivedLogPaths() async throws {
        let f = try NoticeFixture()
        defer { f.remove() }
        var jobs: [JobRecord] = []
        for n in 1...5 { jobs.append(try await f.settled(n)) }
        let expected = try await f.writeLog(jobs[0])
        try await f.archive.markPending(jobID: jobs[1].id, now: noticeNow)
        try await f.archive.markUnavailable(jobID: jobs[2].id, reason: "not found", now: noticeNow)
        _ = try await f.writeLog(jobs[4])
        // A real existing file beside logs must not become an action through a corrupt row.
        let outside = f.home.url.appendingPathComponent("outside.log")
        try Data("private".utf8).write(to: outside)
        try await f.database.execute("UPDATE log_archive SET path = ? WHERE job_id = ?",
                                     [.text(outside.path), .text(jobs[4].id)])
        let notices = await f.planner().settled(jobs, settings: f.settings)
        #expect(notices.count == 5)
        let byID = Dictionary(uniqueKeysWithValues: notices.map { ($0.jobID, $0) })
        #expect(try #require(byID[jobs[0].id]).logPath?.standardizedFileURL == expected.standardizedFileURL)
        for job in jobs.dropFirst() { #expect(try #require(byID[job.id]).logPath == nil) }
        for path in notices.compactMap(\.logPath) {
            #expect(path.standardizedFileURL.deletingLastPathComponent() == f.archive.directory.standardizedFileURL)
        }
    }

    @Test("Lost and successful jobs follow the failure and done settings")
    func outcomeSettings() async throws {
        let f = try NoticeFixture()
        defer { f.remove() }
        let lost = try await f.settled(1, state: .lost, reason: "destination rebooted")
        let done = try await f.settled(2, state: .done)
        let notices = await f.planner().settled([lost, done], settings: f.settings)
        #expect(notices.map(\.kind) == [.lost])
        #expect(notices.first?.jobID == lost.id)
        var enabled = f.settings
        enabled.done = true
        let anotherDone = try await f.settled(3, state: .done)
        let success = await f.planner().settled([anotherDone], settings: enabled)
        #expect(success.map(\.kind) == [.done])
        #expect(success.first?.jobID == anotherDone.id)
        var disabled = f.settings
        disabled.failures = false
        let failed = try await f.settled(4)
        let anotherLost = try await f.settled(5, state: .lost)
        #expect(await f.planner().settled([failed, anotherLost], settings: disabled).isEmpty)
    }

    @Test("Old history is silent on first call and a later settlement is announced")
    func historyIsNotNews() async throws {
        let f = try NoticeFixture()
        defer { f.remove() }
        let old = try await f.settled(1, age: 601)
        let running = f.running(2)
        try await f.ledger.insert(running)
        let planner = f.planner()
        #expect(await planner.settled([old, running], settings: f.settings).isEmpty)
        var patch = JobPatch()
        patch.endedAt = noticeNow
        try await f.ledger.advance(running.id, to: .failed, at: noticeNow, detail: "failed later", patch: patch)
        let later = try #require(try await f.ledger.job(running.id))
        let notices = await planner.settled([old, later], settings: f.settings)
        #expect(notices.map(\.jobID) == [later.id])
        #expect(notices.first?.kind == .failed)
    }

    @Test("Unreachable destinations announce once per running job and respect settings")
    func unreachableJobs() async throws {
        let f = try NoticeFixture()
        defer { f.remove() }
        let planner = f.planner()
        let first = f.running(1)
        let second = f.running(2)
        let offline: [String: Availability] = ["box-a": .offline("tailnet down: stopped")]
        let notices = await planner.unreachable(running: [first], availability: offline, settings: f.settings)
        #expect(notices.count == 1)
        #expect(notices.first?.kind == .unreachable)
        #expect(notices.first?.jobID == first.id)
        #expect(await planner.unreachable(running: [first], availability: offline, settings: f.settings).isEmpty)
        let next = await planner.unreachable(running: [second], availability: offline, settings: f.settings)
        #expect(next.map(\.jobID) == [second.id])
        #expect(next.first?.kind == .unreachable)
        #expect(await planner.unreachable(running: [f.running(3)],
                    availability: ["box-a": .online(address: "100.64.0.10")], settings: f.settings).isEmpty)
        var disabled = f.settings
        disabled.unreachable = false
        #expect(await planner.unreachable(running: [f.running(4)], availability: offline, settings: disabled).isEmpty)
    }

    @Test("Notice text strips terminal escapes and invisible Unicode from commands")
    func untrustedText() async throws {
        let f = try NoticeFixture()
        defer { f.remove() }
        let job = try await f.settled(1, command: "cargo \u{1B}[31mtest\u{1B}[0m\u{200B}")
        let notices = await f.planner().settled([job], settings: f.settings)
        #expect(notices.count == 1)
        let notice = try #require(notices.first)
        #expect(notice.body.contains("cargo test"))
        for text in [notice.title, notice.body] {
            #expect(!text.contains("\u{1B}"))
            #expect(!text.contains("\u{200B}"))
            #expect(!text.contains("[31m"))
            #expect(!text.contains("[0m"))
        }
    }

    @Test("Notification settings default safely and round trip without losing unrelated keys")
    func settingsPersistence() throws {
        let f = try NoticeFixture()
        defer { f.remove() }
        let defaults = f.settings
        #expect(defaults.failures)
        #expect(defaults.unreachable)
        #expect(!defaults.done)
        try Data("{malformed".utf8).write(to: f.config)
        #expect(f.settings == defaults)
        let original: [String: Any] = ["look": "glass", "agent_access": true,
                                       "custom": ["enabled": true, "count": 7]]
        try JSONSerialization.data(withJSONObject: original).write(to: f.config)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.config.path)
        var changed = defaults
        changed.failures = false
        changed.unreachable = false
        changed.done = true
        try NotificationSettings.save(changed, home: f.home)
        #expect(f.settings == changed)
        #expect(try noticeMode(f.config) == 0o600)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: f.config)) as? [String: Any])
        #expect(saved["look"] as? String == "glass")
        #expect(saved["agent_access"] as? Bool == true)
        #expect(NSDictionary(dictionary: try #require(saved["custom"] as? [String: Any]))
            .isEqual(try #require(original["custom"] as? [String: Any])))
        #expect(saved["notify_failures"] as? Bool == false)
        #expect(saved["notify_unreachable"] as? Bool == false)
        #expect(saved["notify_done"] as? Bool == true)
        try NotificationSettings.save(defaults, home: f.home)
        #expect(f.settings == defaults)
    }
}
