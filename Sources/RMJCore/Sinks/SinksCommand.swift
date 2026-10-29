import Foundation

/// `rmj sinks` lists the log sinks with what each has done; `rmj sinks test <id>` sends one line to one sink.
/// Adding a sink needs the app: a secret never goes on a command line.
public enum SinksCommand {
    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        let home = RMJHome(environment: environment)
        let loaded = LogSinkStore.load(home: home)
        for problem in loaded.problems { FileHandle.standardError.write(Data("rmj: \(problem)\n".utf8)) }
        switch arguments.first {
        case nil:
            print(list(loaded.sinks, home: home))
            return 0
        case "test" where arguments.count == 2:
            guard let sink = loaded.sinks.first(where: { $0.id == arguments[1] }) else {
                FileHandle.standardError.write(Data("rmj: no sink \"\(UntrustedText.clean(arguments[1], limit: 40))\" (see: rmj sinks)\n".utf8))
                return 1
            }
            let outcome = await LogSinkAdmin.sendTest(sink, secret: try? Keychain().read(account: sink.keychainAccount))
            print("\(sink.id): \(outcome.message)")
            return outcome.ok ? 0 : 1
        default:
            FileHandle.standardError.write(Data("usage: rmj sinks [test <id>]\n".utf8))
            return 2
        }
    }

    static func list(_ sinks: [LogSinkConfig], home: RMJHome, now: Date = Date()) -> String {
        guard !sinks.isEmpty else { return "no log sinks (add one in RMJ > Settings > Log streaming)" }
        let status = LogSinkStatusStore(home: home).read()
        return sinks.map { sink in
            let s = status.first { $0.id == sink.id } ?? LogSinkStatus(id: sink.id)
            let pending = LogSinkAdmin.spool(sink, home: home).pending()
            let state = !sink.enabled ? "paused" : s.authFailed ? "auth failed" : LogStreamIndicator.state(sinks: [sink], status: [s], now: now) == .failing ? "failing" : "streaming"
            var line = "\(sink.id)  \(sink.kind.rawValue)  \(state)  \(s.sent) sent, \(pending.lines) waiting"
            if s.rejected > 0 { line += ", \(s.rejected) rejected" }
            if s.dropped > 0 { line += ", \(s.dropped) dropped" }
            if let error = s.lastError, s.lastErrorAt.map({ $0 > (s.lastOK ?? .distantPast) }) ?? false { line += "  last error: \(UntrustedText.clean(error, limit: 120))" }
            return line
        }.joined(separator: "\n")
    }
}
