import Foundation

/// A repo renamed on GitHub keeps answering to its old name through a redirect that a box runner's token request does not follow:
/// no runner registers and the jobs queue for good. This asks GitHub for the current name of every repo the rules name and,
/// when the owner is unchanged and GitHub's id for the repo is the one recorded before, rewrites the rules, carries the PAT over and
/// renames the box's runner service in its extras. A transfer to another owner, a name another repo now holds and a repo whose id was
/// never recorded are never healed, and any step that cannot be made durable leaves the rules as they were.
public struct RepoRenameHealer: Sendable {
    public struct Heal: Sendable, Equatable {
        public let old: String
        public let new: String
    }

    public struct Refusal: Sendable, Equatable {
        public let old: String
        public let new: String
        public let reason: String
    }

    public struct Result: Sendable, Equatable {
        public var healed: [Heal] = []
        public var refused: [Refusal] = []
        /// Destinations whose runner targets changed: their box still runs the old name until it is set up again.
        public var destinations: [String] = []
    }

    private struct Rename {
        let old: String
        let new: String
        let id: Int
        var destinations: [String] = []
    }

    private struct ExtrasConflict: Error, CustomStringConvertible {
        let description: String
    }

    private let home: RMJHome
    private let api: GitHubAPI
    private let readToken: @Sendable (String) -> String?
    private let writeToken: @Sendable (String, String) throws -> Void

    public init(home: RMJHome, api: GitHubAPI, readToken: @escaping @Sendable (String) -> String?, writeToken: @escaping @Sendable (String, String) throws -> Void) {
        self.home = home
        self.api = api
        self.readToken = readToken
        self.writeToken = writeToken
    }

    /// The literal `owner/name` repos the rules name; patterns and `org:` targets have no single repo to ask about.
    static func watched(_ rules: Rules) -> [String] {
        var names = rules.tenants.values.flatMap { $0.repos ?? [] }
        for destination in rules.destinations.values {
            names += (destination.runnerTargets ?? []) + (destination.runnerLabels ?? [:]).keys
        }
        names += rules.rules.flatMap { $0.match.repo ?? [] }
        var seen = Set<String>()
        return names.filter { $0.contains("/") && !$0.contains("*") && !$0.hasPrefix("org:") && seen.insert($0.lowercased()).inserted }.sorted()
    }

    public func run() async -> Result {
        let store = RulesStore(home: home)
        guard case .valid(let original, let fingerprint) = store.load() else { return Result() }
        var result = Result()
        var renames = [Rename]()
        let identities = RepoIdentities(home: home)
        var known = identities.ids
        for repo in Self.watched(original) {
            guard let current = await currentRepo(repo) else { continue }
            if current.name.lowercased() == repo.lowercased() {
                known[repo.lowercased()] = known[repo.lowercased()] ?? current.id
                continue
            }
            if let reason = Self.refusal(old: repo, new: current.name, id: current.id, recorded: known[repo.lowercased()], in: original) {
                result.refused.append(Refusal(old: repo, new: current.name, reason: reason))
            } else {
                renames.append(Rename(old: repo, new: current.name, id: current.id))
            }
        }
        identities.save(known)
        guard !renames.isEmpty else { return result }
        var rules = original
        for index in renames.indices { renames[index].destinations = Self.rewrite(&rules, from: renames[index].old, to: renames[index].new) }
        let affected = Array(Set(renames.flatMap(\.destinations))).sorted()
        let pending = PendingRepairs(home: home)
        let added = Array(Set(affected).subtracting(pending.names))
        var restore = [(file: URL, text: String)]()
        do {
            // Refused before anything else is touched: no token is copied for a rename the rules would not accept.
            try store.validate(rules)
            for rename in renames where readToken(rename.new) == nil {
                if let token = readToken(rename.old) { try writeToken(rename.new, token) }
            }
            try pending.add(affected)
            for destination in affected { try migrateExtras(destination: destination, renames: renames, before: original, after: rules, restore: &restore) }
            try store.save(rules, expected: fingerprint)
        } catch {
            for entry in restore.reversed() { try? entry.text.write(to: entry.file, atomically: true, encoding: .utf8) }
            try? pending.remove(added)
            result.refused += renames.map { Refusal(old: $0.old, new: $0.new, reason: "\(error)") }
            return result
        }
        for rename in renames {
            known[rename.old.lowercased()] = nil
            known[rename.new.lowercased()] = rename.id
        }
        identities.save(known)
        result.healed = renames.map { Heal(old: $0.old, new: $0.new) }
        result.destinations = affected
        record(renames)
        return result
    }

