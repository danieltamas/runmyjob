import Foundation

/// Which destination serves a GitHub job. RMJ does not route these: the workflow's `runs-on` labels
/// and the registered runners decide, and this only shows the mapping.
public enum GitHubRouting {
    /// Destinations that have a registered runner carrying every label, sorted.
    public static func servedBy(labels: [String], registrations: [RunnerRegistration]) -> [String] {
        let wanted = Set(labels.map { $0.lowercased() })
        let served = registrations.filter { wanted.isSubset(of: Set($0.labels.map { $0.lowercased() })) }.compactMap(\.destination)
        return Array(Set(served)).sorted()
    }

    /// A self-hosted label set that no destination serves is a mismatch worth showing; GitHub-hosted
    /// labels (no `self-hosted`) are not RMJ's to map.
    public static func isMismatch(labels: [String], registrations: [RunnerRegistration]) -> Bool {
        labels.contains { $0.lowercased() == "self-hosted" } && servedBy(labels: labels, registrations: registrations).isEmpty
    }

    /// Where a repo's runners are registered: `owner/name` and `org:owner` entries of a destination's
    /// `runner_targets`, matched case-insensitively. Returns the destinations that register runners for it.
    /// A destination never serves a repo of another tenant, whatever its targets say: rules are validated on save,
    /// and this holds for a value that was not.
    public static func destinations(forRepo repo: String, rules: Rules) -> [String] {
        let owner = repo.split(separator: "/").first.map { String($0).lowercased() } ?? ""
        return rules.destinations.filter { name, destination in
            let tenant = rules.tenants[destination.tenant]
            let others = rules.tenants.filter { $0.key != destination.tenant }.map(\.value)
            let claimedByOther = others.contains { RulesValidation.matches($0, repo: repo) }
            if claimedByOther, !(tenant.map { RulesValidation.matches($0, repo: repo) } ?? false) { return false }
            return (destination.runnerTargets ?? []).contains { target in
                guard RulesValidation.tenant(tenant, owns: target, others: others) else { return false }
                let target = target.lowercased()
                return target == repo.lowercased() || target == "org:\(owner)"
            }
        }.keys.sorted()
    }
}

/// `gh run rerun`, bound to the repo and run recorded in the ledger row.
public enum GitHubRerun {
    public enum Failure: Error, Equatable { case unknownJob, notFinished, notGitHub, superseded }

    /// `--failed` only when the run has failed jobs and the selected job is one of them.
    public static func argv(ledger: Ledger, jobID: String) async throws -> [String] {
        guard let row = try await ledger.job(jobID) else { throw Failure.unknownJob }
        guard let info = GitHubJobInfo.decode(row.github) else { throw Failure.notGitHub }
        guard row.state.isSettled else { throw Failure.notFinished }
        let ofRun = try await ledger.jobs().compactMap { row in
            GitHubJobInfo.decode(row.github).flatMap { $0.repo == info.repo && $0.runId == info.runId ? (row, $0) : nil }
        }
        // A newer attempt exists: rerunning this one would act on a run that has moved on.
        guard !ofRun.contains(where: { $0.1.runAttempt > info.runAttempt }) else { throw Failure.superseded }
        let failedRun = ofRun.contains { $0.1.runAttempt == info.runAttempt && $0.0.state == .failed }
        var argv = ["gh", "run", "rerun", String(info.runId), "-R", info.repo]
        if failedRun, row.state == .failed { argv.append("--failed") }
        return argv
    }

    public static func rerun(ledger: Ledger, jobID: String, execute: @Sendable ([String]) async throws -> Void) async throws {
        try await execute(try await argv(ledger: ledger, jobID: jobID))
    }
}
