import Foundation

/// A rule's `profile`: a container recipe the user keeps in `<home>/profiles/<name>.json`, with an optional shell
/// prelude next to it. RMJ ships none; they describe the user's own repos.
public struct ProfileStore: Sendable {
    let directory: URL

    public init(home: RMJHome) { directory = home.url.appendingPathComponent("profiles", isDirectory: true) }

    /// Plain names only, so a profile name never walks out of the directory.
    private func file(_ name: String, suffix: String) -> URL? {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }), !name.hasPrefix(".") else { return nil }
        return directory.appendingPathComponent(name + suffix)
    }

    public func exists(_ name: String) -> Bool {
        file(name, suffix: ".json").map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
    }

    func json(_ name: String) -> String? {
        file(name, suffix: ".json").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The image a profile runs, for the box card's list of images in use.
    func image(_ name: String) -> String? {
        json(name).flatMap { try? JSONDecoder().decode(DockerPlan.Profile.self, from: Data($0.utf8)) }?.image
    }

    /// The prelude a profile names, found beside it.
    func prelude(_ file: String) -> String? {
        self.file(file, suffix: "").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
