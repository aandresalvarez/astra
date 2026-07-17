import Foundation
import Testing
@testable import ASTRA

@Suite("Task external operation presentation")
struct TaskExternalOperationPresentationTests {
    @Test("system notification contains only bounded derived state")
    func notificationContentIsBoundedAndSecretFree() {
        let operationID = UUID()
        let content = TaskExternalOperationSystemNotificationContent.make(.init(
            operationID: operationID,
            taskID: UUID(),
            observation: .init(executionState: .processCompleted, health: .healthy)
        ))

        #expect(content.title == "ASTRA external operation")
        #expect(content.body == "Awaiting validation · Reachable")
        #expect(content.identifier.contains(operationID.uuidString.lowercased()))
        #expect(!content.body.contains("command"))
        #expect(!content.body.contains("secret"))
    }

    @Test("ownership rejection has an actionable control message")
    func ownershipRejectionMessage() {
        #expect(TaskExternalOperationPresentation.resultMessage(.ownershipRejected) ==
            "Trusted backend ownership could not be verified")
    }
}
