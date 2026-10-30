import Darwin
import Foundation
import Security
import Testing
@testable import RMJCore

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private final class LockedPID: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int32?

    func store(_ value: Int32) {
        lock.withLock { storedValue = value }
    }

    func load() -> Int32? {
        lock.withLock { storedValue }
    }
}

private struct CommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RMJ-U0-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func runCommand(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws -> CommandResult {
    let process = Process()
    let outputDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: outputDirectory) }
    let stdoutURL = outputDirectory.appendingPathComponent("stdout")
    let stderrURL = outputDirectory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer { try? stdout.close(); try? stderr.close() }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return CommandResult(
        status: process.terminationStatus,
        stdout: try Data(contentsOf: stdoutURL),
        stderr: try Data(contentsOf: stderrURL)
    )
}

private func writeFixtureTree(readme: String = "RMJ\n", swiftLineCount: Int = 1) throws -> URL {
    let root = try temporaryDirectory()
    let sources = root.appendingPathComponent("Sources", isDirectory: true)
    let tests = root.appendingPathComponent("Tests", isDirectory: true)
    let docs = root.appendingPathComponent("docs", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try Data(readme.utf8).write(to: root.appendingPathComponent("README.md"))
    let swift = String(repeating: "// line\n", count: swiftLineCount)
    try Data(swift.utf8).write(to: sources.appendingPathComponent("A.swift"))
    return root
}

private func checkLint(on root: URL) throws -> CommandResult {
    try runCommand(
        "/bin/bash",
        [repositoryRoot.appendingPathComponent("scripts/check.sh").path, "--lint-only", "--root", root.path]
    )
}

private let hasRSVGConvert: Bool = {
    (try? runCommand("/usr/bin/env", ["sh", "-c", "command -v rsvg-convert >/dev/null"]).status) == 0
}()

@Test("Package declares the U0 SwiftPM layout")
func packageDeclaresRequiredTargetsAndPlatform() throws {
    let files = FileManager.default
    for directory in ["RMJCore", "RMJ", "RMJCLI"] {
        #expect(files.fileExists(atPath: repositoryRoot.appendingPathComponent("Sources/\(directory)").path))
    }

    let package = try String(contentsOf: repositoryRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(package.contains("// swift-tools-version: 6.0"))
    #expect(package.contains(".macOS(.v14)"))
    #expect(package.contains(".target(name: \"RMJCore\"") )
    #expect(package.contains(".executableTarget(name: \"RMJ\"") )
    #expect(package.contains(".executableTarget(name: \"RMJCLI\"") )
    #expect(package.contains(".testTarget(name: \"RMJCoreTests\"") )
    #expect(!package.contains(".package("))

    let lowercasedTarget = try Regex(#"\.(?:executableT|t|testT)arget\s*\(\s*name\s*:\s*"rmj""#)
    #expect(package.firstMatch(of: lowercasedTarget) == nil)
}

@Test("RMJCore never imports a UI framework")
func coreHasNoSwiftUIOrAppKitImports() throws {
    let root = repositoryRoot.appendingPathComponent("Sources/RMJCore", isDirectory: true)
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    let forbiddenImport = try Regex(
        #"(?m)^\s*(?:@_exported\s+)?import(?:\s+(?:class|struct|enum|protocol|typealias|func|var|let))?\s+(?:SwiftUI|AppKit)(?:\.|\s*$)"#
    )

    for case let file as URL in enumerator where file.pathExtension == "swift" {
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(source.firstMatch(of: forbiddenImport) == nil, "Forbidden UI import in \(file.path)")
    }
}

@Test("ProcessRunner kills a SIGTERM-ignoring process group after timeout")
func processRunnerKillsTermIgnoringChild() async throws {
    let pid = LockedPID()

    await #expect(throws: ProcessRunner.Failure.timedOut) {
        try await ProcessRunner().run(
            "/bin/sh", ["-c", "trap '' TERM; while :; do sleep 30; done"],
            timeout: .seconds(1),
            started: { pid.store($0) }
        )
    }

    let childPID = try #require(pid.load())
    #expect(kill(childPID, 0) == -1)
    #expect(errno == ESRCH)
}

@Test("ProcessRunner does not hang when a grandchild inherits its pipes")
func processRunnerStopsGrandchildHoldingPipe() async throws {
    let clock = ContinuousClock()
    let started = clock.now

    await #expect(throws: ProcessRunner.Failure.timedOut) {
        try await ProcessRunner().run(
            "/bin/sh", ["-c", "sleep 30 & exit 0"],
            timeout: .seconds(1)
        )
    }

    #expect(started.duration(to: clock.now) < .seconds(20))
}

@Test("ProcessRunner reports timeout even when TERM leads to exit zero")
func processRunnerPreservesTimeoutFailureAfterZeroExit() async throws {
    await #expect(throws: ProcessRunner.Failure.timedOut) {
        try await ProcessRunner().run(
            "/bin/sh", ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"],
            timeout: .seconds(1)
        )
    }
}

