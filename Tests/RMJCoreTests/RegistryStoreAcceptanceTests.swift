import Foundation
import Testing
@testable import RMJCore

private func registryStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("registry-acceptance-\(UUID().uuidString)")
}

private func registryStorePNG(width: UInt32 = 256, height: UInt32 = 256) -> Data {
    var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
    for value in [width, height] {
        bytes += [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
                  UInt8((value >> 8) & 255), UInt8(value & 255)]
    }
    return Data(bytes)
}

private func registryStoreBody() -> Data {
    Data("""
    {
      "schema": 1, "updated": null,
      "apps": [
        {"id":"sample","name":"Sample","kind":"menu-bar","platform":"macOS",
         "pitch":"Synthetic app.","detail":"Synthetic fixture.","repo":"danieltamas/sample",
         "site":null,"icon":"icons/sample.png","iconShape":"macos",
         "install":"brew install danieltamas/tap/sample","mac":null,
         "hue":{"dark":"#5EE6E0","light":"#0B7F86"},"latest":null},
        {"id":"invalid"}
      ]
    }

    """.utf8)
}

private func registryStoreAccepted(_ data: Data) throws -> AppRegistry {
    guard case let .accepted(registry) = RegistryDecoder.read(data) else {
        Issue.record("Expected accepted stored bytes")
        throw NSError(domain: "RegistryStoreAcceptance", code: 1)
    }
    return registry
}

@Suite("Registry store acceptance")
struct RegistryStoreAcceptanceTests {
    @Test("only bounded 256 by 256 PNG headers are accepted")
    func iconValidation() {
        #expect(RegistryIcon.maxBytes == 65_536)
        let header = registryStorePNG()
        #expect(RegistryIcon.accepts(header))
        #expect(!RegistryIcon.accepts(registryStorePNG(width: 128, height: 128)))
        #expect(!RegistryIcon.accepts(registryStorePNG(width: 128)))
        #expect(!RegistryIcon.accepts(registryStorePNG(height: 128)))
        #expect(!RegistryIcon.accepts(Data([255, 216, 255, 224, 0, 16, 74, 70, 73, 70])))
        #expect(!RegistryIcon.accepts(Data("random bytes".utf8)))
        #expect(!RegistryIcon.accepts(Data()))
        for count in 0..<24 {
            #expect(!RegistryIcon.accepts(Data(header.prefix(count))))
        }
        var badSignature = header
        badSignature[0] = 0
        #expect(!RegistryIcon.accepts(badSignature))
        var badChunk = header
        badChunk[12] = 0
        #expect(!RegistryIcon.accepts(badChunk))
        let atLimit = header + Data(repeating: 0, count: 65_536 - header.count)
        #expect(RegistryIcon.accepts(atLimit))
        #expect(!RegistryIcon.accepts(atLimit + Data([0])))
    }

