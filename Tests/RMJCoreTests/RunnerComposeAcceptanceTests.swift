import Testing
import Foundation
import CryptoKit
import RMJCore

private let composeBundle = try! String(contentsOf: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Support/runner-stack/docker-compose.yml"), encoding: .utf8)

private func composeSHA(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct RunnerComposeAcceptanceTests {
    @Test func repoAndOrgGenerateServicesFromEmptyBundledCompose() {
        let result = RunnerCompose(base: composeBundle,
            targets: ["acme/ledger", "org:Acme"], host: "fixture-box")
        #expect(result.services == ["runner-ledger", "runner-acme"])
        #expect(result.generated != nil)
        let folded = RunnerCompose(base: composeBundle,
            targets: ["ACME/LEDGER", "org:acme"], host: "fixture-box")
        #expect(folded.services == result.services)
        #expect(folded.generated != nil)
    }

    @Test func newRepoGeneratesServiceWithOwnerPATLabelsAndBundledImageVersion() throws {
        for version in ["2.338.2", "9.123.4"] {
            let base = composeBundle.replacingOccurrences(of: "2.338.2", with: version)
            let result = RunnerCompose(base: base, targets: ["acme/newapp"], host: "next-box")
            #expect(result.services == ["runner-newapp"])
            let generated = try #require(result.generated)
            for field in ["  runner-newapp:", "RUNNER_TARGET: acme/newapp", "RUNNER_SCOPE: repo",
                          "GH_PAT: ${GH_PAT_ACME:-}", "RUNNER_LABELS_BASE: self-hosted,linux,x64,next-box",
                          "image: gh-runner:\(version)"] {
                #expect(generated.contains(field))
            }
        }
    }

    @Test func newOrgGeneratesOrgScopeTargetAndPAT() throws {
        let result = RunnerCompose(base: composeBundle, targets: ["org:Acme"], host: "fixture-box")
        #expect(result.services == ["runner-acme"])
        let generated = try #require(result.generated)
        #expect(generated.contains("RUNNER_SCOPE: org"))
        #expect(generated.contains("RUNNER_TARGET: Acme\n"))
        #expect(generated.contains("GH_PAT: ${GH_PAT_ACME:-}"))
    }

    @Test func sameRepoNameFromDifferentOwnersGetsDistinctServicesInTargetOrder() throws {
        let result = RunnerCompose(base: composeBundle, targets: ["alice/app", "bob/app"], host: "fixture-box")
        #expect(result.services == ["runner-app", "runner-bob-app"])
        let generated = try #require(result.generated)
        #expect(generated.contains("  runner-app:"))
        #expect(generated.contains("  runner-bob-app:"))
        #expect(generated.contains("RUNNER_TARGET: alice/app"))
        #expect(generated.contains("RUNNER_TARGET: bob/app"))
    }

    @Test func serviceNamesContainOnlyLowercaseASCIILettersDigitsAndHyphens() {
        let result = RunnerCompose(base: composeBundle,
            targets: ["Owner.Name/My_App.v2", "Other/My_App.v2", "org:ACME_Inc"], host: "fixture-box")
        #expect(result.services.count == 3)
        #expect(Set(result.services).count == 3)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for service in result.services {
            #expect(service.hasPrefix("runner-"))
            #expect(service.allSatisfy { allowed.contains($0) })
        }
    }

    @Test func deployWritesGeneratedComposeAndStartsOnlyConfiguredServicesThenIsNoOp() async throws {
        let stack = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-compose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stack) }
        try Data(composeBundle.utf8).write(to: stack.appendingPathComponent("docker-compose.yml"))
        try Data().write(to: stack.appendingPathComponent("entrypoint.sh"))
        let targets = ["acme/ledger", "acme/newapp"]
        let generated = try #require(RunnerCompose(base: composeBundle, targets: targets, host: "next-box").generated)
        let manifest = "\(composeSHA(Data(composeBundle.utf8)))  docker-compose.yml\n"
            + "\(composeSHA(Data()))  entrypoint.sh\n"
        let envHash = composeSHA(Data("GH_PAT_ACME=fixture_token\n".utf8))
        let generatedHash = composeSHA(Data(generated.utf8))
        for current in [false, true] {
            let shell = FakeShell { script, _ in
                if script.contains("sha256sum"), script.contains("| cut ") {
                    if script.contains("/docker-compose.rmj.yml'") {
                        return u6Output(current ? generatedHash : "__absent__")
                    }
                    if script.contains("/.rmj-services'") {
                        return u6Output(current ? composeSHA(Data("runner-ledger\nrunner-newapp\n".utf8)) : "__absent__")
                    }
                    #expect(script.contains("/.env'"))
                    return u6Output(envHash)
                }
                if script.contains("sha256sum") { return u6Output(manifest) }
                if script.contains("cat >") || script.contains("docker compose") || script.contains("docker ps -a") {
                    return u6Output()
                }
                Issue.record("Unexpected fake command: \(script)")
                return u6Output()
            }
            let deployer = RunnerStackDeployer(shell: shell, stack: stack, home: "/home/fixture",
                tokens: ["acme/ledger": "fixture_token", "acme/newapp": "fixture_token"],
                requiredTargets: targets, host: "next-box")
            let report = try await deployer.deploy()
            #expect(report.changedFiles.isEmpty && !report.envChanged)
            #expect(report.composeChanged == !current)
            #expect(report.isNoOp == current)
            #expect(shell.calls.allSatisfy { $0.directory == nil })
            let writes = shell.calls.filter { $0.input != nil }
            let commands = shell.calls.filter { $0.script.contains("docker compose") }.map(\.script)
            if current {
                #expect(writes.isEmpty && commands.isEmpty && report.performed.isEmpty)
            } else {
                #expect(writes.count == 2)
                let write = try #require(writes.first)
                #expect(write.input == Data(generated.utf8))
                for fragment in ["umask 077", "mktemp", "$d/docker-compose.rmj.yml.XXXXXX", "cat >",
                                 "chmod 600", "mv", "\"$d/docker-compose.rmj.yml\""] {
                    #expect(write.script.contains(fragment))
                }
                let servicesWrite = try #require(writes.last)
                #expect(servicesWrite.input == Data("runner-ledger\nrunner-newapp\n".utf8))
                #expect(servicesWrite.script.contains("mktemp \"$d/.rmj-services.XXXXXX\""))
                #expect(servicesWrite.script.contains("mv \"$t\" \"$d/.rmj-services\""))
                let prefix = "cd '/home/fixture/infra/gh-runners' && COMPOSE_FILE=docker-compose.yml:docker-compose.rmj.yml docker compose "
                #expect(commands == [
                    prefix + "build 'runner-ledger' 'runner-newapp' 2>&1",
                    prefix + "up -d --remove-orphans 'runner-ledger' 'runner-newapp' 2>&1"
                ])
                #expect(report.performed == ["wrote docker-compose.rmj.yml", "docker compose build", "docker compose up -d"])
                let writeIndex = try #require(shell.calls.firstIndex { $0.input != nil })
                let buildIndex = try #require(shell.calls.firstIndex { $0.script.contains("docker compose build") })
                #expect(writeIndex < buildIndex)
            }
        }
    }

    @Test func switchingBundledTargetsWithSameOwnerPATReconcilesServices() async throws {
        let base = "services:\n  runner-ledger:\n    environment:\n      RUNNER_SCOPE: repo\n      RUNNER_TARGET: acme/ledger\n  runner-next:\n    environment:\n      RUNNER_SCOPE: repo\n      RUNNER_TARGET: acme/next\n"
        let stack = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stack) }
        try Data(base.utf8).write(to: stack.appendingPathComponent("docker-compose.yml"))
        try Data().write(to: stack.appendingPathComponent("entrypoint.sh"))
        let manifest = "\(composeSHA(Data(base.utf8)))  docker-compose.yml\n"
            + "\(composeSHA(Data()))  entrypoint.sh\n"
        let shell = FakeShell { script, _ in
            if script.contains("sha256sum"), script.contains("| cut ") {
                if script.contains("/.env'") {
                    return u6Output(composeSHA(Data("GH_PAT_ACME=fixture_token\n".utf8)))
                }
                #expect(script.contains("/.rmj-services'"))
                return u6Output(composeSHA(Data("runner-ledger\n".utf8)))
            }
            if script.contains("sha256sum") { return u6Output(manifest) }
            if script.contains("cat >") || script.contains("docker compose") || script.contains("docker ps -a") {
                return u6Output()
            }
            Issue.record("Unexpected fake command: \(script)")
            return u6Output()
        }
        let previous = RunnerStackDeployer(shell: shell, stack: stack, home: "/home/fixture",
            tokens: ["acme/ledger": "fixture_token"], requiredTargets: ["acme/ledger"])
        #expect(try await previous.report().isNoOp)
        let deployer = RunnerStackDeployer(shell: shell, stack: stack, home: "/home/fixture",
            tokens: ["acme/next": "fixture_token"], requiredTargets: ["acme/next"])
        let report = try await deployer.deploy()
        #expect(report.changedFiles.isEmpty && !report.envChanged)
        #expect(report.composeChanged && !report.isNoOp)
        #expect(shell.calls.allSatisfy { $0.directory == nil })
        let writes = shell.calls.filter { $0.input != nil }
        #expect(writes.count == 1)
        let write = try #require(writes.first)
        #expect(write.input == Data("runner-next\n".utf8))
        for fragment in ["umask 077", "mktemp \"$d/.rmj-services.XXXXXX\"", "cat > \"$t\"",
                         "chmod 600 \"$t\"", "mv \"$t\" \"$d/.rmj-services\""] {
            #expect(write.script.contains(fragment))
        }
        let prefix = "cd '/home/fixture/infra/gh-runners' && docker compose "
        #expect(shell.calls.filter { $0.script.contains("docker compose") }.map(\.script) == [
            prefix + "build 'runner-next' 2>&1",
            prefix + "up -d --remove-orphans 'runner-next' 2>&1",
            prefix + "rm -sf 'runner-ledger' 2>&1"
        ])
        #expect(report.performed == ["docker compose build", "docker compose up -d", "docker compose rm"])
    }

    @Test func invalidTargetNeverAppearsInGeneratedFile() throws {
        let invalid = "a/b\n  LEAK: x"
        let result = RunnerCompose(base: composeBundle,
            targets: ["acme/newapp", invalid], host: "fixture-box")
        let generated = try #require(result.generated)
        #expect(result.services == ["runner-newapp"])
        #expect(generated.contains("RUNNER_TARGET: acme/newapp\n"))
        #expect(!generated.contains(invalid))
        #expect(!generated.contains("LEAK"))
        #expect(!generated.contains("RUNNER_TARGET: a/b"))
        let rejected = RunnerCompose(base: composeBundle, targets: [invalid], host: "fixture-box")
        #expect(rejected.generated == nil && rejected.services.isEmpty)
    }

}
