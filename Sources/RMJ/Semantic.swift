import RMJCore
import SwiftUI

/// One hue per meaning (docs/DESIGN.md). A verdict color never marks a resource and a resource color never
/// signals health.
extension Theme {
    static var ok: Color { success }
    static var warn: Color { unassigned }
    static var crit: Color { danger }
    static var unknown: Color { neutral }
}

/// The panes of the Settings window, in the order of docs/DESIGN.md.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", tailscale = "Tailscale", destinations = "Destinations", hooks = "Hooks"
    case retention = "Retention", notifications = "Notifications", logs = "Log streaming", agent = "Agent access", more = "More apps", about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .tailscale: "network"
        case .destinations: "server.rack"
        case .hooks: "terminal"
        case .retention: "clock.arrow.circlepath"
        case .notifications: "bell"
        case .logs: "dot.radiowaves.up.forward"
        case .agent: "sparkles"
        case .more: "square.grid.2x2"
        case .about: "info.circle"
        }
    }

    @MainActor var color: Color {
        switch self {
        case .general, .agent, .logs: Theme.teal
        case .tailscale, .destinations: Theme.ok
        case .hooks, .retention: Theme.warn
        case .more: Theme.teal
        case .notifications, .about: Theme.neutral
        }
    }
}

/// The meanings docs/DESIGN.md adds to the shared signals.
extension Theme {
    static var running: Color { teal }
    static var local: Color { hue(0xB794F6, light: 0x6B46C1) }
    static var tenantA: Color { hue(0x5EEAD4, light: 0x0F766E) }
    static var tenantB: Color { hue(0xF9A8D4, light: 0xBE185D) }

    static func color(_ tone: JobRowPresentation.Tone) -> Color {
        switch tone {
        case .running: running
        case .ok: ok
        case .crit: crit
        case .warn: warn
        case .local: local
        case .unknown: unknown
        case .plain: textSecondary
        }
    }

    /// A tenant keeps one colour everywhere, picked from its name so it is the same in every pane and run;
    /// no tenant stays neutral.
    static func tenant(_ name: String?) -> Color {
        guard let name = name?.lowercased(), !name.isEmpty else { return unknown }
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return sum % 2 == 0 ? tenantA : tenantB
    }
}
