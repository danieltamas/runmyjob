import Foundation

/// Durations and ages as the panel prints them (docs/DESIGN.md, Jobs): `12s`, `6m 15s`, `1h 2m`.
public enum PanelFormat {
    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    /// A wait: seconds under a minute, whole minutes after.
    public static func wait(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60) min" : duration(interval)
    }

    public static func age(_ interval: TimeInterval) -> String { "\(wait(interval)) ago" }

    /// Keeps the head and the tail of a long command and drops the middle (`cargo test ... --no-fail-fast`).
    public static func middleTruncated(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 8 else { return text }
        let head = (limit - 5) / 2 + (limit - 5) % 2
        let tail = (limit - 5) / 2
        return String(text.prefix(head)) + " ... " + String(text.suffix(tail))
    }
}
