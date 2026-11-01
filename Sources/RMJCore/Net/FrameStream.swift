import Foundation

/// Cuts a box's output into frames: text from the first `@@` header line up to and including `@@end`. Whatever comes before a
/// header is dropped; a frame past the size limit is dropped and everything is ignored until the next `@@clock`, which starts a
/// frame again. Chunks may end anywhere.
struct FrameAssembler {
    static let limit = 256 * 1024
    private var pending = [UInt8]()
    private var frame = [UInt8]()
    private var inFrame = false
    private var skipping = false

    mutating func feed(_ data: Data) -> [String] {
        var frames = [String]()
        for byte in data {
            if byte != 0x0A {
                pending.append(byte)
                if pending.count + frame.count > Self.limit { overflow() }
                continue
            }
            let line = pending
            pending.removeAll(keepingCapacity: true)
            if let done = accept(line) { frames.append(done) }
        }
        return frames
    }

    private mutating func overflow() {
        pending.removeAll(keepingCapacity: true)
        frame.removeAll(keepingCapacity: true)
        inFrame = false
        skipping = true
    }

    private mutating func accept(_ line: [UInt8]) -> String? {
        let header = line.starts(with: Array("@@".utf8))
        if skipping {
            guard line.starts(with: Array("@@clock ".utf8)) else { return nil }
            skipping = false
        } else if !inFrame, !header || line == Array("@@end".utf8) {
            return nil
        }
        // A frame that never reached its end is dropped whole when the next one starts: the two are never read as one.
        if inFrame, line.starts(with: Array("@@clock ".utf8)) { frame.removeAll(keepingCapacity: true) }
        inFrame = true
        frame += line + [0x0A]
        if line == Array("@@end".utf8) {
            defer { frame.removeAll(keepingCapacity: true); inFrame = false }
            return String(decoding: frame, as: UTF8.self)
        }
        if frame.count > Self.limit { overflow() }
        return nil
    }
}

/// The newest copy of every section a box has sent. A light frame replaces the light sections; the heavy and rare ones stay until
/// they are three periods old, and then they go: a reading is current or it is unknown, never an old value shown as current.
struct SectionCache {
    private var held: [String: (rc: Int, lines: [String], truncated: Bool, at: Date)] = [:]

    init() {}

    /// nil when the frame is not valid: a light section is missing or it has no closing marker.
    mutating func merge(frame: String, address: String, at: Date, timing: BoxStream.Timing,
                        requires: [String] = [], images: [String] = []) -> DestinationProbeResult? {
        guard let parsed = DestinationProbe.sections(from: frame),
              DestinationProbe.lightSections.allSatisfy({ parsed.sections[$0] != nil }) else { return nil }
        for (name, section) in parsed.sections {
            held[name] = (section.rc, section.lines, parsed.truncated.contains(name), at)
        }
        let period = Double(timing.frameInterval)
        let lives = Dictionary(uniqueKeysWithValues:
            DestinationProbe.heavySections.map { ($0, 3 * period * Double(timing.heavyEvery)) }
            + (DestinationProbe.rareSections).map { ($0, 3 * period * Double(timing.rareEvery)) })
        held = held.filter { name, section in lives[name].map { at.timeIntervalSince(section.at) < $0 } ?? true }
        var merged = ParsedSections(sections: [:], truncated: [])
        for (name, section) in held {
            merged.sections[name] = (section.rc, section.lines)
            if section.truncated { merged.truncated.insert(name) }
            merged.arrivals[name] = section.at
        }
        // The first clock reading was taken as long before the frame's last one as the frame's own script took.
        let scriptSeconds = parsed.number("clockend").flatMap { end in parsed.number("clock").map { max(0, (end - $0) / 1e9) } } ?? 0
        return DestinationProbe.result(from: merged, address: address, probedAt: at, clockReference: at.addingTimeInterval(-scriptSeconds),
                                       requires: requires, images: images)
    }
}
