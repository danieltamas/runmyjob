import Foundation

/// The synthetic data behind the README's renders and the layout tests (docs/SCREENSHOTS.md): fixed clock, made-up
/// repos, RFC 5737 addresses only, no user names or paths.
public enum DemoShots {
    /// 2026-10-25 14:30 UTC: relative times read the same in every render.
    public static let now = Date(timeIntervalSince1970: 1_792_938_600)

    public static func snapshot(stress: Bool = false) -> PanelSnapshot {
        PanelSnapshot(now: now, tailnet: tailnet(), jobs: jobs(stress: stress), destinations: destinations(stress: stress), rulesState: rulesState(),
                      lastOutput: ["rx-running": now.addingTimeInterval(-3), "gh-running": now.addingTimeInterval(-9)],
                      waitingFor: ["rx-waiting": "rx-8841"],
                      githubPolledAt: now.addingTimeInterval(-12), boxesPolledAt: now.addingTimeInterval(-30), rateRemaining: 4_210)
    }

    public static func tailnet(standing: TailnetState.Standing = .running) -> TailnetState {
        TailnetState(standing: standing, magicDNSEnabled: true, peers: [], readAt: now.addingTimeInterval(-20))
    }

    static func jobs(stress: Bool) -> [JobRecord] {
        let repo = stress ? "example-organisation/a-repository-with-a-very-long-name-ab" : "acme/orbit"
        let workflow = stress ? "continuous-integration-and-release-pipeline-for-all-supported-targets" : "ci / test (linux)"
        let reason = stress ? "the destination answered the probe too slowly twice in a row and the tailnet showed its peer as offline since the evening" : "tailnet down"

        var running = JobRecord(id: "rx-running", repo: repo, command: "cargo test --workspace --all-features --no-fail-fast",
                                location: "ai-eu-1", destination: "ai-eu-1", state: .running, queuedAt: now.addingTimeInterval(-262))
        running.tenant = "acme"; running.agent = "claude-code"; running.branch = "feat/router"; running.worktree = "router"
        running.commit = "a1b2c3d4"; running.dirty = true; running.startedAt = now.addingTimeInterval(-250)

        var syncing = JobRecord(id: "rx-syncing", repo: "acme/harbor", command: "just check", location: "ai-eu-1", destination: "ai-eu-1",
                                state: .syncing, queuedAt: now.addingTimeInterval(-14))
        syncing.tenant = "acme"; syncing.agent = "codex"; syncing.branch = "main"; syncing.commit = "9f8e7d6c"; syncing.syncStartedAt = now.addingTimeInterval(-12)

        var github = JobRecord(id: "gh-running", repo: "acme/atlas", command: workflow, location: "ai-eu-1", destination: "ai-eu-1",
                               state: .running, queuedAt: now.addingTimeInterval(-300))
        github.tenant = "acme"; github.startedAt = now.addingTimeInterval(-180)
        github.github = info(repo: "acme/atlas", name: workflow, status: "in_progress", step: "cargo test", number: 3, done: 2, total: 7,
                             started: now.addingTimeInterval(-180)).json

        var waiting = JobRecord(id: "rx-waiting", repo: "acme/nimbus", command: "cargo test", location: "ai-eu-1", destination: "ai-eu-1",
                                state: .queued, queuedAt: now.addingTimeInterval(-20))
        waiting.tenant = "acme"; waiting.agent = "opencode"; waiting.branch = "fix/queue"; waiting.worktree = "queue"

        var queued = JobRecord(id: "gh-queued", repo: "acme/atlas", command: "release / build", location: "github", state: .queued,
                               queuedAt: now.addingTimeInterval(-195))
        queued.tenant = "acme"
        let observation = QueueObservation(labels: ["self-hosted", "linux", "atlas"],
                                           matches: [.init(name: "bf459794a71f-1793112347", state: "offline idle")],
                                           observedAt: now.addingTimeInterval(-15), suspectedCause: "stale registration",
                                           summary: "0 online, 1 offline idle (bf459794a71f-1793112347)")
        var queuedInfo = info(repo: "acme/atlas", name: "release / build", status: "queued", step: nil, number: nil, done: 0, total: 0, started: nil)
        queuedInfo.labels = ["self-hosted", "linux", "atlas"]; queuedInfo.observation = observation
        queued.github = queuedInfo.json

        var failed = JobRecord(id: "rx-failed", repo: repo, command: "just check", location: "ai-eu-1", destination: "ai-eu-1",
                               state: .failed, queuedAt: now.addingTimeInterval(-1_900))
        failed.tenant = "acme"; failed.agent = "claude-code"; failed.branch = "feat/router"; failed.worktree = "router"; failed.commit = "a1b2c3d4"
        failed.exitCode = 101; failed.startedAt = now.addingTimeInterval(-1_850); failed.endedAt = now.addingTimeInterval(-1_470)
        failed.boxStartedAt = failed.startedAt; failed.boxEndedAt = failed.endedAt

        var localFailed = JobRecord(id: "local-failed", repo: "acme/orbit", command: "cargo test", location: "local", fallbackReason: reason,
                                    environment: "mac", state: .failed, queuedAt: now.addingTimeInterval(-3_600))
        localFailed.agent = "codex"; localFailed.branch = "main"; localFailed.commit = "5c4b3a29"; localFailed.exitCode = 1
        localFailed.startedAt = now.addingTimeInterval(-3_590); localFailed.endedAt = now.addingTimeInterval(-3_380); localFailed.macElapsedMS = 210_000; localFailed.avgCPU = 236; localFailed.avgMemoryBytes = 1_450_000_000

        var lost = JobRecord(id: "rx-lost", repo: "acme/harbor", command: "cargo test --workspace", location: "ai-eu-1", destination: "ai-eu-1",
                             state: .lost, queuedAt: now.addingTimeInterval(-5_400))
        lost.tenant = "acme"; lost.agent = "hermes"; lost.branch = "main"; lost.commit = "9f8e7d6c"; lost.startedAt = now.addingTimeInterval(-5_380)

        var done = JobRecord(id: "rx-done", repo: "acme/harbor", command: "cargo test", location: "ai-eu-1", destination: "ai-eu-1",
                             warmth: "warm", state: .done, queuedAt: now.addingTimeInterval(-7_200))
        done.tenant = "acme"; done.agent = "claude-code"; done.branch = "main"; done.commit = "9f8e7d6c"; done.exitCode = 0
        done.startedAt = now.addingTimeInterval(-7_190); done.endedAt = now.addingTimeInterval(-6_815)
        done.boxStartedAt = done.startedAt; done.boxEndedAt = done.endedAt

        var yesterday = done
        yesterday.id = "rx-yesterday"; yesterday.repo = "acme/nimbus"; yesterday.queuedAt = now.addingTimeInterval(-100_000)
        yesterday.startedAt = yesterday.queuedAt.addingTimeInterval(10); yesterday.endedAt = yesterday.queuedAt.addingTimeInterval(400)
        yesterday.boxStartedAt = yesterday.startedAt; yesterday.boxEndedAt = yesterday.endedAt; yesterday.warmth = "unknown"

        return [running, syncing, github, waiting, queued, failed, localFailed, lost, done, yesterday]
    }

