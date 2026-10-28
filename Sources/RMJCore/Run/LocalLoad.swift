import Foundation

/// What a running job costs right now: processor in percent of one core, resident memory in bytes.
public struct JobLoad: Sendable, Equatable {
    public var cpuPercent: Double
    public var memoryBytes: Int64

    public init(cpuPercent: Double, memoryBytes: Int64) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// The load of runs on this Mac: every process under the `rmj run` client of the job (its pid is on record next to the
/// log), summed from one `ps` reading. Jobs on a box have no reading here.
public enum LocalLoad {
    public static func sample(jobs ids: [String], logs directory: URL) async -> [String: JobLoad] {
        var clients = [String: Int32]()
        for id in ids {
            if let text = try? String(contentsOf: LocalClient.file(id, in: directory), encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 { clients[id] = pid }
        }
        guard !clients.isEmpty,
              let output = try? await ProcessRunner().run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss="], timeout: .seconds(5)), output.status == 0
        else { return [:] }
        return load(clients: clients, table: String(decoding: output.stdout, as: UTF8.self))
    }

    /// `pid ppid pcpu rss(KiB)` lines; each client's subtree, the client itself left out.
    static func load(clients: [String: Int32], table: String) -> [String: JobLoad] {
        var children = [Int32: [Int32]](), usage = [Int32: JobLoad]()
        for line in table.split(separator: "\n") {
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count == 4, let pid = Int32(f[0]), let parent = Int32(f[1]), let cpu = Double(f[2]), let rss = Int64(f[3]) else { continue }
            children[parent, default: []].append(pid)
            usage[pid] = JobLoad(cpuPercent: cpu, memoryBytes: rss * 1024)
        }
        var out = [String: JobLoad]()
        for (id, client) in clients {
            var total = JobLoad(cpuPercent: 0, memoryBytes: 0), queue = children[client] ?? [], seen = Set<Int32>()
            while let pid = queue.popLast() {
                guard seen.insert(pid).inserted else { continue }
                if let u = usage[pid] { total.cpuPercent += u.cpuPercent; total.memoryBytes += u.memoryBytes }
                queue += children[pid] ?? []
            }
            if !seen.isEmpty { out[id] = total }
        }
        return out
    }
}
