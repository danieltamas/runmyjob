import Foundation

public struct JobNotice: Sendable, Equatable {
    public enum Kind: String, Sendable { case failed, lost, unreachable, done }

    public let kind: Kind
    public let jobID: String
    public let title: String
    public let body: String
    /// The archived local log, when there is one: the notification's action opens it.
    public let logPath: URL?
}

/// Decides which notifications a change in the ledger deserves. A job is announced once, ever: the ids are kept in the home.
public actor NotificationPlanner {
    /// A job that settled longer ago than this is history, not news.
    static let freshness: TimeInterval = 600
    static let remembered = 5_000

    private let file: URL
    private let archive: LogArchive
    private let ledger: Ledger
    private let secrets: @Sendable () -> [String]
    private let now: @Sendable () -> Date
    private var announced: [String]
    private var announcedSet: Set<String>

    public init(home: RMJHome, archive: LogArchive, secrets: @escaping @Sendable () -> [String] = { [] },
                now: @escaping @Sendable () -> Date = { Date() }) {
        file = home.url.appendingPathComponent("notified.json")
        self.archive = archive
        ledger = Ledger(database: archive.database)
        self.secrets = secrets
        self.now = now
        announced = FileManager.default.contents(atPath: file.path).flatMap { (try? JSONDecoder().decode([String].self, from: $0)) } ?? []
        announcedSet = Set(announced)
    }

    public func settled(_ jobs: [JobRecord], settings: NotificationSettings) async -> [JobNotice] {
        var notices = [JobNotice]()
        var changed = false
        for job in jobs where job.state.isSettled || job.state == .lost {
            guard !announcedSet.contains(job.id) else { continue }
            announcedSet.insert(job.id)
            announced.append(job.id)
            changed = true
            let at = job.endedAt ?? job.startedAt ?? job.queuedAt
            guard now().timeIntervalSince(at) <= Self.freshness else { continue }
            let kind: JobNotice.Kind
            switch job.state {
            case .failed where settings.failures: kind = .failed
            case .lost where settings.failures: kind = .lost
            case .done where settings.done: kind = .done
            default: continue
            }
            notices.append(await notice(kind, job))
        }
        if changed { remember() }
        return notices
    }

    public func unreachable(running jobs: [JobRecord], availability: [String: Availability], settings: NotificationSettings) async -> [JobNotice] {
        guard settings.unreachable else { return [] }
        var notices = [JobNotice]()
        for job in jobs where job.state == .running {
            guard let destination = job.destination, let state = availability[destination], !state.isAvailable else { continue }
            let key = "unreachable|\(job.id)|\(destination)"
            guard announcedSet.insert(key).inserted else { continue }
            announced.append(key)
            remember()
            notices.append(await notice(.unreachable, job, reason: reason(of: state)))
        }
        return notices
    }

    private func notice(_ kind: JobNotice.Kind, _ job: JobRecord, reason: String? = nil) async -> JobNotice {
        let secrets = secrets()
        func text(_ value: String, limit: Int) -> String { Self.text(value, secrets: secrets, limit: limit) }
        let repo = text(job.repo, limit: 100)
        let title = switch kind {
        case .failed: "Job failed: \(repo)"
        case .lost: "Job lost: \(repo)"
        case .done: "Job done: \(repo)"
        case .unreachable: "Destination unreachable: \(text(job.destination ?? job.location, limit: 60))"
        }
        var parts = ["\(repo): \(text(job.command, limit: 120))"]
        parts.append("on \(text(job.destination ?? job.location, limit: 60))")
        switch job.duration {
        case .box(let ms), .mac(let ms): parts.append("took \(PanelFormat.duration(Double(ms) / 1000))")
        case .unknown: break
        }
        let why: String?
        if let reason { why = reason } else { why = await ledgerReason(job) }
        if let why, !why.isEmpty { parts.append(text(why, limit: 200)) }
        return JobNotice(kind: kind, jobID: job.id, title: title, body: parts.joined(separator: ", "), logPath: await logPath(job.id))
    }

    private func reason(of availability: Availability) -> String {
        switch availability {
        case .online: "online"
        case .offline(let why), .unreachable(let why), .rejected(let why): why
        }
    }

    private func ledgerReason(_ job: JobRecord) async -> String? {
        let detail = try? await ledger.events(job.id).last?.detail
        return detail ?? job.fallbackReason
    }

    private func logPath(_ id: String) async -> URL? {
        guard let entry = try? await archive.entry(jobID: id), entry.status == .available, let path = entry.path,
              AgentLog.file(for: entry, in: archive) != nil else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Untrusted text in a notification: escapes and invisible characters out first, so a secret split by them is whole
    /// again, then secrets out, then bounded.
    private static func text(_ value: String, secrets: [String], limit: Int) -> String {
        String(SecretRedactor.scrub(GitHubText.clean(value, limit: 10_000), secrets: secrets).prefix(limit))
    }

    private func remember() {
        if announced.count > Self.remembered {
            announced.removeFirst(announced.count - Self.remembered)
            announcedSet = Set(announced)
        }
        guard let data = try? JSONEncoder().encode(announced), (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
