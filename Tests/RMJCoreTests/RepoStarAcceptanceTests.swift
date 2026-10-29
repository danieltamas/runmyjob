import Foundation
import Testing
import RMJCore

struct RepoStarAcceptanceTests {
    @Test func freshHomeOffersStarAnd404DoesNotWrite() async throws {
        let f = try RepoStarFixture(); defer { f.remove() }
        let calls = RepoStarCalls()
        let subject = f.subject(calls, output: "HTTP/2.0 404 Not Found\n...")
        #expect(subject.shouldOffer())
        #expect(await subject.refresh() == .notStarred)
        #expect(subject.shouldOffer())
        #expect(!FileManager.default.fileExists(atPath: f.config.path))
        #expect(await calls.arguments == [["api", "-i", "user/starred/danieltamas/runmyjob"]])
    }

    @Test func confirmedStarIsRememberedAcrossInstancesAndSkipsFurtherChecks() async throws {
        let f = try RepoStarFixture(); defer { f.remove() }
        try Data(#"{"max_jobs":3}"#.utf8).write(to: f.config)
        let calls = RepoStarCalls()
        let subject = f.subject(calls, output: "HTTP/2.0 204 No Content")
        #expect(await subject.refresh() == .starred)
        #expect(!subject.shouldOffer())
        #expect(await subject.refresh() == .starred)
        let reloaded = f.subject(calls, output: "HTTP/2.0 404 Not Found")
        #expect(!reloaded.shouldOffer())
        _ = await reloaded.refresh()
        #expect(await calls.arguments.count == 1)
        let config = try f.readConfig()
        #expect(config["starred_repo"] as? Bool == true)
        #expect(config["max_jobs"] as? Int == 3)
    }

    @Test func unknownResponsesAreNotRemembered() async throws {
        for (status, output) in [(Int32(0), ""), (0, "HTTP/2.0 500"), (127, "")] {
            let f = try RepoStarFixture(); defer { f.remove() }
            let calls = RepoStarCalls()
            let subject = f.subject(calls, status: status, output: output)
            #expect(await subject.refresh() == .unknown)
            #expect(subject.shouldOffer())
            #expect(!FileManager.default.fileExists(atPath: f.config.path))
            #expect(await subject.refresh() == .unknown)
            #expect(await calls.arguments.count == 2)
        }
    }

    @Test func starUsesPutAndPreservesExistingConfiguration() async throws {
        let f = try RepoStarFixture(); defer { f.remove() }
        try Data(#"{"max_jobs":3}"#.utf8).write(to: f.config)
        let calls = RepoStarCalls()
        let subject = f.subject(calls, output: "HTTP/2.0 204 No Content")
        #expect(await subject.star())
        #expect(!subject.shouldOffer())
        #expect(!f.subject(calls, output: "").shouldOffer())
        #expect(await calls.arguments == [["api", "-i", "-X", "PUT", "user/starred/danieltamas/runmyjob"]])
        let config = try f.readConfig()
        #expect(config["starred_repo"] as? Bool == true)
        #expect(config["max_jobs"] as? Int == 3)
    }

    @Test func failedStarLeavesOfferAndConfigurationUntouched() async throws {
        for output in ["HTTP/2.0 403 Forbidden", ""] {
            let f = try RepoStarFixture(); defer { f.remove() }
            let calls = RepoStarCalls()
            let subject = f.subject(calls, output: output)
            #expect(await subject.star() == false)
            #expect(subject.shouldOffer())
            #expect(!FileManager.default.fileExists(atPath: f.config.path))
        }
    }

    @Test func dismissalPersistsAndPreventsGitHubChecks() async throws {
        let f = try RepoStarFixture(); defer { f.remove() }
        try Data(#"{"max_jobs":3}"#.utf8).write(to: f.config)
        let calls = RepoStarCalls()
        let subject = f.subject(calls, output: "HTTP/2.0 204 No Content")
        subject.dismiss()
        #expect(!subject.shouldOffer())
        _ = await subject.refresh()
        let reloaded = f.subject(calls, output: "")
        #expect(!reloaded.shouldOffer())
        _ = await reloaded.refresh()
        #expect(await calls.arguments.isEmpty)
        #expect(try f.readConfig()["max_jobs"] as? Int == 3)
    }
}

private actor RepoStarCalls {
    var arguments: [[String]] = []
    func record(_ value: [String]) { arguments.append(value) }
}

private struct RepoStarFixture {
    let root: URL
    let home: RMJHome
    var config: URL { root.appendingPathComponent("config.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-star-\(UUID().uuidString)")
        home = RMJHome(environment: ["RMJ_HOME": root.path])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func subject(_ calls: RepoStarCalls, status: Int32 = 0, output: String) -> RepoStar {
        RepoStar(home: home, gh: { arguments in
            await calls.record(arguments)
            return (status, output)
        })
    }

    func readConfig() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
