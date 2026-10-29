import RMJCore
import SwiftUI

/// "Star RMJ on GitHub", glowing in the panel footer until it is done. One click stars the repository
/// through the owner's own `gh`; the result is remembered, so the offer never comes back.
struct StarOffer: View {
    let starring: Bool
    let star: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false
    @State private var overStar = false

    private let gold = Color(red: 1.0, green: 0.78, blue: 0.28)

    var body: some View {
        Button(action: star) {
            HStack(spacing: 5) {
                if starring {
                    ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 11, height: 11)
                } else {
                    Image(systemName: "star.fill").font(.system(size: 10.5, weight: .semibold))
                }
                Text(starring ? "Starring..." : "Star on GitHub").font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(gold)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(gold.opacity(overStar ? 0.26 : 0.14)))
            .overlay(Capsule().strokeBorder(gold.opacity(overStar ? 0.95 : glow ? 0.65 : 0.3), lineWidth: 0.75))
            .shadow(color: gold.opacity(overStar ? 0.7 : glow ? 0.5 : 0.15), radius: overStar || glow ? 9 : 3)
        }
        .buttonStyle(PressStyle(scale: 0.95, hit: AnyShape(Capsule()), lift: 0.1))
        .disabled(starring)
        .onHover { hovering in withAnimation(Motion.snappy) { overStar = hovering } }
        .help("Star danieltamas/runmyjob on GitHub with your gh account")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}
