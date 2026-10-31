import RMJCore
import SwiftUI

/// Everything RMJ puts on a destination, with what it does and why, so nothing on a box is a surprise.
struct BoxContents: View {
    private struct Item: Identifiable {
        let name: String
        let what: String
        var id: String { name }
    }

    private let services: [Item] = [
        Item(name: "gh-runner (one container per runner target)",
             what: "A GitHub Actions self-hosted runner for a repo or org in your rules. Takes one job, exits, and restarts registered afresh. Runs CI on the box instead of GitHub's minutes. Limited CPU, memory and pids; no Docker socket, no published ports."),
        Item(name: "burst-<target>-<id> (temporary)",
             what: "Extra runners the autoscaler starts when jobs queue and the box has room (up to 3 per box). Removed when idle. Log: ~/.rmj/logs/scaler.log."),
        Item(name: "rx job containers",
             what: "One short-lived container per `rmj run` job, built from an image below, with your repo synced in. Gone when the job ends; the box keeps only the build cache you configured."),
    ]

    private let files: [Item] = [
        Item(name: "<home>/infra/gh-runners",
             what: "The runner stack: a Dockerfile, entrypoint and docker-compose files. RMJ writes them at Setup. The GitHub token is piped over ssh into docker compose and never written to disk on the box."),
        Item(name: "rx-run.sh",
             what: "The box-side waiter that starts a job container once a slot is free."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "On your boxes",
                         detail: "Nothing else is installed. A box needs only ssh, docker and rsync; RMJ never touches the host's own packages.") {
                ForEach(services) { row($0) }
            }
            SettingsCard(title: "Build images",
                         detail: "Jobs run inside one of these, chosen by a routing rule's image. RMJ builds the ones your rules use at Setup.") {
                ForEach(BuildEnvironments.catalog, id: \.image) { env in
                    row(Item(name: env.image, what: "\(env.summary). Contains: \(env.tools.joined(separator: ", "))."))
                }
                Text("Your own image: set image on a rule to any image on the box (for example ubuntu:24.04, or one you built there) and list the programs it needs under requires on the destination. RMJ checks they exist; it builds only the images above.")
                    .font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            SettingsCard(title: "Files on the box") { ForEach(files) { row($0) } }
        }
    }

    private func row(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.textPrimary)
            Text(item.what).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
