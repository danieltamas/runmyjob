import RMJCore
import SwiftUI

/// RMJ's design tokens, from the look chosen under General (`Looks.swift`).
@MainActor
enum Theme {
    private static var palette: Palette { Appearance.shared.look.palette }

    // Canvas and surfaces
    static var canvas: Color { palette.canvas }
    static var canvasLift: Color { palette.canvasLift }
    static var shell: Color { palette.shell }
    static var hairline: Color { palette.hairline }
    static var core: Color { palette.core }
    static var coreHover: Color { palette.coreHover }
    static var highlight: Color { palette.highlight }
    static var finish: Finish { palette.finish }
    static var lit: Bool { palette.lit }
    static var scheme: ColorScheme { palette.scheme }
    static var wash: Color { palette.wash }
    static var paneInner: Color { palette.paneInner }
    static var paneEdge: Color { palette.paneEdge }
    static var paneShade: Color { palette.paneShade }

    // Text
    static var textPrimary: Color { palette.textPrimary }
    static var textSecondary: Color { palette.textSecondary }
    static var textTertiary: Color { palette.textTertiary }

    // Brand
    static var teal: Color { palette.teal }
    static var dialLight: Color { palette.dialLight }
    static var brand: LinearGradient { palette.brand }

    // Signals
    static var unassigned: Color { palette.unassigned }
    static var danger: Color { palette.danger }
    static var success: Color { palette.success }
    static var neutral: Color { palette.neutral }

    /// A hue as the dark looks show it, and its deeper partner on a light canvas, where the
    /// bright one would wash out.
    static func hue(_ dark: UInt32, light: UInt32) -> Color {
        Color(hex: scheme == .light ? light : dark)
    }
}

/// Spring curves with mass: nothing in RMJ snaps or eases linearly.
enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let gentle = Animation.spring(response: 0.7, dampingFraction: 0.9)
}

enum Radius {
    static let card: CGFloat = 16
    static let bezel: CGFloat = 3
    static let control: CGFloat = 10
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension Font {
    static let eyebrow = Font.system(size: 9.5, weight: .semibold)
    static let rowTitle = Font.system(size: 13, weight: .medium)
    static let meta = Font.system(size: 11)
    static let statValue = Font.system(size: 26, weight: .semibold, design: .rounded)
    static let statSmall = Font.system(size: 17, weight: .semibold, design: .rounded)
}

/// The canvas every RMJ surface sits on, with the icon's two lights bleeding in from the top
/// in a look that has them.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.canvas
            if Theme.lit {
                RadialGradient(colors: [Theme.teal.opacity(0.16), .clear], center: .init(x: 0.1, y: -0.05),
                               startRadius: 0, endRadius: 260)
                RadialGradient(colors: [Theme.dialLight.opacity(0.07), .clear], center: .init(x: 0.95, y: 0.02),
                               startRadius: 0, endRadius: 220)
            }
        }
        .ignoresSafeArea()
    }
}
