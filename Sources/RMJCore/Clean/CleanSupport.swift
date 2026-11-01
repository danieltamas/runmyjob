import Foundation

/// What walking one tree found. Links are measured as links and never followed, so a link out of
/// a candidate neither adds the target's bytes nor keeps the candidate alive.
struct TreeMeasure {
    var bytes = 0
    var newest = Date.distantPast
    var unreadable = false

    init(path: String) {
        var pending = [path]
        while let current = pending.popLast() {
            var info = stat()
            guard lstat(current, &info) == 0 else { unreadable = true; continue }
            let kind = info.st_mode & mode_t(S_IFMT)
            // A link is not content: only what the tree itself holds shows it in use.
            if kind != mode_t(S_IFLNK) {
                newest = max(newest, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9))
            }
            guard kind == mode_t(S_IFDIR) else { bytes += Int(info.st_size); continue }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current) else { unreadable = true; continue }
            pending.append(contentsOf: names.map { current + "/" + $0 })
        }
    }

    /// nil when nothing is at `path`; links are reported as links.
    static func kind(of path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & mode_t(S_IFMT) : nil
    }

    /// Device and inode: the same pair later means the same directory.
    static func identity(of path: String) -> String? {
        var info = stat()
        return lstat(path, &info) == 0 ? "\(info.st_dev):\(info.st_ino)" : nil
    }

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Whether a process has a candidate as its working directory or runs a program from it. One `lsof`
/// answers for the whole run; if it cannot, everything counts as in use.
actor BusyProbe {
    private let override: (@Sendable (String) async -> Bool)?
    private var loaded = false
    private var held: [String]?

    init(_ override: (@Sendable (String) async -> Bool)?) { self.override = override }

    func isBusy(_ path: String) async -> Bool {
        if let override { return await override(path) }
        if !loaded {
            loaded = true
            let output = try? await ProcessRunner().run("/usr/sbin/lsof", ["-nP", "-d", "cwd,txt", "-Fn"], timeout: .seconds(120))
            // lsof exits 1 when it could not see some processes; above that it did not work.
            if let output, output.status <= 1, !output.stdout.isEmpty {
                held = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
            }
        }
        guard let held else { return true }
        let real = TreeMeasure.canonical(path)
        return held.contains { $0 == path || $0 == real || $0.hasPrefix(path + "/") || $0.hasPrefix(real + "/") }
    }
}

/// `~/.rmj/logs/clean.log`: one tab-separated line per item, written after its outcome, plus
/// `clean.pending`, which names the path before each removal so a crash in the middle is found next run.
struct CleanLog: Sendable {
    static let fileName = "clean.log"
    static let pendingName = "clean.pending"
    static let lockName = "clean.lock"
    let directory: URL
    var file: URL { directory.appendingPathComponent(Self.fileName) }
    var pending: URL { directory.appendingPathComponent(Self.pendingName) }

    /// A descriptor on `path` that never follows a link, created private; nil when that is not possible.
    private func descriptor(_ path: String, flags: Int32) -> Int32? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // O_CLOEXEC: a child started meanwhile (git, lsof) must not inherit the lock and keep it past the run.
        let fd = open(path, flags | O_NOFOLLOW | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { close(fd); return nil }
        return fd
    }

    /// The exclusive hold on the cleaner for one run; the caller closes the descriptor. nil when another run has it.
    func lock() -> Int32? { try? acquire() }

    func acquire() throws -> Int32 {
        guard let fd = descriptor(directory.appendingPathComponent(Self.lockName).path, flags: O_RDWR) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSLocalizedDescriptionKey: "cannot open \(Self.lockName) (errno \(errno))"])
        }
        // A process forked elsewhere in this one holds a copy of the descriptor until it execs, so a busy lock is retried briefly.
        for _ in 0..<100 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            guard errno == EWOULDBLOCK else { break }
            usleep(20_000)
        }
        let code = errno
        close(fd)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSLocalizedDescriptionKey: "flock errno \(code)"])
    }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func append(_ fields: [String], at date: Date) throws {
        guard let fd = descriptor(file.path, flags: O_WRONLY | O_APPEND) else { throw CocoaError(.fileWriteNoPermission) }
        // Closed here, not on deallocation: a late close of a reused descriptor number would hit another file.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { close(fd) }
        let line = ([Self.stamp(date)] + fields.map { UntrustedText.clean($0) }).joined(separator: "\t") + "\n"
        try handle.write(contentsOf: Data(line.utf8))
    }

    func markPending(run: String, path: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("\(run)\t\(UntrustedText.clean(path))\n".utf8).write(to: pending, options: .atomic)
    }

    func clearPending() { try? FileManager.default.removeItem(at: pending) }

    /// A marker left by a run that died between starting a removal and recording it.
    func recoverPending(at date: Date) throws {
        guard let text = try? String(contentsOf: pending, encoding: .utf8) else { return }
        let parts = text.trimmingCharacters(in: .newlines).split(separator: "\t", maxSplits: 1).map(String.init)
        try append([parts.first ?? "unknown", "interrupted", "unknown", "0", parts.count > 1 ? parts[1] : "", "the run ended before this removal was recorded"], at: date)
        clearPending()
    }

    /// Lines older than `cutoff` go; the format puts the sortable timestamp first.
    func prune(before cutoff: Date) {
        // Rewriting the file while a run appends to it would lose lines; a busy cleaner is pruned next time.
        guard FileManager.default.fileExists(atPath: file.path), let held = lock() else { return }
        defer { close(held) }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let limit = Self.stamp(cutoff)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.filter { $0.prefix(limit.count) >= limit }
        guard kept.count < lines.count else { return }
        try? Data((kept.map(String.init).joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).utf8).write(to: file, options: .atomic)
    }
}
