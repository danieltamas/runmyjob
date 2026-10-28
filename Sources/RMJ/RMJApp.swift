import AppKit
import RMJCore
import SwiftUI

@main
struct RMJApp: App {
    @StateObject private var model = PanelModel.live()
    @AppStorage("menuBarElapsed") private var elapsedInMenuBar = false

    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains(TabTiming.flag) { exit(MainActor.assumeIsolated { TabTiming.run() }) }
        if arguments.contains(ScreenshotRender.flag) {
            exit(MainActor.assumeIsolated { ScreenshotRender.run(arguments) })
        }
        // Headless keychain commands run before anything else starts: scripts/keychain-check.sh
        // asks the installed app binary what it can read.
        if arguments.first == KeychainProbe.flag {
            exit(KeychainProbe.runFromCommandLine(Array(arguments.dropFirst())))
        }
        PatHandoff(home: RMJHome()).sweepExpired()
        LoginItem.registerOnce()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(state: model.snapshot.icon, elapsed: elapsedInMenuBar ? model.snapshot.longestRunning.map(PanelFormat.duration) : nil)
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(model: model) }
    }
}

extension NSImage {
    /// The bundled template icon; `swift run` has no bundle, so it falls back to an SF Symbol.
    /// Read once: the menu bar draws it on every frame.
    static let rmjTemplate: NSImage = {
        // Without a bundle (`swift run`, the screenshot render) the checkout's Support/ holds the same file.
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf") ?? SupportFiles.locate("MenuBarIcon.pdf"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "RMJ") ?? NSImage()
    }()
}

extension NSApplication {
    /// Quits, then opens RMJ again once this process is gone: opening it while it still runs
    /// would only bring the running copy forward.
    func relaunch() {
        // `swift run` has no bundle to open again, and quitting would leave nothing running.
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", FileManager.default.isExecutableFile(atPath: Bundle.main.executablePath ?? "")
        else { return NSSound.beep() }
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Own streams, so nothing hangs on a pipe that closes with this process.
        reopen.standardInput = FileHandle.nullDevice
        reopen.standardOutput = FileHandle.nullDevice
        reopen.standardError = FileHandle.nullDevice
        reopen.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; for try in 1 2 3 4 5 6; do /usr/bin/open \"$1\" && exit 0; sleep 1; done",
                            String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        guard (try? reopen.run()) != nil else { return NSSound.beep() }
        terminate(nil)
    }
}
