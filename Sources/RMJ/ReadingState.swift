import SwiftUI

/// The numbers of a card while the panel waits for the boxes' next reading: placeholders that breathe, so a stale value is never taken for a current one.
private struct Reading: ViewModifier {
    let on: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .redacted(reason: on ? .placeholder : [])
            .opacity(on && dim ? 0.45 : 1)
            .onChange(of: on) { _, reading in
                if reading { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true } }
                else { withAnimation(Motion.snappy) { dim = false } }
            }
            .onAppear {
                if on { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true } }
            }
    }
}

extension View {
    func reading(_ on: Bool) -> some View { modifier(Reading(on: on)) }
}
