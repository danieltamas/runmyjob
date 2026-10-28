import Darwin
import Foundation

/// D7's fallback: when the CLI cannot read a Keychain item without the dialog only the app can
/// show, the app offers the value in a file that expires, and the CLI takes it once. The file
/// lives in the 0700 app home, is created mode 0600 without following links, and is deleted by
/// the first successful take or when found stale.
public struct PatHandoff: Sendable {
    public static let lifetime: TimeInterval = 60

    public enum Failure: Error, Equatable {
        case invalidAccount
        case cannotWrite(Int32)
    }

    private let home: RMJHome
    private let directory: URL

    public init(home: RMJHome) {
        self.home = home
        directory = home.url.appendingPathComponent("handoff", isDirectory: true)
    }

    public func offer(_ secret: String, account: String, now: Date = Date()) throws {
        let target = try file(for: account)
        let files = FileManager.default
        try home.prepare()
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        guard Self.isOwned(directory, as: S_IFDIR) else { throw Failure.cannotWrite(ENOTDIR) }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        sweepExpired(now: now)
        let staged = directory.appendingPathComponent(".\(UUID().uuidString)")
        let descriptor = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.cannotWrite(errno) }
        let written = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try written.write(contentsOf: Data("\(Int(now.timeIntervalSince1970))\n\(secret)".utf8))
            try written.close()
            guard rename(staged.path, target.path) == 0 else { throw Failure.cannotWrite(errno) }
            // While this process lives, the offer does not outlast its lifetime.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.lifetime + 1) { [self] in sweepExpired() }
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
    }

    /// Deletes every offer older than the lifetime, so a value nobody took does not stay on disk.
    public func sweepExpired(now: Date = Date()) {
        guard Self.isOwned(directory, as: S_IFDIR) else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let path = directory.appendingPathComponent(name)
            // Removed in place, never renamed away: a concurrent take must still find a live offer.
            if Self.age(of: path, now: now) > Self.lifetime { try? FileManager.default.removeItem(at: path) }
        }
    }

    /// An offer carries its own timestamp; anything else that lingers is judged by its age on disk.
    private static func age(of path: URL, now: Date) -> TimeInterval {
        if isOwned(path, as: S_IFREG), let data = FileManager.default.contents(atPath: path.path),
           let first = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first,
           let offered = TimeInterval(first) {
            return now.timeIntervalSince1970 - offered
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate]) as? Date
        return Date().timeIntervalSince(modified ?? .distantPast)
    }

    /// The offered value, once; nil when nothing was offered, or it was offered too long ago.
    public func take(account: String, now: Date = Date()) throws -> String? {
        let source = try file(for: account)
        sweepExpired(now: now)
        // Renaming is atomic, so of several processes taking at once exactly one gets the file.
        let claimed = directory.appendingPathComponent(".taken-\(UUID().uuidString)")
        guard rename(source.path, claimed.path) == 0 else { return nil }
        defer { try? FileManager.default.removeItem(at: claimed) }
        // A planted link, a pipe or another user's file is never read.
        // Validation and read share one descriptor, so the path cannot be swapped in between;
        // O_NONBLOCK keeps a pipe from blocking the open.
        let descriptor = open(claimed.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              let data = try? reader.readToEnd() else { return nil }
        let parts = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let offered = TimeInterval(parts[0]) else { return nil }
        let age = now.timeIntervalSince1970 - offered
        return (0...Self.lifetime).contains(age) ? String(parts[1]) : nil
    }

    /// Not a link, of the given type, and this user's: checked with lstat, which does not follow.
    /// For the directory; the file is checked on the descriptor it is read from.
    private static func isOwned(_ url: URL, as type: mode_t) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == type && info.st_uid == getuid()
    }

    /// The account names a file, so it is a plain token: no separators, no dots-only names.
    private func file(for account: String) throws -> URL {
        guard !account.isEmpty, account.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              account.contains(where: { $0.isLetter || $0.isNumber }) else { throw Failure.invalidAccount }
        return directory.appendingPathComponent(account)
    }
}
