import Foundation

/// Samples the processes under this `rmj run` while its command runs and answers their average cost at the end.
actor LoadRecorder {
    private var cpu = 0.0, memory = 0.0, count = 0
    private var task: Task<Void, Never>?

    /// The first reading comes after `first`, early enough for a short command; then one every `interval`.
    func start(first: Duration = .milliseconds(600), every interval: Duration = .seconds(2)) {
        let pid = getpid()
        task = Task {
            try? await Task.sleep(for: first)
            while !Task.isCancelled {
                if let output = try? await ProcessRunner().run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss="], timeout: .seconds(5)), output.status == 0,
                   let load = LocalLoad.load(clients: ["run": pid], table: String(decoding: output.stdout, as: UTF8.self))["run"] { add(load) }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func add(_ load: JobLoad) {
        cpu += load.cpuPercent
        memory += Double(load.memoryBytes)
        count += 1
    }

    /// Nil when the command ended before the first sample.
    func stop() -> JobLoad? {
        task?.cancel()
        return count == 0 ? nil : JobLoad(cpuPercent: cpu / Double(count), memoryBytes: Int64(memory / Double(count)))
    }
}
