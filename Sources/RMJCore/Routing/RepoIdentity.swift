import Foundation

/// The canonical `owner/name` of a checkout (from its origin URL), where it lives, and whether it has uncommitted changes.
public struct RepoIdentity: Sendable, Equatable {
    public let slug: String?
    public let worktree: String
    public let dirty: Bool

    public init(slug: String?, worktree: String, dirty: Bool = false) {
        self.slug = slug
        self.worktree = worktree
        self.dirty = dirty
    }

    public var owner: String? { slug?.split(separator: "/").first.map(String.init) }

    /// `git@github.com:Owner/Name.git`, `ssh://git@github.com/Owner/Name`, `https://github.com/Owner/Name.git`
    /// all become `owner/name`. Anything that is not host plus two path parts is nil.
    public static func canonicalSlug(remoteURL: String) -> String? {
        var text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        if let scheme = text.range(of: "://") {
            guard ["ssh", "https", "http", "git"].contains(String(text[..<scheme.lowerBound])) else { return nil }
            text = String(text[scheme.upperBound...])
            guard let slash = text.firstIndex(of: "/") else { return nil }
            host = String(text[..<slash])
            text = String(text[text.index(after: slash)...])
        } else if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            host = String(text[..<colon])
            text = String(text[text.index(after: colon)...])
        } else {
            return nil
        }
        // Only GitHub names repositories here: the same owner/name on another host is not the same repository.
        guard host.split(separator: "@").last?.split(separator: ":").first?.lowercased() == "github.com" else { return nil }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map { $0.lowercased() }
        let valid = { (part: String) in !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } && part != ".." && part != "." }
        guard parts.count == 2, parts.allSatisfy(valid) else { return nil }
        return parts.joined(separator: "/")
    }

    /// Reads the checkout with git; a directory that is not a repository has no slug.
    public static func detect(in directory: URL, runner: ProcessRunner = ProcessRunner()) async -> RepoIdentity {
        func git(_ arguments: [String]) async -> String? {
            guard let output = try? await runner.run("/usr/bin/git", ["-C", directory.path] + arguments, timeout: .seconds(10)),
                  output.status == 0 else { return nil }
            return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let top = await git(["rev-parse", "--show-toplevel"]) ?? directory.path
        let slug = await git(["remote", "get-url", "origin"]).flatMap { canonicalSlug(remoteURL: $0) }
        let dirty = !(await git(["status", "--porcelain"]) ?? "").isEmpty
        return RepoIdentity(slug: slug, worktree: top, dirty: dirty)
    }
}

public enum Tenancy {
    public struct Resolution: Sendable, Equatable {
        public let tenant: String
        /// How it was decided, for the explain.
        public let how: String
    }

    public static let unclassified = "unclassified"

    /// The `repos` table of every tenant first, then the `owners` tables, else unclassified.
    public static func resolve(_ identity: RepoIdentity, in tenants: [String: TenantConfig]) -> Resolution {
        guard let slug = identity.slug?.lowercased(), let owner = identity.owner?.lowercased() else {
            return Resolution(tenant: unclassified, how: "no origin remote")
        }
        let sorted = tenants.sorted(by: { $0.key < $1.key })
        // Two tenants claiming one repo is a configuration the deny cannot be trusted with: fail closed.
        let byRepo = sorted.compactMap { name, tenant in (tenant.repos ?? []).first(where: { Glob.matches($0.lowercased(), slug) }).map { (name, $0) } }
        if byRepo.count > 1 { return Resolution(tenant: unclassified, how: "ambiguous: \(byRepo.map(\.0).joined(separator: " and ")) both claim \(slug)") }
        if let (name, pattern) = byRepo.first { return Resolution(tenant: name, how: "repos table: \(pattern)") }
        let byOwner = sorted.filter { (_, tenant) in (tenant.owners ?? []).contains(where: { $0.lowercased() == owner }) }.map(\.key)
        if byOwner.count > 1 { return Resolution(tenant: unclassified, how: "ambiguous: \(byOwner.joined(separator: " and ")) both list owner \(owner)") }
        if let name = byOwner.first { return Resolution(tenant: name, how: "owners table: \(owner)") }
        return Resolution(tenant: unclassified, how: "owner \(owner) is in no tenant")
    }

    /// Two tenants never mix: a repo of one is denied a destination of another. A tenant that is not declared, or that
    /// is declared `shared` (one person's own repos), is not a company and is never denied.
    public static func denies(repoTenant: String, destinationTenant: String, tenants: [String: TenantConfig]) -> Bool {
        guard repoTenant != destinationTenant, let repo = tenants[repoTenant], let destination = tenants[destinationTenant] else { return false }
        return repo.shared != true && destination.shared != true
    }
}

enum Glob {
    static func matches(_ pattern: String, _ text: String) -> Bool { fnmatch(pattern, text, 0) == 0 }
}

/// The first word of a command and, for `cargo` and `just`, its first subcommand.
public struct CommandWords: Sendable, Equatable {
    public let program: String
    public let subcommand: String?

    public init(argv: [String]) {
        program = URL(fileURLWithPath: argv.first ?? "").lastPathComponent
        let wrapped = ["cargo", "just"].contains(program)
        subcommand = wrapped ? Self.subcommand(program: program, rest: Array(argv.dropFirst())) : nil
    }

    /// Global options that take the next word as their value must not be mistaken for the subcommand.
    private static let valueOptions: [String: [String: Int]] = [
        "cargo": ["--color": 1, "--config": 1, "-C": 1, "-Z": 1],
        "just": ["-f": 1, "--justfile": 1, "-d": 1, "--working-directory": 1, "--set": 2, "--shell": 1, "--color": 1,
                 "--chooser": 1, "--dotenv-path": 1],
    ]

    private static func subcommand(program: String, rest: [String]) -> String? {
        var index = 0
        while index < rest.count {
            let word = rest[index]
            if let values = valueOptions[program]?[word] { index += 1 + values; continue }
            if word.hasPrefix("-") || word.hasPrefix("+") { index += 1; continue }
            return word
        }
        return nil
    }

    public var display: String { ([program] + [subcommand].compactMap { $0 }).joined(separator: " ") }

    /// "cargo build" needs both words; "cargo" needs the program and a subcommand (a bare `cargo` is no build);
    /// any other program matches by its name.
    func matches(_ entry: String) -> Bool {
        let words = entry.split(separator: " ").map(String.init)
        guard let first = words.first, first == program else { return false }
        if ["cargo", "just"].contains(program) {
            guard let subcommand else { return false }
            return words.count == 1 || words[1] == subcommand
        }
        return words.count == 1
    }
}
