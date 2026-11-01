import Foundation

/// What a caller hands an agent run besides the checkout (`--attach`), and what it gets back (`--json`).
extension AgentSession {
    /// A directory of the Mac made readable inside the container at the path it has on the Mac.
    struct Attachment: Equatable, Sendable {
        let boxDirectory: String
        let path: String
    }

    /// Together the attachments may not outgrow this; the check is on the Mac, before anything is sent.
    static let attachmentLimit = 50 * 1024 * 1024

    static func mounts(_ attachments: [Attachment]) -> [String] {
        attachments.flatMap { ["-v", "\($0.boxDirectory):\($0.path):ro"] }
    }

    /// The logical size of every regular file under the directories; symlinks are not followed. A directory that cannot be read
    /// completely counts as over the limit, so a partial scan never approves a transfer.
    static func size(of directories: [String]) -> Int {
        var total = 0
        for directory in directories {
            var complete = true
            guard let files = FileManager.default.enumerator(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                             errorHandler: { _, _ in complete = false; return false }) else { return .max }
            while let url = files.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else { return .max }
                if values.isRegularFile == true { total += values.fileSize ?? 0 }
            }
            if !complete { return .max }
        }
        return total
    }

    /// Sends each attachment to the box; what the box answers is mounted, so only the directory this job owns is accepted.
    static func send(_ attachments: [String], ulid: String, client: BoxClient) async throws -> [Attachment] {
        var sent = [Attachment]()
        for (index, path) in attachments.enumerated() {
            let directory = try await client.sendAttachment(ulid: ulid, index: index, from: path)
            guard directory.hasPrefix("/"), directory.hasSuffix("/rx/.attach/\(ulid)/\(index)"), !directory.split(separator: "/").contains(".."),
                  directory.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }) else {
                throw BoxFailure("the box answered with an unexpected attachment directory")
            }
            sent.append(Attachment(boxDirectory: directory, path: path))
        }
        return sent
    }
}

/// Whether what was written so far ends a line (or is empty), for a caller that appends its own line.
final class LastByte: @unchecked Sendable {
    private let lock = NSLock()
    private var last: UInt8 = 10

    func add(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if let byte = chunk.last { last = byte }
    }

    var endsLine: Bool {
        lock.lock(); defer { lock.unlock() }
        return last == 10
    }
}

/// The `final` of a `--json` result: what the harness answered, as the user would read it.
enum FinalText {
    /// Escapes and invisible characters gone, known secrets redacted, at most 64 KiB.
    static func clean(_ text: String, secrets: [String]) -> String {
        var sanitizer = LogSanitizer()
        let plain = String(decoding: sanitizer.clean(Data(text.utf8)), as: UTF8.self)
        return AgentRunCommand.bounded(SecretRedactor.scrub(plain, secrets: secrets))
    }

    /// A local run's stdout, trimmed; nil when it printed nothing.
    static func local(_ stdout: Data, secrets: [String]) -> String? {
        let text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : clean(text, secrets: secrets)
    }
}
