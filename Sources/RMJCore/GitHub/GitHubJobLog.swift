import Foundation

/// The archived copy of a GitHub job's log: `gh run view --job <id> --log`, written through the
/// same redacting, capped writer as every other log.
public enum GitHubJobLog {
    public typealias Fetch = @Sendable (_ repo: String, _ jobId: Int64, _ token: String?) async throws -> Data

    /// Archives the log of one finished GitHub job; the reason it could not be, or nil when it is
    /// in `~/.rmj/logs/<id>.log`. A job that is still running is refused: a running log is never final.
    public static func archive(ledgerID: String, ledger: Ledger, archive: LogArchive, secrets: [String],
                               token: @Sendable (String) -> String? = { _ in nil }, fetch: Fetch = Self.ghFetch) async -> String? {
        guard let job = try? await ledger.job(ledgerID), let info = GitHubJobInfo.decode(job.github) else { return "not a GitHub job" }
        guard job.state != .queued, job.state != .running else { return "the job is still running" }
        let data: Data
        do { data = try await fetch(info.repo, info.jobId, token(String(info.repo.split(separator: "/").first ?? ""))) } catch {
            let reason = SecretRedactor.scrub(GitHubText.clean(error.localizedDescription, limit: 300), secrets: secrets)
            try? await archive.markPending(jobID: ledgerID, side: "local", reason: reason)
            return reason
        }
        do {
            let writer = try archive.writer(jobID: ledgerID, side: "local", secrets: secrets)
            await writer.write(data)
            try await writer.finish(complete: true)
        } catch { return GitHubText.clean("cannot write the log: \(error.localizedDescription)", limit: 300) }
        return nil
    }

    public static let ghFetch: Fetch = { repo, jobId, token in
        guard let gh = Executables.resolve("gh") else { throw GHCLI.Failure(message: "gh is not installed") }
        var environment = ["PATH": Executables.searchPath(for: gh)]
        if let token { environment["GH_TOKEN"] = token }
        let output = try await ProcessRunner().run(gh, ["run", "view", "--job", String(jobId), "-R", repo, "--log"],
                                                   environment: environment, timeout: .seconds(120))
        guard output.status == 0 else {
            throw GHCLI.Failure(message: "gh run view failed: \(UntrustedText.clean(output.stderr.split(separator: "\n").first.map(String.init) ?? "no output", limit: 200))")
        }
        return output.stdout
    }
}
