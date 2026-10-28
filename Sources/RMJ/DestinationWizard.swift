import RMJCore
import SwiftUI

/// Add a peer as a destination: the fields, the checks, then the setup of the box, each step reported with its fix.
struct DestinationWizard: View {
    let row: BoxInventory.Row
    let tenants: [String]
    let done: () -> Void
    @State private var name = ""
    @State private var alias = ""
    @State private var tenant = ""
    @State private var rx = true
    @State private var runners = false
    @State private var home = ""
    @State private var maxJobs = "3"
    @State private var memoryBudget = "8g"
    @State private var targets = ""
    @State private var tokens: [String: String] = [:]
    @State private var report: OnboardingReport?
    @State private var running = false
    @State private var setup: String?
    @State private var problem: String?

    private var targetList: [String] { targets.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    var body: some View {
        if let setup {
            SetupRunView(name: setup, tokens: [:], done: done)
        } else {
            ModalFrame(title: "Add \(row.host)", detail: "RMJ checks the box, then sets it up. Nothing is installed on it beyond containers.", content: {
                form
                if let problem { ProblemText(text: problem) }
                if let report { steps(report) }
            }, footer: ModalFooter(
                secondary: .init(title: "Cancel", run: done),
                primary: .init(title: running ? "Checking..." : "Check and add", disabled: running || name.isEmpty || tenant.isEmpty || home.isEmpty) { Task { await add() } }))
            .onAppear { name = row.host; alias = row.host; home = "/home/\(NSUserName())"; tenant = tenants.first ?? "" }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Name", "How rules refer to it", $name)
            field("ssh alias", "`ssh <alias>` must work from this Mac without a prompt", $alias)
            field("Tenant", tenants.isEmpty ? "A tenant of your rules file" : tenants.joined(separator: ", "), $tenant)
            field("Home on the box", "Where RMJ keeps its files there", $home)
            SwitchRow(title: "Runs rx jobs (builds, tests)", isOn: $rx)
            SwitchRow(title: "Hosts GitHub runners", isOn: $runners)
            if runners {
                field("Runner targets", "GitHub owners or owner/repo, comma separated", $targets)
                ForEach(targetList, id: \.self) { target in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Token for \(target)").font(.meta).foregroundStyle(Theme.textTertiary)
                        SecretField(placeholder: "Personal access token (stored in the Keychain)", text: Binding(get: { tokens[target] ?? "" }, set: { tokens[target] = $0 }))
                    }
                }
            }
        }
    }

    private func field(_ title: String, _ detail: String, _ text: Binding<String>) -> some View {
        FieldBlock(title: title) { GlassField(placeholder: detail, text: text) }
    }

