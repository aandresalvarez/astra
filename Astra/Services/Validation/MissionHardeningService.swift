import Foundation
import SwiftData
import ASTRAModels

@MainActor
enum MissionHardeningService {
    @discardableResult
    static func recordCheckpoint(
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext
    ) -> TaskMissionCheckpointPayload {
        TaskContextStateManager.refresh(task: task)
        let state = currentState(for: task)
        let checkpoint = TaskMissionCheckpointPayload(
            checkpointID: UUID(),
            runID: run?.id,
            taskStatus: task.status.rawValue,
            runStatus: run?.status.rawValue,
            elapsedSeconds: elapsedSeconds(task: task, run: run),
            tokensUsed: task.tokensUsed,
            costUSD: task.costUSD,
            contractStatus: state?.validationContract?.status,
            openBlockers: Array((state?.blockers ?? []).prefix(8)),
            eventCount: task.events.count,
            sourcePointers: Array((state?.sourcePointers ?? []).prefix(20))
        )
        modelContext.insert(TaskEvent(
            task: task,
            type: TaskMissionEventTypes.checkpointCreated,
            payload: encode(checkpoint),
            run: run
        ))
        let auditFields: [String: String] = [
            "checkpoint_id": checkpoint.checkpointID.uuidString,
            "run_id": run?.id.uuidString ?? "none",
            "elapsed_seconds": String(checkpoint.elapsedSeconds),
            "tokens_used": String(checkpoint.tokensUsed),
            "cost_usd": String(checkpoint.costUSD),
            "contract_status": checkpoint.contractStatus ?? "none",
            "open_blockers": String(checkpoint.openBlockers.count)
        ]
        AppLogger.audit(.missionCheckpointCreated, category: "Mission", taskID: task.id, fields: auditFields)
        return checkpoint
    }

    @discardableResult
    static func exportAuditBundle(
        task: AgentTask,
        modelContext: ModelContext
    ) throws -> TaskMissionAuditBundlePayload {
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let directory = (folder as NSString).appendingPathComponent("mission-audit")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bundlePath = (directory as NSString).appendingPathComponent("mission-audit-bundle.json")
        TaskContextStateManager.refresh(task: task)
        let state = currentState(for: task)
        let plan = TaskPlanService.reconstruct(for: task).plan
        let eventRecords = task.events
            .sorted { $0.timestamp < $1.timestamp }
            .map { event in
                [
                    "id": event.id.uuidString,
                    "type": event.type,
                    "category": event.category,
                    "timestamp": ISO8601DateFormatter().string(from: event.timestamp),
                    "runID": (event.run?.id.uuidString as Any?) ?? NSNull(),
                    "payload": event.payload
                ] as [String: Any]
            }
        let sourcePointers = (state?.sourcePointers ?? []).map { pointer in
            [
                "kind": pointer.kind,
                "id": (pointer.id as Any?) ?? NSNull(),
                "path": (pointer.path as Any?) ?? NSNull(),
                "summary": pointer.summary
            ] as [String: Any]
        }
        let validationEvidence = state.map { validationEvidencePaths(from: $0) } ?? []
        let bundle: [String: Any] = [
            "version": 1,
            "task": [
                "id": task.id.uuidString,
                "title": task.title,
                "goal": task.goal,
                "status": task.status.rawValue,
                "tokensUsed": task.tokensUsed,
                "costUSD": task.costUSD
            ],
            "plan": (plan.map { TaskPlanService.encodePlanPayload($0) } as Any?) ?? NSNull(),
            "contextCapsule": TaskContextStateManager.promptContext(for: task) ?? "",
            "sourcePointers": sourcePointers,
            "validationEvidence": validationEvidence,
            "events": eventRecords
        ]
        guard JSONSerialization.isValidJSONObject(bundle),
              let data = try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys]) else {
            throw CocoaError(.coderInvalidValue)
        }
        try data.write(to: URL(fileURLWithPath: bundlePath), options: [.atomic])

        let payload = TaskMissionAuditBundlePayload(
            bundleID: UUID(),
            path: bundlePath,
            taskID: task.id,
            eventCount: task.events.count,
            checkpointCount: task.events.filter { $0.type == TaskMissionEventTypes.checkpointCreated }.count,
            validationEvidenceCount: validationEvidence.count,
            createdAt: Date()
        )
        modelContext.insert(TaskEvent(
            task: task,
            type: TaskMissionEventTypes.auditBundleCreated,
            payload: encode(payload)
        ))
        AppLogger.audit(.missionAuditBundleCreated, category: "Mission", taskID: task.id, fields: [
            "bundle_id": payload.bundleID.uuidString,
            "path": bundlePath,
            "event_count": String(payload.eventCount),
            "checkpoint_count": String(payload.checkpointCount),
            "validation_evidence_count": String(payload.validationEvidenceCount)
        ])
        return payload
    }

    static func decodeCheckpoint(_ payload: String) -> TaskMissionCheckpointPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskMissionCheckpointPayload.self, from: data)
    }

    static func decodeAuditBundle(_ payload: String) -> TaskMissionAuditBundlePayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskMissionAuditBundlePayload.self, from: data)
    }

    private static func elapsedSeconds(task: AgentTask, run: TaskRun?) -> Int {
        if let run {
            return max(0, Int((run.completedAt ?? Date()).timeIntervalSince(run.startedAt)))
        }
        return max(0, Int(Date().timeIntervalSince(task.createdAt)))
    }

    private static func currentState(for task: AgentTask) -> TaskContextState? {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        return !folder.isEmpty ? TaskContextStateManager.load(taskFolder: folder) : nil
    }

    private static func validationEvidencePaths(from state: TaskContextState) -> [String] {
        let assertionPointers = state.validationContract?.assertions
            .flatMap(\.sourcePointers)
            .compactMap(\.path) ?? []
        return Array(Set(assertionPointers + state.verification.evidence.compactMap(\.path))).sorted()
    }

    private static func encode<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
