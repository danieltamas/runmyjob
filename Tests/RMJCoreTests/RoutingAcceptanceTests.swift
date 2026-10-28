import Testing
import Foundation
import RMJCore

private let routingNow = Date(timeIntervalSince1970: 1_793_102_400)
private let routingTarget = DestinationTarget(alias: "ai-eu-1", peerID: "n-ai-acme-1")

private func routingTailnet(_ name: String = "running") async -> TailnetState {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/tailnet/\(name).json").path
    return await TailnetState.read(environment: ["RMJ_TAILSCALE_FIXTURE": path], now: routingNow)
}

private func routingRules() -> Rules {
    var rules = Rules.shipped
    rules.destinations["ai-eu-1"]?.peerID = "n-ai-acme-1"
    return rules
}

private struct RoutingTransport: RemoteTransport {
    let containers: String
    let images: String

    func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput {
        let output = """
        @@docker rc=0
        27.3.1
        @@rsync rc=0
        rsync version 3.2.7
        @@images rc=0
        \(images)
        @@containers rc=0
        \(containers)
        @@nproc rc=0
        24
        @@mem rc=0
        40000
        @@load rc=0
        0.5
        @@boot rc=0
        routing-boot
        @@uptime rc=0
        3600
        @@clock rc=0
        1793102400000000000
        @@end
        """
        return ProcessOutput(status: 0, stdout: Data(output.utf8), stderr: "")
    }
}

private func routingProbe(age: TimeInterval = 10, containers: String = "", images: String = "rx-rust:latest") async -> DestinationProbeResult {
    await DestinationProbe(transport: RoutingTransport(containers: containers, images: images))
        .probe(routingTarget, tailnet: routingTailnet(), now: routingNow.addingTimeInterval(-age))
}

private actor RoutingProbeSpy: ProbeProvider {
    var latest: DestinationProbeResult?
    let refreshed: DestinationProbeResult
    private(set) var calls = 0

    init(latest: DestinationProbeResult?, refreshed: DestinationProbeResult) {
        self.latest = latest
        self.refreshed = refreshed
    }

    func latest(for destination: String) async -> DestinationProbeResult? { latest }
    func probe(_ target: DestinationTarget, tailnet: TailnetState) async -> DestinationProbeResult {
        calls += 1
        latest = refreshed
        return refreshed
    }
}

private func routingRequest(_ command: [String] = ["cargo", "test"], slug: String? = "acme/axon",
                            destination: String? = nil, forced: Bool = false) -> RouteRequest {
    RouteRequest(command: command, identity: RepoIdentity(slug: slug, worktree: "/tmp/rmj-acceptance"),
                 forceLocal: forced, destination: destination)
}

private func routingRouter(_ spy: RoutingProbeSpy, rules: Rules = routingRules(),
                           state: TailnetState, cargo: Bool = true) -> Router {
    Router(rules: .valid(rules, fingerprint: "acceptance"), tailnet: state, probes: spy,
           fileExists: { cargo && $0 == "/tmp/rmj-acceptance/Cargo.toml" }, now: { routingNow })
}

struct RoutingAcceptanceTests {
    @Test func companyTenantDenyAppliesToRulesAndExplicitDestination() async {
        let probe = await routingProbe()
        let state = await routingTailnet()
        for (slug, destinationTenant, reason) in [
            ("globex/portal-x", "acme", "denied: tenant globex on acme destination"),
            ("acme/atlas", "globex", "denied: tenant acme on globex destination")
        ] {
            var rules = routingRules()
            rules.destinations["ai-eu-1"]?.tenant = destinationTenant
            rules.rules = [rules.rules[1]]
            rules.rules[0].match.tenant = nil
            for override in [nil, "ai-eu-1"] as [String?] {
                let spy = RoutingProbeSpy(latest: probe, refreshed: probe)
                let decision = await routingRouter(spy, rules: rules, state: state)
                    .route(routingRequest(slug: slug, destination: override))
                #expect(decision.location == .local)
                #expect(decision.explanation.joined(separator: "\n").contains(reason))
                #expect(await spy.calls == 0)
            }
        }
    }

