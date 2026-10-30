import Foundation

/// What the engine does around a box run when the run is an agent task: carry the Mac's login in, bring the result out.
struct AgentSession: Sendable {
    /// A token with less time left than this (or than the task's own timeout) would die in the middle of the task.
    static let minimumLifetime: TimeInterval = 600
    static let secretName = "credentials.json"

    let task: AgentTask
    private let credentials: Data
    private let expires: Date
    /// The login's own strings, so output that echoes them is redacted like any other secret.
    let secrets: [String]
    private(set) var base: String?
    private var head: String?

    /// Reads the Mac's login; the reason the task must fall back to the Mac when it cannot be used.
    static func prepare(_ task: AgentTask, source: CredentialSource, now: Date) async -> Result<AgentSession, Fallback> {
        do {
            let staged = try AgentCredentials.stage(raw: try await source.load(), harness: task.harness, now: now, minimumLifetime: max(minimumLifetime, TimeInterval(task.timeoutSeconds)))
            return .success(AgentSession(task: task, credentials: staged.login, expires: staged.expires, secrets: staged.secrets, base: nil))
        } catch AgentCredentials.Failure.expiresSoon {
            return .failure(Fallback(reason: "\(task.harness.program) login expires soon"))
        } catch {
            return .failure(Fallback(reason: "\(task.harness.program) login unavailable"))
        }
    }

    struct Fallback: Error { let reason: String }

    /// The one box-side network the container joins: no route out except the filtering proxy.
    static let network = "rmj-agents"
    static let proxy = "http://rmj-egress:3128"

    /// At most this many agent runs at once on a box, so they cannot starve builds of cpu and memory.
    static let defaultSlots = 2

    /// The container runs the task's own argv, on the filtered network, and finds the prelude that moves the login into place.
    func decorate(_ job: BoxJob, home: String, slots: Int?) -> BoxJob {
        let prelude = (path: "\(home)/rx/.prelude/agent-\(task.harness.program).sh", content: prelude)
        let limit = "slots:\(min(max(slots ?? Self.defaultSlots, 1), 16)):\(home)/rx/.agent-slot"
        let environment = ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"].flatMap { ["-e", "\($0)=\(Self.proxy)"] }
            + ["-e", "NO_PROXY=localhost,127.0.0.1"]
        return BoxJob(ulid: job.ulid, name: job.name, worktree: job.worktree, directory: job.directory, argv: task.argv(onBox: true),
                      options: Self.withoutNetwork(job.options), image: job.image, locks: [limit] + job.locks, prelude: prelude)
            .adding(volume: "\(prelude.path):/prelude.sh:ro")
            // The login lives in the container's memory: nothing of it reaches the image's writable layer.
            .adding(options: ["--tmpfs", "/tmp:rw,nosuid,mode=1777,size=512m", "--network", Self.network] + environment)
    }

    /// A profile's own `--network` would leave the container on a second network with a route out.
    private static func withoutNetwork(_ options: [String]) -> [String] {
        var kept: [String] = [], index = 0
        while index < options.count {
            if options[index] == "--network" { index += 2; continue }
            if options[index].hasPrefix("--network=") || options[index].hasPrefix("--net=") { index += 1; continue }
            kept.append(options[index]); index += 1
        }
        return kept
    }

    /// Inside the container, before the harness starts: the login leaves the shared mount and lives in the container only.
    var prelude: String {
        let login = task.harness.loginPath
        return """
        mkdir -p "$(dirname "\(login)")" && mv /run/rmj/\(Self.secretName) "\(login)" && chmod 600 "\(login)"
        """
    }

    mutating func snapshot(worktree: String) async throws {
        let url = URL(fileURLWithPath: worktree)
        base = try await AgentBranch.snapshot(worktree: url)
        head = try await AgentBranch.head(worktree: url)
    }

    /// Waiting for the locks and the sync can use up the margin the login had when the run was prepared.
    func ensureFresh(now: Date) throws {
        guard expires.timeIntervalSince(now) >= max(Self.minimumLifetime, TimeInterval(task.timeoutSeconds)) else {
            throw BoxFailure("\(task.harness.program) login expires soon")
        }
    }

    /// Writes the login to the box's tmpfs and mounts that directory into the job.
    func stage(_ job: BoxJob, client: BoxClient) async throws -> BoxJob {
        try await client.ensureEgress(image: job.image, hosts: task.harness.egressHosts)
        let directory = try await client.stageSecret(ulid: job.ulid, name: Self.secretName, content: credentials)
        // The path comes from the box: only the exact directory this job owns is mounted.
        guard directory.hasPrefix("/"), !directory.split(separator: "/").contains(".."), directory.hasSuffix("/rmj-\(job.ulid)"),
              directory.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }) else {
            throw BoxFailure("the box answered with an unexpected credentials directory")
        }
        return job.adding(volume: "\(directory):/run/rmj")
    }

    /// Pulls the box's directory and records it as a branch; the line to show the user either way.
    func importResult(_ job: BoxJob, client: BoxClient, worktree: String) async -> (line: String, ok: Bool) {
        guard let base else { return ("the agent finished; no snapshot was taken, so nothing was imported", false) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try await client.pullTree(job, into: scratch)
            let title = task.prompt.split(separator: "\n").first.map(String.init) ?? "agent run"
            switch try await AgentBranch.record(worktree: URL(fileURLWithPath: worktree), base: base, result: scratch, jobID: job.ulid,
                                                message: "rmj agent run \(job.ulid): \(title)", parent: head, unborn: head == nil) {
            case .unchanged: return ("the agent changed nothing", true)
            case .created(let branch, let commit): return ("agent result on branch \(branch) (\(commit.prefix(8)))", true)
            }
        } catch {
            return ("the agent finished but its result could not be imported (\(UntrustedText.clean(error.localizedDescription, limit: 120))); the files stay on the box in \(job.directory)", false)
        }
    }
}
