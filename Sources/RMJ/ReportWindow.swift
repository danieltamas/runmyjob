import AppKit
import RMJCore
import SwiftUI

/// What the report screen shows for one job: the telemetry from the ledger and the log from disk, reloaded
/// every second while the job still writes it.
@MainActor
final class ReportModel: ObservableObject {
    let jobID: String
    @Published private(set) var report: RunReport?
    @Published private(set) var log: LogDocument?
    @Published private(set) var loaded = false
    private var task: Task<Void, Never>?

    init(jobID: String) { self.jobID = jobID }

    /// A report with its data given, for the screenshot render: nothing is read from disk.
    init(jobID: String, report: RunReport, log: LogDocument) {
        self.jobID = jobID
        self.report = report
        self.log = log
        loaded = true
    }

    /// Reloads every second while the job runs or its log is still being written; a settled job whose log has not
    /// arrived yet (a box's log is pulled after it settles) is asked again for half a minute.
    func start() {
        task?.cancel()
        task = Task { [jobID] in
            let home = RMJHome()
            let ledger = await Task.detached { Self.ledger(home) }.value
            var waited = 0
            while !Task.isCancelled {
                let job = await ledger?.job(jobID)
                let document = await Task.detached { LogDocument.load(jobID: jobID, home: home) }.value
                report = job.map { RunReport($0, now: Date()) }
                log = document
                loaded = true
                let running = job.map { !$0.state.isSettled } ?? false
                if document != nil { waited = 0 } else { waited += 1 }
                if !running, document?.isLive != true, document != nil || waited > 30 { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() { task?.cancel() }

    private nonisolated static func ledger(_ home: RMJHome) -> LedgerReader? {
        (try? Database(url: home.url.appendingPathComponent("rmj.sqlite"))).map { LedgerReader(ledger: Ledger(database: $0)) }
    }
}

/// The ledger read as one optional record, so a failed read is an absent job.
struct LedgerReader: Sendable {
    let ledger: Ledger
    func job(_ id: String) async -> JobRecord? { (try? await ledger.job(id)) ?? nil }
}

/// One report window per job, opened like the settings window: its own titled window, never another app.
@MainActor
enum ReportWindows {
    private static var open: [String: NSWindow] = [:]
    private static var models: [String: ReportModel] = [:]

    static func show(jobID: String) {
        if let window = open[jobID] {
            models[jobID]?.start()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = ReportModel(jobID: jobID)
        let host = NSHostingView(rootView: ReportView(model: model))
        // The window's size is the user's: the content must not pin it to its own ideal size.
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host
        window.title = "Run report"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
        open[jobID] = window
        models[jobID] = model
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                model.stop()
                open[jobID] = nil
                models[jobID] = nil
                token.map(NotificationCenter.default.removeObserver)
            }
        }
        model.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
