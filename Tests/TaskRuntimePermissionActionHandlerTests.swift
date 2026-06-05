import Testing
@testable import ASTRA

@Suite("Task runtime permission action handler")
struct TaskRuntimePermissionActionHandlerTests {
    @Test("similar approval requires reusable grants and an active task queue")
    func similarApprovalRequiresReusableGrantsAndActiveTaskQueue() {
        #expect(TaskRuntimePermissionActionHandler.approvalAction(
            canApproveSimilarForTask: true,
            hasTaskQueue: true
        ) == .approveSimilarForTask)

        #expect(TaskRuntimePermissionActionHandler.approvalAction(
            canApproveSimilarForTask: true,
            hasTaskQueue: false
        ) == .approveOnce)

        #expect(TaskRuntimePermissionActionHandler.approvalAction(
            canApproveSimilarForTask: false,
            hasTaskQueue: true
        ) == .approveOnce)
    }
}
