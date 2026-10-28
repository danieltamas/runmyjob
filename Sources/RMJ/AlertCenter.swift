import AppKit
import RMJCore
import UserNotifications

/// Raises the notifications `NotificationPlanner` decides on and keeps the release check. The panel loop feeds it each
/// fresh snapshot; it never reads the ledger itself.
@MainActor
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    private static let repo = "danieltamas/runmyjob"
    private static let openLog = "ro.danieltamas.rmj.open-log"
    private static let category = "ro.danieltamas.rmj.job"
    private static let checkInterval: TimeInterval = 6 * 3600

    /// Opened on the first snapshot: the screenshot render builds a model and must not touch the real home.
    private lazy var planner: NotificationPlanner? = {
        let home = RMJHome()
        let targets = runnerTargets
        return (try? Database(url: home.url.appendingPathComponent("rmj.sqlite"))).map {
            NotificationPlanner(home: home, archive: LogArchive(database: $0, directory: home.url.appendingPathComponent("logs")),
                                secrets: { targets.value.compactMap { try? Keychain().read(account: "rmj.pat.\($0)") } })
        }
    }()
    /// The runner targets whose PATs must never reach a notification; read from the Keychain (never the one-time handoff, which a read would consume) when a notice is built.
    private let runnerTargets = RunnerTargets()

    private final class RunnerTargets: @unchecked Sendable {
        private let lock = NSLock()
        private var targets: [String] = []
        var value: [String] {
            get { lock.withLock { targets } }
            set { lock.withLock { targets = newValue } }
        }
    }
    private let checker: UpdateChecker
    private var checkedAt = Date.distantPast
    /// Tells the panel what the last release check found.
    var onUpdate: (UpdateStatus) -> Void = { _ in }

    override init() {
        let installed = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        checker = UpdateChecker(repo: Self.repo, installed: installed) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        super.init()
        guard Self.hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let action = UNNotificationAction(identifier: Self.openLog, title: "Open log", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [action], intentIdentifiers: [])])
    }

    /// `swift run` and the screenshot render have no bundle, and the notification center traps without one.
    private static var hasBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func handle(_ snapshot: PanelSnapshot) {
        if case .valid(let rules, _)? = snapshot.rulesState {
            runnerTargets.value = rules.destinations.values.flatMap { $0.runnerTargets ?? [] }
        }
        let availability = Self.availability(snapshot)
        let running = snapshot.jobs.filter { $0.state == .running }
        let jobs = snapshot.jobs + snapshot.history
        Task { [weak self] in
            guard let self, let planner else { return }
            let settings = NotificationSettings.load(home: RMJHome())
            let notices = await planner.settled(jobs, settings: settings)
                + planner.unreachable(running: running, availability: availability, settings: settings)
            for notice in notices { post(notice) }
        }
        checkForUpdate(force: false)
    }

    func checkForUpdate(force: Bool) {
        guard force || Date().timeIntervalSince(checkedAt) >= Self.checkInterval else { return }
        checkedAt = Date()
        Task { [checker, onUpdate] in onUpdate(await checker.check()) }
    }

    private static func availability(_ snapshot: PanelSnapshot) -> [String: Availability] {
        guard case .valid(let rules, _)? = snapshot.rulesState else { return [:] }
        return rules.destinations.mapValues {
            DestinationResolver.resolve(DestinationTarget(alias: $0.sshAlias, peerID: $0.peerID), in: snapshot.tailnet)
        }
    }

    private func post(_ notice: JobNotice) {
        guard Self.hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.categoryIdentifier = Self.category
        if let path = notice.logPath?.path { content.userInfo = ["log": path] }
        center.add(UNNotificationRequest(identifier: "\(notice.kind.rawValue)-\(notice.jobID)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["log"] as? String else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }
}
