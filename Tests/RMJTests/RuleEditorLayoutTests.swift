import Testing
import Foundation
import SwiftUI
import AppKit
@testable import RMJ
import RMJCore

@Suite(.serialized)
@MainActor
struct RuleEditorLayoutTests {
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

    @Test func ruleEditorKeepsPanelExactly404PointsInEveryLook() throws {
        let originalLook = Appearance.shared.look
        let originalHome = getenv("RMJ_HOME").map { String(cString: $0) }
        defer {
            Appearance.shared.look = originalLook
            if let originalHome { setenv("RMJ_HOME", originalHome, 1) }
            else { unsetenv("RMJ_HOME") }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmj-rule-editor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {
          "destinations": {
            "box-a": {
              "enabled": true, "peer_id": "nAcmeBox0001CNTRL", "ssh_alias": "box-a", "tenant": "acme",
              "roles": ["rx"], "home": "/home/builder", "max_jobs": 2, "memory_budget": "8g",
              "rx_defaults": { "cpus": 2, "memory": "4g" }
            }
          },
          "tenants": { "acme": { "owners": ["acme"] } },
          "rules": [
            { "name": "Build", "match": { "tenant": ["acme"], "command": ["cargo build"] }, "to": ["box-a"] },
            { "name": "Test", "match": { "tenant": ["acme"], "command": ["cargo test"] }, "to": ["box-a"] }
          ]
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("rules.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                             ofItemAtPath: directory.appendingPathComponent("rules.json").path)
        try #require(setenv("RMJ_HOME", directory.path, 1) == 0)
        let rules = try #require(RulesStore(home: RMJHome()).load().rules)
        #expect(rules.rules.count == 2)
        #expect(rules.destinations.count == 1)
        for look in Look.allCases {
            Appearance.shared.look = look
            let model = PanelModel(snapshot: DemoShots.snapshot())
            model.tab = .routing
            for index in [0, 1, -1] {
                model.editingRule = index
                try host(PanelView(model: model, height: 780)) { hosting in
                    #expect(hosting.fittingSize.width == 404)
                    try rasterize(hosting)
                }
            }
        }
        // More is private @State in RuleEditorCard and cannot be opened from this test.
    }
}
