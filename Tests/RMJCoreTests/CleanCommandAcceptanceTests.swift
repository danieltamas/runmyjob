import Foundation
import Testing
@testable import RMJCore

private final class CleanBundleMarker: NSObject {}

private func cleanCLI() throws -> String {
    let bundles = [Bundle(for: CleanBundleMarker.self)] + Bundle.allBundles
    let starts = bundles.filter { $0.bundleURL.pathExtension == "xctest" }.map(\.bundleURL)
        + [URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()]
    for start in starts {
        var directory = start
        while true {
            let candidate = directory.appendingPathComponent("RMJCLI").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
    }
    Issue.record("Build RMJCLI beside the SwiftPM test product before running command acceptance tests")
    throw BoxFailure("RMJCLI test product missing")
}

private func cleanCommand(_ f: CleanFixture, _ arguments: [String]) async throws -> ProcessOutput {
    try await ProcessRunner().run(try cleanCLI(), ["clean"] + arguments, in: f.root,
        environment: ["RMJ_HOME": f.home.url.path, "HOME": f.root.path, "PATH": "/usr/bin:/bin"], timeout: .seconds(60))
}

private func cleanObject(_ output: ProcessOutput) throws -> [String: Any] {
    // Parsing the entire stdout rejects extra prose, extra objects and trailing output.
    try #require(try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
}

struct CleanCommandAcceptanceTests {
    @Test func textDryRunRemovesNothingAndApplyRemovesWithExitZero() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let path = try f.directory("scratch-cli"); try f.payload(path)
        try f.writeTargets([f.scratch()])
        let dry = try await cleanCommand(f, [])
        #expect(dry.status == 0 && !dry.stdout.isEmpty && f.exists(path))
        let applied = try await cleanCommand(f, ["--apply"])
        #expect(applied.status == 0 && !f.exists(path))
        let runs = try await f.ledger.cleanRuns(limit: 20)
        #expect(runs.count == 2)
        for run in runs { try await f.trace(run) }
    }

    @Test func jsonIsOneObjectWithTheDocumentedRunShape() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let path = try f.directory("scratch-json"); try f.payload(path)
        try f.writeTargets([f.scratch()])
        let dry = try await cleanCommand(f, ["--json"])
        #expect(dry.status == 0 && f.exists(path))
        let object = try cleanObject(dry)
        #expect(Set(object.keys) == Set(["run", "apply", "freed_bytes", "items"]))
        let id = try #require(object["run"] as? String)
        #expect(id.range(of: "^[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil)
        #expect(object["apply"] as? Bool == false && object["freed_bytes"] as? Int == 0)
        let items = try #require(object["items"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items.first?["path"] as? String == path.path)
        #expect(items.first?["action"] as? String == "would_remove")
        #expect(items.first?["kind"] as? String == "scratch")
        #expect(items.first?["bytes"] as? Int == 37 && items.first?["reason"] is String)
        let applied = try await cleanCommand(f, ["--apply", "--json"])
        let appliedObject = try cleanObject(applied)
        #expect(applied.status == 0 && !f.exists(path))
        #expect(appliedObject["apply"] as? Bool == true && appliedObject["freed_bytes"] as? Int == 37)
        #expect((appliedObject["items"] as? [[String: Any]])?.first?["action"] as? String == "removed")
    }

    @Test func failedRemovalExitsOneAndLeavesARecordAndLogLine() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let path = try f.directory("scratch-locked-cli"); try f.payload(path)
        try f.writeTargets([f.scratch()])
        try await cleanProcess("/usr/bin/chflags", ["uchg", path.path])
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path.path) }
        let result = try await cleanCommand(f, ["--apply", "--json"])
        #expect(result.status == 1 && f.exists(path))
        let object = try cleanObject(result)
        #expect((object["items"] as? [[String: Any]])?.first?["action"] as? String == "failed")
        let run = try #require(try await f.ledger.cleanRuns(limit: 1).first)
        try await f.trace(run)
    }

    @Test func rejectedConfigExitsTwoAndDoesNotRemoveAnything() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let path = try f.directory("scratch-invalid"); try f.payload(path)
        // A valid target before the invalid one must not be applied partially.
        let valid = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.scratch())) as? [String: Any])
        let raw = try JSONSerialization.data(withJSONObject: ["targets": [valid, ["kind": "invalid", "path": path.path]]])
        try f.writeConfig(String(decoding: raw, as: UTF8.self))
        let result = try await cleanCommand(f, ["--apply"])
        #expect(result.status == 2 && f.exists(path))
        #expect(!result.stdout.isEmpty || !result.stderr.isEmpty)
    }

    @Test(arguments: [["--unknown"], ["log", "--run"], ["unexpected"]])
    func usageErrorsExitTwo(arguments: [String]) async throws {
        let f = try CleanFixture(); defer { f.remove() }
        try f.writeTargets([])
        #expect(try await cleanCommand(f, arguments).status == 2)
    }

    @Test func logListsLastTwentyRunsAndRunFilterPrintsItsItems() async throws {
        let f = try CleanFixture(); defer { f.remove() }
        let path = try f.directory("scratch-history"); try f.payload(path)
        try f.writeTargets([f.scratch()])
        var ids: [String] = []
        for index in 0..<21 {
            let run = try await f.run([f.scratch()], apply: false, now: f.now.addingTimeInterval(Double(index)))
            ids.append(run.id)
        }
        let listed = try await cleanCommand(f, ["log"])
        #expect(listed.status == 0)
        let text = String(decoding: listed.stdout, as: UTF8.self)
        #expect(!text.contains(ids[0]))
        for id in ids.dropFirst() { #expect(text.contains(id)) }
        let selected = try await cleanCommand(f, ["log", "--run", ids[0]])
        #expect(selected.status == 0)
        let detail = String(decoding: selected.stdout, as: UTF8.self)
        #expect(detail.contains(path.path))
        // The plan does not prescribe the JSON shape of history, only that it supports --json.
        for args in [["log", "--json"], ["log", "--run", ids[0], "--json"]] {
            let result = try await cleanCommand(f, args)
            #expect(result.status == 0)
            _ = try JSONSerialization.jsonObject(with: result.stdout)
        }
        #expect(f.exists(path))
    }
}
