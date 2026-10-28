import Testing
import Foundation
import RMJCore

struct RunReconcileAcceptanceTests {
    @Test func droppedClientLeavesPendingLogThenReconcilesBoxTimesAndFullLog() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        await f.box.configure(failure: "tail", answer: BoxRecord(containerPresent: true, bootID: "boot",
                                                                 launch: .started(container: "c", bootID: "boot")))
        let result = await f.engine().run(f.request())
        #expect(result.state == .running)
        #expect(try await f.ledger.job(result.jobID)?.state == .running)
        #expect(try await f.archive.entry(jobID: result.jobID)?.status == .pending)
        #expect(f.output.text == "box output\n")
        let start = runNow.addingTimeInterval(-1000)
        let end = start.addingTimeInterval(2.5)
        await f.box.configure(answer: BoxRecord(containerPresent: false, bootID: "boot",
                                               launch: .started(container: "c", bootID: "boot"), result: .init(code: 0),
                                               meta: .init(started: start, finished: end, exit: 0)))
        await f.reconcile()
        let row = try #require(try await f.ledger.job(result.jobID))
        #expect(row.state == .done && row.exitCode == 0)
        #expect(row.boxStartedAt == start && row.boxEndedAt == end && row.boxExit == 0)
        #expect(row.duration == .box(milliseconds: 2500))
        #expect(try await f.log(result.jobID) == "full box log\n")
        #expect(await f.box.calls.contains("pullLog"))
        let events = try await f.ledger.events(result.jobID)
        await f.reconcile()
        #expect(try await f.ledger.events(result.jobID) == events)
    }

    @Test func absentContainerDistinguishesRebootFromVanishedAndPullsTruncatedLog() async throws {
        for boot in ["old", "new"] {
            let f = try await RunFixture.make(); defer { f.remove() }
            let id = try await f.insert()
            await f.box.configure(answer: BoxRecord(containerPresent: false, bootID: boot,
                                                    launch: .started(container: "c", bootID: "old")))
            await f.reconcile()
            #expect(try await f.ledger.job(id)?.state == .lost)
            #expect(try await f.ledger.events(id).last?.detail == (boot == "new" ? "destination rebooted" : "container vanished"))
            #expect(try await f.log(id) == "full box log\n")
            #expect(try await f.archive.entry(jobID: id)?.truncated == true)
        }
    }

    @Test func presentContainerWithoutResultLeavesRunningRowUnchanged() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        let id = try await f.insert()
        let before = try await f.ledger.job(id)
        let events = try await f.ledger.events(id)
        await f.box.configure(answer: BoxRecord(containerPresent: true, bootID: "boot",
                                                launch: .started(container: "c", bootID: "boot")))
        await f.reconcile()
        #expect(try await f.ledger.job(id) == before)
        #expect(try await f.ledger.events(id) == events)
    }

    @Test func threeFailedReadsMarkLostAndLaterResultSettlesIt() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        let id = try await f.insert()
        await f.box.configure(recordFailures: true)
        await f.reconcile()
        #expect(await f.box.calls.filter { $0 == "record" }.count == 3)
        #expect(try await f.ledger.job(id)?.state == .lost)
        #expect(try await f.ledger.events(id).last?.detail == "destination unreachable")
        await f.box.configure(answer: BoxRecord(containerPresent: false, bootID: "boot", result: .init(code: 0),
                                               meta: .init(started: runNow.addingTimeInterval(-4), finished: runNow, exit: 0)))
        await f.reconcile()
        #expect(try await f.ledger.job(id)?.state == .done)
        #expect(try await f.ledger.job(id)?.duration == .box(milliseconds: 4000))
    }

    @Test func abandonedQueuedRowFailsButYoungQueuedRowIsUntouched() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        let old = try await f.insert(.queued, age: Reconciler.abandonedAfter + 1)
        let young = try await f.insert(.queued, age: Reconciler.abandonedAfter - 1)
        let before = try await f.ledger.job(young)
        await f.box.configure(answer: BoxRecord(containerPresent: false, bootID: "boot"))
        await f.reconcile()
        #expect(try await f.ledger.job(old)?.state == .failed)
        #expect(try await f.ledger.events(old).last?.detail == "client stopped before the command started")
        #expect(try await f.ledger.job(young) == before)
    }

    @Test func cancelPollsUntilGoneAndHandlesSettledUnknownAndOfflineRows() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        let id = try await f.insert()
        await f.box.setCancelRecords([BoxRecord(containerPresent: true, bootID: "boot"),
                                      BoxRecord(containerPresent: false, bootID: "boot")])
        #expect(await f.engine().cancel(id) == .cancelled)
        #expect(try await f.ledger.job(id)?.state == .cancelled)
        #expect(await f.box.calls == ["cancel:" + id, "record", "record"])
        #expect(await f.engine().cancel(id) == .alreadySettled)
        #expect(await f.engine().cancel("missing") == .notFound)
        #expect(await f.box.calls == ["cancel:" + id, "record", "record"])
        let offline = try await RunFixture.make(stopped: true); defer { offline.remove() }
        let other = try await offline.insert()
        #expect(await offline.engine().cancel(other) == .unreachable)
        #expect(try await offline.ledger.job(other)?.state == .running)
        #expect(await offline.box.calls.isEmpty)
    }

    @Test func cancelledBoxResultIsCancelledRatherThanFailed() async throws {
        let f = try await RunFixture.make(); defer { f.remove() }
        await f.box.configure(answer: BoxRecord(containerPresent: false, bootID: "boot",
                                               launch: .started(container: "c", bootID: "boot"),
                                               result: .init(code: 137, cancelled: true)))
        let result = await f.engine().run(f.request())
        #expect(result.state == .cancelled && result.exitCode == 137)
        #expect(try await f.ledger.job(result.jobID)?.state == .cancelled)
    }
}
