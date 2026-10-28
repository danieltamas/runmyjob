import Foundation

public struct ImageInfo: Sendable, Equatable {
    public let repository: String
    public let tag: String
    public let created: String
    /// `3 days ago`, as docker says it.
    public let age: String
}

public enum RunnerImages {
    /// The images on a destination that RMJ builds or runs: `rx-*` and `gh-runner`.
    public static func list(shell: OpsShell) async throws -> [ImageInfo] {
        let output = try await shell.run("docker images --format '{{.Repository}}\\t{{.Tag}}\\t{{.CreatedAt}}\\t{{.CreatedSince}}'", input: nil, timeout: .seconds(30))
        guard output.status == 0 else { throw RunnerStackDeployer.Failure.remote("docker images exited \(output.status)") }
        return String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map { GitHubText.clean(String($0)) }
            guard f.count >= 4, f[0].hasPrefix("rx-") || f[0] == "gh-runner" else { return nil }
            return ImageInfo(repository: f[0], tag: f[1], created: f[2], age: f[3])
        }
    }

    /// Builds `rx-<name>` from the vendored Dockerfile on the destination (the file is sent over stdin; no context directory).
    public static func build(name: String, dockerfile: Data, shell: OpsShell) async throws {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-".contains($0)) }) else {
            throw RunnerStackDeployer.Failure.remote("bad image name")
        }
        let output = try await shell.run("docker build -t rx-\(name) -", input: dockerfile, timeout: .seconds(3600))
        guard output.status == 0 else { throw RunnerStackDeployer.Failure.remote("docker build exited \(output.status)") }
    }
}
