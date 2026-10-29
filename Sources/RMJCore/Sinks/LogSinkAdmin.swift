import Foundation
import Security

/// What the Settings pane and `rmj sinks` do to a sink beyond streaming: the test line, the secret, clearing the spool.
public enum LogSinkAdmin {
    /// One line to the sink, answered in words: what the ingestor said.
    public static func sendTest(_ sink: LogSinkConfig, secret: String?, transport: LogSinkTransport = URLSessionLogTransport(),
                                host: String = LogStreamer.hostName, now: Date = Date()) async -> (ok: Bool, message: String) {
        let entry = LogEntry(time: now, line: "RMJ test line: log streaming to \(sink.name) works", job: "rmj-test", n: 1, repo: "rmj",
                             tenant: sink.all ? nil : sink.tenants.first, destination: "local")
        do {
            let response = try await transport.send(LogSinkFormat.request(sink: sink, secret: secret, entries: [entry], host: host))
            switch response.status {
            case 200..<300:
                if sink.kind == .elasticsearch, (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["errors"] as? Bool == true {
                    return (false, "HTTP \(response.status), but the bulk request reported item errors")
                }
                return (true, "accepted (HTTP \(response.status))")
            case 401, 403: return (false, "rejected the credentials (HTTP \(response.status))")
            default: return (false, "HTTP \(response.status)")
            }
        } catch {
            return (false, UntrustedText.clean(String(describing: error), limit: 200))
        }
    }

    /// The secret goes to the Keychain; the CLI may read it without a prompt so a run from a terminal can stream.
    public static func saveSecret(_ secret: String, for sink: LogSinkConfig, home: RMJHome, keychain: Keychain = Keychain()) throws {
        let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/rmj").path
        try keychain.write(secret, account: sink.keychainAccount, trusting: isTrustedCLI(cli) ? [cli] : [])
        LogSinkStore.markChanged(home: home)
    }

    /// The CLI gets read access to the secret only when it is a signed binary, unchanged since signing, that is yours
    /// and that nobody else can write to. Anything else is left out: the run then asks for the Keychain's permission.
    static func isTrustedCLI(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil, nil) == errSecSuccess
    }

    public static func spool(_ sink: LogSinkConfig, home: RMJHome) -> LogSpool {
        LogSpool(directory: LogShipper.spoolDirectory(root: home.url.appendingPathComponent("spool", isDirectory: true), sinkID: sink.id))
    }

    /// Throws away what has not been sent yet (and the files set aside).
    public static func discardWaiting(_ sink: LogSinkConfig, home: RMJHome) throws {
        try spool(sink, home: home).clear()
        try LogSinkStatusStore(home: home).modify(id: sink.id) { $0.waitingFiles = 0; $0.waitingLines = 0; $0.oldestWaiting = nil }
    }

    /// Takes the sink out of the config and deletes its spool, status and secret.
    public static func remove(_ sink: LogSinkConfig, home: RMJHome, keychain: Keychain = Keychain()) throws {
        try LogSinkStore.save(LogSinkStore.load(home: home).sinks.filter { $0.id != sink.id }, home: home)
        try? FileManager.default.removeItem(at: LogShipper.spoolDirectory(root: home.url.appendingPathComponent("spool", isDirectory: true), sinkID: sink.id))
        try LogSinkStatusStore(home: home).remove(id: sink.id)
        try? keychain.remove(account: sink.keychainAccount)
    }
}
