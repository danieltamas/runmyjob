import Testing
import Foundation
import CryptoKit
import RMJCore

private func extrasSHA(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct ExtrasFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-extras-\(UUID().uuidString)")
    var directory: URL { root.appendingPathComponent("runner-extras/fixture-box") }
    var stack: URL { root.appendingPathComponent("stack") }
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stack, withIntermediateDirectories: true)
        try Data("services:\n".utf8).write(to: stack.appendingPathComponent("docker-compose.yml"))
        try Data("#!/bin/sh\n".utf8).write(to: stack.appendingPathComponent("entrypoint.sh"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func load(_ destination: String = "fixture-box") -> RunnerExtras {
        RunnerExtras.load(destination: destination, home: RMJHome(environment: ["RMJ_HOME": root.path]))
    }
    func write(_ name: String, _ data: Data = Data("fixture".utf8)) throws {
        try data.write(to: directory.appendingPathComponent(name))
    }
    func hashes() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["docker-compose.yml", "entrypoint.sh"].map {
            ($0, try Data(contentsOf: stack.appendingPathComponent($0)))
        })
    }
}

// The remote boundary uses the shared U6 recording shell; the loader uses real files.
private func extrasShell(remote: [String: Data]) -> FakeShell {
    let lines = remote.sorted { $0.key < $1.key }.map { "\(extrasSHA($0.value))  \($0.key)" }.joined(separator: "\n")
    return FakeShell { script, _ in
        if script.contains("sha256sum"), script.contains("| cut ") { return u6Output("__absent__") }
        if script.contains("sha256sum") { return u6Output(lines) }
        if script.contains("cat >") || script.contains("docker compose") || script.contains("docker ps -a") {
            return u6Output()
        }
        Issue.record("Unexpected command: \(script)")
        return u6Output()
    }
}