    static func info(repo: String, name: String, status: String, step: String?, number: Int?, done: Int, total: Int,
                     started: Date?) -> GitHubJobInfo {
        GitHubJobInfo(repo: repo, name: name, destination: "ai-eu-1", runId: 1_001, jobId: 2_002, runAttempt: 1, status: status,
                      conclusion: nil, htmlUrl: nil, runnerName: nil, labels: ["self-hosted", "linux"], currentStep: step,
                      currentStepNumber: number, stepsDone: done, stepsTotal: total, createdAt: nil, startedAt: started,
                      completedAt: nil, observation: nil, waitingOnDependency: false, parentAttempt: nil)
    }

    static func destinations(stress: Bool) -> [DestinationCardInput] {
        func config(_ tenant: String, roles: [String], maxJobs: Int, budget: String, targets: [String]?) -> DestinationConfig {
            DestinationConfig(enabled: true, peerID: "n-demo", sshAlias: "demo", tenant: tenant, roles: roles, home: "/home/demo",
                              maxJobs: maxJobs, memoryBudget: budget, rxDefaults: nil, runnerStack: nil, runnerTargets: targets)
        }
        func container(_ name: String, _ id: String, version: String = "2.338.2") -> RunnerContainer {
            RunnerContainer(name: name, id: id, image: "gh-runner:\(version)", state: "running", status: "Up 6 hours")
        }
        let samples = [ContainerSample(name: "rx-8841", cpu: "212%", memory: "6.1GiB / 12GiB"),
                       ContainerSample(name: "runner-atlas", cpu: "35%", memory: "2.4GiB / 32GiB"),
                       ContainerSample(name: "runner-orbit", cpu: "1%", memory: "0.4GiB / 32GiB")]
        let probe = DestinationProbeResult(availability: .online(address: "100.64.0.10"), docker: .ok("27.3", at: now), rsync: .ok("3.3", at: now),
                                           images: .ok(["rx-rust", "gh-runner"], at: now), containers: .ok(samples, at: now.addingTimeInterval(-10)),
                                           cores: 16, memoryFreeMB: 11_200, memoryTotalMB: 32_000, diskTotalMB: 480_000, diskFreeMB: 212_000, osName: "Ubuntu 24.04 LTS", load: 3.4, bootID: "boot", uptime: 86_400 * 9,
                                           clockOffsetMS: 12, probedAt: now.addingTimeInterval(-20))
        let name = stress ? "ai-eu-with-a-very-long-destination-name" : "ai-eu-1"
        let online = DestinationCardInput(
            name: name, config: config("acme", roles: ["rx", "runners"], maxJobs: 3, budget: "36g", targets: ["acme/atlas", "org:Acme"]),
            availability: .online(address: "100.64.0.10"), probe: probe,
            runners: [.init(container: container("runner-atlas", "bf4597"), job: "gh-2002", readiness: "registered", busy: true, cpu: "35%", memory: "2.4 GB"),
                      .init(container: container("runner-orbit", "c01d12", version: "2.337.0"), cpu: "1%", memory: "0.4 GB")],
            staleRegistrations: 1, latestRunner: ("2.340.0", "2026-11-20"), rxJobs: jobs(stress: false).filter { $0.id == "rx-running" },
            images: ["rx-rust:latest, 3 days", "gh-runner:2.338.2, 9 days"])
        var offlineProbe = probe
        offlineProbe = DestinationProbeResult(availability: .offline("peer offline"), docker: .ok("27.3", at: now), rsync: .ok("3.3", at: now),
                                              images: .ok(["rx-rust"], at: now), containers: .ok([], at: now), cores: 8, memoryFreeMB: 6_000, memoryTotalMB: 16_000, diskTotalMB: 240_000, diskFreeMB: 90_000, osName: "Ubuntu 22.04 LTS",
                                              load: 0.4, bootID: "boot", uptime: 86_400, clockOffsetMS: 8, probedAt: now.addingTimeInterval(-2_400))
        let offline = DestinationCardInput(
            name: "globex-s1", config: config("globex", roles: ["rx"], maxJobs: 2, budget: "20g", targets: nil),
            availability: .offline("peer offline since 14:43"), probe: offlineProbe, staleRegistrations: 2, images: ["rx-rust:latest, 12 days"])
        return [online, offline]
    }

