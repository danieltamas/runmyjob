import Darwin
import Foundation
import Testing
@testable import RMJCore

// Every test uses an isolated executable, never the real login keychain.
private struct SecurityToolFixture {
    let directory: URL
    var tool: String { directory.appendingPathComponent("security fake").path }

    init(status: Int = 0, output: String = "", stderr: String = "", mode: String = "") throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmj-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, value) in [("status", String(status)), ("stdout", output), ("stderr", stderr), ("mode", mode)] {
            try Data(value.utf8).write(to: directory.appendingPathComponent(name))
        }
        let script = #"""
        #!/bin/sh
        cd -- "${0%/*}" || exit 99
        printf 'call\n' >> calls
        printf '%s\n' "$@" >> argv
        printf '%s\n' "$$" > pid
        if IFS= read -r input; then
            printf 'unexpected input\n' > stdin
            exit 98
        fi
        printf 'eof\n' > stdin
        mode=$(/bin/cat mode)
        if [ "$mode" = hang ]; then
            exec /bin/sleep 30
        fi
        /bin/cat stdout
        /bin/cat stderr >&2
        if [ "$mode" = echo ]; then
            printf '%s\n' "$@" >&2
        fi
        exit "$(/bin/cat status)"
        """#
        try Data(script.utf8).write(to: URL(fileURLWithPath: tool))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool)
    }

    func cleanUp() {
        // A failed timeout assertion must not leave the sleeper behind.
        if (try? contents("mode")) == "hang",
           let text = try? contents("pid"), let pid = Int32(text.trimmingCharacters(in: .newlines)),
           kill(pid, 0) == 0 {
            _ = kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func contents(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func expectInvocation(_ arguments: [String]) throws {
        #expect(try contents("argv") == arguments.map { $0 + "\n" }.joined())
        #expect(try contents("calls") == "call\n")
        #expect(try contents("stdin") == "eof\n")
    }
}

@Suite("Keychain through the security tool")
struct KeychainSecurityToolAcceptanceTests {
    @Test("Write preserves argv and trusts the tool first", arguments: [false, true])
    func writeArguments(withTrust: Bool) throws {
        let fixture = try SecurityToolFixture()
        defer { fixture.cleanUp() }
        let keychain = Keychain(service: "test service", tool: fixture.tool)
        let secret = "-secret with 'quote'"
        let trust = ["/Applications/Test App.app/Contents/MacOS/Test", "/tmp/second"]
        if withTrust {
            try keychain.write(secret, account: "test account", trusting: trust)
        } else {
            try keychain.write(secret, account: "test account")
        }
        var expected = ["add-generic-password", "-U", "-s", "test service", "-a", "test account",
                        "-w", secret, "-T", fixture.tool]
        if withTrust {
            for path in trust { expected += ["-T", path] }
        }
        try fixture.expectInvocation(expected)
    }

    @Test("Read removes exactly one trailing newline", arguments: [
        "  secret with 'quotes'\ninner  ",
        "  secret with 'quotes'\ninner  \n",
        "secret\n\n", "", "\n",
    ])
    func readOutput(output: String) throws {
        let fixture = try SecurityToolFixture(output: output)
        defer { fixture.cleanUp() }
        let keychain = Keychain(tool: fixture.tool)
        let expected = output.hasSuffix("\n") ? String(output.dropLast()) : output
        #expect(try keychain.read(account: "account with spaces") == expected)
        try fixture.expectInvocation([
            "find-generic-password", "-s", "ro.danieltamas.rmj", "-a", "account with spaces", "-w",
        ])
    }

    @Test("Missing read returns nil")
    func readMissing() throws {
        let fixture = try SecurityToolFixture(status: 44, output: "ignored")
        defer { fixture.cleanUp() }
        #expect(try Keychain(service: "custom", tool: fixture.tool).read(account: "a") == nil)
        try fixture.expectInvocation(["find-generic-password", "-s", "custom", "-a", "a", "-w"])
    }

    @Test("Read maps exit 36 and interaction stderr to denied", arguments: [36, 1])
    func readDenied(status: Int) throws {
        let message = status == 1 ? "security: User interaction is not allowed.\n" : ""
        let fixture = try SecurityToolFixture(status: status, stderr: message)
        defer { fixture.cleanUp() }
        let keychain = Keychain(tool: fixture.tool)
        #expect(throws: Keychain.Failure.denied) { try keychain.read(account: "a") }
        try fixture.expectInvocation([
            "find-generic-password", "-s", "ro.danieltamas.rmj", "-a", "a", "-w",
        ])
        #expect(Keychain.Failure.denied.description.contains("approval"))
    }

    @Test("Other read exits preserve the exit status", arguments: [Int32(1), 37, 127])
    func readFailure(status: Int32) throws {
        let fixture = try SecurityToolFixture(status: Int(status))
        defer { fixture.cleanUp() }
        let keychain = Keychain(tool: fixture.tool)
        #expect(throws: Keychain.Failure.failed(status)) { try keychain.read(account: "a") }
        try fixture.expectInvocation([
            "find-generic-password", "-s", "ro.danieltamas.rmj", "-a", "a", "-w",
        ])
    }

    @Test("Write failures preserve exit codes", arguments: [Int32(1), 36, 44])
    func writeFailure(status: Int32) throws {
        let fixture = try SecurityToolFixture(status: Int(status))
        defer { fixture.cleanUp() }
        let keychain = Keychain(tool: fixture.tool)
        #expect(throws: Keychain.Failure.failed(status)) { try keychain.write("secret", account: "a") }
        try fixture.expectInvocation([
            "add-generic-password", "-U", "-s", "ro.danieltamas.rmj", "-a", "a",
            "-w", "secret", "-T", fixture.tool,
        ])
    }

    @Test("Remove succeeds for present and missing items", arguments: [0, 44])
    func removeSuccess(status: Int) throws {
        let fixture = try SecurityToolFixture(status: status)
        defer { fixture.cleanUp() }
        try Keychain(service: "custom", tool: fixture.tool).remove(account: "a")
        try fixture.expectInvocation(["delete-generic-password", "-s", "custom", "-a", "a"])
    }

    @Test("Remove failures preserve exit codes", arguments: [Int32(1), 36, 127])
    func removeFailure(status: Int32) throws {
        let fixture = try SecurityToolFixture(status: Int(status), stderr: "User interaction is not allowed")
        defer { fixture.cleanUp() }
        let keychain = Keychain(tool: fixture.tool)
        #expect(throws: Keychain.Failure.failed(status)) { try keychain.remove(account: "a") }
        try fixture.expectInvocation([
            "delete-generic-password", "-s", "ro.danieltamas.rmj", "-a", "a",
        ])
    }

    @Test("Echoed write argv cannot leak a secret in the thrown error")
    func writeErrorRedactsSecret() throws {
        let secret = "-private 'quoted' token"
        let fixture = try SecurityToolFixture(status: 1, mode: "echo")
        defer { fixture.cleanUp() }
        let keychain = Keychain(tool: fixture.tool)
        do {
            try keychain.write(secret, account: "a")
            Issue.record("Expected write failure")
        } catch {
            #expect((error as? Keychain.Failure) == .failed(1))
            #expect(!String(describing: error).contains(secret))
            #expect(!String(reflecting: error).contains(secret))
            #expect(!error.localizedDescription.contains(secret))
        }
        try fixture.expectInvocation([
            "add-generic-password", "-U", "-s", "ro.danieltamas.rmj", "-a", "a",
            "-w", secret, "-T", fixture.tool,
        ])
    }

    @Test("Timeout denies access promptly and kills the child", arguments: ["read", "write", "remove"])
    func timeout(operation: String) throws {
        let fixture = try SecurityToolFixture(mode: "hang")
        defer { fixture.cleanUp() }
        let keychain = Keychain(allowingPrompts: true, tool: fixture.tool, timeout: .seconds(2))
        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: Keychain.Failure.denied) {
            switch operation {
            case "write": try keychain.write("secret", account: "a")
            case "remove": try keychain.remove(account: "a")
            default: _ = try keychain.read(account: "a")
            }
        }
        #expect(start.duration(to: clock.now) < .seconds(6))
        let pidDeadline = clock.now.advanced(by: .seconds(3))
        var childPID: Int32?
        repeat {
            childPID = (try? fixture.contents("pid")).flatMap { Int32($0.trimmingCharacters(in: .newlines)) }
            if childPID != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while clock.now < pidDeadline
        if childPID == nil {
            // Before the PID write, the child's command still contains the unique script path.
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            probe.arguments = ["-f", NSRegularExpression.escapedPattern(for: fixture.tool)]
            probe.standardOutput = FileHandle.nullDevice
            try probe.run()
            probe.waitUntilExit()
            #expect(probe.terminationStatus == 1)
            return
        }
        let pid = try #require(childPID)
        // exec makes the fake script and sleeper the same child.
        let result = kill(pid, 0)
        let errorCode = errno
        #expect(result == -1)
        #expect(errorCode == ESRCH)
        #expect(try fixture.contents("calls") == "call\n")
        #expect(try fixture.contents("stdin") == "eof\n")
    }
}
