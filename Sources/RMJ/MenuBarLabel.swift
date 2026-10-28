import RMJCore
import SwiftUI

/// The route glyph with the state of docs/DESIGN.md (The menu bar icon): the count of running jobs beside it, a
/// badge until a failure has been seen, a slash while the tailnet is down.
struct MenuBarLabel: View {
    let state: MenuBarIconState
    /// The longest running job's elapsed time, when General asks for it.
    var elapsed: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: .rmjTemplate)
                .overlay { if state == .tailnetDown { Slash().stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round)) } }
                .overlay(alignment: .topTrailing) {
                    if state == .failed { Circle().fill(.red).frame(width: 6, height: 6).offset(x: 2, y: -1) }
                }
            if let count = state.countLabel {
                Text(count).font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            if let elapsed { Text(elapsed).font(.system(size: 11).monospacedDigit()) }
        }
    }

    private struct Slash: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
                path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 2))
            }
        }
    }
}
