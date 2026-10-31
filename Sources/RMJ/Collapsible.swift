import SwiftUI

/// Sizes its one child at its natural height and reports `progress` of that height, so the height is part of the animation
/// itself: no measuring pass, no state write, no frame between the tap and the first moving frame.
private struct CollapseLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: natural.height * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Content that opens and closes by animating its own height, so the card around it grows with the content and the
/// content never shows outside the card (an `if` with a transition lays the content out at its final place at once,
/// while the card is still on its way).
struct Collapsible<Content: View>: View {
    let open: Bool
    @ViewBuilder let content: Content
    @State private var mounted: Bool
    /// What the layout shows: it trails `open` by one update so freshly built content starts at zero and animates up.
    @State private var revealed: Bool
    private let keepMounted: Bool

    /// `lazy`: closed content is not built at all, so a long list of closed rows costs one row each (it stays mounted while it
    /// closes). A short list passes false: the content is always built, so a tap starts the motion in the same frame.
    init(open: Bool, lazy: Bool = true, @ViewBuilder content: () -> Content) {
        self.open = open
        self.content = content()
        _mounted = State(initialValue: open || !lazy)
        _revealed = State(initialValue: open)
        keepMounted = !lazy
    }

    var body: some View {
        Group {
            // `|| open`: the content is built in the very update that opens it, not one update later.
            if mounted || open {
                CollapseLayout(progress: revealed ? 1 : 0) { content }
                    .clipped()
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
            }
        }
        .onChange(of: open) { _, now in
            withAnimation(Motion.snappy) { revealed = now }
            if now { mounted = true; return }
            guard !keepMounted else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                if !open { mounted = false }
            }
        }
    }
}
