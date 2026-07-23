import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels

@MainActor
final class DockerImageRecoveryCoordinator: ObservableObject {
    @Published var pendingPlan: DockerImageRecoveryPlan?
    @Published var isConfirmationPresented = false
    @Published var isBusy = false
    @Published var errorMessage: String?

    var canStartTaskRetry: Bool { !isBusy }

    private let recovery: any DockerImageRecovering
    private let eventRecorder: any DockerImageRecoveryEventRecording
    private var operationID: UUID?
    private var expectedRunID: UUID?
    private var isInvalidated = false

    init(
        recovery: any DockerImageRecovering = DockerImageRecoveryService(),
        eventRecorder: any DockerImageRecoveryEventRecording = DockerImageRecoveryEventRecorder()
    ) {
        self.recovery = recovery
        self.eventRecorder = eventRecorder
    }

    func prepare(image: String, workspace: Workspace?, taskID: UUID, run: TaskRun?) {
        guard !isBusy, let workspace else { return }
        isBusy = true
        errorMessage = nil
        expectedRunID = run?.id
        isInvalidated = false
        let operationID = UUID()
        self.operationID = operationID
        let recoveryWorkspace = DockerImageRecoveryWorkspace(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths,
            preferredSourcePath: ExecutionEnvironmentStore.decode(run?.executionEnvironmentSnapshotJSON).sourcePath
        )
        audit(taskID: taskID, result: "recovery_diagnosis_started", image: image)
        let recovery = self.recovery

        // Keep the task-scoped operation alive through navigation. The view
        // that initiated recovery may be replaced while Docker is running,
        // but the durable started event still needs a terminal outcome.
        Task { [self] in
            let result = await Task.detached(priority: .userInitiated) {
                await recovery.recoveryPlan(image: image, workspace: recoveryWorkspace)
            }.value
            guard self.operationID == operationID else { return }
            isBusy = false
            guard !isInvalidated else {
                audit(taskID: taskID, result: "recovery_plan_invalidated", image: image, level: .warning)
                finishOperation()
                return
            }
            switch result {
            case .success(let plan):
                pendingPlan = plan
                isConfirmationPresented = true
                audit(taskID: taskID, result: "recovery_plan_ready", plan: plan)
            case .failure(let error):
                errorMessage = error.localizedDescription
                audit(taskID: taskID, result: "recovery_plan_unavailable", image: image, detail: error.localizedDescription, level: .warning)
                finishOperation()
            }
        }
    }

    func perform(
        _ plan: DockerImageRecoveryPlan,
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard !isBusy, !isInvalidated, expectedRunID == run?.id else {
            errorMessage = "The failed run changed before Docker recovery could start. Diagnose the latest run again."
            return
        }
        isBusy = true
        isConfirmationPresented = false
        pendingPlan = nil
        guard eventRecorder.record(
            task: task, run: run, plan: plan, result: .started, detail: nil, modelContext: modelContext
        ) else {
            isBusy = false
            finishOperation()
            errorMessage = "ASTRA could not durably record authorization for this Docker repair, so no Docker command was run."
            return
        }
        let operationID = UUID()
        self.operationID = operationID
        let recovery = self.recovery

        // The shared coordinator remains the operation owner even if the
        // selected task view is replaced during a long Docker build.
        Task { [self] in
            let result = await Task.detached(priority: .userInitiated) {
                await recovery.performRecovery(plan)
            }.value
            guard self.operationID == operationID else { return }
            isBusy = false
            if isInvalidated {
                _ = eventRecorder.record(
                    task: task,
                    run: run,
                    plan: plan,
                    result: .failed,
                    detail: "Recovery invalidated because the task's latest run changed; ASTRA did not retry.",
                    modelContext: modelContext
                )
                finishOperation()
                return
            }
            switch result {
            case .success:
                guard eventRecorder.record(
                    task: task, run: run, plan: plan, result: .succeeded, detail: nil, modelContext: modelContext
                ) else {
                    finishOperation()
                    errorMessage = "Docker recovery verified the image, but ASTRA could not durably record success. The task was not retried."
                    return
                }
                finishOperation()
                onSuccess()
            case .failure(let error):
                let recorded = eventRecorder.record(
                    task: task,
                    run: run,
                    plan: plan,
                    result: .failed,
                    detail: error.localizedDescription,
                    modelContext: modelContext
                )
                finishOperation()
                errorMessage = recorded
                    ? error.localizedDescription
                    : "\(error.localizedDescription) ASTRA also could not durably record the recovery failure."
            }
        }
    }

    func invalidateIfRunChanged(to latestRunID: UUID?) {
        guard let expectedRunID, expectedRunID != latestRunID else { return }
        isInvalidated = true
        pendingPlan = nil
        isConfirmationPresented = false
    }

    func cancelPending() {
        guard !isBusy else { return }
        pendingPlan = nil
        isConfirmationPresented = false
        finishOperation()
    }

    private func finishOperation() {
        operationID = nil
        expectedRunID = nil
        isInvalidated = false
    }

    private func audit(
        taskID: UUID,
        result: String,
        image: String? = nil,
        plan: DockerImageRecoveryPlan? = nil,
        detail: String? = nil,
        level: LogLevel = .info
    ) {
        AppLogger.audit(.executionEnvironmentChanged, category: "ExecutionEnvironment", taskID: taskID, fields: [
            "result": result,
            "image": image ?? plan?.image ?? "unknown",
            "recovery_action": plan?.auditAction ?? "none",
            "detail": detail ?? "none"
        ], level: level)
    }
}

struct DockerImageRecoveryDialogModifier: ViewModifier {
    @ObservedObject var coordinator: DockerImageRecoveryCoordinator
    let onConfirm: (DockerImageRecoveryPlan) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                coordinator.pendingPlan?.title ?? "Repair Docker image?",
                isPresented: $coordinator.isConfirmationPresented,
                titleVisibility: .visible
            ) {
                if let plan = coordinator.pendingPlan {
                    Button(plan.action == .retryOnly ? "Retry task" : "Repair and retry") { onConfirm(plan) }
                }
                Button("Cancel", role: .cancel) { coordinator.cancelPending() }
            } message: {
                Text(coordinator.pendingPlan?.confirmation ?? "ASTRA will verify the image before retrying.")
            }
            .alert("Docker Image Recovery Failed", isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { if !$0 { coordinator.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { coordinator.errorMessage = nil }
            } message: {
                Text(coordinator.errorMessage ?? "ASTRA could not repair the Docker image.")
            }
    }
}

enum DockerImageRecoveryPresentation {
    static func image(
        stopReason: String?,
        launchBlockImage: String?,
        runID: UUID?,
        runs: [TaskRun]
    ) -> String? {
        guard stopReason.map(TaskRunStopReason.init(rawValue:)) == .dockerImageUnavailable else { return nil }
        if let launchBlockImage, !launchBlockImage.isEmpty { return launchBlockImage }
        guard let runID, let run = runs.first(where: { $0.id == runID }) else { return nil }
        return ExecutionEnvironmentStore.decode(run.executionEnvironmentSnapshotJSON).image
    }
}
