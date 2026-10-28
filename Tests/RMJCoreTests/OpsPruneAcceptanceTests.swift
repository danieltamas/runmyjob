import Testing
import Foundation
import RMJCore

final class FakeWriteAPI: GitHubWriteAPI, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let token: String?
    }
    private let lock = NSLock()
    private var recorded: [Call] = []
    let pages: [[GitHubRunner]]
    let singles: [Int64: GitHubRunner]
    let missing: Set<Int64>
    let failingPage: Int?
    init(pages: [[GitHubRunner]], singles: [Int64: GitHubRunner] = [:], missing: Set<Int64> = [], failingPage: Int? = nil) {
        self.pages = pages
        self.singles = singles
        self.missing = missing
        self.failingPage = failingPage
    }
    var calls: [Call] { lock.withLock { recorded } }
    func get(_ path: String, query: [String: String], etag: String?, token: String?) async throws -> GitHubResponse {
        lock.withLock { recorded.append(Call(method: "GET", path: path, query: query, token: token)) }
        if let id = path.split(separator: "/").last.flatMap({ Int64($0) }) {
            guard !missing.contains(id), let runner = singles[id] ?? pages.flatMap({ $0 }).first(where: { $0.id == id }) else {
                return GitHubResponse(status: 404)
            }
            return GitHubResponse(status: 200, body: try JSONSerialization.data(withJSONObject: Self.json(runner)))
        }
        let page = Int(query["page"] ?? "1") ?? 1
        if page == failingPage { return GitHubResponse(status: 500) }
        let runners = pages.indices.contains(page - 1) ? pages[page - 1] : []
        return GitHubResponse(status: 200,
                              body: try JSONSerialization.data(withJSONObject: ["runners": runners.map(Self.json)]),
                              hasNextPage: page < pages.count)
    }
    func delete(_ path: String, token: String?) async throws -> GitHubResponse {
        lock.withLock { recorded.append(Call(method: "DELETE", path: path, query: [:], token: token)) }
        return GitHubResponse(status: 204)
    }
    private static func json(_ runner: GitHubRunner) -> [String: Any] {
        ["id": runner.id, "name": runner.name, "status": runner.online ? "online" : "offline",
         "busy": runner.busy, "labels": runner.labels.map { ["name": $0] }]
    }
}

private let u6PrunePath = "/repos/acme/atlas/actions/runners"
private func u6Stale(_ id: Int64, age: Int = 660, online: Bool = false, busy: Bool = false,
                     labels: [String] = ["ai-eu-1"], name: String? = nil) -> GitHubRunner {
    GitHubRunner(id: id, name: name ?? "0123456789ab-\(Int(u6Now.timeIntervalSince1970) - age)",
                 online: online, busy: busy, labels: labels)
}

