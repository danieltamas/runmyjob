import CryptoKit
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

    /// Label an image carries: the SHA-256 of the Dockerfile it was built from, so Setup rebuilds it when RMJ ships a new one.
    public static let fingerprintLabel = "rmj.dockerfile"

    public static func fingerprint(_ dockerfile: Data) -> String { SHA256.hash(data: dockerfile).map { String(format: "%02x", $0) }.joined() }

    /// The fingerprint label of each named image on the destination; an image without one (built before RMJ labelled them) maps to "".
    public static func fingerprints(of images: [String], shell: OpsShell) async throws -> [String: String] {
        guard !images.isEmpty else { return [:] }
        let reads = images.map { "printf '%s %s\\n' '\($0)' \"$(docker image inspect --format '{{index .Config.Labels \"\(fingerprintLabel)\"}}' '\($0)' 2>/dev/null)\"" }
        let output = try await shell.run(reads.joined(separator: "; "), input: nil, timeout: .seconds(30))
        guard output.status == 0 else { throw RunnerStackDeployer.Failure.remote("docker image inspect exited \(output.status)") }
        var result = [String: String]()
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            if let image = parts.first { result[image] = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<no value>", with: "") : "" }
        }
        return result
    }

    /// Builds `rx-<name>` from the vendored Dockerfile on the destination (the file is sent over stdin; no context directory).
    public static func build(name: String, dockerfile: Data, shell: OpsShell) async throws {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-".contains($0)) }) else {
            throw RunnerStackDeployer.Failure.remote("bad image name")
        }
        let output = try await shell.run("docker build --label \(fingerprintLabel)=\(fingerprint(dockerfile)) -t rx-\(name) -", input: dockerfile, timeout: .seconds(3600))
        guard output.status == 0 else { throw RunnerStackDeployer.Failure.remote("docker build exited \(output.status)") }
    }
}
