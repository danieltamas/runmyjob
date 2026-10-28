import Foundation

/// `rmj github poll [--repo owner/name] [--watch]`, `rmj rerun <job id>`.
public enum GitHubCommand {
    public static func poll(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        var repo: String?, watch = false
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--repo": repo = rest.popFirst()
            case "--watch": watch = true
            default: return RunCommand.fail("usage: rmj github poll [--repo owner/name] [--watch]", code: 2)
            }
        }
        let context: RunCommand.Context
        do { context = try await RunCommand.open(environment: environment) } catch { return RunCommand.fail("cannot open the ledger: \(error.localizedDescription)") }
        guard let rules = context.rules.rules else { return RunCommand.fail("rules file is invalid; fix it before polling") }
        let poller = GitHubPoller(api: GHCLI(), ledger: context.ledger, rules: rules, orgToken: orgTokens(rules: rules, home: context.home))
        // Each repo has its own due time: 15 s while it has queued or running jobs, 120 s otherwise.
        var due = [String: Date]()
        repeat {
            do {
                let repos = if let repo { [repo] } else { try await poller.watchedRepos() }
                for name in repos where due[name, default: .distantPast] <= Date() {
                    let result = try await poller.poll(repo: name)
                    print("\(name): \(result.rateLimited ? "rate limited" : "\(result.runs) runs, \(result.jobs) jobs")")
                    due[name] = Date().addingTimeInterval(try await poller.interval(for: name))
                }
            } catch { return RunCommand.fail(error.localizedDescription) }
            print(await poller.footer())
            if watch { try? await Task.sleep(for: .seconds(max(1, (due.values.min() ?? Date()).timeIntervalSinceNow))) }
        } while watch
        return 0
    }

    /// PATs for the orgs named in `runner_targets`: the Keychain (never prompting) or this run's one-time handoff.
    /// Read once up front; none are stored by RMJ outside the Keychain.
    static func orgTokens(rules: Rules, home: RMJHome) -> @Sendable (String) -> String? {
        var tokens = [String: String]()
        let targets = Set(rules.destinations.values.flatMap { $0.runnerTargets ?? [] }.filter { $0.hasPrefix("org:") })
        for target in targets {
            let account = "rmj.pat.\(target)"
            let token = (try? Keychain().read(account: account)) ?? (try? PatHandoff(home: home).take(account: account.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")))
            if let token { tokens[String(target.dropFirst(4)).lowercased()] = token }
        }
        let resolved = tokens
        return { resolved[$0.lowercased()] }
    }

    public static func rerun(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        guard let id = arguments.first else { return RunCommand.fail("usage: rmj rerun <job id>", code: 2) }
        if let problem = await rerunJob(id, environment: environment) { return RunCommand.fail(problem) }
        return 0
    }

    /// Archives one GitHub job's log under `~/.rmj/logs`; the reason it could not be, or nil when it was.
    public static func fetchLog(_ id: String, environment: [String: String] = ProcessInfo.processInfo.environment) async -> String? {
        let context: RunCommand.Context
        do { context = try await RunCommand.open(environment: environment) } catch { return "cannot open the ledger: \(error.localizedDescription)" }
        let tokens = context.rules.rules.map { orgTokens(rules: $0, home: context.home) } ?? { @Sendable _ in nil }
        return await GitHubJobLog.archive(ledgerID: id, ledger: context.ledger, archive: context.archive, secrets: [], token: tokens)
    }

    /// Reruns one GitHub job's run; the reason it could not be, or nil when it was.
    public static func rerunJob(_ id: String, environment: [String: String] = ProcessInfo.processInfo.environment) async -> String? {
        let context: RunCommand.Context
        do { context = try await RunCommand.open(environment: environment) } catch { return "cannot open the ledger: \(error.localizedDescription)" }
        do {
            // The run's current state decides --failed: refresh it first, and refuse when that cannot be done.
            if let repo = try await context.ledger.job(id).flatMap({ GitHubJobInfo.decode($0.github)?.repo }) {
                guard let rules = context.rules.rules else { return "rules file is invalid; cannot confirm the run's state" }
                let result = try await GitHubPoller(api: GHCLI(), ledger: context.ledger, rules: rules, orgToken: orgTokens(rules: rules, home: context.home)).poll(repo: repo)
                if result.rateLimited { return "GitHub rate limit in force; cannot confirm the run's state" }
            }
            try await GitHubRerun.rerun(ledger: context.ledger, jobID: id) { argv in
                guard let gh = Executables.resolve("gh") else { throw GHCLI.Failure(message: "gh is not installed") }
                let output = try await ProcessRunner().run(gh, Array(argv.dropFirst()), environment: ["PATH": Executables.searchPath(for: gh)], timeout: .seconds(60))
                guard output.status == 0 else { throw GHCLI.Failure(message: "gh run rerun failed: \(UntrustedText.clean(output.stderr, limit: 300))") }
            }
        } catch { return "\(error)" }
        return nil
    }
}
