import Foundation

/// `rmj destination report <name>` (a dry deploy: read-only), `rmj destination prune <name> [--preview]`,
/// `rmj destination setup <name>` (images, runner stack, registration check; idempotent).
public enum OpsCommand {
    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        guard arguments.count >= 2, ["report", "prune", "setup"].contains(arguments[0]) else {
            return RunCommand.fail("usage: rmj destination report <name> | prune <name> [--preview] | setup <name>", code: 2)
        }
        let name = arguments[1]
        let context: RunCommand.Context
        do { context = try await RunCommand.open(environment: environment) } catch { return RunCommand.fail("cannot open the ledger: \(error.localizedDescription)") }
        guard let rules = context.rules.rules, let destination = rules.destinations[name] else { return RunCommand.fail("no destination named \(name) in a valid rules file") }
        let targets = destination.runnerTargets ?? []
        do {
            if arguments[0] == "report" {
                guard case .online(let address) = DestinationResolver.resolve(DestinationTarget(alias: destination.sshAlias, peerID: destination.peerID), in: context.tailnet) else {
                    return RunCommand.fail("\(name) is not reachable on the tailnet")
                }
                let shell = SSHOpsShell(address: address, alias: destination.sshAlias)
                guard let stack = environment["RMJ_STACK"].map({ URL(fileURLWithPath: $0) }) ?? SupportFiles.locate("runner-stack", environment: environment) else {
                    return RunCommand.fail("the runner stack files were not found; set RMJ_SUPPORT to a Support directory")
                }
                let report = try await RunnerStackDeployer(shell: shell, stack: stack, home: destination.home, tokens: DestinationOps.tokens(targets, home: context.home), requiredTargets: targets, host: name, labels: destination.runnerLabels ?? [:]).report()
                print(report.isNoOp ? "deploy: no-op (stack and credentials are current)" : "deploy: would change \(report.changedFiles.count) files\(report.credentialsChanged ? " and credentials" : "")\(report.composeChanged ? " and the generated compose file" : "")\(report.legacyEnv ? " and the old .env" : "")")
                for runner in report.runners { print("\(runner.name)  \(runner.state)  version \(runner.version ?? "unknown")  \(runner.status)") }
                for image in try await RunnerImages.list(shell: shell) { print("image \(image.repository):\(image.tag)  \(image.age)") }
            } else if arguments[0] == "setup" {
                guard case .online(let address) = DestinationResolver.resolve(DestinationTarget(alias: destination.sshAlias, peerID: destination.peerID), in: context.tailnet) else {
                    return RunCommand.fail("\(name) is not reachable on the tailnet")
                }
                let tokens = DestinationOps.tokens(targets, home: context.home)
                let registrations = DestinationSetup.registrations(api: GHCLI(), targets: targets, tokens: tokens)
                let setup = DestinationSetup(shell: SSHOpsShell(address: address, alias: destination.sshAlias), name: name, config: destination,
                                             stack: SupportFiles.locate("runner-stack", environment: environment), images: SupportFiles.locate("box/images", environment: environment),
                                             neededImages: rules.images(for: name), tokens: tokens, registrations: registrations, notice: { print($0) })
                let report = await setup.run()
                for step in report.steps {
                    print("\(step.outcome.rawValue)  \(step.name): \(step.detail)")
                    if let hint = step.hint { print("    \(hint)") }
                }
                return report.isReady ? 0 : 1
            } else {
                let pruner = RegistrationPruner(api: GHCLI())
                let preview = arguments.contains("--preview")
                for target in targets {
                    let token = DestinationOps.tokens([target], home: context.home)[target]
                    if preview {
                        for runner in try await pruner.candidates(target: target, destinationLabel: name, token: token) { print("\(target): would delete \(runner.name)") }
                    } else {
                        let result = try await pruner.prune(target: target, destinationLabel: name, token: token)
                        for deleted in result.deleted { print("\(target): deleted \(deleted)") }
                        for skip in result.skipped { print("\(target): skipped \(skip.runner) (\(skip.reason))") }
                    }
                }
            }
        } catch { return RunCommand.fail("\(error)") }
        return 0
    }
}
