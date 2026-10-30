import Foundation
import Testing
@testable import RMJCore

struct AgentRunCommandAcceptanceTests {
    @Test func defaultsAndLiteralPrompt() throws {
        let options = try AgentRunCommand.parse(["--", "fix $(whoami) without shell expansion"])
        #expect(options.destination == nil)
        #expect(options.timeoutSeconds == 3600)
        #expect(!options.unattended && !options.requireBox)
        #expect(options.allowedTools.isEmpty)
        #expect(options.prompt == "fix $(whoami) without shell expansion")
    }

    @Test func allOptionsAndDurationUnits() throws {
        for (duration, seconds) in [("30m", 1800), ("2h", 7200), ("90s", 90)] {
            let options = try AgentRunCommand.parse([
                "--to", "ai-eu-1", "--timeout", duration, "--unattended",
                "--allow", "Read,Edit,Bash", "--require-box", "--", "change the code"
            ])
            #expect(options.destination == "ai-eu-1" && options.timeoutSeconds == seconds)
            #expect(options.unattended && options.requireBox)
            #expect(options.allowedTools == ["Read", "Edit", "Bash"])
            #expect(options.prompt == "change the code")
        }
    }

    @Test func unknownOptionAndMissingPromptAreUsageErrors() {
        for arguments in [["--unknown", "--", "prompt"], [], ["--"], ["--to", "ai-eu-1"]] {
            #expect(throws: AgentRunCommand.Failure.usage) { try AgentRunCommand.parse(arguments) }
        }
    }

    @Test func taskUsesExactBoxDeadlineAndLocalPermissionBoundary() {
        for unattended in [false, true] {
            let task = AgentTask(prompt: "literal prompt", unattended: unattended,
                                 allowedTools: ["Read", "Edit"], timeoutSeconds: 90, requireBox: false)
            #expect(task.argv(onBox: true) == ["timeout", "--signal=TERM", "--kill-after=30", "90", "claude", "-p",
                "literal prompt", "--permission-mode", unattended ? "bypassPermissions" : "acceptEdits",
                "--allowedTools", "Read", "Edit"])
            #expect(task.argv(onBox: false) == ["claude", "-p", "literal prompt", "--allowedTools", "Read", "Edit"])
        }
        let task = AgentTask(prompt: "p", unattended: false, allowedTools: [], timeoutSeconds: 3600, requireBox: false)
        #expect(task.argv(onBox: false) == ["claude", "-p", "p"])
        #expect(!task.argv(onBox: true).contains("--allowedTools"))
    }
}
