import Testing
import Foundation
import RMJCore

private func repoChoiceJob(_ repo: String) -> JobRecord {
    JobRecord(id: UUID().uuidString, repo: repo, command: "true", location: "local",
              queuedAt: Date(timeIntervalSince1970: 0))
}

private func repoChoiceRules() -> Rules {
    var rules = Rules.shipped
    for key in Array(rules.tenants.keys) { rules.tenants[key]?.repos = nil }
    for key in Array(rules.destinations.keys) { rules.destinations[key]?.runnerTargets = nil }
    for index in rules.rules.indices { rules.rules[index].match.repo = nil }
    return rules
}

struct RepoChoicesAcceptanceTests {
    @Test func noJobsAndNilRulesOfferNoRepos() {
        #expect(RepoChoices.known(jobs: [], rules: nil).isEmpty)
    }

    @Test func jobsAloneAreUniqueAndSortedCaseInsensitively() {
        let jobs = ["zebra", "Beta", "alpha", "Beta"].map(repoChoiceJob)
        #expect(RepoChoices.known(jobs: jobs, rules: nil) == ["alpha", "Beta", "zebra"])
    }

    @Test func everyTenantDestinationAndRuleContributesRepos() {
        var rules = repoChoiceRules()
        rules.tenants["acme"]?.repos = ["tenant-one"]
        rules.tenants["globex"]?.repos = ["tenant-two"]
        rules.tenants["personal"]?.repos = ["app-*"]
        rules.destinations["ai-eu-1"]?.runnerTargets = ["runner-one", "org:Acme"]
        rules.destinations["s1"]?.runnerTargets = ["runner-two", "org:globex"]
        rules.rules[0].match.repo = ["rule-one"]
        rules.rules[3].match.repo = ["rule-two"]
        #expect(RepoChoices.known(jobs: [repoChoiceJob("job-only")], rules: rules) == [
            "app-*", "job-only", "rule-one", "rule-two", "runner-one", "runner-two",
            "tenant-one", "tenant-two"
        ])
    }

    @Test func duplicatesWithinAndAcrossAllSourcesAppearOnce() {
        var rules = repoChoiceRules()
        rules.tenants["acme"]?.repos = ["shared", "shared"]
        rules.tenants["globex"]?.repos = ["shared"]
        rules.destinations["ai-eu-1"]?.runnerTargets = ["shared", "shared"]
        rules.destinations["s1"]?.runnerTargets = ["shared"]
        rules.rules[0].match.repo = ["shared", "shared"]
        rules.rules[3].match.repo = ["shared"]
        #expect(RepoChoices.known(jobs: [repoChoiceJob("shared"), repoChoiceJob("shared")],
                                  rules: rules) == ["shared"])
    }

    @Test func emptyAndBlankNamesAreExcludedFromEverySource() {
        var rules = repoChoiceRules()
        let blanks = ["", " ", "   ", "\t"]
        rules.tenants["acme"]?.repos = blanks
        rules.destinations["ai-eu-1"]?.runnerTargets = blanks + ["org:OnlyOrg"]
        rules.rules[0].match.repo = blanks
        #expect(RepoChoices.known(jobs: blanks.map(repoChoiceJob), rules: rules).isEmpty)
    }

    @Test func absentOptionalRepoListsOfferNoRepos() {
        #expect(RepoChoices.known(jobs: [], rules: repoChoiceRules()).isEmpty)
        #expect(RepoChoices.known(jobs: [], rules: Rules()).isEmpty)
    }
}