    @Test func personalReposMayUseEitherCompanyDestination() async {
        let probe = await routingProbe()
        for tenant in ["acme", "globex"] {
            var rules = routingRules()
            rules.destinations["ai-eu-1"]?.tenant = tenant
            let spy = RoutingProbeSpy(latest: probe, refreshed: probe)
            let router = await routingRouter(spy, rules: rules, state: routingTailnet())
            for override in [nil, "ai-eu-1"] as [String?] {
                let decision = await router.route(routingRequest(destination: override))
                #expect(decision.location == .destination(name: "ai-eu-1", address: "100.64.0.10"))
                #expect(decision.tenant == "personal")
            }
        }
    }

    @Test func canonicalRepoSlugNormalizesSupportedRemotesAndRejectsGarbage() {
        for remote in ["git@github.com:Acme/Axon.git", "https://github.com/acme/axon",
                       "ssh://git@github.com/Acme/Axon"] {
            #expect(RepoIdentity.canonicalSlug(remoteURL: remote) == "acme/axon")
        }
        for remote in ["garbage", "a/b/c", "../x"] {
            #expect(RepoIdentity.canonicalSlug(remoteURL: remote) == nil)
        }
    }

    @Test func unknownAndMissingRepoStayUnclassified() async {
        let probe = await routingProbe()
        let spy = RoutingProbeSpy(latest: probe, refreshed: probe)
        let router = await routingRouter(spy, state: routingTailnet())
        for slug in ["nobody/thing", nil] as [String?] {
            let decision = await router.route(routingRequest(slug: slug))
            #expect(decision.location == .local)
            #expect(decision.fallbackReason == "unclassified repo")
            #expect(decision.tenant == "unclassified")
        }
        #expect(await spy.calls == 0)
    }

    @Test func shippedCargoRulesDistinguishBuildTestBareCommandAndMissingManifest() async {
        let probe = await routingProbe()
        let spy = RoutingProbeSpy(latest: probe, refreshed: probe)
        let state = await routingTailnet()
        let router = routingRouter(spy, state: state)
        let build = await router.route(routingRequest(["cargo", "build"]))
        #expect(build.location == .local)
        #expect(build.rule?.contains("cargo build") == true)
        #expect(build.fallbackReason == nil)
        let test = await router.route(routingRequest())
        #expect(test.location == .destination(name: "ai-eu-1", address: "100.64.0.10"))
        #expect(test.fallbackReason == nil)
        let bare = await router.route(routingRequest(["cargo"]))
        #expect(bare.location == .local)
        #expect(bare.fallbackReason == "no rule")
        let missing = await routingRouter(spy, state: state, cargo: false).route(routingRequest())
        #expect(missing.location == .local)
        #expect(missing.fallbackReason == "no rule")
    }

    @Test func shippedCargoBuildRulePrecedesGeneralCargoRule() throws {
        let rules = Rules.shipped.rules
        let build = try #require(rules.firstIndex { $0.match.command?.contains("cargo build") == true })
        let general = try #require(rules.firstIndex { $0.match.command?.contains("cargo") == true })
        #expect(build < general)
    }

    @Test func probeAgeRefreshesStaleAndAbsentSamplesExactlyOnce() async {
        let fresh = await routingProbe(age: 0)
        let old = await routingProbe(age: 90)
        let recent = await routingProbe(age: 10)
        let state = await routingTailnet()
        for (latest, expected) in [(old, 1), (recent, 0), (nil, 1)] as [(DestinationProbeResult?, Int)] {
            let spy = RoutingProbeSpy(latest: latest, refreshed: fresh)
            let decision = await routingRouter(spy, state: state).route(routingRequest())
            #expect(decision.location == .destination(name: "ai-eu-1", address: "100.64.0.10"))
            #expect(await spy.calls == expected)
        }
    }

    @Test func maxJobsSkipsFullDestinationAndFallsLocal() async {
        let probe = await routingProbe(containers: "rx-a 0% 1MiB / 1GiB\nrx-b 0% 1MiB / 1GiB\nrx-c 0% 1MiB / 1GiB")
        let spy = RoutingProbeSpy(latest: probe, refreshed: probe)
        let router = await routingRouter(spy, state: routingTailnet())
        let decision = await router.route(routingRequest())
        #expect(decision.location == .local)
        #expect(decision.fallbackReason?.contains("at max_jobs") == true)
    }

