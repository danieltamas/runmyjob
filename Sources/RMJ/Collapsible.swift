import SwiftUI

private struct CollapsibleHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Content that opens and closes by animating its own measured height, so the card around it grows with the content and
/// the content never shows outside the card (an `if` with a transition lays the content out at its final place at once,
/// while the card is still on its way).
struct Collapsible<Content: View>: View {
    let open: Bool
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0
    @State private var mounted: Bool
    private let keepMounted: Bool

    /// `lazy`: closed content is not built at all, so a long list of closed rows costs one row each (it stays mounted while it
    /// closes). A short list passes false: the content is always measured, so a tap starts the motion in the same frame.
    init(open: Bool, lazy: Bool = true, @ViewBuilder content: () -> Content) {
        self.open = open
        self.content = content()
        _mounted = State(initialValue: open || !lazy)
        keepMounted = !lazy
    }

    var body: some View {
        Group {
            if mounted {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { Color.clear.preference(key: CollapsibleHeight.self, value: $0.size.height) })
                    .onPreferenceChange(CollapsibleHeight.self) { height = $0 }
                    .frame(height: open ? height : 0, alignment: .top)
                    .clipped()
                    .animation(Motion.snappy, value: height)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
            }
        }
        .onChange(of: open) { _, now in
            if now { mounted = true; return }
            guard !keepMounted else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                if !open { mounted = false; height = 0 }
            }
        }
    }
}
