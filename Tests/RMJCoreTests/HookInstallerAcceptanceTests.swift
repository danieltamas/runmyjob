import Testing
import Foundation
import RMJCore

private struct HookFixture {
    let root: URL
    let home: URL
    let shims: URL
    let rmj: URL
    var settings: URL { home.appendingPathComponent(".claude/settings.json") }
    var installer: HookInstaller { HookInstaller(home: home, rmj: rmj.path, shimDirectory: shims) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RMJ-Hooks-\(UUID())")
        home = root.appendingPathComponent("home")
        shims = root.appendingPathComponent("shims")
        rmj = root.appendingPathComponent("fake-rmj")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func directory(_ path: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

private func hookJSON(_ url: URL) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func hookEntries(_ url: URL) throws -> [[String: Any]] {
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let hooks = try #require(object["hooks"] as? [String: Any])
    return try #require(hooks["PreToolUse"] as? [[String: Any]])
}

@Test func hookInstallerPreservesClaudeSettingsAndIsIdempotent() throws {
    let f = try HookFixture()
    defer { f.clean() }
    try f.directory(".claude")
    let original = Data(#"{"theme":"dark","permissions":{"allow":["Read"]},"hooks":{"PostToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"echo after"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo existing"}]},{"matcher":"Write","hooks":[{"type":"command","command":"echo write"}]}]}}"#.utf8)
    try original.write(to: f.settings)
    let originalJSON = try hookJSON(f.settings)
    let originalEntries = try hookEntries(f.settings)
    try f.installer.install(.claudeCode)
    #expect(f.installer.state(of: .claudeCode) == .installed)
    let entries = try hookEntries(f.settings)
    #expect(entries.count == originalEntries.count + 1)
    let owned = entries.filter { entry in
        guard let inner = entry["hooks"] as? [[String: Any]], let first = inner.first,
              let command = first["command"] as? String else { return false }
        return command.hasSuffix(" guard --hook")
    }
    #expect(owned.count == 1)
    let entry = try #require(owned.first)
    #expect(entry["matcher"] as? String == "Bash")
    let inner = try #require(entry["hooks"] as? [[String: Any]])
    #expect(inner.count == 1)
    #expect(inner[0]["command"] as? String == f.rmj.path + " guard --hook")
    let installed = try Data(contentsOf: f.settings)
    try f.installer.install(.claudeCode)
    #expect(try Data(contentsOf: f.settings) == installed)
    try f.installer.remove(.claudeCode)
    #expect(try hookJSON(f.settings) == originalJSON)
    #expect(f.installer.state(of: .claudeCode) == .notInstalled)
    let removed = try Data(contentsOf: f.settings)
    try f.installer.remove(.claudeCode)
    #expect(try Data(contentsOf: f.settings) == removed)
}

@Test func hookInstallerCreatesSettingsAndRejectsNonObjectsWithoutWriting() throws {
    let f = try HookFixture()
    defer { f.clean() }
    try f.directory(".claude")
    #expect(!FileManager.default.fileExists(atPath: f.settings.path))
    try f.installer.install(.claudeCode)
    #expect(try hookEntries(f.settings).count == 1)
    for text in ["[]", "null", "42", "not JSON"] {
        let bytes = Data(text.utf8)
        try bytes.write(to: f.settings)
        #expect(throws: HookInstaller.Failure.unreadable(f.settings.path)) {
            try f.installer.install(.claudeCode)
        }
        #expect(try Data(contentsOf: f.settings) == bytes)
    }
}

@Test func hookInstallerSkipsAbsentHarnessesWithoutCreatingPaths() throws {
    let f = try HookFixture()
    defer { f.clean() }
    #expect(f.installer.status().allSatisfy { $0.state == .notPresent })
    #expect(throws: HookInstaller.Failure.notPresent(.codex)) { try f.installer.install(.codex) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.home.path).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.shims.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path) == ["home"])
    try f.installer.install()
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.home.path).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.shims.path))
    try f.directory(".claude")
    try f.installer.install()
    #expect(f.installer.state(of: .claudeCode) == .installed)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.home.path) == [".claude"])
    #expect(!FileManager.default.fileExists(atPath: f.shims.path))
}