    static func rulesState() -> RulesState {
        let demo = Self.demoRulesJSON
        guard let rules = try? JSONDecoder().decode(Rules.self, from: Data(demo.utf8)) else {
            return .invalid(path: "rules.json", message: "unreadable demo rules")
        }
        return .valid(rules, fingerprint: "demo")
    }

    /// The demo fleet: two companies, one online box and one offline.
    static let demoRulesJSON = """
    {
      "destinations": {
        "ai-eu-1": {
          "enabled": true, "peer_id": "nAcmeBox0001CNTRL", "ssh_alias": "ai-eu-1", "tenant": "acme",
          "roles": ["rx", "runners"], "home": "/home/ubuntu", "max_jobs": 3, "memory_budget": "36g",
          "rx_defaults": { "cpus": 8, "memory": "12g" }, "runner_stack": "/home/ubuntu/infra/gh-runners",
          "runner_targets": ["acme/ledger", "acme/atlas", "org:Acme"]
        },
        "globex-s1": {
          "enabled": true, "peer_id": "", "ssh_alias": "globex-s1", "tenant": "globex",
          "roles": ["rx", "runners"], "home": "/home/globex", "max_jobs": 2, "memory_budget": "24g",
          "runner_targets": ["org:globex"]
        }
      },
      "tenants": {
        "acme": { "owners": ["acme"], "repos": ["acme/ledger", "acme/atlas"] },
        "globex": { "owners": ["globex"], "repos": ["acme/portal*", "acme/gateway*"] },
        "personal": { "repos": ["acme/axon", "acme/run.dev", "acme/cloak",
                                "acme/bton", "acme/notes", "acme/runmyjob"] }
      },
      "rules": [
        { "name": "cargo build stays local (the box builds x86_64)",
          "match": { "command": ["cargo build"] }, "to": ["local"],
          "advisory": "the box builds x86_64 Linux binaries; a binary for this Mac is built here" },
        { "name": "cargo repos to the rust image",
          "match": { "tenant": ["acme", "personal"], "command": ["cargo", "just"], "has": "Cargo.toml" },
          "to": ["ai-eu-1"], "image": "rx-rust",
          "volumes": ["rx-cargo-registry:/usr/local/cargo/registry", "rx-cargo-git:/usr/local/cargo/git",
                      "rx-rustup:/usr/local/rustup", "rx-target-{repo}:/work/target"],
          "cold_marker": { "acme/atlas": "Compiling libduckdb-sys" } },
        { "name": "ledger gate image with its dev pair",
          "match": { "repo": ["acme/ledger"] }, "to": ["ai-eu-1"], "profile": "ledger" },
        { "name": "Globex repos to s1",
          "match": { "tenant": ["globex"] }, "to": ["globex-s1"], "image": "rx-node" }
      ]
    }
    """
}