struct OpsPruneAcceptanceTests {
    @Test func pruneRequiresShapeAgeLabelOfflineAndIdleAndRevalidates() async throws {
        let a = u6Stale(1)
        let runners = [a, u6Stale(2, age: 300), u6Stale(3, online: true), u6Stale(4, busy: true),
                       u6Stale(5, labels: ["another-destination"]), u6Stale(6, name: "my-laptop-runner"),
                       u6Stale(7, name: "0123456789AB-\(Int(u6Now.timeIntervalSince1970) - 660)"),
                       u6Stale(8, name: "0123456789ab-123")]
        let api = FakeWriteAPI(pages: [runners])
        let pruner = RegistrationPruner(api: api, now: { u6Now })
        #expect(try await pruner.candidates(target: "acme/atlas", destinationLabel: "ai-eu-1", token: "fixture-token") == [a])
        #expect(!api.calls.contains { $0.method == "DELETE" })
        let result = try await pruner.prune(target: "acme/atlas", destinationLabel: "ai-eu-1", token: "fixture-token")
        #expect(result.deleted == [a.name] && result.skipped.isEmpty)
        #expect(api.calls.filter { $0.method == "DELETE" }.map(\.path) == [u6PrunePath + "/1"])
        let read = try #require(api.calls.firstIndex { $0.path == u6PrunePath + "/1" && $0.method == "GET" })
        let deletion = try #require(api.calls.firstIndex { $0.method == "DELETE" })
        #expect(read < deletion)
        #expect(api.calls.allSatisfy { $0.token == "fixture-token" })
        for gone in [false, true] {
            var revived = a; revived.online = true
            let changed = FakeWriteAPI(pages: [[a]], singles: [1: revived], missing: gone ? [1] : [])
            let skipped = try await RegistrationPruner(api: changed, now: { u6Now })
                .prune(target: "acme/atlas", destinationLabel: "ai-eu-1", token: nil)
            #expect(skipped.deleted.isEmpty)
            #expect(skipped.skipped.count == 1)
            #expect(skipped.skipped.first?.runner == a.name)
            if gone { #expect(skipped.skipped.first?.reason == "already gone") }
            else { #expect(skipped.skipped.first?.reason.isEmpty == false) }
            #expect(!changed.calls.contains { $0.method == "DELETE" })
        }
    }

    @Test func pruneUsesOrgTargetAndTokenRejectsBadTargetsAndFailsClosedOnLaterPage() async throws {
        let a = u6Stale(1)
        let org = FakeWriteAPI(pages: [[a]])
        let result = try await RegistrationPruner(api: org, now: { u6Now })
            .prune(target: "org:Acme", destinationLabel: "ai-eu-1", token: "org-fixture-token")
        #expect(result.deleted == [a.name])
        #expect(org.calls.allSatisfy { $0.path.hasPrefix("/orgs/Acme/actions/runners") && $0.token == "org-fixture-token" })
        #expect(org.calls.contains { $0.method == "DELETE" && $0.path == "/orgs/Acme/actions/runners/1" })
        for target in ["bad", "org:", "owner/repo/extra"] {
            let api = FakeWriteAPI(pages: [[a]])
            await #expect(throws: GitHubRunners.Failure.self) {
                _ = try await RegistrationPruner(api: api, now: { u6Now })
                    .prune(target: target, destinationLabel: "ai-eu-1", token: nil)
            }
            #expect(api.calls.isEmpty)
        }
        let broken = FakeWriteAPI(pages: [[a], []], failingPage: 2)
        await #expect(throws: GitHubRunners.Failure.self) {
            _ = try await RegistrationPruner(api: broken, now: { u6Now })
                .prune(target: "acme/atlas", destinationLabel: "ai-eu-1", token: nil)
        }
        #expect(broken.calls.contains { $0.query["page"] == "2" })
        #expect(!broken.calls.contains { $0.method == "DELETE" })
    }

    @Test func pruneConsidersAllRegistrationsAcrossMoreThanOneHundredRunners() async throws {
        let first = (1...100).map {
            u6Stale(Int64($0), name: String(format: "%012llx", Int64($0)) + "-1793101740")
        }
        let last = u6Stale(101, age: 900)
        let api = FakeWriteAPI(pages: [first, [last]])
        let result = try await RegistrationPruner(api: api, now: { u6Now })
            .prune(target: "acme/atlas", destinationLabel: "ai-eu-1", token: "fixture")
        #expect(result.deleted == (first + [last]).map(\.name))
        #expect(api.calls.filter { $0.method == "DELETE" }.map(\.path) == (1...101).map { u6PrunePath + "/\($0)" })
        let lists = api.calls.filter { $0.path == u6PrunePath }
        #expect(lists.map { $0.query["page"] } == ["1", "2"])
        #expect(lists.allSatisfy { $0.query["per_page"] == "100" })
        let page2 = try #require(api.calls.firstIndex { $0.query["page"] == "2" })
        let deletion = try #require(api.calls.firstIndex { $0.method == "DELETE" })
        #expect(page2 < deletion)
    }
}
