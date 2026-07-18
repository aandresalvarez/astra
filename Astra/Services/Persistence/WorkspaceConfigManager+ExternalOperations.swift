import Foundation
import SwiftData
import ASTRAModels

extension WorkspaceConfigManager {
    static func externalOperationConfigsForExport(
        workspace: Workspace
    ) -> [UUID: [ExternalOperationConfig]] {
        guard let modelContext = workspace.modelContext else { return [:] }
        let taskIDs = Set(workspace.tasks.map(\.id))
        let operations = ((try? modelContext.fetch(FetchDescriptor<TaskExternalOperation>())) ?? [])
            .filter { taskIDs.contains($0.taskID) }
        return Dictionary(grouping: operations, by: \.taskID).mapValues { values in
            values.sorted { $0.createdAt < $1.createdAt }.map { operation in
                ExternalOperationConfig(
                    id: operation.id.uuidString,
                    externalIdentity: operation.externalIdentity,
                    originatingRunID: operation.originatingRunID.uuidString,
                    backendKind: operation.backendKindRaw,
                    backendJobID: operation.backendJobID,
                    originatingContextRevision: operation.originatingContextRevision,
                    executionState: operation.executionState.rawValue,
                    observationHealth: operation.observationHealth.rawValue,
                    monitoringState: operation.monitoringState.rawValue,
                    nextCheckAt: operation.nextCheckAt,
                    generation: operation.generation,
                    createdAt: operation.createdAt,
                    updatedAt: operation.updatedAt
                )
            }
        }
    }

    /// Imported registrations are descriptive history, never authority to
    /// contact an executor. This policy is unconditional, including same-path
    /// recovery imports that may preserve other trusted workspace settings.
    @MainActor
    static func importQuarantinedExternalOperations(
        _ configs: [ExternalOperationConfig],
        task: AgentTask,
        importedRuns: [TaskRun],
        modelContext: ModelContext
    ) {
        let runIDs = Set(importedRuns.map(\.id))
        var insertedActiveRegistration = false
        for config in configs {
            guard config.backendKind == "docker_workspace_job",
                  isSafeExternalOperationIdentifier(config.backendJobID, maximumLength: 80),
                  isSafeExternalIdentity(config.externalIdentity),
                  let originatingRunID = UUID(uuidString: config.originatingRunID),
                  runIDs.contains(originatingRunID),
                  config.originatingContextRevision.map({
                      $0.count <= 256 && !$0.unicodeScalars.contains(where: isControlScalar)
                  }) ?? true,
                  let executionState = TaskExternalOperationExecutionState(rawValue: config.executionState) else {
                continue
            }

            let identity = uniqueQuarantinedExternalIdentity(
                preferred: config.externalIdentity,
                taskID: task.id,
                modelContext: modelContext
            )
            // A registration that already reached `.completed` (its validation
            // finished) must not import as a reactivatable quarantined row:
            // reactivation reconstructs a quarantined `processCompleted` op as
            // `.validating`, which would schedule a fresh wake and let admission
            // move an already-completed task back to running. Import it as the
            // inert terminal `.completed` state instead — it is never polled,
            // contacted, or reactivatable, so the no-contact boundary still holds.
            let wasCompleted =
                config.monitoringState == TaskExternalOperationMonitoringState.completed.rawValue
            let operation = TaskExternalOperation(
                taskID: task.id,
                externalIdentity: identity,
                originatingRunID: originatingRunID,
                backendKindRaw: config.backendKind,
                backendJobID: config.backendJobID.lowercased(),
                originatingContextRevision: config.originatingContextRevision,
                executionState: executionState,
                observationHealth: .quarantined,
                monitoringState: wasCompleted ? .completed : .quarantined,
                nextCheckAt: nil,
                generation: max(0, config.generation) + 1,
                createdAt: config.createdAt
            )
            operation.updatedAt = max(config.updatedAt, config.createdAt)
            modelContext.insert(operation)
            insertedActiveRegistration = insertedActiveRegistration
                || config.monitoringState == TaskExternalOperationMonitoringState.active.rawValue
                || config.monitoringState == TaskExternalOperationMonitoringState.validating.rawValue
        }

        if insertedActiveRegistration {
            task.status = .waitingExternal
            task.completedAt = nil
            task.updatedAt = Date()
        }
    }

    private static func isSafeExternalOperationIdentifier(
        _ value: String,
        maximumLength: Int
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (65...90).contains(value)
                || (97...122).contains(value)
                || (48...57).contains(value)
                || value == 45
                || value == 95
        }
    }

    private static func isSafeExternalIdentity(_ value: String) -> Bool {
        value.hasPrefix("docker_workspace_job:")
            && value.count <= 256
            && !value.unicodeScalars.contains(where: isControlScalar)
            && !value.contains("..")
            && !value.contains("/")
            && !value.contains("\\")
    }

    private static func isControlScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 32 || scalar.value == 127
    }

    @MainActor
    private static func uniqueQuarantinedExternalIdentity(
        preferred: String,
        taskID: UUID,
        modelContext: ModelContext
    ) -> String {
        let identities = Set(((try? modelContext.fetch(FetchDescriptor<TaskExternalOperation>())) ?? [])
            .map(\.externalIdentity))
        guard identities.contains(preferred) else { return preferred }
        return "quarantined:\(taskID.uuidString.lowercased()):\(UUID().uuidString.lowercased())"
    }
}
