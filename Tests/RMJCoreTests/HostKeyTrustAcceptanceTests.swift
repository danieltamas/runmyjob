import CryptoKit
import Foundation
import Testing
@testable import RMJCore

struct HostKeyTrustAcceptanceTests {
    private let raw = Data([0, 1, 2, 3, 127, 128, 254, 255])
    private var key: HostKey { HostKey(type: "ssh-ed25519", base64: raw.base64EncodedString()) }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rmj-host-key-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func stub(in directory: URL, output: String) throws -> URL {
        let script = directory.appendingPathComponent("keyscan")
        let text = "#!/bin/sh\ncd -- \"$(dirname -- \"$0\")\" || exit 1\n: > started\ncat <<'RMJ_KEYS'\n"
            + output + "\nRMJ_KEYS\n"
        try Data(text.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test func fingerprintMatchesIndependentSHA256() {
        let expected = "SHA256:" + Data(SHA256.hash(data: raw)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        #expect(key.fingerprint == expected)
        #expect(!key.fingerprint.contains("="))
    }

    @Test func createsPrivateKnownHosts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private-ssh")
        let file = directory.appendingPathComponent("known_hosts")
        try HostKeyTrust(knownHosts: file).trust(key, alias: "box_1.example-2")
        #expect(try Data(contentsOf: file) == Data("box_1.example-2 ssh-ed25519 \(key.base64)\n".utf8))
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test(arguments: [false, true])
    func preservesExistingBytes(hasNewline: Bool) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("known_hosts")
        let existing = "# keep comment\nold ssh-rsa AQID" + (hasNewline ? "\n" : "")
        try Data(existing.utf8).write(to: file)
        try HostKeyTrust(knownHosts: file).trust(key, alias: "box")
        let expected = existing + (hasNewline ? "" : "\n") + "box ssh-ed25519 \(key.base64)\n"
        #expect(try Data(contentsOf: file) == Data(expected.utf8))
    }

    @Test func duplicateChangedTypeAndAliasRules() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("known_hosts")
        let trust = HostKeyTrust(knownHosts: file)
        try trust.trust(key, alias: "box")
        let original = try Data(contentsOf: file)
        try trust.trust(key, alias: "box")
        #expect(try Data(contentsOf: file) == original)
        let changed = HostKey(type: key.type, base64: "CQgH")
        #expect(throws: HostKeyTrust.Failure.changed) { try trust.trust(changed, alias: "box") }
        #expect(try Data(contentsOf: file) == original)
        try trust.trust(HostKey(type: "ssh-rsa", base64: changed.base64), alias: "box")
        try trust.trust(key, alias: "other")
        let expected = original + Data("box ssh-rsa CQgH\nother ssh-ed25519 \(key.base64)\n".utf8)
        #expect(try Data(contentsOf: file) == expected)
    }

    @Test func rejectsInvalidTrustWithoutWriting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, HostKey)] = ["", "-box", "box name", "box\nsecond", "box;id", "box/other", "box\tother", "b\u{00F6}x"]
            .map { ($0, key) } + [
                ("box", HostKey(type: key.type, base64: "%%%")),
                ("box", HostKey(type: key.type, base64: "AQID\nsecond ssh-rsa AQID")),
                ("box", HostKey(type: "ssh rsa", base64: key.base64)),
                ("box", HostKey(type: "ssh-rsa\nsecond", base64: key.base64))
            ]
        for (index, input) in cases.enumerated() {
            let directory = root.appendingPathComponent("case-\(index)")
            let file = directory.appendingPathComponent("known_hosts")
            let trust = HostKeyTrust(knownHosts: file)
            #expect(throws: HostKeyTrust.Failure.invalid) { try trust.trust(input.1, alias: input.0) }
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = Data("# existing\nold ssh-rsa AQID\n".utf8)
            try original.write(to: file)
            #expect(throws: HostKeyTrust.Failure.invalid) { try trust.trust(input.1, alias: input.0) }
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test(arguments: ["8.8.8.8", "example.com", "100.64.0.1;id"])
    func rejectsNonTailnetBeforeProcess(address: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try stub(in: root, output: "100.64.0.1 ssh-ed25519 \(key.base64)")
        let trust = HostKeyTrust(knownHosts: root.appendingPathComponent("known_hosts"), keyscan: script.path)
        await #expect(throws: HostKeyTrust.Failure.invalid) { try await trust.scan(address: address) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
    }

    @Test func scanPrefersEd25519ThenFirstValidKey() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let address = "100.64.0.1"
        let rsa = HostKey(type: "ssh-rsa", base64: "AQID")
        let ecdsa = HostKey(type: "ecdsa-sha2-nistp256", base64: "BAUG")
        let outputs: [(String, HostKey)] = [
            ("# comment\n\(address) ssh-rsa AQID\n# another\n\(address) \(ecdsa.type) BAUG\n\(address) ssh-ed25519 \(key.base64)", key),
            ("# comment\n\(address) ssh-rsa AQID\n\(address) \(ecdsa.type) BAUG", rsa),
            ("\(address) ssh-ed25519 %%%\n\(address) \(ecdsa.type) BAUG\n\(address) ssh-rsa AQID", ecdsa)
        ]
        for (output, expected) in outputs {
            let script = try stub(in: root, output: output)
            let trust = HostKeyTrust(knownHosts: root.appendingPathComponent("known_hosts"), keyscan: script.path)
            #expect(try await trust.scan(address: address) == expected)
        }
    }

    @Test(arguments: ["", "# comment\n# another", "100.64.0.1 ssh-ed25519 %%%"])
    func scanWithoutValidKeysThrowsNoKey(output: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try stub(in: root, output: output)
        let trust = HostKeyTrust(knownHosts: root.appendingPathComponent("known_hosts"), keyscan: script.path)
        do {
            _ = try await trust.scan(address: "100.64.0.1")
            Issue.record("Expected noKey")
        } catch let failure as HostKeyTrust.Failure {
            guard case .noKey = failure else {
                Issue.record("Expected noKey, got \(failure)")
                return
            }
        }
    }

    @Test func distinguishesUnknownChangedAndUnreachable() {
        for type in ["ED25519", "ECDSA", "RSA"] {
            #expect(HostKeyTrust.isUnknownKey("No \(type) host key is known for h and you have requested strict checking.Host key verification failed."))
        }
        #expect(!HostKeyTrust.isUnknownKey("REMOTE HOST IDENTIFICATION HAS CHANGED\nHost key verification failed."))
        #expect(!HostKeyTrust.isUnknownKey("Connection timed out"))
    }
}
