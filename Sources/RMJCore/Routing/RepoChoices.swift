import Foundation

/// The repos the rule editor offers in its picker: every repo RMJ has seen or been told about, so a rule is built by
/// choosing, not by typing.
public enum RepoChoices {
    /// Repos of the jobs, the tenants' repos and the destinations' repo runner targets, sorted, without duplicates,
    /// and without org targets or empty names.
    public static func known(jobs: [JobRecord], rules: Rules?) -> [String] {
        var found = Set(jobs.map(\.repo))
        for tenant in rules?.tenants.values ?? [:].values { found.formUnion(tenant.repos ?? []) }
        for destination in rules?.destinations.values ?? [:].values {
            found.formUnion((destination.runnerTargets ?? []).filter { !$0.hasPrefix("org:") })
        }
        for rule in rules?.rules ?? [] { found.formUnion(rule.match.repo ?? []) }
        return found.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
