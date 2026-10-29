import Foundation
import CryptoKit

/// `BoxClient` over ssh and rsync, talking to `rx-run.sh` on the box.
public struct SSHBoxClient: BoxClient {
    public let address: String
    public let alias: String
    public let home: String
    private let runner = ProcessRunner()

    public init(address: String, alias: String, home: String) {
        self.address = address
        self.alias = alias
        self.home = home
    }

    private var script: String { "\(home)/rx/.bin/rx-run.sh" }

    private func ssh(_ words: [String], input: Data? = nil, timeout: Duration = .seconds(60),
                     output: (@Sendable (Data) -> Void)? = nil) async throws -> ProcessOutput {
        let arguments = try SSH.arguments(address: address, alias: alias, command: words.map(SSH.quote))
        return try await runner.run("/usr/bin/ssh", arguments, input: input, timeout: timeout, output: output)
    }

    private func box(_ words: [String], timeout: Duration = .seconds(60), output: (@Sendable (Data) -> Void)? = nil) async throws -> ProcessOutput {
        try await ssh([script] + words, timeout: timeout, output: output)
    }

    private func put(_ content: String, to path: String, mode: String = "755") async throws {
        let wanted = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        let have = try await ssh(["sh", "-c", "sha256sum \(SSH.quote(path)) 2>/dev/null | cut -d' ' -f1"])
        if have.status == 0, String(decoding: have.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == wanted { return }
        let directory = (path as NSString).deletingLastPathComponent
        let staging = SSH.quote("\(path).new.\(UUID().uuidString)")
        let shell = "mkdir -p \(SSH.quote(directory)) && cat > \(staging) && chmod \(mode) \(staging) && mv \(staging) \(SSH.quote(path))"
        let written = try await ssh(["sh", "-c", shell], input: Data(content.utf8))
        guard written.status == 0 else { throw BoxFailure("cannot write \(path) on the box (exit \(written.status))") }
    }

    public func prepare(_ job: BoxJob) async throws {
        try await put(BoxAssets.script, to: script)
        if let prelude = job.prelude { try await put(prelude.content, to: prelude.path, mode: "644") }
    }

    public func begin(_ job: BoxJob, waiting: @escaping @Sendable (String) -> Void) async throws {
        let collected = LineCollector()
        let output = try await box(["begin", job.ulid, job.worktree, job.directory] + job.locks, timeout: .seconds(7 * 3600)) { chunk in
            for line in collected.add(chunk) where line.hasPrefix("waiting for ") {
                waiting(UntrustedText.clean(String(line.dropFirst("waiting for ".count)), limit: 64))
            }
        }
        guard output.status == 0, String(decoding: output.stdout, as: UTF8.self).contains("locked") else {
            if output.status == 4 { throw BoxFailure("cancelled") }
            if output.status == 5 { throw BoxFailure("the box could not take the lock") }
            throw BoxFailure("box did not take the lock (exit \(output.status))")
        }
    }

    public func sync(_ job: BoxJob) async throws {
        try await TreeSync.run(worktree: URL(fileURLWithPath: job.worktree), destination: "\(alias):\(job.directory)/",
                               shell: try SSH.rsyncShell(address: address, alias: alias))
    }

    public func go(_ job: BoxJob) async throws -> BoxLaunch {
        let argv = String(decoding: try JSONSerialization.data(withJSONObject: job.argv), as: UTF8.self)
        let output = try await box(["go", job.ulid, job.name, argv, "--"] + job.options + [job.image] + job.argv,
                                   timeout: .seconds(90))
        let line = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        guard let launch = BoxLaunch.parse(line) else { throw BoxFailure("no launch record (exit \(output.status))") }
        return launch
    }

    public func tail(_ job: BoxJob, output: @escaping @Sendable (Data) -> Void) async throws {
        // The exit status of this ssh is not the command's: the record is read afterwards.
        let result = try await box(["tail", job.ulid], timeout: .seconds(14 * 86400), output: output)
        guard result.status != 255 else { throw BoxFailure("connection to the box dropped") }
    }

    public func record(ulid: String) async throws -> BoxRecord {
        let result = try await box(["job", ulid])
        guard result.status == 0, let record = BoxRecord.parse(String(decoding: result.stdout, as: UTF8.self)) else {
            throw BoxFailure("no answer from the box (exit \(result.status))")
        }
        return record
    }

    public func pullLog(ulid: String, output: @escaping @Sendable (Data) -> Void) async throws {
        let result = try await box(["log", ulid], timeout: .seconds(600), output: output)
        guard result.status == 0 else { throw BoxFailure("cannot read the log (exit \(result.status))") }
    }

    public func load(ulid: String) async -> JobLoad? {
        guard let result = try? await box(["stats", ulid], timeout: .seconds(20)), result.status == 0 else { return nil }
        return BoxLoad.parse(String(decoding: result.stdout, as: UTF8.self))
    }

    public func cancel(ulid: String) async throws {
        let result = try await box(["cancel", ulid])
        guard result.status == 0 else { throw BoxFailure("cancel failed (exit \(result.status))") }
    }
}

public struct SSHBoxFactory: BoxFactory {
    public init() {}
    public func client(destination: String, address: String, config: DestinationConfig) -> BoxClient {
        SSHBoxClient(address: address, alias: config.sshAlias, home: config.home)
    }
}

public struct BoxFailure: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Splits streamed bytes into lines, whatever the chunking.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func add(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        var lines = [String]()
        while let newline = buffer.firstIndex(of: 10) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return lines
    }
}
