import Foundation
import RMJCore

/// Where an in-app update stands. A finished install quits this app, so only `updating` and `failed` are ever seen.
enum UpdateState: Equatable {
    case idle
    case updating(String)
    case failed(String)
}

/// Runs the installer bundled in the app (Contents/Resources/install.sh, the same script as the curl install): it
/// downloads the release, checks its checksum, quits this app, swaps the copy and opens the new one.
enum UpdateInstaller {
    /// Starts the installer for `version`; `stopped` is called with the last line of its log if it ends and this app is still running.
    static func start(version: String, stopped: @escaping @Sendable (String) -> Void) throws {
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            throw UpdateError(reason: "The installer is not part of this build. Install the release from GitHub instead.")
        }
        guard version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else {
            throw UpdateError(reason: "The release version \"\(version)\" is not one this installer accepts.")
        }
        let home = RMJHome()
        try home.prepare()
        let logURL = home.url.appendingPathComponent("update.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        // The installer replaces the copy that is running, wherever it lives.
        process.environment = ["RMJ_VERSION": version, "RMJ_INSTALL_ROOT": URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().path,
                               "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        // A successful install quits this app, so being called at all means it did not finish.
        process.terminationHandler = { _ in stopped(lastLine(of: logURL) ?? "The installer stopped without saying why.") }
        try process.run()
    }

    private static func lastLine(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = UntrustedText.clean(String(decoding: data.suffix(4_000), as: UTF8.self), limit: 4_000)
        return text.split(whereSeparator: \.isNewline).last.map(String.init)
    }
}

struct UpdateError: Error { let reason: String }
