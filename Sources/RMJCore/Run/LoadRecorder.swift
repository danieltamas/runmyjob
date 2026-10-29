import Foundation

/// Samples a running job (by default the processes under this `rmj run`) while its command runs and answers its
/// average cost at the end. A reading that is nil is skipped, never averaged in as zero.
actor LoadRecorder {
    private var cpu = 0.0, memory = 0.0, count = 0
    private var task: Task<Void, Never>?
    private let sample: @Sendable () async -> JobLoad?

    /// The load of this process's own subtree, from one `ps` reading.
    init() {
        let pid = getpid()
        sample = {
            guard let output = try? await ProcessRunner().run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss="], timeout: .seconds(5)), output.status == 0
            else { return nil }
            return LocalLoad.load(clients: ["run": pid], table: String(decoding: output.stdout, as: UTF8.self))["run"]
        }
    }

    init(sample: @escaping @Sendable () async -> JobLoad?) { self.sample = sample }

    /// The first reading comes after `first`, early enough for a short command; then one every `interval`.
    func start(first: Duration = .milliseconds(600), every interval: Duration = .seconds(2)) {
        task = Task {
            try? await Task.sleep(for: first)
            while !Task.isCancelled {
                if let load = await sample() { add(load) }
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
