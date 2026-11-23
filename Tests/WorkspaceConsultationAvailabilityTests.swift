import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

/// A Consult turn refused before any run existed left the person with "Run
/// stopped" and no reason: the refusal was saved but nothing showed it. These
/// pin both halves of the fix: the composer says up front when Consult cannot
/// start, and a refusal that does happen is visible in the task.
@Suite("Workspace consultation availability")
@MainActor
struct WorkspaceConsultationAvailabilityTests {
    private func makeTask() -> AgentTask {
        let workspace = Workspace(name: "Synthetic", primaryPath: "/tmp/astra-consult-availability")
        let task = AgentTask(title: "Question", goal: "Explain files", workspace: workspace)
        TaskWorkspaceConsultationPolicy.apply(true, to: task)
        return task
    }

    @Test("Consult is available exactly when the launch gate would accept it",
          arguments: [ExecutionSandboxEnforcement.off, .bestEffort, .strict])
    func availabilityAgreesWithAdmission(enforcement: ExecutionSandboxEnforcement) {
        let task = makeTask()
        let availability = TaskWorkspaceConsultationAvailability.resolve(sandboxEnforcement: enforcement, task: task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1,
            resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task))
        let lease = TaskExecutionResourceAdmissionPolicy.lockClaims(for: request, task: task,
            runMode: "test", sandboxEnforcement: enforcement)
        let admittedReadOnly = TaskExecutionResourceAdmissionPolicy.workspaceAccess(from: lease) == .shared
        #expect(availability.isAvailable == admittedReadOnly)
        #expect(availability == (enforcement == .off ? .needsSandbox : .available))
        #expect(TaskWorkspaceConsultationAvailability.resolve(sandboxEnforcement: enforcement, task: nil) == availability)
    }

    @Test("The composer reads the stored sandbox mode, and an explicit Off is never defaulted away")
    func storedSandboxEnforcement() {
        let defaults = InMemoryDefaults()
        #expect(TaskWorkspaceConsultationAvailability.storedSandboxEnforcement(defaults: defaults) == .bestEffort)
        defaults.set("off", forKey: AppStorageKeys.sandboxEnforcement)
        #expect(TaskWorkspaceConsultationAvailability.storedSandboxEnforcement(defaults: defaults) == .off)
        defaults.set("strict", forKey: AppStorageKeys.sandboxEnforcement)
        #expect(TaskWorkspaceConsultationAvailability.storedSandboxEnforcement(defaults: defaults) == .strict)
    }

    @Test("Branch changes, automatic tests and template hooks rule Consult out whatever the sandbox")
    func intrinsicWritesRuleConsultOut() {
        let task = makeTask()
        task.isolationStrategy = .gitBranch
        #expect(TaskWorkspaceConsultationAvailability.resolve(sandboxEnforcement: .strict, task: task) == .needsPlainWorkflow)
        task.isolationStrategy = .sameDirectory
        task.validationStrategy = .runTests
        #expect(TaskWorkspaceConsultationAvailability.resolve(sandboxEnforcement: .off, task: task) == .needsPlainWorkflow)
        task.validationStrategy = .manual
        task.templateHooksJSON = "{\"hook\":true}"
        #expect(TaskWorkspaceConsultationAvailability.resolve(sandboxEnforcement: .bestEffort, task: task) == .needsPlainWorkflow)
        task.templateHooksJSON = "{}"
        #expect(TaskWorkspaceConsultationAvailability.resolve(sandboxEnforcement: .bestEffort, task: task) == .available)
    }

    @Test("The menu blocks choosing an unavailable Consult, and flags a saved one that cannot start")
    func menuPresentation() {
        let available = ComposerConsultationMenuPresentation(isConsult: false, availability: .available)
        #expect(!available.consultChoiceDisabled && available.menuNote == nil)
        #expect(available.help == ComposerConsultationMenuPresentation.defaultHelp)
        #expect(available.systemImage == "hammer" && available.accessibilityValue == "Work")

        let work = ComposerConsultationMenuPresentation(isConsult: false, availability: .needsSandbox)
        #expect(work.consultChoiceDisabled && !work.needsAttention)
        #expect(work.menuNote?.contains("Execution Sandbox") == true)
        #expect(work.help.contains("Settings → Runtime"))
        #expect(work.accessibilityValue == "Work. Consult is unavailable")

        // A task saved in Consult before the sandbox was turned off: the menu
        // still shows the selection, warns, and Work stays one click away.
        let stale = ComposerConsultationMenuPresentation(isConsult: true, availability: .needsSandbox)
        #expect(!stale.consultChoiceDisabled && stale.needsAttention)
        #expect(stale.systemImage == "exclamationmark.triangle")
        #expect(stale.help.hasSuffix("Messages sent in Consult will not start."))
        #expect(stale.accessibilityValue == "Consult, cannot start")
    }

    @Test("A refusal no run owns is a line of the conversation; a retry adds a count, not a line")
    func runlessErrorIsVisible() throws {
        let task = makeTask()
        let refusal = "Consult cannot start with writable workspace access. Enable sandbox enforcement, or switch to Work."
        let first = event(task, "error", refusal, at: 10)
        let retried = event(task, "error", refusal, at: 20)
        let run = TaskRun(task: task)
        let inRun = TaskEvent(task: task, type: "error", payload: "Agent exited with code 1.", run: run)
        inRun.timestamp = Date(timeIntervalSince1970: 30)

        let items = TaskThreadSnapshot(goal: task.goal, createdAt: Date(timeIntervalSince1970: 1),
            events: [first, retried, inRun], runs: []).conversationItems
        let failures = items.compactMap { item -> (UUID, String, Int)? in
            guard case let .systemError(id, text, _, count) = item else { return nil }
            return (id, text, count)
        }
        let only = try #require(failures.first)
        #expect(failures.count == 1)
        #expect(only.0 == first.id && only.1 == refusal && only.2 == 2)
        #expect(items.first.map { if case .userMessage = $0 { true } else { false } } == true)
        // It is for the person, not the provider's conversation context.
        #expect(items.compactMap(\.systemContextLine).isEmpty)
    }

    @Test("The message chip turns the gate's reason code into a sentence")
    func lifecycleChipExplainsGateReason() {
        let task = makeTask()
        let eventID = UUID()
        let request = TaskTurnRequest(task: task, messageEventID: eventID, sequence: 1, state: .failed,
            submittedAt: Date(timeIntervalSince1970: 1))
        request.terminalReason = "consultation_requires_read_only_workspace"
        let chip = TaskTurnMessageLifecyclePresentation.resolve(messageEventID: eventID, requests: [request.snapshot])
        #expect(chip?.title == "Couldn’t start")
        // The reason covers sandbox Off and workflow writes alike, so the
        // sentence must name both remedies, not only the sandbox.
        let detail = chip?.detail ?? ""
        #expect(detail.contains("Execution Sandbox") && detail.contains("branch changes") && detail.hasSuffix("or use Work."))

        request.terminalReason = "some_future_reason"
        #expect(TaskTurnMessageLifecyclePresentation.resolve(messageEventID: eventID,
            requests: [request.snapshot])?.detail == "some_future_reason")
    }

    private func event(_ task: AgentTask, _ type: String, _ payload: String, at seconds: TimeInterval) -> TaskEvent {
        let event = TaskEvent(task: task, type: type, payload: payload)
        event.timestamp = Date(timeIntervalSince1970: seconds)
        return event
    }
}
