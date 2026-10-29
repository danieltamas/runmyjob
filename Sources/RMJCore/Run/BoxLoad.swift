import Foundation

/// Reads the box's answer to `rx-run.sh stats`: one `docker stats` line per container of the job,
/// `236.40% 1.352GiB / 31.3GiB` (cpu, memory in use / limit). Several containers are summed; a line that
/// cannot be read makes the whole answer unreadable rather than low.
public enum BoxLoad {
    private static let units: [String: Double] = [
        "B": 1, "KiB": 1_024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776,
        "kB": 1_000, "KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000, "TB": 1_000_000_000_000,
    ]

    public static func parse(_ text: String) -> JobLoad? {
        var total = JobLoad(cpuPercent: 0, memoryBytes: 0), lines = 0
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            guard let load = parse(line: line) else { return nil }
            total.cpuPercent += load.cpuPercent
            total.memoryBytes += load.memoryBytes
            lines += 1
        }
        return lines == 0 ? nil : total
    }

    private static func parse(line: Substring) -> JobLoad? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0].hasSuffix("%"), let cpu = Double(fields[0].dropLast()), cpu.isFinite, cpu >= 0,
              let memory = bytes(fields[1]) else { return nil }
        return JobLoad(cpuPercent: cpu, memoryBytes: memory)
    }

    private static func bytes(_ field: Substring) -> Int64? {
        let split = field.firstIndex { !($0.isNumber || $0 == ".") } ?? field.endIndex
        guard let value = Double(field[..<split]), value.isFinite, value >= 0, let unit = units[String(field[split...])] else { return nil }
        let bytes = value * unit
        return bytes < 9e18 ? Int64(bytes) : nil
    }
}
