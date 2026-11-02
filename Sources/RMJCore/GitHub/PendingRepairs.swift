import Foundation

/// The destinations whose box still has to be set up again after the rules changed under it (`~/.rmj/pending_repairs.json`).
/// Written before the rules change, so a crash between the two cannot lose a box; a box leaves only once its setup succeeded.
struct PendingRepairs {
    let home: RMJHome

    private var file: URL { home.url.appendingPathComponent("pending_repairs.json") }

    var names: Set<String> {
        guard let data = try? Data(contentsOf: file), let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names)
    }

    func add(_ added: [String]) throws { try write(names.union(added)) }

    func remove(_ removed: [String]) throws { try write(names.subtracting(removed)) }

    private func write(_ names: Set<String>) throws {
        if names.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try JSONEncoder().encode(names.sorted()).write(to: file, options: .atomic)
    }
}
