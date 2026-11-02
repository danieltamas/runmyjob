import Foundation

/// The GitHub id of every repo the rules name (`~/.rmj/repo_ids.json`, lower-cased name to id), recorded the first time GitHub answers for it.
/// A name can be reused by another repo after the first one is deleted or moved; the id is what tells a rename from that.
struct RepoIdentities {
    let home: RMJHome

    private var file: URL { home.url.appendingPathComponent("repo_ids.json") }

    var ids: [String: Int] {
        guard let data = try? Data(contentsOf: file), let ids = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return ids
    }

    func save(_ ids: [String: Int]) {
        try? JSONEncoder().encode(ids).write(to: file, options: .atomic)
    }
}
