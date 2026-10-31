import Testing
import RMJCore

// Expected values come from the owner's 2026-10-31 burst runner contract.
struct RunnerScalerAcceptanceTests {
    private let target = "danieltamas/lexito.ro"
    private let other = "org:Gamerina"
    private let gib: Int64 = 1_073_741_824

    private func box(_ name: String = "a", targets: [String]? = nil, cpus: Int = 16,
                     load: Double = 0, free: Int64? = nil, online: Bool = true,
                     bursts: [ScaleBurst] = []) -> ScaleBox {
        ScaleBox(name: name, targets: targets ?? [target], cpus: cpus, load1: load,
                 memoryBudgetBytes: 64 * gib, memoryCommittedBytes: 64 * gib - (free ?? 64 * gib),
                 online: online, bursts: bursts)
    }
    private func demand(_ waits: [Double] = [20], idle: Int = 0, target: String? = nil) -> ScaleDemand {
        ScaleDemand(target: target ?? self.target, waitingSeconds: waits, idleRunners: idle)
    }
    private func burst(_ name: String = "burst-old-abcdef", age: Double = 0,
                       busy: Bool? = nil, target: String? = nil) -> ScaleBurst {
        ScaleBurst(name: name, target: target ?? self.target, ageSeconds: age, busy: busy)
    }

