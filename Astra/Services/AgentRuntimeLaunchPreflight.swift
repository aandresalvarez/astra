import Foundation
import SwiftData

@MainActor
enum AgentRuntimeLaunchPreflight {
    static func prepareTaskFolderForLaunch(
        _ task: AgentTask,
        modelContext: ModelContext,
        phase: String
    ) -> Bool {
        do {
            let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
            AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: [
                "event": "task_folder_prepared",
                "phase": phase,
                "folder_available": String(!folder.isEmpty)
            ], level: .debug)
            return true
        } catch {
            AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
                "reason": "task_folder_create_failed",
                "phase": phase,
                "error_type": String(describing: type(of: error))
            ], level: .error)
            task.status = .failed
            let now = Date()
            task.updatedAt = now
            task.completedAt = now
            task.markUnreadForCurrentStatus(at: now)
            modelContext.insert(TaskEvent(
                task: task,
                type: "error",
                payload: "ASTRA could not create this task's output folder before launching the agent: \(error.localizedDescription)"
            ))
            try? modelContext.save()
            return false
        }
    }

    static func preflightConnectorsBeforeLaunch(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String,
        contextText: String
    ) async -> Bool {
        guard preflightCapabilitiesBeforeLaunch(
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase
        ) else {
            return false
        }

        let fullContext = [
            task.goal,
            task.title,
            contextText
        ].joined(separator: "\n")
        let connectors = ConnectorPreflightService.connectorsRequiringPreflight(
            from: TaskCapabilityResolver(task: task).allConnectors,
            contextText: fullContext
        )
        let traceID = AuditTrace.make("connector-preflight")
        var preflightFields = CapabilityAudit.taskContextFields(source: "connector_preflight_candidates", task: task)
        preflightFields["trace_id"] = traceID
        preflightFields["phase"] = phase
        preflightFields["preflight_connector_count"] = String(connectors.count)
        AppLogger.audit(.capabilityChatContext, category: "Worker", taskID: task.id, fields: preflightFields, level: .debug, fieldMaxLength: 240)

        guard let issue = await ConnectorPreflightService.firstBlockingIssue(
            connectors: connectors,
            contextText: fullContext,
            workspaceID: task.workspace?.id,
            traceID: traceID
        ) else {
            if !connectors.isEmpty {
                AppLogger.audit(.connectorTested, category: "Worker", taskID: task.id, fields: [
                    "source": "task_preflight",
                    "trace_id": traceID,
                    "phase": phase,
                    "workspace_id": task.workspace?.id.uuidString ?? "none",
                    "result": "preflight_passed",
                    "connector_count": String(connectors.count),
                    "connector_names": CapabilityAudit.compactNames(connectors.map(\.name))
                ], level: .info, fieldMaxLength: 240)
            }
            return true
        }

        var fields = issue.auditFields
        fields["trace_id"] = traceID
        fields["phase"] = phase
        AppLogger.audit(.connectorTested, category: "Worker", taskID: task.id, fields: fields, level: .error)

        let message = """
        \(issue.connectorName) connector check failed before the agent ran:

        \(issue.message)

        Fix this connector in Manage Capabilities, then retry the task. ASTRA stopped here so the agent does not guess about Jira permissions from partial API results.
        """
        finishPreLaunchFailure(
            task: task,
            run: run,
            modelContext: modelContext,
            reason: "connector_preflight_failed",
            payload: message
        )
        return false
    }

    static func preflightCapabilitiesBeforeLaunch(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String
    ) -> Bool {
        let issues = CapabilityRuntimeIntegrityService.issues(for: task)
        var fields = CapabilityAudit.taskContextFields(source: "capability_runtime_integrity", task: task)
        fields["phase"] = phase
        fields["result"] = issues.isEmpty ? "passed" : "missing_resources"
        for (key, value) in CapabilityRuntimeIntegrityService.summaryFields(for: issues) {
            fields[key] = value
        }

        guard !issues.isEmpty else {
            AppLogger.audit(.capabilityRuntimeIntegrity, category: "Worker", taskID: task.id, fields: fields, level: .debug, fieldMaxLength: 240)
            return true
        }

        AppLogger.audit(.capabilityRuntimeIntegrity, category: "Worker", taskID: task.id, fields: fields, level: .error, fieldMaxLength: 240)
        finishPreLaunchFailure(
            task: task,
            run: run,
            modelContext: modelContext,
            reason: "capability_runtime_resources_missing",
            payload: CapabilityRuntimeIntegrityService.userMessage(for: issues)
        )
        return false
    }

    static func finishPreLaunchFailure(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        reason: String,
        payload: String
    ) {
        run.status = .failed
        run.stopReason = reason
        run.completedAt = Date()
        task.status = .failed
        task.updatedAt = Date()
        task.markUnreadForCurrentStatus(at: task.updatedAt)
        let event = TaskEvent(task: task, type: "error", payload: payload, run: run)
        modelContext.insert(event)
        AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
            "reason": reason
        ], level: .error)
        try? modelContext.save()
    }
}
