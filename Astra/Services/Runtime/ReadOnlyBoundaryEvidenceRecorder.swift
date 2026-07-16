import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

enum ReadOnlyBoundaryEvidenceRecorder {
    @MainActor
    static func record(
        _ evidence: ReadOnlyBoundaryEvidence?,
        task: AgentTask,
        run: TaskRun,
        in modelContext: ModelContext
    ) {
        guard let evidence else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = (try? encoder.encode(evidence))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"status\":\"\(evidence.status.rawValue)\"}"
        let eventType = evidence.status == .applied
            ? TaskEventTypes.System.readOnlyBoundaryApplied
            : TaskEventTypes.System.readOnlyBoundaryUnavailable
        modelContext.insert(TaskEvent(
            task: task,
            eventType: eventType,
            payload: payload,
            run: run
        ))
    }
}
