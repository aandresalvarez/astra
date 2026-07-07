import Testing
import SwiftUI
@testable import ASTRA

// MARK: - ChatScrollMetrics

@Suite("ChatScrollMetrics")
struct ChatScrollMetricsTests {

    @Test("isAtBottom treats the unmeasured (.infinity) default as at-bottom")
    func isAtBottomTreatsUnmeasuredDefaultAsAtBottom() {
        #expect(ChatScrollMetrics.isAtBottom(bottomMinY: .infinity, viewportHeight: 600))
    }

    @Test("isAtBottom is true resting exactly at the bottom and within the hysteresis slop")
    func isAtBottomIsTrueAtRestAndWithinSlop() {
        let viewportHeight: CGFloat = 600
        #expect(ChatScrollMetrics.isAtBottom(bottomMinY: viewportHeight, viewportHeight: viewportHeight))
        #expect(ChatScrollMetrics.isAtBottom(
            bottomMinY: viewportHeight + ChatScrollMetrics.atBottomSlop,
            viewportHeight: viewportHeight
        ))
    }

    @Test("isAtBottom is false once the sentinel is further below the viewport than the slop allows")
    func isAtBottomIsFalseBelowSlop() {
        let viewportHeight: CGFloat = 600
        #expect(!ChatScrollMetrics.isAtBottom(
            bottomMinY: viewportHeight + ChatScrollMetrics.atBottomSlop + 1,
            viewportHeight: viewportHeight
        ))
    }

    @Test("isAtBottom is true for short content that doesn't fill the viewport")
    func isAtBottomIsTrueForShortContent() {
        // A transcript shorter than the viewport rests with its bottom sentinel well
        // above the viewport's bottom edge — still a legitimate "at bottom" state,
        // not the parked-past-content bug this file also guards against.
        #expect(ChatScrollMetrics.isAtBottom(bottomMinY: 120, viewportHeight: 600))
    }

    @Test("isParkedPastContent is false for the unmeasured (.infinity) default")
    func isParkedPastContentIsFalseForUnmeasuredDefault() {
        #expect(!ChatScrollMetrics.isParkedPastContent(bottomMinY: .infinity))
    }

    @Test("isParkedPastContent is false resting exactly at the bottom")
    func isParkedPastContentIsFalseAtRest() {
        #expect(!ChatScrollMetrics.isParkedPastContent(bottomMinY: 600))
        #expect(!ChatScrollMetrics.isParkedPastContent(bottomMinY: 0))
    }

    @Test("isParkedPastContent ignores sub-pixel negative rounding at a genuine rest")
    func isParkedPastContentIgnoresRoundingNoise() {
        #expect(!ChatScrollMetrics.isParkedPastContent(bottomMinY: -0.4))
        #expect(!ChatScrollMetrics.isParkedPastContent(bottomMinY: ChatScrollMetrics.overscrollParkThreshold + 0.01))
    }

    @Test("isParkedPastContent is false while legitimately scrolled up, away from the bottom")
    func isParkedPastContentIsFalseWhenNotAtBottom() {
        #expect(!ChatScrollMetrics.isParkedPastContent(bottomMinY: 2_400))
    }

    @Test("isParkedPastContent is true once the sentinel has scrolled meaningfully above the viewport top")
    func isParkedPastContentIsTrueWhenScrolledPastTheEnd() {
        // This is the bug's exact signature: a collapsing streaming bubble shrinks the
        // transcript after a scrollTo already landed past its new, shorter end, leaving
        // the actual last pixel of content above the visible viewport entirely.
        #expect(ChatScrollMetrics.isParkedPastContent(bottomMinY: -40))
        #expect(ChatScrollMetrics.isParkedPastContent(bottomMinY: -600))
    }

    @Test(
        "Every parked reading also reads as at-bottom",
        arguments: [-4.01, -40, -600, -5_000, 0, 120, 600]
    )
    func parkedIsAlwaysASubsetOfAtBottom(bottomMinY: CGFloat) {
        // isAtBottom deliberately can't distinguish a genuine rest from a parked
        // scroll — both satisfy `bottomMinY <= viewportHeight + slop`. This pins that
        // relationship: isParkedPastContent must stay a strict subset of isAtBottom,
        // never the other way around, or the recovery watchdog could fire while the
        // jump-to-latest pill is simultaneously (and contradictorily) visible.
        let viewportHeight: CGFloat = 600
        if ChatScrollMetrics.isParkedPastContent(bottomMinY: bottomMinY) {
            #expect(ChatScrollMetrics.isAtBottom(bottomMinY: bottomMinY, viewportHeight: viewportHeight))
        }
    }
}

// MARK: - ChatScrollRecoveryWatchdog

@MainActor
@Suite("ChatScrollRecoveryWatchdog")
struct ChatScrollRecoveryWatchdogTests {
    private static let settleNanoseconds: UInt64 = 25_000_000
    private static let waitPastSettle: Duration = .milliseconds(80)

    @Test("Fires recovery when a parked reading persists past the settle delay, passing the value it fired on")
    func firesAfterSettleDelayWhenStillParked() async {
        let watchdog = ChatScrollRecoveryWatchdog(settleNanoseconds: Self.settleNanoseconds)
        var recoveredValue: CGFloat?

        watchdog.sentinelDidUpdate(bottomMinY: -200) { value in recoveredValue = value }

        try? await Task.sleep(for: Self.waitPastSettle)
        #expect(recoveredValue == -200)
    }

    @Test("Never fires for a healthy (non-parked) reading")
    func neverFiresForHealthyReading() async {
        let watchdog = ChatScrollRecoveryWatchdog(settleNanoseconds: Self.settleNanoseconds)
        var recoverCount = 0

        watchdog.sentinelDidUpdate(bottomMinY: 600) { _ in recoverCount += 1 }

        try? await Task.sleep(for: Self.waitPastSettle)
        #expect(recoverCount == 0)
    }

    @Test("A recovered reading before the delay elapses cancels the pending timer")
    func healthyReadingCancelsPendingTimer() async {
        // Models a bounce that springs back on its own: the sentinel reads parked for
        // a moment, then a fresh (healthy) reading arrives before the settle delay is
        // up. The watchdog must not fight a scroll that already fixed itself.
        let watchdog = ChatScrollRecoveryWatchdog(settleNanoseconds: Self.settleNanoseconds)
        var recoverCount = 0

        watchdog.sentinelDidUpdate(bottomMinY: -200) { _ in recoverCount += 1 }
        watchdog.sentinelDidUpdate(bottomMinY: 600) { _ in recoverCount += 1 }

        try? await Task.sleep(for: Self.waitPastSettle)
        #expect(recoverCount == 0)
    }

    @Test("Only the most recently armed timer can fire, passing the latest value, not the first")
    func onlyLatestArmedTimerFires() async {
        // Re-arming before the first timer's delay elapses must supersede it, not
        // stack a second independent recovery — and the value passed to onRecover
        // must reflect the latest reading, not whatever the first call captured.
        let watchdog = ChatScrollRecoveryWatchdog(settleNanoseconds: Self.settleNanoseconds)
        var recoverCount = 0
        var recoveredValue: CGFloat?

        watchdog.sentinelDidUpdate(bottomMinY: -200) { value in
            recoverCount += 1
            recoveredValue = value
        }
        watchdog.sentinelDidUpdate(bottomMinY: -300) { value in
            recoverCount += 1
            recoveredValue = value
        }

        try? await Task.sleep(for: Self.waitPastSettle)
        #expect(recoverCount == 1)
        #expect(recoveredValue == -300)
    }
}
