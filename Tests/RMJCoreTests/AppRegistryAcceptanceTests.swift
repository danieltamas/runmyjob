import Foundation
import Testing
@testable import RMJCore

private func appRegistryEntry(_ id: String = "sample") -> [String: Any] {
    ["id": id, "name": "Sample", "kind": "menu-bar", "platform": "macOS",
     "pitch": "A synthetic app.", "detail": "A synthetic registry fixture.",
     "repo": "danieltamas/sample", "site": "https://getrun.dev/",
     "icon": "icons/sample.png", "iconShape": "macos",
     "install": "brew install --cask danieltamas/tap/sample",
     "mac": ["bundleId": "ro.danieltamas.sample", "sourceKey": NSNull()],
     "hue": ["dark": "#5EE6E0", "light": "#0B7F86"], "latest": NSNull()]
}

private func appRegistryRelease() -> [String: Any] {
    ["version": "1.2.3", "tag": "v1.2.3", "publishedAt": "2026-10-20T09:30:00Z",
     "url": "https://github.com/danieltamas/sample/releases/tag/v1.2.3"]
}

private func appRegistryData(_ apps: [Any], updated: Any = NSNull()) throws -> Data {
    try appRegistryJSON(["schema": 1, "updated": updated, "apps": apps])
}

private func appRegistryJSON(_ object: Any) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    // Escaped non-ASCII keeps these entry failures distinct from a non-ASCII file refusal.
    let text = String(decoding: data, as: UTF8.self).unicodeScalars.map { scalar in
        scalar.value > 0x7E
            ? String(scalar).utf16.map { String(format: "\\u%04X", Int($0)) }.joined()
            : String(scalar)
    }.joined()
    return Data(text.utf8)
}

private func appRegistryAccepted(_ data: Data) throws -> AppRegistry {
    guard case let .accepted(registry) = RegistryDecoder.read(data) else {
        Issue.record("Expected an accepted registry")
        throw NSError(domain: "AppRegistryAcceptance", code: 1)
    }
    return registry
}

@Suite("App registry acceptance")
struct AppRegistryAcceptanceTests {
    @Test("valid entries retain order and decode all public fields")
    func validFieldsAndOrder() throws {
        var first = appRegistryEntry("rmj")
        first["latest"] = appRegistryRelease()
        var last = appRegistryEntry("last")
        last["kind"] = "terminal"
        last["iconShape"] = "full-bleed"
        last["mac"] = NSNull()
        last["site"] = NSNull()
        let time = "2026-10-20T09:30:00Z"
        let registry = try appRegistryAccepted(appRegistryData([first, appRegistryEntry("middle"), last], updated: time))
        let date = try #require(ISO8601DateFormatter().date(from: time))
        #expect(registry.updated == date)
        #expect(registry.leftOut == 0)
        #expect(registry.apps.map(\.id) == ["rmj", "middle", "last"])
        #expect(registry.shown(excluding: "rmj").map(\.id) == ["middle", "last"])
        #expect(registry.shown(excluding: "absent") == registry.apps)
        let app = try #require(registry.apps.first)
        #expect(app.name == "Sample")
        #expect(app.kind == .menuBar)
        #expect(app.platform == "macOS")
        #expect(app.pitch == "A synthetic app.")
        #expect(app.detail == "A synthetic registry fixture.")
        #expect(app.repo == "danieltamas/sample")
        #expect(app.repoURL.absoluteString == "https://github.com/danieltamas/sample")
        #expect(app.site == URL(string: "https://getrun.dev/"))
        #expect(app.icon == "icons/sample.png")
        #expect(app.iconShape == .macos)
        #expect(app.install == "brew install --cask danieltamas/tap/sample")
        #expect(app.mac?.bundleID == "ro.danieltamas.sample")
        #expect(app.mac != nil && app.mac?.sourceKey == nil)
        #expect(app.dark == 0x5EE6E0 && app.light == 0x0B7F86)
        let release = try #require(app.latest)
        #expect(release.version == "1.2.3" && release.tag == "v1.2.3")
        #expect(release.publishedAt == date)
        #expect(release.url.absoluteString == "https://github.com/danieltamas/sample/releases/tag/v1.2.3")
        #expect(registry.apps[1].latest == nil)
        #expect(registry.apps[2].kind == .terminal && registry.apps[2].iconShape == .fullBleed)
        #expect(registry.apps[2].mac == nil && registry.apps[2].site == nil)
    }

