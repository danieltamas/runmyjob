import Foundation

/// Where a completed run's log is read from (the box, in practice); a test supplies a fixture.
public protocol LogSource: Sendable {
    func pull(jobID: String, into writer: LogWriter) async throws
}

public struct LogPull: Sendable {
    public let ledger: Ledger
    public let archive: LogArchive

    public init(ledger: Ledger, archive: LogArchive) {
        self.ledger = ledger
        self.archive = archive
    }

    /// Pulls every pending log of a run that has stopped running. A pull that cannot happen (box
    /// offline, Mac asleep) leaves the entry `pending` with the reason, to be retried next time.
    @discardableResult
    public func reconcile(source: LogSource, secrets: [String], now: Date = Date()) async throws -> [LogEntry] {
        var pulled = [LogEntry]()
        let waiting = try await archive.pending()
        var ordered = [(LogEntry, JobState)]()
        for entry in waiting {
            guard let job = try await ledger.job(entry.jobID), job.state != .queued, job.state != .syncing, job.state != .running else { continue }
            ordered.append((entry, job.state))
        }
        // Failed and lost runs are the ones someone is waiting to read.
        ordered.sort { ($0.1 == .failed || $0.1 == .lost ? 0 : 1) < ($1.1 == .failed || $1.1 == .lost ? 0 : 1) }
        for (entry, _) in ordered where entry.side == "box" {
            let writer: LogWriter
            do {
                writer = try archive.writer(jobID: entry.jobID, side: entry.side, secrets: secrets, now: now)
            } catch let error as DatabaseError {
                try await archive.markUnavailable(jobID: entry.jobID, side: entry.side,
                                                  reason: error.code == ENOSPC ? "disk full" : UntrustedText.clean(error.message), now: now)
                continue
            }
            do {
                try await source.pull(jobID: entry.jobID, into: writer)
                if let done = try await writer.finish(complete: true, now: now) { pulled.append(done) }
            } catch {
                try await writer.finish(complete: false, now: now)
                try await archive.markPending(jobID: entry.jobID, side: entry.side,
                                              reason: SecretRedactor.scrub(UntrustedText.clean(error.localizedDescription), secrets: secrets), now: now)
            }
        }
        return pulled
    }
}
