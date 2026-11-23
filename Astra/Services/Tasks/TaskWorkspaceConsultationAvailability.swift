import Foundation
import ASTRAModels
import ASTRAPersistence

/// Whether a Consult turn can start, known before it is sent.
///
/// `RuntimeWorkspaceConsultationGate` is the authority and still checks every
/// launch. This is the same decision asked early, from the task's saved
/// settings, so the composer can say why Consult is unavailable instead of
/// accepting a message that is refused a moment later.
enum TaskWorkspaceConsultationAvailability: Equatable, Sendable {
    case available
    /// Sandboxing is Off, so nothing keeps the run from writing the folders
    /// Consult promises only to read; admission would make it a writer.
    case needsSandbox
    /// The task changes branches, runs tests, or runs template hooks, which
    /// ASTRA performs with write access around the run.
    case needsPlainWorkflow

    var isAvailable: Bool { self == .available }

    /// One line for the menu, under the two choices.
    var menuNote: String? {
        switch self {
        case .available: nil
        case .needsSandbox: "Consult needs the Execution Sandbox (Settings → Runtime)"
        case .needsPlainWorkflow: "Consult is off for branch changes, automatic tests and template hooks"
        }
    }

    /// The full explanation, for the control's tooltip and VoiceOver.
    var explanation: String? {
        switch self {
        case .available:
            nil
        case .needsSandbox:
            "Consult only reads workspace files, and the Execution Sandbox is what enforces that. It is Off, so Consult cannot start. Turn it on in Settings → Runtime, or use Work."
        case .needsPlainWorkflow:
            "Consult only reads workspace files. This task changes branches, runs automatic tests, or runs template hooks, which need write access. Turn those off, or use Work."
        }
    }

    /// `task` is nil for a new composer that has no saved draft yet; only the
    /// app-wide sandbox setting is known then.
    ///
    /// With sandboxing Off, admission turns a read-only folder claim into a
    /// write claim unless it only watches that folder, and it never only
    /// watches the code root every task claims. So Off always refuses Consult.
    @MainActor
    static func resolve(
        sandboxEnforcement: ExecutionSandboxEnforcement,
        task: AgentTask?
    ) -> Self {
        if let task, task.isLive, TaskExecutionResourceClaimResolver.requiresExclusiveWorkflowAccess(for: nil, task: task) {
            return .needsPlainWorkflow
        }
        return sandboxEnforcement == .off ? .needsSandbox : .available
    }

    /// The setting admission reads (`TaskQueue.sandboxEnforcementProvider`).
    static func storedSandboxEnforcement(defaults: UserDefaults = .standard) -> ExecutionSandboxEnforcement {
        ExecutionSandboxSettings.resolve(permissionPolicy: .restricted, defaults: defaults).storedEnforcement
    }

    /// A readable sentence for a turn request that ended with one of the
    /// gate's reasons; nil for every other reason. The read-only reason covers
    /// both causes (sandbox Off, or branch changes / tests / hooks), so its
    /// sentence names both remedies rather than guessing which one applied.
    static func terminalDetail(forReason reason: String?) -> String? {
        switch reason {
        case "consultation_requires_read_only_workspace":
            "Consult needs read-only workspace access: turn on the Execution Sandbox and turn off branch changes, automatic tests and template hooks, or use Work."
        case "consultation_plan_commands":
            "Consult cannot run a plan's commands. Use Work."
        default:
            nil
        }
    }
}
