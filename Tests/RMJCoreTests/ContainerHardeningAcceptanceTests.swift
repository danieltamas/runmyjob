import Foundation
import Testing
@testable import RMJCore

struct ContainerHardeningAcceptanceTests {
    private func rule(_ hardening: Bool? = nil) throws -> Rule {
        var json: [String: Any] = ["name": "fixture", "match": [:], "to": ["local"],
            "image": "rx-rust", "cpus": 3, "memory": "6g"]
        if let hardening { json["hardening"] = hardening }
        return try JSONDecoder().decode(Rule.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func defaultAndExplicitHardeningFollowMemoryAndPrecedeImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(home: RMJHome(environment: ["RMJ_HOME": root.path]))
        let config = try #require(Rules.shipped.destinations["ai-eu-1"])
        for enabled in [nil, true] as [Bool?] {
            let plan = try DockerPlan.make(rule: rule(enabled), config: config, repo: "fixture/repo",
                directory: "/fixture/work", profiles: store)
            #expect(Array(plan.options.prefix(12)) == ["--cpus", "3", "--memory", "6g",
                "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "4096", "--user", "@box"])
            #expect(plan.options.contains("/fixture/work:/work"))
            #expect(plan.options.suffix(2) == ["--entrypoint", "/work/.rmj/exec"])
            let argv = plan.options + [plan.image, "printf", "@box"]
            let image = try #require(argv.firstIndex(of: "rx-rust"))
            for flag in ["--cap-drop", "--security-opt", "--pids-limit", "--user"] {
                #expect(try #require(argv.firstIndex(of: flag)) < image)
            }
        }
    }

    @Test func optOutRemovesHardeningButPreservesProfileUser() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = RMJHome(environment: ["RMJ_HOME": root.path])
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        try Data(#"{"image":"rx-rust","user":"1234:1234"}"#.utf8).write(to: profiles.appendingPathComponent("fixture.json"))
        let config = try #require(Rules.shipped.destinations["ai-eu-1"])
        for useProfile in [false, true] {
            for hardening in [false, true] {
                var rule = try rule(hardening)
                if useProfile { rule.image = nil; rule.profile = "fixture" }
                let plan = try DockerPlan.make(rule: rule, config: config, repo: nil,
                    directory: "/fixture/work", profiles: ProfileStore(home: home))
                for flag in ["--cap-drop", "--security-opt", "--pids-limit"] {
                    #expect(plan.options.contains(flag) == hardening)
                }
                #expect(plan.options.filter { $0 == "--user" }.count == (useProfile || hardening ? 1 : 0))
                #expect(plan.options.contains("@box") == (!useProfile && hardening))
                if useProfile {
                    let index = try #require(plan.options.firstIndex(of: "--user"))
                    #expect(plan.options[index + 1] == "1234:1234")
                }
                #expect(plan.options.contains("--cpus") && plan.options.contains("--memory"))
                #expect(plan.options.contains("/fixture/work:/work") && plan.options.contains("/work/.rmj/exec"))
            }
        }
    }

    @Test func hardeningRoundTripsAndRejectsNonBooleanJSON() throws {
        for value in [true, false] {
            let original = try rule(value)
            #expect(original.hardening == value)
            let decoded = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(original))
            #expect(decoded.hardening == value)
        }
        for value in ["off", 0, [true]] as [Any] {
            let json: [String: Any] = ["destinations": [:], "tenants": [:], "rules": [
                ["name": "bad", "match": [:], "to": ["local"], "image": "rx-rust", "hardening": value]]]
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: RulesError.self) { try RulesValidation.parse(data) }
        }
    }

    @Test func boxScriptSubstitutesBoxIdentity() {
        #expect(BoxAssets.script.contains("@box"))
        #expect(BoxAssets.script.contains("id -u") && BoxAssets.script.contains("id -g"))
    }

    @Test func jobCommandBoxMarkerPassesThroughUntouched() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        var request = f.request()
        request.command = ["echo", "@box"]
        _ = await f.engine().run(request)
        let job = try #require(await f.box.jobs.first)
        #expect(job.argv == ["echo", "@box"])
    }
}
