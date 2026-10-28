import Foundation

/// Tailscale's address space: 100.64.0.0/10 and the unique-local prefix fd7a:115c:a1e0::/48.
/// An address outside it is never connected to, whatever a status file claims.
public enum TailnetAddress {
    public static func isTailnet(_ address: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let octets = withUnsafeBytes(of: &v4) { Array($0) }
            return octets[0] == 100 && octets[1] & 0xC0 == 0x40
        }
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0.prefix(6)) } == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        }
        return false
    }
}

/// Text that came from a remote box or a log is data: control characters, escapes and invisible
/// Unicode are dropped and the length is capped before it is shown or stored.
public enum UntrustedText {
    public static func clean(_ text: String, limit: Int = 200) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            // Default-ignorable scalars (U+034F, Hangul fillers, variation selectors) draw nothing.
            if scalar.properties.isDefaultIgnorableCodePoint { return false }
            return switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: false
            default: scalar != "\u{00A0}"
            }
        }
        return String(String.UnicodeScalarView(kept).prefix(limit))
    }
}