@Test("RMJHome uses the default location and RMJ_HOME override")
func rmjHomeResolvesLocations() throws {
    let fakeHome = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fakeHome) }
    let override = fakeHome.appendingPathComponent("isolated")

    #expect(RMJHome(environment: [:], homeDirectory: fakeHome).url.standardizedFileURL.path == fakeHome.appendingPathComponent(".rmj").standardizedFileURL.path)
    #expect(RMJHome(environment: ["RMJ_HOME": override.path], homeDirectory: fakeHome).url.standardizedFileURL.path == override.standardizedFileURL.path)
}

@Test("RMJHome creates and repairs its directory with mode 0700")
func rmjHomeEnforcesPrivatePermissions() throws {
    let parent = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let location = parent.appendingPathComponent(".rmj")
    let home = RMJHome(environment: [:], homeDirectory: parent)

    try home.prepare()
    var attributes = try FileManager.default.attributesOfItem(atPath: location.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: location.path)
    try home.prepare()
    attributes = try FileManager.default.attributesOfItem(atPath: location.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test("check.sh accepts 500 lines and rejects 501 lines")
func checkScriptEnforcesSwiftLineLimit() throws {
    let valid = try writeFixtureTree(swiftLineCount: 500)
    let invalid = try writeFixtureTree(swiftLineCount: 501)
    defer {
        try? FileManager.default.removeItem(at: valid)
        try? FileManager.default.removeItem(at: invalid)
    }

    #expect(try checkLint(on: valid).status == 0)
    #expect(try checkLint(on: invalid).status != 0)
}

@Test("check.sh rejects non-ASCII punctuation and accepts ASCII punctuation")
func checkScriptEnforcesPlainPunctuation() throws {
    let invalidCharacters = ["\u{2013}", "\u{2014}", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2026}", "\u{00A0}"]
    for character in invalidCharacters {
        let root = try writeFixtureTree(readme: "before\(character)after\n")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try checkLint(on: root).status != 0, "Expected rejection of U+\(String(character.unicodeScalars.first!.value, radix: 16))")
    }

    let valid = try writeFixtureTree(readme: "ASCII - dash, \"quotes\", 'apostrophe', and ...\n")
    defer { try? FileManager.default.removeItem(at: valid) }
    #expect(try checkLint(on: valid).status == 0)
}

@Test(
    "Icon rendering is deterministic and matches committed resources",
    .enabled(if: hasRSVGConvert, "rsvg-convert is not on PATH")
)
func iconRenderingIsReproducible() throws {
    let first = try temporaryDirectory()
    let second = try temporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    let script = repositoryRoot.appendingPathComponent("scripts/render-icons.sh").path

    #expect(try runCommand("/bin/bash", [script, first.path], in: repositoryRoot).status == 0)
    #expect(try runCommand("/bin/bash", [script, second.path], in: repositoryRoot).status == 0)

    for name in ["AppIcon.icns", "MenuBarIcon.pdf"] {
        let firstBytes = try Data(contentsOf: first.appendingPathComponent(name))
        let secondBytes = try Data(contentsOf: second.appendingPathComponent(name))
        let committedBytes = try Data(contentsOf: repositoryRoot.appendingPathComponent("Support/\(name)"))
        #expect(firstBytes == secondBytes)
        #expect(firstBytes == committedBytes)
    }
}

@Test("Bundled icon metadata and menu bar template are configured")
func bundleIconAndTemplateConfiguration() throws {
    let infoData = try Data(contentsOf: repositoryRoot.appendingPathComponent("Support/Info.plist"))
    let plist = try #require(
        PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
    )
    #expect(plist["CFBundleIdentifier"] as? String == "ro.danieltamas.rmj")
    #expect(plist["CFBundleExecutable"] as? String == "RMJ")
    #expect(plist["LSUIElement"] as? Bool == true)
    #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
    #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")

    let appIcon = try Data(contentsOf: repositoryRoot.appendingPathComponent("Support/AppIcon.icns"))
    #expect(appIcon.starts(with: Data("icns".utf8)))
    let menuBarIcon = try Data(contentsOf: repositoryRoot.appendingPathComponent("Support/MenuBarIcon.pdf"))
    #expect(menuBarIcon.starts(with: Data("%PDF".utf8)))

    let appSource = try String(
        contentsOf: repositoryRoot.appendingPathComponent("Sources/RMJ/RMJApp.swift"),
        encoding: .utf8
    )
    let templateResource = try Regex(
        #"(?s)forResource:\s*"MenuBarIcon".{0,600}?isTemplate\s*=\s*true"#
    )
    #expect(appSource.firstMatch(of: templateResource) != nil)
}


