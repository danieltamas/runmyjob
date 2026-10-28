import Foundation

public struct GitHubResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public var etag: String?
    public var rateLimitRemaining: Int?
    public var rateLimitReset: Date?
    public var hasNextPage: Bool

    public init(status: Int, body: Data = Data(), etag: String? = nil, rateLimitRemaining: Int? = nil,
                rateLimitReset: Date? = nil, hasNextPage: Bool = false) {
        self.status = status
        self.body = body
        self.etag = etag
        self.rateLimitRemaining = rateLimitRemaining
        self.rateLimitReset = rateLimitReset
        self.hasNextPage = hasNextPage
    }

    /// GitHub says "rate limited" with a 403 or 429 and no requests left.
    public var isRateLimited: Bool { (status == 403 || status == 429) && (rateLimitRemaining ?? 0) == 0 }
}

/// GET requests to the GitHub REST API. `path` starts with `/`; `etag` makes the call conditional.
public protocol GitHubAPI: Sendable {
    func get(_ path: String, query: [String: String], etag: String?, token: String?) async throws -> GitHubResponse
}

/// The real API through `gh api`: gh holds the token (RMJ stores none) and RMJ asks per call.
public struct GHCLI: GitHubAPI {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public init() {}

    public func get(_ path: String, query: [String: String], etag: String?, token: String? = nil) async throws -> GitHubResponse {
        guard let gh = Executables.resolve("gh") else { throw Failure(message: "gh is not installed") }
        var url = path
        if !query.isEmpty {
            url += "?" + query.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
        }
        var arguments = ["api", "-i", "-H", "Accept: application/vnd.github+json"]
        if let etag { arguments += ["-H", "If-None-Match: \(etag)"] }
        arguments.append(url)
        let output = try await ProcessRunner().run(gh, arguments, environment: ["PATH": Executables.searchPath(for: gh)].merging(token.map { ["GH_TOKEN": $0] } ?? [:]) { $1 }, timeout: .seconds(60))
        guard let response = Self.parse(output.stdout) else {
            throw Failure(message: "gh api failed: \(UntrustedText.clean(output.stderr.split(separator: "\n").first.map(String.init) ?? "no output"))")
        }
        return response
    }

    /// `HTTP/2.0 200 OK`, headers, a blank line, the body.
    static func parse(_ data: Data) -> GitHubResponse? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8)) else { return nil }
        let head = String(decoding: data[..<separator.lowerBound], as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        guard let first = head.first, first.hasPrefix("HTTP/"), let status = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return nil }
        var headers = [String: String]()
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return GitHubResponse(status: status, body: Data(data[separator.upperBound...]), etag: headers["etag"],
                              rateLimitRemaining: headers["x-ratelimit-remaining"].flatMap(Int.init),
                              rateLimitReset: headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)),
                              hasNextPage: headers["link"]?.contains("rel=\"next\"") ?? false)
    }
}
