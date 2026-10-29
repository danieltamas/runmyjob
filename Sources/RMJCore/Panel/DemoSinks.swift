import Foundation

extension DemoShots {
    /// Three sinks for the Log streaming screenshot: one healthy, one holding a short backlog, one failing.
    public static var logSinks: [(sink: LogSinkConfig, status: LogSinkStatus, pending: LogSpool.Pending)] {
        let now = Date()
        return [
            (LogSinkConfig(id: "team-loki", kind: .loki, name: "Team Loki", url: "https://loki.example.com", tenants: ["acme"], auth: .basic, user: "rmj"),
             LogSinkStatus(id: "team-loki", sent: 18_412, lastOK: now.addingTimeInterval(-2)),
             LogSpool.Pending(files: 0, lines: 0, bytes: 0, oldest: nil)),
            (LogSinkConfig(id: "datadog-eu", kind: .datadog, name: "Datadog EU", site: "datadoghq.eu", tenants: ["globex"], auth: .apikey),
             LogSinkStatus(id: "datadog-eu", sent: 2_977, lastOK: now.addingTimeInterval(-1)),
             LogSpool.Pending(files: 1, lines: 34, bytes: 9_800, oldest: now.addingTimeInterval(-3))),
            (LogSinkConfig(id: "search", kind: .elasticsearch, name: "Search cluster", url: "http://100.64.12.5:9200", all: true, auth: .apikey),
             LogSinkStatus(id: "search", sent: 905, waitingFiles: 3, waitingLines: 412, oldestWaiting: now.addingTimeInterval(-400),
                           lastOK: now.addingTimeInterval(-410), lastError: "HTTP 503", lastErrorAt: now.addingTimeInterval(-20)),
             LogSpool.Pending(files: 3, lines: 412, bytes: 120_000, oldest: now.addingTimeInterval(-400))),
        ]
    }
}
