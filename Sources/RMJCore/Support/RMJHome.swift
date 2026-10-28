import Foundation

/// Everything RMJ keeps on this Mac: the history database, config and logs. `RMJ_HOME`
/// moves it, so a second instance shares nothing local with the first.
public struct RMJHome: Sendable {
    public let url: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if let path = environment["RMJ_HOME"], !path.isEmpty {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            url = homeDirectory.appendingPathComponent(".rmj", isDirectory: true)
        }
    }

    /// Mode 0700, also on a directory that already exists: history and logs are this user's alone.
    public func prepare() throws {
        let files = FileManager.default
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        // A link or another user's directory is not a private home, and chmod would follow it.
        // Validated and changed on one descriptor, so the path cannot be swapped in between.
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), fchmod(descriptor, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
