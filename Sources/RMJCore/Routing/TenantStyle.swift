import Foundation

/// How a tenant is drawn: a colour and an optional pattern laid over its cards and chips. Every field is optional in
/// `rules.json`; `resolved(for:)` fills what is missing.
public struct TenantStyle: Codable, Sendable, Equatable {
    /// `#RRGGBB`.
    public var color: String?
    /// `none`, `stripes` or `dots`.
    public var pattern: String?
    /// Pixels: a stripe's thickness or a dot's diameter.
    public var width: Double?
    /// Pixels between stripes or dot centres.
    public var size: Double?
    /// Degrees.
    public var angle: Double?
    /// 0 is a regular grid, 1 moves every mark up to a whole cell off it.
    public var scatter: Double?

    public static let patterns = ["none", "stripes", "dots"]
    public static let widthRange = 1.0...32.0
    public static let sizeRange = 4.0...64.0
    public static let angleRange = -180.0...180.0
    public static let scatterRange = 0.0...1.0

    public init(color: String? = nil, pattern: String? = nil, width: Double? = nil, size: Double? = nil, angle: Double? = nil, scatter: Double? = nil) {
        self.color = color
        self.pattern = pattern
        self.width = width
        self.size = size
        self.angle = angle
        self.scatter = scatter
    }

    /// Every field filled.
    public struct Resolved: Sendable, Equatable {
        public let color: String
        public let pattern: String
        public let width: Double
        public let size: Double
        public let angle: Double
        public let scatter: Double
    }

    public func resolved(for tenant: String) -> Resolved {
        Resolved(color: color ?? Self.defaultColor(for: tenant), pattern: pattern ?? "none", width: width ?? 3, size: size ?? 10,
                 angle: angle ?? 45, scatter: scatter ?? 0)
    }

    /// A hue picked from the name, the same in every run, as `#RRGGBB`.
    public static func defaultColor(for tenant: String) -> String {
        let sum = tenant.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(sum % 360) / 60, saturation = 0.7, brightness = 0.8
        let chroma = brightness * saturation
        let x = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch Int(hue) {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let lift = brightness - chroma
        func byte(_ value: Double) -> Int { Int(((value + lift) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// The first problem with the style, named by field, or nil.
    func problem() -> String? {
        if let color, color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil { return "color \"\(color)\" is not #RRGGBB" }
        if let pattern, !Self.patterns.contains(pattern) { return "pattern \"\(pattern)\" is not none, stripes or dots" }
        for (field, value, range) in [("width", width, Self.widthRange), ("size", size, Self.sizeRange),
                                      ("angle", angle, Self.angleRange), ("scatter", scatter, Self.scatterRange)] {
            if let value, !range.contains(value) { return "\(field) \(value) is outside \(range.lowerBound)...\(range.upperBound)" }
        }
        return nil
    }
}
