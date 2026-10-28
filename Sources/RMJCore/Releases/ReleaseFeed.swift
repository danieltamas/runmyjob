import Foundation

/// The newest published release of a GitHub repository, read over plain HTTP so it needs no `gh` login.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let url: URL?

    public init(version: String, url: URL?) {
        self.version = version
        self.url = url
    }

    /// `tag_name` of a GitHub release object, without a leading `v`; nil when the data is not a release with a tag.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = (object["tag_name"] as? String)?.trimmingCharacters(in: .whitespaces), !tag.isEmpty else { return nil }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(version: version, url: (object["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// Whether `latest` is a higher dotted number than `installed` (`1.10.0` beats `1.9.2`; a missing part is 0).
    public static func isNewer(_ latest: String, than installed: String) -> Bool {
        func parts(_ text: String) -> [Int] { text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let (a, b) = (parts(latest), parts(installed))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return false
    }
}

public enum ReleaseFeed {
    public enum Outcome: Equatable, Sendable {
        case release(ReleaseInfo)
        /// The repository exists and has published nothing yet.
        case noRelease
        /// Offline, rate limited or an unreadable answer: the page says nothing rather than something wrong.
        case unavailable
    }

    /// `owner/name`'s latest release. Never throws; every failure is `.unavailable`.
    public static func latest(repo: String, session: URLSession = .shared) async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return .unavailable }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RMJ", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return .unavailable }
        switch http.statusCode {
        case 200: return ReleaseInfo.parse(data).map(Outcome.release) ?? .unavailable
        case 404: return .noRelease
        default: return .unavailable
        }
    }
}
