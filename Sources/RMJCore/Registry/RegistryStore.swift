import Foundation

/// `<home>/registry`: the last accepted app list exactly as read, when it was read, and the icons fetched for it.
/// The bytes are kept unchanged so a relaunch validates them again and counts left-out entries the same way.
public struct RegistryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var file: URL { directory.appendingPathComponent("apps.json") }
    private var readAtFile: URL { directory.appendingPathComponent("read-at") }

    public func save(_ data: Data, readAt: Date) throws {
        try prepare(directory)
        try write(data, to: file)
        try write(Data(String(readAt.timeIntervalSince1970).utf8), to: readAtFile)
    }

    public func load() -> (data: Data, readAt: Date)? {
        guard let data = try? Data(contentsOf: file),
              let stamp = try? String(contentsOf: readAtFile, encoding: .utf8),
              let seconds = TimeInterval(stamp.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return (data, Date(timeIntervalSince1970: seconds))
    }

    public func saveIcon(_ data: Data, path: String) throws {
        guard let url = iconFile(path) else { throw CocoaError(.fileWriteInvalidFileName) }
        try prepare(url.deletingLastPathComponent())
        try write(data, to: url)
    }

    public func icon(path: String) -> Data? {
        iconFile(path).flatMap { try? Data(contentsOf: $0) }
    }

    /// Only `icons/<name>.png`: a path from the network never names a file outside the store.
    private func iconFile(_ path: String) -> URL? {
        RegistryRules.isIconPath(path) ? directory.appendingPathComponent(path) : nil
    }

    /// The store's folders, mode 0700. A symlink in their place is refused: a network icon path must not be written through one.
    private func prepare(_ url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        for folder in [directory, url] {
            guard (try manager.attributesOfItem(atPath: folder.path))[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Written to a private temporary file (mode 0600 from creation), then renamed over the target.
    private func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

public enum RegistryIcon {
    public static let maxBytes = 65_536

    /// A PNG whose header says 256 x 256, at most 64 KiB: what the registry's own check lets in.
    public static func accepts(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(24))
        guard data.count <= maxBytes, bytes.count == 24,
              bytes[0 ..< 8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              bytes[12 ..< 16].elementsEqual([0x49, 0x48, 0x44, 0x52]) else { return false }
        let width = bytes[16 ..< 20].reduce(0) { $0 << 8 | UInt32($1) }
        let height = bytes[20 ..< 24].reduce(0) { $0 << 8 | UInt32($1) }
        return width == 256 && height == 256
    }
}

public enum RegistryRefresh {
    public static let interval: TimeInterval = 3_600

    /// Opening the pane reads at most hourly (the file changes on a release, not by the minute); the button always reads.
    public static func isDue(lastRead: Date?, now: Date, byPress: Bool) -> Bool {
        guard !byPress, let lastRead else { return true }
        return now.timeIntervalSince(lastRead) >= interval
    }
}

public enum InstalledVersion {
    /// A build from a checkout keeps the template's placeholder version and stamps `git describe` under its source key:
    /// only a stamp that is exactly a release tag gives a version to compare.
    public static func comparable(shortVersion: String?, sourceStamp: String?) -> String? {
        if let stamp = sourceStamp {
            return stamp.wholeMatch(of: /v?[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}/) != nil ? stamp : nil
        }
        guard let shortVersion, shortVersion.wholeMatch(of: /[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}/) != nil else { return nil }
        return shortVersion
    }
}

/// One GET to the registry's file host. No API and no token: raw.githubusercontent.com has no rate limit to honor.
public enum RegistryDownload {
    public enum Answer: Sendable, Equatable {
        case data(Data)
        case failed(reason: String)
    }

    public static func get(_ url: URL, userAgent: String, maxBytes: Int) async -> Answer {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        let tooLarge = Answer.failed(reason: "The answer was larger than expected.")
        let session = URLSession(configuration: configuration)
        // Every exit, a refused one included, stops the transfer and releases the session.
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { return .failed(reason: "The answer was not HTTP.") }
            guard http.statusCode == 200 else { return .failed(reason: "GitHub answered \(http.statusCode).") }
            guard http.expectedContentLength <= Int64(maxBytes) else { return tooLarge }
            // Counted as it arrives, so a wrong file is dropped at the cap instead of held whole in memory.
            var data = Data()
            for try await byte in bytes {
                guard data.count < maxBytes else { return tooLarge }
                data.append(byte)
            }
            return .data(data)
        } catch {
            return .failed(reason: "GitHub could not be reached.")
        }
    }
}

/// The registry's file host answers directly: a redirect is somewhere the contract did not name.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
