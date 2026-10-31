import Testing
import Foundation
import SwiftUI
import AppKit
@testable import RMJ
import RMJCore

@Suite(.serialized)
@MainActor
struct RoutingChainLayoutAcceptanceTests {
    private let contentWidth: CGFloat = 376 // 404-point panel minus its gutters.

    @Test func longDemoChainFitsInsideRoutingTab() throws {
        let model = PanelModel(snapshot: DemoShots.snapshot())
        model.tab = .routing
        let routing = try #require(model.snapshot.routing)
        #expect(routing.problem == nil)
        let rule = try #require(routing.rules.first { $0.name == "cargo repos to the rust image" })
        #expect(rule.chain.map(\.name) == ["ai-eu-1", "host-2-gamerina", "host-gamerina"])
        #expect(rule.environment == "rx-rust")

        let original = Appearance.shared.look
        defer { Appearance.shared.look = original }
        for look in Look.allCases {
            Appearance.shared.look = look

            // Positive control: the previous row's fixed-size chips cannot shrink.
            // Their combined width, arrows, spacing, indent and card padding must
            // exceed the proposal. This catches a measuring wrapper that clamps
            // every answer to 376 and would therefore conceal the regression.
            let unwrapped = measuredSize(of: HoverCard(accent: nil, action: nil) {
                HStack(spacing: 5) {
                    ForEach(Array(rule.chain.enumerated()), id: \.offset) { position, item in
                        if position > 0 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        Chip(text: item.name, color: item.isLocal ? Theme.local : Theme.textPrimary)
                    }
                    if let environment = rule.environment {
                        Chip(text: environment, color: Theme.textSecondary, style: .outline)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            })
            #expect(unwrapped.width > contentWidth,
                    "The old non-wrapping chain must expose overflow to this measurement (\(look)).")

            // Measure the real tab, not PanelView's fixed 404-point outer frame.
            // In the old implementation the HStack's minimum width propagates
            // through HoverCard and both VStacks. FlowLayout instead starts new
            // lines within the proposal after card padding and the chain indent.
            let size = measuredSize(of: RoutingTab(model: model))
            #expect(size.width.isFinite && size.width > 0)
            #expect(size.height.isFinite && size.height > 0)
            #expect(size.width <= contentWidth,
                    "Routing content needs \(size.width) points; only \(contentWidth) are available (\(look)).")
        }
    }

    private func measuredSize<V: View>(of view: V) -> CGSize {
        let hosting = NSHostingView(rootView: WidthProposal(width: contentWidth) {
            view.environment(\.stillImage, true).environment(\.demoNow, DemoShots.now)
        })
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        #expect(!window.isVisible)
        return hosting.fittingSize
    }
}

// A proposal is not a fixed frame: return the child's actual requested size,
// including any overflow. An unspecified ideal-width measurement alone would
// also allow unrelated explanatory text to request its full single-line width.
private struct WidthProposal: Layout {
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: nil))
    }
}