private func hookMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o7777
}

@Test func hookInstallerInstallsAndRemovesShimsForPresentHarnesses() throws {
    let harnesses: [(HookInstaller.Harness, String)] = [(.codex, ".codex"), (.openCode, ".config/opencode"), (.hermes, ".hermes")]
    for (harness, directory) in harnesses {
        let f = try HookFixture()
        defer { f.clean() }
        try f.directory(directory)
        let sentinel = f.home.appendingPathComponent(directory).appendingPathComponent("settings.txt")
        let bytes = Data("leave this unchanged\n".utf8)
        try bytes.write(to: sentinel)
        #expect(f.installer.state(of: harness) == .shimsOnly(installed: false))
        try f.installer.install(harness)
        #expect(f.installer.state(of: harness) == .shimsOnly(installed: true))
        #expect(try hookMode(f.shims) == 0o700)
        for name in ["cargo", "just"] {
            let shim = f.shims.appendingPathComponent(name)
            #expect(FileManager.default.isExecutableFile(atPath: shim.path))
            #expect(try hookMode(shim) == 0o755)
        }
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sentinel.deletingLastPathComponent().path) == ["settings.txt"])
        try f.installer.remove(harness)
        #expect(f.installer.state(of: harness) == .shimsOnly(installed: false))
        for name in ["cargo", "just"] {
            #expect(!FileManager.default.fileExists(atPath: f.shims.appendingPathComponent(name).path))
        }
        #expect(try Data(contentsOf: sentinel) == bytes)
    }
}

private func hookScript(_ text: String, at url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func runHookShim(_ f: HookFixture, real: URL, argument: String, nested: Bool = false) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [f.shims.appendingPathComponent("cargo").path, argument]
    process.currentDirectoryURL = f.home
    process.environment = ["HOME": f.home.path, "RMJ_HOME": f.home.appendingPathComponent(".rmj").path,
                           "PATH": f.shims.path + ":" + real.path, "RMJ_IN_SHIM": nested ? "1" : ""]
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

@Test func hookInstallerCargoShimRoutesBuildsBypassesRecursionAndReportsMissingBinary() throws {
    let f = try HookFixture()
    defer { f.clean() }
    try f.directory(".codex")
    let real = f.root.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    // Only shell utilities are linked; no installed cargo can be discovered on PATH.
    for (name, source) in [("dirname", "/usr/bin/dirname"), ("tr", "/usr/bin/tr"),
                           ("grep", "/usr/bin/grep"), ("paste", "/usr/bin/paste")] {
        try FileManager.default.createSymbolicLink(atPath: real.appendingPathComponent(name).path, withDestinationPath: source)
    }
    let cargo = real.appendingPathComponent("cargo")
    try hookScript("#!/bin/sh\nprintf 'REAL %s\\n' \"$*\"\n", at: cargo)
    try hookScript("""
        #!/bin/sh
        printf 'RMJ %s\\n' "$*"
        if [ "$1" = guard ]; then
          [ "$4" = 'cargo build' ] && exit 0
          exit 2
        fi
        exit 0
        """ + "\n", at: f.rmj)
    try f.installer.install(.codex)
    let routed = try runHookShim(f, real: real, argument: "test")
    #expect(routed.0 == 0)
    #expect(routed.1 == "RMJ run -- cargo test\n")
    let build = try runHookShim(f, real: real, argument: "build")
    #expect(build.0 == 0)
    #expect(build.1 == "REAL build\n")
    let nested = try runHookShim(f, real: real, argument: "test", nested: true)
    #expect(nested.0 == 0)
    #expect(nested.1 == "REAL test\n")
    try FileManager.default.removeItem(at: cargo)
    let missing = try runHookShim(f, real: real, argument: "test")
    #expect(missing.0 == 127)
}
