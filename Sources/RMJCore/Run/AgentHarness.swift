import Foundation

/// The coding agents `rmj agent run` can put on a box: what each needs besides the prompt.
public enum AgentHarness: String, Sendable, CaseIterable {
    case claude
    case codex

    /// The command the task runs, and the one a routing rule matches on.
    public var program: String { rawValue }
    /// The image Setup builds for it.
    public var image: String { "rx-\(rawValue)" }
    /// Where the harness reads its login inside the container (HOME is the container's tmpfs `/tmp`).
    var loginPath: String {
        switch self {
        case .claude: "$HOME/.claude/.credentials.json"
        case .codex: "$HOME/.codex/auth.json"
        }
    }
    /// The only hosts the container may reach (HTTPS, through the box's filtering proxy).
    var egressHosts: [String] {
        switch self {
        case .claude: ["api.anthropic.com"]
        case .codex: ["api.openai.com", "chatgpt.com", "auth.openai.com"]
        }
    }
    var defaultCredentials: CredentialSource {
        switch self {
        case .claude: KeychainCredentials()
        case .codex: CodexAuthFile()
        }
    }
}
