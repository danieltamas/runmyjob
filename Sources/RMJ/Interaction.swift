import AppKit
import SwiftUI

/// What every clickable thing in RMJ does: the hand over its whole area, a lift on hover, a sink and dim while pressed.
/// `hit` is the clickable area (the whole rectangle unless the label is a circle or a capsule); `lift` is the hover brightening.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var hit = AnyShape(Rectangle())
    var lift: Double = 0.12

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, scale: scale, hit: hit, lift: lift)
    }
}

private struct PressBody: View {
    let configuration: ButtonStyle.Configuration
    let scale: CGFloat
    let hit: AnyShape
    let lift: Double
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .contentShape(hit)
            .overlay { hit.fill(Color.white.opacity(hovering && isEnabled && !pressed ? lift * 0.6 : 0)).allowsHitTesting(false) }
            .opacity(pressed ? 0.72 : 1)
            .scaleEffect(pressed ? scale : 1)
            .animation(Motion.snappy, value: pressed)
            .animation(Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
            .pointingHandCursor(isEnabled)
    }
}

/// A row-wide button: a wash behind the whole row on hover, a deeper one while pressed.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowPressBody(configuration: configuration)
    }
}

private struct RowPressBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let wash = configuration.isPressed ? 0.10 : hovering ? 0.05 : 0.0
        configuration.label
            .contentShape(Rectangle())
            .background(Theme.wash.opacity(isEnabled ? wash : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(Motion.snappy, value: wash)
            .onHover { hovering = $0 }
            .pointingHandCursor(isEnabled)
    }
}

extension View {
    /// The hand over anything clickable. On macOS 15 SwiftUI owns the cursor, so a nested or
    /// neighbouring region and AppKit's own cursor updates never put the arrow back mid-hover.
    /// Before that it is set on every move, which a tooltip or a layout pass can still undo
    /// until the mouse moves again.
    @ViewBuilder
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        if #available(macOS 15, *) {
            pointerStyle(enabled ? .link : nil)
        } else {
            setsHandOnMove(enabled)
        }
    }

    /// The toggle trait exists from macOS 14; before that the label and the On/Off value carry the state.
    @ViewBuilder
    func toggleTrait() -> some View {
        if #available(macOS 14, *) { accessibilityAddTraits(.isToggle) } else { self }
    }

    private func setsHandOnMove(_ enabled: Bool) -> some View {
        onContinuousHover { phase in
            guard enabled else { return }
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

/// A text-only action ("Reset", "Turn on"): a padded target, so the hand covers more than the letters.
struct LinkButton: View {
    let title: String
    var tint: Color = Theme.teal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.meta).foregroundStyle(tint).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 5)
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }
}

/// An action inside a row, card or footer: the standard secondary button, red when destructive.
struct ChipButton: View {
    let title: String
    var destructive = false
    let action: () -> Void

    var body: some View { ActionButton(title: title, style: destructive ? .destructive : .secondary, action: action) }
}

/// An on/off setting: the label on the left, the switch on the right, and the whole row is the button.
struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(Motion.snappy) { isOn.toggle() } } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let detail { Text(detail).font(.meta).foregroundStyle(Theme.textTertiary) }
                }
                Spacer(minLength: 12)
                SwitchTrack(isOn: isOn)
            }
            .padding(.horizontal, SettingsMetrics.rowInset).padding(.vertical, 6)
        }
        .buttonStyle(RowPressStyle())
        .padding(.horizontal, -SettingsMetrics.rowInset)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .toggleTrait()
    }
}

private struct SwitchTrack: View {
    let isOn: Bool

    var body: some View {
        Capsule().fill(isOn ? Theme.teal : Theme.wash.opacity(0.18))
            .frame(width: 34, height: 20)
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(isOn ? Theme.canvas : Theme.textSecondary).frame(width: 14, height: 14).padding(3)
            }
    }
}

/// Reports whether the pointer is over the view behind which it sits, from an AppKit tracking area. SwiftUI's own hover
/// is lost whenever the view is rebuilt under a resting pointer (every poll rebuilds the rows) and in a panel that is not
/// the key window; a tracking area lives with its NSView, which SwiftUI keeps.
struct HoverRegion: NSViewRepresentable {
    @Binding var inside: Bool

    func makeNSView(context: Context) -> Tracker {
        let view = Tracker()
        view.onChange = { inside = $0 }
        return view
    }

    func updateNSView(_ view: Tracker, context: Context) { view.onChange = { inside = $0 } }

    final class Tracker: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var area: NSTrackingArea?

        /// Clicks and drags go to the views in front of it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let fresh = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(fresh)
            area = fresh
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }
}