struct RunnerExtrasAcceptanceTests {
    @Test func loaderAcceptsOnlyPlainRegularNonReservedFiles() throws {
        let f = try ExtrasFixture(); defer { f.remove() }
        let accepted = ["docker-compose.extra.yml", "cache_1.conf", "A-2.txt", "_worker", "-worker"]
        for name in accepted { try f.write(name) }
        for name in ["docker-compose.yml", "docker-compose.rmj.yml", "entrypoint.sh", ".rmj-services",
                     ".rmj-credentials", ".env", ".hidden", "bad name", "bad;name", "caf\u{00e9}"] {
            try f.write(name)
        }
        let subdirectory = f.directory.appendingPathComponent("subdirectory")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: subdirectory.appendingPathComponent("nested.txt"))
        try FileManager.default.createSymbolicLink(at: f.directory.appendingPathComponent("directory-link"), withDestinationURL: subdirectory)
        try FileManager.default.createSymbolicLink(at: f.directory.appendingPathComponent("file-link"), withDestinationURL: f.directory.appendingPathComponent("cache_1.conf"))
        #expect(Set(f.load().files.keys) == Set(accepted))
    }

    @Test func missingAndUnsafeDestinationsLoadNothing() throws {
        let f = try ExtrasFixture(); defer { f.remove() }
        try f.write("sentinel.txt")
        for name in ["missing", "../fixture-box", "fixture-box/", ".hidden", "fixture..box", ".."] {
            let candidate = f.root.appendingPathComponent("runner-extras").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            if name != "missing" { try Data("sentinel".utf8).write(to: candidate.appendingPathComponent("sentinel.txt")) }
            #expect(f.load(name).files.isEmpty, "Unsafe or missing destination: \(name)")
        }
        #expect(f.load("never-created").files.isEmpty)
    }

    @Test func loaderEnforcesFileCountAndOneMegabyteBoundary() throws {
        let f = try ExtrasFixture(); defer { f.remove() }
        try f.write("exact.bin", Data(repeating: 65, count: 1_000_000))
        try f.write("oversize.bin", Data(repeating: 66, count: 1_000_001))
        #expect(f.load().files["exact.bin"]?.count == 1_000_000)
        #expect(f.load().files["oversize.bin"] == nil)
        for index in 0..<25 { try f.write(String(format: "file%02d.txt", index)) }
        let loaded = f.load().files
        #expect(loaded.count <= 20)
        #expect(!loaded.isEmpty)
        #expect(loaded.values.allSatisfy { $0.count <= 1_000_000 })
    }

    @Test func servicesKeepFileOrderAndStopAtOtherTopLevelSections() {
        let compose = """
        volumes:
          before:
        services:
          z-cache:
            image: redis
            environment:
              nested:
          a-worker:
            image: worker
        volumes:
          cache-data:
        networks:
          private-net:
        """
        #expect(RunnerExtras(files: ["docker-compose.extra.yml": Data(compose.utf8)]).services == ["z-cache", "a-worker"])
        #expect(RunnerExtras.none.services.isEmpty)
        #expect(RunnerExtras(files: ["other.yml": Data(compose.utf8)]).services.isEmpty)
    }

    @Test func reportDetectsMissingAndDifferentExtrasAndUsesVendoredHashOnCollision() async throws {
        let f = try ExtrasFixture(); defer { f.remove() }
        let data = Data("local cache config".utf8)
        let extras = RunnerExtras(files: ["cache.conf": data, "entrypoint.sh": Data("replacement".utf8)])
        let stack = try f.hashes()
        for state in ["missing", "different", "identical"] {
            var remote = stack
            if state != "missing" { remote["cache.conf"] = state == "identical" ? data : Data("old".utf8) }
            let shell = extrasShell(remote: remote)
            let deployer = RunnerStackDeployer(shell: shell, stack: f.stack, home: "/home/fixture", tokens: [:], extras: extras)
            let report = try await deployer.report()
            #expect(report.changedFiles == (state == "identical" ? [] : ["cache.conf"]))
            #expect(report.isNoOp == (state == "identical"))
            #expect(shell.calls.allSatisfy { $0.directory == nil && $0.input == nil && !$0.script.contains("docker compose") })
        }
        var remote = stack
        remote["entrypoint.sh"] = extras.files["entrypoint.sh"]
        remote["cache.conf"] = data
        let shell = extrasShell(remote: remote)
        let report = try await RunnerStackDeployer(shell: shell, stack: f.stack, home: "/home/fixture", tokens: [:], extras: extras).report()
        #expect(report.changedFiles == ["entrypoint.sh"])
    }

    @Test(arguments: [false, true])
    func deployRestoresEveryExtraAfterSyncBeforeComposeAndKeepsPATOutOfFiles(generated: Bool) async throws {
        let f = try ExtrasFixture(); defer { f.remove() }
        let base = generated ? "services:\n" : "services:\n  runner-ledger:\n    environment:\n      RUNNER_SCOPE: repo\n      RUNNER_TARGET: acme/ledger\n"
        try Data(base.utf8).write(to: f.stack.appendingPathComponent("docker-compose.yml"))
        let compose = Data("services:\n  cache:\n    image: redis\n  runner-ledger:\n    restart: always\n  worker:\n    image: worker\n".utf8)
        let extras = RunnerExtras(files: ["docker-compose.extra.yml": compose, "cache.conf": Data("cache=yes\n".utf8),
                                          "entrypoint.sh": Data("must not replace".utf8)])
        var remote = try f.hashes()
        remote["docker-compose.extra.yml"] = compose
        remote["cache.conf"] = Data("old".utf8)
        let shell = extrasShell(remote: remote)
        let token = "github_pat_extrasFixture123"
        _ = try await RunnerStackDeployer(shell: shell, stack: f.stack, home: "/home/fixture",
            tokens: ["acme/ledger": token], requiredTargets: ["acme/ledger"], host: "fixture-box", extras: extras).deploy()
        let calls = shell.calls
        let sync = try #require(calls.firstIndex { $0.directory != nil })
        #expect(calls.filter { $0.directory != nil }.count == 1)
        #expect(calls[sync].directory == f.stack)
        #expect(calls[sync].remote == "/home/fixture/infra/gh-runners")
        let build = try #require(calls.firstIndex { $0.script.contains("docker compose build") })
        for name in ["docker-compose.extra.yml", "cache.conf"] {
            let writes = calls.indices.filter { calls[$0].script.contains("cat >") && calls[$0].script.contains("\"$d/\(name)\"") }
            #expect(writes.count == 1)
            let index = try #require(writes.first)
            #expect(sync < index && index < build)
            #expect(calls[index].input == extras.files[name])
        }
        #expect(!calls.contains { $0.script.contains("cat >") && $0.script.contains("$d/entrypoint.sh") })
        let commands = calls.filter { $0.script.contains("docker compose") }
        #expect(commands.count == 2)
        let files = "COMPOSE_FILE=docker-compose.yml:" + (generated ? "docker-compose.rmj.yml:" : "") + "docker-compose.extra.yml "
        for call in commands {
            #expect(call.script.contains(files))
            #expect(call.input == Data("GH_PAT_ACME=\(token)\n".utf8))
        }
        let up = try #require(commands.first { $0.script.contains("docker compose up -d") })
        #expect(up.script.hasSuffix("docker compose up -d --remove-orphans 'runner-ledger' 'cache' 'worker' 2>&1"))
        for call in calls {
            #expect(!call.script.contains(token))
            if call.script.contains("cat >") {
                #expect(!(String(decoding: call.input ?? Data(), as: UTF8.self).contains(token)))
            }
        }
    }

    @Test func noExtrasPreservesOriginalComposeCommands() async throws {
        let f = try ExtrasFixture(); defer { f.remove() }
        let shell = extrasShell(remote: [:])
        _ = try await RunnerStackDeployer(shell: shell, stack: f.stack, home: "/home/fixture", tokens: [:], extras: RunnerExtras.none).deploy()
        #expect(shell.calls.filter { $0.script.contains("docker compose") }.map(\.script) == [
            "cd '/home/fixture/infra/gh-runners' && docker compose build 2>&1",
            "cd '/home/fixture/infra/gh-runners' && docker compose up -d --remove-orphans 2>&1"
        ])
        #expect(!shell.calls.contains { $0.script.contains("cat >") })
    }
}
