import Foundation

/// One line of a run's output, with where it came from.
public struct LogEntry: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable { case info, warn, error }

    public var time: Date
    public var line: String
    public var level: Level
    public var job: String
    public var n: Int
    public var repo: String
    public var tenant: String?
    public var branch: String?
    public var agent: String?
    public var destination: String

    public init(time: Date, line: String, level: Level = .info, job: String, n: Int, repo: String,
                tenant: String? = nil, branch: String? = nil, agent: String? = nil, destination: String) {
        self.time = time; self.line = line; self.level = level; self.job = job; self.n = n; self.repo = repo
        self.tenant = tenant; self.branch = branch; self.agent = agent; self.destination = destination
    }
}

/// Entries to an ingestor's HTTP request. Pure: the same batch gives the same bytes, so a resent batch is identical
/// (Elasticsearch also gets a stable `_id`).
public enum LogSinkFormat {
    public static let maxLineBytes = 1_048_576
    public static func maxBatch(_ kind: LogSinkConfig.Kind) -> Int { 500 }
    /// A request stays under this many bytes of text; escaping can multiply it by 6, still below Datadog's 5 MB.
    public static let maxRequestBytes = 768 * 1024

    /// Entries split into requests of at most `maxBatch` lines and `maxRequestBytes` of text; a single line always fits.
    public static func chunks(_ entries: [LogEntry], kind: LogSinkConfig.Kind) -> [[LogEntry]] {
        var result: [[LogEntry]] = []
        var current: [LogEntry] = []
        var bytes = 0
        for entry in entries {
            let size = min(entry.line.utf8.count, maxLineBytes) + 256
            if !current.isEmpty, current.count >= maxBatch(kind) || bytes + size > maxRequestBytes {
                result.append(current); current = []; bytes = 0
            }
            current.append(entry); bytes += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func request(sink: LogSinkConfig, secret: String?, entries: [LogEntry], host: String) throws -> URLRequest {
        try sink.validate()
        guard !entries.isEmpty else { throw LogSinkError(message: "no entries to send") }
        let clipped = entries.map { entry -> LogEntry in var copy = entry; copy.line = clip(entry.line); return copy }
        var request: URLRequest
        switch sink.kind {
        case .loki:
            request = try post(sink, path: "/loki/api/v1/push", type: "application/json", body: loki(clipped))
            if let org = sink.orgID, !org.isEmpty { request.setValue(org, forHTTPHeaderField: "X-Scope-OrgID") }
            try authorize(&request, sink: sink, secret: secret)
        case .elasticsearch:
            request = try post(sink, path: "/_bulk", type: "application/x-ndjson", body: bulk(clipped, index: sink.index ?? "rmj-logs", host: host))
            try authorize(&request, sink: sink, secret: secret)
        case .datadog:
            guard let secret, !secret.isEmpty else { throw LogSinkError(message: "sink \(sink.id): the API key is missing") }
            let url = URL(string: "https://http-intake.logs.\(sink.site ?? "datadoghq.com")/api/v2/logs")!
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(secret, forHTTPHeaderField: "DD-API-KEY")
            request.httpBody = try json(datadog(clipped, host: host))
        }
        request.timeoutInterval = 5
        return request
    }

    // MARK: bodies

    private static func loki(_ entries: [LogEntry]) throws -> Data {
        var order: [String] = []
        var streams: [String: (labels: [String: String], values: [[String]])] = [:]
        for entry in entries {
            let labels = ["app": "rmj", "tenant": entry.tenant ?? "none", "repo": entry.repo, "destination": entry.destination, "level": entry.level.rawValue]
            let key = ["tenant", "repo", "destination", "level"].map { labels[$0]! }.joined(separator: "\u{1f}")
            var line: [String: Any] = ["job": entry.job, "n": entry.n, "msg": entry.line]
            if let branch = entry.branch { line["branch"] = branch }
            if let agent = entry.agent { line["agent"] = agent }
            let value = [String(milliseconds(entry.time) * 1_000_000), String(decoding: try json(line), as: UTF8.self)]
            if streams[key] == nil { order.append(key); streams[key] = (labels, []) }
            streams[key]!.values.append(value)
        }
        return try json(["streams": order.map { ["stream": streams[$0]!.labels, "values": streams[$0]!.values] as [String: Any] }])
    }

    /// A comma ends a Datadog tag, so a value from a directory or branch name cannot add a tag of its own.
    private static func tagValue(_ value: String) -> String { value.replacingOccurrences(of: ",", with: "_") }

    private static func datadog(_ entries: [LogEntry], host: String) -> [[String: Any]] {
        entries.map { entry in
            let tags = [entry.tenant.map { "tenant:\(tagValue($0))" }, "repo:\(tagValue(entry.repo))", "destination:\(tagValue(entry.destination))",
                        "job:\(tagValue(entry.job))", entry.branch.map { "branch:\(tagValue($0))" }, entry.agent.map { "agent:\(tagValue($0))" }].compactMap { $0 }
            return ["ddsource": "rmj", "service": "rmj", "hostname": host, "status": entry.level.rawValue, "message": entry.line,
                    "timestamp": milliseconds(entry.time), "job": entry.job, "n": entry.n, "ddtags": tags.joined(separator: ",")]
        }
    }

    private static func bulk(_ entries: [LogEntry], index: String, host: String) throws -> Data {
        var body = Data()
        for entry in entries {
            var meta: [String: Any] = ["job": entry.job, "n": entry.n, "repo": entry.repo, "destination": entry.destination]
            if let tenant = entry.tenant { meta["tenant"] = tenant }
            if let branch = entry.branch { meta["branch"] = branch }
            if let agent = entry.agent { meta["agent"] = agent }
            body.append(try json(["create": ["_index": index, "_id": "\(entry.job)-\(entry.n)"]]))
            body.append(10)
            body.append(try json(["@timestamp": iso(entry.time), "message": entry.line, "log.level": entry.level.rawValue,
                                  "service.name": "rmj", "host.name": host, "rmj": meta] as [String: Any]))
            body.append(10)
        }
        return body
    }

    // MARK: pieces

    private static func post(_ sink: LogSinkConfig, path: String, type: String, body: Data) throws -> URLRequest {
        var base = sink.url ?? ""
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { throw LogSinkError(message: "sink \(sink.id): the URL is not valid") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func authorize(_ request: inout URLRequest, sink: LogSinkConfig, secret: String?) throws {
        guard sink.auth != .none else { return }
        guard let secret, !secret.isEmpty else { throw LogSinkError(message: "sink \(sink.id): the secret is missing from the Keychain") }
        switch sink.auth {
        case .basic: request.setValue("Basic " + Data("\(sink.user ?? ""):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        case .bearer: request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case .apikey: request.setValue("ApiKey \(secret)", forHTTPHeaderField: "Authorization")
        case .none: break
        }
    }

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private static func iso(_ date: Date) -> String {
        let ms = milliseconds(date)
        let whole = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(ms.floorDiv(1000))))
        return String(whole.dropLast()) + String(format: ".%03dZ", Int(ms - ms.floorDiv(1000) * 1000))
    }

    /// A line over the limit is cut on a character boundary and says so.
    private static func clip(_ text: String) -> String {
        guard text.utf8.count > maxLineBytes else { return text }
        var bytes = Array(text.utf8.prefix(maxLineBytes))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self) + " ...[truncated]"
    }
}

private extension Int64 {
    func floorDiv(_ divisor: Int64) -> Int64 { self >= 0 ? self / divisor : -((-self + divisor - 1) / divisor) }
}
