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

    private let recovery: any DockerImageRecovering

    init(recovery: any DockerImageRecovering = DockerImageRecoveryService()) {
        self.recovery = recovery
    }

    func prepare(image: String, workspace: Workspace?, taskID: UUID) {
        guard !isBusy, let workspace else { return }
        isBusy = true
        errorMessage = nil
        let recoveryWorkspace = DockerImageRecoveryWorkspace(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
        audit(taskID: taskID, result: "recovery_diagnosis_started", image: image)

        Task { @MainActor in
            let result = await recovery.recoveryPlan(image: image, workspace: recoveryWorkspace)
            isBusy = false
            switch result {
            case .success(let plan):
                pendingPlan = plan
                isConfirmationPresented = true
                audit(taskID: taskID, result: "recovery_plan_ready", plan: plan)
            case .failure(let error):
                errorMessage = error.localizedDescription
                audit(taskID: taskID, result: "recovery_plan_unavailable", image: image, detail: error.localizedDescription, level: .warning)
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
        guard !isBusy else { return }
        isBusy = true
        isConfirmationPresented = false
        pendingPlan = nil
        DockerImageRecoveryEventRecorder.record(
            task: task, run: run, plan: plan, result: .started, detail: nil, modelContext: modelContext
        )

        Task { @MainActor in
            let result = await recovery.performRecovery(plan)
            isBusy = false
            switch result {
            case .success:
                DockerImageRecoveryEventRecorder.record(
                    task: task, run: run, plan: plan, result: .succeeded, detail: nil, modelContext: modelContext
                )
                onSuccess()
            case .failure(let error):
                DockerImageRecoveryEventRecorder.record(
                    task: task,
                    run: run,
                    plan: plan,
                    result: .failed,
                    detail: error.localizedDescription,
                    modelContext: modelContext
                )
                errorMessage = error.localizedDescription
            }
        }
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
                Button("Cancel", role: .cancel) { coordinator.pendingPlan = nil }
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