    private func steps(_ report: OnboardingReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(report.steps.enumerated()), id: \.offset) { _, step in
                StatusLine(text: "\(step.ok ? "ok" : "failed")  \(step.name): \(step.detail)", tone: step.ok ? .ok : .failed, hint: step.hint)
            }
        }
    }

    private func add() async {
        running = true
        problem = nil
        defer { running = false }
        guard let jobs = Int(maxJobs), jobs > 0 else { return problem = "Max jobs must be a whole number above 0." }
        guard memoryBudget.range(of: #"^[1-9][0-9]*g$"#, options: .regularExpression) != nil else { return problem = "Memory budget looks like 8g." }
        let roles = (rx ? ["rx"] : []) + (runners ? ["runners"] : [])
        guard !roles.isEmpty else { return problem = "Pick at least one role." }
        guard !runners || !targetList.isEmpty else { return problem = "Runners need at least one GitHub owner or repo." }
        var draft = DestinationDraft(name: name, peerID: row.peerID, sshAlias: alias, tenant: tenant, roles: roles, home: home,
                                     maxJobs: jobs, memoryBudget: memoryBudget)
        draft.runnerTargets = runners ? targetList : []
        let result = await DestinationOnboarding(probes: LiveProbeProvider(), store: RulesStore(home: RMJHome())).run(draft, tailnet: await TailnetState.read())
        report = result
        guard result.written else { return }
        // Tokens are stored only for a destination that passed its checks.
        for target in draft.runnerTargets {
            let token = (tokens[target] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            do { try Keychain().write(token, account: "rmj.pat.\(target)") } catch {
                problem = "The destination was added, but the token for \(target) could not be stored: \(error)"
            }
        }
        setup = name
    }
}

/// Runs the setup of a configured destination and lists what each step did.
struct SetupRunView: View {
    let name: String
    let tokens: [String: String]
    let done: () -> Void
    @State private var report: DestinationSetup.Report?
    @State private var working = true
    @State private var notice = ""
    @State private var missing: [String] = []
    /// The targets that share one GitHub owner's PAT, keyed by the first of them (the one the form asks about).
    @State private var sharing: [String: [String]] = [:]
    @State private var entered: [String: String] = [:]
    @State private var storeProblem: String?

    var body: some View {
        ModalFrame(title: "Setting up \(name)", content: {
            if !missing.isEmpty { tokenForm }
            if working, missing.isEmpty { Text(notice.isEmpty ? "Reading the box..." : notice).font(.meta).foregroundStyle(Theme.textSecondary) }
            if let report {
                ForEach(Array(report.steps.enumerated()), id: \.offset) { _, step in
                    StatusLine(text: "\(step.outcome.rawValue)  \(step.name): \(step.detail)",
                               tone: step.outcome == .failed ? .failed : step.outcome == .changed ? .changed : .plain, hint: step.hint)
                }
                Text(report.isReady ? (report.changed ? "Ready. Changed what was missing." : "Ready. Nothing needed changing.") : "Not ready. Fix the failed step and run it again.")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(report.isReady ? Theme.ok : Theme.crit)
            }
        }, footer: footer)
        .task { await prepare() }
    }

    private var footer: ModalFooter {
        if !missing.isEmpty {
            return ModalFooter(secondary: .init(title: "Cancel", run: done),
                               primary: .init(title: "Save and set up", disabled: missing.contains { (entered[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { Task { await saveTokens() } })
        }
        return ModalFooter(primary: working ? nil : .init(title: "Done", run: done))
    }

    /// A destination whose runners need a PAT that is not in the Keychain asks for it here, then sets up.
    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub needs a token to register the runners. It is stored in your Keychain, never in a file.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            ForEach(missing, id: \.self) { target in
                FieldBlock(title: "Token for \(Self.owner(target))", detail: (sharing[target] ?? [target]).joined(separator: ", ")) {
                    SecretField(placeholder: "Personal access token", text: Binding(get: { entered[target] ?? "" }, set: { entered[target] = $0 }))
                }
            }
            if let storeProblem { ProblemText(text: storeProblem) }
        }
    }

    private static func owner(_ target: String) -> String {
        target.hasPrefix("org:") ? target : String(target.split(separator: "/").first ?? Substring(target))
    }

    private func prepare() async {
        guard case .valid(let rules, _) = RulesStore(home: RMJHome()).load(), let config = rules.destinations[name] else { return await run() }
        let targets = config.runnerTargets ?? []
        let found = DestinationOps.tokens(targets, home: RMJHome())
        // One PAT serves every target of the same owner: ask once per owner.
        // A stored PAT of the same owner serves the owner's other targets, so a new repo does not ask again.
        let stored = Dictionary(found.compactMap { target, token in RunnerTarget.environmentName(target).map { ($0, token) } }, uniquingKeysWith: { first, _ in first })
        for target in targets where found[target] == nil {
            guard let name = RunnerTarget.environmentName(target), let token = stored[name] else { continue }
            try? Keychain().write(token, account: "rmj.pat.\(target)")
        }
        let reread = DestinationOps.tokens(targets, home: RMJHome())
        let lacking = targets.filter { reread[$0] == nil }
        sharing = Dictionary(grouping: lacking) { RunnerTarget.environmentName($0) ?? $0 }.reduce(into: [:]) { $0[$1.value[0]] = $1.value }
        missing = lacking.filter { sharing[$0] != nil }
        if missing.isEmpty { await run() } else { working = false }
    }

    private func saveTokens() async {
        for target in missing {
            let token = (entered[target] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            for covered in sharing[target] ?? [target] {
                do { try Keychain().write(token, account: "rmj.pat.\(covered)") } catch {
                    storeProblem = "Could not store the token for \(covered): \(error)"
                    return
                }
            }
        }
        entered = [:]
        storeProblem = nil
        missing = []
        working = true
        await run()
    }

    private func run() async {
        defer { working = false }
        guard case .valid(let rules, _) = RulesStore(home: RMJHome()).load(), let config = rules.destinations[name] else {
            report = DestinationSetup.Report(steps: [DestinationSetup.Step(name: "rules", outcome: .failed, detail: "no destination \(name)", hint: "Fix ~/.rmj/rules.json")])
            return
        }
        let state = await TailnetState.read()
        guard case .online(let address) = DestinationResolver.resolve(DestinationTarget(alias: config.sshAlias, peerID: config.peerID), in: state) else {
            report = DestinationSetup.Report(steps: [DestinationSetup.Step(name: "reachability", outcome: .failed, detail: "\(name) is not online on the tailnet", hint: "Start the machine or Tailscale on it")])
            return
        }
        let home = RMJHome()
        let targets = config.runnerTargets ?? []
        let found = DestinationOps.tokens(targets, home: home)
        let api = GHCLI()
        let registrations = DestinationSetup.registrations(api: api, targets: targets, tokens: found)
        let setup = DestinationSetup(
            shell: SSHOpsShell(address: address, alias: config.sshAlias), name: name, config: config,
            stack: SupportFiles.locate("runner-stack"), images: SupportFiles.locate("box/images"), neededImages: rules.images(for: name),
            tokens: found,
            registrations: registrations,
            notice: { text in Task { @MainActor in notice = text } })
        report = await setup.run()
    }
}
