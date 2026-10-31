import Foundation

/// One small sensor on a destination card: what the box's own counters say, in the compact row.
public struct SensorChip: Sendable, Equatable {
    public let id: String
    public let label: String
    public let value: String
    public let tone: JobRowPresentation.Tone
    /// Oldest first, for a tiny sparkline; may be empty.
    public let series: [Double]
    /// Fan only: true while a fan reports more than 0 rpm.
    public let spinning: Bool
    public let stale: String?
    /// What the value is out of: `of 36 GB`, `of 24 cores`; nil where there is no whole.
    public let detail: String?
}

public enum SensorChips {
    public static let historyLimit = 60
    /// The sparklines show about this long, whatever the probe interval was.
    static let historySpan: TimeInterval = 1_800
    /// Sizes from the box are plain integers: beyond a petabyte in MB they are nonsense, and arithmetic on them would trap.
    private static let sizeLimit = 1_000_000_000

    /// The probes the chips are drawn from: the card's history, closed with the newest probe when that is not in it yet.
    static func samples(_ input: DestinationCardInput) -> [DestinationProbeResult] {
        var samples = Array(input.history.suffix(historyLimit))
        if let probe = input.probe, samples.last.map({ $0.probedAt < probe.probedAt }) ?? true {
            samples = Array((samples + [probe]).suffix(historyLimit))
        }
        guard let newest = samples.last?.probedAt else { return [] }
        return samples.filter { newest.timeIntervalSince($0.probedAt) <= historySpan }
    }

    static func chips(_ input: DestinationCardInput, stale: String?) -> [SensorChip] {
        let samples = samples(input)
        guard let latest = samples.last else { return [] }
        let pairs = zip(samples, samples.dropFirst()).compactMap { older, newer -> SensorRates? in
            guard let a = older.sensors, let b = newer.sensors, older.bootID == newer.bootID else { return nil }
            let rates = SensorRates.between(a, at: older.probedAt, and: b, at: newer.probedAt)
            return rates == SensorRates(cpuBusyPercent: nil, rxBytesPerSecond: nil, txBytesPerSecond: nil) ? nil : rates
        }
        let now: SensorRates? = samples.count > 1 && samples[samples.count - 2].bootID == latest.bootID
            ? latest.sensors.flatMap { newest in samples[samples.count - 2].sensors.map {
                SensorRates.between($0, at: samples[samples.count - 2].probedAt, and: newest, at: latest.probedAt) } }
            : nil
        func chip(_ id: String, _ value: String, _ tone: JobRowPresentation.Tone = .plain, series: [Double] = [], spinning: Bool = false,
                  of whole: String? = nil) -> SensorChip {
            SensorChip(id: id, label: id, value: value, tone: tone, series: series, spinning: spinning, stale: stale, detail: whole.map { "of \($0)" })
        }
        let cores = latest.cores.flatMap { (1...100_000).contains($0) ? "\($0) \($0 == 1 ? "core" : "cores")" : nil }
        var chips: [SensorChip] = []
        if let busy = now?.cpuBusyPercent {
            chips.append(chip("cpu", String(format: "%.0f%%", busy), level(busy, warn: 85, crit: 95), series: pairs.compactMap(\.cpuBusyPercent), of: cores))
        }
        if let total = latest.memoryTotalMB, let free = latest.memoryFreeMB, total > 0, total <= sizeLimit, (0...sizeLimit).contains(free) {
            let used = max(0, total - free)
            chips.append(chip("memory", DestinationCardPresentation.gigabytes(Int64(used) * 1_048_576), share(used, of: total),
                              series: samples.compactMap { sample in sample.memoryTotalMB.flatMap { t in sample.memoryFreeMB.map { Double(max(0, min(t, sizeLimit) - min($0, sizeLimit))) } } },
                              of: megabytes(total)))
        }
        if let load = latest.load {
            let tone: JobRowPresentation.Tone = latest.cores.map { load >= Double($0) * 2 ? .crit : load >= Double($0) ? .warn : .plain } ?? .plain
            chips.append(chip("load", String(format: "%.1f", load), tone, series: samples.compactMap(\.load), of: cores))
        }
        if let total = latest.diskTotalMB, let free = latest.diskFreeMB, total > 0, total <= sizeLimit, (0...sizeLimit).contains(free) {
            let used = max(0, total - free)
            chips.append(chip("disk", String(format: "%.0f%%", Double(used) * 100 / Double(total)), share(used, of: total), of: megabytes(total)))
        }
        if let health = latest.sensors?.diskHealth, let verdict = diskVerdict(health) {
            chips.append(SensorChip(id: "health", label: "health", value: verdict.value, tone: verdict.tone, series: [], spinning: false, stale: stale, detail: verdict.detail))
        }
        if let rx = now?.rxBytesPerSecond { chips.append(chip("down", rate(rx), series: pairs.compactMap(\.rxBytesPerSecond))) }
        if let tx = now?.txBytesPerSecond { chips.append(chip("up", rate(tx), series: pairs.compactMap(\.txBytesPerSecond))) }
        if let uptime = latest.uptime, uptime.isFinite, (0...31_536_000_000).contains(uptime) { chips.append(chip("uptime", duration(uptime))) }
        if let sensors = latest.sensors {
            if let used = sensors.swapUsedMB, used > 0, used <= sizeLimit {
                let total = sensors.swapTotalMB ?? 0
                chips.append(chip("swap", size(used), total > 0 && used * 2 >= total ? .warn : .plain, of: total > 0 && total <= sizeLimit ? size(total) : nil))
            }
            if let hottest = sensors.hottestC {
                chips.append(chip("temp", String(format: "%.0f C", hottest), hottest >= 90 ? .crit : hottest >= 80 ? .warn : .plain,
                                  series: samples.compactMap { $0.sensors?.hottestC }))
            }
            if let fastest = sensors.fansRPM.max() { chips.append(chip("fan", "\(fastest) rpm", spinning: true)) }
        }
        return chips
    }

