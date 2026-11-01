import Foundation
import Testing
@testable import RMJCore

struct AgentAttachAcceptanceTests {
    @Test func absentFlagsPreserveOptionsAndTaskDefaults() throws {
        let o = try AgentRunCommand.parse(["--", "p"])
        #expect(o.appendSystemPrompt == nil && o.attachments.isEmpty && !o.json)
        #expect(o.harness == .claude && o.destination == nil && o.timeoutSeconds == 3600)
        #expect(!o.unattended && !o.requireBox && o.allowedTools.isEmpty)
        #expect(o.model == nil && o.session == nil && o.prompt == "p")
        let task = AgentTask(prompt: "p")
        #expect(task.systemPrompt == nil && task.attachments.isEmpty)
        #expect(task.argv(onBox: false) == ["claude", "-p", "p"])
    }

    @Test func promptFileIsReadAtParseTimeAndAcceptsBothByteBoundaries() throws {
        let root = try attachTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("prompt")
        for text in ["x", String(repeating: "x", count: 65536), "-- words 'quoted'\n$(literal)"] {
            try Data(text.utf8).write(to: file)
            let o = try AgentRunCommand.parse(["--append-system-prompt-file", file.path, "--", "p"])
            try Data("replacement".utf8).write(to: file)
            #expect(o.appendSystemPrompt == text)
        }
    }