    private func currentRepo(_ repo: String) async -> (name: String, id: Int)? {
        guard let response = try? await api.get("/repos/\(repo)", query: [:], etag: nil, token: nil), response.status == 200,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let name = object["full_name"] as? String, name.split(separator: "/").count == 2, let id = object["id"] as? Int else { return nil }
        return (GitHubText.clean(name), id)
    }

    private static func owner(_ repo: String) -> String { repo.split(separator: "/").first.map { $0.lowercased() } ?? "" }

    /// Why a rename is not followed, or nil: a new owner is a transfer, an unrecorded or different id means this may not be the repo the rules meant,
    /// and a name that another tenant holds (also by pattern) is never taken over.
    private static func refusal(old: String, new: String, id: Int, recorded: Int?, in rules: Rules) -> String? {
        if owner(new) != owner(old) { return "now belongs to \(owner(new)); assign it to a tenant that owns it" }
        guard let recorded else { return "its GitHub id was never recorded, so it cannot be told from another repo that took the name; RMJ records it on the first check" }
        if recorded != id { return "the name now belongs to a different repository" }
        func holders(_ repo: String) -> Set<String> { Set(rules.tenants.filter { RulesValidation.matches($0.value, repo: repo) }.keys) }
        if let other = holders(new).subtracting(holders(old)).sorted().first { return "the new name already belongs to tenant \(other)" }
        // The tenants that own the repo, by claim or by owner, must be the same set before and after the names are swapped.
        func owning(_ repo: String, _ rules: Rules) -> Set<String> {
            Set(rules.tenants.filter { RulesValidation.matches($0.value, repo: repo) || ($0.value.owners ?? []).contains { $0.lowercased() == owner(repo) } }.keys)
        }
        var trial = rules
        _ = rewrite(&trial, from: old, to: new)
        if owning(old, rules) != owning(new, trial) { return "the tenant that owns it would change with the new name; assign it to a tenant first" }
        return nil
    }

    /// Replaces `old` everywhere the rules name it; returns the destinations whose runner targets changed.
    private static func rewrite(_ rules: inout Rules, from old: String, to new: String) -> [String] {
        func swap(_ names: [String]) -> [String] {
            var seen = Set<String>()
            return names.map { $0.lowercased() == old.lowercased() ? new : $0 }.filter { seen.insert($0.lowercased()).inserted }
        }
        for (name, tenant) in rules.tenants { rules.tenants[name]?.repos = tenant.repos.map(swap) }
        for index in rules.rules.indices { rules.rules[index].match.repo = rules.rules[index].match.repo.map(swap) }
        var changed = [String]()
        for name in rules.destinations.keys {
            guard var destination = rules.destinations[name] else { continue }
            let before = destination.runnerTargets
            destination.runnerTargets = destination.runnerTargets.map(swap)
            if let labels = destination.runnerLabels, let key = labels.keys.first(where: { $0.lowercased() == old.lowercased() }) {
                var moved = labels
                moved[key] = nil
                if !moved.keys.contains(where: { $0.lowercased() == new.lowercased() }) { moved[new] = labels[key] }
                destination.runnerLabels = moved
            }
            if before != destination.runnerTargets { changed.append(name) }
            rules.destinations[name] = destination
        }
        return changed
    }

