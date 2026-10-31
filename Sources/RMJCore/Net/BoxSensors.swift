import Foundation

public enum SystemKind: String, Sendable, Equatable { case bareMetal, vm, wsl, container, unknown }

/// What one probe read about a box's own health: the kernel's counters and, where the kernel exposes them,
/// temperature and fans. Counters are raw totals; `SensorRates` turns two of them into rates.
public struct SensorSnapshot: Sendable, Equatable {
    public let kind: SystemKind
    /// total - idle - iowait, and the sum of user nice system idle iowait irq softirq steal, from the first line of /proc/stat.
    public let cpuBusyTicks: Int64?
    public let cpuTotalTicks: Int64?
    public let swapTotalMB: Int?
    public let swapUsedMB: Int?
    /// Summed over every interface except `lo`.
    public let netRxBytes: Int64?
    public let netTxBytes: Int64?
    /// PSI "some avg10", percent.
    public let cpuPressure: Double?
    public let memoryPressure: Double?
    public let hottestC: Double?
    /// Fans reporting more than 0 rpm.
    public let fansRPM: [Int]
    public let diskHealth: DiskHealth?

    public init(kind: SystemKind = .unknown, cpuBusyTicks: Int64? = nil, cpuTotalTicks: Int64? = nil, swapTotalMB: Int? = nil,
                swapUsedMB: Int? = nil, netRxBytes: Int64? = nil, netTxBytes: Int64? = nil, cpuPressure: Double? = nil,
                memoryPressure: Double? = nil, hottestC: Double? = nil, fansRPM: [Int] = [], diskHealth: DiskHealth? = nil) {
        self.kind = kind
        self.cpuBusyTicks = cpuBusyTicks
        self.cpuTotalTicks = cpuTotalTicks
        self.swapTotalMB = swapTotalMB
        self.swapUsedMB = swapUsedMB
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
        self.cpuPressure = cpuPressure
        self.memoryPressure = memoryPressure
        self.hottestC = hottestC
        self.fansRPM = fansRPM
        self.diskHealth = diskHealth
    }

    typealias Sections = [String: (rc: Int, lines: [String])]

    /// nil when the box reported nothing usable. Each step stands alone: a bad one never discards another, and
    /// every number is validated rather than clamped.
    static func read(_ sections: Sections) -> SensorSnapshot? {
        func body(_ name: String, anyStatus: Bool = false) -> [String] {
            guard let section = sections[name], anyStatus || section.rc == 0 else { return [] }
            // A colour code is dropped whole, not left as "[31m" around the word it wrapped.
            return section.lines.map { UntrustedText.clean($0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)) }
                .filter { !$0.isEmpty }
        }
        func words(_ line: String?) -> [Substring] { line?.split(separator: " ") ?? [] }

        var busy: Int64?, total: Int64?
        let stat = words(body("cpustat").first)
        if stat.count >= 9, stat[0] == "cpu" {
            let fields = stat[1...8].map { counter($0) }
            if fields.allSatisfy({ $0 != nil }) {
                let values = fields.compactMap { $0 }, sum = values.reduce(0, +)
                if sum <= counterLimit { total = sum; busy = sum - values[3] - values[4] }
            }
        }
        var swapTotal: Int?, swapUsed: Int?
        let swap = words(body("swap").first)
        if swap.count == 2, let t = counter(swap[0]), let u = counter(swap[1]), t <= 1_000_000_000, u <= t {
            swapTotal = Int(t); swapUsed = Int(u)
        }
        var rx: Int64?, tx: Int64?
        let net = words(body("net").first)
        if net.count == 2, let r = counter(net[0]), let t = counter(net[1]) { rx = r; tx = t }

