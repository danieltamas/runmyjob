import Foundation

/// A coding agent's task: what `rmj agent run` hands the engine besides the command that would run it on the Mac.
public struct AgentTask: Sendable, Equatable {
    public var prompt: String
    /// Skip the harness's permission prompts. Only ever applied in the container: the box is the boundary, the Mac is not.
    public var unattended: Bool
    public var allowedTools: [String]
    public var timeoutSeconds: Int
    /// A run that cannot get a box fails instead of falling back to this Mac.
    public var requireBox: Bool

    public init(prompt: String, unattended: Bool = false, allowedTools: [String] = [], timeoutSeconds: Int = 3600, requireBox: Bool = false) {
        self.prompt = prompt
        self.unattended = unattended
        self.allowedTools = allowedTools
        self.timeoutSeconds = timeoutSeconds
        self.requireBox = requireBox
    }

    /// The box variant is bounded by `timeout` inside the container, so a hung harness ends even if the Mac is gone.
    public func argv(onBox: Bool) -> [String] {
        let tools = allowedTools.isEmpty ? [] : ["--allowedTools"] + allowedTools
        guard onBox else { return ["claude", "-p", prompt] + tools }
        return ["timeout", "--signal=TERM", "--kill-after=30", String(timeoutSeconds), "claude", "-p", prompt,
                "--permission-mode", unattended ? "bypassPermissions" : "acceptEdits"] + tools
    }
}
