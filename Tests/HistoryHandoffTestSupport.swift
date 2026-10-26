import Foundation
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// Records the parameters `AgentRuntimeWorker` hands to the injected process
/// runner and returns a canned success — no real process ever spawns. Proves
/// the `AgentRuntimeProcessRunning` seam is real: `AgentRuntimeWorker` depends
/// on the protocol, not the concrete `AgentRuntimeProcessRunner`.
final class FakeAgentProcessRunner: AgentRuntimeProcessRunning {
    private(set) var receivedTaskIDs: [UUID] = []
    private(set) var receivedWorkspacePaths: [String] = []
    private(set) var receivedPrompts: [String] = []
    private(set) var receivedNativeSessions: [String?] = []
    var streamLines: [String] = []
    var onLaunch: ((AgentTask, UUID?) -> Void)?
    var cancelCallCount = 0
    var hostControlBrokerAvailable = true
    var result = AgentProcessResult(exitCode: 0)

    @MainActor private var owner: RuntimeExecutionOwner?
    @MainActor func configureExecutionOwner(_ owner: RuntimeExecutionOwner?) { self.owner = owner }

    func cancel() {
        cancelCallCount += 1
    }

    func isHostControlBrokerAvailable() -> Bool {
        hostControlBrokerAvailable
    }

    @MainActor
    func runRuntimeProcess(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        executablePath: String,
        homeDirectory: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy,
        permissionManifest: RunPermissionManifest?,
        budgetEnforcementMode: BudgetEnforcementMode,
        timeoutSeconds: TimeInterval,
        phase: RunPhase,
        contextText: String,
        nativeContinuationSessionID: String?,
        runID: UUID?,
        launchResourcePlan: TaskLaunchResourcePlan?,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot?,
        runtimeRequirements: TaskRuntimeRequirementSet?,
        liveApprovalsEnabled: Bool,
        noSemanticProgressTimeoutSeconds: TimeInterval?,
        maxRunSeconds: TimeInterval?,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)?,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        receivedTaskIDs.append(task.id)
        receivedWorkspacePaths.append(workspacePath)
        receivedPrompts.append(prompt)
        receivedNativeSessions.append(nativeContinuationSessionID)
        onLaunch?(task, runID)
        for line in streamLines {
            onLine(line, true)
            for event in adapter.parseProcessEvents(line: line, parsesJSONLines: true) {
                if case .systemInit(_, let sessionID) = event { owner?.session(sessionID) }
            }
        }
        return result
    }
}
