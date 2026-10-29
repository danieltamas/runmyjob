import Foundation

/// The "star RMJ on GitHub" offer in the panel footer. It asks GitHub once whether the owner's `gh` account has
/// starred the repository, remembers a yes in `config.json` (`starred_repo`) and never asks again.
/// Starring is the owner's click and nothing else: the call goes through their own logged-in `gh`.
public struct RepoStar: Sendable {
    public enum Standing: Equatable, Sendable { case starred, notStarred, unknown }

    /// Runs `gh` with arguments and returns its exit status and standard output.
    public typealias GH = @Sendable ([String]) async -> (status: Int32, output: String)

    public static let repo = "danieltamas/runmyjob"
    private static let starredKey = "starred_repo"

    private let home: RMJHome
    private let gh: GH

    public init(home: RMJHome, gh: @escaping GH = RepoStar.realGH) {
        self.home = home
        self.gh = gh
    }

    /// Whether the footer offers the star: not starred yet. Read from disk only.
    public func shouldOffer() -> Bool {
        let config = ConfigFile.read(home)
        return config?[Self.starredKey] as? Bool != true
    }

    /// Asks GitHub once; a yes is remembered. No `gh`, no login or no answer is `unknown`: nothing is offered then.
    public func refresh() async -> Standing {
        guard shouldOffer() else { return .starred }
        let answer = await gh(["api", "-i", "user/starred/\(Self.repo)"])
        switch Self.httpStatus(answer.output) {
        case 204:
            try? ConfigFile.merge([Self.starredKey: true], home: home)
            return .starred
        case 404: return .notStarred
        default: return .unknown
        }
    }

    /// Stars the repository for the owner's `gh` account. True when GitHub said so (204), and then it is remembered.
    public func star() async -> Bool {
        let answer = await gh(["api", "-i", "-X", "PUT", "user/starred/\(Self.repo)"])
        guard Self.httpStatus(answer.output) == 204 else { return false }
        try? ConfigFile.merge([Self.starredKey: true], home: home)
        return true
    }

    static func httpStatus(_ output: String) -> Int? {
        guard let line = output.split(whereSeparator: \.isNewline).first, line.hasPrefix("HTTP/") else { return nil }
        return line.split(separator: " ").dropFirst().first.flatMap { Int($0) }
    }

    public static let realGH: GH = { arguments in
        guard let gh = Executables.resolve("gh") else { return (127, "") }
        guard let output = try? await ProcessRunner().run(gh, arguments, environment: ["PATH": Executables.searchPath(for: gh)], timeout: .seconds(30)) else { return (1, "") }
        return (output.status, String(decoding: output.stdout, as: UTF8.self))
    }
}
