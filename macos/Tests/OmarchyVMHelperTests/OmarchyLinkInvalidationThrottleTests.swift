import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Omarchy Link Invalidation throttle")
struct OmarchyLinkInvalidationThrottleTests {
    private let epoch = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("a quiet change emits immediately and a burst coalesces to one trailing emission")
    func coalescesBursts() {
        var throttle = OmarchyLinkInvalidationThrottle(minimumInterval: 2)
        let first = throttle.noteChange(at: epoch)
        #expect(first)

        // A burst inside the interval never emits inline.
        let burstOne = throttle.noteChange(at: epoch.addingTimeInterval(0.1))
        let burstTwo = throttle.noteChange(at: epoch.addingTimeInterval(0.5))
        #expect(!burstOne && !burstTwo)
        #expect(throttle.flushDeadline == epoch.addingTimeInterval(2))

        // Flushing early stays silent; flushing at the deadline emits once.
        let early = throttle.flush(at: epoch.addingTimeInterval(1.9))
        #expect(!early)
        let due = throttle.flush(at: epoch.addingTimeInterval(2))
        #expect(due)
        #expect(throttle.flushDeadline == nil)
        let repeated = throttle.flush(at: epoch.addingTimeInterval(3))
        #expect(!repeated)
    }

    @Test("changes after a quiet interval emit inline again")
    func recoversAfterQuietPeriod() {
        var throttle = OmarchyLinkInvalidationThrottle(minimumInterval: 2)
        let first = throttle.noteChange(at: epoch)
        let second = throttle.noteChange(at: epoch.addingTimeInterval(5))
        #expect(first && second)
        #expect(throttle.flushDeadline == nil)
    }
}
