import Testing
import Foundation
import ASTRAModels
@testable import ASTRA

/// `StatusPill.forStatus(_:)` pins run-outcome language so it does not collide
/// with task-closure vocabulary such as `Closed`.
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
            (.completed,      "Run finished"),
            (.failed,         "Run failed"),
            (.cancelled,      "Cancelled"),
            (.pendingUser,    "Needs input"),
            (.budgetExceeded, "Budget hit")
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
