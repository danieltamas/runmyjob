import Foundation
import os

/// The one way RMJ starts a process: an argv array, never a shell, and a timeout.
public struct ProcessRunner: Sendable {
    private static let log = Logger(subsystem: "ro.danieltamas.rmj", category: "process")

    public enum Failure: Error, LocalizedError, Equatable {
        case timedOut

        public var errorDescription: String? { "The command did not finish in time and was stopped." }
    }

    /// What `run` keeps of a child's output; a streaming `output` callback still sees all of it.
    public static let collectedLimit = 16 * 1024 * 1024

    public init() {}

    /// A non-zero exit is returned, not thrown: what it means is the caller's call. `environment`
    /// is added to this process's own. `started` gets the child's process group as it starts;
    /// `output` gets each chunk of stdout and stderr as it is read (`collectStdout: false` keeps none of stdout in memory, for
    /// a session that streams for days), so a run that is stopped
    /// still shows how far it got.
    public func run(_ executable: String, _ arguments: [String], in directory: URL? = nil,
                    environment: [String: String] = [:], input: Data? = nil, timeout: Duration, collectStdout: Bool = true,
                    started: (@Sendable (Int32) -> Void)? = nil,
                    output: (@Sendable (Data) -> Void)? = nil) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let (exits, exited) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exited.finish() }
        // Logged before it runs, so a command that hangs or fails is named in the log. The program is
        // public; its arguments stay private, since a caller may pass a path or process text.
        Self.log.info("run \(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .private) timeout \(timeout.description, privacy: .public)")
        try process.run()
        started?(process.processIdentifier)
        if let stdin, let input {
            // Written off the cooperative pool: a child that does not read blocks the write.
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }

        // Foundation starts the child as the leader of its own process group, so signalling the
        // group also reaches grandchildren (a test runner's workers) that would keep the pipes
        // open, even after the child itself has exited: the group id lives while any member does.
        let group = -process.processIdentifier
        let signal: @Sendable (Int32) -> Void = { kill(group, $0) }
        // The watchdog runs until the pipes close, not only until the child exits, so a
        // grandchild holding them is stopped at the deadline too. It answers whether it fired.
        let watchdog = Task { () -> Bool in
            do { try await Task.sleep(for: timeout) } catch { return false }
            Self.log.error("timeout: stopping \(executable, privacy: .public) after \(timeout.description, privacy: .public)")
            signal(SIGTERM)
            // Not cancellable and awaited: a grandchild that closed the pipes and ignores SIGTERM
            // is killed before the timeout is reported, also when the caller exits right after.
            await withCheckedContinuation { done in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    signal(SIGKILL)
                    done.resume()
                }
            }
            return true
        }
        return try await withTaskCancellationHandler {
            // Both pipes drain while the child runs: a child that fills one 64 KB pipe buffer
            // while nobody reads it never exits.
            async let out = Self.drain(stdout.fileHandleForReading, output, keep: collectStdout)
            async let err = Self.drain(stderr.fileHandleForReading, output, keep: true)
            let (outData, errData) = await (out, err)
            for await _ in exits {}
            watchdog.cancel()
            // A child that handles SIGTERM and exits 0 still ran past its deadline.
            if await watchdog.value { throw Failure.timedOut }
            try Task.checkCancellation()
            return ProcessOutput(status: process.terminationStatus, stdout: outData,
                                 stderr: String(decoding: errData, as: UTF8.self))
        } onCancel: {
            signal(SIGKILL)
        }
    }

    /// Reads on a dispatch thread, not the cooperative pool, since reading blocks until EOF.
    private static func drain(_ handle: FileHandle, _ output: (@Sendable (Data) -> Void)?, keep: Bool) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var data = Data()
                var open = true
                // `availableData` returns what a pipe holds now and is empty only at EOF. Reading continues
                // past the cap so the child never blocks on a full pipe, but nothing more is kept.
                // Each chunk is an autoreleased NSData and a dispatch thread drains its pool only when this
                // block returns, so without a pool per read a stream that runs for days keeps every chunk.
                while open {
                    autoreleasepool {
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { open = false; return }
                        output?(chunk)
                        if keep, data.count < collectedLimit { data.append(chunk.prefix(collectedLimit - data.count)) }
                    }
                }
                continuation.resume(returning: data)
            }
        }
    }
}

public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public init(status: Int32, stdout: Data, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}
