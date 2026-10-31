import Testing
import Foundation
import RMJCore

@Test(arguments: [
    "npm test", "npm run test", "npm run lint", "pnpm test", "pnpm run typecheck",
    "yarn test", "yarn lint", "bun test", "bun run check", "bun run test:unit",
    "npm run lint:fix", "cd web && pnpm test", "FOO=1 npm test", "npm test -- --watch"
])
func nodeRoutingRecognizesChecksAtCommandPosition(_ command: String) {
    #expect(CommandGuard.kind(of: command) == .check, "Must route: \(command)")
}

@Test(arguments: [
    "npm install", "npm run build", "pnpm build", "bun run dev", "npm run testing",
    "npm run lintx", "echo \"npm test\"", "git commit -m \"npm test\"",
    "rmj run -- npm test", "RX_LOCAL=1 npm test"
])
func nodeRoutingLeavesOtherCommandsAlone(_ command: String) {
    #expect(CommandGuard.kind(of: command) == nil, "Must not route: \(command)")
}

private struct NodeRoutingFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RMJ-Node-\(UUID())")
    var home: URL { root.appendingPathComponent("home") }
    var shims: URL { root.appendingPathComponent("shims") }
    var rmj: URL { root.appendingPathComponent("fake-rmj") }
    var installer: HookInstaller { HookInstaller(home: home, rmj: rmj.path, shimDirectory: shims) }

    init() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func nodeRoutingInstallsExactlySixExecutableShimsAndRequiresEveryOne() throws {
    let expected = ["cargo", "just", "npm", "pnpm", "yarn", "bun"]
    #expect(Set(HookInstaller.shimmed) == Set(expected))
    #expect(HookInstaller.shimmed.count == expected.count)
    let f = try NodeRoutingFixture()
    defer { f.clean() }
    #expect(f.installer.status().first { $0.harness == .codex }?.state == .shimsOnly(installed: false))
    try f.installer.install(.codex)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: f.shims.path)) == Set(expected))
    #expect(f.installer.status().first { $0.harness == .codex }?.state == .shimsOnly(installed: true))
    for name in expected {
        let shim = f.shims.appendingPathComponent(name)
        #expect(FileManager.default.isExecutableFile(atPath: shim.path), "Must be executable: \(name)")
        try FileManager.default.removeItem(at: shim)
        #expect(f.installer.status().first { $0.harness == .codex }?.state == .shimsOnly(installed: false),
                "Missing \(name) must make installation incomplete")
        try f.installer.install(.codex)
        #expect(f.installer.status().first { $0.harness == .codex }?.state == .shimsOnly(installed: true))
    }
}

private func nodeRoutingScript(_ text: String, at url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@Test(arguments: [true, false])
func nodeRoutingNpmShimExecutesRoutedOrRealCommand(_ routed: Bool) throws {
    let f = try NodeRoutingFixture()
    defer { f.clean() }
    let real = f.root.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: real.appendingPathComponent("dirname").path,
                                              withDestinationPath: "/usr/bin/dirname")
    try nodeRoutingScript("#!/bin/sh\nprintf 'REAL\\n'\nprintf '<%s>\\n' \"$@\"\n", at: real.appendingPathComponent("npm"))
    // The guard's exit status represents whether this repository has a routing rule.
    try nodeRoutingScript("""
        #!/bin/sh
        if [ "$1" = guard ]; then
          [ "$2" = --quiet ] && [ "$3" = --command ] &&
          [ "$4" = 'npm test -- --watch' ] && [ "$5" = --cwd ] &&
          [ "$6" = "$PWD" ] || exit 0
          exit \(routed ? 2 : 0)
        fi
        printf 'RMJ\\n'
        printf '<%s>\\n' "$@"
        """ + "\n", at: f.rmj)
    try f.installer.install(.codex)
    let shim = f.shims.appendingPathComponent("npm")
    let text = try String(contentsOf: shim, encoding: .utf8)
    #expect(text.contains(#"guard --quiet --command "npm $*""#))
    #expect(text.contains(#"run -- "npm""#))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [shim.path, "test", "--", "--watch"]
    process.currentDirectoryURL = f.home
    process.environment = ["HOME": f.home.path, "PATH": f.shims.path + ":" + real.path]
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let expected = routed ? "RMJ\n<run>\n<-->\n<npm>\n<test>\n<-->\n<--watch>\n"
                          : "REAL\n<test>\n<-->\n<--watch>\n"
    #expect(String(decoding: data, as: UTF8.self) == expected)
}
