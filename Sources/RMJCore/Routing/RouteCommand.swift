import Foundation

/// A probe taken live over ssh each time; the ledger-backed cache arrives with the run engine.
public struct LiveProbeProvider: ProbeProvider {
    public init() {}
    public func latest(for destination: String) async -> DestinationProbeResult? { nil }
    public func probe(_ target: DestinationTarget, tailnet: TailnetState) async -> DestinationProbeResult {
        await DestinationProbe().probe(target, tailnet: tailnet)
    }
}

/// `rmj route [--repo owner/name] [--path dir] [--to destination] [--json] -- <command>`
public enum RouteCommand {
    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        var repo: String?, path = FileManager.default.currentDirectoryPath, destination: String?, json = false
        var command = [String]()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--": command = Array(rest); rest = []
            case "--json": json = true
            case "--repo": repo = rest.popFirst()
            case "--path": path = rest.popFirst() ?? path
            case "--to": destination = rest.popFirst()
            default: return usage("unknown option \(argument)")
            }
        }
        guard !command.isEmpty else { return usage("no command after --") }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var identity = await RepoIdentity.detect(in: directory)
        if let repo { identity = RepoIdentity(slug: repo.lowercased(), worktree: identity.worktree, dirty: identity.dirty) }
        let home = RMJHome(environment: environment)
        // Rules are read from the home: it must be this user's private directory, not a link or a shared one.
        do { try home.prepare() } catch {
            FileHandle.standardError.write(Data("rmj route: \(UntrustedText.clean(home.url.path)) is not a private directory of this user\n".utf8))
            return 1
        }
        let router = Router(rules: RulesStore(home: home).load(), tailnet: await TailnetState.read(environment: environment),
                            probes: LiveProbeProvider(), fileExists: { FileManager.default.fileExists(atPath: $0) })
        let decision = await router.route(RouteRequest(command: command, identity: identity,
                                                       forceLocal: environment["RX_LOCAL"] == "1", destination: destination)).sanitized()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: (try? encoder.encode(decision)) ?? Data(), as: UTF8.self))
        } else {
            decision.explanation.forEach { print($0) }
            print(decision.locationName)
        }
        return 0
    }

    private static func usage(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("rmj route: \(UntrustedText.clean(message, limit: 120))\nusage: rmj route [--repo owner/name] [--path dir] [--to destination] [--json] -- <command>\n".utf8))
        return 2
    }
}