    /// The worst thing the disk reports, or "OK" when every signal it could read is clean; nil when it read none.
    /// `detail` says what was checked, so "OK" on a disk with no SMART is not mistaken for a SMART pass.
    static func diskVerdict(_ health: DiskHealth) -> (value: String, tone: JobRowPresentation.Tone, detail: String)? {
        let checked = health.smartPassed == nil ? "no SMART here" : "SMART passed"
        if health.smartPassed == false { return ("SMART failing", .crit, "replace the disk") }
        if health.readOnly == true { return ("Read-only", .crit, "remounted after errors") }
        if let errors = health.ioErrors, errors > 0 { return ("\(errors) I/O errors", .warn, "in the kernel log") }
        if let inodes = health.inodePercent, inodes >= 90 { return ("Inodes \(inodes)%", inodes >= 97 ? .crit : .warn, "files, not bytes") }
        guard health.readOnly != nil || health.ioErrors != nil || health.smartPassed != nil else { return nil }
        return ("OK", health.smartPassed == true ? .ok : .plain, checked)
    }

    static func details(_ probe: DestinationProbeResult?) -> [DestinationCardPresentation.Line] {
        guard let sensors = probe?.sensors else { return [] }
        var lines: [DestinationCardPresentation.Line] = []
        func add(_ label: String, _ value: String) { lines.append(.init(label: label, value: value, tone: .plain, stale: nil)) }
        if let kind = kindLabel(sensors.kind) { add("system", kind) }
        if let total = sensors.swapTotalMB, total > 0, let used = sensors.swapUsedMB { add("swap", "\(size(used)) of \(size(total))") }
        if let pressure = sensors.cpuPressure { add("cpu pressure", percent(pressure)) }
        if let pressure = sensors.memoryPressure { add("memory pressure", percent(pressure)) }
        return lines
    }

    static func kindLabel(_ kind: SystemKind) -> String? {
        switch kind {
        case .bareMetal: "bare metal"
        case .vm: "VM"
        case .wsl: "WSL"
        case .container: "container"
        case .unknown: nil
        }
    }

    private static func level(_ value: Double, warn: Double, crit: Double) -> JobRowPresentation.Tone {
        value >= crit ? .crit : value >= warn ? .warn : .plain
    }

    /// Integer arithmetic, so a share exactly on a threshold lands on the same side every time.
    private static func share(_ used: Int, of total: Int) -> JobRowPresentation.Tone {
        used * 100 >= total * 95 ? .crit : used * 100 >= total * 85 ? .warn : .plain
    }

    /// A capacity: whole gigabytes up to a terabyte, then terabytes with one decimal.
    private static func megabytes(_ megabytes: Int) -> String {
        megabytes >= 1_000_000 ? String(format: "%.1f TB", Double(megabytes) / 1_000_000)
            : DestinationCardPresentation.gigabytes(Int64(megabytes) * 1_048_576)
    }

    private static func percent(_ value: Double) -> String { String(format: "%.1f%%", (value * 10).rounded() / 10) }

    private static func size(_ megabytes: Int) -> String { megabytes < 1024 ? "\(megabytes) MB" : String(format: "%.1f GB", Double(megabytes) / 1024) }

    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1000 { return String(format: "%.0f B/s", bytesPerSecond) }
        if bytesPerSecond < 1_000_000 { return String(format: "%.0f KB/s", bytesPerSecond / 1000) }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 86_400 { return "\(total / 86_400)d \(total % 86_400 / 3_600)h" }
        if total >= 3_600 { return "\(total / 3_600)h \(total % 3_600 / 60)m" }
        return "\(total / 60)m"
    }
}