@Test("Package exposes exactly three products")
func packageExposesThreeProducts() throws {
    let result = try runCommand("/usr/bin/env", [
        "swift", "package", "--package-path", repositoryRoot.path, "dump-package"
    ])
    #expect(result.status == 0)
    let manifest = try #require(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
    let products = try #require(manifest["products"] as? [[String: Any]])
    #expect(products.count == 3)
    #expect(Set(products.compactMap { $0["name"] as? String }) == Set(["RMJCore", "RMJ", "RMJCLI"]))
}

@Test("ProcessRunner captures separate streams without pipe-buffer deadlock")
func processRunnerCapturesSeparateStreams() async throws {
    let result = try await ProcessRunner().run(
        "/bin/sh", ["-c", "i=0; while [ $i -lt 10000 ]; do printf 'stdout line\\n'; printf 'stderr line\\n' >&2; i=$((i+1)); done; exit 7"],
        timeout: .seconds(15)
    )
    #expect(result.status == 7)
    #expect(result.stdout == Data(String(repeating: "stdout line\n", count: 10000).utf8))
    #expect(result.stderr == String(repeating: "stderr line\n", count: 10000))
}

@Test("ProcessRunner passes shell metacharacters verbatim as arguments")
func processRunnerPreservesLiteralArguments() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("must-not-exist").path
    let arguments = ["a; touch \(marker)", "$(touch \(marker))", "space and 'quotes'", ""]
    let result = try await ProcessRunner().run(
        "/usr/bin/printf", ["%s\\0"] + arguments, timeout: .seconds(5)
    )
    #expect(result.status == 0)
    #expect(result.stdout == Data((arguments.joined(separator: "\0") + "\0").utf8))
    #expect(result.stderr.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: marker))
}

@Test("RMJ_HOME moves the prepared directory")
func rmjHomePreparesOverride() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let location = root.appendingPathComponent("override/nested")
    try RMJHome(environment: ["RMJ_HOME": location.path], homeDirectory: root).prepare()
    let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".rmj").path))
}

@Test("check.sh rejects punctuation in every documented location")
func checkScriptChecksAllPunctuationLocations() throws {
    for path in ["README.md", "docs/guide.md", "Sources/A.swift"] {
        let root = try writeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("let title = \"before\u{2014}after\"\n".utf8)
            .write(to: root.appendingPathComponent(path))
        #expect(try checkLint(on: root).status != 0, "Expected rejection in \(path)")
    }
}

@Test("check.sh rejects port leftovers only in implementation locations")
func checkScriptRejectsPortLeftovers() throws {
    for directory in ["Sources", "Support", "scripts", ".github"] {
        for name in ["MacMax", "macmax", "MACMAX"] {
            let root = try writeFixtureTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let folder = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("leftover \(name)\n".utf8).write(to: folder.appendingPathComponent("fixture.txt"))
            #expect(try checkLint(on: root).status != 0, "Expected rejection in \(directory): \(name)")
        }
    }
    let root = try writeFixtureTree(readme: "MacMax macmax MACMAX\n")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("MacMax macmax MACMAX\n".utf8).write(to: root.appendingPathComponent("docs/history.md"))
    #expect(try checkLint(on: root).status == 0)
}

