import Foundation

/// Commands and file copies on a destination, over the verified tailnet address. Fakes stand in for it in tests.
public protocol OpsShell: Sendable {
    /// Runs `script` with `sh -c` on the destination; `input` goes to its stdin (secrets travel that way, never in argv).
    func run(_ script: String, input: Data?, timeout: Duration) async throws -> ProcessOutput
    /// Mirrors a local directory into `remote` (rsync, same ssh options). `.env` is never sent or deleted by it.
    func sync(directory: URL, to remote: String) async throws
}

public struct SSHOpsShell: OpsShell {
    public let address: String
    public let alias: String
    private let runner = ProcessRunner()

    public init(address: String, alias: String) {
        self.address = address
        self.alias = alias
    }

    public func run(_ script: String, input: Data?, timeout: Duration) async throws -> ProcessOutput {
        let arguments = try SSH.arguments(address: address, alias: alias, command: ["sh", "-c", SSH.quote(script)])
        return try await runner.run("/usr/bin/ssh", arguments, input: input, timeout: timeout)
    }

    public func sync(directory: URL, to remote: String) async throws {
        guard let rsync = TreeSync.rsyncPath() else { throw TreeSync.Failure.noRsync }
        // rsync hands the path to the remote shell: only plain path characters are allowed.
        guard remote.hasPrefix("/"), remote.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/_.-".contains($0)) }), !remote.contains("..") else {
            throw TreeSync.Failure.rsyncFailed(2, "unsafe remote path")
        }
        // rsync creates only the last path component: a new box has no `<home>/infra` yet.
        let made = try await run("mkdir -p \(SSH.quote(remote))", input: nil, timeout: .seconds(30))
        guard made.status == 0 else {
            throw TreeSync.Failure.rsyncFailed(made.status, UntrustedText.clean(made.stderr.split(separator: "\n").first.map(String.init) ?? "mkdir failed", limit: 200))
        }
        let arguments = ["-az", "--delete", "--filter", "P .env", "--exclude", ".env", "-e", try SSH.rsyncShell(address: address, alias: alias),
                         directory.path + "/", "\(alias):\(remote)/"]
        let output = try await runner.run(rsync, arguments, timeout: .seconds(600))
        guard output.status == 0 else {
            throw TreeSync.Failure.rsyncFailed(output.status, UntrustedText.clean(output.stderr.split(separator: "\n").first.map(String.init) ?? "", limit: 200))
        }
    }
}
