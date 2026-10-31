import Foundation

/// Generic passwords in the login keychain, shared by the app and the CLI, written and read through
/// `/usr/bin/security`. RMJ is ad hoc signed, so an item guarded by RMJ's own signature would ask again
/// after every update; `security` is an Apple binary whose signature never changes, and an item created
/// through it trusts it, so no build of RMJ is ever prompted. The same mechanism as any `security
/// add-generic-password` item. A secret is in the argument list of `security` for the instant a write
/// runs (a read returns it on stdout, never in an argument).
public struct Keychain: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case denied
        /// The tool's exit status. Nothing the tool printed is kept: its arguments hold the secret.
        case failed(OSStatus)

        public var description: String {
            switch self {
            case .denied: "keychain access needs the user's approval (macOS would show a prompt)"
            case .failed(let status): "the keychain tool failed with status \(status)"
            }
        }
    }

    /// `security` exit statuses: errSecItemNotFound and errSecInteractionNotAllowed.
    private static let notFound: Int32 = 44
    private static let interactionNotAllowed: Int32 = 36

    public let service: String
    private let tool: String
    private let timeout: Duration

    /// A process that cannot show the allow/deny dialog (the CLI, a script) gives a call 5 s before it
    /// counts as needing approval; the app, which can show it, waits for the user.
    public init(service: String = "ro.danieltamas.rmj", allowingPrompts: Bool = false, tool: String = "/usr/bin/security", timeout: Duration? = nil) {
        self.service = service
        self.tool = tool
        self.timeout = timeout ?? (allowingPrompts ? .seconds(60) : .seconds(5))
    }

    /// Replaces the item. `trusting` lists more executables that may read it without a prompt, on top of `security`.
    public func write(_ secret: String, account: String, trusting executables: [String] = []) throws {
        var arguments = ["add-generic-password", "-U", "-s", service, "-a", account, "-w", secret, "-T", tool]
        for path in executables { arguments += ["-T", path] }
        let result = try run(arguments)
        guard result.status == 0 else { throw Failure.failed(result.status) }
    }

    /// The secret, or nil when there is no such item.
    public func read(account: String) throws -> String? {
        let result = try run(["find-generic-password", "-s", service, "-a", account, "-w"])
        switch result.status {
        case 0:
            var secret = result.output
            if secret.hasSuffix("\n") { secret.removeLast() }
            return secret
        case Self.notFound:
            return nil
        case Self.interactionNotAllowed:
            throw Failure.denied
        default:
            if result.error.contains("User interaction is not allowed") { throw Failure.denied }
            throw Failure.failed(result.status)
        }
    }

    public func remove(account: String) throws {
        let result = try run(["delete-generic-password", "-s", service, "-a", account])
        guard result.status == 0 || result.status == Self.notFound else { throw Failure.failed(result.status) }
    }

    private struct Result { let status: Int32; let output: String; let error: String }

    /// One run of the tool with stdin closed. A run that outlasts the timeout is killed and counts as
    /// waiting for an approval nobody can give.
    private func run(_ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { throw Failure.failed(127) }
        // Our copies of the write ends are closed at once. Output is read only after the tool has exited, from what is
        // already in the pipes (a secret and a line of text): waiting for the end of the stream would also wait for any
        // other process that was started while these pipes were open and inherited them.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        if finished.wait(timeout: .now() + seconds) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); finished.wait() }
            throw Failure.denied
        }
        return Result(status: process.terminationStatus, output: Self.drain(out.fileHandleForReading), error: Self.drain(err.fileHandleForReading))
    }

    private static func drain(_ handle: FileHandle) -> String {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