// Real login keychain changes can prompt for its password; opt in: RMJ_KEYCHAIN=1 swift test --filter Keychain
@Test(
    "Keychain writes, reads, replaces and removes a generic password",
    .enabled(if: ProcessInfo.processInfo.environment["RMJ_KEYCHAIN"] == "1")
)
func keychainRoundTripAndReplacement() throws {
    let keychain = Keychain(service: "rmj-u0-test-\(UUID().uuidString)")
    let account = "throwaway"
    defer { try? keychain.remove(account: account) }
    #expect(try keychain.read(account: account) == nil)
    try keychain.remove(account: account)
    try keychain.write("first secret", account: account)
    let clock = ContinuousClock()
    let start = clock.now
    #expect(try keychain.read(account: account) == "first secret")
    #expect(start.duration(to: clock.now) < .seconds(5))
    try keychain.write("replacement secret", account: account)
    #expect(try keychain.read(account: account) == "replacement secret")
    try keychain.remove(account: account)
    #expect(try keychain.read(account: account) == nil)
    try keychain.remove(account: account)
}

// Real login keychain changes can prompt for its password; opt in: RMJ_KEYCHAIN=1 swift test --filter Keychain
@Test(
    "Keychain read refuses an untrusted item without prompting",
    .enabled(if: ProcessInfo.processInfo.environment["RMJ_KEYCHAIN"] == "1")
)
func keychainReadDisablesPrompts() throws {
    let keychain = Keychain(service: "rmj-u0-denied-test-\(UUID().uuidString)")
    let account = "throwaway"
    defer { try? keychain.remove(account: account) }
    // Trust a different executable so this test process needs approval to read the item.
    var trusted: SecTrustedApplication?
    let trustedStatus = SecTrustedApplicationCreateFromPath("/usr/bin/false", &trusted)
    try #require(trustedStatus == errSecSuccess)
    let application = try #require(trusted)
    var access: SecAccess?
    let accessStatus = SecAccessCreate("U0 isolated password" as CFString, [application] as CFArray, &access)
    try #require(accessStatus == errSecSuccess)
    let itemAccess = try #require(access)
    let added = SecItemAdd([
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: keychain.service,
        kSecAttrAccount: account,
        kSecValueData: Data("isolated test secret".utf8),
        kSecAttrAccess: itemAccess,
    ] as CFDictionary, nil)
    try #require(added == errSecSuccess)
    let clock = ContinuousClock()
    let start = clock.now
    #expect(throws: Keychain.Failure.denied) { try keychain.read(account: account) }
    #expect(start.duration(to: clock.now) < .seconds(5))
}

// Real login keychain changes can prompt for its password; opt in: RMJ_KEYCHAIN=1 swift test --filter Keychain
@Test(
    "KeychainProbe returns the documented exit statuses",
    .enabled(if: ProcessInfo.processInfo.environment["RMJ_KEYCHAIN"] == "1")
)
func keychainProbeExitStatuses() throws {
    let keychain = Keychain(service: "rmj-u0-probe-test-\(UUID().uuidString)")
    let account = "throwaway"
    defer { try? keychain.remove(account: account) }
    #expect(KeychainProbe.run(["read", account], keychain: keychain) == 3)
    #expect(KeychainProbe.run(["write", account, "test secret"], keychain: keychain) == 0)
    #expect(KeychainProbe.run(["read", account], keychain: keychain) == 0)
    #expect(try keychain.read(account: account) == "test secret")
    #expect(KeychainProbe.run(["remove", account], keychain: keychain) == 0)
    #expect(KeychainProbe.run(["read", account], keychain: keychain) == 3)
    for arguments in [[], ["read"], ["write", account], ["unknown", account]] {
        #expect(KeychainProbe.run(arguments, keychain: keychain) == 1)
    }
}

@Test("Installed-app Keychain check script exists and is executable")
func keychainCheckScriptIsExecutable() {
    #expect(FileManager.default.isExecutableFile(atPath:
        repositoryRoot.appendingPathComponent("scripts/keychain-check.sh").path))
}
