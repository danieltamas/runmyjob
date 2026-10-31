import Foundation

public struct GitHubPollResult: Sendable, Equatable {
    public var runs = 0
    public var jobs = 0
    /// Nothing was requested because GitHub's rate limit is in force.
    public var rateLimited = false
}

/// Reads workflow runs and jobs of the watched repos into the ledger. One poll is one repo; the caller
/// schedules it at `interval(for:)`. Tokens: `gh` supplies its own per call, RMJ stores none; an org's
/// runner list uses the Keychain PAT handed in as `orgToken`.
public actor GitHubPoller {
    public static let activeInterval: TimeInterval = 15
    public static let idleInterval: TimeInterval = 120
    /// A repo with no run in the last day: each poll is a `gh` process, and dozens of quiet repos cost more than everything else RMJ does.
    public static let quietInterval: TimeInterval = 300
    public static let backfillWindow: TimeInterval = 30 * 86400
    /// How long after a run's last update GitHub's job list is still allowed to disagree with the run.
    static let settleWindow: TimeInterval = 3600
    static let ownerListingTTL: TimeInterval = 3600

    private let api: GitHubAPI
    private let ledger: Ledger
    private var rules: Rules
    private let orgToken: @Sendable (String) -> String?
    private let now: @Sendable () -> Date
    private struct RateLimited: Error {}
    private var polling = Set<String>()
    private var tableReady = false
    private var rateLimitedUntilStored: Date?
    private var ownerRepos = [String: (at: Date, repos: [String])]()

    public init(api: GitHubAPI, ledger: Ledger, rules: Rules, orgToken: @escaping @Sendable (String) -> String? = { _ in nil },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.api = api
        self.ledger = ledger
        self.rules = rules
        self.orgToken = orgToken
        self.now = now
    }

    public func update(rules: Rules) { self.rules = rules }

    // MARK: Rate limit and footer

    public func rateLimitedUntil() async -> Date? {
        await restoreRateLimit()
        guard let until = rateLimitedUntilStored, until > now() else { return nil }
        return until
    }

    /// The panel footer: both intervals, and the pause when GitHub's limit is in force.
    public func footer() async -> String {
        let base = "GitHub polling: \(Int(Self.activeInterval)) s with queued or running jobs, \(Int(Self.idleInterval)) s after a run in the last day, \(Int(Self.quietInterval)) s otherwise"
        guard let until = await rateLimitedUntil() else { return base }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return "GitHub rate limit reached, polling paused until \(formatter.string(from: until)). " + base
    }

    private func restoreRateLimit() async {
        guard rateLimitedUntilStored == nil, let stored = try? await readPoll("ratelimit") else { return }
        rateLimitedUntilStored = Date(timeIntervalSince1970: TimeInterval(stored.at) / 1000)
    }

    // MARK: Intervals

    /// 15 s while the repo has something queued or running, 120 s after a run in the last day, else 300 s.
    public func interval(for repo: String) async throws -> TimeInterval {
        let active = try await ledger.database.query(
            "SELECT 1 FROM job WHERE repo = ? AND id LIKE 'gh-%' AND state IN ('queued', 'running') LIMIT 1", [.text(repo)])
        if !active.isEmpty { return Self.activeInterval }
        let dayAgo = Int64((now().timeIntervalSince1970 - 86_400) * 1000)
        let recent = try await ledger.database.query(
            "SELECT 1 FROM job WHERE repo = ? AND id LIKE 'gh-%' AND queued_at > ? LIMIT 1", [.text(repo), .int(dayAgo)])
        return recent.isEmpty ? Self.quietInterval : Self.idleInterval
    }

    // MARK: Watched set

    /// Every explicit `owner/name` of the tenants' repo tables plus every repo of each listed owner and of the
    /// owner of a glob entry (matching it), listed at most once an hour.
    public func watchedRepos() async throws -> [String] {
        var repos = Set<String>()
        var owners = Set<String>()
        var globs = [String]()
        for tenant in rules.tenants.values {
            for entry in tenant.repos ?? [] {
                if entry.contains("*") { globs.append(entry.lowercased()) } else { repos.insert(entry) }
                if entry.contains("*"), let owner = entry.split(separator: "/").first { owners.insert(String(owner)) }
            }
        }
        for tenant in rules.tenants.values { owners.formUnion(tenant.owners ?? []) }
        let listedOwners = Set(rules.tenants.values.flatMap { $0.owners ?? [] })
        for owner in owners.sorted() {
            guard let listed = try await reposOf(owner: owner) else { continue }
            for name in listed {
                let lower = name.lowercased()
                if listedOwners.contains(owner) || globs.contains(where: { Glob.matches($0, lower) }) { repos.insert(name) }
            }
        }
        return repos.sorted()
    }

    private func reposOf(owner: String) async throws -> [String]? {
        if let cached = ownerRepos[owner], now().timeIntervalSince(cached.at) < Self.ownerListingTTL { return cached.repos }
        if await rateLimitedUntil() != nil { return ownerRepos[owner]?.repos }
        do { return try await listOwner(owner) } catch is RateLimited { return ownerRepos[owner]?.repos }
    }

    private func listOwner(_ owner: String) async throws -> [String]? {
        for scope in ["orgs", "users"] {
            var names = [String]()
            var page = 1
            while true {
                let response = try await fetch("/\(scope)/\(owner)/repos", query: ["per_page": "100", "page": String(page)], etag: nil, token: nil)
                if response.status == 404 { break }
                guard response.status == 200 else { throw GHCLI.Failure(message: "GitHub answered \(response.status) listing \(owner)") }
                struct Repo: Decodable { var fullName: String }
                names += try GitHubJSON.decoder.decode([Repo].self, from: response.body).map(\.fullName)
                guard response.hasNextPage else { ownerRepos[owner] = (now(), names); return names }
                page += 1
            }
        }
        return nil
    }

    // MARK: Poll

    public func poll(repo: String) async throws -> GitHubPollResult {
        guard await rateLimitedUntil() == nil else { return GitHubPollResult(rateLimited: true) }
        // A second poll of the same repo while one is in flight would race on the checkpoint; it is a no-op.
        guard polling.insert(repo).inserted else { return GitHubPollResult() }
        defer { polling.remove(repo) }
        do { return try await pollOnce(repo: repo) } catch is RateLimited { return GitHubPollResult(rateLimited: true) }
    }

    /// Any failure (a rate limit, a bad answer, a decoding error) leaves the checkpoint where it was, so the
    /// next poll covers the same window again.
    private func pollOnce(repo: String) async throws -> GitHubPollResult {
        let started = now()
        let key = "runs:\(repo)"
        let last = try await readPoll(key)
        let lastAt = last.map { Date(timeIntervalSince1970: TimeInterval($0.at) / 1000) }
        let floor = Self.hour(started.addingTimeInterval(-Self.backfillWindow))
        // The query window is anchored on the hour and kept between polls while it is inside the 30 days, so
        // the request (and its ETag) is stable; after downtime of more than an hour it restarts an hour
        // before the last complete poll. Paging stops at the cutoff: anything older was seen already.
        let stored = last?.etag.flatMap(Self.split)
        let cutoff = lastAt.map { max(floor, $0.addingTimeInterval(-3600)) } ?? floor
        let gap = lastAt.map { started.timeIntervalSince($0) > 3600 } ?? true
        let kept = stored.map { Date(timeIntervalSince1970: TimeInterval($0.stamp)) }.flatMap { $0 >= floor ? $0 : nil }
        let anchor = gap ? Self.hour(cutoff) : kept ?? floor
        let stamp = Int(anchor.timeIntervalSince1970)
        let runs = try await listRuns(repo: repo, since: anchor, cutoff: cutoff, etag: stored.flatMap { $0.stamp == stamp ? $0.etag : nil })
        var result = GitHubPollResult(runs: runs.fetched.count)
        var known = try await knownRows(repo: repo)
        var pending = runs.fetched
        // Runs that were unfinished at the last poll may have fallen out of the window or the first page.
        let listed = Set(runs.fetched.map(\.id))
        for id in Set(known.values.filter { !$0.state.isSettled }.map(\.info.runId)) where !listed.contains(id) {
            let response = try await fetch("/repos/\(repo)/actions/runs/\(id)", query: [:], etag: nil, token: nil)
            // A deleted run will never settle; anything else unexpected is an incomplete poll.
            if response.status == 404 { continue }
            guard response.status == 200 else { throw GHCLI.Failure(message: "GitHub answered \(response.status) for run \(id) of \(repo)") }
            pending.append(try GitHubJSON.decoder.decode(GHRun.self, from: response.body))
        }
        var registrations: [RunnerRegistration]??
        for run in pending {
            for attempt in 1...max(1, run.runAttempt) {
                let marker = "done:\(repo):\(run.id):\(attempt)"
                // A marker written within the settle window of the run's last update does not cover a row that is still
                // unfinished: that poll may have seen the run completed while the job list still said in_progress. A marker
                // written later is a give-up on a job GitHub never settles, and stays final.
                let settled = run.updatedAt.map { started.timeIntervalSince($0) >= Self.settleWindow } ?? false
                let unfinished = known.values.contains { $0.info.runId == run.id && $0.info.runAttempt == attempt && !$0.state.isSettled }
                if let done = try await readPoll(marker) {
                    let early = run.updatedAt.map { Date(timeIntervalSince1970: TimeInterval(done.at) / 1000).timeIntervalSince($0) < Self.settleWindow } ?? true
                    if !(unfinished && early) { continue }
                }
                let jobs = try await listJobs(repo: repo, run: run, attempt: attempt)
                let live = jobs.filter { $0.status == "queued" || $0.status == "in_progress" }
                if !live.isEmpty, registrations == nil { registrations = .some(try await runnerRegistrations(repo: repo)) }
                let known_ = registrations ?? nil
                for job in jobs {
                    let observation = job.status == "queued" ? known_.map { QueueAnalysis.observe(labels: job.labels, registrations: $0, now: started) } : nil
                    try await store(repo: repo, run: run, job: job, siblings: jobs, observation: observation, registrations: known_ ?? [],
                                    known: &known, now: started)
                    result.jobs += 1
                }
                // Only a completed attempt whose jobs all settled is final; its marker lets later polls skip it. Written after every job is stored.
                if attempt < run.runAttempt || (run.status == "completed" && (live.isEmpty || settled)) { try await writePoll(marker, etag: nil, at: started) }
            }
        }
        try await writePoll(key, etag: "\(stamp):\(runs.etag ?? "")", at: started)
        return result
    }

    private struct Listing { var fetched: [GHRun]; var etag: String? }

    /// Pages of runs created since `since`; a 304 on the first page means nothing new.
    private func listRuns(repo: String, since: Date, cutoff: Date, etag: String?) async throws -> Listing {
        var fetched = [GHRun](), page = 1, firstETag: String?
        let created = ">=" + ISO8601DateFormatter().string(from: since)
        while true {
            let response = try await fetch("/repos/\(repo)/actions/runs", query: ["per_page": "100", "page": String(page), "created": created],
                                            etag: page == 1 ? etag : nil, token: nil)
            if response.status == 304 { return Listing(fetched: [], etag: etag) }
            guard response.status == 200 else { throw GHCLI.Failure(message: "GitHub answered \(response.status) listing runs of \(repo)") }
            if page == 1 { firstETag = response.etag }
            let runs = try GitHubJSON.decoder.decode(GitHubJSON.Runs.self, from: response.body).workflowRuns
            fetched += runs
            let reachedKnown = runs.contains { ($0.createdAt ?? .distantFuture) < cutoff }
            guard response.hasNextPage, !reachedKnown else { return Listing(fetched: fetched, etag: firstETag) }
            page += 1
        }
    }

    private func listJobs(repo: String, run: GHRun, attempt: Int) async throws -> [GHJob] {
        var jobs = [GHJob](), page = 1
        while true {
            let response = try await fetch("/repos/\(repo)/actions/runs/\(run.id)/attempts/\(attempt)/jobs",
                                            query: ["per_page": "100", "page": String(page)], etag: nil, token: nil)
            guard response.status == 200 else { throw GHCLI.Failure(message: "GitHub answered \(response.status) listing jobs of run \(run.id)") }
            jobs += try GitHubJSON.decoder.decode(GitHubJSON.Jobs.self, from: response.body).jobs
            guard response.hasNextPage else { return jobs }
            page += 1
        }
    }

    /// Registered runners at the repo and at its owner when an org token exists, each attributed to the
    /// destination whose `runner_targets` names that scope. Every scope must answer completely: a partial
    /// list would make a wrong cause look like evidence, so any failure gives no observation (nil).
    private func runnerRegistrations(repo: String) async throws -> [RunnerRegistration]? {
        let owner = repo.split(separator: "/").first.map(String.init) ?? ""
        var scopes: [(path: String, target: String, token: String?)] = [("/repos/\(repo)/actions/runners", repo, nil)]
        if let token = orgToken(owner) {
            scopes.append(("/orgs/\(owner)/actions/runners", "org:\(owner)", token))
        } else if rules.destinations.values.contains(where: { ($0.runnerTargets ?? []).contains { $0.lowercased() == "org:\(owner.lowercased())" } }) {
            return nil // an org scope that should be read but cannot be would make the repo's runners look like all of them
        }
        var registrations = [RunnerRegistration]()
        for scope in scopes {
            let destinations = rules.destinations.filter { ($0.value.runnerTargets ?? []).contains { $0.lowercased() == scope.target.lowercased() } }.keys.sorted()
            var page = 1
            while true {
                let response: GitHubResponse
                do { response = try await fetch(scope.path, query: ["per_page": "100", "page": String(page)], etag: nil, token: scope.token) }
                catch is RateLimited { throw RateLimited() }
                catch { return nil }
                guard response.status == 200, let runners = try? GitHubJSON.decoder.decode(GitHubJSON.Runners.self, from: response.body) else { return nil }
                registrations += runners.runners.map {
                    RunnerRegistration(name: GitHubText.clean($0.name), labels: $0.labels.map { GitHubText.clean($0.name) }, online: $0.status == "online",
                                       busy: $0.busy, destination: destinations.count == 1 ? destinations[0] : nil)
                }
                guard response.hasNextPage else { break }
                page += 1
            }
        }
        try? await recordRegistrations(registrations)
        return registrations
    }

    private func recordRegistrations(_ registrations: [RunnerRegistration]) async throws {
        let at = Ledger.ms(now())
        for runner in registrations {
            guard let destination = runner.destination else { continue }
            try await ledger.database.execute("""
                INSERT INTO runner_registration (destination, runner, first_seen, last_seen, status, busy) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (destination, runner) DO UPDATE SET last_seen = excluded.last_seen, status = excluded.status, busy = excluded.busy
                """, [.text(destination), .text(runner.name), .int(at), .int(at), .text(runner.online ? "online" : "offline"), .int(runner.busy ? 1 : 0)])
        }
    }

    // MARK: Ledger

    private struct Known { var state: JobState; var info: GitHubJobInfo; var command: String }

    private func knownRows(repo: String) async throws -> [String: Known] {
        var known = [String: Known]()
        for row in try await ledger.database.query("SELECT id FROM job WHERE repo = ? AND id LIKE 'gh-%'", [.text(repo)]) {
            guard let id = row["id"]?.textValue, let job = try await ledger.job(id), let info = GitHubJobInfo.decode(job.github) else { continue }
            known[id] = Known(state: job.state, info: info, command: job.command)
        }
        return known
    }

    private func store(repo: String, run: GHRun, job: GHJob, siblings: [GHJob], observation: QueueObservation?, registrations: [RunnerRegistration],
                       known: inout [String: Known], now: Date) async throws {
        let id = GitHubMapping.ledgerID(jobID: job.id, attempt: job.runAttempt)
        let command = GitHubText.clean("\(run.name ?? "workflow") / \(job.name)", limit: 300)
        // The previous attempt's row of the same job name, linked only when exactly one fits.
        let previous = job.runAttempt > 1
            ? known.filter { $0.value.info.runId == run.id && $0.value.info.runAttempt == job.runAttempt - 1 && $0.value.info.name == GitHubText.clean(job.name) }.map(\.key) : []
        var info = GitHubMapping.info(repo: repo, run: run, job: job, observation: observation, parent: previous.count == 1 ? previous.first : nil)
        info.destination = job.runnerName.flatMap { name in registrations.first { $0.name == GitHubText.clean(name) }?.destination }
        // An ephemeral runner is gone from GitHub once its job ends: the name recorded while it was registered still says where it ran.
        if info.destination == nil, let name = job.runnerName {
            let rows = try await ledger.database.query("SELECT destination FROM runner_registration WHERE runner = ? LIMIT 2", [.text(GitHubText.clean(name))])
            if rows.count == 1 { info.destination = rows[0]["destination"]?.textValue }
        }
        info.waitingOnDependency = info.waitingOnDependency || GitHubMapping.waitsOnDependency(job, siblings: siblings)
        let state = GitHubMapping.state(status: job.status, conclusion: job.conclusion)
        var patch = JobPatch()
        patch.startedAt = job.startedAt
        patch.endedAt = state.isSettled ? job.completedAt ?? now : nil
        if let existing = known[id] {
            if existing.state != state {
                try await ledger.advance(id, to: state, at: job.completedAt ?? job.startedAt ?? now, detail: job.conclusion, patch: patch)
            }
            if existing.info != info { try await ledger.setGitHub(id, info.json, destination: info.destination) }
        } else {
            var record = JobRecord(id: id, repo: repo, command: command, location: info.destination ?? Self.location(job: job),
                                   environment: "box", state: state, queuedAt: job.createdAt ?? now)
            record.startedAt = job.startedAt
            record.endedAt = patch.endedAt
            record.destination = info.destination
            record.github = info.json
            record.branch = run.headBranch
            record.commit = run.headSha
            record.agent = "github"
            record.tenant = Tenancy.resolve(RepoIdentity(slug: repo.lowercased(), worktree: ""), in: rules.tenants).tenant
            try await ledger.insert(record)
        }
        known[id] = Known(state: state, info: info, command: command)
    }

    private static func location(job: GHJob) -> String {
        job.labels.contains { $0.lowercased() == "self-hosted" } ? "self-hosted" : "github-hosted"
    }

    // MARK: Helpers

    /// Every request goes through here: none is made while the limit is in force, and a 403/429 with no requests
    /// left stops the whole poller until the reset time.
    private func fetch(_ path: String, query: [String: String], etag: String?, token: String?) async throws -> GitHubResponse {
        if let until = rateLimitedUntilStored, until > now() { throw RateLimited() }
        let response = try await api.get(path, query: query, etag: etag, token: token)
        guard response.isRateLimited || response.status == 429 else { return response }
        rateLimitedUntilStored = response.rateLimitReset ?? now().addingTimeInterval(60)
        try? await writePoll("ratelimit", etag: nil, at: rateLimitedUntilStored ?? now())
        throw RateLimited()
    }

    private static func hour(_ date: Date) -> Date { Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600) }

    /// The stored value is `<window start>:<etag>`; the ETag is valid only for that window.
    private static func split(_ stored: String) -> (stamp: Int, etag: String?)? {
        guard let colon = stored.firstIndex(of: ":"), let stamp = Int(stored[..<colon]) else { return nil }
        let etag = String(stored[stored.index(after: colon)...])
        return (stamp, etag.isEmpty ? nil : etag)
    }

    private func ensureTable() async throws {
        guard !tableReady else { return }
        try await ledger.database.execute("CREATE TABLE IF NOT EXISTS github_poll (key TEXT PRIMARY KEY, etag TEXT, at INTEGER NOT NULL)")
        tableReady = true
    }

    private func readPoll(_ key: String) async throws -> (etag: String?, at: Int64)? {
        try await ensureTable()
        guard let row = try await ledger.database.query("SELECT etag, at FROM github_poll WHERE key = ?", [.text(key)]).first,
              let at = row["at"]?.intValue else { return nil }
        return (row["etag"]?.textValue, at)
    }

    private func writePoll(_ key: String, etag: String?, at: Date) async throws {
        try await ensureTable()
        try await ledger.database.execute("""
            INSERT INTO github_poll (key, etag, at) VALUES (?, ?, ?)
            ON CONFLICT (key) DO UPDATE SET etag = excluded.etag, at = excluded.at
            """, [.text(key), .optional(etag), .int(Ledger.ms(at))])
    }
}
