import Foundation

/// A destination's own additions to the runner stack, kept on this Mac in `~/.rmj/runner-extras/<destination>/`: a
/// compose file (`docker-compose.extra.yml`) and the files it builds from. They give a runner what the bare image lacks
/// (a toolchain image, a Postgres and Redis next to it, cache volumes) without RMJ knowing any repo. Services defined
/// there start with the destination's runners and are never swept as orphans.
public struct RunnerExtras: Sendable, Equatable {
    public static let composeName = "docker-compose.extra.yml"
    /// Names the stack itself owns; an extras file cannot replace one.
    static let reserved: Set<String> = ["docker-compose.yml", RunnerCompose.fileName, "entrypoint.sh", ".rmj-services", ".rmj-credentials", ".env"]
    private static let limit = 1_000_000

    public let files: [String: Data]

    public static let none = RunnerExtras(files: [:])

    public init(files: [String: Data]) { self.files = files }

    /// The files of `<home>/runner-extras/<destination>`; plain file names only, nothing else is read.
    public static func load(destination: String, home: RMJHome = RMJHome()) -> RunnerExtras {
        guard destination.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }), !destination.hasPrefix(".") , !destination.contains("..") else { return .none }
        let directory = home.url.appendingPathComponent("runner-extras").appendingPathComponent(destination)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var files = [String: Data]()
        for name in names.sorted().prefix(20) where isFileName(name) && !reserved.contains(name) {
            let url = directory.appendingPathComponent(name)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url), data.count <= limit else { continue }
            files[name] = data
        }
        return RunnerExtras(files: files)
    }

    static func isFileName(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// The service names of the extras compose file (two-space keys under `services:`), in file order.
    public var services: [String] {
        guard let data = files[Self.composeName] else { return [] }
        var names = [String]()
        var inServices = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.hasPrefix(" "), !line.isEmpty, !line.hasPrefix("#") { inServices = line.hasPrefix("services:") }
            guard inServices, line.hasPrefix("  "), !line.hasPrefix("   "), line.hasSuffix(":") else { continue }
            let name = String(line.dropFirst(2).dropLast())
            if name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }), !name.isEmpty { names.append(name) }
        }
        return names
    }

    var hasCompose: Bool { files[Self.composeName] != nil }
}