        var pressure: [String: Double] = [:]
        for line in body("psi") {
            let parts = words(line)
            if parts.count == 2, let value = Double(parts[1]), value.isFinite, (0...100).contains(value) { pressure[String(parts[0])] = value }
        }
        var temps: [Double] = [], fans: [Int] = []
        for line in body("hwmon") {
            let parts = words(line)
            guard parts.count == 2 else { continue }
            if parts[0] == "temp", let milli = Double(parts[1]), milli.isFinite, (-50_000...150_000).contains(milli) { temps.append(milli / 1000) }
            if parts[0] == "fan", let rpm = Int(parts[1]), (1...100_000).contains(rpm) { fans.append(rpm) }
        }
        let snapshot = SensorSnapshot(kind: kind(sections["virt"], body("virt", anyStatus: true).first), cpuBusyTicks: busy, cpuTotalTicks: total,
                                      swapTotalMB: swapTotal, swapUsedMB: swapUsed, netRxBytes: rx, netTxBytes: tx,
                                      cpuPressure: pressure["cpu"], memoryPressure: pressure["memory"], hottestC: temps.max(), fansRPM: fans, diskHealth: DiskHealth.read(sections["diskhealth"].flatMap { $0.rc == 0 ? $0.lines : nil } ?? []))
        return snapshot == SensorSnapshot() ? nil : snapshot
    }

    private static let counterLimit: Int64 = 1_000_000_000_000_000

    private static func counter(_ text: Substring) -> Int64? {
        guard let value = Int64(text), (0...counterLimit).contains(value) else { return nil }
        return value
    }

    /// `systemd-detect-virt` exits 1 and prints `none` on bare metal, so only "not installed" means unknown.
    private static func kind(_ section: (rc: Int, lines: [String])?, _ word: String?) -> SystemKind {
        guard let section, section.rc != 127, let word = word?.lowercased() else { return .unknown }
        switch word {
        case "none": return .bareMetal
        case "wsl": return .wsl
        case "docker", "podman", "lxc", "lxc-libvirt", "openvz", "systemd-nspawn", "rkt": return .container
        case "kvm", "qemu", "vmware", "microsoft", "oracle", "xen", "amazon", "parallels", "bhyve": return .vm
        default: return .unknown
        }
    }
}

/// Rates between two snapshots of the same box. Any counter that went backwards (a reboot) or a CPU interval
/// with no ticks makes the whole interval unusable.
public struct SensorRates: Sendable, Equatable {
    public let cpuBusyPercent: Double?
    public let rxBytesPerSecond: Double?
    public let txBytesPerSecond: Double?

    public static func between(_ older: SensorSnapshot, at olderTime: Date, and newer: SensorSnapshot, at newerTime: Date) -> SensorRates {
        let none = SensorRates(cpuBusyPercent: nil, rxBytesPerSecond: nil, txBytesPerSecond: nil)
        let seconds = newerTime.timeIntervalSince(olderTime)
        guard seconds > 0 else { return none }
        func delta<T: BinaryInteger>(_ a: T?, _ b: T?) -> Double?? {
            guard let a, let b else { return .some(nil) }
            return b >= a ? .some(Double(b - a)) : nil
        }
        guard let busy = delta(older.cpuBusyTicks, newer.cpuBusyTicks), let total = delta(older.cpuTotalTicks, newer.cpuTotalTicks),
              let rx = delta(older.netRxBytes, newer.netRxBytes), let tx = delta(older.netTxBytes, newer.netTxBytes) else { return none }
        var cpu: Double?
        if let busy, let total {
            guard total > 0 else { return none }
            cpu = min(100, busy * 100 / total)
        }
        return SensorRates(cpuBusyPercent: cpu, rxBytesPerSecond: rx.map { $0 / seconds }, txBytesPerSecond: tx.map { $0 / seconds })
    }
}

/// What the disk of the ssh user's home says about itself, from signals a plain user can read. Nothing here is a
/// guess: a field stays nil when the box could not say (no `smartctl`, unreadable kernel log, WSL's virtual disk).
public struct DiskHealth: Sendable, Equatable {
    public let readOnly: Bool?
    public let inodePercent: Int?
    /// Kernel log lines that name a disk or filesystem error.
    public let ioErrors: Int?
    /// nil without SMART; false as soon as any disk fails it.
    public let smartPassed: Bool?

    static func read(_ lines: [String]) -> DiskHealth? {
        var readOnly: Bool?, inodes: Int?, errors: Int?, smart: Bool?
        for line in lines {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            switch (parts[0], parts[1]) {
            case ("ro", "0"): readOnly = false
            case ("ro", "1"): readOnly = true
            case ("smart", "failed"): smart = false
            case ("smart", "passed"): smart = smart ?? true
            case ("inodes", let value): if let n = Int(value), (0...100).contains(n) { inodes = n }
            case ("ioerr", let value): if let n = Int(value), (0...1_000_000_000).contains(n) { errors = n }
            default: continue
            }
        }
        let health = DiskHealth(readOnly: readOnly, inodePercent: inodes, ioErrors: errors, smartPassed: smart)
        return readOnly == nil && inodes == nil && errors == nil && smart == nil ? nil : health
    }
}