    @Test("invalid top levels refuse the whole file with a reason")
    func topLevelFailures() throws {
        let good = try appRegistryData([appRegistryEntry()])
        var cases = [Data("not JSON".utf8), Data("[]".utf8), Data("null".utf8),
                     Data("true".utf8), Data("1".utf8), Data("\"text\"".utf8)]
        cases.append(good + Data(repeating: 32, count: 65_537))
        cases.append(Data("{\"schema\":1,\"updated\":null,\"apps\":[],\"extra\":\"\u{2014}\"}".utf8))
        for schema in ["", "\"schema\":true,", "\"schema\":1.0,", "\"schema\":\"1\",", "\"schema\":null,", "\"schema\":0,", "\"schema\":-1,"] {
            cases.append(Data("{\(schema)\"updated\":null,\"apps\":[{}]}".utf8))
        }
        for apps in ["", ",\"apps\":null", ",\"apps\":{}", ",\"apps\":true", ",\"apps\":[]"] {
            cases.append(Data("{\"schema\":1,\"updated\":null\(apps)}".utf8))
        }
        for updated: Any in ["2026-99-99T99:99:99Z", "2026-02-30T00:00:00Z", "2026-10-20", 
                             "2026-10-20T09:30:00+00:00", "2026-10-20T09:30:00.000Z", 42, true] {
            cases.append(try appRegistryData([appRegistryEntry()], updated: updated))
        }
        cases.append(try appRegistryJSON(["schema": 1, "apps": [appRegistryEntry()]]))
        for data in cases {
            guard case let .refused(reason) = RegistryDecoder.read(data) else {
                Issue.record("Invalid top level must be refused")
                continue
            }
            #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("newer schema takes precedence over invalid remaining fields")
    func newerSchema() {
        #expect(RegistryDecoder.read(Data("{\"schema\":2}".utf8)) == .newerSchema(2))
        #expect(RegistryDecoder.read(Data("{\"schema\":2,\"updated\":false,\"apps\":null}".utf8)) == .newerSchema(2))
    }

    @Test("unknown keys are ignored and null updated is accepted")
    func unknownKeys() throws {
        var entry = appRegistryEntry()
        entry["future"] = ["anything": true]
        let registry = try appRegistryAccepted(appRegistryJSON([
            "schema": 1, "updated": NSNull(), "apps": [entry], "future": [1, 2]
        ]))
        #expect(registry.apps.map(\.id) == ["sample"])
        #expect(registry.leftOut == 0 && registry.updated == nil)
    }

    @Test("every required entry field must be present and correctly typed")
    func requiredFields() throws {
        for key in appRegistryEntry().keys.sorted() {
            var missing = appRegistryEntry("bad")
            missing.removeValue(forKey: key)
            var wrong = appRegistryEntry("bad")
            wrong[key] = 17
            for entry in [missing, wrong] {
                let registry = try appRegistryAccepted(appRegistryData([appRegistryEntry("before"), entry, appRegistryEntry("after")]))
                #expect(registry.apps.map(\.id) == ["before", "after"])
                #expect(registry.leftOut == 1)
            }
        }
    }

    @Test("unsafe entry values leave out only the offending entry")
    func entryRuleFailures() throws {
        var cases: [(String, Any)] = [
            ("id", ""), ("id", "Upper"), ("id", "-x"), ("id", String(repeating: "x", count: 33)),
            ("kind", "desktop"), ("repo", "someone/sample"), ("repo", "danieltamas/."),
            ("repo", "danieltamas/.."), ("repo", "danieltamas/a/b"),
            ("site", "http://github.com/"), ("site", "https://example.com/"),
            ("site", "https://x@github.com/"), ("site", "https://github.com:8443/"),
            ("site", "https://github.com.evil.test/"), ("site", "https://github.com/" + String(repeating: "x", count: 100)),
            ("icon", "../icons/x.png"), ("icon", "icons/X.png"), ("icon", "icons/x.jpg"),
            ("iconShape", "square"),
            ("install", "brew install danieltamas/tap/x | sh"),
            ("install", "brew install danieltamas/tap/x & y"),
            ("install", "curl -fsSL https://getrun.dev/install.sh extra | sh"),
            ("install", "curl -fsSL https://example.com/install.sh | sh"),
            ("install", "brew install danieltamas/tap/x\n"),
            ("mac", [:] as [String: String]),
            ("mac", ["bundleId": "com.example.sample", "sourceKey": NSNull()]),
            ("mac", ["bundleId": "ro.danieltamas.sample", "sourceKey": "SampleSource1"]),
            ("mac", ["bundleId": "ro.danieltamas.sample"]),
            ("hue", ["dark": "#5ee6e0", "light": "#0B7F86"]),
            ("hue", ["dark": "#5EE6E0"]),
            ("pitch", "A \u{2014} pitch")
        ]
        for (key, limit) in [("name", 32), ("platform", 32), ("pitch", 80), ("detail", 200)] {
            for value in ["", "   ", "bad\ntext", String(repeating: "x", count: limit + 1)] {
                cases.append((key, value))
            }
        }
        cases.append(("detail", String(repeating: "x", count: 300)))
        for (key, value) in cases {
            var bad = appRegistryEntry("bad")
            bad[key] = value
            let registry = try appRegistryAccepted(appRegistryData([appRegistryEntry("before"), bad, appRegistryEntry("after")]))
            #expect(registry.apps.map(\.id) == ["before", "after"], "Invalid field: \(key), \(value)")
            #expect(registry.leftOut == 1)
        }
        let scalar = try appRegistryAccepted(appRegistryData([false, appRegistryEntry()]))
        #expect(scalar.leftOut == 1 && scalar.apps.count == 1)
    }

    @Test("release subfields are required and strictly validated")
    func releaseFailures() throws {
        var releases: [[String: Any]] = []
        for key in appRegistryRelease().keys {
            var missing = appRegistryRelease()
            missing.removeValue(forKey: key)
            releases.append(missing)
            var wrong = appRegistryRelease()
            wrong[key] = true
            releases.append(wrong)
        }
        for (key, value) in [("version", "1.2"), ("version", "1234567890.2.3"),
                             ("tag", "v9.9.9"), ("publishedAt", "2026-99-99T99:99:99Z"),
                             ("publishedAt", "2026-02-30T00:00:00Z"),
                             ("publishedAt", "2026-10-20T09:30:00+00:00"),
                             ("url", "https://github.com/danieltamas/other/releases/tag/v1.2.3")] {
            var release = appRegistryRelease()
            release[key] = value
            releases.append(release)
        }
        var unicode = appRegistryRelease()
        unicode["version"] = "\u{0661}.2.3"
        unicode["tag"] = "v\u{0661}.2.3"
        unicode["url"] = "https://github.com/danieltamas/sample/releases/tag/v\u{0661}.2.3"
        releases.append(unicode)
        for release in releases {
            var bad = appRegistryEntry("bad")
            bad["latest"] = release
            let registry = try appRegistryAccepted(appRegistryData([bad, appRegistryEntry("good")]))
            #expect(registry.apps.map(\.id) == ["good"])
            #expect(registry.leftOut == 1)
        }
    }

    @Test("duplicates refer to earlier accepted entries only")
    func duplicateIDs() throws {
        var bad = appRegistryEntry("sample")
        bad["pitch"] = ""
        let registry = try appRegistryAccepted(appRegistryData([bad, appRegistryEntry(), appRegistryEntry(), appRegistryEntry("last")]))
        #expect(registry.apps.map(\.id) == ["sample", "last"])
        #expect(registry.leftOut == 2)
    }

    @Test("all invalid entries still produce an accepted empty list")
    func allLeftOut() throws {
        let registry = try appRegistryAccepted(appRegistryData([[:], false, NSNull()]))
        #expect(registry.apps.isEmpty && registry.leftOut == 3)
    }

    @Test("entries after the first 32 count as left out")
    func entryCap() throws {
        let ids = (0..<33).map { "app-\($0)" }
        let registry = try appRegistryAccepted(appRegistryData(ids.map { appRegistryEntry($0) }))
        #expect(registry.apps.map(\.id) == Array(ids.prefix(32)))
        #expect(registry.leftOut == 1)
        // Invalid early entries must not make room for entries past the input cap.
        var entries: [Any] = ids.prefix(32).map { appRegistryEntry($0) }
        entries[0] = false
        entries.append(appRegistryEntry("past-cap"))
        entries.append(["id": "invalid-past-cap"])
        let capped = try appRegistryAccepted(appRegistryData(entries))
        #expect(capped.apps.map(\.id) == Array(ids[1..<32]))
        #expect(capped.leftOut == 3)
    }

    @Test("allowed install forms hosts and field boundaries are accepted")
    func validBoundaries() throws {
        for host in ["github.com", "raw.githubusercontent.com", "getrun.dev", "getcloak.dev"] {
            for shell in ["sh", "bash"] {
                var entry = appRegistryEntry()
                entry["site"] = "https://\(host)/"
                entry["install"] = "curl -fsSL https://\(host)/install.sh | \(shell)"
                entry["mac"] = ["bundleId": "ro.danieltamas.sample", "sourceKey": "SampleSource"]
                let registry = try appRegistryAccepted(appRegistryData([entry]))
                #expect(registry.leftOut == 0 && registry.apps.first?.mac?.sourceKey == "SampleSource")
            }
        }
        var entry = appRegistryEntry(String(repeating: "x", count: 32))
        for (key, limit) in [("name", 32), ("platform", 32), ("pitch", 80), ("detail", 200)] {
            entry[key] = String(repeating: "x", count: limit)
        }
        entry["install"] = "brew install danieltamas/tap/x"
        var release = appRegistryRelease()
        release["tag"] = "1.2.3"
        release["url"] = "https://github.com/danieltamas/sample/releases/tag/1.2.3"
        entry["latest"] = release
        #expect(try appRegistryAccepted(appRegistryData([entry])).leftOut == 0)
    }

    @Test("registry endpoints accept only safe icon paths")
    func endpoints() {
        #expect(AppRegistry.schema == 1)
        #expect(AppRegistry.fileURL.absoluteString == "https://raw.githubusercontent.com/danieltamas/registry/main/apps.json")
        #expect(AppRegistry.iconURL("icons/sample-2.png")?.absoluteString
            == "https://raw.githubusercontent.com/danieltamas/registry/main/icons/sample-2.png")
        for path in ["", "icons/.png", "icons/X.png", "icons/x.png?x=1", "../icons/x.png", "icons/../x.png", 
                     "/icons/x.png", "https://example.com/x.png", "icons/x.png\n"] {
            #expect(AppRegistry.iconURL(path) == nil)
        }
    }

    @Test("bundled registry and every referenced icon are valid")
    func bundledSnapshot() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Support/Registry")
        let registry = try appRegistryAccepted(Data(contentsOf: root.appendingPathComponent("apps.json")))
        #expect(registry.leftOut == 0)
        #expect(registry.apps.contains { $0.id == "rmj" })
        for app in registry.apps {
            let icon = root.appendingPathComponent(app.icon)
            #expect(FileManager.default.fileExists(atPath: icon.path))
            #expect(RegistryIcon.accepts(try Data(contentsOf: icon)))
        }
    }
}
