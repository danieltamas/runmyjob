import Testing
import Foundation
import CryptoKit
import RMJCore

private func credentialSHA(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct CredentialStack {
    let root: URL
    let base = """
    services:
      runner-active:
        environment:
          RUNNER_SCOPE: repo
          RUNNER_TARGET: acme/active
      runner-unused:
        environment:
          RUNNER_SCOPE: repo
          RUNNER_TARGET: acme/unused
    """
    let tokens = ["zebra/repo": "github_pat_zebra", "acme/active": "github_pat_acme"]
    let env = Data("GH_PAT_ACME=github_pat_acme\nGH_PAT_ZEBRA=github_pat_zebra\n".utf8)
    var targets: [String] { tokens.keys.sorted() }
    var compose: RunnerCompose { RunnerCompose(base: base, targets: targets, host: "fixture") }
    var fingerprint: Data { Data((credentialSHA(env) + "\n").utf8) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(base.utf8).write(to: root.appendingPathComponent("docker-compose.yml"))
        try Data().write(to: root.appendingPathComponent("entrypoint.sh"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }

    func shell(current: Bool = true, legacy: Bool = false, upFails: Bool = false,
               unreadable: String? = nil) -> FakeShell {
        let files = "\(credentialSHA(Data(base.utf8)))  docker-compose.yml\n\(credentialSHA(Data()))  entrypoint.sh\n"
        let hashes = [".rmj-credentials": credentialSHA(fingerprint),
                      ".rmj-services": credentialSHA(Data(compose.manifest.utf8)),
                      "docker-compose.rmj.yml": credentialSHA(Data((compose.generated ?? "").utf8))]
        return FakeShell { script, _ in
            if let unreadable, script.contains("/\(unreadable)'"), !script.contains("cat >") {
                return u6Output("", status: 7, stderr: "Permission denied")
            }
            if script.contains("/.env'"), !script.contains("rm -f") {
                return u6Output(legacy ? credentialSHA(Data("OLD_PAT=old_secret\n".utf8)) : "__absent__")
            }
            for (name, hash) in hashes where script.contains("/\(name)'" ) && !script.contains("cat >") {
                return u6Output(name == ".rmj-credentials" && !current ? "__absent__" : hash)
            }
            if script.contains("sha256sum") { return u6Output(files) }
            if script.contains("docker ps -a") {
                return u6Output("runner-active\tabc123abc123\tgh-runner:1\trunning\tUp 1 hour\n")
            }
            if upFails && script.contains("docker compose up -d") {
                return u6Output("github_pat_acme", status: 1, stderr: "github_pat_zebra")
            }
            return u6Output()
        }
    }
    func deployer(_ shell: FakeShell, tokens: [String: String]? = nil,
                  registrations: (@Sendable () async throws -> [GitHubRunner])? = nil,
                  notice: @escaping @Sendable (String) -> Void = { _ in }) -> RunnerStackDeployer {
        RunnerStackDeployer(shell: shell, stack: root, home: "/home/fixture", tokens: tokens ?? self.tokens,
            requiredTargets: targets, host: "fixture", registrations: registrations, notice: notice)
    }
}

struct RunnerCredentialsAcceptanceTests {
    @Test func currentStackAndCredentialsDeployWithoutMutation() async throws {
        let f = try CredentialStack(); defer { f.remove() }
        let shell = f.shell()
        let report = try await f.deployer(shell).deploy()
        #expect(report.isNoOp && !report.credentialsChanged && !report.legacyEnv)
        #expect(report.performed.isEmpty)
        #expect(shell.calls.allSatisfy {
            $0.input == nil && $0.directory == nil && !$0.script.contains("docker compose")
                && !$0.script.contains("cat >") && !$0.script.contains("rm -f")
        })
    }

    @Test func reportComparesFingerprintOnlyWithTokensAndIncludesLegacyEnv() async throws {
        let f = try CredentialStack(); defer { f.remove() }
        for current in [false, true] {
            for legacy in [false, true] {
                let shell = f.shell(current: current, legacy: legacy)
                let report = try await f.deployer(shell).report()
                #expect(report.credentialsChanged == !current)
                #expect(report.legacyEnv == legacy)
                #expect(report.changedFiles.isEmpty && !report.composeChanged)
                #expect(report.isNoOp == (current && !legacy))
                #expect(report.performed.isEmpty)
                #expect(shell.calls.allSatisfy { $0.input == nil && $0.directory == nil })
            }
        }
        let empty = f.shell(current: false, legacy: true)
        #expect(try await f.deployer(empty, tokens: [:]).report().credentialsChanged == false)
        #expect(try await f.deployer(empty, tokens: [:]).report().legacyEnv)
        #expect(!empty.calls.contains { $0.script.contains("/.rmj-credentials'") })
        for name in [".env", ".rmj-credentials"] {
            await #expect(throws: RunnerStackDeployer.Failure.self) {
                _ = try await f.deployer(f.shell(unreadable: name)).report()
            }
        }
    }

    @Test func rotationUsesOnlyComposeStdinAndCommitsAtomicFingerprintAfterUp() async throws {
        let f = try CredentialStack(); defer { f.remove() }
        var rotated = f.tokens
        rotated["acme/active"] = "github_pat_rotated"
        let env = Data("GH_PAT_ACME=github_pat_rotated\nGH_PAT_ZEBRA=github_pat_zebra\n".utf8)
        let shell = f.shell()
        #expect(try await f.deployer(shell, tokens: rotated).report().credentialsChanged)
        let notices = U6Messages()
        let report = try await f.deployer(shell, tokens: rotated, notice: { notices.append($0) }).deploy()
        #expect(report.credentialsChanged && report.changedFiles.isEmpty && !report.composeChanged)
        #expect(shell.calls.allSatisfy { $0.directory == nil })
        let compose = shell.calls.filter { $0.script.contains("docker compose") }
        #expect(compose.count == 3)
        for step in ["docker compose build", "docker compose up -d", "docker compose rm -sf"] {
            let call = try #require(compose.first { $0.script.contains(step) })
            #expect(call.input == env)
            #expect(call.script.hasPrefix("cd '/home/fixture/infra/gh-runners' &&"))
            let read = try #require(call.script.range(of: "read -r"))
            let docker = try #require(call.script.range(of: step))
            #expect(read.lowerBound < docker.lowerBound)
            #expect(call.script.contains("while ") && call.script.contains("export "))
            #expect(!call.script.contains("--force-recreate"))
        }
        let up = try #require(shell.calls.firstIndex { $0.script.contains("docker compose up -d") })
        let writes = shell.calls.enumerated().filter { $0.element.script.contains("cat >") && $0.element.script.contains(".rmj-credentials") }
        #expect(writes.count == 1)
        let write = try #require(writes.first)
        #expect(write.offset > up)
        #expect(write.element.input == Data((credentialSHA(env) + "\n").utf8))
        for fragment in ["umask 077", "mktemp", "$d/.rmj-credentials.XXXXXX", "chmod 600", "mv"] {
            #expect(write.element.script.contains(fragment))
        }
        for call in shell.calls {
            #expect(!(call.script.contains("cat >") && call.script.contains("$d/.env")))
            for token in rotated.values {
                #expect(!call.script.contains(token))
                if call.input?.range(of: Data(token.utf8)) != nil { #expect(call.script.contains("docker compose")) }
            }
        }
        #expect(!report.performed.contains("wrote .env"))
        #expect(!report.performed.contains { $0.contains(".rmj-credentials") })
        for token in rotated.values {
            #expect(report.performed.allSatisfy { !$0.contains(token) })
            #expect(notices.values.allSatisfy { !$0.contains(token) })
        }
    }

    @Test func busyRunnerRefusesRotationBeforeAnyMutation() async throws {
        let f = try CredentialStack(); defer { f.remove() }
        let shell = f.shell(current: false)
        await #expect(throws: RunnerStackDeployer.Failure.busy(["runner-active"])) {
            _ = try await f.deployer(shell, registrations: {
                [GitHubRunner(id: 1, name: "abc123abc123-1790000000", online: true, busy: true, labels: [])]
            }).deploy()
        }
        #expect(shell.calls.allSatisfy { $0.input == nil && $0.directory == nil && !$0.script.contains("rm -f") })
    }

    @Test func legacyEnvAloneIsRemovedOnlyAfterSuccessfulUpAndReportedLast() async throws {
        let f = try CredentialStack(); defer { f.remove() }
        let shell = f.shell(legacy: true)
        let report = try await f.deployer(shell).deploy()
        #expect(!report.isNoOp && report.legacyEnv && !report.credentialsChanged)
        #expect(report.changedFiles.isEmpty && !report.composeChanged)
        #expect(shell.calls.allSatisfy { $0.directory == nil })
        let up = try #require(shell.calls.firstIndex { $0.script.contains("docker compose up -d") })
        let removal = try #require(shell.calls.firstIndex { $0.script.contains("rm -f") && $0.script.contains("/home/fixture/infra/gh-runners/.env") })
        #expect(removal > up)
        #expect(report.performed.last == "removed .env")
        #expect(!report.performed.contains("wrote .env"))
        #expect(!shell.calls.contains { $0.script.contains("cat >") && $0.script.contains("docker-compose.rmj.yml") })
    }

    @Test func failedUpLeavesLegacyAndFingerprintUntouchedAndScrubsOutput() async throws {
        let f = try CredentialStack(); defer { f.remove() }
        let shell = f.shell(current: false, legacy: true, upFails: true)
        let notices = U6Messages()
        do {
            _ = try await f.deployer(shell, notice: { notices.append($0) }).deploy()
            Issue.record("Failed up was accepted")
        } catch let error as RunnerStackDeployer.Failure {
            guard case .remote = error else { Issue.record("Expected remote failure"); return }
            for token in f.tokens.values { #expect(!error.description.contains(token)) }
        }
        #expect(shell.calls.contains { $0.script.contains("docker compose up -d") })
        #expect(!shell.calls.contains { $0.script.contains("rm -f") && $0.script.contains("/.env") })
        #expect(!shell.calls.contains { $0.script.contains("cat >") && $0.script.contains(".rmj-credentials") })
        #expect(try await f.deployer(shell).report().credentialsChanged)
        #expect(!notices.values.isEmpty)
        for token in f.tokens.values { #expect(notices.values.allSatisfy { !$0.contains(token) }) }
    }

    @Test func generatedComposeRequiresCredentialsAndVendoredStackHasNoEnvFiles() throws {
        let f = try CredentialStack(); defer { f.remove() }
        let generated = try #require(f.compose.generated)
        #expect(generated.contains("GH_PAT: ${GH_PAT_ZEBRA:?run through rmj}"))
        #expect(!generated.contains(":-}"))
        let stack = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Support/runner-stack")
        let walker = try #require(FileManager.default.enumerator(at: stack, includingPropertiesForKeys: nil))
        for case let url as URL in walker {
            #expect(url.lastPathComponent != ".env" && url.lastPathComponent != ".env.example")
        }
    }
}
