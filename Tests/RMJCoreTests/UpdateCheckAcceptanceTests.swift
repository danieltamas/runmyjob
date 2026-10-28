import Foundation
import Testing
import RMJCore

// The synchronous log closure uses a lock; feed sequencing is isolated in an actor.
private final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return messages.count
    }
}

private actor UpdateFeedSequence {
    private var outcomes: [ReleaseFeed.Outcome]
    private var repos: [String] = []

    init(_ outcomes: [ReleaseFeed.Outcome]) { self.outcomes = outcomes }
    func latest(_ repo: String) -> ReleaseFeed.Outcome {
        repos.append(repo)
        return outcomes.isEmpty ? .unavailable : outcomes.removeFirst()
    }
    func requestedRepos() -> [String] { repos }
}

struct UpdateCheckAcceptanceTests {
    @Test("A higher numeric release is available while equal and older releases are current")
    func numericVersions() async {
        let release = ReleaseInfo(version: "1.2.0", url: URL(string: "https://example.com/acme/ledger/releases/v1.2.0"))
        let feed = UpdateFeedSequence([.release(release)])
        let newer = UpdateChecker(repo: "acme/ledger", installed: "1.1.9",
                                  feed: { await feed.latest($0) }, log: { _ in })
        #expect(await newer.check() == .available(release))
        #expect(await feed.requestedRepos() == ["acme/ledger"])
        let equal = UpdateChecker(repo: "acme/ledger", installed: "1.2.0",
                                  feed: { _ in .release(release) }, log: { _ in })
        #expect(await equal.check() == .current)
        let olderRelease = ReleaseInfo(version: "1.9.2", url: nil)
        let ahead = UpdateChecker(repo: "acme/ledger", installed: "1.10.0",
                                  feed: { _ in .release(olderRelease) }, log: { _ in })
        #expect(await ahead.check() == .current)
        let numericNewer = ReleaseInfo(version: "1.10.0", url: nil)
        let behind = UpdateChecker(repo: "acme/ledger", installed: "1.9.2",
                                   feed: { _ in .release(numericNewer) }, log: { _ in })
        #expect(await behind.check() == .available(numericNewer))
    }

    @Test("A repository without a release is current")
    func noRelease() async {
        let checker = UpdateChecker(repo: "acme/ledger", installed: "1.2.0",
                                    feed: { _ in .noRelease }, log: { _ in })
        #expect(await checker.check() == .current)
    }

    @Test("An unavailable feed returns unknown without throwing and logs once across three checks")
    func unavailableLogsOnce() async {
        let log = UpdateLog()
        let checker = UpdateChecker(repo: "acme/ledger", installed: "1.2.0",
                                    feed: { _ in .unavailable }, log: { log.append($0) })
        for _ in 0..<3 { #expect(await checker.check() == .unknown) }
        #expect(log.count == 1)
    }

    @Test("A failed feed can recover and report an available release on the next check")
    func feedRecovery() async {
        let release = ReleaseInfo(version: "1.2.0", url: nil)
        let feed = UpdateFeedSequence([.unavailable, .release(release)])
        let log = UpdateLog()
        let checker = UpdateChecker(repo: "acme/ledger", installed: "1.1.9",
                                    feed: { await feed.latest($0) }, log: { log.append($0) })
        #expect(await checker.check() == .unknown)
        #expect(await checker.check() == .available(release))
        #expect(log.count == 1)
        #expect(await feed.requestedRepos() == ["acme/ledger", "acme/ledger"])
    }

    @Test("A zero release is never available for a zero or unparsable installed version")
    func zeroAndUnparsableVersions() async {
        let release = ReleaseInfo(version: "0.0.0", url: nil)
        for installed in ["0.0.0", "not-a-version"] {
            let checker = UpdateChecker(repo: "acme/ledger", installed: installed,
                                        feed: { _ in .release(release) }, log: { _ in })
            #expect(await checker.check() != .available(release))
        }
    }
}
