import Foundation

/// The sections of one probe frame, each with its exit status and capped body.
struct ParsedSections {
    var sections: [String: (rc: Int, lines: [String])]
    var truncated: Set<String>
    /// When each section was read, where that is not the frame's own time (a cached section keeps its age).
    var arrivals: [String: Date] = [:]

    /// The first line of a section that exited 0, as a finite number.
    func number(_ key: String) -> Double? {
        guard let section = sections[key], section.rc == 0,
              let line = section.lines.lazy.map({ UntrustedText.clean($0) }).first(where: { !$0.isEmpty }) else { return nil }
        return Double(line).flatMap { $0.isFinite ? $0 : nil }
    }
}

/// The box stream's frames are tiered by what they cost: the light tier reads kernel files with the shell's own builtins,
/// the heavy tier talks to docker, the rare tier runs the slow checks. Every turn runs the light tier.
extension DestinationProbe {
    public static let lightSections = ["clock", "mem", "memtotal", "load", "boot", "uptime", "cpustat", "swap", "net", "psi", "hwmon", "disk", "clockend"]
    public static let heavySections = ["docker", "containers"]
    public static let rareSections = ["rsync", "images", "nproc", "diskhealth", "osname", "virt", "tools"]

    /// Variables used by the light snippets: out, rc, k, v, t, f, r, n, rx, tx, ifc, nl, dk. They read `i`, the turn counter,
    /// and `disk_every`, never write them. Each snippet leaves its answer in `$out`; none of them starts a process except where
    /// `maximumCommands` says so (the box's audit log records every one). Arithmetic only ever sees digits: a malformed line must
    /// not abort the shell.
    private static let lightCommands: [(name: String, command: String, maximumCommands: Int)] = [
        ("clock", clockReading, 0),
        ("mem", meminfo("MemAvailable:"), 0),
        ("memtotal", meminfo("MemTotal:"), 0),
        ("load", "read -r out _ < /proc/loadavg", 0),
        ("boot", "read -r out < /proc/sys/kernel/random/boot_id", 0),
        ("uptime", "read -r out _ < /proc/uptime", 0),
        ("cpustat", "read -r out < /proc/stat", 0),
        ("swap", #"t=; f=; while read -r k v _; do case $k in SwapTotal:) t=$v;; SwapFree:) f=$v;; esac; done < /proc/meminfo; "#
            + #"case $t in ''|*[!0-9]*|0?*) false;; *) case $f in ''|*[!0-9]*|0?*) false;; *) out="$((t/1024)) $(((t-f)/1024))";; esac;; esac"#, 0),
        ("net", #"rx=0; tx=0; n=0; while IFS=': ' read -r ifc r a b c d e f g t _; do n=$((n+1)); [ "$n" -gt 2 ] || continue; "#
            + #"case $ifc in lo|veth*|[d]ocker*|br-*|virbr*) continue;; esac; case $r in ''|*[!0-9]*|0?*) continue;; esac; case $t in ''|*[!0-9]*|0?*) continue;; esac; "#
            + #"rx=$((rx+r)); tx=$((tx+t)); done < /proc/net/dev; out="$rx $tx""#, 0),
        ("psi", #"for r in cpu memory; do [ -r /proc/pressure/$r ] && { read -r k v _ < /proc/pressure/$r; [ "$k" = some ] && out="$out$r ${v#*=}$nl"; }; done; true"#, 0),
        ("hwmon", #"for f in /sys/class/hwmon/hwmon*/temp*_input /sys/class/thermal/thermal_zone*/temp; do [ -r "$f" ] && read -r t < "$f" && out="${out}temp $t$nl"; done; "#
            + #"for f in /sys/class/hwmon/hwmon*/fan*_input; do [ -r "$f" ] && read -r t < "$f" && out="${out}fan $t$nl"; done; true"#, 0),
        // Free space has no kernel file to read, so it costs one `df`; it moves slowly, so it is read again every `disk_every` turns
        // and the last answer is sent in between. A failed read clears the answer: it is current or unknown, never stale.
        ("disk", #"if [ -z "$dk" ] || [ $((i % disk_every)) -eq 0 ]; then dk=; set -- $(df -Pm "$HOME"); "#
            + #"[ $# -ge 6 ] && { shift $(($# - 6)); case "$2$4" in ''|*[!0-9]*) ;; *) dk="$2 $4";; esac; }; fi; out=$dk; [ -n "$out" ]"#, 1),
        ("clockend", clockReading, 0),
    ]

    /// Nanoseconds since the epoch. bash 5 has the time in `$EPOCHREALTIME` (microseconds, point or comma by locale), read once
    /// because it changes between two expansions; any other shell asks `date`.
    private static let clockReading = #"if [ -n "$EPOCHREALTIME" ]; then t=$EPOCHREALTIME; t=${t%[.,]*}${t#*[.,]}; out=${t}000; else out=$(date +%s%N); fi"#

    private static func meminfo(_ key: String) -> String {
        #"while read -r k v _; do [ "$k" = \#(key) ] && case $v in ''|*[!0-9]*|0?*) ;; *) out=$((v/1024));; esac; done < /proc/meminfo; [ -n "$out" ]"#
    }

    /// Every step of the stream with the most processes it can start; heavy and rare steps are not budgeted.
    static func streamSteps(requires: [String], images: [String]) -> [(name: String, command: String, maximumCommands: Int)] {
        let light = Set(lightSections)
        let others = (steps + toolsSteps(requires: requires, images: images)).filter { !light.contains($0.name) }
        return lightCommands + others.map { ($0.name, streamCommand($0.name, default: $0.command), 64) }
    }

    /// The loop the box runs for the whole session: a frame per turn, light every turn, heavy and rare on their turns, the counter
    /// starting at 0 so the first frame is complete. It reads and prints, opens no socket and writes no file; the one thing it starts beyond reading is the rare
    /// tools check, which runs a short container as the one-shot probe always did. When ssh goes the next write ends it.
    /// On bash 5 a light turn starts no process at all; the box's audit log records each one (`DestinationProbeTiers.swift`).
    static func streamScript(requires: [String], images: [String], interval: Int, heavyEvery: Int, rareEvery: Int) -> String {
        let steps = streamSteps(requires: requires, images: images)
        func light(_ step: (name: String, command: String, maximumCommands: Int)) -> String {
            #"out=; { \#(step.command); } 2>/dev/null; rc=$?; printf '@@\#(step.name) rc=%s\n%s\n' "$rc" "$out""#
        }
        func tier(_ names: [String]) -> [String] {
            // The containers step runs before the docker step: the docker step reads what it reported.
            let chosen = steps.filter { names.contains($0.name) }
            return (chosen.filter { $0.name == "containers" } + chosen.filter { $0.name != "containers" }).map { streamWrapped(($0.name, $0.command)) }
        }
        let lightSet = Set(lightSections)
        let heavy = tier(heavySections), rare = tier(rareSections + ["tools"])
        let body = steps.filter { lightSet.contains($0.name) && $0.name != "clockend" }.map(light)
        let end = steps.first { $0.name == "clockend" }.map(light) ?? ""
        let turn = ["if [ $((i % \(max(1, heavyEvery)))) -eq 0 ]; then"] + heavy + ["fi", "if [ $((i % \(max(1, rareEvery)))) -eq 0 ]; then"] + rare + ["fi"]
        return (streamPrologue(rareEvery: rareEvery) + ["while :; do"] + body + turn
                + [end, "echo @@end", "i=$((i+1))", streamWait(interval), "done"]).joined(separator: "\n")
    }
}

extension DestinationProbeResult {
    /// The same readings, dated as they were, with the box's availability replaced: how a card keeps the last numbers it had
    /// while saying the box is not answering.
    public func unreachable(_ availability: Availability) -> DestinationProbeResult {
        var copy = DestinationProbeResult(availability: availability, docker: docker, rsync: rsync, images: images, containers: containers,
                                          cores: cores, memoryFreeMB: memoryFreeMB, memoryTotalMB: memoryTotalMB, diskTotalMB: diskTotalMB,
                                          diskFreeMB: diskFreeMB, osName: osName, load: load, bootID: bootID, uptime: uptime,
                                          clockOffsetMS: clockOffsetMS, probedAt: probedAt)
        copy.sensors = sensors
        copy.missingTools = missingTools
        return copy
    }

    /// Whether `other` says the same about the box, whenever it was read.
    func sameReadings(as other: DestinationProbeResult) -> Bool {
        var copy = DestinationProbeResult(availability: availability, docker: docker, rsync: rsync, images: images, containers: containers,
                                          cores: cores, memoryFreeMB: memoryFreeMB, memoryTotalMB: memoryTotalMB, diskTotalMB: diskTotalMB,
                                          diskFreeMB: diskFreeMB, osName: osName, load: load, bootID: bootID, uptime: uptime,
                                          clockOffsetMS: clockOffsetMS, probedAt: other.probedAt)
        copy.sensors = sensors
        copy.missingTools = missingTools
        return copy == other
    }
}