    /// A box's extras (`~/.rmj/runner-extras/<destination>/docker-compose.extra.yml`) override a runner's service by name, and the name comes from the repo:
    /// left alone, the toolchain image would stay on a service that no longer exists and the renamed repo's runner would get the bare image.
    /// Every service whose name changes for this destination's own targets is renamed (a rename can change the collision-free name of another target),
    /// only keys under `services:` are touched, and a name the file already uses stops the heal.
    private func migrateExtras(destination: String, renames: [Rename], before: Rules, after: Rules, restore: inout [(file: URL, text: String)]) throws {
        guard RunnerExtras.isFileName(destination) else { return }
        let file = home.url.appendingPathComponent("runner-extras").appendingPathComponent(destination).appendingPathComponent(RunnerExtras.composeName)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let text = try String(contentsOf: file, encoding: .utf8)
        let base = SupportFiles.locate("runner-stack").flatMap { try? String(contentsOf: $0.appendingPathComponent("docker-compose.yml"), encoding: .utf8) } ?? ""
        let oldTargets = before.destinations[destination]?.runnerTargets ?? []
        let oldNames = RunnerCompose.serviceMap(base: base, targets: oldTargets)
        let newNames = RunnerCompose.serviceMap(base: base, targets: after.destinations[destination]?.runnerTargets ?? [])
        var moves = [String: String]()
        for target in oldTargets {
            let now = renames.first { $0.old.lowercased() == target.lowercased() }?.new ?? target
            if let from = oldNames[target.lowercased()], let to = newNames[now.lowercased()], from != to { moves[from] = to }
        }
        guard !moves.isEmpty else { return }
        let source = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inServices = false
        var keyAt = [Int: String]()
        for (index, line) in source.enumerated() {
            if !line.hasPrefix(" "), !line.isEmpty, !line.hasPrefix("#") { inServices = line.hasPrefix("services:") }
            if inServices, let key = Self.serviceKey(line) { keyAt[index] = key }
        }
        let keys = Set(keyAt.values)
        for (from, to) in moves where keys.contains(from) && keys.contains(to) && moves[to] == nil {
            throw ExtrasConflict(description: "\(destination)'s extras already define \(to); remove one of \(from) and \(to), then set the box up")
        }
        // A service named in `depends_on`, `links` or `volumes_from` would dangle after the rename, and editing YAML structure is not this code's job: stop and say so.
        var blockIndent: Int?
        for line in source {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.prefix { $0 == " " }.count
            if let open = blockIndent, indent <= open { blockIndent = nil }
            if ["depends_on:", "links:", "volumes_from:"].contains(where: trimmed.hasPrefix) {
                blockIndent = indent
            } else if blockIndent == nil { continue }
            for from in moves.keys where Self.mentions(line, name: from) {
                throw ExtrasConflict(description: "\(destination)'s extras refer to \(from) in a dependency line; update that reference by hand, then set the box up")
            }
        }
        var lines = [String]()
        for (index, line) in source.enumerated() {
            if let key = keyAt[index], let to = moves[key], let colon = line.firstIndex(of: ":") {
                lines.append("  \(to)" + line[colon...])
            } else {
                lines.append(line)
            }
        }
        let renamed = lines.joined(separator: "\n")
        guard renamed != text else { return }
        restore.append((file, text))
        try renamed.write(to: file, atomically: true, encoding: .utf8)
    }

    private func record(_ renames: [Rename]) {
        let directory = home.url.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("renames.log")
        let text = renames.map { "\($0.old) -> \($0.new)\n" }.joined()
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: file)
        }
    }
}

private extension RepoRenameHealer {
    /// `  name:` with optional quotes and a trailing comment: the name of a service key, two-space indented.
    static func serviceKey(_ line: String) -> String? {
        guard line.hasPrefix("  "), !line.hasPrefix("   "), let colon = line.firstIndex(of: ":") else { return nil }
        let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
        let name = line[line.index(line.startIndex, offsetBy: 2)..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return name.isEmpty || name.contains(" ") ? nil : name
    }

    /// `name` as a whole word: not part of a longer service, volume or file name.
    static func mentions(_ line: String, name: String) -> Bool {
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        var rest = line[...]
        while let found = rest.range(of: name) {
            let before = rest[..<found.lowerBound].last.map { String($0).unicodeScalars.allSatisfy(word.contains) } ?? false
            let after = rest[found.upperBound...].first.map { String($0).unicodeScalars.allSatisfy(word.contains) } ?? false
            if !before && !after { return true }
            rest = rest[found.upperBound...]
        }
        return false
    }
}
