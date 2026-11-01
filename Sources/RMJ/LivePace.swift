import RMJCore
import SwiftUI

/// Rings when a box sent a frame or the pace changed, and wakes whoever waits on it. A ring with nobody waiting is kept for the next wait.
final class FrameBell: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var rung = false
    private var framesWanted = false

    /// Whether what is on screen changes with every box frame. Only the Destinations tab does: a frame must not rebuild the Jobs list.
    func setFramesWanted(_ wanted: Bool) { lock.withLock { framesWanted = wanted } }

    /// A box sent a frame: rings only while something on screen shows box readings.
    func ringForFrame() {
        if lock.withLock({ framesWanted }) { ring() }
    }

    func ring() {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            if waiting.isEmpty { rung = true }
            defer { waiting = [:] }
            return Array(waiting.values)
        }
        woken.forEach { $0.resume() }
    }

    /// Returns at the next ring, at once when one is kept, or when the task is cancelled.
    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if rung || Task.isCancelled { rung = false; return true }
                    waiting[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiting.removeValue(forKey: id) }?.resume()
        }
    }
}

/// How fast the boxes report: every `live` seconds while the panel or the Destinations settings are on screen, every `idle` seconds
/// otherwise (docs/PLAN.md, U18). Going back to idle waits `linger`, so closing and reopening the panel does not restart the sessions.
@MainActor
final class LivePace {
    static let live = 2
    static let idle = 10
    private static let linger = Duration.seconds(5)
    /// The loop never turns faster than this, however many boxes send a frame.
    private static let floor = 2.0

    private let streams: BoxStreams
    private let bell: FrameBell
    private var watching = Set<String>()
    private var settling: Task<Void, Never>?
    private(set) var isLive = false

    init(streams: BoxStreams, bell: FrameBell) {
        self.streams = streams
        self.bell = bell
    }

    /// A view that shows box readings says whether it is on screen.
    func set(_ viewer: String, onScreen: Bool) {
        if onScreen { watching.insert(viewer) } else { watching.remove(viewer) }
        if onScreen { settling?.cancel() }
        let wanted = !watching.isEmpty
        guard wanted != isLive else { return }
        settling?.cancel()
        if wanted {
            isLive = true
            let streams = streams
            settling = Task { await streams.setFrameInterval(Self.live) }
            // A loop asleep for the hidden-idle 15 s hears of it now.
            bell.ring()
        } else {
            settling = Task { [weak self] in
                try? await Task.sleep(for: Self.linger)
                guard !Task.isCancelled, let self, watching.isEmpty else { return }
                isLive = false
                await streams.setFrameInterval(Self.idle)
            }
        }
    }

    /// Sleeps up to `seconds`. While live, a frame from any box (or the panel opening) ends the wait early, but never within `floor` of its start.
    func wait(_ seconds: Double) async {
        let started = Date()
        var early = false
        while true {
            let remaining = seconds - Date().timeIntervalSince(started)
            if remaining <= 0 { break }
            let bell = bell
            let rang = await withTaskGroup(of: Bool.self) { group in
                group.addTask { try? await Task.sleep(for: .seconds(remaining)); return false }
                group.addTask { await bell.wait(); return true }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            // Frames of an idle pace are not worth a turn of the loop.
            if rang && isLive { early = true; break }
            if !rang { break }
        }
        let spent = Date().timeIntervalSince(started)
        // A timed-out wait is the loop's own beat; only a frame-driven wake is held to the floor.
        if early, spent < Self.floor { try? await Task.sleep(for: .seconds(Self.floor - spent)) }
    }
}