    @Test func invalidPromptFilesDuplicatesAndCodexAreUsageErrors() throws {
        let root = try attachTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("prompt")
        for data in [Data(), Data(repeating: 97, count: 65537), Data([0xff, 0xfe]),
                     Data(String(repeating: "\u{00e9}", count: 32769).utf8)] {
            try data.write(to: file)
            #expect(throws: AgentRunCommand.Failure.usage) {
                try AgentRunCommand.parse(["--append-system-prompt-file", file.path, "--", "p"])
            }
        }
        try Data("valid".utf8).write(to: file)
        for args in [["--append-system-prompt-file"], ["--append-system-prompt-file", "--", "p"],
                     ["--append-system-prompt-file", root.appendingPathComponent("missing").path, "--", "p"],
                     ["--append-system-prompt-file", root.path, "--", "p"],
                     ["--append-system-prompt-file", file.path, "--append-system-prompt-file", file.path, "--", "p"],
                     ["--harness", "codex", "--append-system-prompt-file", file.path, "--", "p"],
                     ["--append-system-prompt-file", file.path, "--harness", "codex", "--", "p"]] {
            #expect(throws: AgentRunCommand.Failure.usage) { try AgentRunCommand.parse(args) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect(throws: AgentRunCommand.Failure.usage) {
            try AgentRunCommand.parse(["--append-system-prompt-file", file.path, "--", "p"])
        }
    }

    @Test func attachmentsAcceptFourStandardizedDirectoriesForBothHarnesses() throws {
        let root = try attachTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = try ["A-1", "b_2", ".c+3", "d@=4"].map { name in
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        for harness in AgentHarness.allCases {
            let args = paths.flatMap { ["--attach", $0 + "/./"] }
            let o = try AgentRunCommand.parse(["--harness", harness.program, "--json"] + args + ["--", "p"])
            #expect(o.attachments == paths && o.json && o.harness == harness)
        }
    }

    @Test func everyInvalidAttachmentShapeIsAUsageError() throws {
        let fm = FileManager.default
        let root = try attachTemporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("file"); try Data("x".utf8).write(to: file)
        for name in ["has space", "has:colon"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let paths = [".", "relative", "", root.appendingPathComponent("missing").path, file.path,
                     root.path + "/../" + root.lastPathComponent, root.path + "/has space", root.path + "/has:colon", "/"]
        for path in paths {
            #expect(throws: AgentRunCommand.Failure.usage) { try AgentRunCommand.parse(["--attach", path, "--", "p"]) }
        }
        for base in ["work", "tmp", "run", "proc", "sys", "dev", "etc", "usr", "bin", "sbin", "lib", "opt", "root", "home"] {
            for path in ["/" + base, "/" + base + "/x"] {
                #expect(throws: AgentRunCommand.Failure.usage) { try AgentRunCommand.parse(["--attach", path, "--", "p"]) }
            }
        }
        for path in ["/usr/bin", "/dev/fd", "/etc/ssh"] {
            #expect(throws: AgentRunCommand.Failure.usage) { try AgentRunCommand.parse(["--attach", path, "--", "p"]) }
        }
        for args in [["--attach"], ["--attach", "--", "p"],
                     Array(repeating: ["--attach", root.path], count: 5).flatMap { $0 } + ["--", "p"]] {
            #expect(throws: AgentRunCommand.Failure.usage) { try AgentRunCommand.parse(args) }
        }
    }

    @Test func jsonCombinesWithAllOtherFlagsWithoutConsumingThePrompt() throws {
        let root = try attachTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("prompt"); try Data("system".utf8).write(to: file)
        let id = "12345678-abcd-4abc-8def-123456789abc"
        let o = try AgentRunCommand.parse(["--json", "--attach", root.path, "--append-system-prompt-file", file.path,
            "--model", "opus", "--resume", id, "--to", "ai-eu-1", "--timeout", "90s", "--unattended",
            "--require-box", "--allow", "Read,Edit", "--", "--json literal"])
        #expect(o.json && o.attachments == [root.path] && o.appendSystemPrompt == "system")
        #expect(o.model == "opus" && o.session == AgentTask.Session(id: id, resume: true))
        #expect(o.destination == "ai-eu-1" && o.timeoutSeconds == 90 && o.unattended && o.requireBox)
        #expect(o.allowedTools == ["Read", "Edit"] && o.prompt == "--json literal")
    }

    @Test func exactArgvOrdersModelSystemPromptSessionAndToolsLocallyAndOnBox() {
        let id = "12345678-abcd-4abc-8def-123456789abc"
        for model in [nil, "opus"] as [String?] {
            for resume in [false, true] {
                let prompt = "-- task 'quotes' and spaces", system = "-- system \"quoted\"\n$(literal)"
                let task = AgentTask(prompt: prompt, allowedTools: ["Read", "Edit"], timeoutSeconds: 90,
                    model: model, session: .init(id: id, resume: resume), systemPrompt: system, attachments: ["/Users/a"])
                let suffix = (model.map { ["--model", $0] } ?? []) + ["--append-system-prompt", system,
                    resume ? "--resume" : "--session-id", id, "--allowedTools", "Read", "Edit"]
                #expect(task.argv(onBox: false) == ["claude", "-p", prompt] + suffix)
                #expect(task.argv(onBox: true) == ["timeout", "--signal=TERM", "--kill-after=30", "90", "claude",
                    "-p", prompt, "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits"] + suffix)
            }
        }
    }

    @Test func decorateAddsOnlyExactReadOnlyAttachmentMounts() async throws {
        for harness in AgentHarness.allCases {
            let task = AgentTask(harness: harness, prompt: "p")
            let raw = try (harness == .claude ? agentCredentialJSON() : codexCredentialJSON())
            let session = try await AgentSession.prepare(task, source: AgentCredentialsFake(raw: raw, trace: AgentBoxFake()), now: runNow).get()
            let job = BoxJob(ulid: "01ATTACH0000000000000000000", name: "attach", worktree: "/Users/a/repo",
                directory: "/home/box/rx/repo", argv: [], options: ["--cpus", "2", "--entrypoint", "/work/.rmj/exec"], image: harness.image)
            let plain = session.decorate(job, home: "/home/box", slots: 2, repo: "acme/axon")
            let attachments = [AgentSession.Attachment(boxDirectory: "/home/box/rx/.attach/id/0", path: "/Users/a/context"),
                               AgentSession.Attachment(boxDirectory: "/home/box/rx/.attach/id/1", path: "/private/var/context")]
            let decorated = session.decorate(job, home: "/home/box", slots: 2, repo: "acme/axon", attachments: attachments)
            var stripped = decorated.options
            for volume in ["/home/box/rx/.attach/id/0:/Users/a/context:ro", "/home/box/rx/.attach/id/1:/private/var/context:ro"] {
                let i = try #require(stripped.firstIndex(of: volume))
                #expect(i > 0 && stripped[i - 1] == "-v")
                #expect(i < (stripped.firstIndex(of: "--entrypoint") ?? 0))
                stripped.removeSubrange((i - 1)...i)
            }
            #expect(stripped == plain.options)
            #expect(decorated.argv == plain.argv && decorated.locks == plain.locks)
            #expect(decorated.prelude?.content == plain.prelude?.content && decorated.prelude?.path == plain.prelude?.path)
        }
    }

    @Test func systemPromptAloneFollowsPromptOptionsWithoutModelSessionOrTools() {
        let text = "-- system 'quoted words'"
        let task = AgentTask(prompt: "task", timeoutSeconds: 90, systemPrompt: text)
        #expect(task.argv(onBox: false) == ["claude", "-p", "task", "--append-system-prompt", text])
        #expect(task.argv(onBox: true) == [
            "timeout", "--signal=TERM", "--kill-after=30", "90", "claude", "-p", "task",
            "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
            "--append-system-prompt", text
        ])
    }

    @Test func finalTextUsesOnlyLastResultEventIncludingAnUnterminatedTail() {
        let stream = AgentStream(emit: { _ in })
        #expect(stream.finalText == nil)
        for line in [#"{"type":"assistant","message":{"content":[{"type":"text","text":"not final"}]}}"#,
                     #"{"type":"user","message":{"content":[{"type":"tool_result","content":"not final"}]}}"#] {
            stream.add(Data((line + "\n").utf8))
        }
        #expect(stream.finalText == nil)
        stream.add(Data(#"{"type":"result","result":"first"}"#.utf8)); stream.add(Data([10]))
        #expect(stream.finalText == "first")
        stream.add(Data(#"{"type":"result","result":"last\nanswer"}"#.utf8)); stream.flush()
        #expect(stream.finalText == "last\nanswer")
        stream.flush(); #expect(stream.finalText == "last\nanswer")
    }

    @Test func jsonLineHasSortedKeysNullsAndEscapedCleanFinal() throws {
        let nilLine = AgentRunCommand.jsonLine(job: "id", location: "local", branch: nil, exit: 3, final: nil)
        #expect(nilLine == #"{"branch":null,"exit":3,"final":null,"job":"id","location":"local"}"#)
        let line = AgentRunCommand.jsonLine(job: "id", location: "box", branch: "rmj/agent/id", exit: 7,
            final: "line one\n\"quoted\"\n\u{1b}[31mred\u{1b}[0m")
        #expect(!line.contains("\n") && !line.contains("\r") && !line.contains("\u{1b}"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["final"] as? String == "line one\n\"quoted\"\nred")
        #expect(object["branch"] as? String == "rmj/agent/id" && object["exit"] as? Int == 7)
        let positions = try ["branch", "exit", "final", "job", "location"].map { try #require(line.range(of: "\"" + $0 + "\":" )).lowerBound }
        #expect(positions == positions.sorted())
    }

    @Test func jsonFinalIsBoundedByUTF8BytesWithoutBreakingCharacters() throws {
        for text in [String(repeating: "a", count: 65537), String(repeating: "\u{20ac}", count: 21846)] {
            let line = AgentRunCommand.jsonLine(job: "id", location: "local", branch: nil, exit: 0, final: text)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let final = try #require(object["final"] as? String)
            let expected = text.first == "a" ? String(repeating: "a", count: 65536) : String(repeating: "\u{20ac}", count: 21845)
            #expect(final == expected && final.utf8.count <= 65536)
        }
    }

    @Test func streamResultSurvivesEveryByteBoundaryAndLaterAssistantDoesNotReplaceIt() {
        let bytes = Data((#"{"type":"result","result":"answer \u00e9"}"# + "\n" +
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"later assistant"}]}}"# + "\n").utf8)
        for split in 0...bytes.count {
            let stream = AgentStream(emit: { _ in })
            stream.add(Data(bytes.prefix(split)))
            stream.add(Data(bytes.dropFirst(split)))
            stream.flush()
            #expect(stream.finalText == "answer \u{00e9}")
        }
    }

    @Test func emptyResultIsAStringAndErrorResultStillProvidesFinalText() throws {
        for (text, isError) in [("", false), ("failure details", true)] {
            let stream = AgentStream(emit: { _ in })
            var data = try JSONSerialization.data(withJSONObject: ["type": "result", "result": text, "is_error": isError])
            data.append(10)
            stream.add(data)
            #expect(stream.finalText == text)
            let line = AgentRunCommand.jsonLine(job: "id", location: "box", branch: nil, exit: isError ? 1 : 0,
                                               final: stream.finalText)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(object["final"] as? String == text)
        }
    }

    @Test func attachmentsNeverChangeHarnessArgvForEitherHarness() {
        for harness in AgentHarness.allCases {
            let plain = AgentTask(harness: harness, prompt: "-- literal 'task'", model: "model")
            let attached = AgentTask(harness: harness, prompt: "-- literal 'task'", model: "model", session: nil,
                                     systemPrompt: nil, attachments: ["/Users/a/context", "/private/var/evidence"])
            #expect(attached.attachments == ["/Users/a/context", "/private/var/evidence"])
            #expect(attached.systemPrompt == nil)
            #expect(attached.argv(onBox: false) == plain.argv(onBox: false))
            #expect(attached.argv(onBox: true) == plain.argv(onBox: true))
        }
    }

    @Test func jsonPreservesExactLimitAndCleansInvisibleTextBeforeReturningIt() throws {
        let atLimit = String(repeating: "z", count: 65536)
        let exact = AgentRunCommand.jsonLine(job: "id", location: "local", branch: nil, exit: 0, final: atLimit)
        let exactObject = try #require(try JSONSerialization.jsonObject(with: Data(exact.utf8)) as? [String: Any])
        #expect(exactObject["final"] as? String == atLimit)
        let dirty = "a\u{200b}b\u{202e}c\u{1b}]0;title\u{07}d"
        let cleaned = AgentRunCommand.jsonLine(job: "id", location: "box", branch: nil, exit: 0, final: dirty)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any])
        #expect(object["final"] as? String == "abcd")
    }

    @Test func jsonFlagAfterSeparatorIsLiteralPromptText() throws {
        let o = try AgentRunCommand.parse(["--", "--json", "--attach", "/tmp/x"])
        #expect(!o.json && o.attachments.isEmpty && o.appendSystemPrompt == nil)
        #expect(o.prompt == "--json --attach /tmp/x")
    }

    @Test func boxScriptPrunesAttachmentsAfterOneDayAndUnsecretRemovesJobAttachments() throws {
        let script = BoxAssets.script
        let start = try #require(script.range(of: "prune()"))
        let end = try #require(script.range(of: "\n}", range: start.upperBound..<script.endIndex))
        let prune = String(script[start.upperBound..<end.lowerBound])
        #expect(prune.range(of: #"find[^\n]*\.attach[^\n]*-mtime\s+\+1(?:\s|$)[^\n]*(?:-delete|-exec\s+rm)"#, options: .regularExpression) != nil)
        let unsecret = try #require(script.range(of: "  unsecret)"))
        let unsecretEnd = try #require(script.range(of: ";;", range: unsecret.upperBound..<script.endIndex))
        let cleanup = String(script[unsecret.upperBound..<unsecretEnd.lowerBound])
        #expect(cleanup.contains("rm -rf") && cleanup.contains(".attach/"))
        #expect(cleanup.contains("$1") || cleanup.contains("$ulid") || cleanup.contains("${ulid}"))
    }
}

// macOS temporaryDirectory is under /var or /private/var, outside the forbidden /tmp mount.
func attachTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-attach-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
