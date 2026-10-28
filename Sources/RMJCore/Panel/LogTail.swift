import Foundation

/// The last lines of a job's archived log, for the expanded row: escapes and invisible characters are stripped.
public enum LogTail {
    public enum Result: Sendable, Equatable {
        case lines([String])
        /// `pending` or `unavailable: <reason>`: the log is not on this Mac.
        case note(String)
    }

    public static let maxLines = 40
    /// Only the end of a large log is read.
    static let window = 64 * 1024

    /// Where a job's log may be: the box's and GitHub's copy, then the one a local run writes (side `mac`); a running log is `.part`.
    public static func candidates(jobID: String, home: RMJHome) -> [URL] {
        let logs = home.url.appendingPathComponent("logs")
        return ["\(jobID).log", "\(jobID).mac.log", "\(jobID).log.part", "\(jobID).mac.log.part"].map { logs.appendingPathComponent($0) }
    }

    /// The finished log of a job on this Mac, when there is one.
    public static func archived(jobID: String, home: RMJHome) -> URL? {
        candidates(jobID: jobID, home: home).first { !$0.lastPathComponent.hasSuffix(".part") && FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func read(jobID: String, home: RMJHome, lines: Int = maxLines) -> Result {
        for url in candidates(jobID: jobID, home: home) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > UInt64(window) ? size - UInt64(window) : 0)
            var sanitizer = LogSanitizer()
            let clean = String(decoding: sanitizer.clean((try? handle.readToEnd()) ?? Data()), as: UTF8.self)
            return .lines(Array(clean.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines + 1).dropLast(clean.hasSuffix("\n") ? 1 : 0).suffix(lines)).map(String.init))
        }
        return .note("pending")
    }
}
