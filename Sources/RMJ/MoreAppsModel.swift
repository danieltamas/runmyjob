import AppKit
import RMJCore

/// A Mac app from More apps that Launch Services knows on this Mac.
struct InstalledCopy: Equatable {
    let url: URL
    /// Nil when there is no release version to compare.
    let version: String?
    /// The `git describe` a build from a checkout stamps (`sourceKey` in the registry).
    let source: String?

    init(url: URL, info: NSDictionary?, sourceKey: String?) {
        self.url = url
        // A source key that is present but not text still marks a source build: its placeholder version is no release.
        source = sourceKey.flatMap { info?[$0] }.map { ($0 as? String) ?? "" }
        version = InstalledVersion.comparable(shortVersion: info?["CFBundleShortVersionString"] as? String, sourceStamp: source)
    }
}

/// More apps' state. The list comes from the owner's registry: the bundled copy first, then the last one read into
/// `<home>/registry`, then a fresh read when the pane opens (at most hourly) or on the refresh button. A read that fails
/// or is refused changes nothing on the cards; the header says why. Nothing else is asked of the network for this page.
@MainActor
final class MoreAppsModel: ObservableObject {
    @Published private(set) var registry: AppRegistry?
    /// When the shown list was read; nil for the bundled copy.
    @Published private(set) var readAt: Date?
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var installed: [String: InstalledCopy] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var checking = false

    private let store: RegistryStore
    private var started = false

    init(home: RMJHome = RMJHome()) {
        store = RegistryStore(directory: home.url.appendingPathComponent("registry", isDirectory: true))
    }

    /// Every app in the registry but RMJ itself, in the registry's order.
    var apps: [RegistryApp] { registry?.shown(excluding: "rmj") ?? [] }

    /// The pane opened (`byPress` false) or the refresh button was pressed.
    func refresh(byPress: Bool) {
        if !started {
            started = true
            showStartingList()
        }
        readInstalled()
        guard !checking, RegistryRefresh.isDue(lastRead: readAt, now: Date(), byPress: byPress) else { return }
        checking = true
        Task {
            await read()
            checking = false
        }
    }

    /// The newest list that still validates: the stored read, else the bundle's copy.
    private func showStartingList() {
        let bundled = Self.bundled()
        if let stored = store.load(), case let .accepted(list) = RegistryDecoder.read(stored.data),
           (list.updated ?? .distantPast) >= (bundled?.updated ?? .distantPast) {
            show(list, readAt: stored.readAt)
        } else if let bundled {
            // An app update ships a newer snapshot than an old stored read.
            show(bundled, readAt: nil)
        } else {
            problem = "This copy of RMJ has no app list. Refresh to read it."
        }
    }

    static func bundled() -> AppRegistry? {
        guard let url = Self.resource("apps.json"), let data = try? Data(contentsOf: url),
              case let .accepted(list) = RegistryDecoder.read(data) else { return nil }
        return list
    }

    /// The bundled snapshot (Support/Registry, copied into the bundle by scripts/bundle.sh).
    private static func resource(_ path: String) -> URL? { SupportFiles.locate("Registry/\(path)") }

    private func show(_ list: AppRegistry, readAt: Date?) {
        registry = list
        self.readAt = readAt
        for app in list.apps where icons[app.icon] == nil {
            guard AppRegistry.iconURL(app.icon) != nil else { continue }
            // Cached and bundled bytes pass the same check as a download.
            let candidates = [store.icon(path: app.icon), Self.resource(app.icon).flatMap { try? Data(contentsOf: $0) }]
            if let data = candidates.lazy.compactMap({ $0 }).first(where: RegistryIcon.accepts), let image = NSImage(data: data) {
                icons[app.icon] = image
            }
        }
    }

    private func read() async {
        let agent = "RMJ/\((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0")"
        let answer = await RegistryDownload.get(AppRegistry.fileURL, userAgent: agent, maxBytes: RegistryDecoder.maxBytes)
        guard case let .data(data) = answer else {
            if case let .failed(reason) = answer { problem = "The app list could not be refreshed: \(reason)" }
            return
        }
        switch RegistryDecoder.read(data) {
        case let .accepted(list):
            let now = Date()
            do {
                try store.save(data, readAt: now)
                problem = nil
            } catch {
                problem = "The app list was read but could not be saved, so the next launch reads it again."
            }
            show(list, readAt: now)
            // An app new to the list may already be on this Mac: the scan before the read only knew the old list.
            readInstalled()
            await fetchIcons(list.apps, userAgent: agent)
        case .newerSchema:
            problem = "This version of RMJ can't read the newer app list. Update RMJ to see it."
        case let .refused(reason):
            problem = "The app list could not be used: \(reason)"
        }
    }

    /// Icons the store does not hold yet. A changed icon always has a new path, so a stored one is never read again;
    /// a failed one keeps the bundle's or the fallback glyph.
    private func fetchIcons(_ apps: [RegistryApp], userAgent: String) async {
        // One deadline for the list and its icons: the contract allows 30 s overall.
        let deadline = Date().addingTimeInterval(30)
        for app in apps where store.icon(path: app.icon).map(RegistryIcon.accepts) != true && Date() < deadline {
            guard let url = AppRegistry.iconURL(app.icon),
                  case let .data(data) = await RegistryDownload.get(url, userAgent: userAgent, maxBytes: RegistryIcon.maxBytes),
                  RegistryIcon.accepts(data), let image = NSImage(data: data) else { continue }
            try? store.saveIcon(data, path: app.icon)
            icons[app.icon] = image
        }
    }

    private func readInstalled() {
        var found: [String: InstalledCopy] = [:]
        for app in registry?.apps ?? [] {
            guard let mac = app.mac, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mac.bundleID) else { continue }
            // Read from disk each time: Bundle caches its Info.plist, so an update made while RMJ runs would not show.
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            found[mac.bundleID] = InstalledCopy(url: url, info: info, sourceKey: mac.sourceKey)
        }
        installed = found
    }
}
