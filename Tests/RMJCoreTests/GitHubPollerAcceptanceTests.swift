import Testing
import Foundation
import RMJCore

struct GitHubPollerAcceptanceTests {
    @Test func pollerStoresTimeoutAndSkippedConclusions() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        await f.api.set(f.repo, runs: [f.run()], jobs: [f.job(10, conclusion: "timed_out"), f.job(11, conclusion: "skipped")])
        _ = try await f.poller().poll(repo: f.repo)
        for (id, state, conclusion) in [(Int64(10), JobState.failed, "timed_out"), (11, .skipped, "skipped")] {
            let row = try await f.row(id)
            #expect(row.id == GitHubMapping.ledgerID(jobID: id, attempt: 1))
            #expect(row.state == state)
            #expect(GitHubJobInfo.decode(row.github)?.conclusion == conclusion)
        }
    }

    @Test func attemptProgressUpdatesSameRowWithoutStateEvent() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let poller = f.poller()
        var job = f.job(status: "in_progress", conclusion: nil)
        job.startedAt = f.clock.now().addingTimeInterval(-50)
        job.runnerName = "runner-a"
        job.steps = [GHStep(name: "Set up job", status: "completed", conclusion: "success", number: 1),
                     GHStep(name: "Checkout", status: "completed", conclusion: "success", number: 2),
                     GHStep(name: "Build", status: "in_progress", conclusion: nil, number: 3),
                     GHStep(name: "Test", status: "queued", conclusion: nil, number: 4)]
        await f.api.set(f.repo, runs: [f.run(status: "in_progress")], jobs: [job])
        _ = try await poller.poll(repo: f.repo)
        let first = try await f.info()
        #expect(first.runId == 1 && first.jobId == 10 && first.runAttempt == 1)
        #expect(first.status == "in_progress" && first.conclusion == nil)
        #expect(first.createdAt == job.createdAt && first.startedAt == job.startedAt && first.completedAt == nil)
        #expect(first.runnerName == "runner-a" && first.labels == job.labels)
        #expect(first.currentStep == "Build" && first.currentStepNumber == 3)
        #expect(first.stepsDone == 2 && first.stepsTotal == 4)
        let row = try await f.row()
        #expect(row.tenant == "acme" && row.agent == "github")
        let events = try await f.ledger.events(row.id)
        job.steps?[2].status = "completed"; job.steps?[2].conclusion = "success"
        job.steps?[3].status = "in_progress"
        await f.api.set(f.repo, runs: [f.run(status: "in_progress")], jobs: [job])
        _ = try await poller.poll(repo: f.repo)
        let updated = try await f.info()
        #expect(updated.currentStep == "Test" && updated.currentStepNumber == 4 && updated.stepsDone == 3)
        #expect(try await f.ledger.jobs().count == 1)
        #expect(try await f.ledger.events(row.id) == events)
        job.status = "completed"; job.conclusion = "success"; job.completedAt = f.clock.now()
        await f.api.set(f.repo, runs: [f.run()], jobs: [job])
        _ = try await poller.poll(repo: f.repo)
        let settled = try await f.info()
        #expect(settled.currentStep == nil && settled.currentStepNumber == nil)
        #expect(settled.completedAt == job.completedAt && settled.conclusion == "success")
    }

    @Test func queuedObservationAndRegistrationRowsRequireEvidence() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let poller = f.poller(token: { _ in "fixture_org_token" })
        await f.api.register("/orgs/acme/actions/runners", [])
        let job = f.job(status: "queued", conclusion: nil)
        let path = "/repos/\(f.repo)/actions/runners"
        let stale = RunnerRegistration(name: "runner-stale", labels: job.labels, online: false, busy: false)
        await f.api.register(path, [stale])
        await f.api.set(f.repo, runs: [f.run(status: "queued")], jobs: [job])
        _ = try await poller.poll(repo: f.repo)
        let first = try await f.info()
        #expect(first.observation?.summary == "0 online, 1 offline idle (runner-stale)")
        #expect(first.observation?.suspectedCause == "stale registration")
        #expect(first.observation?.observedAt == f.clock.now())
        let registrations = try await f.ledger.database.query("SELECT destination, runner, status, busy FROM runner_registration")
        #expect(registrations.count == 1)
        #expect(registrations.first?["destination"]?.textValue == "ai-eu-1")
        #expect(registrations.first?["runner"]?.textValue == "runner-stale")
        #expect(registrations.first?["status"]?.textValue == "offline")
        #expect(registrations.first?["busy"]?.intValue == 0)
        var idle = stale; idle.name = "runner-idle"; idle.online = true
        await f.api.register(path, [stale, idle])
        _ = try await poller.poll(repo: f.repo)
        #expect(try await f.info().observation?.suspectedCause == "unknown")
        var waiting = job; waiting.id = 11; waiting.status = "waiting"
        await f.api.set(f.repo, runs: [f.run(status: "in_progress")], jobs: [waiting])
        _ = try await poller.poll(repo: f.repo)
        let dependency = try await f.info(11)
        #expect(dependency.waitingOnDependency && dependency.observation == nil)
        let unavailable = try U5Fixture(); defer { unavailable.remove() }
        await unavailable.api.set(unavailable.repo, runs: [unavailable.run(status: "queued")], jobs: [unavailable.job(status: "queued", conclusion: nil)])
        _ = try await unavailable.poller().poll(repo: unavailable.repo)
        #expect(try await unavailable.info().observation == nil)
        #expect(try await unavailable.ledger.database.query("SELECT * FROM runner_registration").isEmpty)
    }

    @Test func paginatedRunsRespectThirtyDaysAndConditionalSettledPolls() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let poller = f.poller()
        var runs = (1...250).map { f.run(Int64($0), age: Double($0) * 3600) }
        runs.append(f.run(999, age: 31 * 86400))
        let jobs = runs.map { f.job($0.id + 1000, run: $0.id) }
        await f.api.set(f.repo, runs: runs, jobs: jobs)
        await f.api.tag(f.repo, "runs-v1")
        _ = try await poller.poll(repo: f.repo)
        #expect(try await f.ledger.jobs().count == 250)
        #expect(try await f.ledger.job("gh-1999-1") == nil)
        let calls = await f.api.recorded()
        let lists = calls.filter { $0.path == "/repos/\(f.repo)/actions/runs" }
        #expect(lists.map { $0.query["page"] } == ["1", "2", "3"])
        #expect(calls.allSatisfy { $0.query["per_page"] == "100" })
        #expect(!calls.contains { $0.path.contains("/runs/999/") })
        let floor = try #require(lists.first?.query["created"])
        #expect(floor.hasPrefix(">="))
        let since = try #require(ISO8601DateFormatter().date(from: String(floor.dropFirst(2))))
        #expect(abs(since.timeIntervalSince(f.clock.now().addingTimeInterval(-30 * 86400))) < 3600)
        await f.api.clear()
        _ = try await poller.poll(repo: f.repo)
        let unchanged = await f.api.recorded()
        #expect(unchanged.count <= 1)
        #expect(unchanged.first?.etag == "runs-v1")
        #expect(!unchanged.contains { $0.path.hasSuffix("/jobs") })
        #expect(try await f.ledger.jobs().count == 250)
    }

    @Test func gapBackfillFollowsPagesAndRefreshesOldUnfinishedRunByID() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let poller = f.poller()
        // Created six days before the gap: it falls outside the next incremental listing.
        let old = f.run(1, status: "queued", age: 6 * 86400)
        await f.api.set(f.repo, runs: [old], jobs: [f.job(status: "queued", conclusion: nil)])
        _ = try await poller.poll(repo: f.repo)
        f.clock.advance(7 * 86400)
        var settled = old; settled.status = "completed"; settled.conclusion = "success"
        let newRuns = (2...41).map { f.run(Int64($0), age: Double($0 - 1) * 14000) }
        await f.api.set(f.repo, runs: [settled] + newRuns, jobs: [f.job()] + newRuns.map { f.job($0.id + 1000, run: $0.id) })
        await f.api.cap(10)
        await f.api.clear()
        _ = try await poller.poll(repo: f.repo)
        #expect(try await f.ledger.jobs().count == 41)
        #expect(try await f.row().state == .done)
        let calls = await f.api.recorded()
        #expect(calls.contains { $0.path == "/repos/\(f.repo)/actions/runs/1" })
        #expect(calls.filter { $0.path == "/repos/\(f.repo)/actions/runs" }.count == 4)
    }

    @Test func rateLimitPersistsAcrossRestartAndSuppressesAllRequestsUntilReset() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let poller = f.poller()
        let reset = f.clock.now().addingTimeInterval(600)
        await f.api.limit(reset)
        #expect(try await poller.poll(repo: f.repo).rateLimited)
        #expect(await poller.rateLimitedUntil() == reset)
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        let footer = await poller.footer()
        #expect(footer.contains("rate limit") && footer.contains(formatter.string(from: reset)))
        let count = await f.api.recorded().count
        #expect(try await poller.poll(repo: f.repo).rateLimited)
        let restarted = f.poller()
        #expect(await restarted.rateLimitedUntil() == reset)
        #expect(try await restarted.poll(repo: f.repo).rateLimited)
        #expect(await f.api.recorded().count == count)
        f.clock.advance(601); await f.api.limit(nil)
        await f.api.set(f.repo, runs: [], jobs: [])
        #expect(try await restarted.poll(repo: f.repo).rateLimited == false)
        #expect(await restarted.rateLimitedUntil() == nil)
        #expect(await f.api.recorded().count > count)
    }

    @Test func pollingIntervalsReflectLedgerActivityAndFooter() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let poller = f.poller()
        #expect(GitHubPoller.activeInterval == 15 && GitHubPoller.idleInterval == 120)
        #expect(GitHubPoller.quietInterval == 300)
        #expect(try await poller.interval(for: f.repo) == 300)
        try await f.ledger.insert(JobRecord(id: "gh-settled-1", repo: f.repo, command: "CI", location: "github-hosted", state: .done, queuedAt: f.clock.now()))
        #expect(try await poller.interval(for: f.repo) == 120)
        f.clock.advance(86_400 + 60)
        #expect(try await poller.interval(for: f.repo) == 300)
        for (id, state) in [("gh-q-1", JobState.queued), ("gh-r-1", .running)] {
            let repo = f.repo + id
            try await f.ledger.insert(JobRecord(id: id, repo: repo, command: "CI", location: "github-hosted", state: state, queuedAt: f.clock.now()))
            #expect(try await poller.interval(for: repo) == 15)
        }
        let footer = await poller.footer()
        #expect(footer.contains("15 s") && footer.contains("120 s") && footer.contains("300 s"))
    }

    @Test func rerunAttemptLinksParentWithoutMutatingPriorRow() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let poller = f.poller()
        await f.api.set(f.repo, runs: [f.run()], jobs: [f.job(conclusion: "failure")])
        _ = try await poller.poll(repo: f.repo)
        let parent = try await f.row()
        try await GitHubRerun.rerun(ledger: f.ledger, jobID: parent.id) { argv in
            #expect(argv == ["gh", "run", "rerun", "1", "-R", "acme/atlas", "--failed"])
        }
        await f.api.set(f.repo, runs: [f.run(attempt: 2)], jobs: [f.job(20, attempt: 2)])
        _ = try await poller.poll(repo: f.repo)
        #expect(try await f.info(20, attempt: 2).parentAttempt == parent.id)
        #expect(try await f.row() == parent)
        #expect(parent.state == .failed)
        #expect(try await f.ledger.jobs().count == 2)
    }

    @Test func tenantOwnersAloneDoNotWatchOrListRepos() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let rules = Rules(tenants: ["acme": TenantConfig(owners: ["acme"])])
        let poller = f.poller(rules: rules)
        await f.api.owner("orgs", "acme", repos: ["acme/unrequested"])
        await f.api.owner("users", "acme", repos: ["acme/unrequested"])
        #expect(try await poller.watchedRepos().isEmpty)
        f.clock.advance(3601)
        #expect(try await poller.watchedRepos().isEmpty)
        #expect(await f.api.recorded().isEmpty)
    }

    @Test func explicitReposAndMatchingGlobsUsePaginatedHourlyOwnerCache() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let rules = Rules(tenants: [
            "acme": TenantConfig(owners: ["acme"], repos: ["acme/atlas", "acme/ledger"]),
            "personal": TenantConfig(repos: ["globex/portal*", "globex/sdk*", "solo/tool*"])
        ])
        let poller = f.poller(rules: rules)
        // A match after page one proves the listing follows pagination; nonmatches stay unwatched.
        let globex = (1...100).map { "globex/unmatched\($0)" } + ["globex/portal.ro", "globex/sdk"]
        await f.api.owner("orgs", "acme", repos: ["acme/unrequested"])
        await f.api.owner("orgs", "globex", repos: globex)
        await f.api.owner("users", "solo", repos: ["solo/toolbox", "solo/unmatched"])
        let expected = Set(["acme/atlas", "acme/ledger", "globex/portal.ro", "globex/sdk", "solo/toolbox"])
        #expect(Set(try await poller.watchedRepos()) == expected)
        let first = await f.api.recorded()
        #expect(!first.contains { $0.path == "/orgs/acme/repos" || $0.path == "/users/acme/repos" })
        #expect(first.filter { $0.path == "/orgs/globex/repos" }.map { $0.query["page"] } == ["1", "2"])
        #expect(first.filter { $0.path == "/users/solo/repos" }.map { $0.query["page"] } == ["1"])
        #expect(first.allSatisfy { $0.query["per_page"] == "100" })
        #expect(Set(try await poller.watchedRepos()) == expected)
        #expect(await f.api.recorded().count == first.count)
        await f.api.owner("orgs", "globex", repos: globex + ["globex/portal-new"])
        f.clock.advance(3599)
        #expect(Set(try await poller.watchedRepos()) == expected)
        #expect(await f.api.recorded().count == first.count)
        f.clock.advance(1)
        #expect(Set(try await poller.watchedRepos()) == expected.union(["globex/portal-new"]))
        let refreshed = await f.api.recorded()
        #expect(refreshed.filter { $0.path == "/orgs/globex/repos" }.map { $0.query["page"] } == ["1", "2", "1", "2"])
        #expect(refreshed.filter { $0.path == "/users/solo/repos" }.count == 2)
        #expect(!refreshed.contains { $0.path == "/orgs/acme/repos" || $0.path == "/users/acme/repos" })
    }

    @Test func repoRunnerTargetsAreWatchedButOrgTargetsDoNotExpand() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        var rules = try watchRules(targets: ["org:acme", "globex/portal"])
        rules.destinations["other"] = rules.destinations["box"]
        rules.destinations["other"]?.runnerTargets = ["solo/tool"]
        await f.api.owner("orgs", "acme", repos: ["acme/unrequested"])
        let repos = try await f.poller(rules: rules).watchedRepos()
        #expect(Set(repos) == Set(["globex/portal", "solo/tool"]))
        #expect(await f.api.recorded().isEmpty)
    }

    @Test func onlyRecentSelfHostedGitHubLedgerJobsKeepReposWatched() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let poller = f.poller(rules: Rules())
        let cases: [(String, String, String, TimeInterval)] = [
            ("gh-101-1", "acme/recent", "box", 30 * 86400 - 1),
            ("gh-102-1", "acme/hosted", "github-hosted", 0),
            ("gh-103-1", "acme/old", "box", 30 * 86400 + 1),
            ("local-104", "acme/local", "box", 0),
            ("gh-105-1", "acme/mixed", "box", 60),
            ("gh-106-1", "acme/mixed", "github-hosted", 0)
        ]
        for (id, repo, location, age) in cases {
            try await f.ledger.insert(JobRecord(id: id, repo: repo, command: "CI", location: location,
                state: .done, queuedAt: f.clock.now().addingTimeInterval(-age)))
        }
        #expect(Set(try await poller.watchedRepos()) == Set(["acme/recent", "acme/mixed"]))
        f.clock.advance(2)
        #expect(try await poller.watchedRepos() == ["acme/mixed"])
        #expect(await f.api.recorded().isEmpty)
    }

    @Test func boxReposRequireThatDestinationsRepoOrOrgTarget() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        var rules = try watchRules(targets: ["OrG:AcMe", "GLOBEX/Portal"])
        rules.destinations["other"] = rules.destinations["box"]
        rules.destinations["other"]?.runnerTargets = ["org:outsider"]
        let poller = f.poller(rules: rules)
        #expect(await poller.noteBoxRepos(["aCmE/Atlas"], destination: "box"))
        #expect(await poller.noteBoxRepos(["globex/PORTAL"], destination: "box"))
        #expect(await poller.noteBoxRepos(["ACME/atlas", "Globex/portal"], destination: "box") == false)
        for rejected in ["outsider/repo", "globex/other", "org:acme", "acme/a/b", "../x", "acme/", "invalid"] {
            #expect(await poller.noteBoxRepos([rejected], destination: "box") == false, "Rejected: \(rejected)")
        }
        #expect(await poller.noteBoxRepos(["acme/unknown-box"], destination: "missing") == false)
        let repos = try await poller.watchedRepos()
        #expect(repos.count == 2)
        #expect(Set(repos.map { $0.lowercased() }) == Set(["acme/atlas", "globex/portal"]))
        #expect(try await f.ledger.jobs().isEmpty)
        #expect(await f.api.recorded().isEmpty)
    }

    @Test func boxReposExpireThirtyDaysAfterTheirLastSighting() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let poller = f.poller(rules: try watchRules(targets: ["org:acme"]))
        #expect(await poller.noteBoxRepos(["acme/atlas", "acme/once"], destination: "box"))
        f.clock.advance(20 * 86400)
        #expect(await poller.noteBoxRepos(["ACME/ATLAS"], destination: "box") == false)
        f.clock.advance(10 * 86400)
        #expect(try await poller.watchedRepos().map { $0.lowercased() } == ["acme/atlas"])
        f.clock.advance(20 * 86400 - 1)
        #expect(try await poller.watchedRepos().map { $0.lowercased() } == ["acme/atlas"])
        f.clock.advance(1)
        #expect(try await poller.watchedRepos().isEmpty)
    }

    @Test func watchedReposDeduplicateCaseAcrossEverySource() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        var rules = try watchRules(targets: ["ACME/Atlas", "org:acme"])
        rules.tenants = ["acme": TenantConfig(repos: ["Acme/ATLAS", "acme/atlas", "acme/at*"])]
        await f.api.owner("orgs", "acme", repos: ["aCmE/aTlAs"])
        try await f.ledger.insert(JobRecord(id: "gh-107-1", repo: "acme/ATlas", command: "CI",
            location: "box", state: .done, queuedAt: f.clock.now()))
        let poller = f.poller(rules: rules)
        #expect(await poller.noteBoxRepos(["ACME/ATLAS"], destination: "box"))
        #expect(await poller.noteBoxRepos(["acme/atlas"], destination: "box") == false)
        let repos = try await poller.watchedRepos()
        #expect(repos.count == 1)
        #expect(repos.map { $0.lowercased() } == ["acme/atlas"])
    }

    private func watchRules(targets: [String]) throws -> Rules {
        let json = #"{"destinations":{"box":{"enabled":true,"peer_id":"peer","ssh_alias":"box","tenant":"acme","roles":["github"],"home":"/home/runner","max_jobs":2,"memory_budget":"4g"}},"tenants":{},"rules":[]}"#
        var rules = try JSONDecoder().decode(Rules.self, from: Data(json.utf8))
        rules.destinations["box"]?.runnerTargets = targets
        return rules
    }

    @Test func untrustedNamesAreCleanedBeforeLedgerStorage() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        var run = f.run(); run.name = "C\u{200B}I\u{1B}[31m"
        var job = f.job(); job.name = "ch\u{200B}eck\u{1B}[0m"; job.runnerName = "ru\u{200B}nner\u{1B}[31m"
        await f.api.set(f.repo, runs: [run], jobs: [job])
        _ = try await f.poller().poll(repo: f.repo)
        #expect(try await f.row().command == "CI / check")
        #expect(try await f.info().runnerName == "runner")
    }

    @Test func orgTokenIsUsedOnlyForOrgRunnersAndNeverPersisted() async throws {
        let f = try U5Fixture(); defer { f.remove() }
        let repo = "Acme/project"
        let poller = f.poller(token: { $0.lowercased() == "acme" ? "pat-x" : nil })
        let job = f.job(status: "queued", conclusion: nil)
        await f.api.set(repo, runs: [f.run(status: "queued")], jobs: [job])
        await f.api.register("/repos/\(repo)/actions/runners", [])
        await f.api.register("/orgs/Acme/actions/runners", [RunnerRegistration(name: "org-runner", labels: job.labels, online: true, busy: false)])
        _ = try await poller.poll(repo: repo)
        let calls = await f.api.recorded()
        #expect(calls.filter { $0.path == "/orgs/Acme/actions/runners" }.count == 1)
        for call in calls { #expect(call.token == (call.path == "/orgs/Acme/actions/runners" ? "pat-x" : nil)) }
        let rows = try await f.ledger.database.query("SELECT * FROM job")
        #expect(rows.count == 1)
        for row in rows {
            let command = row["command"]?.textValue ?? ""
            let github = row["github"]?.textValue ?? ""
            #expect(command.contains("pat-x") == false)
            #expect(github.contains("pat-x") == false)
        }
        let footer = await poller.footer()
        #expect(footer.contains("pat-x") == false)
        let registrations = try await f.ledger.database.query("SELECT destination FROM runner_registration")
        #expect(registrations.first?["destination"]?.textValue == "ai-eu-1")
    }
}
