import Foundation

/// A rule's container, turned into the `docker run` words for a job.
struct DockerPlan {
    struct Profile: Decodable {
        var image: String
        var network: String?
        var user: String?
        var env: [String: String]?
        var volumes: [String]?
        var lock: String?
        var prelude: String?
    }

    enum Failure: Error, Equatable { case noImage, unknownProfile(String) }

    let options: [String]
    let image: String
    let locks: [String]
    let prelude: (path: String, content: String)?

    static func make(rule: Rule?, config: DestinationConfig, repo: String?, directory: String, subdirectory: String = "",
                     profiles: ProfileStore) throws -> DockerPlan {
        let home = config.home
        let cpus = rule?.cpus ?? config.rxDefaults?.cpus ?? 4
        let memory = rule?.memory ?? config.rxDefaults?.memory ?? "8g"
        var options = ["--cpus", String(cpus), "--memory", memory]
        // The container is the boundary: no capabilities, no privilege gain, a bounded process count, and the box user
        // (`@box`, which the box script resolves) so the synced tree stays writable. A profile's own user wins.
        let hardened = rule?.hardening != false
        if hardened { options += ["--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "4096"] }
        if hardened, rule?.profile == nil { options += ["--user", "@box"] }
        options += ["-v", "\(directory):/work", "-w", subdirectory.isEmpty ? "/work" : "/work/" + subdirectory]
        let repoName = repo?.split(separator: "/").last.map(String.init) ?? "repo"
        var volumes = (rule?.volumes ?? []).map { $0.replacingOccurrences(of: "{repo}", with: repoName) }
        var image = rule?.image
        // One run at a time per checkout: a second run waits instead of syncing under a running container.
        var locks = ["\(directory).lock"]
        var prelude: (String, String)?
        if let name = rule?.profile {
            guard let json = profiles.json(name), let profile = try? JSONDecoder().decode(Profile.self, from: Data(json.utf8)) else {
                throw Failure.unknownProfile(name)
            }
            image = profile.image
            if let network = profile.network { options += ["--network", network] }
            if let user = profile.user { options += ["--user", user] } else if hardened { options += ["--user", "@box"] }
            for (key, value) in (profile.env ?? [:]).sorted(by: { $0.key < $1.key }) { options += ["-e", "\(key)=\(value)"] }
            volumes += (profile.volumes ?? []).map { $0.replacingOccurrences(of: "{home}", with: home) }
            if let lock = profile.lock { locks.append("\(home)/rx/.\(lock).lock") }
            if let file = profile.prelude, let content = profiles.prelude(file) {
                let path = "\(home)/rx/.prelude/\(file)"
                prelude = (path, content)
                volumes.append("\(path):/prelude.sh:ro")
            }
        }
        guard let image else { throw Failure.noImage }
        options += volumes.flatMap { ["-v", $0] }
        // Not the image's own entrypoint: the wrapper runs the prelude, then the command.
        options += ["--entrypoint", "/work/.rmj/exec"]
        // A persistent volume on the target directory only helps if cargo writes there.
        if volumes.contains(where: { $0.hasSuffix(":/work/target") }) { options += ["-e", "CARGO_TARGET_DIR=/work/target"] }
        return DockerPlan(options: options, image: image, locks: locks, prelude: prelude)
    }

    /// `<home>/rx/<repo>/<hash of the worktree path>`: one directory per checkout.
    static func directory(home: String, repo: String?, worktree: String) -> String {
        let name = repo?.split(separator: "/").last.map { String($0.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) } ?? "repo"
        var hash: UInt64 = 5381
        for byte in worktree.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return "\(home)/rx/\(name.isEmpty ? "repo" : name)/\(String(hash, radix: 16))"
    }
}
