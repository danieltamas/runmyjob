import Foundation

/// The end of an archived log, cleaned for an agent: escapes and invisible characters gone, long lines cut.
enum AgentLog {
    struct Tail {
        var lines: [String]
        /// Something was cut: a long line, or the head of a log larger than the window.
        var truncated: Bool
    }

    static let lineLimit = 4000
    /// Only this much of the end of a log is read, whatever its size.
    static let window = 8 * 1024 * 1024
    static let marker = " [rmj: line truncated]"

    static func tail(of file: URL, lines count: Int) -> Tail? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var sanitizer = LogSanitizer()
        let text = String(decoding: sanitizer.clean(data), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") || text.isEmpty { lines.removeLast() }
        // The window began inside a line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        // Dropping the head of a long log, or the start of a line, is a cut too.
        var cut = start > 0
        let kept = lines.suffix(count).map { line -> String in
            let clean = UntrustedText.clean(line, limit: lineLimit + 1)
            guard clean.unicodeScalars.count > lineLimit else { return clean }
            cut = true
            return String(String.UnicodeScalarView(clean.unicodeScalars.prefix(lineLimit))) + marker
        }
        return Tail(lines: kept, truncated: cut)
    }

    /// The archive's file for a log, only when it lies inside the log folder.
    static func file(for entry: LogArchiveEntry, in archive: LogArchive) -> URL? {
        guard let path = entry.path else { return nil }
        let folder = archive.directory.resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return resolved.path.hasPrefix(folder + "/") ? resolved : nil
    }
}
