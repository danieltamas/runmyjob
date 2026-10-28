import Testing
import Foundation
import RMJCore

struct ReleaseFeedAcceptanceTests {
    @Test(arguments: ["v1.2.3", "V1.2.3", "1.2.3"])
    func parseReadsVersionAndReleaseURL(tag: String) throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "html_url": "https://github.com/owner/app/releases/tag/\(tag)"
        ])
        let release = try #require(ReleaseInfo.parse(body))
        #expect(release.version == "1.2.3")
        #expect(release.url?.absoluteString == "https://github.com/owner/app/releases/tag/\(tag)")
    }

    @Test(arguments: ["not JSON", "{}", "{\"tag_name\":\"\"}",
                      "{\"tag_name\":\"   \"}", "{\"tag_name\":null}"])
    func parseRejectsInvalidJSONOrMissingOrBlankTag(body: String) {
        #expect(ReleaseInfo.parse(Data(body.utf8)) == nil)
    }

    @Test
    func isNewerComparesDottedNumbersAndLeadingSuffixDigits() {
        #expect(ReleaseInfo.isNewer("1.10.0", than: "1.9.2"))
        #expect(!ReleaseInfo.isNewer("1.9.2", than: "1.10.0"))
        #expect(!ReleaseInfo.isNewer("1.2", than: "1.2.0"))
        #expect(!ReleaseInfo.isNewer("1.2.0", than: "1.2"))
        #expect(ReleaseInfo.isNewer("2.0", than: "1.99.9"))
        #expect(!ReleaseInfo.isNewer("1.99.9", than: "2.0"))
        #expect(ReleaseInfo.isNewer("1.2.3-beta", than: "1.2.2"))
        #expect(!ReleaseInfo.isNewer("1.2.3-beta", than: "1.2.3"))
        #expect(!ReleaseInfo.isNewer("1.2.3", than: "1.2.3-beta"))
        #expect(ReleaseInfo.isNewer("1.2.4", than: "1.2.3-beta"))
    }

    @Test
    func latestRequestsGitHubWithHeadersAndReturnsRelease() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let outcome = await ReleaseFeed.latest(repo: "owner/valid", session: session)
        #expect(outcome == .release(ReleaseInfo(
            version: "3.4.5",
            url: URL(string: "https://github.com/owner/valid/releases/tag/v3.4.5")
        )))
    }

    @Test
    func latestReturnsNoReleaseFor404() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        #expect(await ReleaseFeed.latest(repo: "owner/status404", session: session) == .noRelease)
    }

    @Test(arguments: ["status403", "status500", "unreadable", "missingTag"])
    func latestReturnsUnavailableForHTTPOrBodyFailures(scenario: String) async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        #expect(await ReleaseFeed.latest(repo: "owner/\(scenario)", session: session) == .unavailable)
    }

    @Test
    func latestReturnsUnavailableForTransportError() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        #expect(await ReleaseFeed.latest(repo: "owner/transport", session: session) == .unavailable)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    private final class Stub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else {
                Issue.record("Missing request URL")
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let components = url.path.split(separator: "/")
            #expect(components.count == 5)
            guard components.count == 5 else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let scenario = String(components[2])
            #expect(url.absoluteString == "https://api.github.com/repos/owner/\(scenario)/releases/latest")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            let userAgent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            #expect(!userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if scenario == "transport" {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let status: Int
            switch scenario {
            case "status404": status = 404
            case "status403": status = 403
            case "status500": status = 500
            default: status = 200
            }
            let body: String
            switch scenario {
            case "unreadable": body = "not JSON"
            case "missingTag": body = "{}"
            default:
                body = """
                {"tag_name":"v3.4.5","html_url":"https://github.com/owner/valid/releases/tag/v3.4.5"}
                """
            }
            guard let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            ) else {
                Issue.record("Could not create stub response")
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
