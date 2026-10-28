import Foundation

/// `rmj guard` (what a harness's pre-command hook and the shims call) and `rmj hooks install|status|remove [harness]`.
public enum HooksCommand {
    private static let usage = """
        usage: rmj hooks install|status|remove [claude-code|codex|opencode|hermes]
               rmj guard [--hook] [--quiet] [--command <command> --cwd <dir>]
        """

    /// The installer for this user: their home, this binary's path, and the shims under the RMJ home.
    public static func installer(environment: [String: String]) -> HookInstaller {
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        return HookInstaller(home: home, rmj: binaryPath(home: home), shimDirectory: RMJHome(environment: environment).url.appendingPathComponent("shims"))
    }

    private static func binaryPath(home: URL) -> String {
        let installed = home.appendingPathComponent(".local/bin/rmj").path
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        let argument = CommandLine.arguments[0]
        return argument.hasPrefix("/") ? argument : FileManager.default.currentDirectoryPath + "/" + argument
    }

    public static func hooks(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        guard let verb = arguments.first, ["install", "status", "remove"].contains(verb) else { return fail(usage, code: 2) }
        var harness: HookInstaller.Harness?
        if let name = arguments.dropFirst().first {
            guard let found = HookInstaller.Harness(rawValue: name) else { return fail("unknown harness \(UntrustedText.clean(name, limit: 40))\n" + usage, code: 2) }
            harness = found
        }
        let installer = installer(environment: environment)
        do {
            switch verb {
            case "install": try installer.install(harness)
            case "remove": try installer.remove(harness)
            default: break
            }
        } catch { return fail("rmj hooks: \(error)", code: 1) }
        for status in installer.status() { print("\(status.harness.title): \(describe(status.state))") }
        if installer.status().contains(where: { $0.state == .shimsOnly(installed: true) }) {
            print("Shims are in \(installer.shimDirectory.path): put it first on the PATH of the agent's environment. scripts/check.sh is not covered.")
        }
        return 0
    }

    public static func describe(_ state: HookInstaller.State) -> String {
        switch state {
        case .installed: "installed"
        case .notInstalled: "not installed"
        case .notPresent: "not present on this Mac"
        case .shimsOnly(let installed): installed ? "covered by shims only" : "not installed (shims only, no hook)"
        }
    }

    public static func guardCommand(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                                    input: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }) async -> Int32 {
        var hook = false, quiet = false, command: String?, cwd = FileManager.default.currentDirectoryPath
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--hook": hook = true
            case "--quiet": quiet = true
            case "--command": command = rest.popFirst()
            case "--cwd": cwd = rest.popFirst() ?? cwd
            default: return fail("unknown option \(UntrustedText.clean(argument, limit: 40))\n" + usage, code: 2)
            }
        }
        if command == nil {
            // A hook that cannot read its input must never stop the agent.
            guard let object = try? JSONSerialization.jsonObject(with: input()) as? [String: Any],
                  let text = (object["tool_input"] as? [String: Any])?["command"] as? String else { return 0 }
            command = text
            if let directory = object["cwd"] as? String, !directory.isEmpty { cwd = directory }
        }
        guard let command, CommandGuard.kind(of: command) != nil else { return 0 }
        let tools = GuardTools(environment: environment)
        let verdict = await CommandGuard.verdict(command: command, cwd: cwd, classify: tools.classify, destination: tools.destination)
        switch verdict {
        case .allow:
            return 0
        case .advise(let text):
            guard !quiet else { return 0 }
            if hook {
                let payload: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "additionalContext": text]]
                if let data = try? JSONSerialization.data(withJSONObject: payload) { print(String(decoding: data, as: UTF8.self)) }
            } else { print(text) }
            return 0
        case .block(let text):
            if !quiet { FileHandle.standardError.write(Data("BLOCKED: \(text)\n".utf8)) }
            return 2
        }
    }

    private static func fail(_ message: String, code: Int32) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return code
    }
}

/// The two questions the guard asks of the machine: which repo is this directory, and where would the router send it.
struct GuardTools {
    let environment: [String: String]

    func classify(_ directory: String) async -> CommandGuard.RepoClass {
        let identity = await RepoIdentity.detect(in: URL(fileURLWithPath: directory))
        guard let slug = identity.slug else { return .notRepo }
        let name = UntrustedText.clean(slug, limit: 80)
        var tenants: [String: TenantConfig] = [:]
        if case .valid(let rules, _) = RulesStore(home: RMJHome(environment: environment)).load() { tenants = rules.tenants }
        return Tenancy.resolve(identity, in: tenants).tenant == Tenancy.unclassified ? .unclassified(repo: name) : .classified(repo: name)
    }

    func destination(_ command: String, _ directory: String) async -> String? {
        let identity = await RepoIdentity.detect(in: URL(fileURLWithPath: directory))
        var words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        if let at = words.lastIndex(of: "&&") { words = Array(words[(at + 1)...]) }
        guard !words.isEmpty else { return nil }
        let home = RMJHome(environment: environment)
        let router = Router(rules: RulesStore(home: home).load(), tailnet: await TailnetState.read(environment: environment),
                            probes: LiveProbeProvider(), fileExists: { FileManager.default.fileExists(atPath: $0) })
        let decision = await router.route(RouteRequest(command: words, identity: identity)).sanitized()
        if decision.rule == nil, decision.location == .local { return nil }
        return decision.location == .local ? "this Mac" : decision.locationName
    }
}
