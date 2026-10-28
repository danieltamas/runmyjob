import Foundation

/// The per-field rules of the registry contract. Every string is checked as printable ASCII before any pattern, so
/// a character escaped in the JSON (an em dash, Arabic-Indic digits, a bidi mark) never reaches a card.
enum RegistryRules {
    /// For fields the producer caps by pattern only: the file's own 64 KiB bounds them, and a cap of ours would hide
    /// a card the registry accepts.
    private static let unbounded = RegistryDecoder.maxBytes

    static func app(_ value: Any) -> RegistryApp? {
        guard let entry = value as? [String: Any],
              let id = plain(entry["id"], 32), id.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,31}/) != nil,
              let name = plain(entry["name"], 32), let platform = plain(entry["platform"], 32),
              let pitch = plain(entry["pitch"], 80), let detail = plain(entry["detail"], 200),
              let kind = plain(entry["kind"], 16).flatMap(RegistryApp.Kind.init(rawValue:)),
              let repo = plain(entry["repo"], unbounded), isRepo(repo),
              let site = nullable(entry["site"], siteURL),
              let icon = plain(entry["icon"], unbounded), isIconPath(icon),
              let iconShape = plain(entry["iconShape"], 16).flatMap(RegistryApp.IconShape.init(rawValue:)),
              let install = plain(entry["install"], 120), isInstall(install),
              let mac = nullable(entry["mac"], mac),
              let hue = entry["hue"] as? [String: Any],
              let dark = color(hue["dark"]), let light = color(hue["light"]),
              let latest = nullable(entry["latest"], { release($0, repo: repo) }) else { return nil }
        return RegistryApp(id: id, name: name, kind: kind, platform: platform, pitch: pitch, detail: detail, repo: repo,
                           site: site, icon: icon, iconShape: iconShape, install: install, mac: mac, dark: dark,
                           light: light, latest: latest)
    }

    /// Present and null is `.some(nil)`; absent, or present and failing `parse`, is nil.
    static func nullable<T>(_ value: Any?, _ parse: (Any) -> T?) -> T?? {
        guard let value else { return nil }
        if value is NSNull { return .some(nil) }
        return parse(value).map { .some($0) }
    }

    /// A JSON integer: Foundation also answers `as? Int` for `true` and `1.0`, which the contract refuses.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              "csilqCSILQ".contains(String(cString: number.objCType)) else { return nil }
        return number.intValue
    }

    static func plain(_ value: Any?, _ limit: Int) -> String? {
        guard let text = value as? String, !text.isEmpty, text.unicodeScalars.count <= limit,
              text.unicodeScalars.allSatisfy({ (0x20 ... 0x7E).contains($0.value) }),
              !text.allSatisfy({ $0 == " " }) else { return nil }
        return text
    }

    /// `YYYY-MM-DDTHH:MM:SSZ` that is a real time: the formatter alone turns February 30 into March 2.
    static func time(_ value: Any) -> Date? {
        guard let text = plain(value, 20),
              text.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    static func isRepo(_ repo: String) -> Bool {
        guard let match = repo.wholeMatch(of: /danieltamas\/([A-Za-z0-9._-]+)/) else { return false }
        return match.1 != "." && match.1 != ".."
    }

    static func isIconPath(_ path: String) -> Bool {
        path.wholeMatch(of: /icons\/[a-z0-9-]+\.png/) != nil
    }

    static func allowedURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text), parts.scheme == "https",
              let host = parts.host?.lowercased(), AppRegistry.hosts.contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        return parts.url
    }

    static func siteURL(_ value: Any) -> URL? {
        plain(value, 100).flatMap(allowedURL)
    }

    /// One of two commands, matched whole: a tap formula or cask, or one https script piped into a shell.
    static func isInstall(_ command: String) -> Bool {
        if command.wholeMatch(of: /brew install (--cask )?danieltamas\/tap\/[a-z0-9-]{1,32}/) != nil { return true }
        guard let curl = command.wholeMatch(of: /curl -fsSL (https:\/\/[A-Za-z0-9.-]+\/[A-Za-z0-9._\/-]{1,80}) \| (sh|bash)/)
        else { return false }
        return allowedURL(String(curl.1)) != nil
    }

    static func mac(_ value: Any) -> RegistryApp.Mac? {
        guard let mac = value as? [String: Any],
              let bundleID = plain(mac["bundleId"], unbounded), bundleID.wholeMatch(of: /ro\.danieltamas\.[a-z0-9.-]+/) != nil,
              let sourceKey = nullable(mac["sourceKey"], { plain($0, 40).flatMap { $0.wholeMatch(of: /[A-Za-z]{1,32}Source/) != nil ? $0 : nil } })
        else { return nil }
        return RegistryApp.Mac(bundleID: bundleID, sourceKey: sourceKey)
    }

    static func color(_ value: Any?) -> UInt32? {
        guard let text = plain(value, 7), text.wholeMatch(of: /#[0-9A-F]{6}/) != nil else { return nil }
        return UInt32(text.dropFirst(), radix: 16)
    }

    static func release(_ value: Any, repo: String) -> RegistryApp.Release? {
        guard let latest = value as? [String: Any],
              let version = plain(latest["version"], 32),
              version.wholeMatch(of: /[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}/) != nil,
              let tag = plain(latest["tag"], 33), tag == version || tag == "v" + version,
              let publishedAt = latest["publishedAt"].flatMap(time),
              let link = plain(latest["url"], unbounded), link == "https://github.com/\(repo)/releases/tag/\(tag)",
              let url = URL(string: link) else { return nil }
        return RegistryApp.Release(version: version, tag: tag, publishedAt: publishedAt, url: url)
    }
}