    @Test("absent and empty stores have no saved registry")
    func emptyStore() throws {
        let directory = registryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(RegistryStore(directory: directory).load() == nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(RegistryStore(directory: directory).load() == nil)
    }

    @Test("save preserves exact bytes whitespace and read time across store instances")
    func roundTripAndPermissions() throws {
        let directory = registryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = registryStoreBody()
        let readAt = Date(timeIntervalSince1970: 1_790_000_123)
        try RegistryStore(directory: directory).save(data, readAt: readAt)
        let loaded = try #require(RegistryStore(directory: directory).load())
        #expect(loaded.data == data)
        #expect(abs(loaded.readAt.timeIntervalSince(readAt)) < 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        // Discover the raw file without prescribing an internal filename or metadata format.
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let matching = children.filter { (try? Data(contentsOf: $0)) == data }
        #expect(matching.count == 1)
        let saved = try #require(matching.first)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try Data(contentsOf: saved) == data)
    }

    @Test("a later accepted save replaces both bytes and read time")
    func replacement() throws {
        let directory = registryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RegistryStore(directory: directory)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        try store.save(registryStoreBody(), readAt: start)
        let replacement = registryStoreBody() + Data("  \n".utf8)
        try store.save(replacement, readAt: start.addingTimeInterval(90))
        let loaded = try #require(RegistryStore(directory: directory).load())
        #expect(loaded.data == replacement)
        #expect(abs(loaded.readAt.timeIntervalSince(start.addingTimeInterval(90))) < 1)
    }

    @Test("caller revalidation of stored raw bytes retains the left-out count")
    func storedBytesAreDecodedAgain() throws {
        let directory = registryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = registryStoreBody()
        let before = try registryStoreAccepted(original)
        #expect(before.leftOut == 1)
        try RegistryStore(directory: directory).save(original, readAt: Date(timeIntervalSince1970: 1_790_000_000))
        let loaded = try #require(RegistryStore(directory: directory).load())
        let after = try registryStoreAccepted(loaded.data)
        #expect(after.leftOut == before.leftOut)
        #expect(after == before)
        #expect(loaded.data == original)
    }

    @Test("icons round-trip independently by their registry paths")
    func iconsRoundTrip() throws {
        let directory = registryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RegistryStore(directory: directory)
        #expect(store.icon(path: "icons/sample.png") == nil)
        let first = registryStorePNG()
        let second = registryStorePNG() + Data([0, 1, 2])
        try store.saveIcon(first, path: "icons/sample.png")
        try store.saveIcon(second, path: "icons/sample-2.png")
        let reopened = RegistryStore(directory: directory)
        #expect(reopened.icon(path: "icons/sample.png") == first)
        #expect(reopened.icon(path: "icons/sample-2.png") == second)
        #expect(reopened.icon(path: "icons/missing.png") == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("icons/sample.png").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }


    @Test("registry metadata and icon files have private permissions")
    func privateStorePermissions() throws {
        let directory = registryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RegistryStore(directory: directory)
        try store.save(registryStoreBody(), readAt: Date(timeIntervalSince1970: 1_790_000_000))
        try store.saveIcon(registryStorePNG(), path: "icons/sample.png")
        for path in ["", "icons"] {
            let url = path.isEmpty ? directory : directory.appendingPathComponent(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        for path in ["apps.json", "read-at", "icons/sample.png"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(path).path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test("unsafe network icon paths cannot read or write outside the store")
    func unsafeIconPaths() throws {
        let root = registryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("registry")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.png")
        let sentinel = Data("unchanged".utf8)
        try sentinel.write(to: outside)
        let store = RegistryStore(directory: directory)
        try store.save(registryStoreBody(), readAt: Date(timeIntervalSince1970: 1_790_000_000))
        for path in ["../outside.png", "icons/../../outside.png", outside.path, "icons/../outside.png",
                     "icons/%2e%2e/outside.png", "icons/sample.png/../../outside.png", "sample.png",
                     "icons/X.png", "icons/sample.jpg", "icons/sample.png?x=1", "icons/sample.png\n",
                     "https://example.com/outside.png", ""] {
            #expect(throws: (any Error).self) { try store.saveIcon(registryStorePNG(), path: path) }
            #expect(store.icon(path: path) == nil)
            #expect(try Data(contentsOf: outside) == sentinel)
        }
        let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(children) == Set(["apps.json", "read-at"]))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set(["registry", "outside.png"]))
    }

    @Test("automatic reads are due exactly at one hour and presses always read")
    func refreshSchedule() {
        #expect(RegistryRefresh.interval == 3_600)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(RegistryRefresh.isDue(lastRead: nil, now: now, byPress: false))
        #expect(!RegistryRefresh.isDue(lastRead: now.addingTimeInterval(-59 * 60), now: now, byPress: false))
        #expect(!RegistryRefresh.isDue(lastRead: now.addingTimeInterval(-3_599), now: now, byPress: false))
        #expect(RegistryRefresh.isDue(lastRead: now.addingTimeInterval(-3_600), now: now, byPress: false))
        #expect(RegistryRefresh.isDue(lastRead: now.addingTimeInterval(-3_601), now: now, byPress: false))
        for lastRead: Date? in [nil, now, now.addingTimeInterval(-1), now.addingTimeInterval(-3_600)] {
            #expect(RegistryRefresh.isDue(lastRead: lastRead, now: now, byPress: true))
        }
    }

    @Test("clean source tags compare as installed releases")
    func cleanSourceTag() {
        let version = InstalledVersion.comparable(shortVersion: "0.1.0", sourceStamp: "v0.10.1")
        #expect(version == "v0.10.1")
        #expect(InstalledVersion.comparable(shortVersion: nil, sourceStamp: "0.10.1") == "0.10.1")
    }

    @Test("any non-tag source stamp prevents comparison of the placeholder")
    func sourceBuilds() {
        for stamp in ["v0.10.1-57-g73f6f78", "1a62319-dirty", "abc", "", " v1.2.3", "v1.2.3\n",
                      "v1.2", "v1.2.3-beta", "v\u{0661}.2.3"] {
            #expect(InstalledVersion.comparable(shortVersion: "0.1.0", sourceStamp: stamp) == nil)
        }
    }

    @Test("without a stamp only exact three-part ASCII short versions compare")
    func shortVersions() {
        #expect(InstalledVersion.comparable(shortVersion: "2.3.2", sourceStamp: nil) == "2.3.2")
        for version: String? in [nil, "", "2.3", "v2.3.2", "2.3.2.1", " 2.3.2", "2.3.2\n", "\u{0661}.2.3"] {
            #expect(InstalledVersion.comparable(shortVersion: version, sourceStamp: nil) == nil)
        }
    }
}
