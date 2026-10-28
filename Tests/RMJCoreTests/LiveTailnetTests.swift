import Foundation
import RMJCore
import Testing

/// Needs the tailnet up and RMJ_LIVE_DESTINATION configured and reachable: `RMJ_LIVE=1 swift test --filter Live`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RMJ_LIVE"] == "1" &&
    !(ProcessInfo.processInfo.environment["RMJ_LIVE_DESTINATION"] ?? "").isEmpty))
struct LiveTailnetTests {
    @Test func probesConfiguredDestinationOnlineWithDockerAndRsync() async throws {
        let tailnet = await TailnetState.read()
        #expect(tailnet.standing == .running)
        let alias = try #require(ProcessInfo.processInfo.environment["RMJ_LIVE_DESTINATION"])
        let rules = try #require(RulesStore(home: RMJHome()).load().rules)
        let config = try #require(rules.destinations[alias])
        let target = DestinationTarget(alias: config.sshAlias, peerID: config.peerID)
        let result = await DestinationProbe().probe(target, tailnet: tailnet)
        print("live probe:", result)
        #expect(result.availability.isAvailable)
        #expect(result.dockerReady)
        #expect(result.rsyncReady)
        #expect(result.bootID != nil)
    }
}
