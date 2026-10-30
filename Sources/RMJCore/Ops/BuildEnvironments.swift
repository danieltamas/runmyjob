import Foundation

/// A toolchain image RMJ ships a Dockerfile for (`Support/box/images/<name without rx->`) and builds on a destination at Setup.
/// Every job on a box runs in one of these containers; the box itself carries only docker, rsync, ssh and bash.
public struct BuildEnvironment: Sendable, Equatable {
    public let image: String
    public let summary: String
    /// Programs the image must contain; Setup and the probe check them by running the image.
    public let tools: [String]
}

public enum BuildEnvironments {
    public static let catalog: [BuildEnvironment] = [
        BuildEnvironment(image: "rx-rust", summary: "Rust toolchain with cargo, just and cargo-deny",
                         tools: ["bash", "zsh", "git", "jq", "cargo", "just"]),
        BuildEnvironment(image: "rx-node", summary: "Node and bun",
                         tools: ["bash", "zsh", "git", "jq", "node", "bun"]),
        BuildEnvironment(image: "rx-python", summary: "Python with uv and pytest",
                         tools: ["bash", "zsh", "git", "jq", "python3", "uv", "pytest"]),
        BuildEnvironment(image: "rx-go", summary: "Go toolchain",
                         tools: ["bash", "zsh", "git", "jq", "go"]),
        BuildEnvironment(image: "rx-claude", summary: "Claude Code for agent runs",
                         tools: ["bash", "git", "jq", "claude"]),
    ]

    public static func tools(for image: String) -> [String] {
        catalog.first { $0.image == image }?.tools ?? []
    }

    /// The programs to look for in `image`: its own, then the destination's `requires`, once each, plain names only.
    static func required(in image: String, requires: [String]) -> [String] {
        var seen = Set<String>()
        return (tools(for: image) + requires).filter { DestinationConfig.isProgramName($0) && seen.insert($0).inserted }
    }

    /// `rx-rust`, `ubuntu:24.04`, `registry/name`: nothing a shell could read as more than one word.
    static func isImageName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil
    }

    /// The command that prints `missing:<image>:<program>` for each required program the image lacks.
    /// No network, no capabilities: it only looks.
    static func checkCommand(image: String, programs: [String]) -> String {
        let list = programs.map { "'\($0)'" }.joined(separator: " ")
        let loop = "for p in \(list); do command -v \"$p\" >/dev/null 2>&1 || echo \"missing:\(image):$p\"; done"
        return "docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges --entrypoint sh \(image) -c '\(loop)'"
    }
}

/// What an image lacks, as the probe or Setup found it.
public struct MissingTools: Sendable, Equatable {
    public let image: String
    public let programs: [String]

    public init(image: String, programs: [String]) {
        self.image = image
        self.programs = programs
    }
}
