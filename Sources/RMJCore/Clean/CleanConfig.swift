import Foundation

/// What `rmj clean` may remove: `~/.rmj/clean.json`, absent means the defaults.
public struct CleanTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case scratch, worktrees }

    public var kind: Kind
    /// `scratch`: a glob of directories (a wildcard in the last component only). `worktrees`: a git repository.
    public var path: String
    public var afterHours: Int

    public init(kind: Kind, path: String, afterHours: Int = 48) {
        self.kind = kind
        self.path = path
        self.afterHours = afterHours
    }

    private enum CodingKeys: String, CodingKey { case kind, path, afterHours = "after_hours" }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        path = try values.decode(String.self, forKey: .path)
        afterHours = try values.decodeIfPresent(Int.self, forKey: .afterHours) ?? 48
    }
}

public struct CleanConfig: Codable, Equatable, Sendable {
    public var targets: [CleanTarget]

    public init(targets: [CleanTarget]) { self.targets = targets }

    /// RMJ's own build scratch, three days after it was last touched.
    public static var defaults: CleanConfig {
        CleanConfig(targets: [CleanTarget(kind: .scratch, path: expand("~/.cache/rmj-*"), afterHours: 72)])
    }

    static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst() : path
    }

    /// The file's targets, or the defaults and what is wrong with the file: one bad target rejects all of them.
    public static func load(home: RMJHome) -> (config: CleanConfig, problem: String?) {
        let file = home.url.appendingPathComponent("clean.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return (defaults, nil) }
        do {
            var config = try JSONDecoder().decode(CleanConfig.self, from: Data(contentsOf: file))
            for index in config.targets.indices {
                config.targets[index].path = expand(config.targets[index].path)
                if let problem = config.targets[index].problem { return (defaults, "target \(index + 1): \(problem)") }
            }
            return (config, nil)
        } catch {
            return (defaults, "clean.json: \(UntrustedText.clean(error.localizedDescription, limit: 160))")
        }
    }
}

extension CleanTarget {
    /// Why this target is refused, or nil: absolute, at least three components, no `..`, a wildcard in the last component only.
    var problem: String? {
        guard (1...8760).contains(afterHours) else { return "after_hours must be 1 to 8760" }
        guard path.hasPrefix("/") else { return "the path must be absolute" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return "the path must have at least three components" }
        guard !parts.contains("..") else { return "the path may not contain .." }
        guard !parts.dropLast().contains(where: { $0.contains(where: { "*?[".contains($0) }) }) else { return "a wildcard is allowed in the last component only" }
        if kind == .worktrees, parts.last?.contains(where: { "*?[".contains($0) }) == true { return "a worktrees path is a repository, not a glob" }
        return nil
    }
}