    @Test func runnersDoNotConsumeRxSlotsOrChargeTheirMemoryCaps() async {
        let probe = await routingProbe(containers: (1...3).map { "runner-\($0) 0% 1GiB / 32GiB" }.joined(separator: "\n"))
        let spy = RoutingProbeSpy(latest: probe, refreshed: probe)
        let router = await routingRouter(spy, state: routingTailnet())
        let decision = await router.route(routingRequest())
        #expect(decision.location == .destination(name: "ai-eu-1", address: "100.64.0.10"))
    }

    @Test func memoryBudgetChargesRxLimitsRunnerUsageAndRequestedMemory() async {
        let probe = await routingProbe(containers: "rx-a 0% 1GiB / 20GiB\nrunner-a 0% 5GiB / 6GiB")
        let state = await routingTailnet()
        for explicitMemory in [nil, "12g"] as [String?] {
            var rules = routingRules()
            rules.rules[1].memory = explicitMemory
            let spy = RoutingProbeSpy(latest: probe, refreshed: probe)
            let decision = await routingRouter(spy, rules: rules, state: state).route(routingRequest())
            #expect(decision.location == .local)
            #expect(decision.fallbackReason?.contains("over memory budget") == true)
        }
    }

    @Test func forceLocalWinsForOtherwiseRoutableCargoTest() async {
        let probe = await routingProbe()
        let spy = RoutingProbeSpy(latest: probe, refreshed: probe)
        let router = await routingRouter(spy, state: routingTailnet())
        let decision = await router.route(routingRequest(forced: true))
        #expect(decision.location == .local)
        #expect(decision.fallbackReason == "forced")
        #expect(await spy.calls == 0)
    }

    @Test func tenancyRepoGlobsWinOverOwnersAndIgnoreCase() throws {
        let tenants = try JSONDecoder().decode([String: TenantConfig].self, from: Data("""
        {"personal":{"owners":["GLOBEX","ACME"]},"globex":{"repos":["Globex/Portal*"]}}
        """.utf8))
        for slug in ["globex/portal-x", "GLOBEX/PORTAL-X"] {
            let result = Tenancy.resolve(RepoIdentity(slug: slug, worktree: "/tmp/repo"), in: tenants)
            #expect(result.tenant == "globex")
            #expect(result.how.contains("repos table"))
        }
        #expect(Tenancy.resolve(RepoIdentity(slug: "acme/other", worktree: "/tmp/repo"), in: tenants).tenant == "personal")
    }

    @Test func commandWordsHandleToolchainsAbsoluteProgramsAndBareMake() {
        #expect(CommandWords(argv: ["cargo", "+nightly", "test"]).subcommand == "test")
        #expect(CommandWords(argv: ["/usr/bin/cargo", "build"]).program == "cargo")
        #expect(CommandWords(argv: ["make"]).subcommand == nil)
    }

    @Test func stoppedTailnetFallsLocalWithoutProbing() async {
        let probe = await routingProbe()
        let spy = RoutingProbeSpy(latest: nil, refreshed: probe)
        let router = await routingRouter(spy, state: routingTailnet("stopped"))
        let decision = await router.route(routingRequest())
        #expect(decision.location == .local)
        #expect(decision.fallbackReason == "tailnet down")
        #expect(await spy.calls == 0)
    }

    @Test func missingRuleImageSkipsDestination() async {
        let probe = await routingProbe(images: "rx-node:latest")
        let spy = RoutingProbeSpy(latest: probe, refreshed: probe)
        let router = await routingRouter(spy, state: routingTailnet())
        let decision = await router.route(routingRequest())
        #expect(decision.location == .local)
        #expect(decision.fallbackReason?.contains("lacks image rx-rust") == true)
    }

    @Test func explanationIncludesInputsTenantEveryTriedRuleAndResult() async {
        let probe = await routingProbe()
        let spy = RoutingProbeSpy(latest: probe, refreshed: probe)
        let router = await routingRouter(spy, state: routingTailnet())
        let decision = await router.route(routingRequest())
        let lines = decision.explanation
        #expect(lines.contains { $0.contains("repo: acme/axon") })
        #expect(lines.contains { $0.contains("command: cargo test") })
        #expect(lines.contains { $0.contains("tenant: personal") && $0.contains("repos table") })
        for rule in Rules.shipped.rules.prefix(2) {
            #expect(lines.contains { $0.contains("rule \"\(rule.name)\"") })
        }
        #expect(lines.last == "result: ai-eu-1 at 100.64.0.10")
    }
}
