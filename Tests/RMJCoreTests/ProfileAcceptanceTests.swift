import Foundation
import Testing
@testable import RMJCore

func writeLedgerProfile(home: RMJHome) throws {
    let directory = home.url.appendingPathComponent("profiles")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"image":"rx-ledger","network":"dev","user":"1000:1000","prelude":"ledger.prelude.sh"}"#.utf8)
        .write(to: directory.appendingPathComponent("ledger.json"))
    try Data("echo ledger setup\n".utf8).write(to: directory.appendingPathComponent("ledger.prelude.sh"))
}

struct ProfileAcceptanceTests {
    @Test func homeProfileAndPreludeReachTheBox() async throws {
        let f = try await RunFixture.make(profile: "ledger"); defer { f.remove() }
        let result = await f.engine().run(f.request())
        #expect(result.exitCode == 0)
        let job = try #require(await f.box.jobs.first)
        #expect(job.image == "rx-ledger")
        #expect(job.options.contains("dev") && job.options.contains("1000:1000"))
        #expect(job.prelude?.content == "echo ledger setup\n")
        #expect(job.prelude?.path.hasSuffix("/ledger.prelude.sh") == true)
    }

    @Test func unknownProfileIsRejectedByStoreAndFallsBackBeforeBoxPreparation() async throws {
        let f = try await RunFixture.make(profile: "missing"); defer { f.remove() }
        let home = RMJHome(environment: ["RMJ_HOME": f.root.path])
        let store = RulesStore(home: home)
        var rules = Rules.shipped
        rules.rules = [rules.rules[2]]
        rules.rules[0].profile = "missing"
        rules.tenants.removeValue(forKey: "personal")
        try JSONEncoder().encode(rules).write(to: store.url)
        guard case .invalid(_, let message) = store.load() else {
            Issue.record("Unknown profile must invalidate rules"); return
        }
        #expect(message.contains("unknown profile") && message.contains("missing"))
        let result = await f.engine().run(f.request())
        let row = try #require(try await f.ledger.job(result.jobID))
        #expect(row.location == "local" && row.fallbackReason == "no container for this rule")
        #expect(await f.box.calls.isEmpty)
    }

    @Test func profileAndPreludePathsCannotEscapeDirectory() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        let home = RMJHome(environment: ["RMJ_HOME": f.root.path])
        let store = ProfileStore(home: home)
        try Data(#"{"image":"outside"}"#.utf8).write(to: f.root.appendingPathComponent("outside.json"))
        try Data("outside prelude".utf8).write(to: f.root.appendingPathComponent("outside.sh"))
        let config = try #require(Rules.shipped.destinations["ai-eu-1"])
        for name in ["../outside", "../profiles/ledger", "sub/ledger", "..", "/outside"] {
            #expect(!store.exists(name))
            #expect(store.json(name) == nil)
            #expect(throws: RulesError.self) {
                var rules = Rules.starter
                var rule = Rules.shipped.rules[2]; rule.profile = name; rule.to = ["local"]
                rules.rules = [rule]
                return try RulesValidation.parse(JSONEncoder().encode(rules), profileExists: store.exists)
            }
            var rule = Rules.shipped.rules[2]; rule.profile = name
            #expect(throws: DockerPlan.Failure.unknownProfile(name)) {
                try DockerPlan.make(rule: rule, config: config, repo: "acme/ledger", directory: "/work", profiles: store)
            }
        }
        for name in ["../outside.sh", "/outside.sh", "sub/../../outside.sh", ".."] {
            #expect(store.prelude(name) == nil)
        }
    }
}
