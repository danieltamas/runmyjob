import Foundation

/// A menu bar app gets a minimal PATH, so tools are also looked for where installers put them.
public enum Executables {
    public static let searchPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return (inherited + extra.filter { !inherited.contains($0) }).joined(separator: ":")
    }()

    /// The PATH for `program`, its own directory first: nvm's `claude` runs `#!/usr/bin/env node`,
    /// and its node sits beside the link, not beside what the link points to.
    public static func searchPath(for program: String) -> String {
        guard program.contains("/") else { return searchPath }
        let directory = URL(fileURLWithPath: program).deletingLastPathComponent().path
        return ([directory] + searchPath.split(separator: ":").map(String.init).filter { $0 != directory }).joined(separator: ":")
    }

    public static func resolve(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        return searchPath.split(separator: ":").map { "\($0)/\(name)" }
            .first(where: FileManager.default.isExecutableFile)
    }
}
