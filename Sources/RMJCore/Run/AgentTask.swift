import Foundation

/// A coding agent's task: what `rmj agent run` hands the engine besides the command that would run it on the Mac.
public struct AgentTask: Sendable, Equatable {
    /// A Claude conversation the caller starts (`--session-id`) or continues (`--resume`); its transcript is kept on the box between runs.
    public struct Session: Sendable, Equatable {
        public var id: String
        public var resume: Bool

        public init(id: String, resume: Bool) {
            self.id = id
            self.resume = resume
        }
    }

    public var harness: AgentHarness
    public var prompt: String
    /// Skip the harness's permission prompts. Only ever applied in the container: the box is the boundary, the Mac is not.
    public var unattended: Bool
    public var allowedTools: [String]
    public var timeoutSeconds: Int
    /// A run that cannot get a box fails instead of falling back to this Mac.
    public var requireBox: Bool
    public var model: String?
    public var session: Session?
    /// Appended to the harness's system prompt (Claude only): the hat's playbook, kept apart from the task.
    public var systemPrompt: String?
    /// Absolute directories the run reads, mounted read-only at the same path on a box (`--attach`).
    public var attachments: [String]

    public init(harness: AgentHarness = .claude, prompt: String, unattended: Bool = false, allowedTools: [String] = [], timeoutSeconds: Int = 3600,
                requireBox: Bool = false, model: String? = nil, session: Session? = nil,
                systemPrompt: String? = nil, attachments: [String] = []) {
        self.harness = harness
        self.prompt = prompt
        self.unattended = unattended
        self.allowedTools = allowedTools
        self.timeoutSeconds = timeoutSeconds
        self.requireBox = requireBox
        self.model = model
        self.session = session
        self.systemPrompt = systemPrompt
        self.attachments = attachments
    }

    /// The box variant is bounded by `timeout` inside the container, so a hung harness ends even if the Mac is gone.
    public func argv(onBox: Bool) -> [String] {
        switch harness {
        case .claude:
            let tools = allowedTools.isEmpty ? [] : ["--allowedTools"] + allowedTools
            let chosen = (model.map { ["--model", $0] } ?? []) + (systemPrompt.map { ["--append-system-prompt", $0] } ?? [])
                + (session.map { [$0.resume ? "--resume" : "--session-id", $0.id] } ?? [])
            guard onBox else { return ["claude", "-p", prompt] + chosen + tools }
            // stream-json makes every tool call visible while the run goes on; AgentStream turns it back into lines.
            return deadline + ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose", "--permission-mode", unattended ? "bypassPermissions" : "acceptEdits"] + chosen + tools
        case .codex:
            let chosen = model.map { ["-m", $0] } ?? []
            guard onBox else { return ["codex", "exec"] + chosen + [prompt] }
            // Codex's own sandbox cannot start inside the locked-down container; the container is the boundary.
            return deadline + ["codex", "exec"] + chosen + ["--skip-git-repo-check", "--ephemeral", "--dangerously-bypass-approvals-and-sandbox", prompt]
        }
    }

    private var deadline: [String] { ["timeout", "--signal=TERM", "--kill-after=30", String(timeoutSeconds)] }
}
