import Foundation
import RMJCore

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == KeychainProbe.flag {
    exit(KeychainProbe.runFromCommandLine(Array(arguments.dropFirst())))
}
if arguments.first == "route" {
    exit(await RouteCommand.run(arguments: Array(arguments.dropFirst())))
}
if arguments.first == "github", arguments.dropFirst().first == "poll" {
    exit(await GitHubCommand.poll(arguments: Array(arguments.dropFirst(2))))
}
if arguments.first == "destination" {
    exit(await OpsCommand.run(arguments: Array(arguments.dropFirst())))
}
if arguments.first == "hooks" {
    exit(HooksCommand.hooks(arguments: Array(arguments.dropFirst())))
}
if arguments.first == "guard" {
    exit(await HooksCommand.guardCommand(arguments: Array(arguments.dropFirst())))
}
if arguments.first == "rerun" {
    exit(await GitHubCommand.rerun(arguments: Array(arguments.dropFirst())))
}
if let command = arguments.first, ["run", "jobs", "cancel"].contains(command) {
    let rest = Array(arguments.dropFirst())
    switch command {
    case "run": exit(await RunCommand.run(arguments: rest))
    case "jobs": exit(await RunCommand.jobs(arguments: rest))
    default: exit(await RunCommand.cancel(arguments: rest))
    }
}
// The installer recognises its own command by the rmj-cli: marker in this binary.
FileHandle.standardError.write(Data("rmj-cli: nothing to run yet (U0 skeleton)\n".utf8))
exit(2)
