import AppKit
import RMJCore
import SwiftUI

/// The README's screenshots: the real views over synthetic data, drawn by an offscreen window
/// (`RMJ --render-screenshots <dir>`, docs/SCREENSHOTS.md). Nothing is read from or written to ~/.rmj, and nothing
/// reaches the screen, so no capture permission.
@MainActor
enum ScreenshotRender {
    static let flag = "--render-screenshots"
    static let allLooksFlag = "--all-looks"
    static let stressFlag = "--stress"
    static let scaleFlag = "--scale"

    private static var scale: CGFloat = 2

    static func run(_ arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return 2 }
        let scale = arguments.firstIndex(of: scaleFlag).flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 2
        do {
            try render(to: URL(fileURLWithPath: arguments[index + 1], isDirectory: true), allLooks: arguments.contains(allLooksFlag),
                       stress: arguments.contains(stressFlag), scale: CGFloat(scale))
            return 0
        } catch {
            FileHandle.standardError.write(Data("rmj: render failed: \(error)\n".utf8))
            return 1
        }
    }

    /// Every shot of docs/SCREENSHOTS.md that the app draws, in the default look or all three.
    static func render(to directory: URL, allLooks: Bool = false, stress: Bool = false, scale: CGFloat = 2) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.scale = scale
        for look in allLooks ? Look.allCases : [Look.rmj] {
            Appearance.shared.look = look
            let suffix = look == .rmj ? "" : look == .solidGlass ? "-solid-glass" : "-solid-glass-light"
            func url(_ name: String) -> URL { directory.appendingPathComponent("\(name)\(suffix).png") }
            for (name, tab) in [("jobs", PanelTab.jobs)] {
                let model = PanelModel(snapshot: DemoShots.snapshot(stress: stress))
                model.tab = tab
                try write(PanelView(model: model, height: PanelView.height), to: url(name))
            }
            // Review-only: the whole list in one image, past the screen's height.
            try write(PanelView(model: PanelModel(snapshot: DemoShots.snapshot(stress: stress)), height: 1800), to: url("jobs-tall"))
            let destinations = PanelModel(snapshot: DemoShots.snapshot(stress: stress))
            destinations.tab = .destinations
            try write(PanelView(model: destinations, height: 1100), to: url("destinations"))
            let routing = PanelModel(snapshot: DemoShots.snapshot(stress: stress))
            routing.tab = .routing
            try write(PanelView(model: routing, height: 1500), to: url("routing"))
            let open = PanelModel(snapshot: DemoShots.snapshot(stress: stress))
            open.openJobs = ["rx-failed", "gh-queued"]
            try write(PanelView(model: open, height: 1800), to: url("jobs-open"))
            var down = DemoShots.snapshot(stress: stress)
            down.tailnet = DemoShots.tailnet(standing: .stopped)
            try write(PanelView(model: PanelModel(snapshot: down)), to: url("jobs-tailnet-down"))
            let newer = PanelModel(snapshot: DemoShots.snapshot(stress: stress))
            newer.updateStatus = .available(ReleaseInfo(version: "9.9.9", url: nil))
            try write(PanelView(model: newer), to: url("jobs-update"))
            var empty = DemoShots.snapshot(stress: stress)
            empty.jobs = []
            try write(PanelView(model: PanelModel(snapshot: empty)), to: url("jobs-empty"))
            for (name, state) in MenuBarIconState.samples {
                try write(MenuBarLabel(state: state).padding(10).background(Color(white: 0.2)), to: url("menubar-\(name)"))
            }
        }
    }

    /// An offscreen window, not `ImageRenderer`: that one leaves text fields and other AppKit-backed controls as placeholders.
    private static func write(_ view: some View, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.stillImage, true).environment(\.demoNow, DemoShots.now))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        let size = host.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }
}

extension MenuBarIconState {
    static let samples: [(String, MenuBarIconState)] = [("idle", .idle), ("running", .running(3)), ("failed", .failed), ("tailnet-down", .tailnetDown)]
}
