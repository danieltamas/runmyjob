import Testing
import Foundation
import SwiftUI
import AppKit
@testable import RMJ
import RMJCore

@Suite(.serialized)
@MainActor
struct PanelLayoutTests {
    private let panelShots = ["jobs", "jobs-open", "jobs-tall", "jobs-tailnet-down", "jobs-empty", "destinations", "routing"]
    private let iconShots = ["menubar-idle", "menubar-running", "menubar-failed", "menubar-tailnet-down"]
    private let suffixes = ["", "-solid-glass", "-solid-glass-light"]

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-panel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func checkShots(in directory: URL) throws {
        for suffix in suffixes {
            for name in panelShots + iconShots {
                let url = directory.appendingPathComponent(name + suffix + ".png")
                let data = try Data(contentsOf: url)
                #expect(!data.isEmpty, "Empty PNG: \(url.lastPathComponent)")
                let bitmap = try #require(NSBitmapImageRep(data: data))
                #expect(bitmap.pixelsHigh > 0)
                if panelShots.contains(name) { #expect(bitmap.pixelsWide == 808) }
            }
        }
    }

    @Test func screenshotsCoverEveryStateAndLookAtTwoTimesScale() throws {
        let original = Appearance.shared.look
        defer { Appearance.shared.look = original }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try ScreenshotRender.render(to: directory, allLooks: true, stress: false, scale: 2)
        try checkShots(in: directory)
    }

    @Test func stressScreenshotsCoverEveryStateAndLook() throws {
        let original = Appearance.shared.look
        defer { Appearance.shared.look = original }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try ScreenshotRender.render(to: directory, allLooks: true, stress: true, scale: 2)
        try checkShots(in: directory)
    }

    // Keep the never-shown window alive until after measurement and rasterization.
    private func host<V: View>(_ view: V, inspect: (NSHostingView<AnyView>) throws -> Void) throws {
        let root = AnyView(view.environment(\.stillImage, true).environment(\.demoNow, DemoShots.now))
        let hosting = NSHostingView(rootView: root)
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        #expect(!window.isVisible)
        try inspect(hosting)
    }

    private func rasterize(_ host: NSView) throws {
        let size = host.bounds.size
        #expect(size.width > 0 && size.height > 0)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(!png.isEmpty)
    }

    @Test func longJobRowFitsAndKeepsFullTitle() throws {
        let original = Appearance.shared.look
        defer { Appearance.shared.look = original }
        let repo = "acme/" + String(repeating: "repository", count: 4) + "abc"
        let workflow = String(repeating: "workflow ", count: 6) + "builds"
        let reason = String(repeating: "probe failed ", count: 9) + "bad"
        #expect(repo.count == 48 && workflow.count == 60 && reason.count == 120)
        for look in Look.allCases {
            Appearance.shared.look = look
            for expanded in [false, true] {
                var heights: [CGFloat] = []
                for long in [false, true] {
                    let record = JobRecord(id: "synthetic-row", repo: long ? repo : "acme/app",
                        command: long ? workflow : "ci", location: "local",
                        fallbackReason: long ? reason : "offline", environment: "mac", state: .failed,
                        queuedAt: DemoShots.now)
                    let row = JobRowPresentation(record, now: DemoShots.now)
                    let model = PanelModel(snapshot: PanelSnapshot(now: DemoShots.now, tailnet: DemoShots.tailnet(), jobs: [record]))
                    model.tails[record.id] = .note("pending")
                    try host(JobRowView(row: row, expanded: expanded, model: model, toggle: {}).frame(width: 376)) { hosting in
                        #expect(hosting.fittingSize.width <= 376)
                        heights.append(hosting.fittingSize.height)
                        try rasterize(hosting)
                        if long {
                            #expect(row.title == repo)
                        }
                    }
                }
                #expect(heights[1] >= heights[0])
                if !expanded {
                    #expect(heights[1] > heights[0])
                }
                #expect(heights[1] - heights[0] <= 80)
            }
        }
    }

    @Test func panelIsExactly404PointsInEveryTabAndLook() throws {
        let original = Appearance.shared.look
        defer { Appearance.shared.look = original }
        for look in Look.allCases {
            Appearance.shared.look = look
            for tab in [PanelTab.jobs, .destinations, .routing] {
                let model = PanelModel(snapshot: DemoShots.snapshot())
                model.tab = tab
                try host(PanelView(model: model, height: 780)) { hosting in
                    #expect(hosting.fittingSize.width == 404)
                    try rasterize(hosting)
                }
            }
        }
    }

    @Test func emptyTabsRenderInEveryLookWithInvalidRules() throws {
        let original = Appearance.shared.look
        defer { Appearance.shared.look = original }
        let snapshot = PanelSnapshot(now: DemoShots.now, tailnet: DemoShots.tailnet(), jobs: [], destinations: [],
                                    rulesState: .invalid(path: "/synthetic/rules.json", message: "invalid JSON"))
        for look in Look.allCases {
            Appearance.shared.look = look
            for tab in PanelTab.allCases {
                let model = PanelModel(snapshot: snapshot)
                model.tab = tab
                try host(PanelView(model: model, height: 780)) { hosting in
                    #expect(hosting.fittingSize.width == 404)
                    try rasterize(hosting)
                }
            }
        }
    }
}
