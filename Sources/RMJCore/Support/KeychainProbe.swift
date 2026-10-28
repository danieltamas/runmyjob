import Foundation

/// The headless keychain commands behind `scripts/keychain-check.sh`: the app binary and the CLI
/// both run them, so the script can ask each of the two whether it reads an item the other wrote.
/// Exit 0 read or written, 3 no such item, 4 macOS would prompt, 1 any other failure.
public enum KeychainProbe {
    public static let flag = "--keychain-probe"
    /// The entry points honor the flag only with this variable set, which the check script does,
    /// so the shipped binaries are not a general way to drive the Keychain.
    public static let enabledVariable = "RMJ_KEYCHAIN_PROBE"

    public static var isEnabled: Bool { ProcessInfo.processInfo.environment[enabledVariable] == "1" }

    /// The entry point of the shipped binaries: only with the variable set, and only on the
    /// throwaway items of the check script, never on a real PAT.
    public static func runFromCommandLine(_ arguments: [String]) -> Int32 {
        guard isEnabled, arguments.count >= 2, arguments[1].hasPrefix("rmj.test") else {
            return fail("the probe needs \(enabledVariable)=1 and an rmj.test account")
        }
        return run(arguments)
    }

    /// `arguments` follow the flag: `write <account> <secret> [<trusted executable>...]`,
    /// `read <account>`, `remove <account>`.
    public static func run(_ arguments: [String], keychain: Keychain = Keychain()) -> Int32 {
        guard arguments.count >= 2 else { return fail("usage: write|read|remove <account> ...") }
        let account = arguments[1]
        do {
            switch arguments[0] {
            case "write" where arguments.count >= 3:
                try keychain.write(arguments[2], account: account, trusting: Array(arguments.dropFirst(3)))
            case "read":
                // The value is never printed: the probe answers whether it can read, not what it holds.
                guard try keychain.read(account: account) != nil else { return 3 }
            case "remove":
                try keychain.remove(account: account)
            default:
                return fail("usage: write|read|remove <account> ...")
            }
            return 0
        } catch Keychain.Failure.denied {
            return 4
        } catch {
            return fail("\(error)")
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("keychain-probe: \(message)\n".utf8))
        return 1
    }
}
