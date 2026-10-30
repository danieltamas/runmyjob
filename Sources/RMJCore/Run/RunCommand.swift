import Foundation

/// `rmj run [--to dest] [--shell] -- <command...>`, `rmj jobs [--json]`, `rmj cancel <id>`.
public enum RunCommand {
    struct Context {
        let home: RMJHome
        let ledger: Ledger
        let archive: LogArchive
        let tailnet: TailnetState
        let rules: RulesState
    }

    static func open(environment: [String: String]) async throws -> Context {
        let home = RMJHome(environment: environment)
        try home.prepare()
        let database = try Database(url: home.url.appendingPathComponent("rmj.sqlite"))
        return Context(home: home, ledger: Ledger(database: database),
                       archive: LogArchive(database: database, directory: home.url.appendingPathComponent("logs")),
                       tailnet: await TailnetState.read(environment: environment), rules: RulesStore(home: home).load())
    }

    static func fail(_ message: String, code: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data("rmj: \(UntrustedText.clean(message, limit: 300))\n".utf8))
        return code
    }

    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        var destination: String?, shell = false, command = [String]()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--": command = Array(rest); rest = []
            case "--shell": shell = true
            case "--to": destination = rest.popFirst()
            default: return fail("unknown option \(argument)\nusage: rmj run [--to destination] [--shell] -- <command...>", code: 2)
            }
        }
        guard !command.isEmpty else { return fail("no command after --\nusage: rmj run [--to destination] [--shell] -- <command...>", code: 2) }
        return await dispatch(command: command, shell: shell, destination: destination, environment: environment)
    }

    /// Routes and runs one command from the current directory; `agentTask` makes it an agent run.
    static func dispatch(command: [String], shell: Bool, destination: String?, agentTask: AgentTask? = nil, environment: [String: String]) async -> Int32 {
        let context: Context
        do { context = try await open(environment: environment) } catch {
            if agentTask?.requireBox == true {
                return fail("cannot open \(RMJHome(environment: environment).url.path): \(error.localizedDescription); not run, a box was required", code: 3)
            }
            // No ledger is no reason not to run the command.
            _ = fail("cannot open \(RMJHome(environment: environment).url.path): \(error.localizedDescription); running on this Mac without a record", code: 0)
            let pump = OutputPump(writer: nil, output: { FileHandle.standardOutput.write($0) }, secrets: [])
            let status = try? await ProcessRunner().run(shell ? "/bin/bash" : "/usr/bin/env", shell ? ["-c", command.joined(separator: " ")] : command, environment: ["PATH": Executables.searchPath],
                                                        timeout: .seconds(14 * 86400),
                                                        output: pump.add)
            await pump.close()
            return status?.status ?? 127
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let identity = await RepoIdentity.detect(in: directory)
        let facts = await GitFacts.read(in: URL(fileURLWithPath: identity.worktree))
        let probes = LiveProbeProvider()
        let boxes = BoxDirectory(rules: context.rules, tailnet: context.tailnet, factory: SSHBoxFactory())
        let reconciler = Reconciler(ledger: context.ledger, archive: context.archive, boxes: boxes)
        await reconciler.reconcile()
        let engine = RunEngine(ledger: context.ledger, archive: context.archive,
                               router: Router(rules: context.rules, tailnet: context.tailnet, probes: probes,
                                              fileExists: { FileManager.default.fileExists(atPath: $0) }),
                               boxes: boxes, probes: probes,
                               output: { FileHandle.standardOutput.write($0) },
                               notice: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                               streamer: LogStreamer.make(home: RMJHome(environment: environment)))
        let root = URL(fileURLWithPath: identity.worktree).standardizedFileURL.resolvingSymlinksInPath().path
        let here = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let relative = here.hasPrefix(root + "/") ? String(here.dropFirst(root.count + 1)) : ""
        let request = RunRequest(command: command, shell: shell, identity: identity, branch: facts.branch, commit: facts.commit,
                                 destination: destination, forceLocal: environment["RX_LOCAL"] == "1",
                                 agent: AgentContext.detect(environment: environment), subdirectory: relative, agentTask: agentTask)
        let result = await engine.run(request)
        return result.exitCode
    }

    public static func jobs(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        let context: Context
        do { context = try await open(environment: environment) } catch { return fail("cannot open the ledger: \(error.localizedDescription)") }
        let boxes = BoxDirectory(rules: context.rules, tailnet: context.tailnet, factory: SSHBoxFactory())
        await Reconciler(ledger: context.ledger, archive: context.archive, boxes: boxes).reconcile()
        let json = arguments.contains("--json")
        let jobs = ((try? await context.ledger.jobs()) ?? []).prefix(30)
        for job in jobs {
            var events = [Ledger.Event]()
            if !job.state.isSettled { events = (try? await context.ledger.events(job.id)) ?? [] }
            let waiting = job.state == .queued ? events.last?.detail : nil
            if json {
                let object: [String: Any] = ["id": job.id, "state": job.state.rawValue, "location": UntrustedText.clean(job.location, limit: 80),
                                             "exit": job.exitCode as Any? ?? NSNull()]
                print(String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
            } else {
                let timing: String
                switch job.duration {
                case .box(let ms): timing = "\(ms) ms (box)"
                case .mac(let ms): timing = "\(ms) ms (mac)"
                case .unknown: timing = "unknown"
                }
                var line = "\(job.id)  \(job.state.rawValue)  \(job.location)  \(UntrustedText.clean(job.command, limit: 60))  \(timing)"
                if let reason = job.fallbackReason { line += "  [\(reason)]" }
                if let waiting { line += "  \(UntrustedText.clean(waiting))" }
                if let github = GitHubJobInfo.decode(job.github) {
                    if let step = github.currentStep { line += "  step \(github.currentStepNumber ?? github.stepsDone + 1)/\(github.stepsTotal) \(step)" }
                    if let observation = github.observation { line += "  [\(observation.summary); suspected: \(observation.suspectedCause)]" }
                    if github.waitingOnDependency { line += "  [waiting on needs]" }
                }
                print(line)
            }
        }
        return 0
    }

    public static func cancel(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        guard let id = arguments.first else { return fail("usage: rmj cancel <job id>", code: 2) }
        if let problem = await cancelJob(id, environment: environment) { return fail(problem) }
        print("cancelled \(id)")
        return 0
    }

    /// Cancels one job; the reason it could not be, or nil when it was.
    public static func cancelJob(_ id: String, environment: [String: String] = ProcessInfo.processInfo.environment) async -> String? {
        let context: Context
        do { context = try await open(environment: environment) } catch { return "cannot open the ledger: \(error.localizedDescription)" }
        let probes = LiveProbeProvider()
        let boxes = BoxDirectory(rules: context.rules, tailnet: context.tailnet, factory: SSHBoxFactory())
        let engine = RunEngine(ledger: context.ledger, archive: context.archive,
                               router: Router(rules: context.rules, tailnet: context.tailnet, probes: probes, fileExists: { _ in false }),
                               boxes: boxes, probes: probes, output: { _ in }, notice: { _ in })
        switch await engine.cancel(id) {
        case .cancelled: return nil
        case .notFound: return "no job \(UntrustedText.clean(id, limit: 40))"
        case .alreadySettled: return "job \(UntrustedText.clean(id, limit: 40)) has already finished"
        case .unreachable: return "the destination is not reachable; the job was not cancelled"
        }
    }
}
