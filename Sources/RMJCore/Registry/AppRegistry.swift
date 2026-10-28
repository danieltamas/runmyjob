import Foundation

/// One app in the owner's registry (github.com/danieltamas/registry), as Settings > More apps shows it.
public struct RegistryApp: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case menuBar = "menu-bar", terminal }
    /// `macos`: already a macOS icon with its own margin and shape. `fullBleed`: a square mark, inset and rounded.
    public enum IconShape: String, Sendable { case macos, fullBleed = "full-bleed" }

    public struct Mac: Sendable, Equatable {
        public let bundleID: String
        /// The Info.plist key a build from a checkout stamps with `git describe`.
        public let sourceKey: String?

        public init(bundleID: String, sourceKey: String?) {
            self.bundleID = bundleID
            self.sourceKey = sourceKey
        }
    }

    public struct Release: Sendable, Equatable {
        public let version: String
        public let tag: String
        public let publishedAt: Date
        public let url: URL

        public init(version: String, tag: String, publishedAt: Date, url: URL) {
            self.version = version
            self.tag = tag
            self.publishedAt = publishedAt
            self.url = url
        }
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let platform: String
    public let pitch: String
    public let detail: String
    /// GitHub's "danieltamas/<name>".
    public let repo: String
    public let site: URL?
    /// "icons/<name>.png", relative to the registry.
    public let icon: String
    public let iconShape: IconShape
    public let install: String
    /// Nil for an app with no Mac bundle.
    public let mac: Mac?
    public let dark: UInt32
    public let light: UInt32
    /// Nil: no release yet.
    public let latest: Release?

    public init(id: String, name: String, kind: Kind, platform: String, pitch: String, detail: String, repo: String,
                site: URL?, icon: String, iconShape: IconShape, install: String, mac: Mac?, dark: UInt32, light: UInt32,
                latest: Release?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.platform = platform
        self.pitch = pitch
        self.detail = detail
        self.repo = repo
        self.site = site
        self.icon = icon
        self.iconShape = iconShape
        self.install = install
        self.mac = mac
        self.dark = dark
        self.light = light
        self.latest = latest
    }

    public var repoURL: URL { URL(string: "https://github.com/\(repo)")! }
}

/// The accepted part of the registry file.
public struct AppRegistry: Sendable, Equatable {
    public static let schema = 1
    /// Entries past this are counted as left out, not read: the producer caps the file here today.
    public static let maxEntries = 32
    private static let base = "https://raw.githubusercontent.com/danieltamas/registry/main/"
    public static let fileURL = URL(string: base + "apps.json")!
    /// Every link a card opens and every address inside an install command is on one of these.
    static let hosts: Set<String> = ["github.com", "raw.githubusercontent.com", "getrun.dev", "getcloak.dev"]

    public static func iconURL(_ path: String) -> URL? {
        RegistryRules.isIconPath(path) ? URL(string: base + path) : nil
    }

    /// When the registry's refresh last changed a release; nil before its first one.
    public let updated: Date?
    /// The entries that passed every rule, in file order.
    public let apps: [RegistryApp]
    /// Entries that failed a rule: most likely ones this RMJ is too old to read.
    public let leftOut: Int

    public init(updated: Date?, apps: [RegistryApp], leftOut: Int) {
        self.updated = updated
        self.apps = apps
        self.leftOut = leftOut
    }

    public func shown(excluding id: String) -> [RegistryApp] {
        apps.filter { $0.id != id }
    }
}

public enum RegistryRead: Sendable, Equatable {
    case accepted(AppRegistry)
    /// A schema this RMJ does not know: the last good list stays, and the pane asks for an update.
    case newerSchema(Int)
    case refused(reason: String)
}

/// The registry contract's consumer side (docs/CONSUMER.md in the registry, scripts/validate.py its code form). A top
/// level that fails refuses the whole file; an entry that fails is left out and counted. Unknown keys are ignored, so
/// a field added within schema 1 never breaks a shipped RMJ.
public enum RegistryDecoder {
    public static let maxBytes = 65_536

    public static func read(_ data: Data) -> RegistryRead {
        guard data.count <= maxBytes else { return .refused(reason: "The app list is larger than 64 KiB.") }
        guard data.allSatisfy({ $0 < 0x80 }) else { return .refused(reason: "The app list is not plain ASCII.") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .refused(reason: "The app list is not a JSON object.")
        }
        guard let schema = RegistryRules.integer(root["schema"]) else {
            return .refused(reason: "The app list names no schema number.")
        }
        if schema > AppRegistry.schema { return .newerSchema(schema) }
        guard schema == AppRegistry.schema else { return .refused(reason: "The app list's schema \(schema) is unknown.") }
        guard let updated = RegistryRules.nullable(root["updated"], RegistryRules.time) else {
            return .refused(reason: "The app list's update time is not a UTC time.")
        }
        guard let entries = root["apps"] as? [Any], !entries.isEmpty else {
            return .refused(reason: "The app list has no apps.")
        }
        var apps: [RegistryApp] = []
        var ids: Set<String> = []
        for entry in entries.prefix(AppRegistry.maxEntries) {
            guard let app = RegistryRules.app(entry), !ids.contains(app.id) else { continue }
            ids.insert(app.id)
            apps.append(app)
        }
        return .accepted(AppRegistry(updated: updated, apps: apps, leftOut: entries.count - apps.count))
    }
}