    @Test func defaultsAndWaitThresholdAndIdleFloorSupply() {
        let p = RunnerScaler()
        #expect(p.burstCap == 3 && p.runnerMemoryBytes == 8 * gib && p.runnerCPUs == 4)
        #expect(p.minWaitSeconds == 20 && p.idleGraceSeconds == 60)
        #expect(p.unregisteredLimitSeconds == 180 && p.loadCeiling == 0.9)
        #expect(p.plan(boxes: [box()], demand: [demand([19.9])]).isEmpty)
        #expect(p.plan(boxes: [box()], demand: [demand()]) == [.start(box: "a", target: target)])
        #expect(p.plan(boxes: [box()], demand: [demand([20, 200], idle: 2)]).isEmpty)
        #expect(p.plan(boxes: [box()], demand: [demand([19.9, 20, 30], idle: 1)]) ==
                [.start(box: "a", target: target)])
        #expect(p.plan(boxes: [], demand: [demand()]).isEmpty)
    }

    @Test func pendingSupplyCountsAcrossBoxesButExpiresAt180Seconds() {
        let p = RunnerScaler()
        let pending = box("b", bursts: [burst(age: 179.9)])
        #expect(p.plan(boxes: [box(), pending], demand: [demand()]).isEmpty)
        #expect(p.plan(boxes: [box(), pending], demand: [demand([20, 20])]) ==
                [.start(box: "a", target: target)])
        #expect(p.plan(boxes: [box(bursts: [burst(age: 180)])], demand: [demand()]) ==
                [.stop(box: "a", container: "burst-old-abcdef"), .start(box: "a", target: target)])
        #expect(p.plan(boxes: [box(bursts: [burst(busy: true)])], demand: [demand()]) ==
                [.start(box: "a", target: target)])
        #expect(p.plan(boxes: [box(bursts: [burst(target: other)])], demand: [demand()]) ==
                [.start(box: "a", target: target)])
    }

    @Test func measuredScoreSpreadsThreePicksAndUsesCPUCount() {
        let p = RunnerScaler()
        #expect(p.plan(boxes: [box("b"), box("a")], demand: [demand([20, 20, 20])]) == [
            .start(box: "a", target: target), .start(box: "b", target: target),
            .start(box: "a", target: target)
        ])
        #expect(p.plan(boxes: [box("a", cpus: 8, load: 4), box("b", cpus: 32, load: 8)],
                       demand: [demand()]) == [.start(box: "b", target: target)])
        #expect(p.plan(boxes: [box("a", load: 8), box("b", load: 1)], demand: [demand()]) ==
                [.start(box: "b", target: target)])
    }

    @Test func tiesUseFreeBudgetThenNameRegardlessOfInputOrder() {
        let p = RunnerScaler()
        #expect(p.plan(boxes: [box("a", free: 8 * gib), box("z", free: 16 * gib)],
                       demand: [demand()]) == [.start(box: "z", target: target)])
        #expect(p.plan(boxes: [box("z"), box("a")], demand: [demand()]) ==
                [.start(box: "a", target: target)])
    }

    @Test func memoryAndCapacityAreUpdatedAcrossPicksAndTargets() {
        let p = RunnerScaler()
        #expect(p.plan(boxes: [box(free: 8 * gib)], demand: [demand()]) == [.start(box: "a", target: target)])
        #expect(p.plan(boxes: [box(free: 8 * gib - 1)], demand: [demand()]).isEmpty)
        #expect(p.plan(boxes: [box(free: 16 * gib)], demand: [demand([20, 20, 20])]) == [
            .start(box: "a", target: target), .start(box: "a", target: target)
        ])
        let full = (0..<3).map { burst("burst-other-00000\($0)", busy: true, target: other) }
        #expect(p.plan(boxes: [box(bursts: full)], demand: [demand()]).isEmpty)
        #expect(p.plan(boxes: [box(bursts: Array(full.prefix(2)))], demand: [demand([20, 20])]) ==
                [.start(box: "a", target: target)])
        let both = box(targets: [target, other], free: 8 * gib)
        #expect(p.plan(boxes: [both], demand: [demand(target: other), demand()]) ==
                [.start(box: "a", target: other)])
        #expect(p.plan(boxes: [both], demand: [demand(), demand(target: other)]) ==
                [.start(box: "a", target: target)])
        let roomy = box(targets: [target, other])
        #expect(p.plan(boxes: [roomy], demand: [demand([20, 20]), demand([20, 20], target: other)]) == [
            .start(box: "a", target: target), .start(box: "a", target: target), .start(box: "a", target: other)
        ])
    }

    @Test func loadBoundaryInvalidCPUsOfflineAndTenantIsolation() {
        let p = RunnerScaler()
        #expect(p.plan(boxes: [box(cpus: 100, load: 90)], demand: [demand()]).isEmpty)
        #expect(p.plan(boxes: [box(cpus: 100, load: 89)], demand: [demand()]) ==
                [.start(box: "a", target: target)])
        for cpus in [0, -1] { #expect(p.plan(boxes: [box(cpus: cpus)], demand: [demand()]).isEmpty) }
        #expect(p.plan(boxes: [box(online: false, bursts: [burst(age: 500)])], demand: [demand()]).isEmpty)
        #expect(p.plan(boxes: [box("wrong-tenant", targets: [other]), box("right", load: 4)],
                       demand: [demand()]) == [.start(box: "right", target: target)])
        #expect(p.plan(boxes: [box(targets: [target.uppercased()])], demand: [demand()]) ==
                [.start(box: "a", target: target)])
    }

    @Test func idleGraceBusyAndAnyAgeDemandGovernStops() {
        let p = RunnerScaler()
        let states = [burst("burst-young-aaaaaa", age: 59.9, busy: false),
                      burst("burst-idle-bbbbbb", age: 60, busy: false),
                      burst("burst-busy-cccccc", age: 999, busy: true),
                      burst("burst-pending-dddddd", age: 179.9)]
        let b = box(bursts: states)
        #expect(p.plan(boxes: [b], demand: []) == [.stop(box: "a", container: "burst-idle-bbbbbb")])
        #expect(p.plan(boxes: [b], demand: [demand([0])]).isEmpty)
        #expect(p.plan(boxes: [b], demand: [demand([], idle: 4)]) ==
                [.stop(box: "a", container: "burst-idle-bbbbbb")])
        #expect(p.plan(boxes: [b], demand: [demand([0], target: other)]) ==
                [.stop(box: "a", container: "burst-idle-bbbbbb")])
    }

    @Test func stopsPrecedeStartsSortedWithinInputBoxOrderAndAreDeterministic() {
        let p = RunnerScaler()
        let boxes = [box("z", bursts: [burst("burst-z-aaaaaa", age: 180), burst("burst-a-bbbbbb", age: 180)]),
                     box("a", bursts: [burst("burst-b-cccccc", age: 180)])]
        let expected: [ScaleAction] = [
            .stop(box: "z", container: "burst-a-bbbbbb"), .stop(box: "z", container: "burst-z-aaaaaa"),
            .stop(box: "a", container: "burst-b-cccccc"), .start(box: "a", target: target)
        ]
        for _ in 0..<10 { #expect(p.plan(boxes: boxes, demand: [demand()]) == expected) }
    }

    @Test func publicPlannerSettingsControlTheirBoundaries() {
        var p = RunnerScaler()
        p.minWaitSeconds = 5; p.burstCap = 1; p.runnerMemoryBytes = gib
        p.runnerCPUs = 8; p.loadCeiling = 0.5; p.idleGraceSeconds = 10; p.unregisteredLimitSeconds = 30
        #expect(p.plan(boxes: [box(free: gib)], demand: [demand([5, 5])]) == [.start(box: "a", target: target)])
        #expect(p.plan(boxes: [box(load: 8)], demand: [demand([5])]).isEmpty)
        #expect(p.plan(boxes: [box(bursts: [burst(age: 10, busy: false)])], demand: []) ==
                [.stop(box: "a", container: "burst-old-abcdef")])
        #expect(p.plan(boxes: [box(bursts: [burst(age: 30)])], demand: []) ==
                [.stop(box: "a", container: "burst-old-abcdef")])
        #expect(p.plan(boxes: [box("a"), box("b", load: 6)], demand: [demand([5, 5])]) == [
            .start(box: "a", target: target), .start(box: "b", target: target)
        ])
    }
}
