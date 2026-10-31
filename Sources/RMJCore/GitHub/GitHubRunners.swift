import Foundation

/// A runner as GitHub lists it, with the id a delete needs.
public struct GitHubRunner: Sendable, Equatable {
    public var id: Int64
    public var name: String
    public var online: Bool
    public var busy: Bool
    public var labels: [String]

    public init(id: Int64, name: String, online: Bool, busy: Bool, labels: [String]) {
        self.id = id
        self.name = name
        self.online = online
        self.busy = busy
        self.labels = labels
    }
}

/// DELETE requests, kept apart from `GitHubAPI` so read-only fakes stay read-only.
public protocol GitHubWriteAPI: GitHubAPI {
    func delete(_ path: String, token: String?) async throws -> GitHubResponse
}

extension GHCLI: GitHubWriteAPI {
    public func delete(_ path: String, token: String?) async throws -> GitHubResponse {
        guard let gh = Executables.resolve("gh") else { throw Failure(message: "gh is not installed") }
        let output = try await ProcessRunner().run(gh, ["api", "-i", "-X", "DELETE", path], environment: ["PATH": Executables.searchPath(for: gh)]
            .merging(token.map { ["GH_TOKEN": $0] } ?? [:]) { $1 }, timeout: .seconds(60))
        guard let response = Self.parse(output.stdout) else { throw Failure(message: "gh api failed: \(GitHubText.clean(output.stderr))") }
        return response
    }
}

/// A runner target: `owner/name` (repo scope) or `org:Name`.
public enum RunnerTarget {
    public static func path(_ target: String) -> String? {
        if target.hasPrefix("org:") {
            let org = String(target.dropFirst(4))
            return valid(org) ? "/orgs/\(org)/actions/runners" : nil
        }
        let parts = target.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy({ valid(String($0)) }) ? "/repos/\(target)/actions/runners" : nil
    }

    static func valid(_ part: String) -> Bool {
        !part.isEmpty && part != "." && part != ".." && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// The compose variable holding the PAT of a target: `GH_PAT_<OWNER>`.
    public static func environmentName(_ target: String) -> String? {
        let owner = target.hasPrefix("org:") ? String(target.dropFirst(4)) : String(target.split(separator: "/").first ?? "")
        guard valid(owner) else { return nil }
        return "GH_PAT_" + owner.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }
}

public enum GitHubRunners {
    public struct Failure: Error, Equatable { public let message: String }

    /// Every runner of a target, all pages. Any failed page fails the listing: a partial list is not evidence.
    public static func list(api: GitHubAPI, target: String, token: String?) async throws -> [GitHubRunner] {
        guard let path = RunnerTarget.path(target) else { throw Failure(message: "bad runner target") }
        var runners = [GitHubRunner](), page = 1
        while true {
            let response = try await api.get(path, query: ["per_page": "100", "page": String(page)], etag: nil, token: token)
            guard response.status == 200 else { throw Failure(message: permissionHint(response, target: target) ?? "GitHub answered \(response.status) listing runners of \(target)") }
            runners += try decode(response.body)
            guard response.hasNextPage else { return runners }
            page += 1
        }
    }

    public static func get(api: GitHubAPI, target: String, id: Int64, token: String?) async throws -> GitHubRunner? {
        guard let path = RunnerTarget.path(target) else { throw Failure(message: "bad runner target") }
        let response = try await api.get("\(path)/\(id)", query: [:], etag: nil, token: token)
        if response.status == 404 { return nil }
        guard response.status == 200 else { throw Failure(message: "GitHub answered \(response.status) reading runner \(id)") }
        struct One: Decodable { var id: Int64; var name: String; var status: String; var busy: Bool; var labels: [GitHubJSON.Runners.Runner.Label] }
        let one = try GitHubJSON.decoder.decode(One.self, from: response.body)
        return GitHubRunner(id: one.id, name: GitHubText.clean(one.name), online: one.status == "online", busy: one.busy, labels: one.labels.map { GitHubText.clean($0.name) })
    }

    static func decode(_ body: Data) throws -> [GitHubRunner] {
        struct Listed: Decodable { var runners: [Item] }
        struct Item: Decodable { var id: Int64; var name: String; var status: String; var busy: Bool; var labels: [GitHubJSON.Runners.Runner.Label] }
        return try GitHubJSON.decoder.decode(Listed.self, from: body).runners.map {
            GitHubRunner(id: $0.id, name: GitHubText.clean($0.name), online: $0.status == "online", busy: $0.busy, labels: $0.labels.map { GitHubText.clean($0.name) })
        }
    }

    /// A 403 names the permission the PAT lacks in `X-Accepted-GitHub-Permissions`; the answer body is enough to tell it apart.
    static func permissionHint(_ response: GitHubResponse, target: String) -> String? {
        switch response.status {
        case 403: return "the PAT lacks the permission to manage runners of \(target) (GitHub answered 403)"
        // GitHub answers 404 for a name that does not exist as well as for one the PAT cannot see.
        case 404: return "GitHub shows this PAT no \(target) (404): check the exact GitHub name, and that the PAT was created for it with the self-hosted runners permission"
        default: return nil
        }
    }
}
