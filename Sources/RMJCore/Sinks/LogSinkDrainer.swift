import Foundation

public struct LogSinkResponse: Sendable, Equatable {
    public let status: Int
    public let retryAfter: TimeInterval?
    public let body: Data

    public init(status: Int, retryAfter: TimeInterval? = nil, body: Data = Data()) {
        self.status = status; self.retryAfter = retryAfter; self.body = body
    }
}

public protocol LogSinkTransport: Sendable {
    func send(_ request: URLRequest) async throws -> LogSinkResponse
}

public enum SinkHealth: Sendable, Equatable {
    case ok
    case backoff(until: Date, reason: String)
    case authFailed(String)
    case paused
}

/// Sends a sink's spool, oldest file first, and deletes a file only after the sink answered 2xx (at least once).
public actor LogSinkDrainer {
    public struct Outcome: Sendable, Equatable {
        public let files: Int
        public let lines: Int
        public let rejected: Int
        public let health: SinkHealth
        public let lastError: String?
    }

    private enum Verdict {
        case sent
        case retry(after: TimeInterval?, reason: String)
        case authFailed(String)
        case reject
    }

    private static let firstDelay: TimeInterval = 1
    private static let longestDelay: TimeInterval = 300
    private static let longestRetryAfter: TimeInterval = 3600

    private let sink: LogSinkConfig
    private let secret: String?
    private let spool: LogSpool
    private let transport: LogSinkTransport
    private let host: String
    private var failures = 0
    private var waiting: (until: Date, reason: String)?
    private var authFailure: String?

    public init(sink: LogSinkConfig, secret: String?, spool: LogSpool, transport: LogSinkTransport, host: String) {
        self.sink = sink; self.secret = secret; self.spool = spool; self.transport = transport; self.host = host
    }

    public func resume() { authFailure = nil; waiting = nil; failures = 0 }

    public func drain(now: Date = Date()) async -> Outcome {
        guard sink.enabled else { return Outcome(files: 0, lines: 0, rejected: 0, health: .paused, lastError: nil) }
        if let authFailure { return Outcome(files: 0, lines: 0, rejected: 0, health: .authFailed(authFailure), lastError: authFailure) }
        if let waiting, now < waiting.until {
            return Outcome(files: 0, lines: 0, rejected: 0, health: .backoff(until: waiting.until, reason: waiting.reason), lastError: waiting.reason)
        }
        let result = await spool.withDrainLock { await self.pass(now: now) }
        return result ?? Outcome(files: 0, lines: 0, rejected: 0, health: .ok, lastError: nil)
    }

    private func pass(now: Date) async -> Outcome {
        waiting = nil
        var files = 0, lines = 0, rejected = 0
        var quarantined = 0
        defer { rejected += quarantined }
        while let batch = spool.next(quarantined: &quarantined) {
            // Every entry carries its tenant: what this sink may not receive now is dropped here, whatever was queued before.
            let allowed = batch.entries.filter { sink.accepts(tenant: $0.tenant) }
            if allowed.isEmpty { spool.acknowledge(batch.id); continue }
            switch await send(allowed) {
            case .sent:
                spool.acknowledge(batch.id)
                files += 1; lines += allowed.count; failures = 0
            case .reject:
                spool.reject(batch.id)
                rejected += 1
            case .retry(let after, let reason):
                failures += 1
                let delay = after.map { min($0, Self.longestRetryAfter) } ?? min(Self.firstDelay * pow(2, Double(failures - 1)), Self.longestDelay)
                let until = now.addingTimeInterval(delay)
                waiting = (until, reason)
                return Outcome(files: files, lines: lines, rejected: rejected, health: .backoff(until: until, reason: reason), lastError: reason)
            case .authFailed(let reason):
                authFailure = reason
                return Outcome(files: files, lines: lines, rejected: rejected, health: .authFailed(reason), lastError: reason)
            }
        }
        return Outcome(files: files, lines: lines, rejected: rejected, health: .ok, lastError: nil)
    }

    /// A file larger than one request goes in chunks; it counts as sent only when every chunk was.
    private func send(_ entries: [LogEntry]) async -> Verdict {
        var verdict = Verdict.sent
        for chunk in LogSinkFormat.chunks(entries, kind: sink.kind) {
            let request: URLRequest
            do {
                request = try LogSinkFormat.request(sink: sink, secret: secret, entries: chunk, host: host)
            } catch {
                return .authFailed(String(describing: error))
            }
            let response: LogSinkResponse
            do { response = try await transport.send(request) } catch { return .retry(after: nil, reason: String(describing: error)) }
            verdict = classify(response, expected: chunk.count)
            if case .sent = verdict { continue }
            return verdict
        }
        return verdict
    }

    private func classify(_ response: LogSinkResponse, expected: Int) -> Verdict {
        let reason = "HTTP \(response.status)"
        switch response.status {
        case 200..<300: return sink.kind == .elasticsearch ? bulkVerdict(response, expected: expected) : .sent
        case 401, 403: return .authFailed(reason)
        case 408, 429, 500...599: return .retry(after: response.retryAfter, reason: reason)
        default: return .reject
        }
    }

    /// Elasticsearch answers 200 even when single items failed. An answer that cannot be read counts as not delivered.
    /// An item that exists already (409) was delivered by an earlier attempt of this same batch.
    private func bulkVerdict(_ response: LogSinkResponse, expected: Int) -> Verdict {
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any], let errors = object["errors"] as? Bool else {
            return .retry(after: response.retryAfter, reason: "unreadable bulk answer")
        }
        guard errors else { return .sent }
        let items = object["items"] as? [[String: Any]] ?? []
        let statuses = items.compactMap { $0.values.first as? [String: Any] }.compactMap { $0["status"] as? Int }
        guard items.count == expected, statuses.count == expected else { return .retry(after: response.retryAfter, reason: "incomplete bulk answer") }
        let failed = statuses.filter { !(200..<300).contains($0) && $0 != 409 }
        if failed.isEmpty { return .sent }
        if failed.contains(where: { $0 == 401 || $0 == 403 }) { return .authFailed("HTTP 401 in bulk item") }
        if let retryable = failed.first(where: { $0 == 408 || $0 == 429 || $0 >= 500 }) { return .retry(after: response.retryAfter, reason: "HTTP \(retryable) in bulk item") }
        return .reject
    }
}

/// The real transport: 5 second requests, no cookies, no cache, and a redirect is an answer, never followed.
public final class URLSessionLogTransport: NSObject, LogSinkTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    override public init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private static let maxAnswerBytes = 256 * 1024

    public func send(_ request: URLRequest) async throws -> LogSinkResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LogSinkError(message: "not an HTTP answer") }
        // An answer is a status and a short JSON body: a hostile ingestor cannot make this process buffer more than that.
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= Self.maxAnswerBytes { break }
        }
        return LogSinkResponse(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init), body: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
