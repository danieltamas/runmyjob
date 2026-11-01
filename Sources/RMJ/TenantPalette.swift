import RMJCore
import SwiftUI

/// The colour and pattern each tenant was given in Settings (`tenants.<name>.style`), read from the rules the panel last loaded.
/// A tenant without a colour keeps the hue its name gives it.
@MainActor
final class TenantPalette {
    static let shared = TenantPalette()

    private var styles: [String: TenantStyle.Resolved] = [:]
    private var coloured: Set<String> = []

    func update(_ rules: Rules?) {
        styles = Dictionary(uniqueKeysWithValues: (rules?.tenants ?? [:]).map { ($0.key.lowercased(), ($0.value.style ?? TenantStyle()).resolved(for: $0.key)) })
        coloured = Set((rules?.tenants ?? [:]).filter { $0.value.style?.color != nil }.map { $0.key.lowercased() })
    }

    func style(_ tenant: String) -> TenantStyle.Resolved { styles[tenant.lowercased()] ?? TenantStyle().resolved(for: tenant) }

    /// The colour the owner chose, nil when the tenant has none of its own.
    func chosenColor(_ tenant: String) -> Color? {
        coloured.contains(tenant.lowercased()) ? Color(hex: style(tenant).color) : nil
    }
}

extension Color {
    /// `#RRGGBB`; anything else is grey.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { self = .gray; return }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// A tenant's pattern drawn over a card: stripes or dots in its colour, turned by `angle`, with each mark moved off the grid by `scatter`.
/// Faint on purpose: it tells boxes of one tenant apart at a glance and never carries meaning alone.
struct TenantPatternView: View {
    let tenant: String
    /// A style being edited, drawn instead of the saved one.
    var style: TenantStyle.Resolved?
    var opacity = 0.2

    var body: some View {
        let s = style ?? TenantPalette.shared.style(tenant)
        if s.pattern != "none" {
            Canvas { context, size in
                let reach = Double(hypot(size.width, size.height)) / 2 + s.size
                var drawn = context
                drawn.translateBy(x: size.width / 2, y: size.height / 2)
                drawn.rotate(by: .degrees(s.angle))
                let cells = Int(reach / s.size) + 1
                var path = Path()
                for row in -cells...cells {
                    if s.pattern == "stripes" {
                        let y = Double(row) * s.size + Self.jitter(row, 0, 1) * s.scatter * s.size
                        path.addRect(CGRect(x: -reach, y: y - s.width / 2, width: 2 * reach, height: s.width))
                    } else {
                        for column in -cells...cells {
                            let x = Double(column) * s.size + Self.jitter(row, column, 2) * s.scatter * s.size
                            let y = Double(row) * s.size + Self.jitter(row, column, 3) * s.scatter * s.size
                            path.addEllipse(in: CGRect(x: x - s.width / 2, y: y - s.width / 2, width: s.width, height: s.width))
                        }
                    }
                }
                drawn.fill(path, with: .color(Color(hex: s.color).opacity(opacity)))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The same mark moves the same way on every draw: -0.5...0.5 from its place in the grid.
    private static func jitter(_ row: Int, _ column: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(row &* 73_856_093 ^ column &* 19_349_663 ^ salt &* 83_492_791))
        x = (x ^ (x >> 30)) &* 0xbf58_476d_1ce4_e5b9
        x = (x ^ (x >> 27)) &* 0x94d0_49bb_1331_11eb
        x ^= x >> 31
        return Double(x % 10_000) / 10_000 - 0.5
    }
}
