import Foundation

/// Bounds how often one Mac Service's Invalidations reach the guest: a change
/// after a quiet interval emits inline, and any burst inside the interval
/// coalesces into one trailing emission at `flushDeadline`. The type is pure
/// so refresh bounding is testable without timers or EventKit.
struct OmarchyLinkInvalidationThrottle {
    private let minimumInterval: TimeInterval
    private var lastEmission: Date?
    private var pending = false

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// When a coalesced emission is due, or nil when nothing is pending.
    var flushDeadline: Date? {
        guard pending, let lastEmission else { return nil }
        return lastEmission.addingTimeInterval(minimumInterval)
    }

    /// Records one observed change. Returns true when the caller should emit
    /// an Invalidation right now.
    mutating func noteChange(at now: Date) -> Bool {
        if let lastEmission, now < lastEmission.addingTimeInterval(minimumInterval) {
            pending = true
            return false
        }
        lastEmission = now
        pending = false
        return true
    }

    /// Returns true when a coalesced emission is due and marks it emitted.
    mutating func flush(at now: Date) -> Bool {
        guard let deadline = flushDeadline, now >= deadline else { return false }
        lastEmission = now
        pending = false
        return true
    }
}
