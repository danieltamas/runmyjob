import Foundation

extension LogStreamer {
    /// `job<TAB>step<TAB>2026-10-29T08:32:43.0537729Z text`, the shape of `gh run view --log`.
    private static let githubLine = try! NSRegularExpression(pattern: "^[^\\t]*\\t[^\\t]*\\t(\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\d)(?:\\.(\\d{1,9}))?Z ?(.*)$")

    /// A GitHub job's archived log, sent once with GitHub's own timestamps. The archive was redacted when it was written.
    public func shipArchived(_ job: JobRecord, document: LogDocument) {
        guard sinks.contains(where: { $0.accepts(tenant: job.tenant) }) else { return }
        let shipper = LogShipper(sinks: sinks, spoolRoot: home.url.appendingPathComponent("spool", isDirectory: true), secrets: sinkSecrets)
        let formatter = ISO8601DateFormatter()
        var entries: [LogEntry] = []
        for line in document.lines {
            var text = line.text
            var time = job.endedAt ?? job.queuedAt
            let range = NSRange(text.startIndex..., in: text)
            if let match = Self.githubLine.firstMatch(in: text, range: range), let stamp = Range(match.range(at: 1), in: text),
               let date = formatter.date(from: String(text[stamp]) + "Z"), let body = Range(match.range(at: 3), in: text) {
                let fraction = Range(match.range(at: 2), in: text).map { Double("0." + text[$0]) ?? 0 } ?? 0
                time = date.addingTimeInterval(fraction)
                text = String(text[body])
            }
            entries.append(LogEntry(time: time, line: text, level: Self.level(line.kind), job: job.id, n: line.number, repo: job.repo, tenant: job.tenant,
                                    branch: job.branch, agent: job.agent, destination: "github"))
        }
        write(entries, with: shipper)
    }

    static func level(_ kind: LogLine.Kind) -> LogEntry.Level {
        switch kind {
        case .error: .error
        case .warning: .warn
        default: .info
        }
    }
}
