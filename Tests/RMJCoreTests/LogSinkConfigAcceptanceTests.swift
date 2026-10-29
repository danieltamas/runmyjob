import Foundation
import Testing
import RMJCore

struct LogSinkConfigAcceptanceTests {
    @Test func validationAcceptsSecureAndPrivateURLs() throws {
        for host in ["https://example.com", "http://127.0.0.1:3100", "http://[::1]:3100", "http://localhost", "http://100.64.0.0", "http://100.127.255.255", "http://box.team.ts.net"] {
            for kind in [LogSinkConfig.Kind.loki, .elasticsearch] {
                var sink = sinkConfig(); sink.kind = kind; sink.url = host
                try sink.validate()
            }
        }
        var sink = sinkConfig(); sink.tenants = []; sink.all = true
        try sink.validate()
        for id in ["a", "0", String(repeating: "a", count: 32), "a-9"] {
            sink.id = id; try sink.validate()
        }
    }

    @Test func validationRejectsInvalidIDsNamesScopeAndURLs() {
        for id in ["", "A", "-a", "a_b", "a.b", String(repeating: "a", count: 33)] {
            var sink = sinkConfig(); sink.id = id
            #expect(throws: LogSinkError.self) { try sink.validate() }
        }
        var unnamed = sinkConfig(); unnamed.name = ""
        #expect(throws: LogSinkError.self) { try unnamed.validate() }
        var unscoped = sinkConfig(); unscoped.tenants = []
        #expect(throws: LogSinkError.self) { try unscoped.validate() }
        for url in [nil, "", "garbage", "https:///", "ftp://localhost", "http://example.com", "http://100.63.255.255", "http://100.128.0.0", "http://localhost.example.com", "https://u:p@example.com", "https://u@example.com"] as [String?] {
            for kind in [LogSinkConfig.Kind.loki, .elasticsearch] {
                var sink = sinkConfig(); sink.kind = kind; sink.url = url
                #expect(throws: LogSinkError.self) { try sink.validate() }
            }
        }
    }

    @Test func validationChecksProviderAuthenticationAndDatadogSites() throws {
        for kind in [LogSinkConfig.Kind.loki, .elasticsearch] {
            for auth in [LogSinkConfig.Auth.none, .basic, .bearer, .apikey] {
                var sink = sinkConfig(); sink.kind = kind; sink.auth = auth; sink.user = "owner"
                if kind == .loki && auth == .apikey {
                    #expect(throws: LogSinkError.self) { try sink.validate() }
                } else { try sink.validate() }
            }
            for user in [nil, ""] as [String?] {
                var sink = sinkConfig(); sink.kind = kind; sink.auth = .basic; sink.user = user
                #expect(throws: LogSinkError.self) { try sink.validate() }
            }
        }
        var dd = sinkConfig(); dd.kind = .datadog; dd.url = nil; dd.auth = .apikey
        for site in [nil, "datadoghq.com", "datadoghq.eu", "us3.datadoghq.com", "us5.datadoghq.com", "ap1.datadoghq.com"] as [String?] {
            dd.site = site; try dd.validate()
        }
        dd.site = "attacker.example"
        #expect(throws: LogSinkError.self) { try dd.validate() }
        dd.site = nil; dd.url = "https://example.com"
        #expect(throws: LogSinkError.self) { try dd.validate() }
        dd.url = nil
        for auth in [LogSinkConfig.Auth.none, .basic, .bearer] {
            dd.auth = auth; dd.user = "owner"
            #expect(throws: LogSinkError.self) { try dd.validate() }
        }
    }

    @Test func tenantScopeAndJSONRoundTrip() throws {
        var sink = sinkConfig()
        #expect(sink.accepts(tenant: "a")); #expect(!sink.accepts(tenant: "b")); #expect(!sink.accepts(tenant: nil))
        sink.all = true
        #expect(sink.accepts(tenant: nil)); #expect(sink.accepts(tenant: "b"))
        sink.orgID = "org"; sink.user = "owner"; sink.auth = .basic
        let data = try JSONEncoder().encode(sink)
        let object = try jsonObject(data)
        #expect(object["org_id"] as? String == "org")
        #expect(object["orgID"] == nil)
        #expect(try JSONDecoder().decode(LogSinkConfig.self, from: data) == sink)
        #expect(sink.keychainAccount == "rmj.sink.a")
    }

    @Test func storePreservesOtherKeysAndIsolatesBadEntries() throws {
        let f = try SinkFixture(); defer { f.remove() }
        #expect(LogSinkStore.load(home: f.home).sinks.isEmpty)
        let file = f.root.appendingPathComponent("config.json")
        try Data(#"{"notify_done":true,"custom":{"keep":7}}"#.utf8).write(to: file)
        try LogSinkStore.save([sinkConfig()], home: f.home)
        var object = try jsonObject(Data(contentsOf: file))
        #expect(object["notify_done"] as? Bool == true)
        #expect((object["custom"] as? [String: Int])?["keep"] == 7)
        #expect(LogSinkStore.load(home: f.home).sinks == [sinkConfig()])
        var entries = try #require(object["log_sinks"] as? [[String: Any]])
        var invalid = entries[0]; invalid["id"] = "bad-scope"; invalid["tenants"] = []
        entries.append(invalid); entries.append(["id": "bad-decode", "kind": "unknown"])
        object["log_sinks"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let loaded = LogSinkStore.load(home: f.home)
        #expect(loaded.sinks == [sinkConfig()])
        #expect(loaded.problems.contains { $0.contains("bad-scope") })
        #expect(loaded.problems.contains { $0.contains("bad-decode") })
        let before = try Data(contentsOf: file)
        #expect(throws: LogSinkError.self) { try LogSinkStore.save([sinkConfig(), sinkConfig()], home: f.home) }
        var bad = sinkConfig(); bad.name = ""
        #expect(throws: LogSinkError.self) { try LogSinkStore.save([bad], home: f.home) }
        #expect(try Data(contentsOf: file) == before)
        try Data(#"{"other":1}"#.utf8).write(to: file)
        #expect(LogSinkStore.load(home: f.home).sinks.isEmpty)
    }
}

// Shared fixtures use only the supplied public sink API.
struct SinkFixture {
    let root: URL
    let home: RMJHome
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-sinks-\(UUID().uuidString)")
        home = RMJHome(environment: ["RMJ_HOME": root.path])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
func sinkConfig(_ id: String = "a") -> LogSinkConfig {
    LogSinkConfig(id: id, kind: .loki, name: id, url: "https://logs.example.com/", tenants: ["a"])
}
let sinkEpoch = Date(timeIntervalSince1970: 1_700_000_000)
func sinkEntry(_ n: Int = 1, tenant: String? = "a", line: String = "hello") -> LogEntry {
    LogEntry(time: sinkEpoch, line: line, job: "job", n: n, repo: "owner/repo", tenant: tenant,
             branch: "main", agent: "terminal", destination: "ai-eu-1")
}
func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
func sinkMode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attrs[.posixPermissions] as? NSNumber).intValue & 0o777
}
