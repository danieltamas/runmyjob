import Foundation
import Testing
import RMJCore

struct LogSinkFormatAcceptanceTests {
    @Test func lokiRequestLabelsGroupingAndEscapedMessages() throws {
        var sink = sinkConfig(); sink.auth = .basic; sink.user = "owner"; sink.orgID = "org"
        let text = "quote \" newline\n caf\u{e9}"
        let entries = [sinkEntry(1, line: text), sinkEntry(2), sinkEntry(3, tenant: nil)]
        let request = try LogSinkFormat.request(sink: sink, secret: "token", entries: entries, host: "mac")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://logs.example.com/loki/api/v1/push")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("owner:token".utf8).base64EncodedString())
        #expect(request.value(forHTTPHeaderField: "X-Scope-OrgID") == "org")
        let body = try jsonObject(#require(request.httpBody))
        let streams = try #require(body["streams"] as? [[String: Any]])
        #expect(streams.count == 2)
        for tenant in ["a", "none"] {
            let stream = try #require(streams.first { ($0["stream"] as? [String: String])?["tenant"] == tenant })
            #expect(stream["stream"] as? [String: String] == ["app": "rmj", "tenant": tenant, "repo": "owner/repo", "destination": "ai-eu-1", "level": "info"])
            let values = try #require(stream["values"] as? [[String]])
            #expect(values.count == (tenant == "a" ? 2 : 1))
            let expected = tenant == "a" ? Array(entries.prefix(2)) : [entries[2]]
            for (value, entry) in zip(values, expected) {
                #expect(value[0] == "1700000000000000000")
                let line = try jsonObject(Data(value[1].utf8))
                #expect(line["job"] as? String == "job"); #expect(line["n"] as? Int == entry.n)
                #expect(line["msg"] as? String == entry.line)
                #expect(line["branch"] as? String == "main"); #expect(line["agent"] as? String == "terminal")
            }
        }
        var error = sinkEntry(4); error.level = .error
        let grouped = try LogSinkFormat.request(sink: sink, secret: "token", entries: entries + [error], host: "mac")
        #expect((try jsonObject(#require(grouped.httpBody))["streams"] as? [Any])?.count == 3)
    }

    @Test func datadogRequestFieldsSitesAndNilTenantTags() throws {
        var sink = sinkConfig(); sink.kind = .datadog; sink.url = nil; sink.auth = .apikey
        var second = sinkEntry(2, tenant: nil); second.branch = nil; second.agent = nil; second.level = .warn
        for site in [nil, "datadoghq.eu", "us3.datadoghq.com", "us5.datadoghq.com", "ap1.datadoghq.com"] as [String?] {
            sink.site = site
            let req = try LogSinkFormat.request(sink: sink, secret: "key", entries: [sinkEntry(), second], host: "mac")
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://http-intake.logs.\(site ?? "datadoghq.com")/api/v2/logs")
            #expect(req.value(forHTTPHeaderField: "DD-API-KEY") == "key")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let data = try #require(req.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            #expect(body.count == 2)
            for (i, item) in body.enumerated() {
                #expect(item["ddsource"] as? String == "rmj"); #expect(item["service"] as? String == "rmj")
                #expect(item["hostname"] as? String == "mac"); #expect(item["message"] as? String == "hello")
                #expect(item["timestamp"] as? Int64 == 1_700_000_000_000)
                #expect(item["job"] as? String == "job"); #expect(item["n"] as? Int == i + 1)
            }
            #expect(body[0]["status"] as? String == "info"); #expect(body[1]["status"] as? String == "warn")
            #expect(body[0]["ddtags"] as? String == "tenant:a,repo:owner/repo,destination:ai-eu-1,job:job,branch:main,agent:terminal")
            #expect(body[1]["ddtags"] as? String == "repo:owner/repo,destination:ai-eu-1,job:job")
        }
    }

    @Test func elasticsearchNDJSONStableIDsTimestampAndOptionalFields() throws {
        var sink = sinkConfig(); sink.kind = .elasticsearch; sink.auth = .apikey
        var entry = sinkEntry(); entry.time = Date(timeIntervalSince1970: 1_700_000_000.205)
        let req = try LogSinkFormat.request(sink: sink, secret: "key", entries: [entry], host: "mac")
        #expect(req.httpMethod == "POST"); #expect(req.url?.absoluteString == "https://logs.example.com/_bulk")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-ndjson")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "ApiKey key")
        let data = try #require(req.httpBody)
        #expect(data.last == 10)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2)
        let action = try jsonObject(Data(lines[0].utf8))
        #expect(action["create"] as? [String: String] == ["_index": "rmj-logs", "_id": "job-1"])
        let doc = try jsonObject(Data(lines[1].utf8))
        #expect(doc["@timestamp"] as? String == "2023-11-14T22:13:20.205Z")
        #expect(doc["message"] as? String == "hello"); #expect(doc["log.level"] as? String == "info")
        #expect(doc["service.name"] as? String == "rmj"); #expect(doc["host.name"] as? String == "mac")
        let rmj = try #require(doc["rmj"] as? [String: Any])
        #expect(rmj["job"] as? String == "job"); #expect(rmj["n"] as? Int == 1)
        for (key, value) in ["repo": "owner/repo", "destination": "ai-eu-1", "tenant": "a", "branch": "main", "agent": "terminal"] {
            #expect(rmj[key] as? String == value)
        }
        sink.index = "custom"; entry.tenant = nil; entry.branch = nil; entry.agent = nil
        let custom = try LogSinkFormat.request(sink: sink, secret: "key", entries: [entry], host: "mac")
        let customLines = String(decoding: try #require(custom.httpBody), as: UTF8.self).split(separator: "\n")
        #expect((try jsonObject(Data(customLines[0].utf8))["create"] as? [String: String])?["_index"] == "custom")
        let metadata = try #require(try jsonObject(Data(customLines[1].utf8))["rmj"] as? [String: Any])
        for key in ["tenant", "branch", "agent"] { #expect(metadata[key] == nil) }
    }

    @Test func allFormatsTruncateAtUTF8BoundaryAndEncodeDeterministically() throws {
        let text = String(repeating: "\u{e9}", count: 786_432)
        let expected = String(repeating: "\u{e9}", count: 524_288) + " ...[truncated]"
        #expect(LogSinkFormat.maxLineBytes == 1_048_576)
        for kind in [LogSinkConfig.Kind.loki, .datadog, .elasticsearch] {
            var sink = sinkConfig(); sink.kind = kind
            if kind == .datadog { sink.url = nil; sink.auth = .apikey }
            #expect(LogSinkFormat.maxBatch(kind) == 500)
            for line in ["quote \"\n caf\u{e9}", text] {
                let req = try LogSinkFormat.request(sink: sink, secret: "key", entries: [sinkEntry(line: line)], host: "mac")
                let again = try LogSinkFormat.request(sink: sink, secret: "key", entries: [sinkEntry(line: line)], host: "mac")
                #expect(req.httpBody == again.httpBody)
                let data = try #require(req.httpBody)
                let message: String?
                switch kind {
                case .loki:
                    let streams = try #require(try jsonObject(data)["streams"] as? [[String: Any]])
                    let values = try #require(streams[0]["values"] as? [[String]])
                    message = try jsonObject(Data(values[0][1].utf8))["msg"] as? String
                case .datadog:
                    let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                    message = rows[0]["message"] as? String
                case .elasticsearch:
                    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                    message = try jsonObject(Data(lines[1].utf8))["message"] as? String
                }
                #expect(message == (line == text ? expected : line))
            }
        }
    }

    @Test func authenticationHeadersAndMissingInputs() throws {
        for kind in [LogSinkConfig.Kind.loki, .elasticsearch] {
            for auth in [LogSinkConfig.Auth.none, .basic, .bearer] {
                var sink = sinkConfig(); sink.kind = kind; sink.auth = auth; sink.user = "u"
                let req = try LogSinkFormat.request(sink: sink, secret: "s", entries: [sinkEntry()], host: "mac")
                let expected: String? = auth == .none ? nil : auth == .basic ? "Basic dTpz" : "Bearer s"
                #expect(req.value(forHTTPHeaderField: "Authorization") == expected)
                if auth != .none {
                    #expect(throws: LogSinkError.self) { try LogSinkFormat.request(sink: sink, secret: nil, entries: [sinkEntry()], host: "mac") }
                }
            }
        }
        var sink = sinkConfig()
        #expect(throws: LogSinkError.self) { try LogSinkFormat.request(sink: sink, secret: nil, entries: [], host: "mac") }
        sink.url = nil
        #expect(throws: LogSinkError.self) { try LogSinkFormat.request(sink: sink, secret: nil, entries: [sinkEntry()], host: "mac") }
        for kind in [LogSinkConfig.Kind.datadog, .elasticsearch] {
            sink.kind = kind; sink.auth = .apikey; sink.url = kind == .datadog ? nil : "https://example.com"
            #expect(throws: LogSinkError.self) { try LogSinkFormat.request(sink: sink, secret: nil, entries: [sinkEntry()], host: "mac") }
        }
    }
}
