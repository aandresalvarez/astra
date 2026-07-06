import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

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

    @Test("credential requests produce reusable ASTRA-only grants")
    func credentialRequestsProduceReusableAstraOnlyGrants() {
        let label = "connector:11111111-1111-1111-1111-111111111111:JIRA_API_TOKEN"
        let grants = PermissionBroker.approvalGrants(for: .credential(label: label))

        #expect(grants == [.credential(label: label)])
        #expect(PermissionBroker.taskScopedApprovalGrants(for: grants) == grants)
        #expect(PermissionBroker.providerGrantStrings(for: grants, runtime: .claudeCode).isEmpty)
        #expect(PermissionBroker.providerRuntimeGrantStrings(for: grants, runtime: .claudeCode).isEmpty)
    }

    @Test("one-run credential grants expose labels without becoming task scoped")
    func oneRunCredentialGrantsStayTransient() {
        let task = AgentTask(title: "Credential", goal: "Use Jira")
        let label = "connector:11111111-1111-1111-1111-111111111111:JIRA_API_TOKEN"
        let grants = PermissionBroker.approvalGrants(for: .credential(label: label))

        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: task).isEmpty)
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(
            for: task,
            additionalGrants: grants
        ) == [label])
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: task).isEmpty)
    }
}
