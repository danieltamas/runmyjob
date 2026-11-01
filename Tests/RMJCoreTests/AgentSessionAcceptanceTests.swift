import CryptoKit
import Foundation
import Testing
@testable import RMJCore

struct AgentSessionAcceptanceTests {
    private let id = "12345678-abcd-4abc-8def-123456789abc"

    @Test func modelsParseForBothHarnessesAndEnforceTheWholeGrammar() throws {
        let accepted = ["claude-opus-4-5", "opus[1m]", "gpt-5.1-codex", "A", "0._:[]-",
                        String(repeating: "a", count: 64)]
        let rejected = ["", "-opus", "has space", "a;b", "$(x)", "a\nb", "a\n",
                        String(repeating: "a", count: 65), "_opus", ".opus", "opus/1"]
        for harness in ["claude", "codex"] {
            for model in accepted {
                let options = try AgentRunCommand.parse(["--harness", harness, "--model", model, "--", "p"])
                #expect(options.model == model)
                #expect(options.session == nil)
            }
            for model in rejected {
                #expect(throws: AgentRunCommand.Failure.usage) {
                    try AgentRunCommand.parse(["--harness", harness, "--model", model, "--", "p"])
                }
            }
            for suffix in [["--model"], ["--model", "--", "p"]] {
                #expect(throws: AgentRunCommand.Failure.usage) {
                    try AgentRunCommand.parse(["--harness", harness] + suffix)
                }
            }
        }
    }

    @Test func sessionFlagsNormalizeUUIDsAndSelectResume() throws {
        for flag in ["--session-id", "--resume"] {
            for value in [id, id.uppercased(), "12345678-AbCd-4aBc-8dEf-123456789aBc"] {
                for harness in [[], ["--harness", "claude"]] {
                    let options = try AgentRunCommand.parse(harness + [flag, value, "--model", "opus[1m]", "--", "p"])
                    #expect(options.session?.id == id)
                    #expect(options.session?.resume == (flag == "--resume"))
                    #expect(options.model == "opus[1m]")
                }
            }
        }
    }

    @Test func invalidMissingExclusiveAndCodexSessionsAreUsageErrors() {
        for flag in ["--session-id", "--resume"] {
            for value in ["", "not-a-uuid", "12345678-abcd-4abc-8def-123456789abg"] {
                #expect(throws: AgentRunCommand.Failure.usage) {
                    try AgentRunCommand.parse([flag, value, "--", "p"])
                }
            }
            for arguments in [[flag], [flag, "--", "p"],
                              ["--harness", "codex", flag, id, "--", "p"],
                              [flag, id, "--harness", "codex", "--", "p"]] {
                #expect(throws: AgentRunCommand.Failure.usage) { try AgentRunCommand.parse(arguments) }
            }
        }
        for flags in [["--session-id", id, "--resume", id], ["--resume", id, "--session-id", id]] {
            #expect(throws: AgentRunCommand.Failure.usage) { try AgentRunCommand.parse(flags + ["--", "p"]) }
        }
    }

    @Test func absentNewFlagsPreserveExistingOptionsAndTaskDefaults() throws {
        for harness in AgentHarness.allCases {
            let arguments = ["--harness", harness.program, "--to", "ai-eu-1", "--timeout", "90s",
                             "--unattended", "--require-box"]
                + (harness == .claude ? ["--allow", "Read,Edit"] : []) + ["--", "literal $(x)"]
            let options = try AgentRunCommand.parse(arguments)
            #expect(options.model == nil && options.session == nil)
            #expect(options.harness == harness && options.destination == "ai-eu-1")
            #expect(options.timeoutSeconds == 90 && options.unattended && options.requireBox)
            #expect(options.allowedTools == (harness == .claude ? ["Read", "Edit"] : []))
            #expect(options.prompt == "literal $(x)")
            let task = AgentTask(harness: harness, prompt: "p")
            #expect(task.model == nil && task.session == nil)
        }
        let defaults = try AgentRunCommand.parse(["--", "p"])
        #expect(defaults.model == nil && defaults.session == nil)
        #expect(defaults.harness == .claude && defaults.destination == nil)
        #expect(defaults.timeoutSeconds == 3600 && !defaults.unattended && !defaults.requireBox)
        #expect(defaults.allowedTools.isEmpty && defaults.prompt == "p")
    }

    @Test func claudeVectorsKeepModelSessionAndToolsInExactOrder() {
        for prompt in ["literal prompt", "--model x", "-p"] {
            for model in [nil, "opus[1m]"] as [String?] {
                for resume in [nil, false, true] as [Bool?] {
                    for unattended in [false, true] {
                        for tools in [[], ["Read", "Bash(git log:*)"]] {
                            let session = resume.map { AgentTask.Session(id: id, resume: $0) }
                            let task = AgentTask(prompt: prompt, unattended: unattended, allowedTools: tools,
                                                 timeoutSeconds: 90, model: model, session: session)
                            let modelArgs = model.map { ["--model", $0] } ?? []
                            let sessionArgs = resume.map { [$0 ? "--resume" : "--session-id", id] } ?? []
                            let toolArgs = tools.isEmpty ? [] : ["--allowedTools"] + tools
                            #expect(task.argv(onBox: false) == ["claude", "-p", prompt] + modelArgs + sessionArgs + toolArgs)
                            #expect(task.argv(onBox: true) == ["timeout", "--signal=TERM", "--kill-after=30", "90",
                                "claude", "-p", prompt, "--output-format", "stream-json", "--verbose", "--permission-mode",
                                unattended ? "bypassPermissions" : "acceptEdits"] + modelArgs + sessionArgs + toolArgs)
                        }
                    }
                }
            }
        }
    }

    @Test func codexVectorsPutModelImmediatelyAfterExecAndKeepPromptLiteral() {
        for prompt in ["literal prompt", "--model x", "-p"] {
            for model in [nil, "gpt-5.1-codex"] as [String?] {
                for unattended in [false, true] {
                    let task = AgentTask(harness: .codex, prompt: prompt, unattended: unattended,
                                         timeoutSeconds: 90, model: model)
                    let modelArgs = model.map { ["-m", $0] } ?? []
                    #expect(task.argv(onBox: false) == ["codex", "exec"] + modelArgs + [prompt])
                    #expect(task.argv(onBox: true) == ["timeout", "--signal=TERM", "--kill-after=30", "90", "codex", "exec"]
                        + modelArgs + ["--skip-git-repo-check", "--ephemeral", "--dangerously-bypass-approvals-and-sandbox", prompt])
                }
            }
        }
    }

    @Test func sessionDirectoriesHashCanonicalRepoOrLiteralWorktreeWithoutPathInjection() {
        let home = "/home/box", worktree = "/Users/owner/Project"
        let prefix = home + "/rx/.sessions/"
        for repo in [nil, "acme/axon", "Acme/Axon", "acme/other", "../..", "repo with spaces", "a;b"] as [String?] {
            let path = AgentSession.sessionDirectory(home: home, repo: repo, worktree: worktree)
            let input = repo?.lowercased() ?? worktree
            let hash = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(path == prefix + hash.prefix(16))
            #expect(path.hasPrefix(prefix))
            let key = String(path.dropFirst(prefix.count))
            #expect(key.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil)
        }
        let original = AgentSession.sessionDirectory(home: home, repo: "acme/axon", worktree: worktree)
        #expect(original == AgentSession.sessionDirectory(home: home, repo: "Acme/Axon", worktree: "/another/worktree"))
        #expect(original != AgentSession.sessionDirectory(home: home, repo: "acme/other", worktree: worktree))
        #expect(AgentSession.sessionDirectory(home: home, repo: nil, worktree: worktree)
            != AgentSession.sessionDirectory(home: home, repo: nil, worktree: worktree.lowercased()))
    }

    @Test func decorateAddsOnlyTheClaudeProjectsVolumeAndPreservesLoginPreludeAndEgress() async throws {
        let home = "/home/box"
        for harness in AgentHarness.allCases {
            let source = AgentCredentialsFake(raw: try (harness == .claude ? agentCredentialJSON() : codexCredentialJSON()),
                                              trace: AgentBoxFake())
            let task = AgentTask(harness: harness, prompt: "p", timeoutSeconds: 90)
            let baseline = try await AgentSession.prepare(task, source: source, now: runNow).get()
            let job = BoxJob(ulid: "01SESSIONTEST00000000000000", name: "session-test", worktree: "/Mac/repo",
                             directory: home + "/rx/work", argv: task.argv(onBox: true),
                             options: ["--cpus", "2", "-v", "keep:/kept", "--network", "old", "--entrypoint", "/work/.rmj/exec"],
                             image: harness.image, locks: ["checkout.lock"])
            let plain = baseline.decorate(job, home: home, slots: 3, repo: "acme/axon")
            #expect(!plain.options.joined(separator: " ").contains(".sessions"))
            #expect(plain.prelude?.path == home + "/rx/.prelude/agent-" + harness.program + ".sh")
            let login = harness == .claude ? "$HOME/.claude/.credentials.json" : "$HOME/.codex/auth.json"
            #expect(plain.prelude?.content == "mkdir -p \"$(dirname \"\(login)\")\" && mv /run/rmj/credentials.json \"\(login)\" && chmod 600 \"\(login)\"")
            #expect(plain.locks == ["slots:3:\(home)/rx/.agent-slot", "checkout.lock"])
            for pair in [["--network", "rmj-agents"], ["-e", "HTTPS_PROXY=http://rmj-egress:3128"],
                         ["-e", "HTTP_PROXY=http://rmj-egress:3128"]] {
                #expect(plain.options.indices.contains { i in
                    i + 1 < plain.options.count && Array(plain.options[i...i + 1]) == pair
                })
            }
            for resume in [false, true] {
                var withSession = task
                withSession.session = AgentTask.Session(id: id, resume: resume)
                let prepared = try await AgentSession.prepare(withSession, source: source, now: runNow).get()
                for repo in [nil, "acme/axon"] as [String?] {
                    let decorated = prepared.decorate(job, home: home, slots: 3, repo: repo)
                    let volume = AgentSession.sessionDirectory(home: home, repo: repo, worktree: job.worktree)
                        + ":/tmp/.claude/projects"
                    let occurrences = decorated.options.indices.filter { i in
                        i + 1 < decorated.options.count && Array(decorated.options[i...i + 1]) == ["-v", volume]
                    }
                    if harness == .claude {
                        #expect(occurrences.count == 1)
                        if let i = occurrences.first {
                            var stripped = decorated.options
                            stripped.removeSubrange(i...i + 1)
                            #expect(stripped == plain.options)
                            #expect(i < (decorated.options.firstIndex(of: "--entrypoint") ?? 0))
                        }
                    } else {
                        #expect(occurrences.isEmpty && decorated.options == plain.options)
                    }
                    #expect(decorated.prelude?.path == plain.prelude?.path)
                    #expect(decorated.prelude?.content == plain.prelude?.content)
                    #expect(decorated.locks == plain.locks)
                }
            }
        }
    }

    @Test func boxScriptContainsPrivateSessionCreationAndFourteenDayPruning() throws {
        let script = BoxAssets.script
        let sessions = try #require(script.range(of: ".sessions/"))
        let launch = try #require(script.range(of: "docker create"))
        #expect(sessions.lowerBound < launch.lowerBound)
        #expect(script.contains("mkdir") && script.contains("700"))
        #expect(script.contains("$HOME/rx/.sessions") || script.contains("${HOME}/rx/.sessions"))
        #expect(script.range(of: #"-mtime\s+\+14"#, options: .regularExpression) != nil)
        let prune = try #require(script.range(of: "prune()"))
        let end = try #require(script.range(of: "\n}", range: prune.upperBound..<script.endIndex))
        let body = script[prune.upperBound..<end.lowerBound]
        #expect(body.contains("find") && body.contains("-mtime +14"))
        #expect(body.contains("sessions"))
    }

    @Test(.enabled(if: sessionScriptToolsAvailable,
                   "Requires bash and flock on PATH; script text assertions run on every host"))
    func realBoxGoCreatesOnlySessionVolumesPrivatelyBeforeDocker() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rmj-session-acceptance-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let script = root.appendingPathComponent("rx-run.sh")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Support/box/rx-run.sh")
        let real = try String(contentsOf: source, encoding: .utf8)
        #expect(real.trimmingCharacters(in: .whitespacesAndNewlines)
            == BoxAssets.script.trimmingCharacters(in: .whitespacesAndNewlines))
        try Data(real.utf8).write(to: script)
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let docker = bin.appendingPathComponent("docker")
        try Data("""
        #!/bin/sh
        if [ -n "$EXPECT_SESSION" ]; then
          [ -d "$EXPECT_SESSION" ] || exit 91
          printf checked > "$HOME/docker-checked"
        else
          printf checked > "$HOME/docker-checked"
        fi
        exit 1
        """.utf8).write(to: docker)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)
        for (index, kind) in ["session", "outside", "etc", "traversal"].enumerated() {
            let home = root.appendingPathComponent("home-\(index)")
            let logs = home.appendingPathComponent("rx/.logs")
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            let sessionPath = home.path + "/rx/.sessions/abc"
            let outside = home.path + "/outside"
            let host = kind == "session" ? sessionPath : kind == "etc" ? "/etc"
                : kind == "traversal" ? home.path + "/rx/.sessions/../../escaped" : outside
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
            env["PATH"] = bin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            env["EXPECT_SESSION"] = kind == "session" ? sessionPath : ""
            env.removeValue(forKey: "BASH_ENV")
            let ulid = "01SESSIONTEST0000000000000\(index)"
            let go = sessionScriptProcess(script, arguments: ["go", ulid, "test", "[]", "--", "-v",
                host + ":" + (kind == "session" ? "/tmp/.claude/projects" : "/x"), "--entrypoint", "/bin/true", "stub"], environment: env)
            let waiter = sessionScriptProcess(script, arguments: ["_waiter", ulid, "/Mac/repo", home.path + "/work"], environment: env)
            try go.run()
            defer { if go.isRunning { go.terminate() } }
            try waiter.run()
            defer { if waiter.isRunning { waiter.terminate() } }
            let deadline = Date().addingTimeInterval(10)
            while (go.isRunning || waiter.isRunning) && Date() < deadline {
                if kind != "session", !go.isRunning, waiter.isRunning,
                   !fm.fileExists(atPath: logs.appendingPathComponent(ulid + ".go").path) {
                    waiter.terminate()
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            try #require(!go.isRunning && !waiter.isRunning, "Stubbed go/waiter must finish within 10 seconds")
            if kind == "session" {
                #expect(fm.fileExists(atPath: home.path + "/docker-checked"))
                let attrs = try fm.attributesOfItem(atPath: sessionPath)
                #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
                #expect((attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
            }
            #expect(!fm.fileExists(atPath: outside))
            #expect(!fm.fileExists(atPath: home.path + "/escaped"))
            if kind != "session" { #expect(!fm.fileExists(atPath: sessionPath)) }
        }
    }
}

private var sessionScriptToolsAvailable: Bool {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    return ["bash", "flock"].allSatisfy { tool in
        path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: String($0) + "/" + tool) }
    }
}

private func sessionScriptProcess(_ script: URL, arguments: [String], environment: [String: String]) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bash", script.path] + arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return process
}
