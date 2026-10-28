import AppKit
import RMJCore
import SwiftUI

/// `RMJ --time-tabs`: how long the real panel takes to settle after each tab press, over demo data (a dev check for
/// the lag between pressing a tab and seeing it).
@MainActor
enum TabTiming {
    static let flag = "--time-tabs"

    static func run() -> Int32 {
        let model = PanelModel(snapshot: DemoShots.snapshot(stress: true))
        let host = NSHostingView(rootView: PanelView(model: model, height: PanelView.height).environment(\.demoNow, DemoShots.now))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        settle(host)
        let rounds = Int(ProcessInfo.processInfo.environment["RMJ_TAB_ROUNDS"] ?? "") ?? 1
        for tab in Array(repeating: [PanelTab.destinations, .routing, .history, .jobs, .history, .routing], count: rounds).flatMap({ $0 }) {
            let began = ContinuousClock.now
            withAnimation(nil) { model.select(tab) }
            settle(host)
            let elapsed = ContinuousClock.now - began
            print("\(tab.rawValue): \(elapsed.formatted(.units(allowed: [.milliseconds], width: .narrow)))")
        }
        return 0
    }

    private static func settle(_ host: NSHostingView<some View>) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.001))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
}
