import Testing
import Foundation
@testable import ASTRA

/// `StatusPill.forStatus(_:)` is the single source of truth for the
/// chip language across the app. These tests pin down which statuses
/// produce a pill and the exact label text — if anyone shortens
/// "Agent done" to "Done" the Kanban Done column collides, so we lock
/// the strings here.
@Suite("StatusPill")
struct StatusPillTests {

    @Test("Quiet states produce no pill")
    func quietStatesAreNil() {
        for status: TaskStatus in [.draft, .queued, .running] {
            #expect(StatusPill.forStatus(status) == nil,
                    "\(status) should not surface a pill")
        }
    }

    @Test("Each non-quiet status produces a pill with stable label")
    func labelsArePinned() {
        let expected: [(TaskStatus, String)] = [
            (.completed,      "Agent done"),
            (.failed,         "Failed"),
            (.cancelled,      "Cancelled"),
            (.pendingUser,    "Needs answer"),
            (.budgetExceeded, "Budget")
        ]
        for (status, label) in expected {
            let pill = StatusPill.forStatus(status)
            #expect(pill?.label == label, "\(status) label drifted")
        }
    }

    @Test("Each pill carries help text suitable for the AX hint slot")
    func helpTextPresent() {
        for status: TaskStatus in [.completed, .failed, .cancelled, .pendingUser, .budgetExceeded] {
            let pill = StatusPill.forStatus(status)
            #expect(pill?.help != nil, "\(status) missing help")
            #expect((pill?.help?.count ?? 0) > 20,
                    "\(status) help is too short to be useful")
        }
    }

    @Test("Compact size factory propagates through to the rendered pill")
    func sizePropagates() {
        let regular = StatusPill.forStatus(.completed, size: .regular)
        let compact = StatusPill.forStatus(.completed, size: .compact)
        #expect(regular?.size == .regular)
        #expect(compact?.size == .compact)
    }
}
