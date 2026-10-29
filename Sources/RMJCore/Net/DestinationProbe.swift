import Foundation

/// Runs one remote command on a destination and returns what it printed. A spy stands in for it in tests.
public protocol RemoteTransport: Sendable {
    func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput
}

public struct SSHTransport: RemoteTransport {
    public init() {}

    public func run(address: String, alias: String, script: String, timeout: Duration) async throws -> ProcessOutput {
        let arguments = try SSH.arguments(address: address, alias: alias, command: ["sh", "-c", SSH.quote(script)])
        return try await ProcessRunner().run("/usr/bin/ssh", arguments, timeout: timeout)
    }
}

/// A value read from the box, with when; a missing tool is not a failure of the box.
public enum Reading<Value: Sendable & Equatable>: Sendable, Equatable {
    case ok(Value, at: Date)
    case unavailable(String, at: Date)
    case failed(String, at: Date)

    public var value: Value? {
        if case .ok(let value, _) = self { return value }
        return nil
    }
}

public struct ContainerSample: Sendable, Equatable {
    public let name: String
    public let cpu: String
    public let memory: String
}

public struct DestinationProbeResult: Sendable, Equatable {
    public let availability: Availability
    public let docker: Reading<String>
    public let rsync: Reading<String>
    public let images: Reading<[String]>
    public let containers: Reading<[ContainerSample]>
    public let cores: Int?
    public let memoryFreeMB: Int?
    public let memoryTotalMB: Int?
    /// The filesystem holding the ssh user's home, in MB.
    public let diskTotalMB: Int?
    public let diskFreeMB: Int?
    /// `PRETTY_NAME` of /etc/os-release, e.g. `Ubuntu 24.04.1 LTS`.
    public let osName: String?
    public let load: Double?
    public let bootID: String?
    public let uptime: TimeInterval?
    public let clockOffsetMS: Int?
    public let probedAt: Date
    /// The `requires` programs the box lacks, in the order required; nil when none were required or the box did not report.
    public var missingPrograms: [String]?

    public var dockerReady: Bool { docker.value != nil }
    public var rsyncReady: Bool { rsync.value != nil }

    /// The expected images the box does not have; all of them when the list could not be read.
    public func missingImages(expected: [String]) -> [String] {
        let present = Set(images.value ?? [])
        return expected.filter { !present.contains($0) }
    }

    static func without(_ availability: Availability, at now: Date) -> DestinationProbeResult {
        let unread = "not probed"
        return DestinationProbeResult(availability: availability, docker: .unavailable(unread, at: now),
                                      rsync: .unavailable(unread, at: now), images: .unavailable(unread, at: now),
                                      containers: .unavailable(unread, at: now), cores: nil, memoryFreeMB: nil, memoryTotalMB: nil, diskTotalMB: nil, diskFreeMB: nil, osName: nil, load: nil,
                                      bootID: nil, uptime: nil, clockOffsetMS: nil, probedAt: now)
    }

    /// `rebooted since <t>` when the boot id differs from the one seen before.
    public func rebootNote(previousBootID: String?) -> String? {
        guard let previousBootID, let bootID, previousBootID != bootID, let uptime else { return nil }
        return "rebooted since \(DestinationResolver.timestamp(probedAt.addingTimeInterval(-uptime)))"
    }
}

/// Reads one destination in one ssh call. The caller supplies the tailnet state and keeps it fresh
/// (`TailnetMonitor.current(maxAge:)`); the probe contacts only an address that state verifies.
public struct DestinationProbe: Sendable {
    public static let timeout: Duration = .seconds(20)
    private let transport: RemoteTransport

    public init(transport: RemoteTransport = SSHTransport()) { self.transport = transport }

