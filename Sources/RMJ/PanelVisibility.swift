import AppKit
import SwiftUI

/// Whether the menu bar panel is on screen. Perpetual motion pauses while it is not: a hidden
/// panel would otherwise redraw at the display's rate.
extension EnvironmentValues {
    @Entry var panelVisible = true
    /// Drawn once into an image (the README's screenshots): `ImageRenderer` draws no scroll
    /// view's content and runs no appear animation, so lists lay out flat and fully shown.
    @Entry var stillImage = false
    /// The README's fixed clock: relative times read the same in every render.
    @Entry var demoNow: Date?
}

/// A dot that breathes while something runs. The breath is a Core Animation loop, run by the
/// window server: a SwiftUI timeline would re-render and re-lay out the whole panel every frame
/// for each dot. It stops while the panel is hidden.
struct PulseDot: View {
    @Environment(\.panelVisible) private var panelVisible
    @Environment(\.stillImage) private var stillImage
    let color: Color
    var pulsing = true

    var body: some View {
        // ImageRenderer draws no AppKit view.
        if stillImage {
            Circle().fill(color).frame(width: 6, height: 6)
        } else {
            PulseLayer(color: NSColor(color), pulsing: pulsing && panelVisible).frame(width: 6, height: 6)
        }
    }
}

private struct PulseLayer: NSViewRepresentable {
    let color: NSColor
    let pulsing: Bool

    func makeNSView(context: Context) -> PulseView { PulseView() }
    func updateNSView(_ view: PulseView, context: Context) { view.show(color: color, pulsing: pulsing) }
}

final class PulseView: NSView {
    private let dot = CALayer()
    private let halo = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        for circle in [halo, dot] {
            circle.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
            circle.cornerRadius = 3
            layer?.addSublayer(circle)
        }
        halo.opacity = 0
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for circle in [halo, dot] { circle.position = CGPoint(x: bounds.midX, y: bounds.midY) }
        CATransaction.commit()
    }

    func show(color: NSColor, pulsing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = color.cgColor
        halo.backgroundColor = color.withAlphaComponent(0.45).cgColor
        CATransaction.commit()
        guard pulsing != (halo.animation(forKey: "breath") != nil) else { return }
        if pulsing { halo.add(Self.breath, forKey: "breath") } else { halo.removeAnimation(forKey: "breath") }
    }

    private static var breath: CAAnimation {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let breath = CAAnimationGroup()
        breath.animations = [grow, fade]
        breath.duration = 1.4
        breath.timingFunction = CAMediaTimingFunction(name: .easeOut)
        breath.repeatCount = .infinity
        return breath
    }
}

/// Follows its window's occlusion: a menu bar panel's views stay alive after it closes.
struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = { shown in if visible != shown { visible = shown } }
    }
}

final class VisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var token: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let token { NotificationCenter.default.removeObserver(token) }
        token = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        report()
    }

    /// After the current update: AppKit can move the view while SwiftUI lays it out.
    private func report() {
        let shown = window?.occlusionState.contains(.visible) ?? false
        DispatchQueue.main.async { [weak self] in self?.onChange?(shown) }
    }
}
