import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Task decision dock context builder")
struct TaskDecisionDockContextBuilderTests {
    @Test("runtime permission state keeps latest request open until a later approval")
    func runtimePermissionStateKeepsLatestRequestOpenUntilLaterApproval() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let closed = TaskRuntimePermissionState.build(events: [
            event("permission.approval.requested", payload: "Runtime grant: Bash(gh search prs *)", at: start),
            event("task.approved", payload: "approved", at: start.addingTimeInterval(1))
        ])

        #expect(!closed.hasOpenApprovalRequest)
        #expect(closed.latestRequestPayload == "Runtime grant: Bash(gh search prs *)")
        #expect(closed.canApproveSimilarForTask == false)

        let reopened = TaskRuntimePermissionState.build(events: [
            event("task.approved", payload: "approved", at: start),
            event("permission.approval.requested", payload: "Runtime grant: Bash(gh search prs *)", at: start.addingTimeInterval(1))
        ])

        #expect(reopened.hasOpenApprovalRequest)
        #expect(reopened.decision?.title.isEmpty == false)
        #expect(reopened.taskScopedGrants == [.shellCommand(executable: "gh", pattern: "search prs *")])
        #expect(reopened.canApproveSimilarForTask)
    }

    @Test("runtime permission state reads typed open requests without audit events")
    func runtimePermissionStateReadsTypedOpenRequestsWithoutAuditEvents() {
        let workspace = Workspace(name: "Typed Approval", primaryPath: "/tmp/typed-approval")
        let task = AgentTask(title: "Typed Approval", goal: "Review pull requests", workspace: workspace)
        let payload = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .shell(command: "gh search prs author:@me --limit 10", toolName: "Bash"),
            reason: "The shell command requires user approval by the effective ASTRA policy.",
            grants: [.shellCommand(executable: "gh", pattern: "search prs *")],
            requestID: "typed-request-1"
        )

        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(
            payload: payload,
            task: task,
            at: Date(timeIntervalSince1970: 2_000)
        )

        let state = TaskRuntimePermissionState.build(task: task)
        #expect(state.hasOpenApprovalRequest)
        #expect(state.latestRequestPayload == payload)
        #expect(state.taskScopedGrants == [.shellCommand(executable: "gh", pattern: "search prs *")])
        #expect(TaskRuntimePermissionOpenRequestStore.latestRequestedToolName(for: task) == "Bash")

        TaskRuntimePermissionOpenRequestStore.resolveOpenRequest(requestID: "typed-request-1", task: task)

        #expect(!TaskRuntimePermissionState.build(task: task).hasOpenApprovalRequest)
        #expect(TaskRuntimePermissionOpenRequestStore.latestRequestPayload(for: task) == nil)
        #expect(task.runtimePermissionOpenRequestsJSON == "[]")
    }

    @Test("sandbox permission tool names are normalized with a local fallback")
    func sandboxPermissionToolNamesAreNormalizedWithLocalFallback() {
        let workspace = Workspace(name: "Sandbox Approval", primaryPath: "/tmp/sandbox-approval")
        let namedTask = AgentTask(title: "Named Tool", goal: "Read a protected path", workspace: workspace)
        let unnamedTask = AgentTask(title: "Unnamed Tool", goal: "Read a protected path", workspace: workspace)

        let namedPayload = PermissionBroker.approvalPayloadString(
            providerID: .codexCLI,
            request: .sandboxPath(path: "/tmp/input", access: "read", toolName: "  Read  "),
            reason: "The enabled sandbox denied this path.",
            grants: [.sandboxPath(path: "/tmp/input", access: "read")],
            requestID: "named-sandbox-request"
        )
        let unnamedPayload = PermissionBroker.approvalPayloadString(
            providerID: .codexCLI,
            request: .sandboxPath(path: "/tmp/input", access: "read", toolName: "   "),
            reason: "The enabled sandbox denied this path.",
            grants: [.sandboxPath(path: "/tmp/input", access: "read")],
            requestID: "unnamed-sandbox-request"
        )

        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: namedPayload, task: namedTask)
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: unnamedPayload, task: unnamedTask)

        #expect(TaskRuntimePermissionOpenRequestStore.latestRequestedToolName(for: namedTask) == "Read")
        #expect(TaskRuntimePermissionOpenRequestStore.latestRequestedToolName(for: unnamedTask) == "Local sandbox")
    }

    @Test("explicit empty typed permission state does not resurrect legacy audit requests")
    func explicitEmptyTypedPermissionStateDoesNotResurrectLegacyAuditRequests() {
        let workspace = Workspace(name: "Typed State", primaryPath: "/tmp/typed-state")
        let task = AgentTask(title: "Typed State", goal: "Keep closed requests closed", workspace: workspace)
        let payload = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .credential(label: "connector:11111111-1111-1111-1111-111111111111:API_TOKEN"),
            reason: "Credential access requires approval.",
            grants: [.credential(label: "connector:11111111-1111-1111-1111-111111111111:API_TOKEN")]
        )
        let legacyRequest = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.permissionApprovalRequested,
            payload: payload
        )
        task.events = [legacyRequest]
        task.runtimePermissionOpenRequestsJSON = "[]"

        let closedState = TaskRuntimePermissionState.build(task: task)
        #expect(!closedState.hasOpenApprovalRequest)
        #expect(closedState.latestRequestPayload == nil)
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task))
        #expect(TaskRuntimePermissionOpenRequestStore.latestRequestPayload(for: task) == nil)
        #expect(TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: task).isEmpty)

        task.runtimePermissionOpenRequestsJSON = nil

        #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task))
        #expect(TaskRuntimePermissionOpenRequestStore.latestRequestPayload(for: task) == payload)
    }

    @Test("malformed typed permission state fails closed instead of replaying audit history")
    func malformedTypedPermissionStateFailsClosedInsteadOfReplayingAuditHistory() {
        let workspace = Workspace(name: "Corrupt State", primaryPath: "/tmp/corrupt-state")
        let task = AgentTask(title: "Corrupt State", goal: "Fail closed", workspace: workspace)
        let payload = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .shell(command: "gh pr list", toolName: "Bash"),
            reason: "Shell access requires approval.",
            grants: [.shellCommand(executable: "gh", pattern: "pr list *")]
        )
        task.events = [TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.permissionApprovalRequested,
            payload: payload
        )]
        task.runtimePermissionOpenRequestsJSON = "{not-valid-json"

        let state = TaskRuntimePermissionState.build(task: task)

        #expect(!state.hasOpenApprovalRequest)
        #expect(state.latestRequestPayload == nil)
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task))
        #expect(TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: task).isEmpty)
        #expect(TaskRuntimePermissionOpenRequestStore.closeRequestsAuthorizedByAutonomousPolicy(for: task) == 0)
        #expect(task.runtimePermissionOpenRequestsJSON == "[]")
    }

    @Test("Auto closes provider requests but preserves sandbox path approvals")
    func autoClosesProviderRequestsButPreservesSandboxPathApprovals() {
        let workspace = Workspace(name: "Auto State", primaryPath: "/tmp/auto-state")
        let task = AgentTask(title: "Auto State", goal: "Reconcile requests", workspace: workspace)
        let credentialPayload = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .connectorCredentials(
                connectorID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                displayName: "Jira connector credential (1 configured credential)",
                labels: ["connector:22222222-2222-2222-2222-222222222222:JIRA_API_TOKEN"]
            ),
            reason: "Credential access requires approval.",
            grants: [.credential(label: "connector:22222222-2222-2222-2222-222222222222:JIRA_API_TOKEN")],
            requestID: "credential-request"
        )
        let sandboxPayload = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .sandboxPath(path: "/tmp/input", access: "read", toolName: "Bash"),
            reason: "The enabled sandbox denied this path.",
            grants: [.sandboxPath(path: "/tmp/input", access: "read")],
            requestID: "sandbox-request"
        )
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: credentialPayload, task: task)
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: sandboxPayload, task: task)

        let closed = TaskRuntimePermissionOpenRequestStore.closeRequestsAuthorizedByAutonomousPolicy(for: task)

        #expect(closed == 1)
        #expect(TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: task) == [sandboxPayload])
        #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task))
    }

    @Test("artifact paths are trimmed deduplicated and preserve first occurrence order")
    func artifactPathsAreTrimmedDeduplicatedAndPreserveFirstOccurrenceOrder() {
        let paths = TaskDecisionDockContextBuilder.artifactPaths(
            generatedFilePaths: [" /tmp/report.md ", "/tmp/index.html", ""],
            storedArtifactPaths: ["/tmp/report.md", "  /tmp/notes.md  ", "/tmp/index.html"]
        )

        #expect(paths == ["/tmp/report.md", "/tmp/index.html", "/tmp/notes.md"])
    }

    @Test("context builder owns plan labels and visible thread affordances")
    func contextBuilderOwnsPlanLabelsAndVisibleThreadAffordances() {
        let plan = TaskPlanPayload(
            title: "Architecture debt",
            goal: "Extract TaskMainView surfaces",
            steps: [
                TaskPlanPayloadStep(id: "done", title: "Already done", status: .done),
                TaskPlanPayloadStep(id: "next", title: "Extract decision dock")
            ]
        )

        let context = TaskDecisionDockContextBuilder.context(input(
            status: .completed,
            executableApprovedPlan: plan,
            isPlanCanvasVisible: true,
            artifactPaths: ["/tmp/index.html"]
        ))

        #expect(context.hasExecutableApprovedPlan)
        #expect(context.planActionTitle == "Approve next step")
        #expect(context.planActionDetail == "Next: Extract decision dock")
        #expect(context.planModeLabel == "Ask mode runs one approved step, then pauses again.")
        #expect(context.visibleThreadAffordances == Set<TaskThreadAffordance>([
            .runDetails,
            .artifactOpen,
            .planDetails
        ]))
    }

    @Test("extra detail builder preserves runtime pending approval and routine states")
    func extraDetailBuilderPreservesRuntimePendingApprovalAndRoutineStates() {
        let details = TaskDecisionDockContextBuilder.extraDetails(TaskDecisionDockContextBuilder.ExtraDetailsInput(
            status: .running,
            runtimeHealth: runtimeHealth(
                message: "Possibly stalled",
                detail: "No output for 5 minutes.",
                isAttention: true
            ),
            shouldShowPendingApprovalStatus: true,
            hasRuntimePermissionRequest: false,
            pendingApprovalStatusDetail: "Waiting for a reviewer.",
            isCreatingScheduleForCurrentTask: true,
            isGeneratingRecap: true,
            recapStatusMessage: "Could not summarize.",
            currentScheduleStatusMessage: "Routine saved.",
            isScheduleStatusError: false
        ))

        #expect(details.map(\.id) == [
            "runtime-health",
            "pending-approval",
            "routine-creating",
            "recap-generating",
            "recap-message",
            "routine-status"
        ])
        #expect(details.first?.tone == .attention)
        #expect(details.last?.tone == .verified)
    }

    private func input(
        status: TaskStatus,
        executableApprovedPlan: TaskPlanPayload? = nil,
        isPlanCanvasVisible: Bool = false,
        artifactPaths: [String] = []
    ) -> TaskDecisionDockContextBuilder.Input {
        TaskDecisionDockContextBuilder.Input(
            status: status,
            isClosed: false,
            review: TaskPresentationState.reviewPresentation(status: status, isClosed: false),
            mission: nil,
            verification: nil,
            pendingReviewState: .none,
            runtimePermission: .empty,
            executableApprovedPlan: executableApprovedPlan,
            skipPermissions: false,
            canOpenPlan: true,
            isPlanCanvasVisible: isPlanCanvasVisible,
            canRunApprovedPlan: true,
            latestRunHasNoUsableResult: false,
            completedTaskNeedsArtifactAttention: false,
            canCancel: true,
            canRun: true,
            canApprove: true,
            canRetry: true,
            canResume: false,
            canToggleDone: true,
            hasProviderSession: false,
            failureReason: nil,
            artifactPaths: artifactPaths,
            extraDetails: []
        )
    }

    private func event(_ type: String, payload: String, at timestamp: Date) -> TaskRuntimePermissionState.Event {
        TaskRuntimePermissionState.Event(type: type, payload: payload, timestamp: timestamp)
    }

    private func runtimeHealth(message: String, detail: String?, isAttention: Bool) -> TaskRuntimeHealth {
        TaskRuntimeHealth(
            state: isAttention ? .possiblyStalled : .active,
            message: message,
            detail: detail,
            lastActivityAt: nil,
            lastRuntimeProgressAt: nil,
            lastConversationAt: nil,
            lastWarningAt: nil,
            lastWarningTool: nil,
            latestToolName: nil,
            latestRunID: nil,
            eventCount: 0,
            outputCharacterCount: 0
        )
    }
}
