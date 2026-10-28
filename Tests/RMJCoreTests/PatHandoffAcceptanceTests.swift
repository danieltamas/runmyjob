import Darwin
import Foundation
import Testing
import RMJCore

private func withPatHome(_ body: (RMJHome, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RMJ-PatHandoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = RMJHome(environment: ["RMJ_HOME": root.appendingPathComponent("home").path])
    try home.prepare()
    try body(home, root)
}

private func handoffPath(_ home: RMJHome, account: String = "test-account") -> URL {
    home.url.appendingPathComponent("handoff", isDirectory: true).appendingPathComponent(account)
}

private func patMode(_ url: URL) throws -> mode_t {
    var info = stat()
    try #require(stat(url.path, &info) == 0)
    return info.st_mode & 0o7777
}

@Test("An offered secret can be taken exactly once")
func patHandoffIsConsumedExactlyOnce() throws {
    try withPatHome { home, _ in
        let handoff = PatHandoff(home: home)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try handoff.offer("test secret", account: "test-account", now: now)
        #expect(try handoff.take(account: "test-account", now: now) == "test secret")
        #expect(try handoff.take(account: "test-account", now: now) == nil)
        #expect(!FileManager.default.fileExists(atPath: handoffPath(home).path))
    }
}

@Test("An expired handoff returns nil and removes its file")
func patHandoffExpiresAndRemovesFile() throws {
    try withPatHome { home, _ in
        let handoff = PatHandoff(home: home)
        let offered = Date(timeIntervalSince1970: 1_800_000_000)
        try handoff.offer("test secret", account: "test-account", now: offered)
        #expect(try handoff.take(account: "test-account",
                                 now: offered.addingTimeInterval(PatHandoff.lifetime + 1)) == nil)
        #expect(!FileManager.default.fileExists(atPath: handoffPath(home).path))
    }
}

@Test("A handoff remains valid at exactly its lifetime")
func patHandoffAcceptsExactLifetime() throws {
    try withPatHome { home, _ in
        let handoff = PatHandoff(home: home)
        let offered = Date(timeIntervalSince1970: 1_800_000_000)
        try handoff.offer("boundary secret", account: "test-account", now: offered)
        #expect(try handoff.take(account: "test-account",
                                 now: offered.addingTimeInterval(PatHandoff.lifetime)) == "boundary secret")
    }
}

@Test("A clock before the offer cannot retrieve the secret")
func patHandoffRejectsClockBeforeOffer() throws {
    try withPatHome { home, _ in
        let handoff = PatHandoff(home: home)
        let offered = Date(timeIntervalSince1970: 1_800_000_000)
        try handoff.offer("test secret", account: "test-account", now: offered)
        #expect(try handoff.take(account: "test-account", now: offered.addingTimeInterval(-1)) == nil)
    }
}

@Test("Offer creates private directory and file modes")
func patHandoffCreatesPrivateModes() throws {
    try withPatHome { home, _ in
        try PatHandoff(home: home).offer("test secret", account: "test-account")
        #expect(try patMode(handoffPath(home).deletingLastPathComponent()) == 0o700)
        #expect(try patMode(handoffPath(home)) == 0o600)
    }
}

@Test("Offer repairs an existing wider directory mode")
func patHandoffRepairsDirectoryMode() throws {
    try withPatHome { home, _ in
        let directory = handoffPath(home).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try #require(try patMode(directory) == 0o755)
        try PatHandoff(home: home).offer("test secret", account: "test-account")
        #expect(try patMode(directory) == 0o700)
        #expect(try patMode(handoffPath(home)) == 0o600)
    }
}

@Test("Invalid accounts are rejected without filesystem writes",
      arguments: ["../outside", "nested/account", "..", ".", "", "caf\u{00E9}"])
func patHandoffRejectsInvalidAccounts(account: String) throws {
    try withPatHome { home, root in
        let files = FileManager.default
        let outside = root.appendingPathComponent("outside")
        let sentinel = Data("unchanged".utf8)
        try sentinel.write(to: outside)
        let before = try files.subpathsOfDirectory(atPath: root.path).sorted()
        let handoff = PatHandoff(home: home)
        #expect(throws: PatHandoff.Failure.invalidAccount) {
            try handoff.offer("test secret", account: account)
        }
        #expect(throws: PatHandoff.Failure.invalidAccount) {
            try handoff.take(account: account)
        }
        #expect(try files.subpathsOfDirectory(atPath: root.path).sorted() == before)
        #expect(try Data(contentsOf: outside) == sentinel)
        #expect(try files.contentsOfDirectory(atPath: home.url.path).isEmpty)
    }
}

@Test("Offer replaces a planted symlink without modifying its destination")
func patHandoffReplacesSymlinkWithoutFollowingIt() throws {
    try withPatHome { home, root in
        let files = FileManager.default
        let target = handoffPath(home)
        let destination = root.appendingPathComponent("outside")
        try Data("old content".utf8).write(to: destination)
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: target, withDestinationURL: destination)
        let handoff = PatHandoff(home: home)
        try handoff.offer("new secret", account: "test-account")
        var info = stat()
        try #require(lstat(target.path, &info) == 0)
        #expect(info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        #expect(try Data(contentsOf: destination) == Data("old content".utf8))
        #expect(try handoff.take(account: "test-account") == "new secret")
        #expect(try Data(contentsOf: destination) == Data("old content".utf8))
    }
}

@Test("Newlines and Unicode in a secret round-trip exactly")
func patHandoffPreservesNewlinesAndUnicode() throws {
    try withPatHome { home, _ in
        let secret = "\nfirst\n\u{0219}\u{1F512}\u{65E5}\u{672C}\ne\u{0301}\n\n"
        let handoff = PatHandoff(home: home)
        try handoff.offer(secret, account: "test-account")
        let received = try #require(try handoff.take(account: "test-account"))
        #expect(Array(received.utf8) == Array(secret.utf8))
    }
}
