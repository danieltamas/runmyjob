import Foundation

/// A coding agent's task: what `rmj agent run` hands the engine besides the command that would run it on the Mac.
public struct AgentTask: Sendable, Equatable {
    public var harness: AgentHarness
    public var prompt: String
    /// Skip the harness's permission prompts. Only ever applied in the container: the box is the boundary, the Mac is not.
    public var unattended: Bool
    public var allowedTools: [String]
    public var timeoutSeconds: Int
    /// A run that cannot get a box fails instead of falling back to this Mac.
    public var requireBox: Bool

    public init(harness: AgentHarness = .claude, prompt: String, unattended: Bool = false, allowedTools: [String] = [], timeoutSeconds: Int = 3600, requireBox: Bool = false) {
        self.harness = harness
        self.prompt = prompt
        self.unattended = unattended
        self.allowedTools = allowedTools
        self.timeoutSeconds = timeoutSeconds
        self.requireBox = requireBox
    }

    /// The box variant is bounded by `timeout` inside the container, so a hung harness ends even if the Mac is gone.
    public func argv(onBox: Bool) -> [String] {
        switch harness {
        case .claude:
            let tools = allowedTools.isEmpty ? [] : ["--allowedTools"] + allowedTools
            guard onBox else { return ["claude", "-p", prompt] + tools }
            // stream-json makes every tool call visible while the run goes on; AgentStream turns it back into lines.
            return deadline + ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose", "--permission-mode", unattended ? "bypassPermissions" : "acceptEdits"] + tools
        case .codex:
            guard onBox else { return ["codex", "exec", prompt] }
            // Codex's own sandbox cannot start inside the locked-down container; the container is the boundary.
            return deadline + ["codex", "exec", "--skip-git-repo-check", "--ephemeral", "--dangerously-bypass-approvals-and-sandbox", prompt]
        }
    }

    private var deadline: [String] { ["timeout", "--signal=TERM", "--kill-after=30", String(timeoutSeconds)] }
}