    /// Never throws: every failure is a result. A destination the tailnet does not show online is
    /// not contacted at all.
    public func probe(_ target: DestinationTarget, tailnet: TailnetState, now: Date = Date()) async -> DestinationProbeResult {
        let availability = DestinationResolver.resolve(target, in: tailnet)
        guard case .online(let address) = availability else { return .without(availability, at: now) }
        do {
            let began = ContinuousClock.now
            let output = try await transport.run(address: address, alias: target.alias, script: Self.script(requires: target.requires), timeout: Self.timeout)
            let elapsed = began.duration(to: ContinuousClock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            guard output.status == 0 else {
                return .without(.unreachable("ssh exit \(output.status): \(UntrustedText.clean(Self.firstLine(output.stderr)))"), at: now)
            }
            guard let result = Self.parse(String(decoding: output.stdout, as: UTF8.self), address: address, probedAt: now, callSeconds: seconds, requires: target.requires) else {
                return .without(.unreachable("incomplete probe output"), at: now)
            }
            return result
        } catch ProcessRunner.Failure.timedOut {
            return .without(.unreachable("ssh timeout"), at: now)
        } catch {
            return .without(.unreachable("ssh failed: \(UntrustedText.clean(error.localizedDescription))"), at: now)
        }
    }

    private static let steps: [(name: String, command: String)] = [
        ("clock", "date +%s%N"),
        ("docker", "docker info --format '{{.ServerVersion}}'"),
        ("rsync", "v=$(rsync --version) && printf '%s\\n' \"$v\" | head -n1"),
        ("images", "docker image ls --format '{{.Repository}}:{{.Tag}}'"),
        ("containers", "a=$(docker ps -q --filter label=rx) && b=$(docker ps -q --filter label=rmj.job) "
            + "&& c=$(docker ps -q --filter name=^runner-) "
            + "&& ids=$(printf '%s\\n%s\\n%s\\n' \"$a\" \"$b\" \"$c\" | awk 'NF && !seen[$0]++') "
            + "&& { [ -z \"$ids\" ] || docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' $ids; }"),
        ("nproc", "nproc"),
        ("mem", "awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo"),
        ("memtotal", "awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo"),
        ("disk", "df -Pm \"$HOME\" | awk 'NR==2 {print $2, $4}'"),
        ("osname", "sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '\"'"),
        ("load", "cut -d' ' -f1 /proc/loadavg"),
        ("boot", "cat /proc/sys/kernel/random/boot_id"),
        ("uptime", "cut -d' ' -f1 /proc/uptime"),
        ("clockend", "date +%s%N"),
    ]

    /// Each step reports its own exit status in its header, its output is capped, and `@@end`
    /// proves the script ran to the end: a truncated or silent reply is never read as healthy.
    static let bodyCap = 16384
    static let script = script(requires: [])

    /// The `tools` step lists `missing:<name>` for each required program the box lacks; a name that is not a plain
    /// program name never reaches the box.
    static func script(requires: [String]) -> String {
        let tools = requires.filter(DestinationConfig.isProgramName)
        let extra = tools.isEmpty ? [] : [(name: "tools", command: tools.map { "command -v '\($0)' >/dev/null 2>&1 || echo missing:\($0)" }.joined(separator: "; "))]
        return (steps + extra).map { step in
            "out=$(\(step.command) 2>&1); rc=$?; printf '@@\(step.name) rc=%s\\n' \"$rc\"; printf '%s\\n' \"$out\" | head -c \(bodyCap); echo"
        }.joined(separator: "\n") + "\necho @@end"
    }

    /// nil unless the output has the closing marker.
    static func parse(_ text: String, address: String, probedAt now: Date, callSeconds: TimeInterval, requires: [String] = []) -> DestinationProbeResult? {
        let lineCap = 200
        var bytes = [String: Int](), truncated = Set<String>()
        var sections = [String: (rc: Int, lines: [String])](), current: String?, ended = false
        let known = Set(steps.map(\.name) + ["tools"])
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == "@@end" { ended = true; break }
            if line.hasPrefix("@@"), let header = header(line), known.contains(header.name), sections[header.name] == nil {
                sections[header.name] = (header.rc, [])
                current = header.name
            } else if let current {
                bytes[current, default: 0] += line.utf8.count + 1
                if sections[current]!.lines.count < lineCap && bytes[current]! < bodyCap { sections[current]!.lines.append(line) } else { truncated.insert(current) }
            }
        }
        guard ended else { return nil }
        func lines(_ key: String) -> [String] { (sections[key]?.lines ?? []).map { UntrustedText.clean($0) }.filter { !$0.isEmpty } }
        func reading(_ key: String) -> Reading<String> {
            guard let section = sections[key] else { return .unavailable("not reported", at: now) }
            let first = lines(key).first
            switch (section.rc, first) {
            case (0, let value?): return .ok(value, at: now)
            case (127, _): return .unavailable("not installed", at: now)
            case (0, nil): return .unavailable("no output", at: now)
            default: return .failed(first ?? "exit \(section.rc)", at: now)
            }
        }
        func list<T: Sendable & Equatable>(_ key: String, _ transform: (String) -> T?) -> Reading<[T]> {
            // A sample cut at the line cap is not presented as the whole.
            if truncated.contains(key) { return .failed("output truncated", at: now) }
            switch reading(key) {
            case .failed(let reason, _): return .failed(reason, at: now)
            case .unavailable(let reason, _) where sections[key]?.rc != 0 || reason == "not reported": return .unavailable(reason, at: now)
            default: return .ok(lines(key).compactMap(transform), at: now)
            }
        }
        func number(_ key: String) -> Double? { reading(key).value.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
        // The clock is read first and last in the script: the call time minus the script's own time
        // is the network, half of which separates the call's start from the first reading.
        let scriptSeconds = number("clockend").flatMap { end in number("clock").map { (end - $0) / 1e9 } } ?? 0
        let clockReference = now.addingTimeInterval(max(0, callSeconds - max(0, scriptSeconds)) / 2)
        let clock = number("clock").map { ($0 / 1_000_000 - clockReference.timeIntervalSince1970 * 1000).rounded() }
            .flatMap { abs($0) < 1e12 ? Int($0) : nil }
        let disk = reading("disk").value.map { $0.split(separator: " ").compactMap { Int($0) } }.flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        let required = requires.filter(DestinationConfig.isProgramName)
        var missing: [String]?
        if !required.isEmpty, let tools = sections["tools"], tools.rc == 0, !truncated.contains("tools") {
            let reported = Set(lines("tools"))
            missing = required.filter { reported.contains("missing:\($0)") }
        }
        var result = DestinationProbeResult(
            availability: .online(address: address), docker: reading("docker"), rsync: reading("rsync"),
            images: list("images") { $0 }, containers: list("containers", container),
            cores: reading("nproc").value.flatMap { Int($0) }, memoryFreeMB: reading("mem").value.flatMap { Int($0) },
            memoryTotalMB: reading("memtotal").value.flatMap { Int($0) }, diskTotalMB: disk?.0, diskFreeMB: disk?.1,
            osName: reading("osname").value.map { String($0.prefix(60)) },
            load: number("load"), bootID: reading("boot").value, uptime: number("uptime"), clockOffsetMS: clock, probedAt: now)
        result.missingPrograms = missing
        return result
    }

    private static func header(_ line: String) -> (name: String, rc: Int)? {
        let parts = line.dropFirst(2).split(separator: " ")
        guard parts.count == 2, parts[1].hasPrefix("rc="), let rc = Int(parts[1].dropFirst(3)) else { return nil }
        return (String(parts[0]), rc)
    }

    private static func container(_ line: String) -> ContainerSample? {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        return parts.count == 3 ? ContainerSample(name: parts[0], cpu: parts[1], memory: parts[2]) : nil
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? "no output").prefix(200).description
    }
}
