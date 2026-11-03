import Foundation

/// A job whose box is only full (at `max_jobs` or over the memory budget) waits for room instead of running on the
/// Mac: for a repo whose tests need the box's services, and whose Mac checkout holds real credentials, a silent
/// fallback runs the wrong thing in the wrong place. Any other reason to leave the box (offline, denied, no rule)
/// still falls back at once.
enum CapacityWait {
    /// Two hours, the same bound the box's own lock wait uses.
    static let limit: Duration = .seconds(7200)

    static func isCapacity(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason.contains(" over memory budget") || reason.contains(" at max_jobs")
    }

    /// The first decision that is not a capacity skip, or the last capacity decision once `limit` has passed.
    static func route(_ request: RouteRequest, router: Router, poll: Duration, limit: Duration = CapacityWait.limit,
                      notice: @Sendable (String) -> Void) async -> RouteDecision {
        var decision = await router.route(request).sanitized()
        guard isCapacity(decision.fallbackReason), !request.forceLocal else { return decision }
        notice("rmj: waiting for room on the box: \(decision.fallbackReason ?? "full")")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while isCapacity(decision.fallbackReason), clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: poll)
            decision = await router.route(request).sanitized()
        }
        return decision
    }
}
