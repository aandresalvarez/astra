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
                    updatedAt: operation.updatedAt,
                    launchResourceKey: operation.launchResourceKey,
                    lastNotificationKey: operation.lastNotificationKey,
                    lastWakeKey: operation.lastWakeKey
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
            // A registration that already reached `.completed` AND whose
            // delivery was acknowledged must not import as a reactivatable
            // quarantined row: reactivation would schedule a fresh wake and
            // let admission move an already-completed task back to running.
            // But `.completed` alone does not prove processing finished — for
            // failure/cancellation/interruption/timeout observations the
            // monitor sets `.completed` BEFORE the reasoning wake delivers, so
            // an export taken in that window must import as reactivatable
            // (quarantined) or the task is stranded with no wake and no
            // controls. Delivered-ness is judged against the EXPORTED
            // observation (health as it was), since import quarantines health.
            let exportedObservation = TaskExternalOperationObservation(
                executionState: executionState,
                health: TaskExternalOperationObservationHealth(rawValue: config.observationHealth) ?? .unknown
            )
            let exportedWakeKey = TaskExternalOperationWakeKeyDerivation.wakeKey(for: exportedObservation)
            let wasCompleted =
                config.monitoringState == TaskExternalOperationMonitoringState.completed.rawValue
                    && (exportedWakeKey == nil || config.lastWakeKey == exportedWakeKey)
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
                // `config.generation` is untrusted (decoded verbatim from an
                // imported config that may come from a backup or another
                // machine); a syntactically valid `Int.max` would trap Swift's
                // checked `+ 1` and crash the import. `generation` is only ever
                // used as a local optimistic-concurrency counter compared for
                // equality within one process's lease lifecycle — never
                // serialized as an authoritative identifier — so clamping an
                // absurd value down changes no observable behavior. Bounded
                // well below Int.max (not just Int.max - 1) because this same
                // field is unclamped-incremented again on every subsequent
                // poll/cancel/reactivate cycle in TaskExternalOperationMonitor
                // Service, which would immediately re-trap otherwise.
                generation: min(max(0, config.generation), 1_000_000_000) + 1,
                createdAt: config.createdAt
            )
            operation.updatedAt = max(config.updatedAt, config.createdAt)
            // Preserve the LAUNCH-TIME execution-root key so a reactivated
            // registration excludes the root the job actually mounted, not the
            // workspace's current (user-mutable) path.
            if let launchKey = config.launchResourceKey,
               isSafeImportedFreeformValue(launchKey, maximumLength: 1_024) {
                operation.launchResourceKey = launchKey
            }
            // Delivery acknowledgements travel with the row so a later export
            // of this store keeps distinguishing delivered terminal failures
            // from pending ones.
            if let notificationKey = config.lastNotificationKey,
               isSafeImportedFreeformValue(notificationKey, maximumLength: 256) {
                operation.lastNotificationKey = notificationKey
            }
            if let wakeKey = config.lastWakeKey,
               isSafeImportedFreeformValue(wakeKey, maximumLength: 256) {
                operation.lastWakeKey = wakeKey
            }
            // Preserve the exported row's id when it is a valid, non-colliding
            // UUID: exported `externalOperation.review.required` task events
            // reference operations by this id, and minting a fresh one would
            // make `hasResolvedFailureReview` unable to match an already
            // approved historical failure — reopening a spurious review gate
            // on the next unrelated successful continuation.
            if let importedID = config.id.flatMap(UUID.init(uuidString:)) {
                let existing = (try? modelContext.fetch(FetchDescriptor<TaskExternalOperation>(
                    predicate: #Predicate<TaskExternalOperation> { $0.id == importedID }
                ))) ?? []
                if existing.isEmpty {
                    operation.id = importedID
                }
            }
            modelContext.insert(operation)
            insertedActiveRegistration = insertedActiveRegistration
                || config.monitoringState == TaskExternalOperationMonitoringState.active.rawValue
                || config.monitoringState == TaskExternalOperationMonitoringState.validating.rawValue
                // An exported `.completed` failure whose reasoning wake was
                // still undelivered imports as reactivatable — the task must
                // keep its waitingExternal state and controls.
                || (config.monitoringState == TaskExternalOperationMonitoringState.completed.rawValue
                        && !wasCompleted)
        }

        // An explicitly cancelled task stays cancelled: a user can cancel a
        // task while its external job is still monitored, so the export
        // legitimately carries `.cancelled` alongside a nonterminal operation.
        // Rewriting it to waitingExternal would let a later "Verify and
        // reactivate" wake pass the cancellation admission guard and resume
        // provider work the user explicitly cancelled.
        if insertedActiveRegistration, task.status != .cancelled {
            task.status = .waitingExternal
            task.completedAt = nil
            task.updatedAt = Date()
        }
    }

    /// Bounded, control-character-free validation for imported free-form
    /// values that are compared or displayed but never executed
    /// (launchResourceKey, delivery acknowledgement keys).
    private static func isSafeImportedFreeformValue(
        _ value: String,
        maximumLength: Int
    ) -> Bool {
        !value.isEmpty
            && value.count <= maximumLength
            && !value.unicodeScalars.contains(where: isControlScalar)
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
