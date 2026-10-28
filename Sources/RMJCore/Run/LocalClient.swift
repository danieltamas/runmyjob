import Darwin
import Foundation

/// A run on this Mac lives only as long as the `rmj run` client that started it: the client writes its pid next to the
/// log and removes the file when it settles the row. A row still open whose client is gone (killed, crashed, the Mac
/// restarted) is found by `isGone` and settled by the reconciler.
public enum LocalClient {
    static func file(_ id: String, in directory: URL) -> URL { directory.appendingPathComponent("\(id).client") }

    static func record(_ id: String, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file(id, in: directory).path, contents: Data("\(getpid())\n".utf8), attributes: [.posixPermissions: 0o600])
    }

    static func clear(_ id: String, in directory: URL) {
        try? FileManager.default.removeItem(at: file(id, in: directory))
    }

    /// True when no process answers to the pid on record, or none is on record.
    static func isGone(_ id: String, in directory: URL) -> Bool {
        guard let text = try? String(contentsOf: file(id, in: directory), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return true }
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}
