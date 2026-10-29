import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Retires only the resumable pointer. Prior runs, native session files, task
/// status, and workspace files remain evidence. The caller saves this transition
/// and its event in the same transaction as the rest of the launch or repair.
enum CopilotInstructionSessionService {
    static let eventType = "astra.provider_session_instruction_policy_changed"

    enum Failure: Error { case activeExecution }

    @MainActor
    @discardableResult
    static func resetIfNeeded(
        task: AgentTask,
        instructions: CopilotRepositoryInstructions,
        context: ModelContext,
        admittedRunID: UUID? = nil
    ) throws -> Bool {
        guard task.runtimeID == AgentRuntimeID.copilotCLI.rawValue,
              let session = task.sessionId, !session.isEmpty else { return false }
        guard (task.status != .running || admittedRunID != nil),
              !task.runs.contains(where: { $0.status == .running && $0.id != admittedRunID }) else {
            throw Failure.activeExecution
        }
        let previousRun = task.runs.filter { $0.providerSessionId == session && $0.id != admittedRunID }
            .max { $0.startedAt < $1.startedAt }
        let previous = previousRun.flatMap { ProviderLaunchSignatureService.storedSignature(for: task, run: $0) }
        guard previous?.repositoryInstructionContract != instructions.signatureComponent else { return false }
        let payload = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "previousSessionID": session,
            "mode": instructions.mode.rawValue,
            "instructionContract": instructions.signatureComponent,
            "reason": "repository_instruction_policy_changed",
            "guidancePaths": instructions.files.map(\.path)
        ], options: [.sortedKeys])
        task.sessionId = nil
        context.insert(TaskEvent(task: task, type: eventType, payload: String(decoding: payload, as: UTF8.self)))
        return true
    }
}
